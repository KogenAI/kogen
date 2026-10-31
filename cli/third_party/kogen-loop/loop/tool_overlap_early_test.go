package loop

import (
	"context"
	"reflect"
	"slices"
	"testing"
)

// A call that is complete in the stream starts before the response ends; argument fragments
// never execute, nor does a Chat Completions answer before its whole body is validated.
func TestToolOverlapEarly(t *testing.T) {
	for _, wire := range []string{"responses", "messages"} {
		t.Run(wire, func(t *testing.T) {
			repo := newOLRepo(t)
			fragments := make(chan struct{})
			proceed := make(chan struct{})
			hold := make(chan struct{})
			finished := make(chan struct{})
			prov := newOLProvider(t, wire,
				func(s *olStream) {
					// The first call's fragments, then its completion; the response is then held.
					if wire == "responses" {
						// Concatenated, these fragments are a valid object naming another
						// pattern than the completed item: only the completed item may run.
						s.frag(0, "a", "search_text", `{"pattern":"WR`, `ONG"}`)
					} else {
						s.frag(0, "a", "search_text", `{"pattern":"fi`, `rst"}`)
					}
					close(fragments)
					s.wait(proceed)
					s.done(0, "a", "search_text", `{"pattern":"first"}`)
					s.wait(hold)
					s.call(1, "b", "search_text", `{"pattern":"second"}`)
					s.end()
					close(finished)
				},
				olFinish,
			)
			d, role, sess := olDirect(t, prov)
			rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, sess)}
			run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{BeforeRequest: func(context.Context, []any) error { return nil }})

			<-fragments
			repo.idle(t, "argument fragments")
			close(proceed)

			// The call starts while the response is still open: the server holds it until
			// the call has started.
			repo.startedKeys(t, "first")
			select {
			case <-finished:
				t.Fatal("the response completed before the first call was observed running")
			default:
			}
			close(hold)
			repo.startedKeys(t, "second")
			repo.release("first", "second")
			res, err := run.wait(t)
			if err != nil || res.Ending != EndTerminal || res.Requests != 2 {
				t.Fatalf("%+v %v", res, err)
			}
			if got := repo.entered(); !reflect.DeepEqual(got, []string{"first", "second"}) {
				t.Fatalf("executed %v: fragments must not run", got)
			}
			reqs := prov.requests()
			if len(reqs) != 2 || !reflect.DeepEqual(olOutputIDs(wire, reqs[1]), []string{"a", "b"}) {
				t.Fatalf("requests %d, outputs %v", len(reqs), reqs)
			}
		})
	}

	// Chat Completions has no per-call completion marker: nothing runs until the whole
	// answer is read and validated, then the calls run together.
	t.Run("chat", func(t *testing.T) {
		repo := newOLRepo(t)
		half := make(chan struct{})
		proceed := make(chan struct{})
		prov := newOLProvider(t, "chat",
			func(s *olStream) {
				s.chat([][3]string{{"a", "search_text", `{"pattern":"first"}`}, {"b", "search_text", `{"pattern":"second"}`}}, func() {
					close(half)
					s.wait(proceed)
				})
			},
			olFinish,
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, sess)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
		<-half
		repo.idle(t, "a half-read Chat Completions answer")
		close(proceed)
		repo.startedKeys(t, "first", "second")
		repo.release("first", "second")
		res, err := run.wait(t)
		if err != nil || res.Ending != EndTerminal || res.Requests != 2 {
			t.Fatalf("%+v %v", res, err)
		}
		if reqs := prov.requests(); len(reqs) != 2 || !reflect.DeepEqual(olOutputIDs("chat", reqs[1]), []string{"a", "b"}) {
			t.Fatalf("requests %v", reqs)
		}
	})

	// The completed response is the authority: when its output is not what the stream
	// delivered, the early call's work is joined and discarded and the response's calls run.
	t.Run("replaced output", func(t *testing.T) {
		repo := newOLRepo(t)
		replaced := fcall("a", "search_text", `{"pattern":"second"}`)
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.call(0, "a", "search_text", `{"pattern":"first"}`)
				s.end(replaced)
			},
			olFinish,
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, sess)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
		repo.startedKeys(t, "first")
		repo.release("first")
		repo.startedKeys(t, "second")
		repo.release("second")
		res, err := run.wait(t)
		if err != nil || res.Ending != EndTerminal {
			t.Fatalf("%+v %v", res, err)
		}
		want := []any{userMsg("go"), replaced, fout("a", "second"), res.Input[len(res.Input)-1]}
		if !reflect.DeepEqual(res.Input[:3], want[:3]) {
			t.Fatalf("input %v", res.Input)
		}
		if got := repo.entered(); !slices.Equal(got, []string{"first", "second"}) {
			t.Fatalf("executed %v", got)
		}
	})
}
