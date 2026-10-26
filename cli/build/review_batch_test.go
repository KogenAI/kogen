package build

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	agent "kogen-loop/tools"
)

// A reviewer that asks for many pinned source parts in ONE response leaves an unsplittable call
// batch with all its outputs in the newest exchange. When mandatory authority, catalog and the
// reset fit but that whole batch does not, the reads that have not reached the model yet are
// deferred natively (never counted as delivered) instead of refusing the review, and every
// resume of the checkpoint that saved the full batch recovers the same way.

const (
	batchFrom = 100 // first pinned part of the batch (0-based)
	batchSize = 20  // parallel read_file calls of one response
)

// batchHeadroom leaves a window of this many bytes beyond the bounded opening: enough for the
// reset and some, but far from all, of the batch.
func batchHeadroom(int) int { return 60_000 }

// batchStaged is a pinned review that has completed one window: five parts delivered, archived
// by the first reset. got1 is the input that reset kept.
func batchStaged(t *testing.T) (*budgetScenario, []any) {
	t.Helper()
	s := budgetPinned(t, batchHeadroom)
	got1, err := s.b.prepareContext("review", s.role, "policy", s.input(t, 1_000), nil)
	if err != nil {
		t.Fatal(err)
	}
	return s, got1
}

// batch is one assistant response of k parallel read_file calls of consecutive pinned parts and
// the complete outputs of those calls (calls first, then outputs, as one exchange).
func (s *budgetScenario) batch(t *testing.T, from, k int) (items []any, outputs []string) {
	t.Helper()
	tools := &agent.Tools{Root: s.b.Root, Enabled: []string{"read_file"}}
	var calls, answers []any
	for i := from; i < from+k; i++ {
		id := "batch-" + itoa(i)
		out, err := tools.Run("read_file", map[string]any{"path": s.parts[i].Path})
		if err != nil {
			t.Fatal(err)
		}
		calls = append(calls, map[string]any{
			"type": "function_call", "call_id": id, "name": "read_file",
			"arguments": jsonText(map[string]any{"path": s.parts[i].Path}),
		})
		answers = append(answers, map[string]any{"type": "function_call_output", "call_id": id, "output": out.Text})
		outputs = append(outputs, out.Text)
	}
	return slices.Concat(calls, answers), outputs
}

const batchDeferredPrefix = "not delivered: pinned review source part "

// batchOutputs are the outputs of the batch in the tail of a request, in call order.
func batchOutputs(t *testing.T, input []any, k int) []string {
	t.Helper()
	var out []string
	for _, it := range input[len(input)-k:] {
		m, _ := it.(map[string]any)
		if m["type"] != "function_call_output" {
			t.Fatalf("not an output: %v", m)
		}
		text, _ := m["output"].(string)
		out = append(out, text)
	}
	return out
}

func batchPaths(s *budgetScenario, from, k int) []string {
	var paths []string
	for _, ref := range s.parts[from : from+k] {
		paths = append(paths, ref.Path)
	}
	return paths
}

// batchExpect is the shared check of a recovered batch window: got is the request the recovery
// returned for input.
func batchExpect(t *testing.T, s *budgetScenario, got []any, full []string, unreadBefore []string) {
	t.Helper()
	b, role := s.b, s.role
	n := len(s.parts)
	if m := budgetMeasure(t, b, role, got); !m.Fits || m.RenderedBytes > agent.InputBudgetBytes {
		t.Fatalf("the reduced request does not fit: %+v", m)
	}
	eq(t, "mandatory opening kept", reflect.DeepEqual(got[:len(s.opening)], s.opening), true)

	// Calls are unchanged; the outputs are the exact originals up to the first deferral and the
	// native deferral from there on (a suffix, last first).
	calls := got[len(got)-2*batchSize : len(got)-batchSize]
	for i, it := range calls {
		m, _ := it.(map[string]any)
		eq(t, "call id", m["call_id"], any("batch-"+itoa(batchFrom+i)))
		eq(t, "call name", m["name"], any("read_file"))
	}
	outputs := batchOutputs(t, got, batchSize)
	first := batchSize
	for i, out := range outputs {
		if strings.HasPrefix(out, batchDeferredPrefix) {
			first = min(first, i)
			continue
		}
		if first < batchSize {
			t.Fatalf("output %d is delivered after a deferred one: not a suffix", i)
		}
		eq(t, "kept output", out, full[i])
	}
	if first == 0 || first == batchSize {
		t.Fatalf("deferred from %d of %d: nothing proven", first, batchSize)
	}
	var deferredParts []any
	for i := first; i < batchSize; i++ {
		number := batchFrom + i + 1
		eq(t, "deferral text", outputs[i], batchDeferredPrefix+itoa(number)+" did not fit this working window "+
			"with the mandatory authority and catalog; it is not counted as read. Read it again with read_file in a "+
			"later response; keep batching unread parts (about 10 per response), using fewer per response only as needed to fit.")
		deferredParts = append(deferredParts, float64(number))
	}

	// The archive of this reset is what was sent: deferred outputs are substituted, never full.
	state := b.WorkingContext["review"]
	eq(t, "history length", len(state.History), n+2)
	archive := state.History[n+1]
	archiveOK(t, archive)
	data, err := os.ReadFile(archive.Path)
	if err != nil {
		t.Fatal(err)
	}
	for i := first; i < batchSize; i++ {
		if strings.Contains(string(data), jsonText(full[i])) {
			t.Fatalf("the archive holds the full text of deferred part %d", batchFrom+i+1)
		}
	}
	var doc struct {
		Input []map[string]any `json:"input"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	archived := map[string]string{}
	for _, it := range doc.Input {
		if it["type"] == "function_call_output" {
			archived[it["call_id"].(string)], _ = it["output"].(string)
		}
	}
	for i, out := range outputs {
		eq(t, "archived output "+itoa(i), archived["batch-"+itoa(batchFrom+i)], out)
	}

	// Delivery: the earlier window's parts stay delivered, the kept batch parts are delivered,
	// the deferred ones stay unread; no part is credited that the model never received.
	unread, err := b.materialUnread(got)
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	deferred := batchPaths(s, batchFrom+first, batchSize-first)
	kept := batchPaths(s, batchFrom, first)
	for _, path := range unreadBefore {
		if !slices.Contains(kept, path) {
			want = append(want, path)
		}
	}
	slices.Sort(want)
	eq(t, "unread after the reset", unread, want)
	for _, path := range deferred {
		if !slices.Contains(unread, path) {
			t.Fatalf("deferred %s is credited as delivered", path)
		}
	}
	for _, path := range slices.Concat(kept, batchPaths(s, 0, budgetReads)) {
		if slices.Contains(unread, path) {
			t.Fatalf("delivered %s is unread", path)
		}
	}

	reset := handoffOf(t, got)
	note := reset["deferred_reads"].(map[string]any)
	eq(t, "deferred parts", note["parts"].([]any), deferredParts)
	eq(t, "deferred note", note["note"], any("native: these reads did not fit this window and are not counted; read them again"))
	source := reset["review_delivery"].(map[string]any)["source"].(map[string]any)
	eq(t, "delivered", source["delivered"], any(float64(budgetReads+first)))
	eq(t, "unread listed", len(source["unread"].([]any)), n-budgetReads-first)
	for _, part := range deferredParts {
		if !slices.Contains(source["unread"].([]any), part) {
			t.Fatalf("deferred part %v is not listed unread", part)
		}
	}
	eq(t, "history in catalog", reset["history_in_catalog"].(map[string]any)["count"], any(float64(n)))
	if err := b.validateWorkingContext(); err != nil {
		t.Fatal(err)
	}
}

func TestReviewBatchDefersUndeliveredPinnedReadsThatDoNotFit(t *testing.T) {
	t.Parallel()
	s, got1 := batchStaged(t)
	b, role := s.b, s.role
	ceiling := agent.InputBudgetBytes
	unreadBefore, err := b.materialUnread(got1)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "unread before", len(unreadBefore), len(s.parts)-budgetReads)

	batch, full := s.batch(t, batchFrom, batchSize)
	input := slices.Concat(got1, batch)

	// The live failure: the mandatory opening fits, the opening with the whole batch does not
	// (so mandatory + reset + the batch, the old reduced request, could not), yet a small part of
	// the batch does.
	if s.openingBytes > ceiling-batchHeadroom(0) {
		t.Fatalf("the opening %d leaves no window", s.openingBytes)
	}
	if m := budgetMeasure(t, b, role, slices.Concat(s.opening, batch)); m.Fits {
		t.Fatalf("the opening with the whole batch fits: %+v", m)
	}
	if budgetMeasure(t, b, role, input).Fits {
		t.Fatal("the input is not over budget")
	}
	one := []any{batch[0], batch[batchSize]}
	if m := budgetMeasure(t, b, role, slices.Concat(s.opening, one)); !m.Fits {
		t.Fatalf("not even one read of the batch fits: %+v", m)
	}

	got, err := b.prepareContext("review", role, "policy", input, nil)
	if err != nil {
		t.Fatalf("the batch is refused: %v", err)
	}
	batchExpect(t, s, got, full, unreadBefore)
	// The caller's input is never changed.
	eq(t, "caller output", batchOutputs(t, input, batchSize), full)
}

func TestReviewBatchResumeReplaysTheSavedInputAndRecoversTheSameWay(t *testing.T) {
	t.Parallel()
	s, got1 := batchStaged(t)
	b, role := s.b, s.role
	unreadBefore, err := b.materialUnread(got1)
	if err != nil {
		t.Fatal(err)
	}
	batch, full := s.batch(t, batchFrom, batchSize)
	input := slices.Concat(got1, batch)

	// The checkpoint (stage review) saved this input with the full executed outputs, never sent;
	// resume loads it from JSON and the converse's first request goes through prepareContext.
	raw, err := encodeJSON(map[string]any{"input": input})
	if err != nil {
		t.Fatal(err)
	}
	v, err := decodeJSONNumbers(raw)
	if err != nil {
		t.Fatal(err)
	}
	saved := v.(map[string]any)["input"].([]any)
	got, err := b.prepareContext("review", role, "policy", saved, nil)
	if err != nil {
		t.Fatalf("the resumed batch is refused: %v", err)
	}
	batchExpect(t, s, got, full, unreadBefore)

	// What Request retains is the substituted input: another request over it needs no reset.
	again, err := b.prepareContext("review", role, "policy", got, nil)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "retained input is a fixed point", reflect.DeepEqual(again, got), true)
	eq(t, "history unchanged", len(b.WorkingContext["review"].History), len(s.parts)+2)
}

func TestReviewBatchNonPinnedOverflowStillRefusesWithoutAnArchive(t *testing.T) {
	t.Parallel()
	s := budgetPinned(t, batchHeadroom)
	b, role := s.b, s.role
	pinned, full := s.batch(t, batchFrom, 3)
	calls, answers := pinned[:3], pinned[3:]
	big := strings.Repeat("y", 150_000)
	calls = append(slices.Clone(calls), map[string]any{
		"type": "function_call", "call_id": "big", "name": "read_file", "arguments": jsonText(map[string]any{"path": "pad.txt"}),
	})
	answers = append(slices.Clone(answers), map[string]any{"type": "function_call_output", "call_id": "big", "output": big})
	input := slices.Concat(s.opening, s.reads(t), calls, answers)
	before := slices.Clone(b.WorkingContext["review"].History)

	_, err := b.prepareContext("review", role, "policy", input, nil)
	if err == nil {
		t.Fatal("an overflow from an ordinary file is accepted")
	}
	for _, part := range []string{"candidate/context_budget_exceeded: review: measured ", "mandatory ", "ceiling 524288, output reserve 131072 tokens"} {
		contains(t, "error", err.Error(), part)
	}
	if _, err := os.Stat(filepath.Join(b.Run.Dir, "working-context")); !os.IsNotExist(err) {
		t.Fatal("an archive was written")
	}
	if !slices.Equal(b.WorkingContext["review"].History, before) {
		t.Fatal("history changed by a refused reset")
	}
	// Neither the pinned nor the ordinary outputs were touched in the caller's input.
	eq(t, "pinned outputs", batchOutputs(t, input[len(input)-4:len(input)-1], 3), full)
	eq(t, "ordinary output", batchOutputs(t, input[len(input)-1:], 1), []string{big})
}

func TestReviewBatchResetThatFitsDefersNothingAndKeepsItsBytes(t *testing.T) {
	t.Parallel()
	s := budgetPinned(t, batchHeadroom)
	b, role := s.b, s.role
	input := s.input(t, 1_000)
	got, err := b.prepareContext("review", role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	reset := handoffOf(t, got)
	if _, ok := reset["deferred_reads"]; ok {
		t.Fatalf("a window that fits deferred reads: %v", reset["deferred_reads"])
	}
	n := len(s.parts)
	state := b.WorkingContext["review"]
	eq(t, "history length", len(state.History), n+1)
	// The archive is exactly the input that was replaced.
	want, err := encodeJSON(map[string]any{"input": input})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(state.History[n].Path)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "archive bytes", string(data), string(want)+"\n")
	archiveOK(t, state.History[n])
	eq(t, "newest exchange kept", reflect.DeepEqual(got[len(got)-2:], input[len(input)-2:]), true)
	source := reset["review_delivery"].(map[string]any)["source"].(map[string]any)
	eq(t, "delivered", source["delivered"], any(float64(budgetReads)))
}

func TestReviewBatchOnlyCompleteUndeliveredPinnedReadsAreCandidates(t *testing.T) {
	t.Parallel()
	s, got1 := batchStaged(t)
	b := s.b
	tools := &agent.Tools{Root: b.Root, Enabled: []string{"read_file"}}
	read := func(i int) string {
		out, err := tools.Run("read_file", map[string]any{"path": s.parts[i].Path})
		if err != nil {
			t.Fatal(err)
		}
		return out.Text
	}
	rel, err := filepath.Rel(b.Root, s.parts[101].Path)
	if err != nil {
		t.Fatal(err)
	}
	call := func(id, name, path string) any {
		return map[string]any{"type": "function_call", "call_id": id, "name": name, "arguments": jsonText(map[string]any{"path": path})}
	}
	answer := func(id, text string) any {
		return map[string]any{"type": "function_call_output", "call_id": id, "output": text}
	}
	// An unread part read completely in an EARLIER exchange of this window is not the newest's.
	earlier := []any{call("old", "read_file", s.parts[105].Path), answer("old", read(105))}
	truncated := read(102)[:100]
	newest := []any{
		call("a", "read_file", s.parts[100].Path), // complete, absolute: candidate
		call("b", "read_file", rel),               // complete, relative: candidate
		call("c", "read_file", s.parts[0].Path),   // delivered by an archived window: no
		call("d", "read_file", s.parts[102].Path), // partial text: no
		call("e", "read_file", "pad.txt"),         // another file: no
		call("f", "run_shell", s.parts[103].Path), // not read_file: no
		call("g", "read_file", s.parts[104].Path), // output of another part: no
		answer("a", read(100)), answer("b", read(101)), answer("c", read(0)), answer("d", truncated),
		answer("e", read(103)), answer("f", read(103)), answer("g", read(103)),
	}
	input := slices.Concat(got1, earlier, newest)
	got, custody, err := b.deferrable(input)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("candidates %+v", got)
	}
	start := len(got1) + len(earlier) + 7
	eq(t, "first index", got[0].index, start)
	eq(t, "second index", got[1].index, start+1)
	eq(t, "first path", got[0].path, s.parts[100].Path)
	eq(t, "second path", got[1].path, s.parts[101].Path)
	eq(t, "first item", got[0].item["call_id"], any("a"))
	eq(t, "first type", got[0].item["type"], any("function_call_output"))
	contains(t, "first text", got[0].item["output"].(string), batchDeferredPrefix+"101 did not fit")
	contains(t, "second text", got[1].item["output"].(string), batchDeferredPrefix+"102 did not fit")
	// The deferred numbers are the ones the substituted input does not deliver.
	sub := slices.Clone(input)
	sub[got[0].index], sub[got[1].index] = got[0].item, got[1].item
	eq(t, "deferred parts", custody.deferredParts(b.Root, sub, got), []int{101, 102})
	// A part read completely again in the same exchange is delivered, not deferred.
	again := slices.Clone(sub)
	again[got[1].index] = answer("b", read(101))
	eq(t, "re-read", custody.deferredParts(b.Root, again, got[1:]), []int{})
}
