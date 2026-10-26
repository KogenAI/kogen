package tools

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

var omittedMarker = regexp.MustCompile(`(?s)\A(.*)\n\[\.\.\. (\d+) bytes omitted \.\.\.\]\n(.*)\z`)

// checkDelivery is the shared delivery of a tool result (bounded text, idempotent, honest
// about the bytes it omits).
func checkDelivery(t *testing.T, text string) {
	t.Helper()
	call := Call{Item: map[string]any{"call_id": "exact-call"}}
	display := Cut(text)
	out := call.Output(display)
	if out["type"] != "function_call_output" || out["call_id"] != "exact-call" || out["output"] != display {
		t.Fatalf("output item %v", out)
	}
	if !utf8.ValidString(display) || len(display) > 16_384 {
		t.Fatalf("%d bytes, valid=%v", len(display), utf8.ValidString(display))
	}
	if Cut(display) != display {
		t.Fatal("delivery is not idempotent")
	}
	if len(text) <= 16_384 {
		if display != text {
			t.Fatal("fitting text changed")
		}
		return
	}
	m := omittedMarker.FindStringSubmatch(display)
	if m == nil {
		t.Fatalf("no marker in %q", display[:min(len(display), 200)])
	}
	head, tail := m[1], m[3]
	omitted, _ := strconv.Atoi(m[2])
	if !strings.HasPrefix(text, head) || !strings.HasSuffix(text, tail) {
		t.Fatal("the kept ends are not the ends of the text")
	}
	if len(head) < 4093 || len(head) > 4096 {
		t.Fatalf("head %d bytes", len(head))
	}
	if omitted != len(text)-len(head)-len(tail) {
		t.Fatalf("omitted %d, want %d", omitted, len(text)-len(head)-len(tail))
	}
}

func TestSharedDeliveryPreservesFittingTextAndBoundsOversizedTextHonestly(t *testing.T) {
	// ExUnit: test/kogen/tool_output_test.exs: shared delivery preserves fitting text and bounds oversized text honestly
	for _, size := range []int{16_383, 16_384, 16_385} {
		for _, unit := range []string{"x", "Δ🙂\r\n\t\"\\\x00"} {
			text := strings.Repeat(unit, size/len(unit)) + strings.Repeat("z", size%len(unit))
			checkDelivery(t, text)
		}
	}
	// Both ends of a byte-selected region can bisect a multibyte character.
	checkDelivery(t, strings.Repeat("🙂Δ", 90_000))
	checkDelivery(t, "refused: "+strings.Repeat("large control feedback\n", 2_000))
}

func TestANumberedSingleLineCustodyReadIsBoundedOnlyAtDelivery(t *testing.T) {
	// ExUnit: test/kogen/tool_output_test.exs: a numbered single-line custody read is bounded only at delivery
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".kogen/local"), 0o755); err != nil {
		t.Fatal(err)
	}
	original := `{"value":"` + strings.Repeat("x", 514_428) + `"}`
	if len(original) != 514_440 {
		t.Fatalf("fixture %d bytes", len(original))
	}
	path := filepath.Join(root, ".kogen/local/archive.json")
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}
	tools := &Tools{Root: root, Enabled: []string{ReadFileTool}}
	out, err := tools.Run(ReadFileTool, map[string]any{"path": path, "start_line": int64(1), "end_line": int64(35)})
	if err != nil {
		t.Fatal(err)
	}
	if out.Text != "1\t"+original {
		t.Fatalf("the read is %d bytes, want the whole original", len(out.Text))
	}
	checkDelivery(t, out.Text)
	if got, _ := os.ReadFile(path); string(got) != original {
		t.Fatal("the private original changed")
	}
}
