//go:build !race

package build

import (
	"strings"
	"testing"
)

// The S-DECREL case pins 232 source parts, and the reverse-order case in a fresh review 113 more, the shape of the historical failure, and drives a
// real review across several working windows: it is the heaviest fixture of the Build tests
// (hundreds of private files and 500 KB checkpoints per request). It runs in the ordinary test
// run and in the acceptance bridge, and is left out of the race detector's run, whose cost it
// would add to the package's whole time budget although the scripted flow has a single
// conversation and no concurrency of its own.
func init() {
	heavyAllowanceCases = append(heavyAllowanceCases, func(t *testing.T, kit allowanceKit) {
		t.Run("S-DECREL: unread rejections, prose, then the forced verdict in the same conversation", func(t *testing.T) {
			t.Parallel()
			e, f := kit.build(t, pinned232())
			f.then(submit(f, "changes", finding("blocking", "the parts were not delivered")), // exempt: first unread answer
				submit(f, "approve")) // rejected: spends the rejected-verdict allowance
			f.then(repeatHandler(deliverThen(f, prose("I have reviewed everything."),
				submit(f, "approve", finding("note", "fine"))), 40)...) // the last one is the reminder request: forced
			events, reqs := kit.check(t, e, f, pinned232(), 232, -1, -1, []string{
				"unread_progress_exempt:[0,0]", "rejected_verdict:[1,0]", "no_tool_turn:[1,1]",
			})
			// Both rejections were real: each named the parts no completed response had delivered.
			want := kit.wanted(events, "rejected_verdict", 232)
			eq(t, "unread at the exempt changes", kit.unread(t, reqs[1], `(\d+) pinned part\(s\) unread; read them before a verdict`), want)
			eq(t, "unread at the rejected approval", kit.unread(t, reqs[2], `Read all pinned source evidence before approving: (\d+) unread part`), want)
			if want <= 0 || want >= 232 {
				t.Fatalf("unread %d: delivery was catalogued, not real", want)
			}
			contains(t, "reminder", requestText(reqs[len(reqs)-1]), "Not a valid verdict: the review ended without calling submit_review. Call submit_review.")
		})
	})

	heavyAllowanceCases = append(heavyAllowanceCases, func(t *testing.T, kit allowanceKit) {
		// The reverse order runs as the fresh review 2 of a Build whose review 1 ended on two
		// prose-only turns, so it also shows that a fresh native review keeps its own delivery rule:
		// review 1's native delivery of its own parts counts for nothing in review 2.
		t.Run("reverse order in a fresh review: prose, then a rejected verdict, then a valid one", func(t *testing.T) {
			t.Parallel()
			e, f := kit.build(t, pinned113())
			f.then(prose("a"), prose("b"), // review 1: two prose-only turns end it
				prose("Looks fine to me."), // review 2
				submit(f, "approve"))       // forced; still rejected: forcing is not delivery
			f.then(repeatHandler(deliverThen(f, submit(f, "approve", finding("note", "fine"))), 40)...)
			a := e.reviewed()
			if a.exit != 0 {
				t.Fatalf("exit %d\n%s", a.exit, a.shown())
			}
			id := e.onlyRun()
			reqs := f.reviewRequests()
			eq(t, "review 1 parts", len(catalogParts(reviewCatalog(t, reqs[0]))), 113)
			second := catalogParts(reviewCatalog(t, reqs[2]))
			eq(t, "review 2 parts", len(second), 113)
			for _, p := range second {
				if !strings.Contains(p, "/review-source/2-") {
					t.Fatalf("review 2 part %s is not its own", p)
				}
			}
			for i, req := range reqs {
				var want any = "auto"
				if i == 1 || i == 3 {
					want = forcedSubmit
				}
				eq(t, "tool_choice of request "+itoa(i), req["tool_choice"], want)
				if (i < 2) != (cacheKey(req) == cacheKey(reqs[0])) || (i >= 2) != (cacheKey(req) == cacheKey(reqs[2])) {
					t.Fatalf("request %d is in the wrong conversation", i)
				}
			}
			events := e.events(id)
			eq(t, "reviews", e.result(id)["reviews"], any(float64(2)))
			verdicts := eventsNamed(events, "review")
			eq(t, "verdict events", len(verdicts), 2)
			eq(t, "review 1", verdicts[0]["reason"], any("no_tool_reminder_exhausted"))
			eq(t, "review 2", verdicts[1]["verdict"], any("approve"))
			eq(t, "approved review", verdicts[1]["review"], any(float64(2)))
			var got []string
			for _, ev := range eventsNamed(events, "review_allowance") {
				got = append(got, itoa(int(ev["review"].(float64)))+":"+ev["why"].(string)+":"+jsonOf(counters(ev)))
			}
			eq(t, "allowance log", got, []string{"1:no_tool_turn:[0,1]", "2:no_tool_turn:[0,1]", "2:rejected_verdict:[1,1]"})
			// The forced approval was rejected for the parts review 2 had not been given: only the
			// prefill of its own requests before that moment counts.
			var delivered []float64
			want := -1
			for _, ev := range events {
				if ev["event"] == "review_source_prefill" && ev["review"] == float64(2) {
					for _, p := range ev["parts"].([]any) {
						delivered = append(delivered, p.(float64))
					}
				}
				if ev["event"] == "review_allowance" && ev["why"] == "rejected_verdict" {
					want = 113 - len(union(delivered))
					break
				}
			}
			eq(t, "unread at the forced rejected approval", kit.unread(t, reqs[4], `Read all pinned source evidence before approving: (\d+) unread part`), want)
			if want <= 0 || want >= 113 {
				t.Fatalf("unread %d: delivery was catalogued, not real", want)
			}
			var material map[string]any
			for _, ev := range eventsNamed(events, "review_material") {
				material = ev
			}
			eq(t, "review of the material", material["review"], any(float64(2)))
			eq(t, "parts read", material["parts_read"], any(float64(113)))
		})
	})
}
