package tools

import (
	"bytes"
	"compress/zlib"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"hash/crc32"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

func pngChunk(typ string, data []byte) []byte {
	var b bytes.Buffer
	binary.Write(&b, binary.BigEndian, uint32(len(data)))
	b.WriteString(typ)
	b.Write(data)
	binary.Write(&b, binary.BigEndian, crc32.ChecksumIEEE(append([]byte(typ), data...)))
	return b.Bytes()
}

func deflate(raw []byte) []byte {
	var b bytes.Buffer
	w := zlib.NewWriter(&b)
	w.Write(raw)
	w.Close()
	return b.Bytes()
}

func ihdr(w, h uint32, enc []byte) []byte {
	data := binary.BigEndian.AppendUint32(nil, w)
	data = binary.BigEndian.AppendUint32(data, h)
	return pngChunk("IHDR", append(data, enc...))
}

var rgb8 = []byte{8, 2, 0, 0, 0}

// png is a PNG with these dimensions and raw (unfiltered-length) scanline data; extra
// chunks go between IHDR and IDAT.
func png(w, h uint32, raw []byte, extra []byte, enc []byte) []byte {
	if enc == nil {
		enc = rgb8
	}
	var b bytes.Buffer
	b.Write(pngSignature)
	b.Write(ihdr(w, h, enc))
	b.Write(extra)
	b.Write(pngChunk("IDAT", deflate(raw)))
	b.Write(pngChunk("IEND", nil))
	return b.Bytes()
}

func rawPNG(chunks ...[]byte) []byte {
	return append(append([]byte{}, pngSignature...), bytes.Join(chunks, nil)...)
}

func imageRoot(t *testing.T) (string, *Tools) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return root, newTools(root, ViewImageTool)
}

func view(t *testing.T, tools *Tools, path string) Output {
	t.Helper()
	out, err := tools.Run(ViewImageTool, map[string]any{"path": path})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestOriginalBytesStayTypedThroughOutputCutDeletionAndCompleteJSONAccounting(t *testing.T) {
	root, tools := imageRoot(t)
	bytes_ := png(1, 1, []byte{0, 255, 0, 0}, pngChunk("tEXt", []byte("padding\x00"+strings.Repeat("x", 30_000))), nil)
	path := filepath.Join(root, "pixels.png")
	os.WriteFile(path, bytes_, 0o644)

	if d := Defs(ViewImageTool); len(d) != 1 || d[0]["name"] != "view_image" {
		t.Fatalf("definitions %v", d)
	}
	result := view(t, tools, "pixels.png")
	if !result.Typed() || len(result.Parts) != 2 {
		t.Fatalf("result %+v", result)
	}
	first, second := result.Parts[0].(map[string]any), result.Parts[1].(map[string]any)
	if first["type"] != "input_text" || second["type"] != "input_image" {
		t.Fatalf("parts %v", result.Parts)
	}
	var meta map[string]any
	if err := json.Unmarshal([]byte(first["text"].(string)), &meta); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(bytes_)
	want := map[string]any{
		"version": 1.0, "path": "pixels.png", "sha256": hex.EncodeToString(sum[:]), "bytes": float64(len(bytes_)),
		"format": "png", "width": 1.0, "height": 1.0, "read_candidate": "UNKNOWN", "capture_candidate": "UNKNOWN",
		"route": "UNKNOWN", "viewport": "UNKNOWN", "fixture_state": "UNKNOWN",
	}
	if !reflect.DeepEqual(meta, want) {
		t.Errorf("metadata %v, want %v", meta, want)
	}
	if second["image_url"] != "data:image/png;base64,"+base64.StdEncoding.EncodeToString(bytes_) {
		t.Error("the image URL is not the original bytes")
	}
	if cut := result.Cut(); !reflect.DeepEqual(cut.Parts, result.Parts) {
		t.Error("Cut changed typed parts")
	}

	call := Call{Item: map[string]any{"call_id": "pixels-1"}}
	output := call.Output(result)
	os.Remove(path)
	if !reflect.DeepEqual(output, map[string]any{"type": "function_call_output", "call_id": "pixels-1", "output": result.Parts}) {
		t.Errorf("output %v", output)
	}

	body := provider.NewClient("test").Body(provider.Request{
		Role:         provider.Role{Model: "gpt-6.1-sol", Effort: "high"},
		Instructions: "Δ🙂 policy",
		Input:        []any{output},
		Tools:        AsAny(Defs(ViewImageTool)),
	})
	found := false
	for _, it := range body["input"].([]any) {
		found = found || reflect.DeepEqual(it, output)
	}
	if !found {
		t.Fatal("the image output is not in the request body input")
	}
	empty := map[string]any{}
	for k, v := range body {
		empty[k] = v
	}
	empty["padding"] = ""
	enc, _ := encodeJSON(empty)
	for _, c := range []struct {
		n    int
		fits bool
	}{{524_287, true}, {524_288, true}, {524_289, false}} {
		request := map[string]any{}
		for k, v := range empty {
			request[k] = v
		}
		request["padding"] = strings.Repeat("x", c.n-len(enc))
		m, err := Measure(request)
		if err != nil {
			t.Fatal(err)
		}
		if m != (Measurement{RenderedBytes: c.n, InputBudgetBytes: 524_288, OutputReserveTokens: 131_072, Fits: c.fits}) {
			t.Errorf("measure at %d: %+v", c.n, m)
		}
		err = GuardImages(request, "shape")
		if c.fits && err != nil {
			t.Errorf("guard at %d: %v", c.n, err)
		}
		if !c.fits {
			e, ok := sys.AsError(err)
			if !ok || e.Class != "candidate" || e.Reason != "context_budget_exceeded" || e.Exit != 1 {
				t.Fatalf("guard at %d: %v", c.n, err)
			}
			wantDetail := "shape: measured/mandatory 524289 bytes; ceiling 524288; reserve 131072 tokens. Frozen pixels retained in conversation. Use external image preparation or ordinary Refine and new exact approval."
			if e.Detail != wantDetail {
				t.Errorf("detail %q", e.Detail)
			}
		}
	}
	if len(Cut(strings.Repeat("x", 20_000))) > 16_384 {
		t.Error("cut too long")
	}
}

func TestGuardIgnoresAConversationWithoutImages(t *testing.T) {
	huge := map[string]any{"input": []any{map[string]any{"type": "function_call_output", "call_id": "c", "output": strings.Repeat("x", 600_000)}}}
	if err := GuardImages(huge, "build"); err != nil {
		t.Errorf("text-only request refused: %v", err)
	}
	if err := GuardImages(map[string]any{}, "build"); err != nil {
		t.Errorf("no input: %v", err)
	}
}

func TestBoundedDecoderRejectsMalformedFramingCRCUnsupportedEncodingsFiltersAndBombs(t *testing.T) {
	root, tools := imageRoot(t)
	valid := png(1, 1, []byte{0, 1, 2, 3}, nil, nil)
	good := deflate([]byte{0, 1, 2, 3})
	cases := map[string][]byte{
		"signature": []byte("not png"),
		"truncated": valid[:40],
		"crc":       append(append([]byte{}, valid[:len(valid)-1]...), 0),
		"trailing":  append(append([]byte{}, valid...), "junk"...),
		"compressed_trailing": rawPNG(ihdr(1, 1, rgb8), pngChunk("IDAT", append(append([]byte{}, good...), "junk"...)),
			pngChunk("IEND", nil)),
		"animation":         png(1, 1, []byte{0, 1, 2, 3}, pngChunk("acTL", make([]byte, 8)), nil),
		"duplicate_palette": png(1, 1, []byte{0, 1, 2, 3}, append(pngChunk("PLTE", []byte{1, 2, 3}), pngChunk("PLTE", []byte{4, 5, 6})...), nil),
		"rgba":              png(1, 1, []byte{0, 1, 2, 3}, nil, []byte{8, 6, 0, 0, 0}),
		"interlaced":        png(1, 1, []byte{0, 1, 2, 3}, nil, []byte{8, 2, 0, 0, 1}),
		"filter":            png(1, 1, []byte{5, 1, 2, 3}, nil, nil),
		"short":             png(1, 1, []byte{0, 1, 2}, nil, nil),
		"bomb":              png(1, 1, make([]byte, 1_000_000), nil, nil),
		"zero":              png(0, 1, []byte{0}, nil, nil),
		"dimension":         png(2049, 1, []byte{0}, nil, nil),
		"empty":             {},
		"bytes":             bytes.Repeat([]byte("x"), 131_073),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			os.WriteFile(filepath.Join(root, name), data, 0o644)
			out := view(t, tools, name)
			if out.Typed() {
				t.Fatal("typed result")
			}
			for _, part := range []string{"error:", "external image", "131072"} {
				if !strings.Contains(out.Text, part) {
					t.Errorf("result lacks %q: %s", part, out.Text)
				}
			}
		})
	}
	for _, args := range []map[string]any{{}, {"path": 42}, {"path": "absent"}, {"path": "."}} {
		if out := view2(t, tools, args); !strings.Contains(out.Text, "error:") {
			t.Errorf("%v: %q", args, out.Text)
		}
	}
}

func view2(t *testing.T, tools *Tools, args map[string]any) Output {
	t.Helper()
	out, err := tools.Run(ViewImageTool, args)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestDimensionByteAndFilterInclusiveBounds(t *testing.T) {
	root, tools := imageRoot(t)
	ok := func(name string, data []byte) {
		t.Helper()
		os.WriteFile(filepath.Join(root, "valid"), data, 0o644)
		if out := view(t, tools, "valid"); !out.Typed() {
			t.Errorf("%s: %s", name, out.Text)
		}
	}
	for _, w := range []uint32{1, 2047, 2048} {
		for filter := byte(0); filter <= 4; filter++ {
			ok("filter", png(w, 1, append([]byte{filter}, make([]byte, 3*w)...), nil, nil))
		}
	}
	ok("palette", png(1, 1, []byte{0, 1, 2, 3}, pngChunk("PLTE", []byte{1, 2, 3}), nil))
	for _, n := range []int{131_071, 131_072} {
		base := png(1, 1, []byte{0, 0, 0, 0}, nil, nil)
		data := png(1, 1, []byte{0, 0, 0, 0}, pngChunk("tEXt", []byte("p\x00"+strings.Repeat("x", n-len(base)-14))), nil)
		if len(data) != n {
			t.Fatalf("built %d bytes, want %d", len(data), n)
		}
		ok("size", data)
	}
}

func TestCompactEventsDistinguishReadRejectionUncertainTransportAndCompletedDelivery(t *testing.T) {
	root, tools := imageRoot(t)
	path := filepath.Join(root, "pixels")
	data := png(1, 1, []byte{0, 1, 2, 3}, nil, nil)
	os.WriteFile(path, data, 0o644)
	result := view(t, tools, path)
	call := Call{Item: map[string]any{"call_id": strings.Repeat("Δ\n", 5000)}}

	var events []map[string]any
	emit := func(e map[string]any) { events = append(events, e) }
	emit(ReadEvent(call, result, "review"))
	if ReadEvent(call, Output{Text: "plain"}, "review") != nil {
		t.Error("a text result has a read event")
	}
	input := []any{call.Output(result)}

	for _, facts := range []map[string]any{{"http_status": int64(400)}, {"event_kind": "response.failed"}} {
		failure := &sys.Error{Class: "provider", Reason: "rejected", Detail: "synthetic", ProviderFailure: facts}
		_, err := Deliver(input, "review", emit, func() (*provider.Response, error) { return nil, failure })
		if err != failure {
			t.Errorf("error changed: %v", err)
		}
	}
	uncertain := errors.New("uncertain")
	if _, err := Deliver(input, "review", emit, func() (*provider.Response, error) { return nil, uncertain }); err != uncertain {
		t.Errorf("error changed: %v", err)
	}
	response := &provider.Response{ID: "response-1"}
	if got, err := Deliver(input, "review", emit, func() (*provider.Response, error) { return response, nil }); got != response || err != nil {
		t.Errorf("response changed: %v %v", got, err)
	}

	var statuses []any
	for _, e := range events {
		statuses = append(statuses, e["status"])
	}
	if !reflect.DeepEqual(statuses, []any{"read", "failed", "failed", "unknown", "completed"}) {
		t.Errorf("statuses %v", statuses)
	}
	if events[4]["response_id"] != "response-1" || events[3]["response_id"] != nil {
		t.Errorf("response ids %v %v", events[3]["response_id"], events[4]["response_id"])
	}
	ids := map[any]bool{}
	for _, e := range events[1:] {
		id, _ := e["request_id"].(string)
		if !strings.HasPrefix(id, "image-request-") || ids[id] {
			t.Errorf("each request needs its own image-request-<hex> id: %v", id)
		}
		ids[id] = true
	}
	for _, e := range events {
		line, err := encodeJSON(e)
		if err != nil {
			t.Fatal(err)
		}
		if len(line) > 8192 {
			t.Errorf("event of %d bytes", len(line))
		}
		if strings.Contains(string(line), "data:image") || strings.Contains(string(line), base64.StdEncoding.EncodeToString(data)) {
			t.Errorf("event carries pixels: %s", line)
		}
		if id, _ := e["call_id"].(string); len(id) > 256 {
			t.Errorf("call_id of %d bytes", len(id))
		}
	}
	// What a read event says about the image.
	read := events[0]
	sum := sha256.Sum256(data)
	if read["event"] != "image_read" || read["owner"] != "review" || read["sha256"] != hex.EncodeToString(sum[:]) || read["width"] != int64(1) {
		t.Errorf("read event %v", read)
	}
}

func TestDeliverReportsNothingWithoutImages(t *testing.T) {
	var events []map[string]any
	input := []any{map[string]any{"role": "user", "content": "hi"}, OutputItem("c", "text")}
	if _, err := Deliver(input, "build", func(e map[string]any) { events = append(events, e) },
		func() (*provider.Response, error) { return &provider.Response{}, nil }); err != nil || len(events) != 0 {
		t.Errorf("events %v, error %v", events, err)
	}
	// A nil sink is allowed.
	if _, err := Deliver(input, "build", nil, func() (*provider.Response, error) { return nil, nil }); err != nil {
		t.Fatal(err)
	}
}

func TestDeliveryStatus(t *testing.T) {
	failure := func(facts map[string]any) error { return &sys.Error{ProviderFailure: facts} }
	for _, c := range []struct {
		err  error
		want string
	}{
		{nil, "completed"},
		{failure(map[string]any{"http_status": 429}), "failed"},
		{failure(map[string]any{"http_status": int64(500)}), "failed"},
		{failure(map[string]any{"http_status": "500"}), "unknown"},
		{failure(map[string]any{"event_kind": "response.failed"}), "failed"},
		{failure(map[string]any{"event_kind": "response.incomplete"}), "failed"},
		{failure(map[string]any{"event_kind": "error"}), "failed"},
		{failure(map[string]any{"event_kind": "response.created"}), "unknown"},
		{failure(nil), "unknown"},
		{&sys.Interrupted{Signal: "SIGINT"}, "unknown"},
		{errors.New("network"), "unknown"},
	} {
		if got := DeliveryStatus(c.err); got != c.want {
			t.Errorf("%v: %s, want %s", c.err, got, c.want)
		}
	}
}

func TestImageEntriesNeedExactlyMetadataTextAndImage(t *testing.T) {
	meta := `{"sha256":"abc","path":"p.png"}`
	text := map[string]any{"type": "input_text", "text": meta}
	image := map[string]any{"type": "input_image", "image_url": "data:image/png;base64,AA=="}
	item := func(call any, output any) any {
		return map[string]any{"type": "function_call_output", "call_id": call, "output": output}
	}
	input := []any{
		map[string]any{"role": "user", "content": "x"},
		item("ok", []any{text, image}),
		item("text-output", "plain"),
		item("one-part", []any{text}),
		item("three", []any{text, image, image}),
		item("swapped", []any{image, text}),
		item("bad-json", []any{map[string]any{"type": "input_text", "text": "not json"}, image}),
		item("not-an-object", []any{map[string]any{"type": "input_text", "text": "[1]"}, image}),
		map[string]any{"type": "function_call", "call_id": "call", "name": "view_image"},
	}
	entries := ImageEntries(input)
	if len(entries) != 1 || entries[0].CallID != "ok" || entries[0].Meta["sha256"] != "abc" {
		t.Errorf("entries %v", entries)
	}
}

func TestBoundedTextCutsOnACharacter(t *testing.T) {
	if got := boundedText(strings.Repeat("é", 200), 256); got != strings.Repeat("é", 128) {
		t.Errorf("exact fit: %d bytes", len(got))
	}
	if got := boundedText(strings.Repeat("€", 100), 256); len(got) != 255 {
		t.Errorf("3-byte characters: %d bytes", len(got))
	}
	if got := boundedText("short", 256); got != "short" {
		t.Errorf("short: %q", got)
	}
}

func TestViewImageNeedsARegularReadableFile(t *testing.T) {
	root, tools := imageRoot(t)
	good := png(1, 1, []byte{0, 1, 2, 3}, nil, nil)
	os.WriteFile(filepath.Join(root, "ok.png"), good, 0o644)
	os.Symlink("ok.png", filepath.Join(root, "link.png"))
	os.Symlink("missing.png", filepath.Join(root, "broken.png"))
	os.Mkdir(filepath.Join(root, "dir"), 0o755)
	if out := view(t, tools, "link.png"); !out.Typed() {
		t.Errorf("a link to an image: %s", out.Text)
	}
	if out := view(t, tools, filepath.Join(root, "ok.png")); !out.Typed() {
		t.Errorf("an absolute path: %s", out.Text)
	}
	for path, reason := range map[string]string{
		"dir":        "artifact is not a regular file",
		"missing":    "cannot stat artifact: enoent",
		"ok.png/x":   "cannot stat artifact: enotdir",
		"broken.png": "cannot stat artifact: enoent",
		"a\x00b":     "cannot stat artifact: badarg",
	} {
		if out := view(t, tools, path); !strings.Contains(out.Text, ": "+reason+". Limits: ") {
			t.Errorf("%q: %s", path, out.Text)
		}
	}
	if os.Geteuid() != 0 {
		locked := filepath.Join(root, "locked.png")
		os.WriteFile(locked, good, 0o000)
		out := view(t, tools, "locked.png")
		if !strings.Contains(out.Text, "no match of right hand side value: {:error, :eacces}") {
			t.Errorf("unreadable file: %s", out.Text)
		}
	}
	// A long selected path is shortened to 512 characters in the message.
	long := strings.Repeat("é", 600)
	out := view(t, tools, long)
	if !strings.HasPrefix(out.Text, "error: "+strings.Repeat("é", 512)+": ") {
		t.Errorf("long path: %.80s", out.Text)
	}
}

func TestViewImageNamesTheCandidateItWasReadFrom(t *testing.T) {
	_, root := newRepo(t)
	write(t, root, "keep.txt", "keep\n")
	commitAll(t, root)
	write(t, root, "other/intent.md", "an uncommitted intent\n")
	os.WriteFile(filepath.Join(root, "px.png"), png(1, 1, []byte{0, 1, 2, 3}, nil, nil), 0o644)
	tools := newTools(root, ViewImageTool)

	tree := func() string {
		out := view(t, tools, "px.png")
		if !out.Typed() {
			t.Fatal(out.Text)
		}
		var meta map[string]any
		json.Unmarshal([]byte(out.Parts[0].(map[string]any)["text"].(string)), &meta)
		return meta["read_candidate"].(string)
	}
	all := tree()
	if len(all) != 40 {
		t.Fatalf("candidate %q", all)
	}
	tools.Excluded = []string{"other"}
	if without := tree(); without == all || len(without) != 40 {
		t.Errorf("excluding a folder left the candidate %s (was %s)", without, all)
	}
	if status := gitIn(t, root, "status", "--porcelain"); !strings.Contains(status, "?? other/") {
		t.Errorf("the user's index changed: %q", status)
	}
}

func TestViewImageOutsideARepositoryHasAnUnknownCandidate(t *testing.T) {
	root, tools := imageRoot(t)
	os.WriteFile(filepath.Join(root, "px.png"), png(1, 1, []byte{0, 1, 2, 3}, nil, nil), 0o644)
	out := view(t, tools, "px.png")
	if !out.Typed() || !strings.Contains(out.Parts[0].(map[string]any)["text"].(string), `"read_candidate":"UNKNOWN"`) {
		t.Errorf("%+v", out)
	}
}
