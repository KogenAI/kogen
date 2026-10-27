package build

import (
	"bytes"
	"compress/zlib"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"math"
	"math/big"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"

	"kogen/project"
)

// The decoder of the Elixir Kogen's version 3 checkpoints (legacy.go), tested against real
// checkpoints written by the Elixir Kogen: testdata/legacy/gen.exs builds them with the real
// modules (Kogen.Build.save/2) and the tests resume them.

// ---- test helpers: terms ----

func lmap(kv ...any) *legacyMap {
	m := &legacyMap{index: map[string]int{}}
	for i := 0; i < len(kv); i += 2 {
		legacyPut(m, kv[i], kv[i+1])
	}
	return m
}

func latom(s string) legacyAtom { return legacyAtom(s) }

// legacyPut sets key in m, keeping the order of the keys it has.
func legacyPut(m *legacyMap, key, val any) {
	id := legacyKey(key)
	if i, ok := m.index[id]; ok {
		m.vals[i] = val
		return
	}
	m.index[id] = len(m.keys)
	m.keys = append(m.keys, key)
	m.vals = append(m.vals, val)
}

// legacyDelete removes key from m.
func legacyDelete(m *legacyMap, key any) {
	id := legacyKey(key)
	i, ok := m.index[id]
	if !ok {
		return
	}
	m.keys = slices.Delete(m.keys, i, i+1)
	m.vals = slices.Delete(m.vals, i, i+1)
	m.index = map[string]int{}
	for j, k := range m.keys {
		m.index[legacyKey(k)] = j
	}
}

// legacyDig follows keys (atoms given as legacyAtom) through nested maps.
func legacyDig(t testing.TB, root any, keys ...any) any {
	t.Helper()
	cur := root
	for _, k := range keys {
		m, ok := cur.(*legacyMap)
		if !ok {
			t.Fatalf("not a map at %v: %T", k, cur)
		}
		v, ok := m.get(k)
		if !ok {
			t.Fatalf("no key %v", k)
		}
		cur = v
	}
	return cur
}

func legacyDigMap(t testing.TB, root any, keys ...any) *legacyMap {
	t.Helper()
	m, ok := legacyDig(t, root, keys...).(*legacyMap)
	if !ok {
		t.Fatalf("not a map at %v", keys)
	}
	return m
}

// legacyReplace is the term with from replaced by to in every binary.
func legacyReplace(t any, from, to string) any {
	switch x := t.(type) {
	case string:
		return strings.ReplaceAll(x, from, to)
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = legacyReplace(e, from, to)
		}
		return out
	case legacyTuple:
		out := make(legacyTuple, len(x))
		for i, e := range x {
			out[i] = legacyReplace(e, from, to)
		}
		return out
	case *legacyImproper:
		return &legacyImproper{Items: legacyReplace(x.Items, from, to).([]any), Tail: legacyReplace(x.Tail, from, to)}
	case *legacyMap:
		out := &legacyMap{index: map[string]int{}}
		for i, k := range x.keys {
			legacyPut(out, legacyReplace(k, from, to), legacyReplace(x.vals[i], from, to))
		}
		return out
	}
	return t
}

// legacyEncode is the external term format of a term the way the Erlang runtime writes it
// (the reader's inverse, to move fixtures and to check the reader against real bytes).
func legacyEncode(t any) []byte {
	var b bytes.Buffer
	b.WriteByte(131)
	legacyEnc(&b, t)
	return b.Bytes()
}

func legacyEnc(b *bytes.Buffer, t any) {
	u32 := func(n int) { b.Write(binary.BigEndian.AppendUint32(nil, uint32(n))) }
	switch x := t.(type) {
	case int64:
		switch {
		case x >= 0 && x <= 255:
			b.Write([]byte{97, byte(x)})
		case x >= math.MinInt32 && x <= math.MaxInt32:
			b.WriteByte(98)
			u32(int(int32(x)))
		default:
			legacyEnc(b, big.NewInt(x))
		}
	case *big.Int:
		mag := new(big.Int).Abs(x).Bytes()
		slices.Reverse(mag)
		sign := byte(0)
		if x.Sign() < 0 {
			sign = 1
		}
		if len(mag) <= 255 {
			b.Write([]byte{110, byte(len(mag)), sign})
		} else {
			b.WriteByte(111)
			u32(len(mag))
			b.WriteByte(sign)
		}
		b.Write(mag)
	case float64:
		b.WriteByte(70)
		b.Write(binary.BigEndian.AppendUint64(nil, math.Float64bits(x)))
	case legacyAtom:
		if len(x) <= 255 {
			b.Write([]byte{119, byte(len(x))})
		} else {
			b.WriteByte(118)
			b.Write(binary.BigEndian.AppendUint16(nil, uint16(len(x))))
		}
		b.WriteString(string(x))
	case string:
		b.WriteByte(109)
		u32(len(x))
		b.WriteString(x)
	case []any:
		if len(x) == 0 {
			b.WriteByte(106)
			return
		}
		bytesOnly := len(x) <= 65535
		for _, e := range x {
			if n, ok := e.(int64); !ok || n < 0 || n > 255 {
				bytesOnly = false
			}
		}
		if bytesOnly {
			b.WriteByte(107)
			b.Write(binary.BigEndian.AppendUint16(nil, uint16(len(x))))
			for _, e := range x {
				b.WriteByte(byte(e.(int64)))
			}
			return
		}
		b.WriteByte(108)
		u32(len(x))
		for _, e := range x {
			legacyEnc(b, e)
		}
		b.WriteByte(106)
	case *legacyImproper:
		b.WriteByte(108)
		u32(len(x.Items))
		for _, e := range x.Items {
			legacyEnc(b, e)
		}
		legacyEnc(b, x.Tail)
	case legacyTuple:
		if len(x) <= 255 {
			b.Write([]byte{104, byte(len(x))})
		} else {
			b.WriteByte(105)
			u32(len(x))
		}
		for _, e := range x {
			legacyEnc(b, e)
		}
	case *legacyMap:
		b.WriteByte(116)
		u32(len(x.keys))
		for i, k := range x.keys {
			legacyEnc(b, k)
			legacyEnc(b, x.vals[i])
		}
	default:
		panic("legacyEnc: unsupported term")
	}
}

func legacyUnhex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// ---- the external term format ----

// legacyGolden are terms written by the Erlang runtime (OTP 29): the bytes, and the term the
// reader must give.
var legacyGolden = []struct {
	name, hex string
	want      any
}{
	{"small integer", "8361c8", int64(200)},
	{"zero", "836100", int64(0)},
	{"integer", "836200011170", int64(70000)},
	{"negative integer", "8362fffeee90", int64(-70000)},
	{"largest int32", "83627fffffff", int64(math.MaxInt32)},
	{"beyond int32", "836e05000000000001", int64(4294967296)},
	{"smallest int64", "836e08010000000000000080", int64(math.MinInt64)},
	{"big", "836e0d00d20a3f4eeee073c3f60fe98e01", func() any { n, _ := new(big.Int).SetString("123456789012345678901234567890", 10); return n }()},
	{"negative big", "836e0d01d20a3f4eeee073c3f60fe98e01", func() any { n, _ := new(big.Int).SetString("-123456789012345678901234567890", 10); return n }()},
	{"float", "83463ff8000000000000", 1.5},
	{"negative float", "8346bfb999999999999a", -0.1},
	{"atom nil", "8377036e696c", latom("nil")},
	{"atom true", "83770474727565", latom("true")},
	{"utf-8 atom", "83770968c3a96c6c6fe29c93", latom("héllo✓")},
	{"atom", "8377057068617365", latom("phase")},
	{"binary", "836d0000000a6e61c3af766520e29c93", "naïve ✓"},
	{"empty binary", "836d00000000", ""},
	{"string of bytes", "836b0003616263", []any{int64(97), int64(98), int64(99)}},
	{"empty list", "836a", []any{}},
	{"list", "836c0000000461016d0000000374776f770574687265654640120000000000006a", []any{int64(1), "two", latom("three"), 4.5}},
	{"nested", "836c000000026c0000000261016b0001026a74000000017701616b0001036a",
		[]any{[]any{int64(1), []any{int64(2)}}, lmap(latom("a"), []any{int64(3)})}},
	{"improper list", "836c00000002610161026103", &legacyImproper{Items: []any{int64(1), int64(2)}, Tail: int64(3)}},
	{"improper list of binaries", "836c000000016d00000001616d0000000162", &legacyImproper{Items: []any{"a"}, Tail: "b"}},
	{"tuple", "83680377026f6b61016d0000000178", legacyTuple{latom("ok"), int64(1), "x"}},
	{"empty tuple", "836800", legacyTuple{}},
	{"map", "83740000000361036801610477016161016d00000001626b000102",
		lmap(int64(3), legacyTuple{int64(4)}, latom("a"), int64(1), "b", []any{int64(2)})},
	{"empty map", "837400000000", lmap()},
}

func TestLegacyReaderReadsWhatTheErlangRuntimeWrites(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/run.ex decode_checkpoint/1 (binary_to_term of the saved Build map)
	rows := map[string]string{}
	var raw map[string]string
	if err := json.Unmarshal([]byte(legacyGoldenRows), &raw); err != nil {
		t.Fatal(err)
	}
	for k, v := range raw {
		rows[k] = v
	}
	for _, g := range legacyGolden {
		t.Run(g.name, func(t *testing.T) {
			data := legacyUnhex(t, g.hex)
			got, err := legacyDecodeTerm(data)
			if err != nil {
				t.Fatal(err)
			}
			if legacyKey(got) != legacyKey(g.want) {
				t.Fatalf("got %#v, want %#v", got, g.want)
			}
			if !bytes.Equal(legacyEncode(got), data) {
				t.Fatalf("the writer does not give back %x", data)
			}
		})
	}
	t.Run("a struct", func(t *testing.T) {
		got, err := legacyDecodeTerm(legacyUnhex(t, rows["struct"]))
		if err != nil {
			t.Fatal(err)
		}
		m := got.(*legacyMap)
		if !legacyStructOf(m, "Kogen.Run") {
			t.Fatal("not a Kogen.Run")
		}
		for k, v := range map[string]string{"id": "ab", "dir": "/d", "log": "/d/log.jsonl"} {
			if got, _ := m.atom(k); got != v {
				t.Fatalf("%s = %v", k, got)
			}
		}
	})
	t.Run("a map of 40 entries", func(t *testing.T) {
		data := legacyUnhex(t, rows["big map"])
		got, err := legacyDecodeTerm(data)
		if err != nil {
			t.Fatal(err)
		}
		m := got.(*legacyMap)
		if len(m.keys) != 40 {
			t.Fatalf("%d keys", len(m.keys))
		}
		if v, _ := m.get("k17"); v != int64(17) {
			t.Fatalf("k17 = %v", v)
		}
		if !bytes.Equal(legacyEncode(got), data) {
			t.Fatal("the writer does not give back the bytes")
		}
	})
	t.Run("a tuple of 300", func(t *testing.T) {
		data := legacyUnhex(t, rows["big tuple"])
		got, err := legacyDecodeTerm(data)
		if err != nil || len(got.(legacyTuple)) != 300 || !bytes.Equal(legacyEncode(got), data) {
			t.Fatalf("%v", err)
		}
	})
	t.Run("a list of 300 integers", func(t *testing.T) {
		data := legacyUnhex(t, rows["long charlist"])
		got, err := legacyDecodeTerm(data)
		if err != nil || len(got.([]any)) != 300 || got.([]any)[299] != int64(300) || !bytes.Equal(legacyEncode(got), data) {
			t.Fatalf("%v", err)
		}
	})
	t.Run("compressed terms", func(t *testing.T) {
		got, err := legacyDecodeTerm(legacyUnhex(t, rows["compressed"]))
		if err != nil || got != strings.Repeat("abc", 1000) {
			t.Fatalf("%v", err)
		}
		got, err = legacyDecodeTerm(legacyUnhex(t, rows["compressed map"]))
		if err != nil {
			t.Fatal(err)
		}
		if v, _ := got.(*legacyMap).atom("b"); v != int64(2) {
			t.Fatalf("b = %v", v)
		}
	})
	t.Run("Latin-1 atoms", func(t *testing.T) {
		got, err := legacyDecodeTerm([]byte{131, 100, 0, 2, 0xe9, 0x41}) // ATOM_EXT "éA"
		if err != nil || got != latom("éA") {
			t.Fatalf("%v %v", got, err)
		}
		got, err = legacyDecodeTerm([]byte{131, 115, 2, 0xe9, 0x41}) // SMALL_ATOM_EXT
		if err != nil || got != latom("éA") {
			t.Fatalf("%v %v", got, err)
		}
	})
	t.Run("the old float text", func(t *testing.T) {
		text := append([]byte("1.25000000000000000000e+00"), 0, 0, 0, 0, 0)
		got, err := legacyDecodeTerm(append([]byte{131, 99}, text...))
		if err != nil || got != 1.25 {
			t.Fatalf("%v %v", got, err)
		}
	})
	t.Run("bytes after the term are ignored, as binary_to_term ignores them", func(t *testing.T) {
		got, err := legacyDecodeTerm([]byte{131, 97, 1, 0})
		if err != nil || got != int64(1) {
			t.Fatalf("%v %v", got, err)
		}
	})
}

func TestLegacyReaderRefusesEverythingElse(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/run.ex decode_checkpoint/1 (binary_to_term with :safe refuses what it cannot trust)
	var rows map[string]string
	if err := json.Unmarshal([]byte(legacyGoldenRows), &rows); err != nil {
		t.Fatal(err)
	}
	deep := func(n int) []byte {
		b := []byte{131}
		for range n {
			b = append(b, 108, 0, 0, 0, 1)
		}
		b = append(b, 106)
		for range n {
			b = append(b, 106)
		}
		return b
	}
	var bomb bytes.Buffer
	zw := zlib.NewWriter(&bomb)
	zw.Write(make([]byte, 4<<20))
	zw.Close()
	compressed := func(declared uint32, stream []byte) []byte {
		return append(append([]byte{131, 80}, binary.BigEndian.AppendUint32(nil, declared)...), stream...)
	}
	cases := map[string][]byte{
		"empty":                          {},
		"no version":                     {97, 1},
		"wrong version":                  {130, 97, 1},
		"version only":                   {131},
		"unknown tag":                    {131, 1},
		"a process id":                   legacyUnhex(t, rows["pid"]),
		"a reference":                    legacyUnhex(t, rows["ref"]),
		"a fun":                          legacyUnhex(t, rows["fun"]),
		"an external fun":                legacyUnhex(t, rows["export fun"]),
		"a bit string":                   legacyUnhex(t, rows["bitstring"]),
		"a port":                         legacyUnhex(t, rows["port"]),
		"an atom-cache reference":        {131, 82, 1},
		"truncated integer":              {131, 98, 0, 1},
		"truncated binary":               {131, 109, 0, 0, 0, 5, 'a', 'b'},
		"binary longer than input":       {131, 109, 0xff, 0xff, 0xff, 0xff},
		"list longer than input":         {131, 108, 0xff, 0xff, 0xff, 0xff, 97, 1},
		"map larger than input":          {131, 116, 0x7f, 0xff, 0xff, 0xff, 97, 1},
		"tuple larger than input":        {131, 105, 0x10, 0, 0, 0, 97, 1},
		"big larger than input":          {131, 111, 0x10, 0, 0, 0, 0, 1},
		"list without a tail":            {131, 108, 0, 0, 0, 1, 97, 1},
		"duplicate map keys":             {131, 116, 0, 0, 0, 2, 97, 1, 97, 1, 97, 1, 97, 2},
		"a list as a map key":            {131, 116, 0, 0, 0, 1, 106, 97, 1},
		"a sign that is not a sign":      {131, 110, 1, 2, 5},
		"a UTF-8 atom that is not UTF-8": {131, 119, 1, 0xff},
		"a Latin-1 atom of 256":          append([]byte{131, 100, 1, 0}, bytes.Repeat([]byte{'a'}, 256)...),
		"nesting beyond the bound":       deep(legacyMaxDepth + 5),
		"a float that is not":            append([]byte{131, 99}, bytes.Repeat([]byte("x"), 31)...),
		"a compressed term that lies about its size": compressed(5, bomb.Bytes()),
		"a compressed term too large":                compressed(legacyMaxTerm+1, bomb.Bytes()),
		"a compressed term without a stream":         compressed(10, []byte{1, 2, 3}),
		"NaN":                                        append([]byte{131, 70}, binary.BigEndian.AppendUint64(nil, math.Float64bits(math.NaN()))...),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if got, err := legacyDecodeTerm(data); err == nil {
				t.Fatalf("read %#v", got)
			}
		})
	}
	if got, err := legacyDecodeTerm(deep(100)); err != nil {
		t.Fatalf("nesting of 100: %v (%v)", err, got != nil)
	}
	// The input is never trusted for sizes: a hostile document allocates what it can fill.
	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	for range 200 {
		legacyDecodeTerm([]byte{131, 108, 0x07, 0xff, 0xff, 0xff, 97, 1})
		legacyDecodeTerm([]byte{131, 116, 0x03, 0xff, 0xff, 0xff, 97, 1})
	}
	runtime.ReadMemStats(&after)
	if grown := after.TotalAlloc - before.TotalAlloc; grown > 8<<20 {
		t.Fatalf("hostile counts allocated %d bytes", grown)
	}
}

func TestLegacyFloatsAreWrittenLikeElixirs(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/run.ex (conversation items are JSON values; Elixir's JSON.encode writes floats this way)
	for f, want := range map[float64]string{
		1.0: "1.0", 0.1: "0.1", 1.0e21: "1.0e21", 1.5e-7: "1.5e-7", 100000.0: "1.0e5", 123456789.123: "123456789.123",
		1.0e16: "1.0e16", 1.0e15: "1.0e15", 5.0e-324: "5.0e-324", 1.7976931348623157e308: "1.7976931348623157e308",
		math.Copysign(0, -1): "-0.0", 0.0001: "0.0001", 0.00001: "1.0e-5", 12345678901234567890.0: "1.2345678901234567e19",
		100.0: "100.0", 1000.0: "1.0e3", 12345.678: "12345.678", 0.5: "0.5", 0.0025: "0.0025", 123.0: "123.0",
		99999.0: "99999.0", 1234567.0: "1234567.0", 0.001: "0.001", 3.14159: "3.14159", 4.5e15: "4.5e15",
		123456789012345.0: "123456789012345.0", 0.00012: "1.2e-4", 7.0e-7: "7.0e-7", 0: "0.0",
	} {
		if got := legacyFloatText(f); got != want {
			t.Errorf("%v: %s, want %s", f, got, want)
		}
	}
}

func TestLegacyTermsAreJSONValues(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/run.ex valid_input?/1 (the saved conversations are the provider's JSON)
	m := lmap("role", "user", "n", int64(3), "f", 2.5, "ok", latom("true"), "none", latom("nil"), "kind", latom("builder"),
		"list", []any{int64(1), "é"}, "deep", lmap(latom("a"), int64(-4)))
	v, ok := legacyJSON(m)
	if !ok {
		t.Fatal("no JSON value")
	}
	b, _ := json.Marshal(v)
	want := `{"deep":{"a":-4},"f":2.5,"kind":"builder","list":[1,"é"],"n":3,"none":null,"ok":true,"role":"user"}`
	if string(b) != want {
		t.Fatalf("%s", b)
	}
	for name, bad := range map[string]any{
		"tuple": legacyTuple{int64(1)}, "improper": &legacyImproper{Items: []any{int64(1)}, Tail: int64(2)},
		"binary that is not UTF-8": "\xff", "integer key": lmap(int64(1), int64(2)),
		"atom and binary key of the same name": lmap(latom("a"), int64(1), "a", int64(2)),
	} {
		if _, ok := legacyJSON(bad); ok {
			t.Errorf("%s has a JSON value", name)
		}
	}
}

// ---- the fixtures ----

const legacyDir = "testdata/legacy"

type legacyManifest struct {
	Root      string                `json:"root"`
	Slug      string                `json:"slug"`
	Start     string                `json:"start"`
	StartTree string                `json:"start_tree"`
	Tracked   []string              `json:"tracked"`
	AuthorEnv map[string]string     `json:"author_env"`
	Cases     map[string]legacyCase `json:"cases"`
}

type legacyCase struct {
	ID         string            `json:"id"`
	Checkpoint string            `json:"checkpoint"`
	Edits      map[string]string `json:"edits"`
	PassTree   string            `json:"pass_tree"`
	Commit     string            `json:"commit"`
	ModelLine  string            `json:"model_line"`
}

func legacyLoadManifest(t testing.TB) legacyManifest {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(legacyDir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m legacyManifest
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

// legacyDoc is a fixture's checkpoint file as a JSON object (a case name, or a variant file).
func legacyDoc(t testing.TB, name string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(legacyDir, name+".checkpoint.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

func legacyTerm(t testing.TB, doc map[string]any) *legacyMap {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(doc["state"].(string))
	if err != nil {
		t.Fatal(err)
	}
	term, err := legacyDecodeTerm(raw)
	if err != nil {
		t.Fatal(err)
	}
	return term.(*legacyMap)
}

func legacyJSONBytes(t testing.TB, doc map[string]any) []byte {
	t.Helper()
	b, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return append(b, '\n')
}

// legacyChanged is a fixture's checkpoint file with its state (and envelope) changed.
func legacyChanged(t testing.TB, name string, state func(m *legacyMap), envelope func(doc map[string]any)) []byte {
	t.Helper()
	doc := legacyDoc(t, name)
	if state != nil {
		m := legacyTerm(t, doc)
		state(m)
		doc["state"] = base64.StdEncoding.EncodeToString(legacyEncode(m))
	}
	if envelope != nil {
		envelope(doc)
	}
	return legacyJSONBytes(t, doc)
}

func TestTheWriterGivesBackTheBytesTheElixirKogenSaved(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/build.ex save/2 (the state is :erlang.term_to_binary of the Build map)
	man := legacyLoadManifest(t)
	for name := range man.Cases {
		t.Run(name, func(t *testing.T) {
			doc := legacyDoc(t, name)
			raw, _ := base64.StdEncoding.DecodeString(doc["state"].(string))
			term, err := legacyDecodeTerm(raw)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(legacyEncode(term), raw) {
				t.Fatal("re-encoding the decoded Build does not give the saved bytes")
			}
		})
	}
}

func TestEveryRealCheckpointDecodes(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/run.ex decode_checkpoint/1 (valid_state?/2 on the Build map as Build.save/2 wrote it)
	man := legacyLoadManifest(t)
	for name, c := range man.Cases {
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(legacyDir, c.Checkpoint))
			if err != nil {
				t.Fatal(err)
			}
			loaded, err := legacyDecode(raw)
			if err != nil {
				t.Fatal(err)
			}
			st := loaded.State
			eq(t, "version", loaded.Doc.Version, 3)
			eq(t, "run id", st.Run.ID, c.ID)
			eq(t, "root", st.Root, man.Root)
			eq(t, "slug", st.Slug, man.Slug)
			eq(t, "start", st.Start, man.Start)
			eq(t, "start tree", st.StartTree, man.StartTree)
			eq(t, "run dir", st.Run.Dir, man.Root+"/.kogen/local/runs/"+c.ID)
			eq(t, "log", st.Run.LogPath, st.Run.Dir+"/log.jsonl")
			if want := man.Root + "/.git/index"; st.GitIndex != want && st.GitIndex != "/private"+want {
				t.Fatalf("git index %s", st.GitIndex)
			}
			eq(t, "approval", loaded.Doc.Approval, st.ApprovalBytes)
			eq(t, "config", configJSON(st.Config) != "", true)
			eq(t, "setup", strings.Join(st.Config.Setup, "|"), "true")
			eq(t, "checks", len(st.Config.Checks), 2)
			eq(t, "check", st.Config.Checks[1].Name+"="+st.Config.Checks[1].Run, "unit=grep -q . app.txt")
			eq(t, "acceptance", st.Config.Acceptance.Run+" "+st.Config.Acceptance.StepsDir, "sh accept.sh features/steps")
			eq(t, "protect", strings.Join(st.Config.Protect, "|"), "accept.sh")
			eq(t, "build model", st.Config.Models["build"].Model+"/"+st.Config.Models["build"].Effort, "gpt-6.1-sol/medium")
			eq(t, "no workers", st.Config.ShapeWorkers.Enabled, false)
			if st.Config.ShapeWorkers.Roles == nil {
				t.Fatal("workers' roles are nil")
			}
			eq(t, "usage", st.Usage, Tokens{count(120), count(40), count(31), count(7)})
			eq(t, "attempt usage", st.AttemptUsage, st.Usage)
			eq(t, "round", st.Round, 1)
			eq(t, "model active", st.ModelActiveMS, int64(1234))
			if st.Baseline[0] != ".kogen/intents/fixture/intent.md" || !slices.Contains(st.Baseline, "accept.sh") ||
				!slices.Contains(st.Baseline, project.ConfigPath) {
				t.Fatalf("baseline %v", st.Baseline)
			}
			for _, p := range st.Baseline {
				if len(st.BaselineDigests[p]) != 64 {
					t.Fatalf("digest of %s: %q", p, st.BaselineDigests[p])
				}
			}
			if st.SourceProvenance != nil || st.Parent != nil || st.RootRun != nil {
				t.Fatal("source, parent or root run set")
			}
			if len(st.PromptCache) != 1 {
				t.Fatalf("cache states %v", st.PromptCache)
			}
			for _, cs := range st.PromptCache {
				eq(t, "cache state", cs.ID+" "+cs.Response, "conversation-fixture-1 resp_fixture_1")
			}
			if (name == "builder" || name == "builder_verify" || name == "tool" || name == "commit") && st.WorkingContext["build"] == nil {
				t.Fatalf("no builder working context")
			}
		})
	}
}

func TestTheContinuationsOfRealCheckpoints(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/run.ex valid_continuation?/1 and Kogen.Build.save/2 (the stages the Build saves)
	man := legacyLoadManifest(t)
	load := func(name string) *State {
		raw, err := os.ReadFile(filepath.Join(legacyDir, man.Cases[name].Checkpoint))
		if err != nil {
			t.Fatal(err)
		}
		l, err := legacyDecode(raw)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		return l.State
	}
	text := func(items []any, i int) string {
		b, _ := json.Marshal(items[i])
		return string(b)
	}

	b := load("builder")
	eq(t, "builder stage", b.Continuation.Stage, StageBuilder)
	eq(t, "builder items", len(b.Continuation.Input), 4)
	first := b.Continuation.Input[0].(map[string]any)
	eq(t, "role", first["role"], any("user"))
	blocks := first["content"].([]any)
	eq(t, "first block", blocks[0].(map[string]any)["text"], any("# Intent: Preserve the fixture\n\nThe stable authority — naïve ✓\n"))
	eq(t, "call", text(b.Continuation.Input, 2), `{"arguments":"{\"command\":\"cat app.txt\"}","call_id":"call_1","id":"fc_1","name":"shell","status":"completed","type":"function_call"}`)
	eq(t, "output", text(b.Continuation.Input, 3), `{"call_id":"call_1","output":"baseline\n","type":"function_call_output"}`)
	oc := b.WorkingContext["build"]
	eq(t, "mandatory", len(oc.Mandatory), 1)
	eq(t, "observation", oc.Observations[0], any("finished a read ✓"))
	eq(t, "history", len(oc.History), 0)
	if b.LastPass != nil || b.LastReview != nil || b.Blocker != nil {
		t.Fatal("pass, review or blocker set")
	}

	v := load("builder_verify")
	eq(t, "verify stage", v.Continuation.Stage, StageBuilderVerify)
	eq(t, "finish", v.Continuation.Finish["name"], any("finish"))
	eq(t, "verify items", len(v.Continuation.Input), 5)

	tl := load("tool")
	eq(t, "tool stage", tl.Continuation.Stage, StageTool)
	eq(t, "tool owner", tl.Continuation.Owner, "build")
	eq(t, "commit stage", load("commit").Continuation.Stage, StageCommit)
	eq(t, "commit tree", load("commit").Continuation.Tree, man.Cases["commit"].PassTree)
	eq(t, "startup stage", load("startup").Continuation.Stage, StageStartup)
	eq(t, "startup phase", load("startup").Phase, "startup")
	bl := load("blocker")
	eq(t, "blocker class", bl.Blocker["classification"], any("BUILDER-REPORTED"))
	eq(t, "blocker paths", reflect.DeepEqual(bl.Blocker["paths"], []any{"accept.sh"}), true)

	landed := load("landed")
	eq(t, "landed stage", landed.Continuation.Stage, StageLanded)
	eq(t, "landed commit", landed.Continuation.Commit, man.Cases["landed"].Commit)
	eq(t, "landed review", landed.LastReview.Verdict+" "+landed.LastReview.Tree, "approve "+man.Cases["landed"].PassTree)
	eq(t, "landed pass", landed.LastPass.Green && landed.LastPass.Tree == man.Cases["landed"].PassTree, true)
	eq(t, "landed pass setup", len(landed.LastPass.Setup), 1)
	eq(t, "landed pass model", landed.LastPass.Model.State, "none")
	eq(t, "landed pass acceptance", landed.LastPass.Acceptance.Passed, 2)
	eq(t, "landed scenario", landed.LastPass.Acceptance.Scenarios[1].Name+" "+landed.LastPass.Acceptance.Scenarios[1].Status, "Second passed")
	eq(t, "landed steps", len(landed.LastPass.Acceptance.Scenarios[0].Steps), 2)

	// The review stages hold the reviewer's session the way review.go keeps it.
	rv := load("review")
	eq(t, "review stage", rv.Continuation.Stage, StageReview)
	s, err := reviewDecode(rv.Continuation.Review)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "review role", s.Role.Model+"/"+s.Role.Effort+"/"+s.Role.Provider, "gpt-6.1-sol/high/")
	eq(t, "review input", len(s.Input), 1)
	eq(t, "review usage", s.Usage, zeroTokens())
	if s.Verdict != nil || s.Tree != "" || len(s.Attempts) != 0 || rv.Continuation.Pass == nil || !rv.Continuation.Pass.Green {
		t.Fatalf("review session %+v", s)
	}
	eq(t, "review pass", rv.Continuation.Pass.Tree, man.Cases["review"].PassTree)
	eq(t, "review count", rv.Review, 1)

	vv := load("review_verify")
	eq(t, "review_verify stage", vv.Continuation.Stage, StageReviewVerify)
	s, _ = reviewDecode(vv.Continuation.Review)
	eq(t, "verdict", s.Verdict.Verdict, "approve")
	eq(t, "note", s.Verdict.Findings[0]["message"], any("fine — ✓"))
	eq(t, "tree", s.Tree, man.Cases["review_verify"].PassTree)
	eq(t, "verify usage", s.Usage, Tokens{count(9), count(3), count(4), count(1)})
	eq(t, "conversation after the verdict", len(s.Input), 2)
	eq(t, "last review", vv.LastReview == nil, true)

	rr := load("review_retry_verify")
	eq(t, "retry stage", rr.Continuation.Stage, StageReviewRetry)
	s, _ = reviewDecode(rr.Continuation.Review)
	eq(t, "retry verdict", s.Verdict.Verdict, "changes")
	eq(t, "retry attempts", len(s.Attempts), 1)
	eq(t, "retry attempt", s.Attempts[0].Verdict+" "+s.Attempts[0].Tree, "changes "+man.Cases["review_retry_verify"].PassTree)
	eq(t, "pending", rr.LastReview.Verdict, "pending")
	eq(t, "pending finding", rr.LastReview.Findings[0]["message"], any("Original unresolved requirement"))

	// A Quint model: the model line's numbers come across as the Intent's own parse gives them.
	md := load("model")
	eq(t, "model pass", md.LastPass.Model.State, "ok")
	in, err := md.intent()
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "model line", in.ModelLine, strings.TrimPrefix(man.Cases["model"].ModelLine, "Model: "))
	eq(t, "model", in.Model.Path+" "+strings.Join(in.Model.Invariants, ",")+" "+in.Model.Seed+" "+in.Model.Samples+" "+in.Model.Steps, "model.qnt Inv,Other 7 20 5")
}

// legacyGoldenRows are further terms written by the Erlang runtime (OTP 29), by name.
const legacyGoldenRows = `{
 "struct": "837400000004770269646d00000002616277036c6f676d0000000c2f642f6c6f672e6a736f6e6c77036469726d000000022f64770a5f5f7374727563745f5f7710456c697869722e4b6f67656e2e52756e",
 "big map": "8374000000286d000000036b313961136d000000036b333361216d000000036b323461186d000000026b3561056d000000036b333961276d000000036b333661246d000000026b3661066d000000036b333261206d000000036b313861126d000000036b3133610d6d000000036b3237611b6d000000036b323261166d000000036b333461226d000000026b3861086d000000036b3130610a6d000000036b3134610e6d000000026b3761076d000000036b3330611e6d000000036b313661106d000000036b3135610f6d000000026b3961096d000000036b333761256d000000036b3131610b6d000000026b3361036d000000026b3161016d000000026b3261026d000000036b343061286d000000036b323161156d000000036b323561196d000000026b3461046d000000036b333561236d000000036b3132610c6d000000036b3239611d6d000000036b323061146d000000036b3238611c6d000000036b3331611f6d000000036b323361176d000000036b3236611a6d000000036b313761116d000000036b33386126",
 "big tuple": "83690000012c610161026103610461056106610761086109610a610b610c610d610e610f6110611161126113611461156116611761186119611a611b611c611d611e611f6120612161226123612461256126612761286129612a612b612c612d612e612f6130613161326133613461356136613761386139613a613b613c613d613e613f6140614161426143614461456146614761486149614a614b614c614d614e614f6150615161526153615461556156615761586159615a615b615c615d615e615f6160616161626163616461656166616761686169616a616b616c616d616e616f6170617161726173617461756176617761786179617a617b617c617d617e617f6180618161826183618461856186618761886189618a618b618c618d618e618f6190619161926193619461956196619761986199619a619b619c619d619e619f61a061a161a261a361a461a561a661a761a861a961aa61ab61ac61ad61ae61af61b061b161b261b361b461b561b661b761b861b961ba61bb61bc61bd61be61bf61c061c161c261c361c461c561c661c761c861c961ca61cb61cc61cd61ce61cf61d061d161d261d361d461d561d661d761d861d961da61db61dc61dd61de61df61e061e161e261e361e461e561e661e761e861e961ea61eb61ec61ed61ee61ef61f061f161f261f361f461f561f661f761f861f961fa61fb61fc61fd61fe61ff6200000100620000010162000001026200000103620000010462000001056200000106620000010762000001086200000109620000010a620000010b620000010c620000010d620000010e620000010f6200000110620000011162000001126200000113620000011462000001156200000116620000011762000001186200000119620000011a620000011b620000011c620000011d620000011e620000011f6200000120620000012162000001226200000123620000012462000001256200000126620000012762000001286200000129620000012a620000012b620000012c",
 "long charlist": "836c0000012c610161026103610461056106610761086109610a610b610c610d610e610f6110611161126113611461156116611761186119611a611b611c611d611e611f6120612161226123612461256126612761286129612a612b612c612d612e612f6130613161326133613461356136613761386139613a613b613c613d613e613f6140614161426143614461456146614761486149614a614b614c614d614e614f6150615161526153615461556156615761586159615a615b615c615d615e615f6160616161626163616461656166616761686169616a616b616c616d616e616f6170617161726173617461756176617761786179617a617b617c617d617e617f6180618161826183618461856186618761886189618a618b618c618d618e618f6190619161926193619461956196619761986199619a619b619c619d619e619f61a061a161a261a361a461a561a661a761a861a961aa61ab61ac61ad61ae61af61b061b161b261b361b461b561b661b761b861b961ba61bb61bc61bd61be61bf61c061c161c261c361c461c561c661c761c861c961ca61cb61cc61cd61ce61cf61d061d161d261d361d461d561d661d761d861d961da61db61dc61dd61de61df61e061e161e261e361e461e561e661e761e861e961ea61eb61ec61ed61ee61ef61f061f161f261f361f461f561f661f761f861f961fa61fb61fc61fd61fe61ff6200000100620000010162000001026200000103620000010462000001056200000106620000010762000001086200000109620000010a620000010b620000010c620000010d620000010e620000010f6200000110620000011162000001126200000113620000011462000001156200000116620000011762000001186200000119620000011a620000011b620000011c620000011d620000011e620000011f6200000120620000012162000001226200000123620000012462000001256200000126620000012762000001286200000129620000012a620000012b620000012c6a",
 "pid": "8358770d6e6f6e6f6465406e6f686f7374000000650000000000000000",
 "ref": "835a0003770d6e6f6e6f6465406e6f686f73740000000000006136dfd40003995ba39d",
 "fun": "83700000005301627c2211416b248c37f65c11706f6cfd00000003000000007711656c697869725f636f6d70696c65725f326103620313e11058770d6e6f6e6f6465406e6f686f7374000000000000000000000000",
 "export fun": "8371770d456c697869722e537472696e6777067570636173656101",
 "bitstring": "834d000000010320",
 "port": "8378770d6e6f6e6f6465406e6f686f7374000000000000000000000000",
 "compressed": "835000000bbd789cedc2310d00300800307e54b2ddf8431e3638dab42372ea7d5555f5f805db1a7ddd",
 "compressed map": "835000000206789c2b616060602a674ccc656060fc52310a461c28674c4a6402005d53ee4f"
}`

// ---- resuming the Elixir Kogen's Builds ----

type legacyOptions struct {
	// file is the checkpoint file to use when it is not the case's own (a variant).
	file string
	// raw writes the file as it is: no moving of paths, no new envelope.
	raw      bool
	state    func(m *legacyMap)
	envelope func(doc map[string]any)
	// before runs once the repository is made, before the checkpoint is written.
	before func(e *env)
}

func legacyWith(f func(o *legacyOptions)) func(*legacyOptions) { return f }

// newLegacyEnv makes the repository of testdata/legacy/project at a new place (the start
// commit and every tree are the Elixir Kogen's, byte for byte), gets it into the state the
// case was saved in, and writes the Elixir checkpoint with the paths moved, as the Build's own
// run folder holds it. It returns the repository and the id of the saved Build.
func newLegacyEnv(t *testing.T, name string, opts ...func(*legacyOptions)) (*env, string) {
	t.Helper()
	var o legacyOptions
	for _, f := range opts {
		f(&o)
	}
	man := legacyLoadManifest(t)
	c, ok := man.Cases[name]
	if !ok {
		t.Fatalf("no fixture case %q", name)
	}
	e := &env{t: t, root: physical(t, t.TempDir()), home: physical(t, t.TempDir()), aux: physical(t, t.TempDir()), prov: newFakeProvider(t)}
	e.hooks = t.TempDir()
	e.git = isolatedEnv()
	for k, v := range man.AuthorEnv {
		e.git = append(e.git, k+"="+v)
	}
	e.run("git", "init", "-q", "--initial-branch=main")
	for k, v := range map[string]string{"user.name": "Kogen Fixture", "user.email": "kogen-fixture@example.invalid",
		"commit.gpgsign": "false", "core.hooksPath": e.hooks} {
		e.run("git", "config", k, v)
	}
	project := filepath.Join(legacyDir, "project")
	var approval []byte
	err := filepath.WalkDir(project, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(project, path)
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if rel == "APPROVAL" {
			approval = b
			return nil
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(rel, ".sh") {
			mode = 0o755
		}
		writeFile(t, filepath.Join(e.root, rel), string(b), mode)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	e.run("git", append([]string{"add"}, man.Tracked...)...)
	e.run("git", "commit", "-qm", "fixture baseline")
	if got := e.head(); got != man.Start {
		t.Fatalf("the start commit is %s, the Elixir Kogen's is %s: the fixture project and gen.exs have drifted apart", got, man.Start)
	}
	if o.before != nil {
		o.before(e)
	}
	// The Build made the tree of its start (the objects stay in the repository).
	if tree, err := e.gitRepo().Tree(man.Start, nil); err != nil || tree != man.StartTree {
		t.Fatalf("the tree of the start is %s (%v), the Elixir Kogen's is %s", tree, err, man.StartTree)
	}
	for rel, text := range c.Edits {
		e.write(rel, text)
	}
	if c.Commit != "" {
		e.run("git", "add", "-A")
		msg := filepath.Join(e.aux, "commit-message.txt")
		writeFile(t, msg, "Preserve the fixture\n\nKogen-Intent: fixture\n", 0o644)
		e.run("git", "commit", "-q", "-F", msg)
		if got := e.head(); got != c.Commit {
			t.Fatalf("the landed commit is %s, the Elixir Kogen's is %s", got, c.Commit)
		}
	} else {
		writeFile(t, filepath.Join(e.root, ".kogen/local/approvals/fixture.json"), string(approval), 0o644)
	}
	index, err := os.ReadFile(filepath.Join(e.root, ".git/index"))
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(e.root, ".kogen/local/runs", c.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "index-at-start"), string(index), 0o644)
	writeFile(t, filepath.Join(dir, "result.json"), `{"build":"`+c.ID+`","outcome":"interrupted","slug":"fixture"}`+"\n", 0o644)

	file := name
	if o.file != "" {
		file = o.file
	}
	if o.raw {
		b, err := os.ReadFile(filepath.Join(legacyDir, file+".checkpoint.json"))
		if err != nil {
			t.Fatal(err)
		}
		writeFile(t, filepath.Join(dir, "checkpoint.json"), string(b), 0o600)
		return e, c.ID
	}
	doc := legacyDoc(t, file)
	state := legacyTerm(t, doc)
	moved := legacyReplace(legacyReplace(state, "/private"+man.Root, e.root), man.Root, e.root).(*legacyMap)
	if o.state != nil {
		o.state(moved)
	}
	doc["state"] = base64.StdEncoding.EncodeToString(legacyEncode(moved))
	identity, err := fileIdentity(e.root)
	if err != nil {
		t.Fatal(err)
	}
	candidate, err := e.gitRepo().Tree(man.Start, nil)
	if err != nil {
		t.Fatal(err)
	}
	doc["identity"], doc["candidate"], doc["index"] = identity, candidate, base64.StdEncoding.EncodeToString(index)
	if o.envelope != nil {
		o.envelope(doc)
	}
	writeFile(t, filepath.Join(dir, "checkpoint.json"), string(legacyJSONBytes(t, doc)), 0o600)
	return e, c.ID
}

// legacyResume resumes with the independent review (the core tests' default is a stand-in).
func legacyResume(e *env, id string) *attempt {
	return e.resume(id, func(in *ResumeInput) { in.Reviewer = reviewIndependent{} })
}

func legacyChild(t *testing.T, e *env, id string) string {
	t.Helper()
	for _, c := range e.runIDs() {
		if c != id {
			return c
		}
	}
	t.Fatalf("no resumed run besides %s: %v", id, e.runIDs())
	return ""
}

// legacyTexts are the texts of a request's conversation, the developer policy left out: the
// message blocks, tool arguments and tool outputs.
func legacyTexts(req map[string]any) []string {
	var out []string
	items, _ := req["input"].([]any)
	for _, it := range items {
		m, _ := it.(map[string]any)
		if m["role"] == "developer" {
			continue
		}
		switch c := m["content"].(type) {
		case string:
			out = append(out, c)
		case []any:
			for _, b := range c {
				if bm, ok := b.(map[string]any); ok {
					if s, ok := bm["text"].(string); ok {
						out = append(out, s)
					}
				}
			}
		}
		for _, k := range []string{"arguments", "output"} {
			if s, ok := m[k].(string); ok {
				out = append(out, s)
			}
		}
	}
	return out
}

// legacyContinues checks that the texts the Elixir Build saved reach the provider in this
// order, each in the message it was saved in or a later one (nothing else is asserted about
// what the Go engine adds around them).
func legacyContinues(t *testing.T, req map[string]any, want ...string) {
	t.Helper()
	texts := legacyTexts(req)
	at := 0
	for _, w := range want {
		found := false
		for ; at < len(texts); at++ {
			if strings.Contains(texts[at], w) {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("the request lacks %q (in order); it has %q", w, texts)
		}
	}
}

func approveVerdict() map[string]any {
	return map[string]any{"verdict": "approve", "findings": []any{}}
}

// legacyLanded checks the end of a resumed Build: one commit on the start, the message, the
// resumed run's result, and the Elixir run's files exactly as they were.
func legacyLanded(t *testing.T, e *env, id string, r *attempt, before map[string]string) string {
	t.Helper()
	man := legacyLoadManifest(t)
	if r.exit != 0 || r.err != nil {
		t.Fatalf("exit %d err %v\n%s", r.exit, r.err, r.shown())
	}
	child := legacyChild(t, e, id)
	contains(t, "stdout", r.out.String(), "resuming Build "+id+" as "+child+" (root "+id+")\n")
	contains(t, "stdout", r.out.String(), "landed fixture ")
	eq(t, "commits", e.gitOut("rev-list", "--count", man.Start+"..HEAD"), "1")
	eq(t, "parent", e.gitOut("rev-parse", "HEAD^"), man.Start)
	eq(t, "message", e.gitOut("log", "-1", "--format=%B"), "Preserve the fixture\n\nKogen-Intent: fixture")
	res := e.result(child)
	eq(t, "outcome", res["outcome"], any("landed"))
	eq(t, "resumed_from", res["resumed_from"], any(id))
	eq(t, "root_build", res["root_build"], any(id))
	if !reflect.DeepEqual(e.runFiles(id), before) {
		t.Fatal("the files of the Elixir Build changed")
	}
	doc, state := e.checkpoint(child)
	eq(t, "child version", doc["version"], any(float64(4)))
	eq(t, "child stage", state["continuation"].(map[string]any)["stage"], any("landed"))
	// The conversation the Elixir Build had keeps its prompt-cache state.
	cache, _ := state["prompt_cache_states"].(map[string]any)
	kept := false
	for _, v := range cache {
		if v.(map[string]any)["id"] == "conversation-fixture-1" && v.(map[string]any)["response"] == "resp_fixture_1" {
			kept = true
		}
	}
	if !kept {
		t.Fatalf("prompt cache states %v", cache)
	}
	return child
}

func TestALegacyBuilderCheckpointResumesTheSameConversationAndLandsOnce(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_context_files_test.exs: cancelled initial request freezes conversation; test/integration/build_boundaries_test.exs: resuming pending reviewer verification keeps repairs with the reviewer
	e, id := newLegacyEnv(t, "builder")
	f := e.prov
	f.then(f.calls("finish", map[string]any{"summary": "nothing to change"}), f.calls("submit_review", approveVerdict()))
	before := e.runFiles(id)
	checkpoint := e.read(".kogen/local/runs/" + id + "/checkpoint.json")
	r := legacyResume(e, id)
	child := legacyLanded(t, e, id, r, before)
	if e.read(".kogen/local/runs/"+id+"/checkpoint.json") != checkpoint {
		t.Fatal("checkpoint.json of the Elixir Build changed")
	}
	reqs := f.requests()
	eq(t, "requests", len(reqs), 2)
	legacyContinues(t, reqs[0], "# Intent: Preserve the fixture\n\nThe stable authority — naïve ✓\n", "# Files\n\nREADME.md\napp.txt\n",
		`{"command":"cat app.txt"}`, "baseline\n")
	legacyContinues(t, reqs[1], "Preserve the fixture")
	// The request is the saved conversation, item for item: the policy is the request's own
	// instructions and no cache marker rides on any block.
	var want []any
	if err := json.Unmarshal([]byte(`[
 {"role":"user","content":[
  {"type":"input_text","text":"# Intent: Preserve the fixture\n\nThe stable authority — naïve ✓\n"},
  {"type":"input_text","text":"# Files\n\nREADME.md\napp.txt\n"}]},
 {"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Look at app.txt first."}],"encrypted_content":"gAAAAABfixture==","status":"completed"},
 {"type":"function_call","id":"fc_1","call_id":"call_1","name":"shell","arguments":"{\"command\":\"cat app.txt\"}","status":"completed"},
 {"type":"function_call_output","call_id":"call_1","output":"baseline\n"}]`), &want); err != nil {
		t.Fatal(err)
	}
	got, _ := reqs[0]["input"].([]any)
	if _, own := reqs[0]["instructions"].(string); !own || !reflect.DeepEqual(got, want) {
		t.Fatalf("the resumed request is not the saved conversation:\n%v", got)
	}
	res := e.result(child)
	eq(t, "passes", res["passes"], any(float64(1)))
	eq(t, "reviews", res["reviews"], any(float64(1)))
	eq(t, "usage", res["usage"].(map[string]any)["input"], any(float64(122)))
	eq(t, "attempt usage", res["attempt_usage"].(map[string]any)["input"], any(float64(2)))
	if res["model_active_ms"].(float64) < 1234 {
		t.Fatalf("model_active_ms %v", res["model_active_ms"])
	}
	_, state := e.checkpoint(child)
	eq(t, "round", state["round"], any(float64(1)))
	events := e.events(child)
	if ev := eventsNamed(events, "resume"); len(ev) != 1 || ev[0]["parent"] != id || ev[0]["root"] != id {
		t.Fatalf("resume event %v", ev)
	}
	// The conversation scope of the requests is the root run.
	attempt := eventsNamed(events, "provider_attempt")[0]["provider"].(map[string]any)
	eq(t, "lineage", attempt["lineage"], any(id))
	// Resuming the child, which landed, is a no-op.
	commit := e.head()
	again := legacyResume(e, child)
	eq(t, "again exit", again.exit, 0)
	eq(t, "again stdout", again.out.String(), "Build "+child+" already landed "+commit+"\n")
	eq(t, "requests", f.count(), 2)
	// The Elixir run cannot be resumed any more: HEAD moved.
	old := legacyResume(e, id)
	eq(t, "old exit", old.exit, 1)
	contains(t, "old", old.shown(), "candidate/resume_refused: Build "+id+": HEAD moved or uncertain commit; inspect git log;")
}

func TestALegacyBuilderVerifyCheckpointRunsTheFixersAndThePassThenLands(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/build.ex resume_locked: stage builder_verify (round_end/1, then Shape.output of the saved finish call)
	e, id := newLegacyEnv(t, "builder_verify")
	f := e.prov
	f.then(f.calls("submit_review", approveVerdict()))
	before := e.runFiles(id)
	r := legacyResume(e, id)
	child := legacyLanded(t, e, id, r, before)
	eq(t, "requests", f.count(), 1)
	legacyContinues(t, f.requests()[0], "Preserve the fixture")
	eq(t, "passes", e.result(child)["passes"], any(float64(1)))
	eq(t, "round", e.result(child)["repairs"], any(float64(0)))
}

func TestALegacyReviewCheckpointContinuesTheSameReviewerConversation(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: resuming pending reviewer verification keeps repairs with the reviewer
	e, id := newLegacyEnv(t, "review")
	f := e.prov
	f.then(f.calls("submit_review", approveVerdict()))
	before := e.runFiles(id)
	r := legacyResume(e, id)
	child := legacyLanded(t, e, id, r, before)
	man := legacyLoadManifest(t)
	eq(t, "committed tree", e.gitOut("rev-parse", "HEAD^{tree}"), man.Cases["review"].PassTree)
	eq(t, "candidate", e.gitOut("show", "HEAD:app.txt"), "candidate")
	reqs := f.requests()
	eq(t, "requests", len(reqs), 1)
	legacyContinues(t, reqs[0], "# Intent\n\nPreserve the fixture\n# acceptance.feature", "acceptance: passed (2 scenarios)")
	eq(t, "model", reqs[0]["model"], any("gpt-6.1-sol"))
	eq(t, "reviews", e.result(child)["reviews"], any(float64(1)))
	eq(t, "passes", e.result(child)["passes"], any(float64(1)))
}

func TestALegacyReviewVerifyCheckpointJudgesTheSavedVerdictWithoutAskingAgain(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/review.ex resume/2: stage review_verify with an approve verdict (evaluate/8)
	e, id := newLegacyEnv(t, "review_verify")
	before := e.runFiles(id)
	r := legacyResume(e, id)
	child := legacyLanded(t, e, id, r, before)
	eq(t, "requests", e.prov.count(), 0)
	contains(t, "stdout", r.out.String(), "review: approved, 1 note(s)")
	contains(t, "stdout", r.out.String(), "note: app.txt:1: fine — ✓")
	eq(t, "reviews", e.result(child)["reviews"], any(float64(1)))
}

func TestALegacyRetryCheckpointSendsTheBlockerAndTheFreshResultsToTheSameReviewer(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: blocked #{retry_outcome} retry provider failure retains fresh evidence and the saved reviewer
	e, id := newLegacyEnv(t, "review_retry_verify")
	f := e.prov
	f.then(f.calls("submit_review", approveVerdict()))
	before := e.runFiles(id)
	r := legacyResume(e, id)
	child := legacyLanded(t, e, id, r, before)
	reqs := f.requests()
	eq(t, "requests", len(reqs), 1)
	legacyContinues(t, reqs[0], "# Intent\n\nPreserve the fixture\n# acceptance.feature", "Final verification passed.",
		"The caller explicitly resumed this blocked Build", "Original unresolved requirement")
	eq(t, "passes", e.result(child)["passes"], any(float64(2)))
}

func TestALegacyLandedBuildIsANoOpThatNamesTheCommit(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/build.ex resume_locked: already-landed commit provenance
	e, id := newLegacyEnv(t, "landed")
	before, runs := e.runFiles(id), e.runIDs()
	r := legacyResume(e, id)
	eq(t, "exit", r.exit, 0)
	eq(t, "stdout", r.out.String(), "Build "+id+" already landed "+e.head()+"\n")
	if !reflect.DeepEqual(e.runFiles(id), before) || !reflect.DeepEqual(e.runIDs(), runs) || e.prov.count() != 0 {
		t.Fatal("a run, a request or a change of the Elixir Build's files")
	}
	// HEAD moved on: the commit is not the landing any more.
	e.run("git", "commit", "-q", "--allow-empty", "-m", "moved")
	moved := legacyResume(e, id)
	eq(t, "moved exit", moved.exit, 1)
	contains(t, "moved", moved.shown(), "candidate/resume_refused: Build "+id+": HEAD moved or uncertain commit; inspect git log;")

	// A landing whose commit does not sit on the Build's start is refused.
	e2, id2 := newLegacyEnv(t, "landed", legacyWith(func(o *legacyOptions) {
		o.state = func(m *legacyMap) { legacyPut(m, latom("start"), strings.Repeat("a", 40)) }
	}))
	other := legacyResume(e2, id2)
	eq(t, "provenance exit", other.exit, 1)
	contains(t, "provenance", other.shown(), "candidate/resume_refused: Build "+id2+": already-landed commit provenance changed;")
}

func TestLegacyResumeRefusals(t *testing.T) {
	t.Parallel()
	// ExUnit: test/integration/build_boundaries_test.exs: resume refuses damaged index custody, configuration and required saved state before effects; pre-clean checkpoints cannot authorize resume
	type refusal struct {
		name     string
		fixture  string
		file     string
		raw      bool
		state    func(m *legacyMap)
		envelope func(doc map[string]any)
		prep     func(e *env, id string)
		want     string
		kind     string
	}
	runDir := func(m *legacyMap) *legacyMap { return legacyDigMap(t, m, latom("run")) }
	cases := []refusal{
		{name: "damaged index backup", prep: func(e *env, id string) {
			os.WriteFile(e.runPath(id, "index-at-start"), []byte("damaged original index"), 0o644)
		}, want: "original index backup missing or damaged: "},
		{name: "index custody", prep: func(e *env, id string) { e.write("staged.txt", "x\n"); e.run("git", "add", "staged.txt") },
			want: "index/staged custody changed"},
		{name: "configuration", prep: func(e *env, id string) { e.write(".kogen/project.yaml", "version: [invalid") },
			want: "baseline changed: .kogen/project.yaml"},
		{name: "protected check file", prep: func(e *env, id string) { e.write("accept.sh", "#!/bin/sh\nexit 0\n") },
			want: "baseline changed: accept.sh"},
		{name: "step file", prep: func(e *env, id string) { e.write(stepsFile, "// changed\n") }, want: "baseline changed: " + stepsFile},
		{name: "intent", prep: func(e *env, id string) { e.write(".kogen/intents/fixture/intent.md", "# changed\n") },
			want: "baseline changed: .kogen/intents/fixture/intent.md"},
		{name: "approval", prep: func(e *env, id string) {
			e.write(".kogen/local/approvals/fixture.json", strings.Replace(e.read(".kogen/local/approvals/fixture.json"), "Kogen Fixture", "Somebody Else", 1))
		}, want: "approval changed"},
		{name: "approval removed", prep: func(e *env, id string) { os.Remove(filepath.Join(e.root, ".kogen/local/approvals/fixture.json")) },
			want: "approval changed"},
		{name: "head moved", prep: func(e *env, id string) { e.run("git", "commit", "-q", "--allow-empty", "-m", "moved") },
			want: "HEAD moved or uncertain commit; inspect git log"},
		{name: "candidate drift", prep: func(e *env, id string) { e.write("app.txt", "drift\n") },
			want: "candidate contents/modes or unrelated paths changed: app.txt"},
		{name: "unrelated path", prep: func(e *env, id string) { e.write("other.txt", "x\n") },
			want: "candidate contents/modes or unrelated paths changed: other.txt"},
		{name: "another checkout", envelope: func(doc map[string]any) { doc["identity"] = "/elsewhere:1:2" }, want: "another checkout identity"},
		{name: "another root", state: func(m *legacyMap) {
			legacyPut(m, latom("root"), "/elsewhere")
			legacyPut(legacyDigMap(t, m, latom("intent")), latom("root"), "/elsewhere")
		},
			want: "another checkout identity"},
		{name: "index path", state: func(m *legacyMap) { legacyPut(m, latom("git_index"), "/elsewhere/index") }, want: "checkpoint run/index paths changed"},
		{name: "run folder", state: func(m *legacyMap) { legacyPut(runDir(m), latom("dir"), "/elsewhere/run") }, want: "checkpoint run/index paths changed"},
		{name: "run log", state: func(m *legacyMap) { legacyPut(runDir(m), latom("log"), "/elsewhere/log.jsonl") }, want: "checkpoint run/index paths changed"},
		{name: "configuration of the Build differs", state: func(m *legacyMap) {
			legacyPut(legacyDigMap(t, m, latom("config")), latom("setup"), []any{"false"})
		}, want: "baseline/configuration changed"},
		{name: "baseline of the Build differs", state: func(m *legacyMap) {
			legacyPut(m, latom("baseline"), []any{".kogen/intents/fixture/intent.md", project.ConfigPath})
		}, want: "baseline/configuration changed"},
		{name: "tool boundary", fixture: "tool", want: "uncertain tool boundary; inspect effects before starting a freshly approved Build"},
		{name: "commit boundary", fixture: "commit", want: "uncertain commit boundary; inspect effects before starting a freshly approved Build"},
		{name: "startup boundary", fixture: "startup", want: "uncertain startup boundary; inspect effects before starting a freshly approved Build"},
		{name: "blocker", fixture: "blocker", want: "protected-contract blocker requires correction and fresh approval"},
		{name: "version 2", file: "version2", raw: true, want: "incompatible checkpoint version 2"},
		{name: "truncated state", file: "damaged-truncated", raw: true, want: "damaged checkpoint state"},
		{name: "state that is not a term", file: "damaged-garbage", raw: true, want: "damaged checkpoint state"},
		{name: "missing phase", file: "malformed-no-phase", raw: true, want: "malformed required checkpoint fields"},
		{name: "unknown phase", file: "malformed-phase", raw: true, want: "malformed required checkpoint fields"},
		{name: "envelope without an approval", envelope: func(doc map[string]any) { delete(doc, "approval") }, want: "malformed required checkpoint fields"},
		{name: "state that is not text", envelope: func(doc map[string]any) { doc["state"] = map[string]any{} }, want: "malformed required checkpoint fields"},
		{name: "state that is not base64", envelope: func(doc map[string]any) { doc["state"] = "not base64!" }, want: "malformed required checkpoint fields"},
		{name: "state with a line break", envelope: func(doc map[string]any) {
			s := doc["state"].(string)
			doc["state"] = s[:8] + "\n" + s[8:]
		}, want: "malformed required checkpoint fields"},
		{name: "a hand-built state", state: func(m *legacyMap) { legacyDelete(m, latom("working_context")) }, want: "malformed required checkpoint fields"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fixture := c.fixture
			if fixture == "" {
				fixture = "builder"
			}
			e, id := newLegacyEnv(t, fixture, legacyWith(func(o *legacyOptions) {
				o.file, o.raw, o.state, o.envelope = c.file, c.raw, c.state, c.envelope
			}))
			if c.prep != nil {
				c.prep(e, id)
			}
			before, files, runs, requests := e.state(), e.runFiles(id), e.runIDs(), e.prov.count()
			r := e.resume(id)
			eq(t, "exit", r.exit, 1)
			kind := c.kind
			if kind == "" {
				kind = "resume_refused"
			}
			text := r.shown()
			contains(t, "output", text, "candidate/"+kind+": Build "+id+": "+c.want)
			contains(t, "output", text, "inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build\n")
			contains(t, "output", text, "  no newly created Build run;")
			if !reflect.DeepEqual(e.state(), before) {
				t.Fatalf("custody changed:\n%v\n%v", before, e.state())
			}
			if !reflect.DeepEqual(e.runFiles(id), files) {
				t.Fatal("the evidence of the Build changed")
			}
			if !reflect.DeepEqual(e.runIDs(), runs) || e.prov.count() != requests {
				t.Fatal("a run or request was started")
			}
		})
	}
}

func TestLegacyResumeRefusesWorkingContextHistoryCustody(t *testing.T) {
	t.Parallel()
	// ExUnit: lib/kogen/working_context.ex validate!
	e, id := newLegacyEnv(t, "builder", legacyWith(func(o *legacyOptions) {
		o.state = func(m *legacyMap) {
			owner := legacyDigMap(t, m, latom("working_context"), "build")
			legacyPut(owner, latom("history"), []any{lmap("path", "/elsewhere/1.json", "sha256", strings.Repeat("0", 64))})
		}
	}))
	r := e.resume(id)
	eq(t, "exit", r.exit, 1)
	contains(t, "output", r.shown(), "candidate/resume_refused: working-context history custody missing, changed or unsafe: /elsewhere/1.json;")
}

// ---- decoding checks, with no repository ----

// legacyDecodeAt is decodeCheckpoint on a fixture whose paths are moved to root (a folder
// that holds the Intent's feature), with the state and envelope changed.
func legacyDecodeAt(t *testing.T, name, root string, state func(m *legacyMap), envelope func(doc map[string]any)) (*Loaded, string) {
	t.Helper()
	man := legacyLoadManifest(t)
	raw := legacyChanged(t, name, func(m *legacyMap) {
		moved := legacyReplace(legacyReplace(m, "/private"+man.Root, root), man.Root, root).(*legacyMap)
		*m = *moved
		if state != nil {
			state(m)
		}
	}, envelope)
	return decodeCheckpoint(raw, legacyDecode)
}

func legacyFeatureRoot(t *testing.T) string {
	t.Helper()
	root := physical(t, t.TempDir())
	writeFile(t, filepath.Join(root, project.FeaturePath("fixture")), testFeature, 0o644)
	return root
}

func TestLegacyDecodeRefusesWhatValidStateRefuses(t *testing.T) {
	t.Parallel()
	// ExUnit: test/kogen/run_test.exs: checkpoint decoder refuses damaged, incomplete and incompatible state
	root := legacyFeatureRoot(t)
	atom := latom
	dig := func(m *legacyMap, keys ...string) *legacyMap {
		var ks []any
		for _, k := range keys {
			ks = append(ks, atom(k))
		}
		return legacyDigMap(t, m, ks...)
	}
	key := func(name string) func(m *legacyMap) { return func(m *legacyMap) { legacyDelete(m, atom(name)) } }
	set := func(name string, v any) func(m *legacyMap) { return func(m *legacyMap) { legacyPut(m, atom(name), v) } }
	type mutation struct {
		fixture string
		state   func(m *legacyMap)
		doc     func(doc map[string]any)
	}
	cases := map[string]mutation{}
	for _, k := range []string{"model", "phase", "t0", "last_pass", "last_review", "blocker", "parent", "root_run", "working_context", "source_provenance",
		"root", "slug", "start", "git_index", "start_tree", "approval_bytes", "run", "config", "intent", "baseline", "baseline_digests", "excluded",
		"round", "pass", "review", "repairs", "model_active_ms", "unknown_requests", "usage", "attempt_usage", "continuation"} {
		cases["no "+k] = mutation{state: key(k)}
	}
	for name, m := range map[string]mutation{
		"phase elsewhere":           {state: set("phase", atom("done"))},
		"phase as text":             {state: set("phase", "building")},
		"t0 as text":                {state: set("t0", "0")},
		"root as an atom":           {state: set("root", atom("root"))},
		"slug missing":              {state: set("slug", atom("nil"))},
		"start as an integer":       {state: set("start", int64(1))},
		"approval bytes":            {state: set("approval_bytes", int64(1))},
		"run is a plain map":        {state: func(m *legacyMap) { legacyDelete(dig(m, "run"), atom("__struct__")) }},
		"run of another module":     {state: func(m *legacyMap) { legacyPut(dig(m, "run"), atom("__struct__"), atom("Elixir.Other")) }},
		"run id":                    {state: func(m *legacyMap) { legacyPut(dig(m, "run"), atom("id"), int64(1)) }},
		"run folder":                {state: func(m *legacyMap) { legacyPut(dig(m, "run"), atom("dir"), atom("nil")) }},
		"run log":                   {state: func(m *legacyMap) { legacyDelete(dig(m, "run"), atom("log")) }},
		"config is a plain map":     {state: func(m *legacyMap) { legacyDelete(dig(m, "config"), atom("__struct__")) }},
		"config setup":              {state: func(m *legacyMap) { legacyPut(dig(m, "config"), atom("setup"), "true") }},
		"config check":              {state: func(m *legacyMap) { legacyPut(dig(m, "config"), atom("checks"), []any{"lint"}) }},
		"config model role":         {state: func(m *legacyMap) { legacyPut(dig(m, "config", "models"), "build", lmap(atom("model"), "x")) }},
		"intent is a plain map":     {state: func(m *legacyMap) { legacyDelete(dig(m, "intent"), atom("__struct__")) }},
		"intent root":               {state: func(m *legacyMap) { legacyPut(dig(m, "intent"), atom("root"), "/elsewhere") }},
		"intent slug":               {state: func(m *legacyMap) { legacyPut(dig(m, "intent"), atom("slug"), "other") }},
		"intent title":              {state: func(m *legacyMap) { legacyPut(dig(m, "intent"), atom("title"), atom("nil")) }},
		"intent title differs":      {state: func(m *legacyMap) { legacyPut(dig(m, "intent"), atom("title"), "Another title") }},
		"intent text":               {state: func(m *legacyMap) { legacyPut(dig(m, "intent"), atom("text"), int64(1)) }},
		"model is nil":              {state: set("model", atom("nil"))},
		"model is not the Intent's": {state: set("model", lmap(atom("path"), "m.qnt"))},
		"last pass is not a map":    {state: set("last_pass", "pass")},
		"last review verdict":       {state: set("last_review", lmap(atom("verdict"), "maybe", atom("findings"), []any{}, atom("n"), int64(1)))},
		"last review findings":      {state: set("last_review", lmap(atom("verdict"), "approve", atom("findings"), atom("nil"), atom("n"), int64(1)))},
		"last review number":        {state: set("last_review", lmap(atom("verdict"), "approve", atom("findings"), []any{}, atom("n"), "1"))},
		"working context is a list": {state: set("working_context", []any{})},
		"working context owner": {state: func(m *legacyMap) {
			legacyPut(dig(m, "working_context"), "other", lmap(atom("mandatory"), []any{}, atom("observations"), []any{}, atom("history"), []any{}))
		}},
		"working context mandatory": {state: func(m *legacyMap) {
			legacyPut(legacyDigMap(t, m, atom("working_context"), "build"), atom("mandatory"), []any{"text"})
		}},
		"working context observations": {state: func(m *legacyMap) {
			legacyPut(legacyDigMap(t, m, atom("working_context"), "build"), atom("observations"), atom("nil"))
		}},
		"working context history": {state: func(m *legacyMap) {
			legacyPut(legacyDigMap(t, m, atom("working_context"), "build"), atom("history"), []any{lmap("path", "p")})
		}},
		"source without a contract hash": {state: set("source_provenance", lmap("path", "p", "sha256", "s"))},
		"source that is not a map":       {state: set("source_provenance", "p")},
		"cache states nil":               {state: set("prompt_cache_states", atom("nil"))},
		"cache states list":              {state: set("prompt_cache_states", []any{})},
		"cache state empty":              {state: set("prompt_cache_states", lmap("key", lmap()))},
		"cache id empty":                 {state: set("prompt_cache_states", lmap("key", lmap(atom("id"), "", atom("unsupported"), atom("false"), atom("response"), atom("nil"))))},
		"cache id too long":              {state: set("prompt_cache_states", lmap("key", lmap(atom("id"), strings.Repeat("x", 257), atom("unsupported"), atom("false"), atom("response"), atom("nil"))))},
		"cache unsupported as text":      {state: set("prompt_cache_states", lmap("key", lmap(atom("id"), "id", atom("unsupported"), "false", atom("response"), atom("nil"))))},
		"cache response empty":           {state: set("prompt_cache_states", lmap("key", lmap(atom("id"), "id", atom("unsupported"), atom("false"), atom("response"), "")))},
		"cache key is an atom":           {state: set("prompt_cache_states", lmap(atom("key"), lmap(atom("id"), "id", atom("unsupported"), atom("false"), atom("response"), atom("nil"))))},
		"baseline is not a list":         {state: set("baseline", "x")},
		"baseline without the config":    {state: set("baseline", []any{".kogen/intents/fixture/intent.md"})},
		"baseline entry has no digest":   {state: set("baseline_digests", lmap(project.ConfigPath, "d"))},
		"digests is a list":              {state: set("baseline_digests", []any{})},
		"excluded entry":                 {state: set("excluded", []any{int64(1)})},
		"negative round":                 {state: set("round", int64(-1))},
		"pass as text":                   {state: set("pass", "1")},
		"negative review":                {state: set("review", int64(-1))},
		"negative repairs":               {state: set("repairs", int64(-1))},
		"negative model time":            {state: set("model_active_ms", int64(-1))},
		"negative unknown requests":      {state: set("unknown_requests", int64(-1))},
		"negative usage":                 {state: set("usage", lmap(atom("input"), int64(-1), atom("output"), int64(0), atom("cached"), int64(0), atom("reasoning"), int64(0)))},
		"usage lacks a count":            {state: set("usage", lmap(atom("input"), int64(1), atom("output"), int64(0), atom("cached"), int64(0)))},
		"attempt usage as text":          {state: set("attempt_usage", "none")},
		"unknown stage":                  {state: set("continuation", lmap(atom("stage"), atom("elsewhere")))},
		"stage as text":                  {state: set("continuation", lmap(atom("stage"), "builder"))},
		"builder input item":             {state: set("continuation", lmap(atom("stage"), atom("builder"), atom("input"), []any{"text"}))},
		"builder without input":          {state: set("continuation", lmap(atom("stage"), atom("builder")))},
		"builder_verify without finish":  {state: set("continuation", lmap(atom("stage"), atom("builder_verify"), atom("input"), []any{}))},
		"builder_verify finish":          {state: set("continuation", lmap(atom("stage"), atom("builder_verify"), atom("input"), []any{}, atom("finish"), "f"))},
		"landed without a commit":        {state: set("continuation", lmap(atom("stage"), atom("landed")))},
		"review without a session":       {state: set("continuation", lmap(atom("stage"), atom("review")))},
		"approval differs":               {doc: func(doc map[string]any) { doc["approval"] = base64.StdEncoding.EncodeToString([]byte("other")) }},
		"identity is not text":           {doc: func(doc map[string]any) { doc["identity"] = float64(1) }},
		"no candidate":                   {doc: func(doc map[string]any) { delete(doc, "candidate") }},
		"index is not base64":            {doc: func(doc map[string]any) { doc["index"] = "***" }},
		"approval is not base64":         {doc: func(doc map[string]any) { doc["approval"] = "***" }},
	} {
		cases[name] = m
	}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			fixture := c.fixture
			if fixture == "" {
				fixture = "builder"
			}
			_, why := legacyDecodeAt(t, fixture, root, c.state, c.doc)
			eq(t, "reason", why, "malformed required checkpoint fields")
		})
	}
	// The unchanged fixture, moved, is accepted.
	man := legacyLoadManifest(t)
	good := legacyChanged(t, "builder", func(m *legacyMap) {
		*m = *legacyReplace(legacyReplace(m, "/private"+man.Root, root), man.Root, root).(*legacyMap)
	}, nil)
	if _, why := decodeCheckpoint(good, legacyDecode); why != "" {
		t.Fatalf("the moved fixture is refused: %s", why)
	}
}

func TestLegacyDecodeRefusesIncompleteReviewAndPassState(t *testing.T) {
	t.Parallel()
	// ExUnit: test/kogen/run_test.exs: green reuse requires complete required clean evidence, not a stored Boolean
	root := legacyFeatureRoot(t)
	atom := latom
	cont := func(m *legacyMap, keys ...string) *legacyMap {
		ks := []any{atom("continuation")}
		for _, k := range keys {
			ks = append(ks, atom(k))
		}
		return legacyDigMap(t, m, ks...)
	}
	set := func(m *legacyMap, name string, v any, keys ...string) { legacyPut(cont(m, keys...), atom(name), v) }
	type mutation struct {
		fixture string
		state   func(m *legacyMap)
	}
	cases := map[string]mutation{
		"pass not clean":            {"review", func(m *legacyMap) { set(m, "clean", atom("false"), "pass") }},
		"pass number as text":       {"review", func(m *legacyMap) { set(m, "n", "1", "pass") }},
		"pass green flag missing":   {"review", func(m *legacyMap) { set(m, "green", atom("nil"), "pass") }},
		"pass without a tree":       {"review", func(m *legacyMap) { legacyDelete(cont(m, "pass"), atom("tree")) }},
		"pass acceptance not run":   {"review", func(m *legacyMap) { set(m, "acceptance", atom("not_run"), "pass") }},
		"pass acceptance elsewhere": {"review", func(m *legacyMap) { set(m, "acceptance", atom("elsewhere"), "pass") }},
		"pass acceptance exit":      {"review", func(m *legacyMap) { set(m, "status", int64(1), "pass", "acceptance") }},
		"pass acceptance problems":  {"review", func(m *legacyMap) { set(m, "problems", []any{"report_invalid"}, "pass", "acceptance") }},
		"pass acceptance scenarios": {"review", func(m *legacyMap) { set(m, "scenarios", atom("nil"), "pass", "acceptance") }},
		"pass lacks a scenario": {"review", func(m *legacyMap) {
			set(m, "scenarios", legacyDig(t, m, atom("continuation"), atom("pass"), atom("acceptance"), atom("scenarios")).([]any)[:1], "pass", "acceptance")
		}},
		"pass model missing":    {"review", func(m *legacyMap) { legacyDelete(cont(m, "pass"), atom("model")) }},
		"pass model is a model": {"review", func(m *legacyMap) { set(m, "model", legacyTuple{atom("ok"), []any{}}, "pass") }},
		"pass model failed":     {"review", func(m *legacyMap) { set(m, "model", legacyTuple{atom("failed"), []any{"x"}}, "pass") }},
		"pass model tuple":      {"review", func(m *legacyMap) { set(m, "model", legacyTuple{atom("maybe"), []any{}}, "pass") }},
		"pass checks reversed": {"review", func(m *legacyMap) {
			set(m, "checks", slicesReversed(legacyDig(t, m, atom("continuation"), atom("pass"), atom("checks")).([]any)), "pass")
		}},
		"pass checks missing": {"review", func(m *legacyMap) { set(m, "checks", []any{}, "pass") }},
		"pass check without output": {"review", func(m *legacyMap) {
			legacyDelete(legacyDig(t, m, atom("continuation"), atom("pass"), atom("checks")).([]any)[0].(*legacyMap), atom("output"))
		}},
		"pass moved":                 {"review", func(m *legacyMap) { set(m, "moved", []any{"app.txt"}, "pass") }},
		"pass moved not a list":      {"review", func(m *legacyMap) { set(m, "moved", atom("nil"), "pass") }},
		"pass failing":               {"review", func(m *legacyMap) { set(m, "failing", []any{"lint"}, "pass") }},
		"pass not run":               {"review", func(m *legacyMap) { set(m, "not_run", []any{"lint"}, "pass") }},
		"pass not run entries":       {"review", func(m *legacyMap) { set(m, "not_run", []any{int64(1)}, "pass") }},
		"pass setup missing":         {"review", func(m *legacyMap) { legacyDelete(cont(m, "pass"), atom("setup")) }},
		"pass setup empty":           {"review", func(m *legacyMap) { set(m, "setup", []any{}, "pass") }},
		"no session":                 {"review", func(m *legacyMap) { legacyDelete(cont(m), atom("session")) }},
		"no pass":                    {"review", func(m *legacyMap) { legacyDelete(cont(m), atom("pass")) }},
		"pass is nil":                {"review", func(m *legacyMap) { set(m, "pass", atom("nil")) }},
		"session role without model": {"review", func(m *legacyMap) { legacyDelete(cont(m, "session", "role"), atom("model")) }},
		"session role effort":        {"review", func(m *legacyMap) { set(m, "effort", int64(1), "session", "role") }},
		"session input item":         {"review", func(m *legacyMap) { set(m, "input", []any{"x"}, "session") }},
		"session attempts":           {"review", func(m *legacyMap) { set(m, "attempts", atom("nil"), "session") }},
		"session tools":              {"review", func(m *legacyMap) { set(m, "tools", atom("nil"), "session") }},
		"session usage":              {"review", func(m *legacyMap) { set(m, "usage", atom("nil"), "session") }},
		"verify without a verdict":   {"review_verify", func(m *legacyMap) { legacyDelete(cont(m), atom("verdict")) }},
		"verify verdict name":        {"review_verify", func(m *legacyMap) { set(m, "verdict", "maybe", "verdict") }},
		"verify verdict findings":    {"review_verify", func(m *legacyMap) { set(m, "findings", "none", "verdict") }},
		"verify usage":               {"review_verify", func(m *legacyMap) { set(m, "usage", atom("nil")) }},
		"verify input":               {"review_verify", func(m *legacyMap) { set(m, "input", []any{"x"}) }},
		"verify tree":                {"review_verify", func(m *legacyMap) { set(m, "tree", int64(1)) }},
		"retry without a tree":       {"review_retry_verify", func(m *legacyMap) { legacyDelete(cont(m), atom("tree")) }},
		"last pass incomplete":       {"landed", func(m *legacyMap) { set(m, "status", "skipped", "pass") }},
		"landed review tree":         {"landed", func(m *legacyMap) { legacyPut(legacyDigMap(t, m, atom("last_review")), atom("tree"), "other") }},
		"landed review verdict":      {"landed", func(m *legacyMap) { legacyPut(legacyDigMap(t, m, atom("last_review")), atom("verdict"), "pending") }},
		"landed without a review":    {"landed", func(m *legacyMap) { legacyPut(m, atom("last_review"), atom("nil")) }},
		"landed without a pass":      {"landed", func(m *legacyMap) { legacyPut(m, atom("last_pass"), atom("nil")) }},
	}
	// The incomplete green pass of the landed case sits in last_pass, not in the continuation.
	cases["last pass incomplete"] = mutation{"landed", func(m *legacyMap) {
		pass := legacyDigMap(t, m, atom("last_pass"))
		legacyPut(legacyDig(t, pass, atom("acceptance")).(*legacyMap), atom("passed"), int64(1))
	}}
	for name, c := range cases {
		t.Run(name, func(t *testing.T) {
			_, why := legacyDecodeAt(t, c.fixture, root, c.state, nil)
			eq(t, "reason", why, "malformed required checkpoint fields")
		})
	}
	// Each fixture, moved, is accepted: the refusals above are the changes.
	for name := range legacyLoadManifest(t).Cases {
		if name == "model" {
			continue // its Quint model is not on disk here: complete_pass? needs only the feature
		}
		t.Run("accepted "+name, func(t *testing.T) {
			if _, why := legacyDecodeAt(t, name, root, nil, nil); why != "" {
				t.Fatal(why)
			}
		})
	}
}

func slicesReversed(l []any) []any {
	out := slices.Clone(l)
	slices.Reverse(out)
	return out
}

func TestLegacyDecodeAcceptsAndRefusesLikeTheElixirDecoder(t *testing.T) {
	t.Parallel()
	// ExUnit: test/kogen/run_test.exs: checkpoint decoder refuses damaged, incomplete and incompatible state; green reuse requires complete required clean evidence, not a stored Boolean
	for _, raw := range []string{
		"{broken", "{}", `{"version":999}`, `{"version":1,"state":"bad"}`,
		`{"version":3,"state":"bad"}`, `{"version":3}`, `{"version":3,"state":7}`, `{"version":"3","state":"x"}`, `[]`, ``,
		`{"version":1,"state":"` + base64.StdEncoding.EncodeToString(legacyEncode(lmap())) + `"}`,
	} {
		if _, why := decodeCheckpoint([]byte(raw), legacyDecode); why == "" {
			t.Errorf("%q is accepted", raw)
		}
	}
	reasons := map[string]string{
		`{"version":3,"state":"bad"}`:  "malformed required checkpoint fields",
		`{"version":3}`:                "malformed required checkpoint fields",
		`{"version":3,"state":7}`:      "malformed required checkpoint fields",
		`{"version":2,"state":"x"}`:    "incompatible checkpoint version 2",
		`{"version":3,"state":"AAAA"}`: "damaged checkpoint state", // base64 of bytes that are no term
	}
	for raw, want := range reasons {
		if _, why := decodeCheckpoint([]byte(raw), legacyDecode); why != want {
			t.Errorf("%s: %q, want %q", raw, why, want)
		}
	}
	// A state that is a term but not a map is malformed, not damaged.
	for _, term := range []any{lmap(), []any{}, int64(1), "state", latom("nil"), legacyTuple{}} {
		raw := `{"version":3,"state":"` + base64.StdEncoding.EncodeToString(legacyEncode(term)) + `"}`
		if _, why := decodeCheckpoint([]byte(raw), legacyDecode); why != "malformed required checkpoint fields" {
			t.Errorf("%#v: %q", term, why)
		}
	}

	root := legacyFeatureRoot(t)
	writeFile(t, filepath.Join(root, ".kogen/intents/example/acceptance.feature"), "Feature: Example\n  Scenario: Complete\n    Given a gate\n", 0o644)
	atom := latom
	config := lmap(atom("__struct__"), atom("Elixir.Kogen.Config"), atom("setup"), []any{"true"}, atom("fix"), []any{},
		atom("checks"), []any{legacyTuple{"z-first", "true"}, legacyTuple{"a-last", "true"}}, atom("acceptance_run"), atom("nil"),
		atom("steps_dir"), atom("nil"), atom("protect"), []any{}, atom("models"), lmap(), atom("shape_workers"), lmap(atom("enabled"), atom("false")))
	intent := lmap(atom("__struct__"), atom("Elixir.Kogen.Intent"), atom("root"), root, atom("slug"), "example", atom("title"), "Example",
		atom("text"), "# Example\n\nModel: not applicable — fixture\n", atom("model"), "not applicable — fixture")
	run := lmap(atom("__struct__"), atom("Elixir.Kogen.Run"), atom("id"), "abcd1234", atom("dir"), root+"/.kogen/local/runs/abcd1234", atom("log"), root+"/.kogen/local/runs/abcd1234/log.jsonl")
	zero := func() *legacyMap {
		return lmap(atom("input"), int64(0), atom("cached"), int64(0), atom("output"), int64(0), atom("reasoning"), int64(0))
	}
	approval := base64.StdEncoding.EncodeToString([]byte("approval"))
	state := func() *legacyMap {
		return lmap(atom("root"), root, atom("slug"), "example", atom("start"), "head", atom("git_index"), "index", atom("start_tree"), "tree",
			atom("approval_bytes"), approval, atom("run"), run, atom("config"), config, atom("intent"), intent, atom("model"), atom("none"),
			atom("phase"), atom("building"), atom("t0"), int64(0), atom("last_pass"), atom("nil"), atom("last_review"), atom("nil"),
			atom("blocker"), atom("nil"), atom("parent"), atom("nil"), atom("root_run"), atom("nil"),
			atom("baseline_digests"), lmap(project.ConfigPath, "digest"), atom("baseline"), []any{project.ConfigPath}, atom("excluded"), []any{},
			atom("round"), int64(1), atom("pass"), int64(1), atom("review"), int64(1), atom("repairs"), int64(0), atom("model_active_ms"), int64(0),
			atom("unknown_requests"), int64(0), atom("usage"), zero(), atom("attempt_usage"), zero(), atom("working_context"), lmap(),
			atom("source_provenance"), atom("nil"), atom("continuation"), lmap(atom("stage"), atom("builder"), atom("input"), []any{}))
	}
	encode := func(m *legacyMap) []byte {
		doc := map[string]any{"version": 3, "state": base64.StdEncoding.EncodeToString(legacyEncode(m)), "identity": "identity",
			"candidate": "tree", "index": base64.StdEncoding.EncodeToString([]byte("index")), "approval": approval}
		b, _ := json.Marshal(doc)
		return b
	}
	if _, why := decodeCheckpoint(encode(state()), legacyDecode); why != "" {
		t.Fatalf("the plain state is refused: %s", why)
	}
	legacy := legacyJSONBytes(t, map[string]any{"version": 2, "state": "x"})
	if _, why := decodeCheckpoint(legacy, legacyDecode); why != "incompatible checkpoint version 2" {
		t.Fatalf("version 2: %s", why)
	}
	noContext := state()
	legacyDelete(noContext, atom("working_context"))
	if _, why := decodeCheckpoint(encode(noContext), legacyDecode); why == "" {
		t.Fatal("a state without a working context is accepted")
	}

	session := lmap(atom("input"), []any{}, atom("attempts"), []any{}, atom("role"), lmap(atom("model"), "fixture", atom("effort"), "high"),
		atom("tools"), []any{}, atom("usage"), lmap())
	check := func(name, command string) *legacyMap {
		return lmap(atom("name"), name, atom("command"), command, atom("status"), int64(0), atom("output"), "")
	}
	passMap := func(extra ...any) *legacyMap {
		p := lmap(atom("green"), atom("true"), atom("clean"), atom("true"), atom("moved"), []any{}, atom("failing"), []any{},
			atom("acceptance"), lmap(atom("status"), int64(0), atom("problems"), []any{}, atom("passed"), int64(1),
				atom("scenarios"), []any{lmap(atom("line"), int64(2), atom("name"), "Complete", atom("status"), "passed")}),
			atom("model"), atom("none"), atom("checks"), []any{check("z-first", "true"), check("a-last", "true")},
			atom("n"), int64(1), atom("tree"), "tree")
		for i := 0; i < len(extra); i += 2 {
			legacyPut(p, extra[i], extra[i+1])
		}
		return p
	}
	current := func() *legacyMap {
		return passMap(atom("not_run"), []any{}, atom("setup"), []any{check("setup-1", "true")})
	}
	for name, evidence := range map[string]func() *legacyMap{"old": func() *legacyMap { return passMap() }, "current": current} {
		t.Run(name, func(t *testing.T) {
			with := func(last *legacyMap, continuation *legacyMap) *legacyMap {
				st := state()
				if last != nil {
					legacyPut(st, atom("last_pass"), last)
				}
				legacyPut(st, atom("continuation"), continuation)
				return st
			}
			review := func(p *legacyMap) *legacyMap {
				return lmap(atom("stage"), atom("review"), atom("pass"), p, atom("session"), session)
			}
			if _, why := decodeCheckpoint(encode(with(evidence(), review(evidence()))), legacyDecode); why != "" {
				t.Fatalf("the complete evidence is refused: %s", why)
			}
			cache := lmap("conversation", lmap(atom("id"), "conversation-id", atom("unsupported"), atom("true"), atom("response"), "resp_last"))
			good := with(evidence(), review(evidence()))
			legacyPut(good, atom("prompt_cache_states"), cache)
			loaded, why := decodeCheckpoint(encode(good), legacyDecode)
			if why != "" {
				t.Fatal(why)
			}
			eq(t, "cache", loaded.State.PromptCache["conversation"].ID+" "+loaded.State.PromptCache["conversation"].Response, "conversation-id resp_last")
			if !loaded.State.PromptCache["conversation"].Unsupported {
				t.Fatal("unsupported lost")
			}
			for _, damaged := range []any{atom("nil"), []any{}, lmap("key", lmap()),
				lmap("key", lmap(atom("id"), "id", atom("unsupported"), "false", atom("response"), atom("nil")))} {
				st := with(evidence(), review(evidence()))
				legacyPut(st, atom("prompt_cache_states"), damaged)
				if _, why := decodeCheckpoint(encode(st), legacyDecode); why == "" {
					t.Errorf("damaged cache states %#v are accepted", damaged)
				}
			}
			e := evidence()
			incomplete := map[string]*legacyMap{
				"not run":     func() *legacyMap { p := evidence(); legacyPut(p, atom("not_run"), []any{"a-last"}); return p }(),
				"no checks":   func() *legacyMap { p := evidence(); legacyPut(p, atom("checks"), []any{}); return p }(),
				"acceptance":  func() *legacyMap { p := evidence(); legacyPut(p, atom("acceptance"), atom("not_run")); return p }(),
				"empty setup": func() *legacyMap { p := evidence(); legacyPut(p, atom("setup"), []any{}); return p }(),
				"no setup": func() *legacyMap {
					p := evidence()
					legacyPut(p, atom("not_run"), []any{})
					legacyDelete(p, atom("setup"))
					return p
				}(),
				"not clean": func() *legacyMap { p := evidence(); legacyPut(p, atom("clean"), atom("false")); return p }(),
				"scenario": func() *legacyMap {
					p := evidence()
					legacyPut(legacyDigMap(t, p, atom("acceptance")), atom("scenarios"), []any{})
					return p
				}(),
				"checks wrong": func() *legacyMap {
					p := evidence()
					legacyPut(p, atom("checks"), slicesReversed(legacyDig(t, p, atom("checks")).([]any)))
					return p
				}(),
			}
			_ = e
			for what, p := range incomplete {
				if _, why := decodeCheckpoint(encode(with(p, lmap(atom("stage"), atom("builder"), atom("input"), []any{}))), legacyDecode); why == "" {
					t.Errorf("%s: an incomplete green pass in last_pass is accepted", what)
				}
				if _, why := decodeCheckpoint(encode(with(nil, review(p))), legacyDecode); why == "" {
					t.Errorf("%s: an incomplete green pass in the continuation is accepted", what)
				}
			}
		})
	}
}

// ---- fuzzing ----

func FuzzLegacyDecode(f *testing.F) {
	man := legacyLoadManifest(f)
	for name := range man.Cases {
		doc := legacyDoc(f, name)
		raw, _ := base64.StdEncoding.DecodeString(doc["state"].(string))
		f.Add(raw)
	}
	var rows map[string]string
	if err := json.Unmarshal([]byte(legacyGoldenRows), &rows); err != nil {
		f.Fatal(err)
	}
	for _, h := range rows {
		b, _ := hex.DecodeString(h)
		f.Add(b)
	}
	for _, g := range legacyGolden {
		b, _ := hex.DecodeString(g.hex)
		f.Add(b)
	}
	f.Fuzz(func(t *testing.T, data []byte) {
		term, err := legacyDecodeTerm(data)
		if err == nil {
			// What is read can be written and read again to the same term.
			again, err := legacyDecodeTerm(legacyEncode(term))
			if err != nil || legacyKey(again) != legacyKey(term) {
				t.Fatalf("a term that does not survive writing: %v", err)
			}
			legacyJSON(term)
		}
		// As the state of a checkpoint, it is accepted or refused with one of the two reasons.
		raw, _ := json.Marshal(map[string]any{"version": 3, "identity": "i", "candidate": "c", "index": "", "approval": "",
			"state": base64.StdEncoding.EncodeToString(data)})
		if _, err := legacyDecode(raw); err != nil && err.Error() != legacyMalformed && err.Error() != legacyDamaged {
			t.Fatalf("reason %q", err)
		}
	})
}
