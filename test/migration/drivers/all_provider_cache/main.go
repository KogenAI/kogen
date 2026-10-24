package main

import (
	"context"
	"encoding/json"
	"fmt"
	"kogen/agent"
	"kogen/provider"
	"kogen/sys"
	"os"
	"strings"
	"time"
)

type observer struct{ Rows []any }

func (o *observer) Attempt(r map[string]any) { o.Rows = append(o.Rows, map[string]any{"provider": r}) }
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
func run() error {
	var c map[string]any
	b, e := os.ReadFile(os.Args[1])
	if e != nil {
		return e
	}
	if e = json.Unmarshal(b, &c); e != nil {
		return e
	}
	a := c["authority"].(map[string]any)
	text := func(m map[string]any, k string) string { v, _ := m[k].(string); return v }
	env := append(os.Environ(), "HOME="+text(c, "home"), "KOGEN_PROVIDER_URL="+text(c, "url"))
	s := sys.NewWith(env, ".")
	client := &provider.Client{Cache: provider.NewCache(nil)}
	obs := &observer{}
	role := provider.Role{Provider: text(c, "provider"), Model: text(c, "model"), Effort: text(c, "effort")}
	tools := []any{map[string]any{"type": "function", "name": "read_file", "description": "Read exact text", "parameters": map[string]any{"type": "object", "properties": map[string]any{"path": map[string]any{"type": "string"}}, "required": []any{"path"}, "additionalProperties": false}, "strict": true}}
	base := []any{map[string]any{"role": "user", "content": provider.ContractBlocks(text(a, "contract"), "dynamic suffix")}}
	scope := "fixture-build"
	req := func(input []any) provider.Request {
		return provider.Request{Role: role, Instructions: text(a, "policy"), Input: input, Tools: tools, Scope: scope, Single: c["single"] == true, Budget: 10 * time.Second, Context: map[string]any{"phase": "shape", "role": "shape"}}
	}
	call := func(input []any) (map[string]any, *provider.Response) {
		r, e := client.Respond(context.Background(), s, req(input), obs)
		if e != nil {
			outcome := "failed"
			if v, ok := e.(*sys.Error); ok {
				outcome = v.Class + "/" + v.Reason
			}
			return map[string]any{"outcome": outcome, "value": nil}, nil
		}
		return map[string]any{"outcome": "completed", "value": map[string]any{"usage": r.Known.Map()}}, r
	}
	result := map[string]any{}
	if c["mode"] == "budget" {
		render := func(t string) map[string]any {
			return client.Body(req([]any{map[string]any{"role": "user", "content": t}}))
		}
		raw, _ := json.Marshal(render(""))
		overhead := len(raw)
		limit := int(a["limit"].(float64))
		sizes := []int{}
		fits := []bool{}
		reserves := []int{}
		for _, n := range []int{limit - 1, limit, limit + 1} {
			r, _ := json.Marshal(render(strings.Repeat("x", n-overhead)))
			sizes = append(sizes, len(r))
			fits = append(fits, len(r) <= provider.InputBudgetBytes)
			reserves = append(reserves, 131072)
		}
		results := []any{}
		for _, n := range []int{limit, limit + 1} {
			r, _ := call([]any{map[string]any{"role": "user", "content": strings.Repeat("x", n-overhead)}})
			results = append(results, r)
		}
		result = map[string]any{"bytes": sizes, "fits": fits, "reserves": reserves, "results": results}
	} else {
		first, r := call(base)
		results := []any{first}
		if r != nil {
			next := append([]any{}, base...)
			for _, it := range r.Items {
				if replay := agent.ReplayItem(it); replay != nil {
					next = append(next, replay)
				}
			}
			for _, it := range r.Items {
				if it["type"] == "function_call" {
					next = append(next, agent.OutputItem(it["call_id"], text(a, "tool_result")+":"+fmt.Sprint(it["call_id"])))
				}
			}
			saved, _ := json.Marshal(client.Cache.States())
			var states map[string]provider.CacheState
			if e = json.Unmarshal(saved, &states); e != nil {
				return e
			}
			client.Cache = provider.NewCache(states)
			second, _ := call(next)
			results = append(results, second)
			if c["mode"] != "refusal" {
				scope = "fixture-independent-review"
				third, _ := call(base)
				scope = "fixture-new-context"
				fourth, _ := call(base)
				results = append(results, third, fourth)
			}
		}
		result["results"] = results
	}
	result["rows"] = obs.Rows
	out, e := json.Marshal(result)
	if e != nil {
		return e
	}
	return os.WriteFile(os.Args[2], out, 0600)
}
