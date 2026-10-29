package tools

import (
	"fmt"
	"io"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"
)

// rangeFill is n bytes of newline-terminated filler lines (n >= 1).
func rangeFill(n int) string {
	var b strings.Builder
	for n > 64 {
		b.WriteString(strings.Repeat("f", 63) + "\n")
		n -= 64
	}
	if n > 0 {
		b.WriteString(strings.Repeat("f", n-1) + "\n")
	}
	return b.String()
}

// rangePage is a page of exactly total bytes with each text placed at its byte offset
// (the offsets ascend and leave room for filler, which keeps every text on its own line).
func rangePage(t *testing.T, total int, at map[int]string) string {
	t.Helper()
	offsets := make([]int, 0, len(at))
	for o := range at {
		offsets = append(offsets, o)
	}
	sort.Ints(offsets)
	var b strings.Builder
	for _, o := range offsets {
		if o < b.Len() || o > 0 && o-b.Len() < 1 && o != b.Len() {
			t.Fatalf("offset %d overlaps", o)
		}
		if o > b.Len() {
			b.WriteString(rangeFill(o - b.Len()))
		}
		b.WriteString(at[o])
	}
	if total < b.Len() {
		t.Fatalf("page %d is longer than %d", b.Len(), total)
	}
	if total > b.Len() {
		b.WriteString(rangeFill(total - b.Len()))
	}
	return b.String()
}

func rangeOrigin(t *testing.T, pages map[string]string) *fixtureOrigin {
	t.Helper()
	return newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
		io.WriteString(w, pages[r.URL.Path])
	})
}

func rangeFetch(t *testing.T, d Documentation, o *fixtureOrigin, path string, extra map[string]any) (map[string]any, string) {
	t.Helper()
	args := map[string]any{"operation": "fetch", "url": o.URL + path, "base": o.URL}
	for k, v := range extra {
		args[k] = v
	}
	out, text := lookup(t, d, args)
	if !utf8.ValidString(text) {
		t.Fatalf("result is not UTF-8")
	}
	return out, text
}

// rangeSource is the body without a synthetic untrusted marker prefix (the pages carry
// no marker themselves).
func rangeSource(out map[string]any) string {
	return strings.TrimPrefix(out["body"].(string), docMarker)
}

func rangeInt(t *testing.T, out map[string]any, key string) int {
	t.Helper()
	v, ok := out[key].(float64)
	if !ok {
		t.Fatalf("%s missing or not a number in %v", key, out)
	}
	return int(v)
}

func TestLDOCRangeFind(t *testing.T) {
	const heading = "## 1-hour cache duration\n"
	page := rangePage(t, 163840, map[int]string{
		2000:   "Note: the 1-hour cache duration is optional.\n",
		58229:  heading,
		90000:  "zebra-only prose mentions Needle-Text here.\n",
		120000: "## 1-Hour Cache Duration extended\n",
	})
	if len(page) != 163840 || page[58229:58229+len(heading)] != heading {
		t.Fatalf("fixture is wrong: %d", len(page))
	}
	o := rangeOrigin(t, map[string]string{"/p": page})
	d := Documentation{}

	out, text := rangeFetch(t, d, o, "/p", map[string]any{"find": "1-HOUR CACHE DURATION"})
	if len(text) > 16384 {
		t.Fatalf("result is %d bytes", len(text))
	}
	if out["status"] != "retrieved" || rangeInt(t, out, "body_offset") != 58229 || rangeInt(t, out, "body_total") != 163840 {
		t.Fatalf("heading find: %s", text[:300])
	}
	src := rangeSource(out)
	if !strings.HasPrefix(src, heading) || !strings.HasPrefix(page[58229:], src) {
		t.Fatalf("body does not start at the heading line: %q", src[:60])
	}
	if rangeInt(t, out, "next_offset") != 58229+len(src) {
		t.Fatalf("next_offset %v", out["next_offset"])
	}

	// A prose-only query starts at the line of its first match.
	out, _ = rangeFetch(t, d, o, "/p", map[string]any{"find": "needle-text"})
	if rangeInt(t, out, "body_offset") != 90000 || !strings.HasPrefix(rangeSource(out), "zebra-only prose") {
		t.Fatalf("prose find: offset %v", out["body_offset"])
	}

	// Matches before the offset are excluded: the later heading wins, then nothing.
	out, _ = rangeFetch(t, d, o, "/p", map[string]any{"find": "1-hour cache duration", "offset": 58229 + len(heading)})
	if rangeInt(t, out, "body_offset") != 120000 || !strings.HasPrefix(rangeSource(out), "## 1-Hour Cache Duration extended\n") {
		t.Fatalf("offset exclusion: %v", out["body_offset"])
	}
	// Without an offset the earlier prose match does not beat the first heading.
	out, _ = rangeFetch(t, d, o, "/p", map[string]any{"find": "Cache Duration", "offset": 0})
	if rangeInt(t, out, "body_offset") != 58229 {
		t.Fatalf("heading preference: %v", out["body_offset"])
	}
	// An empty find is absent: the plain offset applies.
	out, _ = rangeFetch(t, d, o, "/p", map[string]any{"find": "", "offset": 777})
	if rangeInt(t, out, "body_offset") != 777 {
		t.Fatalf("empty find: %v", out["body_offset"])
	}
}

func TestLDOCRangePaging(t *testing.T) {
	// "€" (3 bytes) occupies bytes 99998..100000; the next rune starts at 100001.
	page := rangePage(t, 163840, map[int]string{99998: "€\n"[:3]})
	page = page[:99998] + "€" + page[100001:]
	if len(page) != 163840 || !utf8.ValidString(page) || page[99998:100001] != "€" {
		t.Fatalf("fixture is wrong")
	}
	ascii := rangePage(t, 163840, nil)
	o := rangeOrigin(t, map[string]string{"/m": page, "/a": ascii})
	d := Documentation{}

	out, _ := rangeFetch(t, d, o, "/a", map[string]any{"offset": 100000})
	if rangeInt(t, out, "body_offset") != 100000 || !strings.HasPrefix(ascii[100000:], rangeSource(out)) {
		t.Fatalf("ASCII offset: %v", out["body_offset"])
	}
	for _, c := range []struct{ offset, want int }{
		{99998, 99998}, {99999, 99998}, {100000, 99998}, {100001, 100001},
		{0, 0}, {-5, 0}, {163840, 163840}, {999999, 163840},
	} {
		out, _ := rangeFetch(t, d, o, "/m", map[string]any{"offset": c.offset})
		src := rangeSource(out)
		if rangeInt(t, out, "body_offset") != c.want || rangeInt(t, out, "body_total") != 163840 || !strings.HasPrefix(page[c.want:], src) {
			t.Errorf("offset %d: body_offset %v want %d", c.offset, out["body_offset"], c.want)
		}
		if c.want == 163840 {
			if src != "" || out["next_offset"] != nil || out["truncated"] != false {
				t.Errorf("offset %d at the end: %v", c.offset, out)
			}
		}
	}

	var got strings.Builder
	offset, calls := 0, 0
	for {
		calls++
		if calls > 163840+1 {
			t.Fatal("paging did not finish")
		}
		out, _ := rangeFetch(t, d, o, "/m", map[string]any{"offset": offset})
		src := rangeSource(out)
		if rangeInt(t, out, "body_total") != 163840 || rangeInt(t, out, "body_offset") != offset || !utf8.ValidString(src) {
			t.Fatalf("page at %d: %v", offset, out["body_offset"])
		}
		got.WriteString(src)
		next, more := out["next_offset"]
		if !more {
			break
		}
		if int(next.(float64)) != offset+len(src) || len(src) == 0 {
			t.Fatalf("page at %d: next_offset %v after %d bytes", offset, next, len(src))
		}
		offset = int(next.(float64))
	}
	if got.String() != page {
		t.Fatalf("reconstruction differs (%d bytes)", got.Len())
	}
	if len(o.requests) < calls {
		t.Fatalf("expected one request per call")
	}
}

func TestLDOCRangeNotFound(t *testing.T) {
	page := rangePage(t, 163840, nil)
	o := rangeOrigin(t, map[string]string{"/p": page})
	out, _ := rangeFetch(t, Documentation{}, o, "/p", map[string]any{"find": "not present anywhere"})
	if out["status"] != "not_found" || out["body"] != "" || rangeInt(t, out, "body_total") != 163840 {
		t.Fatalf("not found: %v", out)
	}
	if note, _ := out["error"].(string); note == "" || len(note) > 80 {
		t.Fatalf("note %q", note)
	}
	if _, has := out["next_offset"]; has || out["url"] != o.URL+"/p" || out["untrusted"] != true || out["operation"] != "fetch" {
		t.Fatalf("metadata: %v", out)
	}
}

func TestLDOCRangeCompatibility(t *testing.T) {
	lines := ""
	for i := 0; len(lines) < 163840; i++ {
		lines += fmt.Sprintf("line %05d lorem ipsum\n", i)
	}
	lines = lines[:163840]
	hostile := "x\n" + docMarker + "\n" + strings.Repeat("h", 30000)
	origin := newFixtureOrigin(t, func(w http.ResponseWriter, r *http.Request, base string) {
		switch r.URL.Path {
		case "/big":
			io.WriteString(w, lines)
		case "/hostile":
			io.WriteString(w, hostile)
		case "/search":
			fmt.Fprintf(w, `{"sources":[{"url":"%s/a","title":"A"}]}`, base)
		default:
			io.WriteString(w, "small\n")
		}
	})
	d := Documentation{}
	base := origin.URL
	fetch := func(path string) (map[string]any, string) {
		return lookup(t, d, map[string]any{"operation": "fetch", "url": base + path, "base": base})
	}

	// Bodies pinned from the implementation before ranged reads existed.
	_, text := fetch("/s")
	want := `{"body":"small\n","body_total":6,"error":"","operation":"fetch","query":"","sources":[],"status":"retrieved","truncated":false,"untrusted":true,"url":"` + base + `/s"}`
	if text != want {
		t.Errorf("small: %s", text)
	}
	out, _ := fetch("/big")
	if out["body"] != docMarker+lines[:10215] || out["truncated"] != true || rangeInt(t, out, "body_total") != 163840 || rangeInt(t, out, "next_offset") != 10215 {
		t.Errorf("big: %d bytes of body, next %v", len(out["body"].(string)), out["next_offset"])
	}
	if _, has := out["body_offset"]; has {
		t.Errorf("plain fetch reports body_offset")
	}
	out, _ = fetch("/hostile")
	if out["body"] != hostile[:15015] || out["status"] != "untrusted" || out["error"] != docUntrusted || out["truncated"] != true ||
		rangeInt(t, out, "body_total") != len(hostile) || rangeInt(t, out, "next_offset") != 15015 {
		t.Errorf("hostile: %v", out["next_offset"])
	}
	if _, has := out["body_offset"]; has {
		t.Errorf("plain hostile fetch reports body_offset")
	}
	// Continuation calls are one request each.
	before := len(origin.requests)
	out, _ = fetch("/big")
	for i := 0; i < 2; i++ {
		out, _ = lookup(t, d, map[string]any{"operation": "fetch", "url": base + "/big", "base": base, "offset": out["next_offset"]})
	}
	if n := len(origin.requests) - before; n != 3 {
		t.Errorf("%d origin requests for 3 fetches", n)
	}

	search, _ := lookup(t, d, map[string]any{"operation": "search", "query": "hit", "base": base})
	wantSearch := map[string]any{
		"operation": "search", "status": "retrieved", "query": "hit", "url": "", "body": "", "error": "",
		"untrusted": false, "truncated": false,
		"sources": []any{map[string]any{"url": base + "/a", "title": "A"}},
	}
	if !reflect.DeepEqual(search, wantSearch) {
		t.Errorf("search changed: %v", search)
	}
	// Non-retrieved fetches still report body_total zero.
	out, _ = lookup(t, d, map[string]any{"operation": "fetch", "url": "ftp://x/y"})
	if out["status"] != "unsupported" || rangeInt(t, out, "body_total") != 0 {
		t.Errorf("unsupported fetch: %v", out)
	}
}

// Paging a marked page under the fixed 16384-byte result bound reconstructs the whole body,
// and a late slice of a clean page stays retrieved.
func TestLDOCRangeFixedBounds(t *testing.T) {
	quotes := strings.Repeat(`"`, 3000) + "\n"
	page := rangePage(t, 163840, map[int]string{0: quotes, 60000: docMarker + "\n", 100000: "late\n"})
	clean := rangePage(t, 163840, nil)
	o := rangeOrigin(t, map[string]string{"/p": page, "/c": clean})
	d := Documentation{}
	offset := 0
	var got strings.Builder
	for {
		out, text := rangeFetch(t, d, o, "/p", map[string]any{"offset": offset})
		if len(text) > docOutputLimit {
			t.Fatalf("result is %d bytes", len(text))
		}
		src := rangeSource(out)
		if rangeInt(t, out, "body_total") != len(page) || rangeInt(t, out, "body_offset") != offset || out["untrusted"] != true {
			t.Fatalf("at %d: %v", offset, out["body_total"])
		}
		// The marker lies inside the page, so the page is marked even where the selected
		// slice misses it.
		if out["status"] != "untrusted" || out["error"] != docUntrusted {
			t.Fatalf("at %d: status %v", offset, out["status"])
		}
		got.WriteString(src)
		next, more := out["next_offset"]
		if !more {
			break
		}
		if int(next.(float64)) != offset+len(src) || len(src) == 0 {
			t.Fatalf("at %d: no progress", offset)
		}
		offset = int(next.(float64))
	}
	if got.String() != page {
		t.Fatalf("reconstruction differs (%d bytes)", got.Len())
	}
	out, _ := rangeFetch(t, d, o, "/c", map[string]any{"offset": 170000})
	if out["status"] != "retrieved" || rangeInt(t, out, "body_offset") != len(clean) || out["body"] != "" {
		t.Fatalf("clamped offset: %v", out)
	}
	out, _ = rangeFetch(t, d, o, "/c", map[string]any{"offset": 100000})
	if out["status"] != "retrieved" || rangeInt(t, out, "body_offset") != 100000 {
		t.Fatalf("late slice of a clean page: %v", out["status"])
	}
}
