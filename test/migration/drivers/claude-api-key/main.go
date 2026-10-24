// Command driver exercises the provider transport and the request-budget measurement of the Go
// engine directly, for the claude-api-key-provider acceptance suite. It reads one JSON request
// file and writes one JSON receipt file: `driver <request.json> <receipt.json>`.
//
// Only observations that have no installed-CLI form live here: the answer one logical provider
// call returns to its caller (items, validated usage, attempt records) and the exact size of the
// complete next request. Everything else in the suite runs through the installed `kogen`.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"kogen/agent"
	"kogen/provider"
	"kogen/sys"
)

type request struct {
	Mode     string `json:"mode"`
	Home     string `json:"home"`
	URL      string `json:"url"`
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Effort   string `json:"effort"`
	Budget   int    `json:"budget"`
	Image    bool   `json:"image"`
}

type records struct{ rows []map[string]any }

func (r *records) Attempt(rec map[string]any) { r.rows = append(r.rows, rec) }

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func tools() []any {
	return []any{map[string]any{
		"type": "function", "name": "read_file", "description": "Read local text", "strict": true,
		"parameters": map[string]any{
			"type":                 "object",
			"properties":           map[string]any{"path": map[string]any{"type": "string"}},
			"required":             []any{"path"},
			"additionalProperties": false,
		},
	}}
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: driver <request.json> <receipt.json>")
		os.Exit(2)
	}
	raw, err := os.ReadFile(os.Args[1])
	must(err)
	var c request
	must(json.Unmarshal(raw, &c))
	role := provider.Role{Provider: c.Provider, Model: c.Model, Effort: c.Effort}
	if role.Provider == "" {
		role.Provider = "anthropic"
	}
	if role.Model == "" {
		role.Model = "claude-opus-5-5"
	}
	if role.Effort == "" {
		role.Effort = "high"
	}
	s := sys.NewWith([]string{"HOME=" + c.Home, "KOGEN_PROVIDER_URL=" + c.URL, "KOGEN_AUTH_URL=" + c.URL}, c.Home)
	client := provider.NewClient("kogen test (driver)")
	base := []any{map[string]any{"role": "user", "content": "LOCAL_NATIVE_CONTRACT"}}
	var result any
	switch c.Mode {
	case "budget":
		result = budget(client, role)
	default:
		result = transport(client, s, role, c, base)
	}
	out, err := json.Marshal(result)
	must(err)
	must(os.WriteFile(os.Args[2], out, 0o600))
}

// budget renders the complete next request at the three byte sizes around the 524288-byte
// ceiling and measures each the way the engine does.
func budget(client *provider.Client, role provider.Role) map[string]any {
	render := func(text string) map[string]any {
		return client.Body(provider.Request{Role: role, Instructions: "LOCAL_POLICY", Input: []any{map[string]any{"role": "user", "content": text}}, Tools: tools(), Scope: "budget"})
	}
	size := func(text string) int {
		m, err := agent.Measure(render(text))
		must(err)
		return m.RenderedBytes
	}
	var bodies []map[string]any
	var bytes []int
	var fits []bool
	var reserve []int
	for _, target := range []int{524287, 524288, 524289} {
		n := target - size("")
		for i := 0; i < 8 && size(strings.Repeat("x", n)) != target; i++ {
			n += target - size(strings.Repeat("x", n))
		}
		body := render(strings.Repeat("x", n))
		m, err := agent.Measure(body)
		must(err)
		bodies = append(bodies, body)
		bytes, fits, reserve = append(bytes, m.RenderedBytes), append(fits, m.Fits), append(reserve, m.OutputReserveTokens)
	}
	isMessages := true
	for _, b := range bodies {
		_, hasMessages := b["messages"].([]any)
		_, hasInput := b["input"]
		isMessages = isMessages && hasMessages && !hasInput
	}
	return map[string]any{"body_is_messages": isMessages, "bytes": bytes, "fits": fits, "reserve": reserve}
}

type outcome struct {
	Outcome string           `json:"outcome"`
	Detail  string           `json:"detail"`
	Items   []map[string]any `json:"items"`
	Usage   map[string]any   `json:"usage"`
	Records []map[string]any `json:"records"`
	Elapsed int64            `json:"elapsed"`
	Value   bool             `json:"value"`
}

func invoke(client *provider.Client, s *sys.Session, role provider.Role, c request, scope string, input []any) outcome {
	obs := &records{}
	started := time.Now()
	budget := time.Duration(c.Budget) * time.Millisecond
	if budget == 0 {
		budget = 15 * time.Second
	}
	resp, err := client.Respond(s.Context(), s, provider.Request{Role: role, Instructions: "LOCAL_POLICY", Input: input, Tools: tools(), Budget: budget, Scope: scope}, obs)
	o := outcome{Records: obs.rows, Elapsed: time.Since(started).Milliseconds()}
	if err != nil {
		var e *sys.Error
		var i *sys.Interrupted
		switch {
		case errors.As(err, &e):
			o.Outcome, o.Detail = e.Class+"/"+e.Reason, e.Detail
		case errors.As(err, &i):
			o.Outcome = "cancel/" + i.Signal
		default:
			must(err)
		}
		return o
	}
	o.Outcome, o.Value, o.Items, o.Usage = "completed", true, resp.Items, resp.Known.Map()
	return o
}

// transport is one conversation: a first request, its replay with one result per tool call
// after a save and reload of the conversation, and an independent review of the base input.
func transport(client *provider.Client, s *sys.Session, role provider.Role, c request, base []any) map[string]any {
	input := base
	if c.Image {
		input = append(append([]any{}, base...), map[string]any{"type": "function_call_output", "call_id": "image", "output": []any{
			map[string]any{"type": "input_text", "text": "{}"},
			map[string]any{"type": "input_image", "image_url": "data:image/png;base64,synthetic"},
		}})
	}
	first := invoke(client, s, role, c, "local-build", input)
	results := []outcome{first}
	var calls []map[string]any
	for _, item := range first.Items {
		if item["type"] == "function_call" {
			calls = append(calls, item)
		}
	}
	if len(calls) > 0 {
		next := append([]any{}, input...)
		next = append(next, agent.Replay(first.Items)...)
		for _, call := range calls {
			next = append(next, agent.OutputItem(call["call_id"], "LOCAL_TOOL_RESULT:"+fmt.Sprint(call["call_id"])))
		}
		// The saved conversation is reloaded from its serialized form.
		saved, err := json.Marshal(next)
		must(err)
		var reloaded []any
		must(json.Unmarshal(saved, &reloaded))
		results = append(results, invoke(client, s, role, c, "local-build", reloaded))
		results = append(results, invoke(client, s, role, c, "local-independent-review", base))
	}
	return map[string]any{"results": results}
}
