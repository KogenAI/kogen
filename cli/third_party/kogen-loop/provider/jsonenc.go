package provider

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// encodeJSON encodes v as compact JSON the way Kogen's Elixir implementation does, which
// matters because prompt-cache fingerprints hash these bytes: object keys sorted by byte
// order, strings escaped only for `"`, `\` and control characters (uppercase \u00XX), no
// HTML escaping, integers verbatim and floats in Erlang's shortest form (1.0e3, 0.5).
func encodeJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := writeJSON(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

func mustEncode(v any) []byte {
	b, err := encodeJSON(v)
	if err != nil {
		panic(err)
	}
	return b
}

func writeJSON(b *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(x))
	case string:
		writeString(b, x)
	case int:
		b.WriteString(strconv.FormatInt(int64(x), 10))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case int32:
		b.WriteString(strconv.FormatInt(int64(x), 10))
	case uint64:
		b.WriteString(strconv.FormatUint(x, 10))
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return fmt.Errorf("cannot encode %v as JSON", x)
		}
		b.WriteString(formatFloat(x))
	case json.Number:
		s := x.String()
		if strings.ContainsAny(s, ".eE") {
			f, err := strconv.ParseFloat(s, 64)
			if err != nil || math.IsInf(f, 0) {
				return fmt.Errorf("cannot encode number %q", s)
			}
			b.WriteString(formatFloat(f))
		} else {
			b.WriteString(s)
		}
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			writeString(b, k)
			b.WriteByte(':')
			if err := writeJSON(b, x[k]); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	case []any:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := writeJSON(b, e); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	default:
		raw, err := json.Marshal(x)
		if err != nil {
			return err
		}
		n, err := decodeJSON(raw)
		if err != nil {
			return err
		}
		return writeJSON(b, n)
	}
	return nil
}

const hexUpper = "0123456789ABCDEF"

func writeString(b *bytes.Buffer, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			b.WriteString("�")
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte(hexUpper[r>>4])
			b.WriteByte(hexUpper[r&15])
		default:
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	b.WriteByte('"')
}

// formatFloat renders f like Erlang's float_to_binary(f, [short]): the shorter of the
// decimal and the scientific form (decimal on a tie), always scientific from 2^53 up.
func formatFloat(f float64) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	s := strconv.FormatFloat(f, 'e', -1, 64)
	sign := ""
	if s[0] == '-' {
		sign, s = "-", s[1:]
	}
	mant, exp, _ := strings.Cut(s, "e")
	e, _ := strconv.Atoi(exp)
	digits := strings.Replace(mant, ".", "", 1)
	rest := digits[1:]
	if rest == "" {
		rest = "0"
	}
	sci := digits[:1] + "." + rest + "e" + strconv.Itoa(e)
	var dec string
	switch {
	case e < 0:
		dec = "0." + strings.Repeat("0", -e-1) + digits
	case len(digits) <= e+1:
		dec = digits + strings.Repeat("0", e+1-len(digits)) + ".0"
	default:
		dec = digits[:e+1] + "." + digits[e+1:]
	}
	if math.Abs(f) < 1<<53 && len(dec) <= len(sci) {
		return sign + dec
	}
	return sign + sci
}

// decodeJSON decodes one JSON value into maps, slices, strings, bools, nil, int64 for
// integers, float64 for other numbers and json.Number for integers beyond int64, so the
// integer/float distinction of the wire survives re-encoding.
func decodeJSON(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, fmt.Errorf("trailing data after JSON value")
	}
	return normalize(v), nil
}

func normalize(v any) any {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			x[k] = normalize(e)
		}
		return x
	case []any:
		for i, e := range x {
			x[i] = normalize(e)
		}
		return x
	case json.Number:
		s := x.String()
		if !strings.ContainsAny(s, ".eE") {
			if n, err := strconv.ParseInt(s, 10, 64); err == nil {
				return n
			}
			return x
		}
		f, err := strconv.ParseFloat(s, 64)
		if err != nil {
			return x
		}
		return f
	}
	return v
}

// asMap returns v as a JSON object.
func asMap(v any) (map[string]any, bool) {
	m, ok := v.(map[string]any)
	return m, ok
}

func asList(v any) ([]any, bool) {
	switch x := v.(type) {
	case []any:
		return x, true
	case []map[string]any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = e
		}
		return out, true
	}
	return nil, false
}

// asInt returns v when it is an integer (not a float), like Elixir's is_integer.
func asInt(v any) (int64, bool) {
	switch x := v.(type) {
	case int64:
		return x, true
	case int:
		return int64(x), true
	}
	return 0, false
}

func str(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok
}

// text is a string value or "".
func text(v any) string {
	s, _ := v.(string)
	return s
}

func nonempty(v any) bool {
	s, ok := v.(string)
	return ok && s != ""
}
