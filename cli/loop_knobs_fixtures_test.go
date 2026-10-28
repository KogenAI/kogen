package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"kogen-loop/provider"
	"kogen-loop/tools"
	"kogen/agent"
)

// testdata/loop_knobs_golden.json holds knobFixtureRequests and the cuts of knobFixtureRaw as the
// previous pin (c7e8331f) rendered them, through knobNormalize: provider.Client.Body of the
// request as built here and tools.Cut of each raw result. TestLoopKnobsZeroCompatibility renders
// the same through the research settings and compares.

// knobFixtureRoles are one role per wire, as the request fixtures render them.
var knobFixtureRoles = []provider.Role{
	{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"},
	{Provider: "supergrok", Model: "grok-4.7", Effort: "high"},
	{Provider: "opencode-go", Model: "kimi-k3", Effort: "high"},
	{Provider: "anthropic", Model: "claude-opus-5-5", Effort: "high"},
	{Provider: "openai-compatible", Model: "local-model", Effort: "medium", BaseURL: "http://localhost:11434/v1"},
}

// knobFixtureEveryTool is every tool definition a Shape, Refine, Build or Review request offers.
var knobFixtureEveryTool = []string{tools.ShellTool, tools.ViewImageTool, tools.ReadFileTool, tools.WriteFileTool, agent.ReportBlockerTool, agent.FinishTool,
	tools.ListFilesTool, tools.SearchTextTool, agent.ProbeTool, tools.DocumentationTool, agent.SubmitTool, agent.SubmitReviewTool,
	agent.SubmitRefinementTool, agent.SubmitConfigurationTool, agent.ShapeBatchTool, agent.WorkerResultTool}

// knobFixtureRaw are tool results as a tool returns them: just inside, just over and far over
// the 16384-byte bound, the last with multibyte text.
func knobFixtureRaw() []string {
	return []string{
		strings.Repeat("a", 16384),
		strings.Repeat("b", 16385),
		strings.Repeat("héllo 🙂 wörld\n", 3000),
	}
}

// knobFixtureInput is a conversation with tool calls and their results; cut is the delivery
// of one tool result.
func knobFixtureInput(cut func(string) string) []any {
	input := []any{
		map[string]any{"role": "user", "content": "Authority: the approved Intent and its protected files."},
		map[string]any{"role": "user", "content": "Cumulative proposal manifest: []"},
	}
	for i, raw := range knobFixtureRaw() {
		id := fmt.Sprintf("call-%d", i)
		args, _ := json.Marshal(map[string]any{"path": fmt.Sprintf("file-%d.txt", i)})
		input = append(input,
			map[string]any{"type": "function_call", "call_id": id, "name": "read_file", "arguments": string(args)},
			map[string]any{"type": "function_call_output", "call_id": id, "output": cut(raw)},
		)
	}
	return append(input, map[string]any{"role": "user", "content": "Continue."})
}

// knobFixtureRequests are the requests of every wire with the full tool set and a
// conversation, as the Client renders them.
func knobFixtureRequests(cut func(string) string, request func(provider.Request) provider.Request, body func(provider.Request) map[string]any) []map[string]any {
	var out []map[string]any
	for _, role := range knobFixtureRoles {
		req := request(provider.Request{
			Role: role, Instructions: "Policy of the fixture.", Input: knobFixtureInput(cut),
			Tools: agent.AsAny(agent.Defs(knobFixtureEveryTool...)), CacheID: "knob-fixture-cache",
		})
		out = append(out, map[string]any{"provider": role.Provider, "body": body(req)})
	}
	return out
}

// knobNormalize is a request body as the golden keeps it: decoded JSON in which the
// documentation tool definition (the one text the new pin changes) is a placeholder and every
// string over 256 bytes is its length and SHA-256, so the golden stays small and a difference
// of one byte still shows.
func knobNormalize(v any) any {
	raw, _ := json.Marshal(v)
	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		panic(err)
	}
	var walk func(v any) any
	walk = func(v any) any {
		switch x := v.(type) {
		case map[string]any:
			if x["name"] == tools.DocumentationTool && (x["parameters"] != nil || x["input_schema"] != nil) {
				return "<documentation tool definition>"
			}
			for k, e := range x {
				x[k] = walk(e)
			}
			return x
		case []any:
			for i, e := range x {
				x[i] = walk(e)
			}
			return x
		case string:
			if len(x) > 256 {
				sum := sha256.Sum256([]byte(x))
				return fmt.Sprintf("sha256:%s:%d", hex.EncodeToString(sum[:]), len(x))
			}
		}
		return v
	}
	return walk(decoded)
}
