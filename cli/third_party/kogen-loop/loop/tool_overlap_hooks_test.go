package loop

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/tools"
)

// With any response or call hook installed the engine keeps its documented order: the whole
// response is validated first, then the calls run one after another, each hook seeing the
// outputs before it. A BeforeRequest hook alone does not disable overlap.
func TestToolOverlapHooks(t *testing.T) {
	sentinel := errors.New("hook failure")

	// held streams two calls with a pause between them; the pause ends when proceed closes.
	held := func(t *testing.T) (*olProvider, *olRepo, chan struct{}, chan struct{}) {
		sent, proceed := make(chan struct{}), make(chan struct{})
		repo := newOLRepo(t)
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.call(0, "a", "search_text", `{"pattern":"first"}`)
				close(sent)
				s.wait(proceed)
				s.call(1, "b", "search_text", `{"pattern":"second"}`)
				s.end()
			},
			olFinish,
		)
		return prov, repo, sent, proceed
	}
	setup := func(t *testing.T, prov *olProvider, repo *olRepo) (Round, *Direct) {
		d, role, sess := olDirect(t, prov)
		return Round{Role: role, Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, sess)}, d
	}

	hooks := map[string]func(log func(string)) Hooks{
		"AfterResponse": func(log func(string)) Hooks {
			return Hooks{AfterResponse: func(_ context.Context, resp *provider.Response, _ []any) error {
				log("response")
				return nil
			}}
		},
		"BeforeCall": func(log func(string)) Hooks {
			return Hooks{BeforeCall: func(_ context.Context, c tools.Call, input []any) error {
				log("before " + c.CallID().(string))
				return nil
			}}
		},
		"HandleCall": func(log func(string)) Hooks {
			return Hooks{HandleCall: func(_ context.Context, c tools.Call) (Handled, error) {
				log("handle " + c.CallID().(string))
				return Handled{}, nil
			}}
		},
		"AfterCall": func(log func(string)) Hooks {
			return Hooks{AfterCall: func(_ context.Context, c tools.Call, _ tools.Output, _ bool, _ []any) error {
				log("after " + c.CallID().(string))
				return nil
			}}
		},
	}
	for name, mk := range hooks {
		t.Run("serial after the validated response/"+name, func(t *testing.T) {
			prov, repo, sent, proceed := held(t)
			rd, d := setup(t, prov, repo)
			var order []string
			h := mk(func(s string) { order = append(order, s) })
			run := olStart(context.Background(), rd, []any{userMsg("go")}, d, h)
			<-sent
			repo.idle(t, "a call before its response is validated")
			close(proceed)
			if k := repo.next(t); k != "first" {
				t.Fatalf("started %q first", k)
			}
			repo.idle(t, "the second call beside the first")
			repo.release("first")
			if k := repo.next(t); k != "second" {
				t.Fatalf("started %q second", k)
			}
			repo.release("second")
			res, err := run.wait(t)
			if err != nil || res.Ending != EndTerminal || res.Requests != 2 {
				t.Fatalf("%+v %v", res, err)
			}
			calls := []any{map[string]any{"type": "function_call", "call_id": "a", "name": "search_text", "arguments": `{"pattern":"first"}`},
				map[string]any{"type": "function_call", "call_id": "b", "name": "search_text", "arguments": `{"pattern":"second"}`}}
			want := append([]any{userMsg("go")}, calls...)
			want = append(want, fout("a", "first"), fout("b", "second"))
			if got := res.Input[:len(want)]; marshal(t, got) != marshal(t, want) {
				t.Fatalf("history\n got %s\nwant %s", marshal(t, got), marshal(t, want))
			}
			wantOrder := map[string][]string{
				"AfterResponse": {"response", "response"},
				"BeforeCall":    {"before a", "before b", "before fin"},
				"HandleCall":    {"handle a", "handle b"},
				"AfterCall":     {"after a", "after b", "after fin"},
			}[name]
			if !reflect.DeepEqual(order, wantOrder) {
				t.Fatalf("hook order %v, want %v", order, wantOrder)
			}
		})
	}

	t.Run("hooks see preceding outputs and intercept", func(t *testing.T) {
		repo := newOLRepo(t)
		repo.release("second")
		rq := &scriptRequester{script: [][]map[string]any{
			{olSearch("a", "first"), olSearch("b", "second"), fcall("t", "finish", `{}`)}, {fcall("end", "finish", `{}`)}}}
		var seen [][]any
		var after []string
		h := Hooks{
			BeforeCall: func(_ context.Context, c tools.Call, input []any) error {
				seen = append(seen, append([]any(nil), input...))
				return nil
			},
			HandleCall: func(_ context.Context, c tools.Call) (Handled, error) {
				if c.CallID() == "a" {
					return Handled{Handled: true, Output: tools.Output{Text: "intercepted"}}, nil
				}
				return Handled{}, nil
			},
			AfterCall: func(_ context.Context, c tools.Call, out tools.Output, terminal bool, input []any) error {
				after = append(after, c.CallID().(string)+"="+out.Text)
				return nil
			},
		}
		rd := Round{Tools: olTools(t.TempDir(), repo, nil)}
		res, err := Run(context.Background(), rd, []any{userMsg("go")}, rq, h)
		if err != nil || res.Ending != EndTerminal {
			t.Fatalf("%+v %v", res, err)
		}
		if got := repo.entered(); !reflect.DeepEqual(got, []string{"second"}) {
			t.Fatalf("an intercepted call ran: %v", got)
		}
		if !reflect.DeepEqual(after, []string{"a=intercepted", "b=second", "t="}) {
			t.Fatalf("after %v", after)
		}
		if len(seen) != 3 || len(seen[0]) != 4 || !reflect.DeepEqual(seen[1][4:], []any{fout("a", "intercepted")}) ||
			!reflect.DeepEqual(seen[2][4:], []any{fout("a", "intercepted"), fout("b", "second")}) {
			t.Fatalf("inputs seen by BeforeCall: %v", seen)
		}
	})

	t.Run("error precedence", func(t *testing.T) {
		repo := newOLRepo(t)
		repo.release("first", "second")
		for _, hook := range []string{"AfterResponse", "BeforeCall", "HandleCall", "AfterCall"} {
			rq := &scriptRequester{script: [][]map[string]any{{olSearch("a", "first"), olSearch("b", "second")}, {fcall("end", "finish", `{}`)}}}
			n := 0
			h := Hooks{}
			switch hook {
			case "AfterResponse":
				h.AfterResponse = func(context.Context, *provider.Response, []any) error { return sentinel }
			case "BeforeCall":
				h.BeforeCall = func(context.Context, tools.Call, []any) error {
					if n++; n == 2 {
						return sentinel
					}
					return nil
				}
			case "HandleCall":
				h.HandleCall = func(context.Context, tools.Call) (Handled, error) {
					if n++; n == 2 {
						return Handled{}, sentinel
					}
					return Handled{}, nil
				}
			case "AfterCall":
				h.AfterCall = func(context.Context, tools.Call, tools.Output, bool, []any) error {
					if n++; n == 2 {
						return sentinel
					}
					return nil
				}
			}
			before := len(repo.entered())
			res, err := Run(context.Background(), Round{Tools: olTools(t.TempDir(), repo, nil)}, nil, rq, h)
			if err != sentinel || res.Ending != "" || res.Input != nil {
				t.Fatalf("%s: %+v %v", hook, res, err)
			}
			ran := len(repo.entered()) - before
			if want := map[string]int{"AfterResponse": 0, "BeforeCall": 1, "HandleCall": 1, "AfterCall": 2}[hook]; ran != want {
				t.Fatalf("%s: %d calls ran, want %d", hook, ran, want)
			}
			if len(rq.requests) != 1 {
				t.Fatalf("%s: %d requests", hook, len(rq.requests))
			}
		}
		// BeforeRequest keeps its place and its error before the first request.
		rq := &scriptRequester{script: [][]map[string]any{{olSearch("a", "first")}}}
		_, err := Run(context.Background(), Round{Tools: olTools(t.TempDir(), repo, nil)}, nil, rq,
			Hooks{BeforeRequest: func(context.Context, []any) error { return sentinel }})
		if err != sentinel || len(rq.requests) != 0 {
			t.Fatalf("BeforeRequest: %v, %d requests", err, len(rq.requests))
		}
	})

	t.Run("BeforeRequest alone permits overlap", func(t *testing.T) {
		prov, repo, sent, proceed := held(t)
		rd, d := setup(t, prov, repo)
		var requests int
		h := Hooks{BeforeRequest: func(context.Context, []any) error { requests++; return nil }}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, h)
		<-sent
		// The response is still open and the first call is running.
		repo.startedKeys(t, "first")
		close(proceed)
		repo.startedKeys(t, "second")
		repo.release("first", "second")
		res, err := run.wait(t)
		if err != nil || res.Ending != EndTerminal || requests != 2 {
			t.Fatalf("%+v %v, %d BeforeRequest calls", res, err, requests)
		}
	})
}
