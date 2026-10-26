package tools

import (
	"encoding/json"
	"math"
	"reflect"
	"strings"
	"testing"
)

// TestDecodeAcceptsAndRefusesWhatErlangsJSONDoes lists inputs with the answer Elixir's
// JSON.decode/1 gave (testdata/gen_tools.exs covers more through the tools).
func TestDecodeAcceptsAndRefusesWhatErlangsJSONDoes(t *testing.T) {
	for _, c := range []struct {
		text string
		ok   bool
	}{
		{"{\"path\":\"\xff\"}", false},
		{`{"a":1e999}`, false},
		{`{"a":-1e999}`, false},
		{"\uFEFF{\"a\":1}", false},
		{"{\"a\":\"x\ty\"}", false},
		{`{"a":NaN}`, false},
		{`{"a":.5}`, false},
		{`{"a":1.}`, false},
		{`{"a":+1}`, false},
		{`{"a":"\x"}`, false},
		{`{"a":"\u12"}`, false},
		{`{"a":"\uDC00"}`, false},
		{`{"a":"😀"}`, true},
		{`{"a":"\uD83Dx"}`, false},
		{`{"a":"\uD83DA"}`, false},
		{`{"a":"\uD83D😀"}`, false},
		{`{"a":"\\uD83D"}`, true},
		{"{\"a\":1}\n", true},
		{"{\"a\":1}\x00", false},
		{"{\"a\":\"\u2028\"}", true},
		{`{'a':1}`, false},
		{`{"a":tru}`, false},
		{`{"a":1,,}`, false},
		{`{ "a" : 1 , "b" : [ ] }`, true},
		{`{"a":0.5e-2}`, true},
		{`{"a":-}`, false},
		{`{"a":1e}`, false},
		{`{"a":"\/"}`, true},
		{`{"a":"\b\f"}`, true},
		{`{"a":"\""}`, true},
		{`{"a":"\U0041"}`, false},
		{`{"a":01}`, false},
		{`{"a":-0}`, true},
		{`{"a":1E1}`, true},
		{`{"a":1}{"b":2}`, false},
		{``, false},
		{`   `, false},
		{`{"a":[1,2,{"b":[]}]}`, true},
		{strings.Repeat("[", 50) + strings.Repeat("]", 50), true},
	} {
		_, err := decodeJSON([]byte(c.text))
		if (err == nil) != c.ok {
			t.Errorf("%q: error %v, want ok=%v", c.text, err, c.ok)
		}
	}
}

func TestDecodeKeepsIntegersAndFloatsApart(t *testing.T) {
	v, err := decodeJSON([]byte(`{"i":2,"f":2.0,"e":1e0,"neg":-3,"big":123456789012345678901234567890,"zero":-0,"small":5e-324}`))
	if err != nil {
		t.Fatal(err)
	}
	m := v.(map[string]any)
	if m["i"] != int64(2) || m["f"] != 2.0 || m["e"] != 1.0 || m["neg"] != int64(-3) || m["zero"] != int64(0) || m["small"] != 5e-324 {
		t.Errorf("%#v", m)
	}
	if n, ok := m["big"].(json.Number); !ok || n.String() != "123456789012345678901234567890" {
		t.Errorf("big integer: %#v", m["big"])
	}
	if n, ok := integerValue(m["big"]); !ok || n != math.MaxInt64 {
		t.Errorf("big integer clamps to %d (%v)", n, ok)
	}
	if n, ok := integerValue(json.Number("-123456789012345678901234567890")); !ok || n != math.MinInt64 {
		t.Errorf("big negative integer clamps to %d (%v)", n, ok)
	}
	for _, v := range []any{2.0, "2", nil, true, json.Number("1e3")} {
		if _, ok := integerValue(v); ok {
			t.Errorf("%#v is not an integer", v)
		}
	}
}

func TestEncodeSortsKeysAndEscapesLikeKogenAlwaysHas(t *testing.T) {
	got, err := encodeJSON(map[string]any{
		"b": []any{1, int64(2), 2.5, 1e20, true, nil}, "a": "é\"\\\n\t\x01<>&\u2028", "c": map[string]any{"z": 0.0, "y": []string{"x"}},
		"d": []map[string]any{{"k": json.Number("7")}}, "e": "\xff",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"a":"é\"\\\n\t\u0001<>&` + "\u2028" + `","b":[1,2,2.5,1.0e20,true,null],"c":{"y":["x"],"z":0.0},"d":[{"k":7}],"e":"` + "\uFFFD" + `"}`
	if string(got) != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
	if _, err := encodeJSON(math.NaN()); err == nil {
		t.Error("NaN encoded")
	}
	// A value of another type goes through encoding/json.
	got, err = encodeJSON(struct {
		B int    `json:"b"`
		A string `json:"a"`
	}{1, "x"})
	if err != nil || string(got) != `{"a":"x","b":1}` {
		t.Errorf("struct: %s %v", got, err)
	}
}

func TestFormatFloatIsErlangsShortestForm(t *testing.T) {
	for f, want := range map[float64]string{0: "0.0", 1: "1.0", 0.5: "0.5", 1e20: "1.0e20", 123456.789: "123456.789", 1e-7: "1.0e-7", -2.5: "-2.5", 100: "100.0", 1e15: "1.0e15"} {
		if got := formatFloat(f); got != want {
			t.Errorf("%v: %s, want %s", f, got, want)
		}
	}
	_ = reflect.DeepEqual
}
