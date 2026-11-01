package loop

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/api"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// rbExchange is one complete exchange of a conversation: a call and the output that answers it.
func rbExchange(i int, pad int) []any {
	id := fmt.Sprintf("call-%03d", i)
	return []any{
		map[string]any{"type": "function_call", "call_id": id, "name": "read_file", "arguments": fmt.Sprintf(`{"path":"f%03d.txt"}`, i)},
		map[string]any{"type": "function_call_output", "call_id": id, "output": fmt.Sprintf("FACT-%03d %s", i, strings.Repeat("a", pad))},
	}
}

// rbHistory is the task and n exchanges whose outputs carry pad filler bytes; the newest output
// carries newestPad.
func rbHistory(n, pad, newestPad int) []any {
	in := []any{map[string]any{"role": "user", "content": "TASK: keep every fact"}}
	for i := 1; i <= n; i++ {
		p := pad
		if i == n {
			p = newestPad
		}
		in = append(in, rbExchange(i, p)...)
	}
	return in
}

func rbSummary(text string) func(*olStream) {
	return func(s *olStream) { s.text(0, text); s.end() }
}

func rbOK(s *olStream) { s.text(0, "ok"); s.end() }

// rbSetup is a Direct over a local provider that answers with script, and a measurer of the
// complete rendered body.
func rbSetup(t *testing.T, model string, script ...func(*olStream)) (*Direct, Request, *olProvider, func([]any) tools.Measurement) {
	t.Helper()
	p := newOLProvider(t, "responses", script...)
	d, role, _ := olDirect(t, p)
	role.Model = model
	d.CacheID = provider.NewCacheID()
	d.Cache = provider.NewCache(nil)
	d.Client.Cache = d.Cache
	r := Request{Owner: "test", Role: role, Instructions: "INSTRUCTIONS stay exact", Tools: olDefs()}
	measure := func(in []any) tools.Measurement {
		m, err := tools.Measure(d.Client.Body(provider.Request{
			Role: role, Instructions: r.Instructions, Input: in, Tools: r.Tools, CacheID: d.CacheID, Cache: d.Cache,
		}), role)
		if err != nil {
			t.Fatal(err)
		}
		return m
	}
	return d, r, p, measure
}

func rbIsSummaryRequest(body map[string]any) bool {
	_, hasTools := body["tools"]
	return !hasTools
}

func rbBodyFits(t *testing.T, body map[string]any, role provider.Role) {
	t.Helper()
	m, err := tools.Measure(body, role)
	if err != nil {
		t.Fatal(err)
	}
	if !m.Fits {
		t.Errorf("a request of %d bytes was sent over the %d-byte ceiling", m.RenderedBytes, m.InputBudgetBytes)
	}
}

func rbInputText(body map[string]any) string {
	return fmt.Sprint(body["input"])
}

func TestRequestBudgetBoundary(t *testing.T) {
	t.Parallel()
	for _, model := range []string{"fixture-model", "gpt-6.1-sol"} {
		t.Run(model, func(t *testing.T) {
			t.Parallel()
			_, r0, _, m0 := rbSetup(t, model)
			base := m0(rbHistory(6, 100, 0))
			limit := base.InputBudgetBytes
			if limit > provider.InputBudgetBytes || limit != provider.RequestInputBytes(r0.Role) {
				t.Fatalf("limit %d is not the repository ceiling or a smaller family bound", limit)
			}
			// One byte of filler is one byte of the rendered request.
			sizeAt := func(delta int) []any {
				return rbHistory(6, 100, limit-base.RenderedBytes+delta)
			}

			for _, delta := range []int{-1, 0} {
				t.Run(fmt.Sprintf("limit%+d", delta), func(t *testing.T) {
					t.Parallel()
					d, r, p, measure := rbSetup(t, model, rbOK)
					r.Input = sizeAt(delta)
					if got := measure(r.Input).RenderedBytes; got != limit+delta {
						t.Fatalf("rendered %d, want %d", got, limit+delta)
					}
					condensed := 0
					d.Condensed = func(Condensation) { condensed++ }
					_, sent, err := d.Request(context.Background(), r)
					if err != nil {
						t.Fatal(err)
					}
					if !reflect.DeepEqual(sent, r.Input) || condensed != 0 || len(p.requests()) != 1 {
						t.Errorf("a request that fits changed: condensed %d, %d requests", condensed, len(p.requests()))
					}
				})
			}

			t.Run("limit+1 condenses and then fits", func(t *testing.T) {

				t.Parallel()
				d, r, p, measure := rbSetup(t, model, rbSummary("SUMMARY keeps FACT-001 to FACT-005"), rbOK)
				r.Input = sizeAt(1)
				if got := measure(r.Input).RenderedBytes; got != limit+1 {
					t.Fatalf("rendered %d, want %d", got, limit+1)
				}
				var got []Condensation
				d.Condensed = func(c Condensation) { got = append(got, c) }
				_, sent, err := d.Request(context.Background(), r)
				if err != nil {
					t.Fatal(err)
				}
				reqs := p.requests()
				if len(reqs) != 2 || !rbIsSummaryRequest(reqs[0]) || rbIsSummaryRequest(reqs[1]) {
					t.Fatalf("%d requests; want one summarization request then the condensed request", len(reqs))
				}
				for _, b := range reqs {
					rbBodyFits(t, b, r.Role)
				}
				if len(got) != 1 || got[0].BytesBefore != limit+1 || got[0].BytesAfter > limit || got[0].Requests != 1 || got[0].CondensedExchanges < 1 {
					t.Errorf("disclosure %+v", got)
				}
				if measure(sent).RenderedBytes > limit {
					t.Error("the sent input does not fit")
				}
				text := rbInputText(reqs[1])
				for _, keep := range []string{"TASK: keep every fact", "call-006", CondensedHeader, "SUMMARY keeps FACT-001"} {
					if !strings.Contains(text, keep) {
						t.Errorf("the condensed request lost %q", keep)
					}
				}
				if reqs[1]["instructions"] != r.Instructions {
					t.Error("instructions changed")
				}
			})

			t.Run("immutable content that cannot fit is refused without any request", func(t *testing.T) {

				t.Parallel()
				d, r, p, _ := rbSetup(t, model)
				// The task alone fills the window; older exchanges exist but cannot make room.
				in := rbHistory(4, 100, 100)
				in[0] = map[string]any{"role": "user", "content": strings.Repeat("a", limit)}
				r.Input = in
				d.Condensed = func(Condensation) { t.Error("condensed an irreducible request") }
				_, _, err := d.Request(context.Background(), r)
				se, ok := sys.AsError(err)
				if !ok || se.Class != api.ErrClassLoop || se.Reason != api.ErrContextBudget {
					t.Fatalf("error %v", err)
				}
				if n := len(p.requests()); n != 0 {
					t.Errorf("%d requests were sent", n)
				}
			})
		})
	}
}

func TestRequestBudgetFailures(t *testing.T) {
	t.Parallel()
	// eight exchanges of about 90 KB: far over the ceiling, and too large for one summary request.
	big := func() []any { return rbHistory(8, 90_000, 90_000) }

	t.Run("summary requests fit, carry no tools and include the prior summary", func(t *testing.T) {

		t.Parallel()
		d, r, p, _ := rbSetup(t, "fixture-model", rbSummary("FIRST SUMMARY covers FACT-001"), rbSummary("SECOND SUMMARY"), rbOK)
		r.Input = big()
		var got []Condensation
		d.Condensed = func(c Condensation) { got = append(got, c) }
		if _, _, err := d.Request(context.Background(), r); err != nil {
			t.Fatal(err)
		}
		reqs := p.requests()
		if len(reqs) < 3 {
			t.Fatalf("%d requests; the history needs at least two chunks", len(reqs))
		}
		for i, b := range reqs {
			rbBodyFits(t, b, r.Role)
			if i < len(reqs)-1 {
				if !rbIsSummaryRequest(b) || b["instructions"] == r.Instructions {
					t.Errorf("request %d is not a bare summarization request", i)
				}
			}
		}
		if !strings.Contains(rbInputText(reqs[1]), "FIRST SUMMARY covers FACT-001") {
			t.Error("the second summarization request does not include the first summary")
		}
		if rbIsSummaryRequest(reqs[len(reqs)-1]) {
			t.Error("the last request is not the conversation's")
		}
		if len(got) != 1 || got[0].Requests != len(reqs)-1 || got[0].Requests > 2*8+2 {
			t.Errorf("disclosure %+v", got)
		}
	})

	t.Run("a provider failure stops without sending the conversation", func(t *testing.T) {

		t.Parallel()
		// The script ends after zero answers: the provider refuses the summarization request.
		d, r, p, _ := rbSetup(t, "fixture-model")
		r.Input = big()
		d.Condensed = func(Condensation) { t.Error("disclosed a condensation that did not happen") }
		resp, _, err := d.Request(context.Background(), r)
		se, ok := sys.AsError(err)
		if resp != nil || !ok || se.Class != "provider" {
			t.Fatalf("response %v, error %v", resp, err)
		}
		for _, b := range p.requests() {
			if !rbIsSummaryRequest(b) {
				t.Error("the conversation was sent after the summarization failed")
			}
		}
	})

	t.Run("cancellation stops at once", func(t *testing.T) {

		t.Parallel()
		hang := make(chan struct{})
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		seen := make(chan struct{})
		d, r, p, _ := rbSetup(t, "fixture-model", func(s *olStream) { close(seen); s.wait(hang) })
		r.Input = big()
		done := make(chan error, 1)
		go func() { _, _, err := d.Request(ctx, r); done <- err }()
		select {
		case <-seen:
		case <-time.After(20 * time.Second):
			t.Fatal("the summarization request never arrived")
		}
		cancel()
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("cancellation returned no error")
			}
			if se, ok := sys.AsError(err); ok && se.Reason == api.ErrContextBudget {
				t.Errorf("cancellation reported as a budget refusal: %v", err)
			}
		case <-time.After(20 * time.Second):
			t.Fatal("Request did not return after cancellation")
		}
		if n := len(p.requests()); n != 1 {
			t.Errorf("%d requests; cancellation must not start another", n)
		}
	})

	t.Run("a summary that cannot be made shorter ends the attempt", func(t *testing.T) {

		t.Parallel()
		huge := strings.Repeat("s", 200_000) // above the summary cap, so one merge is tried
		d, r, p, _ := rbSetup(t, "fixture-model", rbSummary(huge), rbSummary(huge), rbOK)
		r.Input = big()
		_, _, err := d.Request(context.Background(), r)
		var se *sys.Error
		if !errors.As(err, &se) || se.Class != api.ErrClassLoop || se.Reason != api.ErrContextBudget {
			t.Fatalf("error %v", err)
		}
		reqs := p.requests()
		if len(reqs) != 2 {
			t.Errorf("%d requests; want the summary and one merge, then a stop", len(reqs))
		}
		for _, b := range reqs {
			if !rbIsSummaryRequest(b) {
				t.Error("an unreduced request was sent")
			}
		}
	})

	t.Run("an empty summary is not a finish", func(t *testing.T) {

		t.Parallel()
		d, r, p, _ := rbSetup(t, "fixture-model", func(s *olStream) { s.text(0, "  "); s.end() }, rbOK)
		r.Input = big()
		_, _, err := d.Request(context.Background(), r)
		if se, ok := sys.AsError(err); !ok || se.Reason != api.ErrContextBudget {
			t.Fatalf("error %v", err)
		}
		if n := len(p.requests()); n != 1 {
			t.Errorf("%d requests", n)
		}
	})

	t.Run("an exchange that cannot fit a summary request is refused", func(t *testing.T) {

		t.Parallel()
		in := rbHistory(3, 100, 100)
		in = append(in[:3:3], rbExchange(9, provider.InputBudgetBytes)...) // older, alone over the ceiling
		in = append(in, rbExchange(10, 100)...)
		d, r, p, measure := rbSetup(t, "fixture-model")
		r.Input = in
		if measure(in).Fits {
			t.Fatal("fixture fits")
		}
		_, _, err := d.Request(context.Background(), r)
		if se, ok := sys.AsError(err); !ok || se.Reason != api.ErrContextBudget {
			t.Fatalf("error %v", err)
		}
		if n := len(p.requests()); n != 0 {
			t.Errorf("%d requests were sent", n)
		}
	})
}
