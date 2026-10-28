package build

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"kogen-loop/provider"
	"kogen-loop/tools"
)

// Run-record measurements (hashes, byte counts, token counts, line numbers only): they are
// taken where Kogen builds a request and receives a tool result, never from request or file
// content.

// requestUsage is the usage of a request event: the totals and the provider-reported
// cache-write tokens (null when the provider does not report them).
type requestUsage struct {
	Tokens
	CacheWrite *int `json:"cache_write"`
}

func requestUsageOf(got Tokens, resp *provider.Response) requestUsage {
	return requestUsage{Tokens: got, CacheWrite: resp.Known.Write}
}

// requestBytes is the byte length of the serialized request body.
func (b *Attempt) requestBytes(req provider.Request) int {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(b.deps.Client.Body(req)); err != nil {
		return 0
	}
	return buf.Len() - 1
}

var omittedMarker = regexp.MustCompile(`\n\[\.\.\. (\d+) bytes omitted \.\.\.\]\n`)

// cutFields are bytes_before_cut and bytes_delivered of a tool result that tools.Cut cut
// (nil for an uncut one). The cut keeps a head of at most 4096 bytes before the marker that
// counts the omitted bytes, so the uncut size is the delivered size less the marker plus them.
func cutFields(delivered string) map[string]any {
	if len(delivered) > 16384 {
		return nil
	}
	loc := omittedMarker.FindStringSubmatchIndex(delivered)
	if loc == nil || loc[0] > 4096 || loc[0] < 4000 {
		return nil
	}
	var omitted int
	if err := json.Unmarshal([]byte(delivered[loc[2]:loc[3]]), &omitted); err != nil {
		return nil
	}
	return map[string]any{"bytes_before_cut": len(delivered) - (loc[1] - loc[0]) + omitted, "bytes_delivered": len(delivered)}
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func lineArg(v any) (int64, bool) {
	switch n := v.(type) {
	case int64:
		return n, true
	case int:
		return int64(n), true
	case float64:
		return int64(n), n == float64(int64(n))
	case json.Number:
		i, err := n.Int64()
		return i, err == nil
	}
	return 0, false
}

// toolRecordFields are the extra fields of a tool_call or review_tool_call event: the cut
// sizes of a cut text result and, for a successful read_file, its source and the hash of the
// entire file (or pinned review part) at read time. partID names a pinned review source
// part by its path.
func (b *Attempt) toolRecordFields(call tools.Call, out tools.Output, partID func(path string) (int, bool)) map[string]any {
	extra := map[string]any{}
	if !out.Typed() {
		for k, v := range cutFields(out.Text) {
			extra[k] = v
		}
	}
	if call.Name != tools.ReadFileTool {
		return extra
	}
	args := call.Args()
	path, ok := args["path"].(string)
	if !ok || strings.ContainsRune(path, 0) {
		return extra
	}
	abs := path
	if path == "~" || strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			abs = home + path[1:]
		}
	}
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(b.Root, abs)
	}
	abs = filepath.Clean(abs)
	data, err := os.ReadFile(abs)
	if err != nil {
		return extra
	}
	extra["content_sha256"] = sha256Hex(data)
	if id, ok := partID(abs); ok {
		extra["source"] = map[string]any{"kind": "review_source_part", "part_id": id}
		return extra
	}
	lines := strings.Split(string(data), "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	start, end := int64(1), int64(len(lines))
	if n, ok := lineArg(args["start_line"]); ok && n > 0 {
		start = n
	}
	if n, ok := lineArg(args["end_line"]); ok && n >= start {
		end = min(n, end)
	}
	extra["source"] = map[string]any{
		"kind": "file", "path_sha256": sha256Hex([]byte(path)), "start_line": start, "end_line": end,
		"whole": start == 1 && end == int64(len(lines)),
	}
	return extra
}

// reviewPartID is the number of the pinned review source part stored at path, if it is one
// of the current review's.
func (b *Attempt) reviewPartID(path string) (int, bool) {
	c, err := b.reviewCustody(nil)
	if err != nil || c == nil {
		return 0, false
	}
	n, ok := c.numbers[filepath.Clean(path)]
	return n, ok && n > 0
}
