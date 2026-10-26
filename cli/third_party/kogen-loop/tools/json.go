package tools

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// encodeJSON is compact JSON the way Kogen has always written it: object keys sorted by
// byte order, strings escaped only for `"`, `\` and control characters (uppercase \u00XX),
// no HTML escaping. It is the same encoding as kogen/provider's request bodies, whose size
// the image guard measures.
func encodeJSON(v any) ([]byte, error) {
	var b bytes.Buffer
	if err := writeJSON(&b, v); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
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
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
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
	case []map[string]any:
		l := make([]any, len(x))
		for i, e := range x {
			l[i] = e
		}
		return writeJSON(b, l)
	case []string:
		l := make([]any, len(x))
		for i, e := range x {
			l[i] = e
		}
		return writeJSON(b, l)
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
// integer/float distinction of the wire survives. Like Erlang's JSON, it refuses text that
// is not valid UTF-8, unpaired surrogate escapes and numbers too large for a float.
func decodeJSON(data []byte) (any, error) {
	if !utf8.Valid(data) {
		return nil, fmt.Errorf("invalid UTF-8")
	}
	if !pairedSurrogates(data) {
		return nil, fmt.Errorf("unpaired surrogate escape")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := decodeValue(dec, 0)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("trailing data after JSON value")
	}
	return v, nil
}

const maxDepth = 10_000

// decodeValue reads one value. Like Erlang's JSON, an object keeps the first of a repeated
// key.
func decodeValue(dec *json.Decoder, depth int) (any, error) {
	if depth > maxDepth {
		return nil, fmt.Errorf("JSON nested too deeply")
	}
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		if t == '{' {
			m := map[string]any{}
			for dec.More() {
				key, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := decodeValue(dec, depth+1)
				if err != nil {
					return nil, err
				}
				if _, dup := m[key.(string)]; !dup {
					m[key.(string)] = v
				}
			}
			_, err := dec.Token()
			return m, err
		}
		l := []any{}
		for dec.More() {
			v, err := decodeValue(dec, depth+1)
			if err != nil {
				return nil, err
			}
			l = append(l, v)
		}
		_, err := dec.Token()
		return l, err
	case json.Number:
		return number(t)
	}
	return tok, nil
}

// pairedSurrogates is false when a string has a \uD800..\uDBFF escape without a following
// \uDC00..\uDFFF escape, or a \uDC00..\uDFFF escape without a preceding one.
func pairedSurrogates(data []byte) bool {
	hex4 := func(i int) (rune, bool) {
		if i+6 > len(data) || data[i] != '\\' || data[i+1] != 'u' {
			return 0, false
		}
		n, err := strconv.ParseUint(string(data[i+2:i+6]), 16, 32)
		return rune(n), err == nil
	}
	inString := false
	for i := 0; i < len(data); i++ {
		switch c := data[i]; {
		case !inString:
			inString = c == '"'
		case c == '"':
			inString = false
		case c == '\\':
			if i+1 < len(data) && data[i+1] == 'u' {
				if r, ok := hex4(i); ok {
					switch {
					case r >= 0xD800 && r <= 0xDBFF:
						low, ok := hex4(i + 6)
						if !ok || low < 0xDC00 || low > 0xDFFF {
							return false
						}
						i += 6
					case r >= 0xDC00 && r <= 0xDFFF:
						return false
					}
					i += 5
					continue
				}
			}
			i++
		}
	}
	return true
}

// number is n as int64, float64, or json.Number for an integer beyond int64.
func number(n json.Number) (any, error) {
	s := n.String()
	if !strings.ContainsAny(s, ".eE") {
		if i, err := strconv.ParseInt(s, 10, 64); err == nil {
			return i, nil
		}
		return n, nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsInf(f, 0) {
		return nil, fmt.Errorf("number %s out of range", s)
	}
	return f, nil
}
