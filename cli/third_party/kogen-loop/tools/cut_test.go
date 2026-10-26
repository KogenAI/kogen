package tools

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"unicode/utf8"
)

// TestCutMatchesTheElixirCut compares Cut with Kogen.Tools.cut for text around the limit, with
// multi-byte characters at the cut points, with invalid UTF-8 and with many digits in the
// count.
func TestCutMatchesTheElixirCut(t *testing.T) {
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
	parts := Output{Parts: []any{map[string]any{"type": "input_text", "text": strings.Repeat("x", 40_000)}}}
	if got := parts.Cut(); !got.Typed() || len(got.Parts) != 1 || got.Parts[0].(map[string]any)["text"] != parts.Parts[0].(map[string]any)["text"] {
		t.Error("typed output changed")
	}
	long := Output{Text: strings.Repeat("y", 20_000)}
	if got := long.Cut(); got.Typed() || len(got.Text) > 16_384 || got.Text != Cut(long.Text) {
		t.Errorf("text output: %d bytes", len(got.Text))
	}
}
