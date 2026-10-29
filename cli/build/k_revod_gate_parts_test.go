package build

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/agent"
	"kogen/project"
)

// The default parts mode is unchanged by the on_demand hunk gate (k-revod-gate): every
// provider request of a long parts-mode review (instructions, authority, catalog, guidance,
// native source data, reset handoff, tool schema and replay) is byte for byte what the code
// before the gate sent. testdata/k-revod-gate/parts-requests.json was written by this very
// scenario run against that earlier code (KOGEN_REVOD_GATE_GOLDEN=write), not recomputed from
// the current production code.

const revodGateGolden = "testdata/k-revod-gate/parts-requests.json"

// revodGateFixedDir is a new temporary folder whose physical path has exactly n bytes, so that
// the requests carrying it have the same size (and so the same windows and native data) on
// every host and run.
func revodGateFixedDir(t *testing.T, n int) string {
	t.Helper()
	base := physical(t, t.TempDir())
	pad := n - len(base) - 1
	if pad < 1 || pad > 200 {
		t.Fatalf("temporary folder %s cannot be padded to %d bytes", base, n)
	}
	dir := filepath.Join(base, strings.Repeat("p", pad))
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	return dir
}

// revodGatePartsRequests runs a long parts-mode review (pinned parts, native source data, a
// working-window reset, reads and approval) and returns every reviewer request body with only
// the run-specific values replaced: the temporary folders, the run id, the cache identity and
// the hashes of the working-context archives (which hold those folders).
func revodGatePartsRequests(t *testing.T) []string {
	t.Helper()
	dates := []string{"GIT_AUTHOR_DATE=2026-10-22T00:00:00Z", "GIT_COMMITTER_DATE=2026-10-22T00:00:00Z"}
	aux := revodGateFixedDir(t, 220)
	// The committed configuration names the acceptance script through the environment, so the
	// start HEAD, the candidate tree and the authority are the same in every run.
	t.Setenv("KOGEN_REVOD_GATE_ACCEPT", filepath.Join(aux, "accept.sh"))
	e := newEnvIn(t, revodGateFixedDir(t, 220), revodGateFixedDir(t, 220), aux, dates, func(c *project.Config) {
		c.Acceptance.Run = `sh "$KOGEN_REVOD_GATE_ACCEPT"`
	})
	f := e.prov
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": bigFile()}, "finish", map[string]any{"summary": "done"}))
	for i := 0; i < 3; i++ {
		f.then(f.calls("write_file", map[string]any{"path": ".kogen/local/padding", "content": strings.Repeat("x", 190_000)}))
	}
	reader := confirmingReviewer(t, f, nil)
	for i := 0; i < 40; i++ {
		f.then(reader)
	}
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || e.head() == start {
		t.Fatalf("not landed: %d %s %s", a.exit, a.shown(), a.errs)
	}
	run := e.onlyRun()
	var bodies []string
	for i, raw := range f.rawRequests() {
		req := f.requests()[i]
		if requestInstructions(req) != agent.Prompt(agent.Reviewer) {
			continue
		}
		text := string(raw)
		if key, ok := req["prompt_cache_key"].(string); ok && key != "" {
			text = strings.ReplaceAll(text, key, "<CACHE>")
		}
		if reset := resetHandoff(t, req); reset != nil {
			for _, h := range reset["history"].([]any) {
				ref := h.(map[string]any)
				if strings.Contains(ref["path"].(string), "/working-context/") {
					text = strings.ReplaceAll(text, ref["sha256"].(string), "<ARCHIVE>")
				}
			}
		}
		for old, repl := range map[string]string{e.root: "<ROOT>", e.home: "<HOME>", e.aux: "<AUX>"} {
			text = strings.ReplaceAll(text, old, repl)
		}
		bodies = append(bodies, strings.ReplaceAll(text, "/runs/"+run+"/", "/runs/<RUN>/"))
	}
	return bodies
}

type revodGateRequest struct {
	Bytes  int    `json:"bytes"`
	SHA256 string `json:"sha256"`
	// Markers are facts of the request the comparison relies on having exercised.
	Prefill bool `json:"prefill"`
	Reset   bool `json:"reset"`
	Reads   int  `json:"read_file_calls"`
}

func revodGateDescribe(t *testing.T, bodies []string) []revodGateRequest {
	t.Helper()
	out := make([]revodGateRequest, len(bodies))
	for i, body := range bodies {
		var req map[string]any
		if err := json.Unmarshal([]byte(body), &req); err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256([]byte(body))
		out[i] = revodGateRequest{Bytes: len(body), SHA256: hex.EncodeToString(sum[:]),
			Prefill: strings.Contains(body, jsonEscaped(prefillMarker)), Reset: resetHandoff(t, req) != nil,
			Reads: strings.Count(body, `"name":"read_file"`)}
	}
	return out
}

func jsonEscaped(s string) string {
	raw, _ := json.Marshal(s)
	return strings.Trim(string(raw), `"`)
}

func TestKRevodGatePartsUnchanged(t *testing.T) {
	bodies := revodGatePartsRequests(t)
	got := revodGateDescribe(t, bodies)
	if os.Getenv("KOGEN_REVOD_GATE_GOLDEN") == "write" {
		raw, err := json.MarshalIndent(got, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(revodGateGolden), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(revodGateGolden, append(raw, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Skip("golden written")
	}
	raw, err := os.ReadFile(revodGateGolden)
	if err != nil {
		t.Fatal(err)
	}
	var want []revodGateRequest
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatal(err)
	}
	// The scenario must have exercised what the comparison is about.
	prefill, reset := false, false
	for _, w := range want {
		prefill, reset = prefill || w.Prefill, reset || w.Reset
	}
	if len(want) < 3 || !prefill || !reset {
		t.Fatalf("the frozen scenario lacks native source data or a reset: %+v", want)
	}
	if len(got) != len(want) {
		t.Fatalf("%d parts-mode review requests, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			lacks(t, "parts-mode request", bodies[i], "required_parts")
			t.Errorf("parts-mode review request %d changed: %+v, want %+v", i+1, got[i], want[i])
		}
	}
	// No on_demand policy leaks into the default requests.
	for i, body := range bodies {
		for _, s := range []string{"required_parts", "required_unread", "on_demand", "hunk-covering", "covering changed hunks"} {
			if strings.Contains(body, s) {
				t.Errorf("parts-mode review request %d carries %q", i+1, s)
			}
		}
	}
	t.Run("empty-source controls", revodGateEmptySourceControls)
}
