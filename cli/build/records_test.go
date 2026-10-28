package build

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/tools"
)

func TestRequestUsageCarriesCacheWriteOrNull(t *testing.T) {
	seven := 7
	for _, c := range []struct {
		write *int
		want  string
	}{{&seven, `"cache_write":7`}, {nil, `"cache_write":null`}} {
		raw, err := json.Marshal(requestUsageOf(zeroTokens(), &provider.Response{Known: provider.KnownUsage{Write: c.write}}))
		if err != nil || !strings.Contains(string(raw), c.want) || !strings.Contains(string(raw), `"cached":0`) {
			t.Fatalf("%s %v", raw, err)
		}
	}
}

func TestCutFieldsOnlyForCutResults(t *testing.T) {
	if cutFields(strings.Repeat("x", 16384)) != nil {
		t.Fatal("an uncut result has cut fields")
	}
	f := cutFields(tools.Cut(strings.Repeat("x", 40960)))
	if f["bytes_before_cut"] != 40960 || f["bytes_delivered"].(int) > 16384 {
		t.Fatalf("%v", f)
	}
}

func TestAnAnthropicBuildRequestRecordsCacheCreationAsCacheWrite(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	cfgPath := filepath.Join(e.root, ".kogen/project.yaml")
	cfg, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	role := regexp.MustCompile(`(?m)^  build:\n(    .*\n)+`)
	writeFile(t, cfgPath, string(role.ReplaceAll(cfg, []byte("  build: {provider: anthropic, model: claude-sonnet-5-5, effort: high}\n"))), 0o644)
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "anthropic build role")
	e.approve()
	dir := filepath.Join(e.home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		t.Fatal(err)
	}
	e.prov.then(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		frame := func(v map[string]any) {
			io.WriteString(w, "event: "+v["type"].(string)+"\ndata: "+jsonText(v)+"\n\n")
		}
		frame(map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_fixture", "model": "claude-sonnet-5-5",
			"usage": map[string]any{"input_tokens": 7, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 9}}})
		for i, b := range []map[string]any{
			{"type": "tool_use", "id": "w1", "name": "write_file", "input": map[string]any{"path": "app.txt", "content": "candidate\n"}},
			{"type": "tool_use", "id": "f1", "name": "finish", "input": map[string]any{"summary": "done"}},
		} {
			frame(map[string]any{"type": "content_block_start", "index": i, "content_block": b})
			frame(map[string]any{"type": "content_block_stop", "index": i})
		}
		frame(map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": "tool_use"}, "usage": map[string]any{"output_tokens": 4}})
		frame(map[string]any{"type": "message_stop"})
	})
	e.prov.then(submit(e.prov, "approve"))
	a := e.build()
	if a.exit != 0 {
		t.Fatalf("exit %d\n%s\n%s", a.exit, a.shown(), a.errs)
	}
	var builds int
	for _, ev := range eventsNamed(e.events(e.onlyRun()), "request") {
		usage, _ := ev["usage"].(map[string]any)
		if _, ok := usage["cache_write"]; !ok {
			t.Fatalf("request without usage.cache_write: %v", ev)
		}
		if ev["role"] == "build" {
			builds++
			eq(t, "anthropic cache_write", usage["cache_write"], any(float64(9)))
		}
	}
	eq(t, "build requests", builds, 1)
}
