package build

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"kogen-loop/tools"
	"kogen/agent"
	"kogen/executor"
)

// An external reviewer's first prompt is measured, source included, against the inclusive input
// ceiling the native reviewer already uses (tools.InputBudgetBytes). A prompt that fits is one
// review in one session. A larger one is cut into ordered parts of the exact review source, each
// reviewed in its own fresh session whose complete prompt fits; mandatory material that leaves
// no room for source stops before anything is sent.

// reviewTask is what the external reviewer is asked, besides the authority and the source.
const reviewTask = "# Review task\n\n" +
	"Review the candidate above against the approved Intent. The complete authority, the check results, the diff and the full text of every changed file are included in this message; they are Kogen's exact data for this candidate.\n" +
	reviewTaskTail

// reviewPartsTask replaces reviewTask's first paragraph when the source is reviewed in parts; it is
// the same for every part.
const reviewPartsTask = "# Review task\n\n" +
	"The candidate's source does not fit one review prompt, so it is reviewed in ordered parts, each by its own independent session. This message carries the complete authority and one part: the check results, every changed path and one consecutive piece of the exact diff and full text of changed files, nothing clipped; the other pieces go to the other parts' sessions. Review against the approved Intent with this part as your focus and read any checkout file you need. Reviewers of earlier parts may have made verified repairs, so the checkout holds the current candidate.\n" +
	reviewTaskTail

const reviewTaskTail = "Repair concrete defects within the approved Intent with your tools; protected paths cannot be edited. Maintenance preferences are non-blocking notes.\n" +
	agent.LimitRaises + "\n" +
	"Finish with the structured verdict: verdict approve or changes, and findings {path, line, severity blocking|note, message}. A changes verdict needs a blocking finding; an approve verdict has none. Kogen verifies any contents you changed and tells you the actual results."

// reviewCeiling is the inclusive ceiling of one external review prompt.
const reviewCeiling = tools.InputBudgetBytes

// reviewCut is the byte range [From, To) of the review source one part carries.
type reviewCut struct{ From, To int }

// reviewPartHeader is everything of part k of n's text before its slice: its position, the
// source range it carries, the check results of the pass the source was cut from, every changed
// path (the catalog as one JSON line) and the heading of the slice.
func reviewPartHeader(k, n, from, to, total int, sum, checks, catalog string) string {
	return fmt.Sprintf("# Review part %d of %d\n\n"+
		"This part carries bytes [%d, %d) of the %d bytes of the candidate's complete review source (SHA-256 %s); the other parts carry the rest, in order.\n\n"+
		"# Check results of the final pass\n\n%s\n\n"+
		"# Every changed path\n\n%s\n\n"+
		"# Source part %d of %d\n\n", k, n, from, to, total, sum, checks, catalog, k, n)
}

// reviewParter cuts the review source into parts that each fit the ceiling.
type reviewParter struct {
	source  string
	sum     string
	checks  string
	catalog string
	// blocks are the byte ranges of the source holding one path's material: its block in the diff
	// and its heading and full text, in source order.
	blocks []materialSegment
	// measure is the executor's exact first-prompt length for the review brief with this dynamic
	// text and the parts' stable text.
	measure func(dynamic string) int
	ceiling int
}

func (c *reviewParter) header(k, n, from, to int) string {
	return reviewPartHeader(k, n, from, to, len(c.source), c.sum, c.checks, c.catalog)
}

// prompt is the complete first prompt of part k of n carrying source[from:to].
func (c *reviewParter) prompt(k, n, from, to int) int {
	return c.measure(c.header(k, n, from, to)) + (to - from)
}

// mandatory is the prompt bytes that are not source: the complete first prompt of a first part
// with an empty slice.
func (c *reviewParter) mandatory() int { return c.prompt(1, 1, 0, 0) }

// hasRoom reports whether the mandatory prompt leaves at least one pinned source part
// (materialPartBytes) under the ceiling for source.
func (c *reviewParter) hasRoom() bool { return c.ceiling-c.mandatory() >= materialPartBytes }

// maxTo is the largest end of a part that starts at from such that its complete prompt fits the
// ceiling (equality fits), or -1 when even an empty slice does not.
func (c *reviewParter) maxTo(k, n, from int) int {
	if c.prompt(k, n, from, from) > c.ceiling {
		return -1
	}
	lo, hi := from, len(c.source)
	for lo < hi {
		mid := lo + (hi-lo+1)/2
		if c.prompt(k, n, from, mid) <= c.ceiling {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// cut is the parts, in order, each as long as possible such that (a) its complete prompt fits the
// ceiling; (b) it does not end inside one path's material when that material alone would fit one
// part; (c) otherwise it ends just after a newline when one is available within the room, else at
// a UTF-8 character boundary.
func (c *reviewParter) cut() ([]reviewCut, error) {
	// A part's header names the number of parts, which the cut itself decides: take the least
	// number of digits that the resulting count fits.
	for digits, n := 1, 9; ; digits, n = digits+1, n*10+9 {
		cuts, err := c.cutAssuming(n)
		if err != nil {
			return nil, err
		}
		if len(strconv.Itoa(len(cuts))) <= digits {
			return cuts, nil
		}
	}
}

func (c *reviewParter) cutAssuming(n int) ([]reviewCut, error) {
	var cuts []reviewCut
	for from := 0; from < len(c.source); {
		k := len(cuts) + 1
		limit := c.maxTo(k, n, from)
		if limit <= from {
			return nil, fmt.Errorf("part %d has no room for source: its complete prompt without source is %d bytes", k, c.prompt(k, n, from, from))
		}
		to := limit
		if limit < len(c.source) {
			to = c.endBefore(k, n, from, limit)
		}
		cuts = append(cuts, reviewCut{from, to})
		from = to
	}
	return cuts, nil
}

// endBefore is where the part of k of n starting at from ends when its complete prompt allows
// source up to limit, which is short of the end of the source.
func (c *reviewParter) endBefore(k, n, from, limit int) int {
	// (b) A path's material that straddles the limit and would fit the next part whole starts it.
	for _, blk := range c.blocks {
		if blk.Start < limit && limit < blk.End && blk.Start > from && blk.End <= c.maxTo(k+1, n, blk.Start) {
			return blk.Start
		}
		// A path's material that ends exactly at the limit (a text without a final newline) is
		// kept whole: an earlier newline would end the part inside it.
		if blk.End == limit && blk.Start >= from {
			return limit
		}
	}
	// (c) After the last newline of the room, else at a character boundary.
	if i := strings.LastIndexByte(c.source[from:limit], '\n'); i >= 0 {
		return from + i + 1
	}
	to := limit
	for to > from+1 && !utf8.RuneStart(c.source[to]) {
		to--
	}
	return to
}

// texts renders the parts' dynamic texts: each part's header, then its exact slice.
func (c *reviewParter) texts(cuts []reviewCut) []string {
	out := make([]string, len(cuts))
	for i, cut := range cuts {
		out[i] = c.header(i+1, len(cuts), cut.From, cut.To) + c.source[cut.From:cut.To]
	}
	return out
}

// reviewBlocks locates each changed path's material in the review source: its block in the diff
// (from its `diff --git` line to the next block or the end of the diff) and its `--- <path>`
// heading with its full text (to the next heading or the end), in source order.
func (b *Attempt) reviewBlocks(tree string, m materialSet) ([]materialSegment, error) {
	_, segments, _, err := b.materialManifest(tree, m.Files, m.texts, m.Source)
	if err != nil {
		return nil, err
	}
	heading := map[string]int{}
	for _, t := range m.texts {
		heading[t.path] = len(t.heading)
	}
	for i, seg := range segments {
		if seg.Kind == "file" {
			segments[i].Start -= heading[seg.Path]
		}
	}
	slices.SortFunc(segments, func(a, b materialSegment) int { return a.Start - b.Start })
	return segments, nil
}

// reviewMeasure is the exact length of the first prompt an executor sends for the review role
// and a brief: its own report when it gives one, otherwise the length of its two texts.
func reviewMeasure(exec executor.Executor, brief executor.Brief) int {
	if p, ok := exec.(executor.PromptSizer); ok {
		return p.FirstPromptBytes(executor.RoleReview, brief)
	}
	return len(brief.Stable) + len(brief.Dynamic)
}
