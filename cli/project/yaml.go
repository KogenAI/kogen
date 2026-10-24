package project

import (
	"regexp"
	"strings"
	"unicode"
)

// The YAML subset `.kogen/project.yaml` uses (SET-4): block mappings and sequences, one-line
// flow `[...]` and `{...}`, plain and quoted scalars, comments. Every node keeps its line so
// problems can name it; duplicate keys are errors. Plain `true`, `false` and numbers keep their
// text; the configuration decides what each key accepts.

type nodeKind int

const (
	kindMap nodeKind = iota
	kindSeq
	kindScalar
)

type yamlNode struct {
	kind   nodeKind
	line   int
	pairs  []yamlPair // kindMap
	items  []*yamlNode
	text   string // kindScalar
	null   bool   // empty value, `null` or `~`
	quoted bool
}

type yamlPair struct {
	key  string
	line int
	node *yamlNode
}

// problem is one configuration problem with the source line it names.
type problem struct {
	line int
	msg  string
}

type yamlFail problem

func failAt(n int, msg string) { panic(yamlFail{n, msg}) }

type yamlLine struct {
	n, indent int
	text      string
}

var (
	mappingLineRe = regexp.MustCompile(`^[A-Za-z0-9_.\/-]+:( |$)`)
	splitKeyRe    = regexp.MustCompile(`^([A-Za-z0-9_.\/-]+):(?: (.*))?$`)
	flowPairRe    = regexp.MustCompile(`(?s)^([A-Za-z0-9_.\/-]+):\s*(.*)$`)
)

func trimLeftSpace(s string) string  { return strings.TrimLeftFunc(s, unicode.IsSpace) }
func trimRightSpace(s string) string { return strings.TrimRightFunc(s, unicode.IsSpace) }

// parseYAML returns the document's root node, or the problems that stop it.
func parseYAML(text string) (node *yamlNode, problems []problem) {
	var lines []yamlLine
	for i, raw := range strings.Split(text, "\n") {
		content := stripComment(trimRightSpace(raw))
		if strings.TrimSpace(content) == "" {
			continue
		}
		indent := len(content) - len(strings.TrimLeft(content, " "))
		lines = append(lines, yamlLine{i + 1, indent, trimLeftSpace(content)})
	}
	if len(lines) == 0 {
		return nil, []problem{{1, "the file is empty"}}
	}
	defer func() {
		if r := recover(); r != nil {
			f, ok := r.(yamlFail)
			if !ok {
				panic(r)
			}
			node, problems = nil, []problem{problem(f)}
		}
	}()
	n, rest := yamlBlock(lines, lines[0].indent)
	if len(rest) > 0 {
		return nil, []problem{{rest[0].n, "unexpected indentation"}}
	}
	return n, nil
}

// stripComment removes a comment: `#` at the start or after a space, outside quotes.
func stripComment(s string) string {
	var q byte
	prev := byte(' ')
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '#' && q == 0 && (prev == ' ' || prev == '\t') {
			return trimRightSpace(s[:i])
		}
		if q == 0 && (c == '"' || c == '\'') {
			q = c
		} else if q == c {
			q = 0
		}
		prev = c
	}
	return s
}

func yamlBlock(lines []yamlLine, indent int) (*yamlNode, []yamlLine) {
	if strings.HasPrefix(lines[0].text, "-") {
		return yamlSeq(lines, indent)
	}
	return yamlMap(lines, indent)
}

func scalarNull(n int) *yamlNode { return &yamlNode{kind: kindScalar, line: n, null: true} }

func countDeeper(lines []yamlLine, indent int) int {
	k := 0
	for k < len(lines) && lines[k].indent > indent {
		k++
	}
	return k
}

func yamlSeq(lines []yamlLine, indent int) (*yamlNode, []yamlLine) {
	var items []*yamlNode
	for len(lines) > 0 && lines[0].indent == indent && strings.HasPrefix(lines[0].text, "-") {
		l := lines[0]
		item := l.text[1:]
		if item != "" && !strings.HasPrefix(item, " ") {
			failAt(l.n, "expected a space after -")
		}
		at := indent + 1 + len(item) - len(strings.TrimLeft(item, " "))
		item = trimLeftSpace(item)
		k := countDeeper(lines[1:], indent)
		children, rest := lines[1:1+k], lines[1+k:]
		var node *yamlNode
		switch {
		case item == "" && len(children) == 0:
			node = scalarNull(l.n)
		case item == "":
			node = yamlNested(children)
		case mappingLineRe.MatchString(item):
			node = yamlNested(append([]yamlLine{{l.n, at, item}}, children...))
		case len(children) > 0:
			failAt(children[0].n, "unexpected indentation")
		default:
			node = yamlValue(item, l.n)
		}
		items = append(items, node)
		lines = rest
	}
	return &yamlNode{kind: kindSeq, line: items[0].line, items: items}, lines
}

func yamlNested(lines []yamlLine) *yamlNode {
	node, rest := yamlBlock(lines, lines[0].indent)
	if len(rest) > 0 {
		failAt(rest[0].n, "unexpected indentation")
	}
	return node
}

func yamlMap(lines []yamlLine, indent int) (*yamlNode, []yamlLine) {
	first := lines[0].n
	var pairs []yamlPair
	for len(lines) > 0 {
		l := lines[0]
		if l.indent > indent {
			failAt(l.n, "unexpected indentation")
		}
		if l.indent != indent {
			break
		}
		m := splitKeyRe.FindStringSubmatch(l.text)
		if m == nil {
			failAt(l.n, "expected key: value")
		}
		key, valueText := m[1], strings.TrimSpace(m[2])
		for _, p := range pairs {
			if p.key == key {
				failAt(l.n, "duplicate key "+key)
			}
		}
		k := countDeeper(lines[1:], indent)
		children, rest := lines[1:1+k], lines[1+k:]
		if valueText == "" && len(children) == 0 {
			// A sequence may sit at its key's own indentation.
			for k < len(rest) && (rest[k].indent > indent || (rest[k].indent == indent && strings.HasPrefix(rest[k].text, "-"))) {
				k++
			}
			children, rest = rest[:k], rest[k:]
		}
		var node *yamlNode
		switch {
		case valueText != "" && len(children) > 0:
			failAt(children[0].n, "unexpected indentation")
		case valueText != "":
			node = yamlValue(valueText, l.n)
		case len(children) == 0:
			node = scalarNull(l.n)
		default:
			node = yamlNested(children)
		}
		pairs = append(pairs, yamlPair{key, l.n, node})
		lines = rest
	}
	return &yamlNode{kind: kindMap, line: first, pairs: pairs}, lines
}

// yamlValue reads an inline value: a flow collection, a quoted scalar, or a plain scalar that
// runs to the end of the line (commas and brackets are part of it, as in
// `run: python3 -c "print(1, 2)"`).
func yamlValue(text string, n int) *yamlNode {
	var node *yamlNode
	var rest string
	if strings.ContainsRune("[{\"'", rune(text[0])) {
		node, rest = flow(text, n)
	} else {
		node, rest = plainBlock(text, n)
	}
	if t := strings.TrimSpace(rest); t != "" {
		failAt(n, "unexpected text "+t)
	}
	return node
}

func flow(text string, n int) (*yamlNode, string) {
	switch {
	case strings.HasPrefix(text, "["):
		var items []*yamlNode
		rest := flowItems(trimLeftSpace(text[1:]), n, ']', func(t string) string {
			node, r := flow(t, n)
			items = append(items, node)
			return r
		})
		return &yamlNode{kind: kindSeq, line: n, items: items}, rest
	case strings.HasPrefix(text, "{"):
		var pairs []yamlPair
		rest := flowItems(trimLeftSpace(text[1:]), n, '}', func(t string) string {
			p, r := flowPair(t, n)
			pairs = append(pairs, p)
			return r
		})
		// Duplicates are found once the whole mapping has been read.
		for i, p := range pairs {
			for _, q := range pairs[:i] {
				if q.key == p.key {
					failAt(n, "duplicate key "+p.key)
				}
			}
		}
		return &yamlNode{kind: kindMap, line: n, pairs: pairs}, rest
	case strings.HasPrefix(text, "\""):
		return quotedScalar(text[1:], n, '"')
	case strings.HasPrefix(text, "'"):
		return quotedScalar(text[1:], n, '\'')
	}
	return plainFlow(text, n)
}

// flowItems reads `item {, item}` up to the closing byte and returns the text after it.
func flowItems(text string, n int, closer byte, item func(string) string) string {
	open := "["
	if closer == '}' {
		open = "{"
	}
	first := true
	for {
		if first && len(text) > 0 && text[0] == closer {
			return text[1:]
		}
		rest := item(trimLeftSpace(text))
		first = false
		r := trimLeftSpace(rest)
		switch {
		case strings.HasPrefix(r, ","):
			text = trimLeftSpace(r[1:])
		case len(r) > 0 && r[0] == closer:
			return r[1:]
		default:
			failAt(n, "unclosed "+open)
		}
	}
}

func flowPair(text string, n int) (yamlPair, string) {
	m := flowPairRe.FindStringSubmatch(text)
	if m == nil {
		failAt(n, "expected key: value in {...}")
	}
	key, rest := m[1], m[2]
	if rest == "" || strings.HasPrefix(rest, ",") || strings.HasPrefix(rest, "}") {
		return yamlPair{key, n, scalarNull(n)}, rest
	}
	node, rest := flow(rest, n)
	return yamlPair{key, n, node}, rest
}

func rejectUnsupported(s string, n int) {
	if s != "" && strings.ContainsRune("|>&*!", rune(s[0])) {
		failAt(n, "unsupported YAML: "+s+"; use a quoted string")
	}
}

func plainBlock(text string, n int) (*yamlNode, string) {
	s := strings.TrimSpace(text)
	rejectUnsupported(s, n)
	if s == "null" || s == "~" {
		return scalarNull(n), ""
	}
	return &yamlNode{kind: kindScalar, line: n, text: s}, ""
}

func plainFlow(text string, n int) (*yamlNode, string) {
	cut := strings.IndexAny(text, ",]}")
	if cut < 0 {
		cut = len(text)
	}
	s := strings.TrimSpace(text[:cut])
	rejectUnsupported(s, n)
	if s == "" || s == "null" || s == "~" {
		return scalarNull(n), text[cut:]
	}
	return &yamlNode{kind: kindScalar, line: n, text: s}, text[cut:]
}

func quotedScalar(s string, n int, q byte) (*yamlNode, string) {
	var b strings.Builder
	for i := 0; ; {
		if i >= len(s) {
			failAt(n, "unclosed quote")
		}
		c := s[i]
		switch {
		case q == '\'' && c == q && i+1 < len(s) && s[i+1] == q:
			b.WriteByte('\'')
			i += 2
		case c == q:
			return &yamlNode{kind: kindScalar, line: n, text: b.String(), quoted: true}, s[i+1:]
		case c == '\\' && q == '"' && i+1 < len(s):
			b.WriteString(unescape(s[i+1], n))
			i += 2
		default:
			b.WriteByte(c)
			i++
		}
	}
}

func unescape(c byte, n int) string {
	switch c {
	case 'n':
		return "\n"
	case 't':
		return "\t"
	case '"':
		return "\""
	case '\\':
		return "\\"
	}
	failAt(n, "unknown escape \\"+string([]byte{c}))
	return ""
}
