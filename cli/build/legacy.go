package build

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"strconv"
	"strings"
	"unicode/utf8"

	"kogen/project"
	"kogen/provider"
	"kogen/verify"
)

// This file reads the version 3 checkpoints of the Elixir Kogen: the JSON envelope of
// `Kogen.Run.decode_checkpoint/1`, whose `state` is the base64 of `:erlang.term_to_binary` of
// the Build's map, and maps that map onto this package's State. Nothing in a checkpoint is
// ever executed: the Erlang external term format is decoded by a reader that knows only the
// tags `term_to_binary` writes for this data and refuses every other tag (funs, pids, ports,
// references, bit strings, atom-cache references), that never allocates more than the input
// can fill and that bounds nesting.

// The reasons a version 3 checkpoint is refused (the texts of `decode_checkpoint/1`).
const (
	legacyMalformed = "malformed required checkpoint fields"
	legacyDamaged   = "damaged checkpoint state"
)

const (
	// legacyMaxTerm bounds the encoded term (after inflating) and legacyMaxState the base64
	// text it comes from; legacyMaxDepth bounds the nesting of terms.
	legacyMaxTerm  = 32 << 20
	legacyMaxState = legacyMaxTerm/3*4 + 8
	legacyMaxDepth = 512
)

// ---- the Erlang external term format ----

// A decoded term is one of: int64, *big.Int (only beyond int64), float64, legacyAtom, string
// (a binary: any bytes), []any (a proper list, never nil), *legacyImproper, legacyTuple or
// *legacyMap.
type legacyAtom string

type legacyTuple []any

// legacyImproper is a list with a tail that is not a list.
type legacyImproper struct {
	Items []any
	Tail  any
}

// legacyMap is a map term in the order it was written; keys are unique.
type legacyMap struct {
	keys, vals []any
	index      map[string]int
}

func (m *legacyMap) get(key any) (any, bool) {
	i, ok := m.index[legacyKey(key)]
	if !ok {
		return nil, false
	}
	return m.vals[i], true
}

// atom is the value under the atom key name.
func (m *legacyMap) atom(name string) (any, bool) { return m.get(legacyAtom(name)) }

// legacyKey is a canonical text of a term, to tell equal keys apart.
func legacyKey(t any) string {
	switch x := t.(type) {
	case int64:
		return "i" + strconv.FormatInt(x, 10)
	case *big.Int:
		return "i" + x.String()
	case float64:
		return "f" + strconv.FormatUint(math.Float64bits(x), 16)
	case legacyAtom:
		return "a" + strconv.Itoa(len(x)) + ":" + string(x)
	case string:
		return "b" + strconv.Itoa(len(x)) + ":" + x
	case []any:
		var b strings.Builder
		b.WriteString("l[")
		for _, e := range x {
			b.WriteString(legacyKey(e))
			b.WriteByte(',')
		}
		b.WriteByte(']')
		return b.String()
	case *legacyImproper:
		return "p" + legacyKey(x.Items) + "|" + legacyKey(x.Tail)
	case legacyTuple:
		var b strings.Builder
		b.WriteString("t{")
		for _, e := range x {
			b.WriteString(legacyKey(e))
			b.WriteByte(',')
		}
		b.WriteByte('}')
		return b.String()
	case *legacyMap:
		var b strings.Builder
		b.WriteString("m%{")
		for i, k := range x.keys {
			b.WriteString(legacyKey(k) + "=>" + legacyKey(x.vals[i]) + ",")
		}
		b.WriteByte('}')
		return b.String()
	}
	return "?"
}

var errLegacyTerm = errors.New("unreadable external term")

// legacyDecodeTerm reads one term in the external term format, from its version byte. Bytes
// after the term are ignored, as `binary_to_term/1` ignores them.
func legacyDecodeTerm(data []byte) (any, error) {
	if len(data) > legacyMaxTerm || len(data) < 2 || data[0] != 131 {
		return nil, errLegacyTerm
	}
	body := data[1:]
	if body[0] == 80 { // compressed: size, then a zlib stream of the term
		if len(body) < 5 {
			return nil, errLegacyTerm
		}
		size := binary.BigEndian.Uint32(body[1:5])
		if size > legacyMaxTerm {
			return nil, errLegacyTerm
		}
		zr, err := zlib.NewReader(bytes.NewReader(body[5:]))
		if err != nil {
			return nil, errLegacyTerm
		}
		inflated, err := io.ReadAll(io.LimitReader(zr, int64(size)+1))
		if err != nil || len(inflated) != int(size) {
			return nil, errLegacyTerm
		}
		body = inflated
	}
	r := &legacyReader{b: body}
	return r.term(0)
}

type legacyReader struct {
	b []byte
	i int
}

func (r *legacyReader) left() int { return len(r.b) - r.i }

func (r *legacyReader) take(n int) ([]byte, error) {
	if n < 0 || n > r.left() {
		return nil, errLegacyTerm
	}
	s := r.b[r.i : r.i+n]
	r.i += n
	return s, nil
}

func (r *legacyReader) u8() (int, error) {
	s, err := r.take(1)
	if err != nil {
		return 0, err
	}
	return int(s[0]), nil
}

func (r *legacyReader) u16() (int, error) {
	s, err := r.take(2)
	if err != nil {
		return 0, err
	}
	return int(binary.BigEndian.Uint16(s)), nil
}

// u32 is a count that must still fit in the input (every element takes a byte at least).
func (r *legacyReader) u32() (int, error) {
	s, err := r.take(4)
	if err != nil {
		return 0, err
	}
	n := binary.BigEndian.Uint32(s)
	if uint64(n) > uint64(len(r.b)) {
		return 0, errLegacyTerm
	}
	return int(n), nil
}

func (r *legacyReader) term(depth int) (any, error) {
	if depth > legacyMaxDepth {
		return nil, errLegacyTerm
	}
	tag, err := r.u8()
	if err != nil {
		return nil, err
	}
	switch tag {
	case 97: // SMALL_INTEGER_EXT
		n, err := r.u8()
		return int64(n), err
	case 98: // INTEGER_EXT
		s, err := r.take(4)
		if err != nil {
			return nil, err
		}
		return int64(int32(binary.BigEndian.Uint32(s))), nil
	case 70: // NEW_FLOAT_EXT
		s, err := r.take(8)
		if err != nil {
			return nil, err
		}
		f := math.Float64frombits(binary.BigEndian.Uint64(s))
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return nil, errLegacyTerm
		}
		return f, nil
	case 99: // FLOAT_EXT: the old 31-byte text
		s, err := r.take(31)
		if err != nil {
			return nil, err
		}
		text := strings.TrimRight(string(s), "\x00")
		f, err := strconv.ParseFloat(text, 64)
		if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
			return nil, errLegacyTerm
		}
		return f, nil
	case 110, 111: // SMALL_BIG_EXT, LARGE_BIG_EXT
		var n int
		if tag == 110 {
			n, err = r.u8()
		} else {
			n, err = r.u32()
		}
		if err != nil {
			return nil, err
		}
		sign, err := r.u8()
		if err != nil || sign > 1 {
			return nil, errLegacyTerm
		}
		digits, err := r.take(n)
		if err != nil {
			return nil, err
		}
		be := make([]byte, n)
		for i, d := range digits {
			be[n-1-i] = d
		}
		v := new(big.Int).SetBytes(be)
		if sign == 1 {
			v.Neg(v)
		}
		if v.IsInt64() {
			return v.Int64(), nil
		}
		return v, nil
	case 100, 115, 118, 119: // ATOM_EXT, SMALL_ATOM_EXT (Latin-1); ATOM_UTF8_EXT, SMALL_ATOM_UTF8_EXT
		var n int
		if tag == 115 || tag == 119 {
			n, err = r.u8()
		} else {
			n, err = r.u16()
		}
		if err != nil {
			return nil, err
		}
		s, err := r.take(n)
		if err != nil {
			return nil, err
		}
		if tag == 118 || tag == 119 {
			if !utf8.Valid(s) || utf8.RuneCount(s) > 255 {
				return nil, errLegacyTerm
			}
			return legacyAtom(s), nil
		}
		if n > 255 {
			return nil, errLegacyTerm
		}
		runes := make([]rune, n)
		for i, c := range s {
			runes[i] = rune(c)
		}
		return legacyAtom(string(runes)), nil
	case 109: // BINARY_EXT
		n, err := r.u32()
		if err != nil {
			return nil, err
		}
		s, err := r.take(n)
		return string(s), err
	case 107: // STRING_EXT: a list of bytes
		n, err := r.u16()
		if err != nil {
			return nil, err
		}
		s, err := r.take(n)
		if err != nil {
			return nil, err
		}
		list := make([]any, n)
		for i, c := range s {
			list[i] = int64(c)
		}
		return list, nil
	case 106: // NIL_EXT
		return []any{}, nil
	case 108: // LIST_EXT
		n, err := r.u32()
		if err != nil {
			return nil, err
		}
		items := make([]any, 0, min(n, r.left()))
		for range n {
			e, err := r.term(depth + 1)
			if err != nil {
				return nil, err
			}
			items = append(items, e)
		}
		tail, err := r.term(depth + 1)
		if err != nil {
			return nil, err
		}
		switch t := tail.(type) {
		case []any:
			return append(items, t...), nil
		case *legacyImproper:
			return &legacyImproper{Items: append(items, t.Items...), Tail: t.Tail}, nil
		}
		return &legacyImproper{Items: items, Tail: tail}, nil
	case 104, 105: // SMALL_TUPLE_EXT, LARGE_TUPLE_EXT
		var n int
		if tag == 104 {
			n, err = r.u8()
		} else {
			n, err = r.u32()
		}
		if err != nil {
			return nil, err
		}
		if n > r.left() {
			return nil, errLegacyTerm
		}
		t := make(legacyTuple, 0, n)
		for range n {
			e, err := r.term(depth + 1)
			if err != nil {
				return nil, err
			}
			t = append(t, e)
		}
		return t, nil
	case 116: // MAP_EXT
		n, err := r.u32()
		if err != nil {
			return nil, err
		}
		if 2*n > r.left() {
			return nil, errLegacyTerm
		}
		m := &legacyMap{index: make(map[string]int, n)}
		for range n {
			k, err := r.term(depth + 1)
			if err != nil {
				return nil, err
			}
			v, err := r.term(depth + 1)
			if err != nil {
				return nil, err
			}
			switch k.(type) {
			case int64, *big.Int, float64, legacyAtom, string:
			default:
				return nil, errLegacyTerm // a Build's maps are keyed by atoms and binaries
			}
			id := legacyKey(k)
			if _, dup := m.index[id]; dup {
				return nil, errLegacyTerm
			}
			m.index[id] = len(m.keys)
			m.keys = append(m.keys, k)
			m.vals = append(m.vals, v)
		}
		return m, nil
	}
	return nil, errLegacyTerm
}

// ---- terms as JSON values ----

// legacyFloatText is a float the way Elixir's JSON encoder writes it: the shortest digits
// that read back the same, in the shorter of the decimal and the exponent form (decimal on a
// tie).
func legacyFloatText(f float64) string {
	sign := ""
	if math.Signbit(f) {
		sign, f = "-", -f
	}
	e := strconv.FormatFloat(f, 'e', -1, 64) // d.ddde±XX
	mant, expText, _ := strings.Cut(e, "e")
	exp, _ := strconv.Atoi(expText)
	digits := strings.Replace(mant, ".", "", 1)
	var dec string
	switch {
	case exp >= 0 && len(digits) <= exp+1:
		dec = digits + strings.Repeat("0", exp+1-len(digits)) + ".0"
	case exp >= 0:
		dec = digits[:exp+1] + "." + digits[exp+1:]
	default:
		dec = "0." + strings.Repeat("0", -exp-1) + digits
	}
	frac := digits[1:]
	if frac == "" {
		frac = "0"
	}
	sci := digits[:1] + "." + frac + "e" + strconv.Itoa(exp)
	if len(sci) < len(dec) {
		return sign + sci
	}
	return sign + dec
}

// legacyJSON is a term as the JSON value Elixir would have encoded for it: atoms true, false
// and nil are the JSON values, any other atom is its name, binaries must be UTF-8, numbers
// are json.Number, maps become objects (atom and binary keys alike). Tuples, improper lists
// and other keys have no JSON form.
func legacyJSON(t any) (any, bool) {
	switch x := t.(type) {
	case int64:
		return json.Number(strconv.FormatInt(x, 10)), true
	case *big.Int:
		return json.Number(x.String()), true
	case float64:
		return json.Number(legacyFloatText(x)), true
	case legacyAtom:
		switch x {
		case "true":
			return true, true
		case "false":
			return false, true
		case "nil":
			return nil, true
		}
		return string(x), true
	case string:
		return x, utf8.ValidString(x)
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			v, ok := legacyJSON(e)
			if !ok {
				return nil, false
			}
			out[i] = v
		}
		return out, true
	case *legacyMap:
		out := make(map[string]any, len(x.keys))
		for i, k := range x.keys {
			var name string
			switch kk := k.(type) {
			case legacyAtom:
				name = string(kk)
			case string:
				if !utf8.ValidString(kk) {
					return nil, false
				}
				name = kk
			default:
				return nil, false
			}
			if _, dup := out[name]; dup {
				return nil, false
			}
			v, ok := legacyJSON(x.vals[i])
			if !ok {
				return nil, false
			}
			out[name] = v
		}
		return out, true
	}
	return nil, false
}

// ---- reading the Build's map ----

// legacyConv reads terms into typed values; the first thing that is not what a Build keeps
// marks it bad, and every later read gives zero values.
type legacyConv struct{ bad bool }

func (c *legacyConv) fail() { c.bad = true }

func legacyIsNil(t any) bool { a, ok := t.(legacyAtom); return ok && a == "nil" }

func (c *legacyConv) mp(t any) *legacyMap {
	m, ok := t.(*legacyMap)
	if !ok {
		c.fail()
		return &legacyMap{index: map[string]int{}}
	}
	return m
}

// field is the value under an atom key; absent reads as the atom nil, as `b[:key]` does.
func (c *legacyConv) field(m *legacyMap, name string) any {
	if v, ok := m.atom(name); ok {
		return v
	}
	return legacyAtom("nil")
}

func (c *legacyConv) has(m *legacyMap, name string) bool { _, ok := m.atom(name); return ok }

func (c *legacyConv) str(t any) string {
	s, ok := t.(string)
	if !ok {
		c.fail()
	}
	return s
}

func (c *legacyConv) optStr(t any) *string {
	if legacyIsNil(t) {
		return nil
	}
	s := c.str(t)
	return &s
}

// integer is an Elixir integer that fits int64.
func (c *legacyConv) integer(t any) int64 {
	n, ok := t.(int64)
	if !ok {
		c.fail() // not an integer, or beyond int64: no counter of a Build is that large
	}
	return n
}

func (c *legacyConv) count(t any) int {
	n := c.integer(t)
	if n < 0 || n > math.MaxInt32 {
		c.fail()
		return 0
	}
	return int(n)
}

func (c *legacyConv) list(t any) []any {
	l, ok := t.([]any)
	if !ok {
		c.fail()
	}
	return l
}

func (c *legacyConv) strList(t any) []string {
	var out []string
	for _, e := range c.list(t) {
		out = append(out, c.str(e))
	}
	return out
}

func (c *legacyConv) atomIs(t any, names ...string) string {
	a, ok := t.(legacyAtom)
	if ok {
		for _, n := range names {
			if string(a) == n {
				return n
			}
		}
	}
	c.fail()
	return ""
}

func (c *legacyConv) boolean(t any) bool {
	a, ok := t.(legacyAtom)
	if !ok || (a != "true" && a != "false") {
		c.fail()
	}
	return a == "true"
}

// json is the JSON value of a term.
func (c *legacyConv) json(t any) any {
	v, ok := legacyJSON(t)
	if !ok {
		c.fail()
	}
	return v
}

// items is a conversation: a list of maps (the JSON objects of the provider's items).
func (c *legacyConv) items(t any) []any {
	l := c.list(t)
	out := make([]any, 0, len(l))
	for _, e := range l {
		if _, ok := e.(*legacyMap); !ok {
			c.fail()
			continue
		}
		out = append(out, c.json(e))
	}
	return out
}

// object is a map term as a JSON object.
func (c *legacyConv) object(t any) map[string]any {
	if _, ok := t.(*legacyMap); !ok {
		c.fail()
		return nil
	}
	m, _ := c.json(t).(map[string]any)
	return m
}

// tokens is a usage map with the four counts a Build keeps, each a nonnegative integer or nil
// (a request that did not report it). A session's usage needs only to be a map, so a missing
// count reads as 0 when lenient.
func (c *legacyConv) tokens(t any, lenient bool) Tokens {
	m := c.mp(t)
	read := func(name string) *int {
		v, ok := m.atom(name)
		switch {
		case !ok && lenient:
			return count(0)
		case !ok:
			c.fail()
			return nil
		case legacyIsNil(v):
			return nil
		}
		return count(c.count(v))
	}
	return Tokens{Input: read("input"), Cached: read("cached"), Output: read("output"), Reasoning: read("reasoning")}
}

// legacyStructOf reports whether m is the struct of the named Elixir module.
func legacyStructOf(m *legacyMap, module string) bool {
	v, ok := m.atom("__struct__")
	return ok && v == legacyAtom("Elixir."+module)
}

// role is a model role map: model and effort strings, and a provider when it names one.
func (c *legacyConv) role(t any) project.Role {
	m := c.mp(t)
	r := project.Role{Model: c.str(c.field(m, "model")), Effort: c.str(c.field(m, "effort"))}
	if c.has(m, "provider") {
		r.Provider = c.str(c.field(m, "provider"))
	}
	return r
}

func (c *legacyConv) config(t any) *project.Config {
	m := c.mp(t)
	if !legacyStructOf(m, "Kogen.Config") {
		c.fail()
		return nil
	}
	cfg := &project.Config{
		Setup:   c.nonEmpty(c.strList(c.field(m, "setup"))),
		Fix:     c.nonEmpty(c.strList(c.field(m, "fix"))),
		Protect: c.nonEmpty(c.strList(c.field(m, "protect"))),
		Models:  map[string]project.Role{},
	}
	for _, e := range c.list(c.field(m, "checks")) {
		pair, ok := e.(legacyTuple)
		if !ok || len(pair) != 2 {
			c.fail()
			continue
		}
		cfg.Checks = append(cfg.Checks, project.Check{Name: c.str(pair[0]), Run: c.str(pair[1])})
	}
	run, steps := c.field(m, "acceptance_run"), c.field(m, "steps_dir")
	if !legacyIsNil(run) || !legacyIsNil(steps) {
		cfg.Acceptance = &project.Acceptance{}
		if !legacyIsNil(run) {
			cfg.Acceptance.Run = c.str(run)
		}
		if !legacyIsNil(steps) {
			cfg.Acceptance.StepsDir = c.str(steps)
		}
	}
	models := c.mp(c.field(m, "models"))
	for i, k := range models.keys {
		cfg.Models[c.str(k)] = c.role(models.vals[i])
	}
	cfg.ShapeWorkers = project.Workers{Roles: map[string]project.Role{}}
	workers := c.mp(c.field(m, "shape_workers"))
	for i, k := range workers.keys {
		if k == legacyAtom("enabled") {
			cfg.ShapeWorkers.Enabled = c.boolean(workers.vals[i])
		} else {
			cfg.ShapeWorkers.Roles[c.str(k)] = c.role(workers.vals[i])
		}
	}
	return cfg
}

func (c *legacyConv) nonEmpty(l []string) []string {
	if len(l) == 0 {
		return nil
	}
	return l
}

// pass is a recorded verification pass (`valid_pass?/1`), as the Go record of it.
func (c *legacyConv) pass(t any) *verify.Pass {
	m := c.mp(t)
	if c.bad {
		return nil
	}
	if c.field(m, "clean") != legacyAtom("true") {
		c.fail()
	}
	c.integer(c.field(m, "n"))
	c.boolean(c.field(m, "green"))
	c.str(c.field(m, "tree"))
	doc := map[string]any{}
	for _, k := range []string{"n", "clean", "green", "tree"} {
		doc[k] = c.json(c.field(m, k))
	}
	switch acc := c.field(m, "acceptance").(type) {
	case legacyAtom:
		if acc != "not_run" {
			c.fail()
		}
		doc["acceptance"] = "not_run"
	case *legacyMap:
		c.list(c.field(acc, "scenarios"))
		c.integer(c.field(acc, "passed"))
		c.integer(c.field(acc, "status"))
		c.list(c.field(acc, "problems"))
		doc["acceptance"] = c.json(acc)
	default:
		c.fail()
	}
	if !c.has(m, "model") {
		c.fail()
	}
	switch model := c.field(m, "model").(type) {
	case legacyAtom:
		doc["model"] = string(model)
	case legacyTuple:
		if len(model) != 2 {
			c.fail()
			break
		}
		doc["model"] = map[string]any{c.atomIs(model[0], "ok", "failed"): c.json(c.strListTerm(model[1]))}
	default:
		c.fail()
	}
	checks := c.list(c.field(m, "checks"))
	for _, e := range checks {
		check := c.mp(e)
		c.str(c.field(check, "name"))
		c.str(c.field(check, "command"))
		c.integer(c.field(check, "status"))
		c.str(c.field(check, "output"))
	}
	doc["checks"] = c.json(c.field(m, "checks"))
	c.strListTerm(c.field(m, "moved"))
	c.strListTerm(c.field(m, "failing"))
	doc["moved"], doc["failing"] = c.json(c.field(m, "moved")), c.json(c.field(m, "failing"))
	hasSetup, hasNotRun := c.has(m, "setup"), c.has(m, "not_run")
	if hasNotRun {
		c.strListTerm(c.field(m, "not_run"))
		doc["not_run"] = c.json(c.field(m, "not_run"))
	}
	if hasSetup {
		doc["setup"] = c.json(c.field(m, "setup"))
	}
	if hasNotRun && !hasSetup && c.field(m, "green") == legacyAtom("true") {
		c.fail() // complete_pass?/4 reads the setup of a pass that records its unrun items
	}
	if c.bad {
		return nil
	}
	b, err := json.Marshal(doc)
	var p verify.Pass
	if err != nil || json.Unmarshal(b, &p) != nil {
		c.fail()
		return nil
	}
	return &p
}

// strListTerm checks a list of binaries and returns it as the term.
func (c *legacyConv) strListTerm(t any) any {
	c.strList(t)
	return t
}

func (c *legacyConv) review(t any) *ReviewRecord {
	if legacyIsNil(t) {
		return nil
	}
	m := c.mp(t)
	r := &ReviewRecord{Verdict: c.atomIsString(c.field(m, "verdict"), "approve", "changes", "pending", "invalid"), N: c.count(c.field(m, "n"))}
	r.Findings = c.findings(c.field(m, "findings"))
	if c.has(m, "tree") && !legacyIsNil(c.field(m, "tree")) {
		r.Tree = c.str(c.field(m, "tree"))
	}
	return r
}

// atomIsString is a binary that is one of names (the verdicts are binaries, not atoms).
func (c *legacyConv) atomIsString(t any, names ...string) string {
	s, ok := t.(string)
	if ok {
		for _, n := range names {
			if s == n {
				return s
			}
		}
	}
	c.fail()
	return ""
}

func (c *legacyConv) findings(t any) []map[string]any {
	out := []map[string]any{}
	for _, e := range c.list(t) {
		if _, ok := e.(*legacyMap); !ok {
			c.fail()
			continue
		}
		out = append(out, c.object(e))
	}
	return out
}

func (c *legacyConv) cacheStates(t any) map[string]provider.CacheState {
	out := map[string]provider.CacheState{}
	m := c.mp(t)
	for i, k := range m.keys {
		s := c.mp(m.vals[i])
		st := provider.CacheState{ID: c.str(c.field(s, "id")), Unsupported: c.boolean(c.field(s, "unsupported"))}
		if r := c.field(s, "response"); !legacyIsNil(r) {
			st.Response = c.str(r)
			if st.Response == "" {
				c.fail() // a response is 1..256 bytes or nil
			}
		}
		if !st.Valid() {
			c.fail()
		}
		out[c.str(k)] = st
	}
	return out
}

func (c *legacyConv) workingContext(t any) map[string]*OwnerContext {
	out := map[string]*OwnerContext{}
	m := c.mp(t)
	for i, k := range m.keys {
		owner := c.str(k)
		if owner != "build" && owner != "review" {
			c.fail()
		}
		s := c.mp(m.vals[i])
		oc := &OwnerContext{Mandatory: c.items(c.field(s, "mandatory")), Observations: c.jsonList(c.field(s, "observations"))}
		if im, ok := s.atom("inline_material"); ok && !legacyIsNil(im) {
			oc.InlineMaterial = c.material(im)
		}
		if st, ok := s.atom("source_tree"); ok && !legacyIsNil(st) {
			tree := c.str(st)
			oc.SourceTree = &tree
		}
		oc.History = []HistoryRef{}
		for _, h := range c.list(c.field(s, "history")) {
			ref := c.mp(h)
			oc.History = append(oc.History, HistoryRef{Path: c.str(refGet(ref, "path")), SHA256: c.str(refGet(ref, "sha256"))})
		}
		out[owner] = oc
	}
	return out
}

// material is the review material a state keeps for its inline opening message.
func (c *legacyConv) material(t any) *materialSet {
	m := c.mp(t)
	set := &materialSet{
		Authority: c.str(c.field(m, "authority")), Source: c.str(c.field(m, "source")),
		Checks: c.str(c.field(m, "checks")), Files: []map[string]any{},
	}
	for _, e := range c.list(c.field(m, "files")) {
		if _, ok := e.(*legacyMap); !ok {
			c.fail()
			continue
		}
		set.Files = append(set.Files, c.object(e))
	}
	return set
}

// jsonList is a list term as a JSON array, empty when it is not one.
func (c *legacyConv) jsonList(t any) []any {
	c.list(t)
	l, _ := c.json(t).([]any)
	if l == nil {
		l = []any{}
	}
	return l
}

// refGet is a binary-keyed value, nil when absent.
func refGet(m *legacyMap, name string) any {
	if v, ok := m.get(name); ok {
		return v
	}
	return legacyAtom("nil")
}

func (c *legacyConv) source(t any) *project.SourceRef {
	if legacyIsNil(t) {
		return nil
	}
	m := c.mp(t)
	ref := &project.SourceRef{
		Path: c.str(refGet(m, "path")), SHA256: c.str(refGet(m, "sha256")), ContractSHA256: c.str(refGet(m, "contract_sha256")),
	}
	return ref
}

// ---- staged plans ----

func (c *legacyConv) stageDef(t any) stageDef {
	m := c.mp(t)
	d := stageDef{ID: c.str(refGet(m, "id")), Title: c.str(refGet(m, "title")), Goal: c.str(refGet(m, "goal"))}
	d.Checks = c.strList(refGet(m, "checks"))
	return d
}

// progress is the stage progress map (binary keys), or nil.
func (c *legacyConv) progress(t any) *StageProgress {
	if legacyIsNil(t) {
		return nil
	}
	m := c.mp(t)
	p := &StageProgress{Total: c.count(refGet(m, "total")), Completed: c.strList(refGet(m, "completed")), Phase: c.str(refGet(m, "phase"))}
	if p.Completed == nil {
		p.Completed = []string{}
	}
	if a := refGet(m, "active"); !legacyIsNil(a) {
		id := c.str(a)
		p.Active = &id
	}
	return p
}

func (c *legacyConv) evidence(t any) StageEvidence {
	m := c.mp(t)
	e := StageEvidence{StageID: c.str(c.field(m, "stage_id")), Index: c.count(c.field(m, "stage_index")), Contract: c.str(c.field(m, "contract"))}
	if pass := c.pass(m); pass != nil {
		e.Pass = *pass
	}
	cust := c.mp(c.field(m, "custody"))
	e.Custody = &StageCustody{Path: c.str(refGet(cust, "path")), SHA256: c.str(refGet(cust, "sha256"))}
	return e
}

// stages reads the optional staged-plan fields of a Build (absent in a Build that had none).
func (c *legacyConv) stages(b *legacyMap) (plan []stageDef, progress *StageProgress, evidence []StageEvidence) {
	if v, ok := b.atom("stage_plan"); ok && !legacyIsNil(v) {
		for _, e := range c.list(v) {
			plan = append(plan, c.stageDef(e))
		}
	}
	if v, ok := b.atom("stage_progress"); ok {
		progress = c.progress(v)
	}
	if v, ok := b.atom("stage_evidence"); ok && !legacyIsNil(v) {
		for _, e := range c.list(v) {
			evidence = append(evidence, c.evidence(e))
		}
	}
	return plan, progress, evidence
}

// ---- the continuation ----

// reviewState is the reviewer's saved session (review.go) for a review stage of a Build read
// from a version 3 checkpoint: Elixir's `Kogen.Review` kept the same things. In the stage
// review that is the session (role, the conversation to send next, usage and attempts so
// far); in review_verify and review_retry_verify the continuation's own conversation, usage
// and verdict (the conversation after it) and the candidate tree it judged, with the
// attempts of the session.
func (c *legacyConv) reviewState(m *legacyMap, stage string) reviewSession {
	session := c.mp(c.field(m, "session"))
	rs := reviewSession{
		Tools:    c.jsonList(c.field(session, "tools")),
		Role:     c.role(c.field(session, "role")),
		Input:    c.items(c.field(session, "input")),
		Usage:    c.tokens(c.field(session, "usage"), true),
		Attempts: []reviewAttempt{},
	}
	for _, a := range c.list(c.field(session, "attempts")) {
		am := c.mp(a)
		rs.Attempts = append(rs.Attempts, reviewAttempt{
			Pass: c.count(c.field(am, "pass")), Tree: c.str(c.field(am, "tree")),
			Verdict: c.str(c.field(am, "verdict")), Findings: c.findings(c.field(am, "findings")),
		})
	}
	if stage != StageReview {
		verdict := c.mp(c.field(m, "verdict"))
		if v := c.review(legacyWithN(verdict)); v != nil {
			rs.Verdict = &reviewVerdict{Verdict: v.Verdict, Findings: v.Findings}
		}
		rs.Usage = c.tokens(c.field(m, "usage"), true)
		rs.Input = c.items(c.field(m, "input"))
		rs.Tree = c.str(c.field(m, "tree"))
	}
	return rs
}

// legacyWithN is the verdict map with the review number the validator gives it.
func legacyWithN(m *legacyMap) *legacyMap {
	out := &legacyMap{index: map[string]int{}}
	for i, k := range m.keys {
		out.index[legacyKey(k)] = len(out.keys)
		out.keys = append(out.keys, k)
		out.vals = append(out.vals, m.vals[i])
	}
	if _, ok := out.atom("n"); !ok {
		out.index[legacyKey(legacyAtom("n"))] = len(out.keys)
		out.keys = append(out.keys, legacyAtom("n"))
		out.vals = append(out.vals, int64(0))
	}
	return out
}

func (c *legacyConv) continuation(t any) Continuation {
	m := c.mp(t)
	stage := c.atomIs(c.field(m, "stage"), "startup", "builder", "builder_verify", "tool", "commit", "landed",
		"review", "review_verify", "review_retry_verify")
	cont := Continuation{Stage: stage}
	switch stage {
	case StageBuilder:
		cont.Input = c.items(c.field(m, "input"))
	case StageBuilderVerify:
		cont.Input = c.items(c.field(m, "input"))
		if !c.has(m, "finish") {
			c.fail()
			break
		}
		if f := c.field(m, "finish"); !legacyIsNil(f) {
			cont.Finish = c.object(f)
		}
	case StageReview, StageReviewVerify, StageReviewRetry:
		if !c.has(m, "pass") || !c.has(m, "session") {
			c.fail()
			break
		}
		cont.Pass = c.pass(c.field(m, "pass"))
		if rs := c.reviewState(m, stage); !c.bad {
			raw, err := rs.encode()
			if err != nil {
				c.fail()
			}
			cont.Review = raw
		}
	case StageLanded:
		cont.Commit = c.str(c.field(m, "commit"))
	case StageTool:
		// Nothing of a tool boundary is used: a resume refuses it before anything else.
		switch o := c.field(m, "owner").(type) {
		case legacyAtom:
			cont.Owner = map[legacyAtom]string{"builder": "build", "reviewer": "review"}[o]
		case string:
			// The boundary a model request saved names its role as text, not as a stage owner.
			cont.Owner, cont.Request = o, true
		}
	case StageCommit:
		if tree, ok := c.field(m, "tree").(string); ok {
			cont.Tree = tree
		}
	}
	return cont
}

// ---- the Build ----

// legacyState maps the Build map of a version 3 checkpoint onto a State, with the checks of
// `Kogen.Run.valid_state?/2` that need the checkpoint's envelope (doc is its JSON object).
func legacyState(t any, doc map[string]any) (*State, bool) {
	c := &legacyConv{}
	b := c.mp(t)
	if c.bad {
		return nil, false
	}
	for _, k := range []string{"model", "phase", "t0", "last_pass", "last_review", "blocker", "parent", "root_run", "working_context", "source_provenance"} {
		if !c.has(b, k) {
			return nil, false
		}
	}
	st := &State{
		Phase: c.atomIs(c.field(b, "phase"), "startup", "building"),
		T0:    c.integer(c.field(b, "t0")),
	}
	st.Root, st.Slug, st.Start = c.str(c.field(b, "root")), c.str(c.field(b, "slug")), c.str(c.field(b, "start"))
	st.GitIndex, st.StartTree, st.ApprovalBytes = c.str(c.field(b, "git_index")), c.str(c.field(b, "start_tree")), c.str(c.field(b, "approval_bytes"))

	run := c.mp(c.field(b, "run"))
	if !legacyStructOf(run, "Kogen.Run") {
		c.fail()
	}
	st.Run = &Run{ID: c.str(c.field(run, "id")), Dir: c.str(c.field(run, "dir")), LogPath: c.str(c.field(run, "log"))}
	st.Config = c.config(c.field(b, "config"))

	intent := c.mp(c.field(b, "intent"))
	if !legacyStructOf(intent, "Kogen.Intent") {
		c.fail()
	}
	if c.str(c.field(intent, "root")) != st.Root || c.str(c.field(intent, "slug")) != st.Slug {
		c.fail()
	}
	title := c.str(c.field(intent, "title"))
	st.IntentText = c.str(c.field(intent, "text"))
	if c.bad {
		return nil, false
	}
	if !legacyModelMatches(c.field(b, "model"), st, title) {
		return nil, false
	}

	st.LastPass = nil
	if lp := c.field(b, "last_pass"); !legacyIsNil(lp) {
		st.LastPass = c.pass(lp)
	}
	st.WorkingContext = c.workingContext(c.field(b, "working_context"))
	st.SourceProvenance = c.source(c.field(b, "source_provenance"))
	st.LastReview = c.review(c.field(b, "last_review"))
	st.PromptCache = c.cacheStates(legacyDefaultMap(b, "prompt_cache_states"))

	digests := c.mp(c.field(b, "baseline_digests"))
	st.Baseline = c.strList(c.field(b, "baseline"))
	if st.Baseline == nil {
		st.Baseline = []string{}
	}
	st.BaselineDigests = map[string]string{}
	for i, k := range digests.keys {
		path := c.str(k)
		switch d := digests.vals[i].(type) {
		case string:
			st.BaselineDigests[path] = hex.EncodeToString([]byte(d))
		case legacyAtom:
			if d != "missing" {
				c.fail()
			}
			st.BaselineDigests[path] = "missing"
		default:
			c.fail()
		}
	}
	st.Excluded = c.strList(c.field(b, "excluded"))
	st.Round, st.Pass, st.Review = c.count(c.field(b, "round")), c.count(c.field(b, "pass")), c.count(c.field(b, "review"))
	st.Repairs, st.UnknownRequests = c.count(c.field(b, "repairs")), c.count(c.field(b, "unknown_requests"))
	st.ModelActiveMS = c.integer(c.field(b, "model_active_ms"))
	if st.ModelActiveMS < 0 {
		c.fail()
	}
	st.Usage, st.AttemptUsage = c.tokens(c.field(b, "usage"), false), c.tokens(c.field(b, "attempt_usage"), false)
	st.Continuation = c.continuation(c.field(b, "continuation"))

	if bl := c.field(b, "blocker"); !legacyIsNil(bl) {
		st.Blocker = c.object(bl)
	}
	st.StagePlan, st.StageProgress, st.StageEvidence = c.stages(b)
	st.Parent, st.RootRun = c.optStr(c.field(b, "parent")), c.optStr(c.field(b, "root_run"))
	if c.bad {
		return nil, false
	}
	for _, f := range []string{"identity", "candidate", "index", "approval"} {
		if _, ok := doc[f].(string); !ok {
			return nil, false
		}
	}
	if doc["approval"] != st.ApprovalBytes {
		return nil, false
	}
	return st, true
}

// legacyDefaultMap is the value under an atom key, an empty map when the key is absent.
func legacyDefaultMap(m *legacyMap, name string) any {
	if v, ok := m.atom(name); ok {
		return v
	}
	return &legacyMap{index: map[string]int{}}
}

// legacyModelMatches is `b.model == Kogen.Intent.model(b.intent)` with a model: the saved
// model, the title and the model line of the Intent the saved text gives.
func legacyModelMatches(saved any, st *State, title string) bool {
	intent, err := st.intent()
	if err != nil || intent.Title != title || intent.Model == nil {
		return false
	}
	m := intent.Model
	if m.None {
		return saved == legacyAtom("none")
	}
	sm, ok := saved.(*legacyMap)
	if !ok || len(sm.keys) != 5 {
		return false
	}
	get := func(name string) (string, bool) { v, ok := sm.atom(name); s, ok2 := v.(string); return s, ok && ok2 }
	path, ok1 := get("path")
	seed, ok2 := get("seed")
	samples, ok3 := get("samples")
	steps, ok4 := get("steps")
	invs, ok5 := sm.atom("invariants")
	list, ok6 := invs.([]any)
	if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) || len(list) != len(m.Invariants) {
		return false
	}
	for i, e := range list {
		if s, ok := e.(string); !ok || s != m.Invariants[i] {
			return false
		}
	}
	return path == m.Path && seed == m.Seed && samples == m.Samples && steps == m.Steps
}

// legacyDecode reads a version 3 checkpoint as `Kogen.Run.decode_checkpoint/1` does and
// returns it as the state a resume continues from. Its error texts are the reasons that
// function gives: "malformed required checkpoint fields" and "damaged checkpoint state"
// (the version number is refused by the caller). Atoms are read as text: the Elixir reader
// also refuses atoms its VM has not seen, which says nothing about the checkpoint's own
// validity.
func legacyDecode(raw []byte) (*Loaded, error) {
	v, err := decodeJSONNumbers(raw)
	m, ok := v.(map[string]any)
	if err != nil || !ok {
		return nil, errors.New(legacyMalformed)
	}
	if version, _ := m["version"].(json.Number); version != "3" {
		return nil, errors.New(legacyMalformed)
	}
	text, ok := m["state"].(string)
	if !ok || len(text) > legacyMaxState || strings.ContainsAny(text, "\r\n") {
		return nil, errors.New(legacyMalformed)
	}
	encoded, err := decodeBase64(text)
	if err != nil {
		return nil, errors.New(legacyMalformed)
	}
	term, err := legacyDecodeTerm(encoded)
	if err != nil {
		return nil, errors.New(legacyDamaged)
	}
	st, ok := legacyState(term, m)
	if !ok {
		return nil, errors.New(legacyMalformed)
	}
	doc := Checkpoint{Version: 3}
	if v, ok := m["stage_progress"]; ok && v != nil {
		raw, _ := json.Marshal(v)
		var p StageProgress
		if err := json.Unmarshal(raw, &p); err != nil || p.Completed == nil {
			return nil, errors.New(legacyMalformed)
		}
		doc.StageProgress = &p
	}
	if v, ok := m["recovery_raw"]; ok && v != nil {
		raw, _ := json.Marshal(v)
		doc.RecoveryRaw = map[string]*RawMeta{}
		if err := json.Unmarshal(raw, &doc.RecoveryRaw); err != nil {
			doc.RecoveryRaw = map[string]*RawMeta{"": nil} // never equal to a candidate's identity
		}
	}
	doc.Identity, _ = m["identity"].(string)
	doc.Candidate, _ = m["candidate"].(string)
	doc.Index, _ = m["index"].(string)
	doc.Approval, _ = m["approval"].(string)
	return &Loaded{Doc: doc, State: st}, nil
}
