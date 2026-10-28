package loop

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"kogen-loop/tools"
)

const ledgerCap = 8192

// ReadLedger retains bounded read references for one caller-owned logical round.
type ReadLedger struct {
	entries []any
	dropped int
}

// NewReadLedger enables an initially empty read ledger.
func NewReadLedger() *ReadLedger { return &ReadLedger{} }

func (l *ReadLedger) content() []byte {
	b, _ := json.Marshal(struct {
		Type    string `json:"type"`
		Dropped int    `json:"dropped"`
		Entries []any  `json:"entries"`
	}{"read_ledger", l.dropped, l.entries})
	return b
}

func (l *ReadLedger) record(call tools.Call, out tools.Output, full string) {
	path, _ := call.Args()["path"].(string)
	var entry any
	if call.Name == tools.ReadFileTool {
		start, end := 0, 0
		for _, line := range strings.Split(full, "\n") {
			n, _, ok := strings.Cut(line, "\t")
			if !ok {
				continue
			}
			i, err := strconv.Atoi(n)
			if err != nil {
				continue
			}
			if start == 0 {
				start = i
			}
			end = i
		}
		note := ""
		for _, line := range strings.Split(out.Text, "\n") {
			n, text, ok := strings.Cut(line, "\t")
			if !ok {
				continue
			}
			if _, err := strconv.Atoi(n); err != nil {
				continue
			}
			text = strings.TrimSpace(text)
			if text != "" {
				r := []rune(text)
				if len(r) > 80 {
					r = r[:80]
				}
				note = string(r)
				break
			}
		}
		sum := sha256.Sum256([]byte(out.Text))
		entry = map[string]any{"tool": call.Name, "path": path, "start_line": start, "end_line": end, "sha256": fmt.Sprintf("%x", sum), "note": note}
	} else if call.Name == tools.ViewImageTool {
		meta := out.Parts[0].(map[string]any)["text"].(string)
		var data struct {
			SHA string `json:"sha256"`
		}
		_ = json.Unmarshal([]byte(meta), &data)
		entry = map[string]any{"tool": call.Name, "path": path, "sha256": data.SHA}
	} else {
		return
	}
	l.entries = append(l.entries, entry)
	for len(l.content()) > ledgerCap && len(l.entries) > 0 {
		l.entries = l.entries[1:]
		l.dropped++
	}
}

// Continuation appends one bounded ledger message to a copy of fresh base input.
// The returned event belongs to the caller's run-event sink.
func (l *ReadLedger) Continuation(base []any) ([]any, map[string]any) {
	if l.entries == nil {
		l.entries = []any{}
	}
	content := l.content()
	input := make([]any, len(base), len(base)+1)
	copy(input, base)
	input = append(input, map[string]any{"role": "user", "content": string(content)})
	return input, map[string]any{"event": "read_ledger_reset", "entries": len(l.entries), "bytes": len(content), "dropped": l.dropped}
}
