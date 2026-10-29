package tools

import (
	"bytes"
	"compress/zlib"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"path/filepath"
	"slices"
	"unicode/utf8"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// view_image: one local PNG, read-only, bounded, delivered to the model as typed pixels
// next to a metadata text. Anything outside the limits is a tool result that says so.

const imageLimits = "static non-interlaced RGB8 PNG, 1..131072 bytes, dimensions 1..2048"

const (
	maxImageBytes     = 131_072
	maxImageDimension = 2048
)

// Context budget of a request that carries images (the working-context measure).
const (
	InputBudgetBytes    = provider.InputBudgetBytes
	OutputReserveTokens = provider.OutputReserveTokens
)

var pngSignature = []byte{137, 80, 78, 71, 13, 10, 26, 10}

func (t *Tools) viewImage(args map[string]any) Output {
	path, isString := args["path"].(string)
	parts, err := t.readImage(path, isString)
	if err == nil {
		return Output{Parts: parts}
	}
	if isString {
		if text := refusal(path, err); text != "" {
			return Output{Text: text}
		}
	}
	selected := "(no selected path)"
	if isString {
		selected = firstRunes(path, 512)
	}
	return Output{Text: "error: " + selected + ": unreadable/nonregular artifact or invalid PNG: " +
		firstRunes(err.Error(), 512) + ". Limits: " + imageLimits +
		". Prepare/export a supported image with an ordinary external image preparation/capture tool and select it again."}
}

func firstRunes(s string, n int) string {
	for i := range s {
		if n == 0 {
			return s[:i]
		}
		n--
	}
	return s
}

func (t *Tools) readImage(path string, isString bool) ([]any, error) {
	if !isString {
		return nil, errors.New("path must be a string")
	}
	root, rel, err := t.openRoot(path)
	var ce containError
	switch {
	case errors.As(err, &ce):
		return nil, err
	case err != nil:
		return nil, errors.New("cannot stat artifact: " + reason(err))
	}
	defer root.Close()
	st, err := root.Stat(rel)
	switch {
	case err != nil:
		return nil, errors.New("cannot stat artifact: " + reason(err))
	case !st.Mode().IsRegular():
		return nil, errors.New("artifact is not a regular file")
	}
	f, err := root.Open(rel)
	if err != nil {
		return nil, errors.New("no match of right hand side value: {:error, :" + reason(err) + "}")
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxImageBytes+1))
	if err != nil || len(data) < 1 || len(data) > maxImageBytes {
		return nil, errors.New("original byte limit exceeded or empty/unreadable artifact")
	}
	width, height, err := validatePNG(data)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(data)
	meta := imageMetadata(path, hex.EncodeToString(sum[:]), len(data), width, height, t.candidate())
	return []any{
		map[string]any{"type": "input_text", "text": meta},
		map[string]any{"type": "input_image", "image_url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(data)},
	}, nil
}

// imageMetadata is the metadata text that precedes the pixels: one JSON object with the
// image's facts and the facts Kogen does not know (capture, route, viewport, fixture state).
// The keys come in the order the Elixir Kogen has always printed them, which is not
// alphabetical.
func imageMetadata(path, sha string, size, width, height int, candidate string) string {
	var b bytes.Buffer
	field := func(name string, value any) {
		if b.Len() > 1 {
			b.WriteByte(',')
		}
		writeString(&b, name)
		b.WriteByte(':')
		writeJSON(&b, value)
	}
	b.WriteByte('{')
	field("version", 1)
	field("path", path)
	field("format", "png")
	field("bytes", size)
	field("width", width)
	field("sha256", sha)
	field("capture_candidate", "UNKNOWN")
	field("fixture_state", "UNKNOWN")
	field("height", height)
	field("read_candidate", candidate)
	field("route", "UNKNOWN")
	field("viewport", "UNKNOWN")
	b.WriteByte('}')
	return b.String()
}

// candidate is the tree of the candidate the image was read from, or UNKNOWN.
func (t *Tools) candidate() string {
	repo := t.repo()
	tree, err := repo.Tree(repo.Head(), t.Excluded)
	if err != nil || tree == "" {
		return "UNKNOWN"
	}
	return tree
}

// ---- the PNG ----

type phase int

const (
	phaseHeader phase = iota
	phaseBefore
	phasePalette
	phaseData
	phaseAfter
)

// validatePNG accepts a static, non-interlaced RGB8 PNG whose scanlines are all there with
// legal filters and returns its dimensions. The messages are what the model reads.
func validatePNG(b []byte) (width, height int, err error) {
	if !bytes.HasPrefix(b, pngSignature) {
		return 0, 0, errors.New("invalid PNG signature")
	}
	w, h, compressed, err := pngChunks(b[len(pngSignature):])
	if err != nil {
		return 0, 0, err
	}
	rowSize := 1 + 3*w
	raw, err := inflate(compressed, h*rowSize)
	if err != nil {
		return 0, 0, err
	}
	for i := 0; i < len(raw); i += rowSize {
		if raw[i] > 4 {
			return 0, 0, errors.New("illegal scanline filter")
		}
	}
	return w, h, nil
}

func isLetter(c byte) bool { return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }

func pngChunks(rest []byte) (w, h int, idat []byte, err error) {
	have, ph, idats := false, phaseHeader, 0
	for {
		if len(rest) < 12 {
			return 0, 0, nil, errors.New("malformed or missing PNG chunks")
		}
		size := uint64(binary.BigEndian.Uint32(rest))
		if uint64(len(rest)) < 12+size {
			return 0, 0, nil, errors.New("malformed or missing PNG chunks")
		}
		typ := string(rest[4:8])
		data := rest[8 : 8+size]
		crc := binary.BigEndian.Uint32(rest[8+size:])
		rest = rest[12+size:]

		if crc32.Update(crc32.ChecksumIEEE([]byte(typ)), crc32.IEEETable, data) != crc {
			return 0, 0, nil, errors.New("chunk CRC mismatch")
		}
		if !(isLetter(typ[0]) && isLetter(typ[1]) && isLetter(typ[2]) && isLetter(typ[3])) || typ[2] < 'A' || typ[2] > 'Z' {
			return 0, 0, nil, errors.New("invalid PNG chunk type")
		}

		switch {
		case typ == "IHDR" && !have && ph == phaseHeader:
			if len(data) != 13 {
				return 0, 0, nil, errors.New("invalid IHDR length")
			}
			if !bytes.Equal(data[8:], []byte{8, 2, 0, 0, 0}) {
				return 0, 0, nil, errors.New("unsupported PNG encoding; requires non-interlaced RGB8")
			}
			iw, ih := binary.BigEndian.Uint32(data), binary.BigEndian.Uint32(data[4:])
			if iw < 1 || iw > maxImageDimension || ih < 1 || ih > maxImageDimension {
				return 0, 0, nil, errors.New("dimension limit exceeded")
			}
			w, h, have, ph = int(iw), int(ih), true, phaseBefore

		case typ == "PLTE" && have && ph == phaseBefore && len(data) >= 3 && len(data) <= 768 && len(data)%3 == 0:
			ph = phasePalette

		case typ == "PLTE":
			return 0, 0, nil, errors.New("duplicate, misplaced or invalid PLTE chunk")

		case typ == "IDAT" && have && (ph == phaseBefore || ph == phasePalette || ph == phaseData):
			idat = append(idat, data...)
			idats++
			ph = phaseData

		case typ == "IEND" && have && (ph == phaseData || ph == phaseAfter) && idats > 0 && len(data) == 0 && len(rest) == 0:
			return w, h, idat, nil

		case have && !slices.Contains([]string{"IHDR", "IDAT", "IEND", "acTL", "fcTL", "fdAT"}, typ):
			if typ[0] < 'a' || typ[0] > 'z' {
				return 0, 0, nil, errors.New("unsupported critical chunk")
			}
			if ph == phaseData {
				ph = phaseAfter
			}

		default:
			return 0, 0, nil, errors.New("unsupported encoding, animation or invalid chunk order")
		}
	}
}

// inflate returns exactly limit bytes of the zlib stream in data, which must be the whole
// of data. The output is produced in 4000-byte steps and refused as soon as a step passes
// the limit, so a bomb costs little.
func inflate(data []byte, limit int) ([]byte, error) {
	dataError := errors.New("Erlang error: :data_error")
	in := bytes.NewReader(data)
	zr, err := zlib.NewReader(in)
	if errors.Is(err, zlib.ErrDictionary) && len(data) >= 6 {
		// The Elixir code did not expect zlib to ask for a preset dictionary; its message
		// shows the unexpected answer, with the dictionary's Adler-32.
		return nil, fmt.Errorf("no match of right hand side value:\n\n    {:need_dictionary, %d, []}\n", binary.BigEndian.Uint32(data[2:6]))
	}
	if err != nil {
		return nil, dataError
	}
	var raw []byte
	remaining := limit
	buf := make([]byte, 4000)
	for {
		n := 0
		var rerr error
		for n < len(buf) && rerr == nil {
			var m int
			m, rerr = zr.Read(buf[n:])
			n += m
		}
		finished := errors.Is(rerr, io.EOF)
		if rerr != nil && !finished || finished && in.Len() > 0 {
			return nil, dataError
		}
		if n > remaining {
			return nil, errors.New("decompressed scanline bound exceeded")
		}
		remaining -= n
		raw = append(raw, buf[:n]...)
		if finished {
			break
		}
	}
	if len(raw) != limit {
		return nil, errors.New("incorrect decompressed scanline size")
	}
	return raw, nil
}

// ---- accounting and events ----

// ImageEntry is an image delivered in a conversation: the call that read it and the metadata
// text it carried (path, sha256, bytes, format, width, height, candidate facts).
type ImageEntry struct {
	CallID any
	Meta   map[string]any
}

// ImageEntries lists the function_call_output items of input that carry an image: exactly
// the metadata text and the input_image.
func ImageEntries(input []any) []ImageEntry {
	var entries []ImageEntry
	for _, it := range input {
		m, ok := it.(map[string]any)
		if !ok || m["type"] != "function_call_output" {
			continue
		}
		id, ok := m["call_id"]
		if !ok {
			continue
		}
		parts, ok := m["output"].([]any)
		if !ok || len(parts) != 2 {
			continue
		}
		first, _ := parts[0].(map[string]any)
		second, _ := parts[1].(map[string]any)
		text, isText := first["text"].(string)
		if first["type"] != "input_text" || !isText || second["type"] != "input_image" {
			continue
		}
		meta, err := decodeJSON([]byte(text))
		if mm, ok := meta.(map[string]any); err == nil && ok {
			entries = append(entries, ImageEntry{CallID: id, Meta: mm})
		}
	}
	return entries
}

// Measurement is the rendered size of a request against the context budget.
type Measurement struct {
	RenderedBytes       int
	InputBudgetBytes    int
	OutputReserveTokens int
	Fits                bool
}

// Measure sizes the complete JSON body against the global ceiling and, when a role
// is supplied, any smaller documented family bound. Unknown families remain unknown.
func Measure(body map[string]any, role ...provider.Role) (Measurement, error) {
	enc, err := encodeJSON(body)
	if err != nil {
		return Measurement{}, err
	}
	limit := InputBudgetBytes
	if len(role) > 0 {
		limit = provider.RequestInputBytes(role[0])
	}
	return Measurement{len(enc), limit, OutputReserveTokens, len(enc) <= limit}, nil
}

// GuardImages refuses a request body that carries images and does not fit the context
// budget: the frozen pixels stay in the conversation and cannot be dropped to make room.
func GuardImages(body map[string]any, owner string) error {
	input, _ := body["input"].([]any)
	if len(ImageEntries(input)) == 0 {
		return nil
	}
	m, err := Measure(body)
	if err != nil {
		return err
	}
	if m.Fits {
		return nil
	}
	return sys.Fail("candidate", "context_budget_exceeded",
		fmt.Sprintf("%s: measured/mandatory %d bytes; ceiling %d; reserve %d tokens. Frozen pixels retained in conversation. Use external image preparation or ordinary Refine and new exact approval.",
			owner, m.RenderedBytes, InputBudgetBytes, OutputReserveTokens), 1)
}

// ReadEvent is the image_read event of an image tool result, or nil for any other result:
// the image's metadata with event, owner, call_id and status.
func ReadEvent(call Call, out Output, owner string) map[string]any {
	if !out.Typed() {
		return nil
	}
	entries := ImageEntries([]any{call.Output(out)})
	if len(entries) != 1 {
		return nil
	}
	event := map[string]any{}
	for k, v := range entries[0].Meta {
		event[k] = v
	}
	event["event"] = "image_read"
	event["owner"] = owner
	event["call_id"] = call.CallID()
	event["status"] = "read"
	return boundEvent(event)
}

// DeliveryStatus is how a request that carried images ended: completed, failed when the
// provider rejected it (an HTTP status or a failure event), else unknown, because the
// images may or may not have arrived.
func DeliveryStatus(err error) string {
	if err == nil {
		return "completed"
	}
	if e, ok := sys.AsError(err); ok {
		switch e.ProviderFailure["http_status"].(type) {
		case int, int64:
			return "failed"
		}
		if kind, _ := e.ProviderFailure["event_kind"].(string); kind == "response.failed" || kind == "response.incomplete" || kind == "error" {
			return "failed"
		}
	}
	return "unknown"
}

// DeliveryEvents is one image_delivery event per image in input. requestID names the
// request; responseID is the provider's ("" for none).
func DeliveryEvents(input []any, owner, requestID, status, responseID string) []map[string]any {
	var events []map[string]any
	for _, e := range ImageEntries(input) {
		var response any
		if responseID != "" {
			response = responseID
		}
		events = append(events, boundEvent(map[string]any{
			"event":       "image_delivery",
			"owner":       owner,
			"call_id":     e.CallID,
			"sha256":      e.Meta["sha256"],
			"status":      status,
			"request_id":  requestID,
			"response_id": response,
		}))
	}
	return events
}

// Deliver sends a request with send and reports through emit what became of the images in
// input: image_delivery events with the status completed, failed or unknown. send's result
// and error are returned unchanged.
func Deliver(input []any, owner string, emit func(map[string]any), send func() (*provider.Response, error)) (*provider.Response, error) {
	resp, err := send()
	if len(ImageEntries(input)) == 0 || emit == nil {
		return resp, err
	}
	id := filepath.Base(sys.TmpPath("image-request"))
	response := ""
	if err == nil && resp != nil {
		response = resp.ID
	}
	for _, e := range DeliveryEvents(input, owner, id, DeliveryStatus(err), response) {
		emit(e)
	}
	return resp, err
}

// boundEvent limits each text value of an event to 256 bytes, on a character boundary.
func boundEvent(event map[string]any) map[string]any {
	for k, v := range event {
		if s, ok := v.(string); ok {
			event[k] = boundedText(s, 256)
		}
	}
	return event
}

func boundedText(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	s = s[:limit]
	for !utf8.ValidString(s) {
		s = s[:len(s)-1]
	}
	return s
}
