package provider

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// inspectTerm renders a decoded JSON value the way Elixir's inspect/1 does; the text
// appears in messages for incomplete responses (`%{"reason" => "max_output_tokens"}`).
func inspectTerm(v any) string {
	switch x := v.(type) {
	case nil:
		return "nil"
	case bool:
		return strconv.FormatBool(x)
	case string:
		return inspectString(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case int:
		return strconv.Itoa(x)
	case float64:
		return formatFloat(x)
	case []any:
		parts := make([]string, len(x))
		for i, e := range x {
			parts[i] = inspectTerm(e)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, len(keys))
		for i, k := range keys {
			parts[i] = inspectString(k) + " => " + inspectTerm(x[k])
		}
		return "%{" + strings.Join(parts, ", ") + "}"
	}
	return fmt.Sprint(v)
}

func inspectString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	rs := []rune(s)
	for i, r := range rs {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == 0x1b:
			b.WriteString(`\e`)
		case r == 7:
			b.WriteString(`\a`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r == '\v':
			b.WriteString(`\v`)
		case r == 0:
			b.WriteString(`\0`)
		case r == '#' && i+1 < len(rs) && rs[i+1] == '{':
			b.WriteString(`\#`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02X`, r)
		case !unicode.IsPrint(r):
			fmt.Fprintf(&b, `\u%04X`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
