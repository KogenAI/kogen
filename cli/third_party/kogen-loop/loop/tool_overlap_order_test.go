package loop

import (
	"context"
	"fmt"
	"reflect"
	"testing"
)

// Independent calls run together and finish in any order, while the conversation keeps the
// response's order: replayed items as received, then one output per call in call order.
func TestToolOverlapOrder(t *testing.T) {
	calls := []map[string]any{olSearch("a", "first"), olSearch("b", "second"), olSearch("c", "third")}
	wantOut := func(res Result) []any {
		return []any{
			userMsg("go"),
			map[string]any{"type": "reasoning", "id": "rs0", "summary": []any{}},
			calls[0],
			map[string]any{"type": "message", "role": "assistant", "content": []any{map[string]any{"type": "output_text", "text": "thinking"}}},
			calls[1], calls[2],
			fout("a", "first"), fout("b", "second"), fout("c", "third"),
			res.Input[len(res.Input)-1],
		}
	}
	// reverse releases the three calls in reverse of their order, each only after the one
	// before it has finished, once all three are known to be running.
	reverse := func(t *testing.T, repo *olRepo) {
		repo.startedKeys(t, "first", "second", "third")
		for _, k := range []string{"third", "second", "first"} {
			repo.release(k)
			if got := repo.nextEnd(t); got != k {
				t.Fatalf("%q finished, want %q", got, k)
			}
		}
	}

	t.Run("responses", func(t *testing.T) {
		repo := newOLRepo(t)
		prov := newOLProvider(t, "responses",
			func(s *olStream) {
				s.reasoning(0)
				s.call(1, "a", "search_text", `{"pattern":"first"}`)
				s.text(2, "thinking")
				s.call(3, "b", "search_text", `{"pattern":"second"}`)
				s.call(4, "c", "search_text", `{"pattern":"third"}`)
				s.end()
			},
			olFinish,
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, sess)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
		reverse(t, repo)
		res, err := run.wait(t)
		if err != nil || res.Ending != EndTerminal || res.Requests != 2 {
			t.Fatalf("%+v %v", res, err)
		}
		if got, want := marshal(t, res.Input), marshal(t, wantOut(res)); got != want {
			t.Fatalf("history\n got %s\nwant %s", got, want)
		}
		reqs := prov.requests()
		if len(reqs) != 2 {
			t.Fatalf("%d requests", len(reqs))
		}
		var seq []string
		for _, it := range reqs[1]["input"].([]any) {
			m := it.(map[string]any)
			seq = append(seq, fmt.Sprint(m["type"], ":", m["call_id"]))
		}
		want := []string{"<nil>:<nil>", "reasoning:<nil>", "function_call:a", "message:<nil>", "function_call:b", "function_call:c",
			"function_call_output:a", "function_call_output:b", "function_call_output:c"}
		if !reflect.DeepEqual(seq, want) {
			t.Fatalf("next request input %v, want %v", seq, want)
		}
	})

	t.Run("messages", func(t *testing.T) {
		repo := newOLRepo(t)
		prov := newOLProvider(t, "messages",
			func(s *olStream) {
				s.text(0, "thinking")
				s.call(1, "a", "search_text", `{"pattern":"first"}`)
				s.call(2, "b", "search_text", `{"pattern":"second"}`)
				s.call(3, "c", "search_text", `{"pattern":"third"}`)
				s.end()
			},
			func(s *olStream) { s.call(0, "fin", "finish", `{}`); s.end() },
		)
		d, role, sess := olDirect(t, prov)
		rd := Round{Role: role, Definitions: olDefs(), Tools: olTools(t.TempDir(), repo, sess)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, d, Hooks{})
		reverse(t, repo)
		res, err := run.wait(t)
		if err != nil || res.Ending != EndTerminal {
			t.Fatalf("%+v %v", res, err)
		}
		reqs := prov.requests()
		if len(reqs) != 2 || !reflect.DeepEqual(olOutputIDs("messages", reqs[1]), []string{"a", "b", "c"}) {
			t.Fatalf("requests %v", reqs)
		}
		n := len(res.Input)
		if !reflect.DeepEqual(res.Input[n-5:n-2], []any{fout("a", "first"), fout("b", "second"), fout("c", "third")}) {
			t.Fatalf("history %v", res.Input)
		}
	})

	// A requester that only returns completed responses gets the same rules.
	t.Run("legacy requester", func(t *testing.T) {
		repo := newOLRepo(t)
		items := []map[string]any{calls[0], calls[1], calls[2]}
		end := fcall("end", "finish", `{}`)
		rq := &scriptRequester{script: [][]map[string]any{items, {end}}}
		rd := Round{Tools: olTools(t.TempDir(), repo, nil)}
		run := olStart(context.Background(), rd, []any{userMsg("go")}, rq, Hooks{})
		reverse(t, repo)
		res, err := run.wait(t)
		if err != nil {
			t.Fatal(err)
		}
		want := []any{userMsg("go"), calls[0], calls[1], calls[2], fout("a", "first"), fout("b", "second"), fout("c", "third")}
		if len(rq.requests) != 2 || !reflect.DeepEqual(rq.requests[1], want) {
			t.Fatalf("next request %#v, want %#v", rq.requests, want)
		}
		if !reflect.DeepEqual(res.Input, append(want, end)) || res.Ending != EndTerminal {
			t.Fatalf("result %#v", res)
		}
	})
}
