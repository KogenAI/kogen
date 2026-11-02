package build

import (
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"

	"kogen/executor"
)

// testParter is a parter over source whose complete prompt is extra bytes of framing and the
// part's text (so a part's room is the ceiling less extra and its header).
func testParter(source string, blocks []materialSegment, ceiling, extra int) *reviewParter {
	return &reviewParter{
		source: source, sum: hashHex([]byte(source)), checks: "checks passed", catalog: `[{"path":"a.txt","status":"added"}]`,
		blocks: blocks, ceiling: ceiling, measure: func(dynamic string) int { return extra + len(dynamic) },
	}
}

// lines is n lines of exactly 50 bytes.
func lines(n int, fill string) string {
	return strings.Repeat(strings.Repeat(fill, 49)+"\n", n)
}

// exactly is a text of exactly n bytes made of 50-byte lines (the last one shorter), ending in a
// newline.
func exactly(n int, fill string) string {
	text := lines(n/50, fill)
	if rest := n % 50; rest > 0 {
		text += strings.Repeat(fill, rest-1) + "\n"
	}
	return text
}

func mustCut(t *testing.T, c *reviewParter) []reviewCut {
	t.Helper()
	cuts, err := c.cut()
	if err != nil {
		t.Fatal(err)
	}
	return cuts
}

// checkCover asserts the cuts are consecutive ranges whose concatenation is the whole source,
// and that every part's rendered complete prompt fits the ceiling.
func checkCover(t *testing.T, c *reviewParter, cuts []reviewCut) {
	t.Helper()
	at := 0
	var joined strings.Builder
	for i, cut := range cuts {
		if cut.From != at || cut.To <= cut.From {
			t.Fatalf("part %d is [%d, %d) after %d", i+1, cut.From, cut.To, at)
		}
		at = cut.To
		joined.WriteString(c.source[cut.From:cut.To])
	}
	if at != len(c.source) || joined.String() != c.source {
		t.Fatalf("the parts cover %d of %d bytes", at, len(c.source))
	}
	for i, text := range c.texts(cuts) {
		if got := c.measure(text); got > c.ceiling {
			t.Fatalf("part %d of %d has a %d-byte prompt over the %d-byte ceiling", i+1, len(cuts), got, c.ceiling)
		}
		if !strings.HasPrefix(text, "# Review part "+strconv.Itoa(i+1)+" of "+strconv.Itoa(len(cuts))+"\n") {
			t.Fatalf("part %d text starts %q", i+1, text[:40])
		}
	}
}

// A part is as long as possible: its complete prompt may equal the ceiling (equality fits) and
// one more byte would not.
func TestReviewPartsFitTheCeilingInclusively(t *testing.T) {
	source := strings.Repeat("a", 90000) // no newline: only the ceiling decides where a part ends
	c := testParter(source, nil, 20000, 1500)
	cuts := mustCut(t, c)
	checkCover(t, c, cuts)
	if len(cuts) < 5 {
		t.Fatalf("parts %v", cuts)
	}
	for i, cut := range cuts[:len(cuts)-1] {
		text := c.texts(cuts)[i]
		if got := c.measure(text); got != c.ceiling {
			t.Errorf("part %d prompt is %d bytes, want exactly the ceiling %d", i+1, got, c.ceiling)
		}
		if over := c.prompt(i+1, len(cuts), cut.From, cut.To+1); over <= c.ceiling {
			t.Errorf("part %d could take one more byte (%d)", i+1, over)
		}
	}
}

// Path material that fits one part is never split: at exactly the room of a part it stays
// whole, one byte larger it is split, after a newline.
func TestReviewPartsKeepPathMaterialWhole(t *testing.T) {
	const ceiling, extra, start = 10000, 0, 6000
	filler, tail := lines(start/50, "a"), lines(100, "t")
	build := func(block int) (*reviewParter, []materialSegment) {
		blocks := []materialSegment{{Path: "b.txt", Kind: "file", Start: start, End: start + block}}
		return testParter(filler+exactly(block, "b")+tail, blocks, ceiling, extra), blocks
	}
	probe, _ := build(9000)
	room := probe.maxTo(2, 9, start) - start

	for _, tc := range []struct {
		block int
		whole bool
	}{{room - 1, true}, {room, true}, {room + 1, false}} {
		c, _ := build(tc.block)
		cuts := mustCut(t, c)
		checkCover(t, c, cuts)
		if tc.whole {
			if cuts[0].To != start || cuts[1].From != start || cuts[1].To < start+tc.block {
				t.Errorf("block of %d (room %d) was split: %v", tc.block, room, cuts)
			}
			continue
		}
		if cuts[0].To <= start || cuts[0].To >= start+tc.block || c.source[cuts[0].To-1] != '\n' {
			t.Errorf("block of %d (room %d) was not split after a newline inside it: %v", tc.block, room, cuts)
		}
	}
}

// Path material without a final newline that ends exactly where a part's room ends stays whole
// in that part, rather than being split at its last newline.
func TestReviewPartsKeepMaterialEndingAtTheLimit(t *testing.T) {
	const total, ceiling, start = 30000, 10000, 3000
	limit := testParter(strings.Repeat("x", total), nil, ceiling, 0).maxTo(1, 9, 0)
	text := exactly(limit-start, "b")
	text = text[:len(text)-1] + "b"
	source := lines(start/50, "a") + text + "\n" + strings.Repeat("t", total-limit-1)
	c := testParter(source, []materialSegment{{Path: "b.txt", Kind: "file", Start: start, End: limit}}, ceiling, 0)
	cuts := mustCut(t, c)
	checkCover(t, c, cuts)
	if cuts[0].To != limit {
		t.Fatalf("the material [%d, %d) was split: %v", start, limit, cuts)
	}
}

// A line longer than the room of a part is split at a UTF-8 character boundary.
func TestReviewPartsSplitLongLinesAtCharacters(t *testing.T) {
	source := strings.Repeat("✓é€", 20000) // 3-, 2- and 3-byte characters, no newline
	c := testParter(source, nil, 15001, 700)
	cuts := mustCut(t, c)
	checkCover(t, c, cuts)
	if len(cuts) < 4 {
		t.Fatalf("parts %v", cuts)
	}
	for i, cut := range cuts {
		if !utf8.ValidString(source[cut.From:cut.To]) {
			t.Errorf("part %d [%d, %d) ends inside a character", i+1, cut.From, cut.To)
		}
	}
}

// Parts end just after a newline when one is within the room.
func TestReviewPartsEndAfterNewlines(t *testing.T) {
	c := testParter(lines(2000, "x"), nil, 20000, 900)
	cuts := mustCut(t, c)
	checkCover(t, c, cuts)
	for i, cut := range cuts[:len(cuts)-1] {
		if c.source[cut.To-1] != '\n' {
			t.Errorf("part %d ends mid-line", i+1)
		}
	}
}

// Room for one pinned source part (6000 bytes) proceeds in parts; one byte less stops.
func TestReviewPartsMinimumRoom(t *testing.T) {
	const ceiling = 100000
	c := testParter(lines(5000, "x"), nil, ceiling, 0)
	header := len(c.header(1, 1, 0, 0))
	for _, tc := range []struct {
		room int
		want bool
	}{{materialPartBytes, true}, {materialPartBytes - 1, false}, {materialPartBytes + 1, true}} {
		c := testParter(lines(5000, "x"), nil, ceiling, ceiling-tc.room-header)
		if got := c.hasRoom(); got != tc.want {
			t.Errorf("%d bytes of room: proceeds %v, want %v", tc.room, got, tc.want)
		}
		if got := c.ceiling - c.mandatory(); got != tc.room {
			t.Errorf("room %d, want %d", got, tc.room)
		}
	}
	// A part with no room at all is an error, never an endless cut.
	if _, err := testParter(lines(50, "x"), nil, 300, 0).cut(); err == nil {
		t.Fatal("a ceiling below the header cut parts")
	}
}

// reviewMeasure uses the executor's own report, and len(Stable)+len(Dynamic) without one.
func TestReviewMeasure(t *testing.T) {
	brief := executor.Brief{Stable: "abc", Dynamic: "defgh"}
	if got := reviewMeasure(newLineupExec(t), brief); got != 8 {
		t.Fatalf("measure without the method: %d", got)
	}
	if got := reviewMeasure(sizedExec{newLineupExec(t)}, brief); got != 1000+8 {
		t.Fatalf("measure with the method: %d", got)
	}
}

type sizedExec struct{ executor.Executor }

func (s sizedExec) FirstPromptBytes(role string, brief executor.Brief) int {
	if role != executor.RoleReview {
		return -1
	}
	return 1000 + len(brief.Stable) + len(brief.Dynamic)
}
