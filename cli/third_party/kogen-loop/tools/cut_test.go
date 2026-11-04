package tools

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

// TestCutMatchesTheElixirCut compares Cut with Kogen.Tools.cut for text around the limit, with
// multi-byte characters at the cut points and with many digits in the
// count.
func TestCutMatchesTheElixirCut(t *testing.T) {
	t.Parallel()
	data, err := os.ReadFile("testdata/cut_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name, Unit, Sha256, Head string
		N, Bytes                 int
		Marker                   *string
	}
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			t.Parallel()
			unit, err := base64.StdEncoding.DecodeString(c.Unit)
			if err != nil {
				t.Fatal(err)
			}
			got := Cut(strings.Repeat(string(unit), c.N))
			sum := sha256.Sum256([]byte(got))
			if len(got) != c.Bytes || hex.EncodeToString(sum[:]) != c.Sha256 {
				t.Errorf("%d bytes sha256 %x, want %d bytes sha256 %s", len(got), sum, c.Bytes, c.Sha256)
			}
		})
	}
}

func TestCutKeepsHeadAndTailAroundAMarker(t *testing.T) {
	t.Parallel()
	text := strings.Repeat("0123456789", 3000) // 30000 bytes
	got := Cut(text)
	marker := "\n[... 13647 bytes omitted ...]\n"
	if !strings.HasPrefix(got, text[:4096]+"\n[... ") {
		t.Errorf("does not start with the first 4096 bytes and the marker")
	}
	if !strings.Contains(got, marker) {
		t.Errorf("marker %q missing in %q...", marker, got[4090:4140])
	}
	if !strings.HasSuffix(got, text[len(text)-12_288+len(marker):]) {
		t.Errorf("does not end with the last bytes")
	}
	if len(got) > 16_384 {
		t.Errorf("%d bytes", len(got))
	}
	if text[:16_384] != Cut(text[:16_384]) {
		t.Errorf("text at the limit changed")
	}
}

func TestCutEndsOnWholeCharacters(t *testing.T) {
	t.Parallel()
	for _, unit := range []string{"é", "€", "😀"} {
		got := Cut(strings.Repeat(unit, 20_000))
		if !utf8.ValidString(got) {
			t.Errorf("%s: result is not valid UTF-8", unit)
		}
		if len(got) > 16_384 {
			t.Errorf("%s: %d bytes", unit, len(got))
		}
	}
}

func TestCutOfAnOutputPassesTypedPartsUnchanged(t *testing.T) {
	t.Parallel()
	parts := Output{Parts: []any{map[string]any{"type": "input_text", "text": strings.Repeat("x", 40_000)}}}
	if got := parts.Cut(); !got.Typed() || len(got.Parts) != 1 || got.Parts[0].(map[string]any)["text"] != parts.Parts[0].(map[string]any)["text"] {
		t.Error("typed output changed")
	}
	long := Output{Text: strings.Repeat("y", 20_000)}
	if got := long.Cut(); got.Typed() || len(got.Text) > 16_384 || got.Text != Cut(long.Text) {
		t.Errorf("text output: %d bytes", len(got.Text))
	}
}

func TestCutLineAligned(t *testing.T) {
	numberedFrom := func(start, count int) string {
		var b strings.Builder
		for i := start; i < start+count; i++ {
			fmt.Fprintf(&b, "%d\t%s\n", i, strings.Repeat("x", 79))
		}
		return b.String()
	}
	for name, text := range map[string]string{
		"lines":         strings.Repeat(strings.Repeat("a", 79)+"\n", 500),
		"numbered":      numberedFrom(1, 500),
		"numbered from": numberedFrom(99_990, 500),
		"single":        strings.Repeat("x", 30000),
		"unicode":       strings.Repeat("€", 10000),
		"below":         strings.Repeat("x", 16383),
		"at":            strings.Repeat("x", 16384),
		"above":         strings.Repeat("x", 16385),
	} {
		t.Run(name, func(t *testing.T) {
			checkDelivery(t, text)
			got := Cut(text)
			if len(text) <= 16384 {
				return
			}
			m := omittedMarker.FindStringSubmatch(got)
			head, tail := m[1], m[6]
			wantHead := validPrefix(text[:4096])
			if i := strings.LastIndexByte(wantHead, '\n'); i >= 0 {
				wantHead = wantHead[:i+1]
			}
			if head != wantHead {
				t.Fatal("incorrect retained head")
			}
			if m[2] == "" {
				tailBudget := 16384 - 4096 - len(fmt.Sprintf("\n[... %d bytes omitted ...]\n", len(text)))
				wantTail := validSuffix(text[len(text)-tailBudget:])
				if i := strings.IndexByte(wantTail, '\n'); i >= 0 {
					wantTail = wantTail[i+1:]
				}
				if tail != wantTail {
					t.Fatal("incorrect retained tail")
				}
				return
			}
			if name == "single" || name == "unicode" || name == "above" {
				t.Fatalf("line marker for non-line text: %q", got[len(head):len(head)+60])
			}
			lines, _ := strconv.Atoi(m[2])
			if strings.HasPrefix(name, "numbered") {
				a, _ := strconv.Atoi(m[3])
				b, _ := strconv.Atoi(m[4])
				start := 1
				if name == "numbered from" {
					start = 99_990
				}
				if want := start + strings.Count(head, "\n"); a != want || b != a+lines-1 {
					t.Fatalf("range %d-%d, want %d-%d", a, b, want, want+lines-1)
				}
				if !strings.HasPrefix(tail, strconv.Itoa(b+1)+"\t") {
					t.Fatalf("tail does not start at line %d", b+1)
				}
			} else if m[3] != "" {
				t.Fatal("range in plain text marker")
			}
			if strings.Count(head, "\n")+lines+strings.Count(tail, "\n") != strings.Count(text, "\n") {
				t.Fatal("kept and omitted lines do not add up")
			}
		})
	}
}

func TestCutLineForms(t *testing.T) {
	line := strings.Repeat("x", 79) + "\n"
	if got, want := Cut(strings.Repeat(line, 500)), "\n[... 296 lines, 23680 bytes omitted ...]\n"; !strings.Contains(got, want) {
		t.Errorf("plain: missing %q", want)
	}
	// 16385 bytes of 80-byte lines omit exactly one line.
	text := strings.Repeat(line, 205)[:16385]
	if got, want := Cut(text), "\n[... 1 line, 80 bytes omitted ...]\n"; !strings.Contains(got, want) {
		t.Errorf("one line: missing %q in %q", want, got[4000:4200])
	}
	var numbered strings.Builder
	for i := 1; i <= 1200; i++ {
		fmt.Fprintf(&numbered, "%d\trow %d %s\n", i, i, strings.Repeat("y", 24))
	}
	if got, want := Cut(numbered.String()), "\n[... 765 lines (117-881), 28305 bytes omitted ...]\n"; !strings.Contains(got, want) {
		t.Errorf("numbered: missing %q", want)
	}
	if got, want := Cut("exit status: 0\n"+strings.Repeat("a", 29985)), "\n[... 17728 bytes omitted ...]\n"; !strings.Contains(got, want) {
		t.Errorf("status line: missing %q", want)
	}
}

func TestCutMarkerWidthStaysWithinTheBound(t *testing.T) {
	for _, size := range []int{16385, 16400, 99999, 1000000} {
		plain := strings.Repeat(strings.Repeat("x", 79)+"\n", size/80+1)[:size]
		var numbered strings.Builder
		for i := 1; numbered.Len() < size; i++ {
			fmt.Fprintf(&numbered, "%d\t%s\n", i, strings.Repeat("x", 70))
		}
		for name, text := range map[string]string{
			"plain": plain, "numbered": numbered.String()[:size], "single": strings.Repeat("x", size),
		} {
			if got := Cut(text); len(got) > 16384 || Cut(got) != got {
				t.Errorf("%s %d: %d bytes, idempotent=%v", name, size, len(got), Cut(got) == got)
			}
		}
	}
}
