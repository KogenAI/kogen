package tools

import (
	"reflect"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestLCutDefaults(t *testing.T) {
	text := strings.Repeat("0123456789", 4000)
	want := Cut(text)
	tl, err := New(Tools{})
	if err != nil {
		t.Fatal(err)
	}
	if got := tl.Cut(Output{Text: text}).Text; got != want || len(got) > 16384 || !strings.HasPrefix(got, text[:4096]+"\n[... ") {
		t.Errorf("default Tools cut differs: %d bytes", len(got))
	}
	if got := new(Tools).Cut(Output{Text: text}).Text; got != want {
		t.Error("zero literal cut differs")
	}
	if got := (Output{Text: text}).Cut().Text; got != want {
		t.Error("Output.Cut differs")
	}
}

func TestLCutConfigured(t *testing.T) {
	tl, err := New(Tools{ResultBound: 32768, ResultHead: 8192})
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []int{32767, 32768, 32769, 40000} {
		text := strings.Repeat("0123456789", n/10+1)[:n]
		got := tl.Cut(Output{Text: text}).Text
		if n <= 32768 {
			if got != text {
				t.Errorf("%d: fitting text changed", n)
			}
			continue
		}
		if len(got) > 32768 {
			t.Errorf("%d: %d bytes", n, len(got))
		}
		if !strings.HasPrefix(got, text[:8192]+"\n[... ") {
			t.Errorf("%d: head not retained", n)
		}
		i := strings.Index(got[8192:], "bytes omitted ...]\n")
		if i < 0 {
			t.Fatalf("%d: no marker", n)
		}
		tail := got[8192+i+len("bytes omitted ...]\n"):]
		expectedTailSize := 32768 - 8192 - len("\n[... "+strconv.Itoa(n)+" bytes omitted ...]\n")
		if tail != text[len(text)-expectedTailSize:] {
			t.Errorf("%d: tail is not a suffix", n)
		}
		absent := n - 8192 - len(tail)
		if !strings.Contains(got, "\n[... "+strconv.Itoa(absent)+" bytes omitted ...]\n") {
			t.Errorf("%d: marker does not count %d absent bytes", n, absent)
		}
		if tl.Cut(Output{Text: got}).Text != got {
			t.Errorf("%d: not idempotent", n)
		}
	}
}

func TestLCutUTF8AndTyped(t *testing.T) {
	tl, err := New(Tools{ResultBound: 256, ResultHead: 100})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range []string{"é", "€", "😀"} {
		for pad := 0; pad < 4; pad++ {
			text := strings.Repeat("a", pad) + strings.Repeat(r, 400)
			got := tl.Cut(Output{Text: text}).Text
			if !utf8.ValidString(got) || len(got) > 256 || !strings.Contains(got, "bytes omitted") {
				t.Errorf("%q pad %d: %d bytes valid=%v", r, pad, len(got), utf8.ValidString(got))
			}
			if tl.Cut(Output{Text: got}).Text != got {
				t.Errorf("%q pad %d: not idempotent", r, pad)
			}
		}
	}
	typed := Output{Parts: []any{map[string]any{"type": "input_image"}}, Text: strings.Repeat("x", 1000)}
	got := tl.Cut(typed)
	if !reflect.DeepEqual(got, typed) {
		t.Error("typed output changed")
	}
}

func TestLCutValidation(t *testing.T) {
	cases := []struct {
		name       string
		bound, hd  int
		wantErrSub string
	}{
		{"negative bound", -1, 0, "ResultBound"},
		{"negative head", 0, -1, "ResultHead"},
		{"bound 127", 127, 1, "ResultBound"},
		{"bound 128", 128, 1, ""},
		{"bound 129", 129, 1, ""},
		{"head equals bound", 200, 200, "ResultHead"},
		{"head above bound", 200, 300, "ResultHead"},
		{"63 remaining", 200, 137, "remaining"},
		{"64 remaining", 200, 136, ""},
		{"65 remaining", 200, 135, ""},
		{"zero head defaults against small bound", 200, 0, "ResultHead"},
		{"zero bound defaults with small head", 0, 100, ""},
		{"zero bound with head too big", 0, 16384, "ResultHead"},
	}
	for _, c := range cases {
		tl, err := New(Tools{ResultBound: c.bound, ResultHead: c.hd})
		if c.wantErrSub == "" {
			if err != nil || tl == nil {
				t.Errorf("%s: %v", c.name, err)
			}
			continue
		}
		if err == nil || tl != nil || !strings.Contains(err.Error(), c.wantErrSub) {
			t.Errorf("%s: err %v", c.name, err)
		}
	}
}
