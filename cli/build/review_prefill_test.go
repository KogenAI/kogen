package build

import (
	"encoding/json"
	"os"
	"reflect"
	"slices"
	"strings"
	"testing"

	agent "kogen-loop/tools"
)

// Native deterministic transport of pinned review source: Kogen itself appends the next unread
// pinned parts, complete and in catalog order, as a clearly labelled data message into the spare
// budget of a review request, so that no model round trip is needed just to request them. A part
// counts as delivered only when a model output follows the message in the same window (the
// provider returned a completed continuation for the request that carried it); a pending message,
// altered text, another review or another marker never counts.

// prefillHeadroom leaves the bounded opening 150000 bytes under the ceiling: room for the 32768
// byte safety margin and a few (but far from all) of the 686 pinned parts.
func prefillHeadroom(int) int { return 150_000 }

func prefillScenario(t *testing.T) *budgetScenario {
	t.Helper()
	return budgetPinned(t, prefillHeadroom)
}

// prefillCase is one named item of a table.
type prefillCase struct {
	name string
	item any
}

// prefillNext is the prefill of input, and the message it appended (nil: nothing appended).
func prefillNext(t *testing.T, s *budgetScenario, input []any) ([]any, any) {
	t.Helper()
	out, err := s.b.prefillSource(s.role, "policy", nil, input)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) == len(input) {
		return out, nil
	}
	eq(t, "one message appended", len(out), len(input)+1)
	eq(t, "the input is kept as it was", reflect.DeepEqual(out[:len(input)], input), true)
	return out, out[len(out)-1]
}

type prefillPart struct {
	Part int    `json:"part"`
	Path string `json:"path"`
	Read string `json:"read"`
}

func prefillParts(t *testing.T, msg any) []prefillPart {
	t.Helper()
	m, _ := msg.(map[string]any)
	text, _ := m["content"].(string)
	body, ok := strings.CutPrefix(text, prefillMarker+"\n")
	if !ok || m["role"] != "user" {
		t.Fatalf("not a prefill message: %.80v", text)
	}
	var doc struct {
		Version int           `json:"version"`
		Review  int           `json:"review"`
		Parts   []prefillPart `json:"parts"`
	}
	if err := json.Unmarshal([]byte(body), &doc); err != nil {
		t.Fatal(err)
	}
	eq(t, "version", doc.Version, 1)
	eq(t, "review", doc.Review, 1)
	return doc.Parts
}

// prefillForged is a message of the native shape carrying the given entries for a review.
func prefillForged(t *testing.T, review int, parts []prefillPart) any {
	t.Helper()
	list := make([]any, len(parts))
	for i, p := range parts {
		list[i] = map[string]any{"part": p.Part, "path": p.Path, "read": p.Read}
	}
	msg, err := prefillMessage(review, list)
	if err != nil {
		t.Fatal(err)
	}
	return msg
}

// prefillExact is the exact entry of the i-th (0-based) pinned part.
func prefillExact(c *reviewCustody, s *budgetScenario, i int) prefillPart {
	return prefillPart{Part: i + 1, Path: s.parts[i].Path, Read: c.sources[s.parts[i].Path]}
}

func prefillModel(id string) []any { return budgetPad(id, 10) }

// prefillUnread is the unread parts as a set, the way the approval check lists them.
func prefillUnread(t *testing.T, b *Attempt, input []any) map[string]bool {
	t.Helper()
	unread, err := b.materialUnread(input)
	if err != nil {
		t.Fatal(err)
	}
	set := map[string]bool{}
	for _, path := range unread {
		set[path] = true
	}
	eq(t, "no duplicate", len(set), len(unread))
	return set
}

func prefillPaths(parts []prefillPart) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p.Path)
	}
	return out
}

// prefillSaved is the input as a resumed run loads it: through JSON, numbers kept.
func prefillSaved(t *testing.T, input []any) []any {
	t.Helper()
	raw, err := encodeJSON(map[string]any{"input": input})
	if err != nil {
		t.Fatal(err)
	}
	v, err := decodeJSONNumbers(raw)
	if err != nil {
		t.Fatal(err)
	}
	return v.(map[string]any)["input"].([]any)
}

func TestReviewPrefillAppendsTheLongestMeasuredRunOfCompleteUnreadParts(t *testing.T) {
	t.Parallel()
	s := prefillScenario(t)
	b, role := s.b, s.role
	n := len(s.parts)
	if n < 600 {
		t.Fatalf("%d pinned parts", n)
	}
	custody, err := b.reviewCustody(s.opening)
	if err != nil {
		t.Fatal(err)
	}

	out, msg := prefillNext(t, s, s.opening)
	if msg == nil {
		t.Fatal("nothing was prefilled")
	}
	parts := prefillParts(t, msg)
	k := len(parts)
	if k < 2 || k >= n {
		t.Fatalf("%d parts prefilled", k)
	}
	// Every part is complete, byte exact and in catalog order, from the first unread one.
	expected := make([]prefillPart, k)
	for i, p := range parts {
		eq(t, "part number", p.Part, i+1)
		eq(t, "path", p.Path, s.parts[i].Path)
		eq(t, "read is the exact read_file text", p.Read, custody.sources[p.Path])
		expected[i] = prefillExact(custody, s, i)
	}
	eq(t, "the message is the canonical one", reflect.DeepEqual(msg, prefillForged(t, 1, expected)), true)

	// The request fits with the margin, and one more part would not.
	m := budgetMeasure(t, b, role, out)
	if !m.Fits || m.RenderedBytes+prefillMargin > agent.InputBudgetBytes {
		t.Fatalf("the prefilled request leaves no margin: %+v", m)
	}
	more := prefillForged(t, 1, append(slices.Clone(expected), prefillExact(custody, s, k)))
	over := budgetMeasure(t, b, role, slices.Concat(s.opening, []any{more}))
	if over.RenderedBytes+prefillMargin <= agent.InputBudgetBytes {
		t.Fatalf("part %d would have fit: %+v (the run is not the longest)", k+1, over)
	}
	// Nothing else changed.
	eq(t, "opening", reflect.DeepEqual(out[:len(s.opening)], s.opening), true)
}

func TestReviewPrefillIsNotCountedWhilePendingAndCountsOnceAModelOutputFollows(t *testing.T) {
	t.Parallel()
	s := prefillScenario(t)
	b := s.b
	n := len(s.parts)
	custody, err := b.reviewCustody(s.opening)
	if err != nil {
		t.Fatal(err)
	}
	pending, msg := prefillNext(t, s, s.opening)
	parts := prefillParts(t, msg)
	k := len(parts)

	// Pending: no response follows, the parts stay unread.
	eq(t, "unread while pending", len(prefillUnread(t, b, pending)), n)
	delivery, err := b.reviewDelivery(pending, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	source := delivery["source"].(map[string]any)
	eq(t, "delivered while pending", source["delivered"], any(0))
	// The approval check agrees.
	r := &reviewRun{b: b}
	approve := map[string]any{"verdict": "approve", "findings": []any{}}
	_, problems, err := r.validate(approve, pending)
	if err != nil {
		t.Fatal(err)
	}
	if len(problems) != 1 || !strings.Contains(problems[0], "Read all pinned source evidence before approving: "+itoa(n)+" unread part(s)") {
		t.Fatalf("approval while pending: %v", problems)
	}

	// A model output after it proves the continuation: tool calls, assistant messages (with or
	// without a type) and reasoning all count; a tool output or a user message does not.
	for _, c := range []prefillCase{
		{"function_call", prefillModel("m")[0]},
		{"message", map[string]any{"type": "message", "role": "assistant", "content": []any{}}},
		{"role", map[string]any{"role": "assistant", "content": "ok"}},
		{"reasoning", map[string]any{"type": "reasoning", "id": "r1"}},
	} {
		unread := prefillUnread(t, b, slices.Concat(pending, []any{c.item}))
		eq(t, c.name+": unread after a model output", len(unread), n-k)
		for _, p := range parts {
			if unread[p.Path] {
				t.Fatalf("%s: part %d is still unread", c.name, p.Part)
			}
		}
	}
	for _, c := range []prefillCase{
		{"output", map[string]any{"type": "function_call_output", "call_id": "x", "output": "ok"}},
		{"user", map[string]any{"role": "user", "content": "carry on"}},
		{"typed_user", map[string]any{"type": "message", "role": "user", "content": "carry on"}},
		{"typed_system", map[string]any{"type": "message", "role": "system", "content": "caller data"}},
		{"typed_missing_role", map[string]any{"type": "message", "content": "caller data"}},
	} {
		eq(t, c.name+": not a model output", len(prefillUnread(t, b, slices.Concat(pending, []any{c.item}))), n)
	}

	// The approval check lists exactly the parts that are still unread.
	_, problems, err = r.validate(approve, slices.Concat(pending, prefillModel("m")))
	if err != nil {
		t.Fatal(err)
	}
	if len(problems) != 1 || !strings.Contains(problems[0], itoa(n-k)+" unread part(s)") {
		t.Fatalf("approval after delivery: %v", problems)
	}

	// A pending message is not offered twice: the next prefill continues after it. A small one
	// leaves room for more.
	small := prefillForged(t, 1, []prefillPart{prefillExact(custody, s, 0), prefillExact(custody, s, 1)})
	twice := slices.Concat(s.opening, []any{small})
	_, next := prefillNext(t, s, twice)
	if next == nil {
		t.Fatal("nothing was prefilled after a pending message")
	}
	eq(t, "the next run skips the pending parts", prefillParts(t, next)[0].Part, 3)
	// Once answered, the parts it carried are delivered and the next run starts after them.
	_, next = prefillNext(t, s, slices.Concat(twice, prefillModel("m")))
	eq(t, "the next run starts after the delivered", prefillParts(t, next)[0].Part, 3)
	for _, p := range prefillParts(t, next) {
		if slices.Contains(prefillPaths(parts[:2]), p.Path) {
			t.Fatalf("delivered part %d is offered again", p.Part)
		}
	}
}

func TestReviewPrefillNeverCountsTamperedOrMislabelledData(t *testing.T) {
	t.Parallel()
	s := prefillScenario(t)
	b := s.b
	n := len(s.parts)
	custody, err := b.reviewCustody(s.opening)
	if err != nil {
		t.Fatal(err)
	}
	model := prefillModel("m")

	// One entry altered, another partial, a path that is no pinned part, one exact: only the
	// exact one counts.
	altered, partial := prefillExact(custody, s, 0), prefillExact(custody, s, 1)
	altered.Read = strings.Replace(altered.Read, "0123", "0124", 1)
	partial.Read = partial.Read[:len(partial.Read)/2]
	stray := prefillPart{Part: 99, Path: "/tmp/not-a-part.json", Read: "x"}
	input := slices.Concat(s.opening, []any{prefillForged(t, 1, []prefillPart{altered, partial, stray, prefillExact(custody, s, 2)})}, model)
	unread := prefillUnread(t, b, input)
	eq(t, "unread", len(unread), n-1)
	eq(t, "altered text counts", unread[s.parts[0].Path], true)
	eq(t, "partial text counts", unread[s.parts[1].Path], true)
	eq(t, "the exact part is delivered", unread[s.parts[2].Path], false)

	// Another review, another marker, another version, a role that is not user, content that is
	// not JSON or not text: nothing counts.
	good := prefillForged(t, 1, []prefillPart{prefillExact(custody, s, 3)})
	text := good.(map[string]any)["content"].(string)
	for _, c := range []prefillCase{
		{"another review", prefillForged(t, 2, []prefillPart{prefillExact(custody, s, 3)})},
		{"another marker", map[string]any{"role": "user", "content": strings.Replace(text, "Native pinned review source data", "Pinned review source data", 1)}},
		{"marker not first", map[string]any{"role": "user", "content": "note\n" + text}},
		{"another version", map[string]any{"role": "user", "content": strings.Replace(text, `"version":1`, `"version":2`, 1)}},
		{"assistant role", map[string]any{"role": "assistant", "content": text}},
		{"not json", map[string]any{"role": "user", "content": prefillMarker + "\nnot json"}},
		{"block content", map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": text}}}},
	} {
		eq(t, c.name, len(prefillUnread(t, b, slices.Concat(s.opening, []any{c.item}, model))), n)
	}
	// The exact message, once a model output follows it, does count (the control).
	eq(t, "control", len(prefillUnread(t, b, slices.Concat(s.opening, []any{good}, model))), n-1)
	// A model output BEFORE the message proves nothing about it.
	eq(t, "output before", len(prefillUnread(t, b, slices.Concat(s.opening, model, []any{good}))), n)

	// A modified part file is refused by custody before anything is prefilled.
	victim := s.parts[3].Path
	if err := os.WriteFile(victim, []byte("tampered\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := b.prefillSource(s.role, "policy", nil, s.opening)
	if err == nil || !strings.Contains(err.Error(), "history custody missing, changed or unsafe: "+victim) {
		t.Fatalf("a changed pinned part is prefilled: %v", err)
	}
	if out != nil {
		t.Fatal("input returned with an error")
	}
}

func TestReviewPrefillAnsweredCountsThroughAResetArchiveAndAResume(t *testing.T) {
	t.Parallel()
	s := prefillScenario(t)
	b, role := s.b, s.role
	n := len(s.parts)
	_, msg := prefillNext(t, s, s.opening)
	parts := prefillParts(t, msg)
	k := len(parts)

	// The prefill message sits before a model response of its window; the newest exchange is only
	// the last one, so the reset archives the whole window and does not keep the message.
	input := slices.Concat(s.opening, []any{msg},
		budgetPad("pad-0", 100_000), budgetPad("pad-1", 100_000), budgetPad("pad-2", 100_000), budgetPad("newest", 1_000))
	if budgetMeasure(t, b, role, input).Fits {
		t.Fatal("the input is not over budget")
	}
	// Resume shape: the input as JSON counts the same way, on its own.
	eq(t, "saved input", len(prefillUnread(t, b, prefillSaved(t, input))), n-k)

	got, err := b.prepareContext("review", role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range got {
		if reflect.DeepEqual(it, msg) {
			t.Fatal("the answered prefill message is kept in the reduced window")
		}
	}
	unread := prefillUnread(t, b, got)
	eq(t, "unread after the reset", len(unread), n-k)
	for _, p := range parts {
		if unread[p.Path] {
			t.Fatalf("part %d answered before the reset is not counted through the archive", p.Part)
		}
	}
	source := handoffOf(t, got)["review_delivery"].(map[string]any)["source"].(map[string]any)
	eq(t, "reset reports delivered", source["delivered"], any(float64(k)))
	eq(t, "reset reports unread", len(source["unread"].([]any)), n-k)
	// The reduced window as JSON (the retained input of a resume) counts the same way.
	eq(t, "saved reduced", len(prefillUnread(t, b, prefillSaved(t, got))), n-k)
}

func TestReviewPrefillPendingMessageAtAResetIsKeptAndStillUncounted(t *testing.T) {
	t.Parallel()
	s := prefillScenario(t)
	b, role := s.b, s.role
	n := len(s.parts)
	custody, err := b.reviewCustody(s.opening)
	if err != nil {
		t.Fatal(err)
	}
	// A pending message (a request that has not been answered), small enough to keep: it is the
	// trailing item of the input, so the reset keeps it with the newest exchange and the archive
	// holds it unanswered.
	pending := prefillForged(t, 1, []prefillPart{prefillExact(custody, s, 0), prefillExact(custody, s, 1)})
	input := slices.Concat(s.opening,
		budgetPad("pad-0", 100_000), budgetPad("pad-1", 100_000), budgetPad("pad-2", 100_000), []any{pending})
	if budgetMeasure(t, b, role, input).Fits {
		t.Fatal("the input is not over budget")
	}
	got, err := b.prepareContext("review", role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "the pending message is kept, not dropped", reflect.DeepEqual(got[len(got)-1], pending), true)
	eq(t, "unread after the reset", len(prefillUnread(t, b, got)), n)
	source := handoffOf(t, got)["review_delivery"].(map[string]any)["source"].(map[string]any)
	eq(t, "reset reports delivered", source["delivered"], any(float64(0)))

	// The archive holds the unanswered message, and it does not count through the archive.
	state := b.WorkingContext["review"]
	archiveOK(t, state.History[len(state.History)-1])
	eq(t, "archives alone", len(prefillUnread(t, b, nil)), n)

	// The reduced window is the retained input: once the model answers it, the parts count.
	eq(t, "answered", len(prefillUnread(t, b, slices.Concat(got, prefillModel("m")))), n-2)
}

func TestReviewPrefillWithoutPrefillMessagesDeliversAsBefore(t *testing.T) {
	t.Parallel()
	s := prefillScenario(t)
	b := s.b
	n := len(s.parts)

	// The paused-checkpoint shape: the opening and complete read_file exchanges only.
	input := slices.Concat(s.opening, s.reads(t))
	unread := prefillUnread(t, b, input)
	eq(t, "unread", len(unread), n-budgetReads)
	for i, ref := range s.parts {
		eq(t, "part "+itoa(i+1), unread[ref.Path], i >= budgetReads)
	}
	delivery, err := b.reviewDelivery(input, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	source := delivery["source"].(map[string]any)
	eq(t, "parts", source["parts"], any(n))
	eq(t, "delivered", source["delivered"], any(budgetReads))
	want := make([]int, 0, n-budgetReads)
	for i := budgetReads + 1; i <= n; i++ {
		want = append(want, i)
	}
	eq(t, "unread numbers", source["unread"], any(want))
	contains(t, "note", delivery["note"].(string), "Read unread pinned parts in batches of about 10 read_file calls per response")
	contains(t, "note", delivery["note"].(string), "Kogen also appends unread pinned parts as native source data messages; they count once a completed response follows them.")

	// A review without pinned parts, or no review at all, never prefills.
	plain, _, tree := materialAttempt(t)
	items := []any{map[string]any{"role": "user", "content": "x"}}
	out, err := plain.prefillSource(materialRole(), "policy", nil, items)
	if err != nil || !reflect.DeepEqual(out, items) {
		t.Fatalf("no review: %v %v", out, err)
	}
	opening, err := plain.materialPrepare(tree, testMaterial("small source\n"), materialRole(), "policy", nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(plain.WorkingContext["review"].History) != 0 {
		t.Fatal("a small source was pinned")
	}
	out, err = plain.prefillSource(materialRole(), "policy", nil, opening)
	if err != nil || !reflect.DeepEqual(out, opening) {
		t.Fatalf("inline review: %v %v", out, err)
	}
}

func TestReviewPrefillIsAppendedAfterToolOutputsAndLeavesToolPairsAlone(t *testing.T) {
	t.Parallel()
	s := prefillScenario(t)
	input := slices.Concat(s.opening, s.reads(t), budgetPad("w", 100))
	out, msg := prefillNext(t, s, input)
	if msg == nil {
		t.Fatal("nothing was prefilled")
	}
	eq(t, "the message is last", reflect.DeepEqual(out[len(out)-1], msg), true)
	last, _ := out[len(out)-2].(map[string]any)
	eq(t, "after the last tool output", last["type"], any("function_call_output"))
	// Every call keeps its output next to it, in order, exactly as before.
	for i := len(s.opening); i < len(input); i++ {
		eq(t, "item "+itoa(i), reflect.DeepEqual(out[i], input[i]), true)
	}
	// The delivered parts are not offered again.
	parts := prefillParts(t, msg)
	eq(t, "first offered part", parts[0].Part, budgetReads+1)
	for _, p := range parts {
		for _, ref := range s.parts[:budgetReads] {
			if p.Path == ref.Path {
				t.Fatalf("delivered part %d is offered again", p.Part)
			}
		}
	}
}

func TestReviewPrefillLeavesInputAloneWhenNoPartFits(t *testing.T) {
	t.Parallel()
	// An opening that leaves less than the margin plus one part.
	s := budgetPinned(t, func(int) int { return prefillMargin + 2_000 })
	out, msg := prefillNext(t, s, s.opening)
	if msg != nil || len(out) != len(s.opening) {
		t.Fatalf("a part was appended that does not fit with the margin: %d items", len(out))
	}
}
