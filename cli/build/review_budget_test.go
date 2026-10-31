package build

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	agent "kogen-loop/tools"
	"kogen/project"
)

// A review whose candidate source is pinned into hundreds of parts has a bounded opening that
// already lists every part in its catalog. A working-window reset must not list them all a
// second time on top of that opening (a native Build reached a measured 547145 bytes against
// the 524288-byte ceiling this way though its opening had fit), while native history custody
// keeps every part reference.

// budgetReads is how many pinned parts the reviewer has been given completely before the resets.
const budgetReads = 5

// budgetSource is about 4.1 MB of ASCII source: 686 pinned parts of 6000 bytes.
func budgetSource() string { return strings.Repeat("0123456789abcdef-line\n", 187_000) }

func budgetMaterial(authority string) materialSet {
	return materialSet{Authority: authority, Source: budgetSource(), Checks: "acceptance: passed (1 scenarios)", Files: []map[string]any{}}
}

// budgetMeasure is the real measurement against the unchanged ceiling.
func budgetMeasure(t *testing.T, b *Attempt, role project.Role, input []any) agent.Measurement {
	t.Helper()
	m, err := agent.Measure(b.bodyOf(role, "policy", input, nil, "review"), providerRole(role))
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "ceiling", m.InputBudgetBytes, agent.InputBudgetBytes)
	return m
}

// budgetDuplicate is the bytes a second listing of the references would add to a request
// that carries the opening.
func budgetDuplicate(t *testing.T, b *Attempt, role project.Role, opening []any, refs []HistoryRef) int {
	t.Helper()
	list := make([]any, len(refs))
	for i, h := range refs {
		list[i] = map[string]any{"path": h.Path, "sha256": h.SHA256}
	}
	encoded, err := project.EncodeJSON(list)
	if err != nil {
		t.Fatal(err)
	}
	with := budgetMeasure(t, b, role, append(slices.Clone(opening), map[string]any{"role": "user", "content": string(encoded)}))
	without := budgetMeasure(t, b, role, append(slices.Clone(opening), map[string]any{"role": "user", "content": ""}))
	return with.RenderedBytes - without.RenderedBytes
}

const budgetBaseAuthority = "exact approved authority\n"

// budgetPadding is an authority whose bounded opening measures ceiling - headroom(dup) bytes
// for the 686-part source, with dup the bytes a second listing of the part references adds.
func budgetPadding(t *testing.T, headroom func(dup int) int) (authority string, dup, parts int) {
	t.Helper()
	probe, _, tree := materialAttempt(t)
	role := materialRole()
	opening, err := probe.materialPrepare(tree, budgetMaterial(budgetBaseAuthority), role, "policy", nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	refs := probe.WorkingContext["review"].History
	dup = budgetDuplicate(t, probe, role, opening, refs)
	pad := agent.InputBudgetBytes - headroom(dup) - budgetMeasure(t, probe, role, opening).RenderedBytes
	if pad <= 0 {
		t.Fatalf("no authority padding fits: %d", pad)
	}
	return budgetBaseAuthority + strings.Repeat("a", pad), dup, len(refs)
}

type budgetScenario struct {
	b            *Attempt
	e            *env
	role         project.Role
	opening      []any
	parts        []HistoryRef
	openingBytes int
	dupBytes     int
}

// budgetPinned is a review whose source is pinned into parts with a bounded opening that fits.
func budgetPinned(t *testing.T, headroom func(dup int) int) *budgetScenario {
	t.Helper()
	authority, dup, _ := budgetPadding(t, headroom)
	b, e, tree := materialAttempt(t)
	role := materialRole()
	opening, err := b.materialPrepare(tree, budgetMaterial(authority), role, "policy", nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	return &budgetScenario{
		b: b, e: e, role: role, opening: opening, parts: slices.Clone(b.WorkingContext["review"].History),
		openingBytes: budgetMeasure(t, b, role, opening).RenderedBytes, dupBytes: dup,
	}
}

func budgetPad(id string, n int) []any {
	arguments := jsonText(map[string]any{"path": "pad.txt", "content": strings.Repeat("x", n)})
	return []any{
		map[string]any{"type": "function_call", "call_id": id, "name": "write_file", "arguments": arguments},
		map[string]any{"type": "function_call_output", "call_id": id, "output": "ok"},
	}
}

// reads are complete read_file exchanges of the first pinned parts.
func (s *budgetScenario) reads(t *testing.T) []any {
	t.Helper()
	tools := &agent.Tools{Root: s.b.Root, Enabled: []string{"read_file"}}
	var items []any
	for i, ref := range s.parts[:budgetReads] {
		id := "read-" + itoa(i)
		out, err := tools.Run("read_file", map[string]any{"path": ref.Path})
		if err != nil {
			t.Fatal(err)
		}
		items = append(items,
			map[string]any{"type": "function_call", "call_id": id, "name": "read_file", "arguments": jsonText(map[string]any{"path": ref.Path})},
			map[string]any{"type": "function_call_output", "call_id": id, "output": out.Text})
	}
	return items
}

// input is the opening, the completed reads, three large exchanges and a newest exchange of
// last bytes: over the budget, so that the reset path runs.
func (s *budgetScenario) input(t *testing.T, last int) []any {
	t.Helper()
	input := append(slices.Clone(s.opening), s.reads(t)...)
	for i := 0; i < 3; i++ {
		input = append(input, budgetPad("pad-"+itoa(i), 100_000)...)
	}
	return append(input, budgetPad("newest", last)...)
}

func refText(h HistoryRef) string {
	return jsonText(map[string]any{"path": h.Path, "sha256": h.SHA256})
}

func archiveOK(t *testing.T, ref HistoryRef) {
	t.Helper()
	data, err := os.ReadFile(ref.Path)
	if err != nil || hashHex(data) != ref.SHA256 {
		t.Fatalf("archive %s: %v", ref.Path, err)
	}
}

func TestReviewBudgetResetDoesNotRepeatCatalogPartsYetKeepsCustodyAndDelivery(t *testing.T) {
	t.Parallel()
	// Studio native Build: candidate/context_budget_exceeded, source 4109131 bytes in 685 parts,
	// measured 547145, mandatory 547359, ceiling 524288, after an opening that fit.
	s := budgetPinned(t, func(dup int) int { return 24_000 + dup/2 })
	b, role := s.b, s.role
	n := len(s.parts)
	if n < 600 {
		t.Fatalf("%d pinned parts", n)
	}
	ceiling := agent.InputBudgetBytes
	// The scenario is real: the opening fits, a second listing of its references would not.
	if s.openingBytes > ceiling {
		t.Fatalf("the opening %d does not fit %d", s.openingBytes, ceiling)
	}
	if s.openingBytes+s.dupBytes <= ceiling {
		t.Fatalf("opening %d plus a second listing %d fits %d: nothing is proven", s.openingBytes, s.dupBytes, ceiling)
	}

	input := s.input(t, 1_000)
	if budgetMeasure(t, b, role, input).Fits {
		t.Fatal("the input is not over budget")
	}
	unread, err := b.materialUnread(input)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "unread before the reset", len(unread), n-budgetReads)

	got, err := b.prepareContext("review", role, "policy", input, nil)
	if err != nil {
		t.Fatal(err)
	}
	reduced := budgetMeasure(t, b, role, got)
	if !reduced.Fits || reduced.RenderedBytes > ceiling {
		t.Fatalf("the reduced request does not fit: %+v", reduced)
	}
	// The unreduced references would have broken the ceiling.
	if reduced.RenderedBytes+s.dupBytes <= ceiling {
		t.Fatalf("reduced %d plus a second listing %d fits: nothing is proven", reduced.RenderedBytes, s.dupBytes)
	}
	if !reflect.DeepEqual(got[:len(s.opening)], s.opening) {
		t.Fatal("the mandatory opening is not kept exactly")
	}

	reset := handoffOf(t, got)
	state := b.WorkingContext["review"]
	eq(t, "history length", len(state.History), n+1)
	if !slices.Equal(state.History[:n], s.parts) {
		t.Fatal("native history lost or reordered a pinned part")
	}
	archive := state.History[n]
	archiveOK(t, archive)
	history := reset["history"].([]any)
	eq(t, "reset history", history, []any{map[string]any{"path": archive.Path, "sha256": archive.SHA256}})
	note := reset["history_in_catalog"].(map[string]any)
	eq(t, "omitted count", note["count"], any(float64(n)))
	contains(t, "note", note["note"].(string), "listed in full in the pinned candidate source catalog of the mandatory opening message")
	// Every omitted reference really is listed verbatim in the mandatory opening.
	catalog := strings.Join(mandatoryTexts(got[:len(s.opening)]), "\n")
	for _, ref := range s.parts {
		if !strings.Contains(catalog, refText(ref)) {
			t.Fatalf("omitted %s is not listed in the catalog", ref.Path)
		}
	}
	if err := b.validateWorkingContext(); err != nil {
		t.Fatal(err)
	}

	// Delivery is unchanged by the reset.
	unread, err = b.materialUnread(got)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "unread after the reset", len(unread), n-budgetReads)
	source := reset["review_delivery"].(map[string]any)["source"].(map[string]any)
	eq(t, "delivery parts", source["parts"], any(float64(n)))
	eq(t, "delivery delivered", source["delivered"], any(float64(budgetReads)))
	eq(t, "delivery unread", len(source["unread"].([]any)), n-budgetReads)
	eq(t, "delivery current", source["current"], any(true))

	// A second reset carries both archives and still no part twice.
	again := slices.Concat(got, budgetPad("again-1", 100_000), budgetPad("again-2", 100_000), budgetPad("again-3", 100_000), budgetPad("again-newest", 1_000))
	if budgetMeasure(t, b, role, again).Fits {
		t.Fatal("the second input is not over budget")
	}
	got2, err := b.prepareContext("review", role, "policy", again, nil)
	if err != nil {
		t.Fatal(err)
	}
	if m := budgetMeasure(t, b, role, got2); !m.Fits {
		t.Fatalf("the second reduced request does not fit: %+v", m)
	}
	reset2 := handoffOf(t, got2)
	state = b.WorkingContext["review"]
	eq(t, "history length after two resets", len(state.History), n+2)
	if !slices.Equal(state.History[:n], s.parts) || state.History[n] != archive {
		t.Fatal("history changed order after the second reset")
	}
	archiveOK(t, state.History[n+1])
	eq(t, "second reset history", reset2["history"].([]any), []any{
		map[string]any{"path": archive.Path, "sha256": archive.SHA256},
		map[string]any{"path": state.History[n+1].Path, "sha256": state.History[n+1].SHA256},
	})
	eq(t, "second omitted count", reset2["history_in_catalog"].(map[string]any)["count"], any(float64(n)))
	unread, err = b.materialUnread(got2)
	if err != nil {
		t.Fatal(err)
	}
	eq(t, "unread after two resets", len(unread), n-budgetReads)
	source = reset2["review_delivery"].(map[string]any)["source"].(map[string]any)
	eq(t, "delivered after two resets", source["delivered"], any(float64(budgetReads)))
	if err := b.validateWorkingContext(); err != nil {
		t.Fatal(err)
	}
}

func TestReviewBudgetOmittedPartsRemainUnderCustodyValidation(t *testing.T) {
	t.Parallel()
	s := budgetPinned(t, func(dup int) int { return 24_000 + dup/2 })
	b := s.b
	if _, err := b.prepareContext("review", s.role, "policy", s.input(t, 1_000), nil); err != nil {
		t.Fatal(err)
	}
	if err := b.validateWorkingContext(); err != nil {
		t.Fatal(err)
	}
	// A part the reset no longer repeats is still guarded.
	victim := s.parts[len(s.parts)/2].Path
	if err := os.WriteFile(victim, []byte("tampered\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := b.validateWorkingContext()
	if err == nil || !strings.Contains(err.Error(), "history custody missing, changed or unsafe: "+victim) {
		t.Fatalf("a changed pinned part is accepted: %v", err)
	}
}

func TestReviewBudgetCatalogThatCannotFitStillRefusesBeforeAnyCustody(t *testing.T) {
	t.Parallel()
	authority, _, _ := budgetPadding(t, func(int) int { return -5_000 })
	b, e, tree := materialAttempt(t)
	index := e.state()["index"]
	_, err := b.materialPrepare(tree, budgetMaterial(authority), materialRole(), "policy", nil, nil, false)
	if err == nil {
		t.Fatal("an opening over the ceiling is accepted")
	}
	for _, part := range []string{"candidate/context_budget_exceeded: review: mandatory authority/catalog ", "ceiling 524288", "output reserve 131072 tokens"} {
		contains(t, "error", err.Error(), part)
	}
	if _, err := os.Stat(filepath.Join(b.Run.Dir, "review-source")); !os.IsNotExist(err) {
		t.Fatal("source custody was created")
	}
	eq(t, "index", e.state()["index"], index)
}

func TestReviewBudgetResetThatCannotFitStillRefusesWithoutAnArchive(t *testing.T) {
	t.Parallel()
	// The opening fits, but with this newest exchange the reduced request cannot.
	s := budgetPinned(t, func(int) int { return 20_000 })
	b := s.b
	if s.openingBytes > agent.InputBudgetBytes {
		t.Fatalf("the opening %d does not fit", s.openingBytes)
	}
	before := slices.Clone(b.WorkingContext["review"].History)
	_, err := b.prepareContext("review", s.role, "policy", s.input(t, 150_000), nil)
	if err == nil {
		t.Fatal("an irreducible request is accepted")
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
}

func TestReviewBudgetResetWithoutCatalogListedReferencesRepeatsEveryReferenceAndAddsNothing(t *testing.T) {
	t.Parallel()
	// Non-review owners and reviews without pinned parts keep the exact complete history list.
	for _, owner := range []string{"build", "review"} {
		t.Run(owner, func(t *testing.T) {
			t.Parallel()
			b, _, _ := windowAttempt(t)
			role := defaultRole()
			input := []any{map[string]any{"role": "user", "content": "exact approved authority"}}
			pads := func(prefix string) []any {
				var items []any
				for i := 0; i < 3; i++ {
					items = append(items, budgetPad(prefix+itoa(i), 190_000)...)
				}
				return items
			}
			input = slices.Concat(input, pads("first-"), budgetPad("first-newest", 1_000))
			for round := 1; round <= 2; round++ {
				got, err := b.prepareContext(owner, role, "policy", input, nil)
				if err != nil {
					t.Fatal(err)
				}
				reset := handoffOf(t, got)
				state := b.WorkingContext[owner]
				eq(t, "archives", len(state.History), round)
				want := []any{}
				for _, h := range state.History {
					want = append(want, map[string]any{"path": h.Path, "sha256": h.SHA256})
				}
				eq(t, "history", reset["history"].([]any), want)
				if _, ok := reset["history_in_catalog"]; ok {
					t.Fatalf("round %d added history_in_catalog: %v", round, reset["history_in_catalog"])
				}
				input = slices.Concat(got, pads("next-"+itoa(round)+"-"), budgetPad("newest-"+itoa(round), 1_000))
			}
		})
	}
}

func TestReviewBudgetMandatoryTextsReadsStringAndBlockContent(t *testing.T) {
	t.Parallel()
	mandatory := []any{
		map[string]any{"role": "user", "content": []any{
			map[string]any{"type": "input_text", "text": "authority"},
			map[string]any{"type": "input_text", "text": "catalog"},
			map[string]any{"type": "input_image", "image_url": "x"},
		}},
		map[string]any{"role": "user", "content": "diagnostic"},
		"not a message",
	}
	eq(t, "texts", mandatoryTexts(mandatory), []string{"authority", "catalog", "diagnostic"})
	if !listedIn([]string{"a", "xy catalog"}, "catalog") || listedIn([]string{"a", "b"}, "catalog") {
		t.Fatal("listedIn")
	}
}
