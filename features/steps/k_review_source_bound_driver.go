package build

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/executor/claudecode"
	"kogen/project"
)

// Observation only: mounted as a test with go -overlay; it changes no production source. Each
// mode runs the real Build over the real Claude Code adapter for both the build and the review
// role, against a scripted fake `claude` shell program (never the real claude binary), and
// writes the facts the acceptance steps assert.

const krsbScript = `#!/bin/sh
state="$KOGEN_KRSB_STATE"
case "$1" in
--version) echo "2.1.312 (Claude Code)"; exit 0;;
auth) echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0;;
esac
n=$(cat "$state/calls" 2>/dev/null || echo 0)
n=$((n+1))
echo $n > "$state/calls"
cat > "$state/call-$n.prompt"
sid=
prev=
role=build
for a in "$@"; do
  if [ "$prev" = --session-id ] || [ "$prev" = --resume ]; then sid=$a; fi
  if [ "$prev" = --json-schema ]; then case "$a" in *verdict*) role=review;; esac; fi
  prev=$a
done
printf '%s\n' "$sid" > "$state/call-$n.sid"
printf '%s\n' "$role" > "$state/call-$n.role"
cwd=$(pwd -P)
printf '{"type":"system","subtype":"init","cwd":"%s","session_id":"%s","mcp_servers":[],"model":"claude-opus-5-5","permissionMode":"acceptEdits","apiKeySource":"none","claude_code_version":"2.1.312"}\n' "$cwd" "$sid"
if [ "$role" = build ]; then
  if [ ! -f "$state/built" ]; then : > "$state/built"; sh "$state/build.sh"; fi
  sed "s/@SID@/$sid/" "$state/build-result.json"
  exit 0
fi
r=$(cat "$state/reviews" 2>/dev/null || echo 0)
r=$((r+1))
echo $r > "$state/reviews"
if [ -f "$state/review-$r.jsonl" ]; then sed "s/@SID@/$sid/" "$state/review-$r.jsonl"; else sed "s/@SID@/$sid/" "$state/approve.json"; fi
`

// krsbLines is shell that writes count lines of about 51 bytes, each naming tag, to file.
func krsbLines(file, tag string, count int) string {
	return fmt.Sprintf("awk 'BEGIN{for(n=1;n<=%d;n++) printf \"%s line %%06d review source bound fixture text\\n\", n}' > %s", count, tag, file)
}

func krsbResult(structured any) string {
	b, _ := json.Marshal(map[string]any{
		"type": "result", "subtype": "success", "is_error": false, "num_turns": 1, "session_id": "@SID@",
		"result": "round finished", "terminal_reason": "completed", "permission_denials": []any{}, "structured_output": structured,
	})
	return string(b) + "\n"
}

// The Claude Code 2.1.312 refusal observed in Build 6eb946ca (round-1.jsonl), session id replaced.
const krsbRefusal = `{"type":"system","subtype":"status","status":"compacting","compact_output_chars":0,"session_id":"@SID@","uuid":"2c3cbbb9-fc72-4c1d-9124-17fd285d9817"}
{"type":"system","subtype":"status","status":null,"compact_result":"failed","compact_error":"too_few_groups","session_id":"@SID@","uuid":"1c87e819-743d-4235-b2b9-a88e39084e5f"}
{"type":"assistant","message":{"id":"0ff1a240-2e64-4451-ab83-dc347b42f86c","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"text","text":"Prompt is too long"}]},"parent_tool_use_id":null,"session_id":"@SID@","uuid":"9e9aed68-43df-41a5-bf92-1fcce38d6b45","error":"invalid_request","is_api_error_message":true}
{"duration_api_ms":0,"stop_reason":"stop_sequence","session_id":"@SID@","total_cost_usd":0,"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"modelUsage":{},"permission_denials":[],"terminal_reason":"blocking_limit","is_error":true,"num_turns":1,"subtype":"success","api_error_status":null,"result":"Prompt is too long","type":"result","duration_ms":681}
`

type krsbCase struct {
	build   []string          // shell lines the builder round runs in the checkout
	reviews map[int]string    // review call -> complete stream after init
	blocks  map[string]string // fixture path -> its full-text heading
}

func krsbCases() map[string]krsbCase {
	block := func(verdict string) string {
		return krsbResult(map[string]any{"verdict": verdict, "findings": []any{map[string]any{"path": "big-1.txt", "line": 1, "severity": "blocking", "message": "part blocker"}}})
	}
	six := []string{"printf 'candidate\\n' > app.txt"}
	sixBlocks := map[string]string{}
	for i := 1; i <= 6; i++ {
		p := fmt.Sprintf("big-%d.txt", i)
		six = append(six, krsbLines(p, fmt.Sprintf("big-%d", i), 2300))
		sixBlocks[p] = "--- " + p + " (added; mode 100644)\n"
	}
	repro := []string{"printf 'candidate\\n' > app.txt", "mkdir -p lineup"}
	reproBlocks := map[string]string{}
	for i := 1; i <= 80; i++ {
		p := fmt.Sprintf("lineup/m-%02d.txt", i)
		repro = append(repro, krsbLines(p, fmt.Sprintf("m-%02d", i), 700))
		reproBlocks[p] = "--- " + p + " (added; mode 100644)\n"
	}
	return map[string]krsbCase{
		"small":       {build: []string{"printf 'candidate\\n' > app.txt", "printf 'small\\n' > small.txt"}},
		"six":         {build: six, blocks: sixBlocks},
		"repro":       {build: repro, blocks: reproBlocks},
		"large":       {build: []string{"printf 'candidate\\n' > app.txt", krsbLines("large.txt", "large", 23600)}},
		"part1-block": {build: six, blocks: sixBlocks, reviews: map[int]string{1: block("changes")}},
		"part2-block": {build: six, blocks: sixBlocks, reviews: map[int]string{2: block("changes")}},
		"authority":   {build: []string{"printf 'candidate\\n' > app.txt", krsbLines("README.md", "readme", 11800)}},
		"refusal":     {build: []string{"printf 'candidate\\n' > app.txt", "printf 'small\\n' > small.txt"}, reviews: map[int]string{1: krsbRefusal}},
	}
}

func krsbWrite(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestKReviewSourceBoundObservation runs every fixture named in KOGEN_KRSB_MODES (comma separated)
// and writes the facts of each, by fixture name, to KOGEN_KRSB_OUTPUT.
func TestKReviewSourceBoundObservation(t *testing.T) {
	all := map[string]any{}
	defer func() {
		raw, err := json.Marshal(all)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(os.Getenv("KOGEN_KRSB_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}()
	for _, mode := range strings.Split(os.Getenv("KOGEN_KRSB_MODES"), ",") {
		c, ok := krsbCases()[mode]
		if !ok {
			t.Fatalf("unknown fixture %q", mode)
		}
		out := map[string]any{"mode": mode}
		t.Run(mode, func(t *testing.T) { krsbObserve(t, c, out) })
		all[mode] = out
	}
}

// krsbObserve runs one fixture's Build and records its facts in out.
func krsbObserve(t *testing.T, c krsbCase, out map[string]any) {
	e := newEnv(t)
	e.useLineup("    max_rounds: 2\n")
	start := e.head()

	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(dir, "home")
	bin := claudecode.RuntimePath(home)
	if err := os.MkdirAll(filepath.Dir(bin), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bin, []byte(krsbScript), 0o755); err != nil {
		t.Fatal(err)
	}
	krsbWrite(t, filepath.Join(state, "build.sh"), strings.Join(c.build, "\n")+"\n")
	krsbWrite(t, filepath.Join(state, "build-result.json"), krsbResult(map[string]any{"summary": "built"}))
	krsbWrite(t, filepath.Join(state, "approve.json"), krsbResult(map[string]any{"verdict": "approve", "findings": []any{}}))
	for r, stream := range c.reviews {
		krsbWrite(t, filepath.Join(state, fmt.Sprintf("review-%d.jsonl", r)), stream)
	}
	env := append(append([]string{}, e.git...), "PATH="+os.Getenv("PATH"), "KOGEN_KRSB_STATE="+state)
	x := claudecode.New(claudecode.Options{Home: home, HookCommand: []string{"/bin/true"}, Env: env})
	a := e.build(func(in *Input) {
		in.External = func(project.Role) (executor.Executor, error) { return x, nil }
		in.Reviewer = nil
	})

	out["exit"] = a.exit
	out["stdout"] = a.out.String()
	out["err"] = ""
	if se, ok := sys.AsError(a.err); ok {
		out["err"] = se.Class + "/" + se.Reason + ": " + se.Detail
		out["err_lines"] = se.Lines
	} else if a.err != nil {
		out["err"] = a.err.Error()
	}
	out["commits"] = strings.TrimSpace(e.commitsSince(start))
	out["head_same"] = e.head() == start

	// The calls the fake received.
	calls := 0
	if b, err := os.ReadFile(filepath.Join(state, "calls")); err == nil {
		fmt.Sscan(strings.TrimSpace(string(b)), &calls)
	}
	type call struct {
		sid, role, prompt string
	}
	var all []call
	for n := 1; n <= calls; n++ {
		p, _ := os.ReadFile(filepath.Join(state, fmt.Sprintf("call-%d.prompt", n)))
		s, _ := os.ReadFile(filepath.Join(state, fmt.Sprintf("call-%d.sid", n)))
		r, _ := os.ReadFile(filepath.Join(state, fmt.Sprintf("call-%d.role", n)))
		all = append(all, call{strings.TrimSpace(string(s)), strings.TrimSpace(string(r)), string(p)})
	}
	buildSIDs, reviewSIDs := map[string]bool{}, []string{}
	reviewPrompt := map[string]string{}
	var promptBytes []int
	for _, k := range all {
		if k.role == "build" {
			buildSIDs[k.sid] = true
			continue
		}
		if _, seen := reviewPrompt[k.sid]; !seen {
			reviewSIDs = append(reviewSIDs, k.sid)
			reviewPrompt[k.sid] = k.prompt
			promptBytes = append(promptBytes, len(k.prompt))
		}
	}
	out["review_sessions"] = len(reviewSIDs)
	out["review_prompt_bytes"] = promptBytes
	distinct := len(reviewSIDs) > 0
	for _, s := range reviewSIDs {
		if buildSIDs[s] || s == "" {
			distinct = false
		}
	}
	out["review_sessions_fresh"] = distinct

	intentText := e.read(project.IntentMDPath(testSlug))
	featureText := e.read(project.FeaturePath(testSlug))
	authorityComplete := len(reviewSIDs) > 0
	for _, s := range reviewSIDs {
		if !strings.Contains(reviewPrompt[s], intentText) || !strings.Contains(reviewPrompt[s], featureText) {
			authorityComplete = false
		}
	}
	out["authority_in_every_prompt"] = authorityComplete

	kept := true
	for _, line := range c.build {
		if f := strings.Fields(line); len(f) > 0 && f[len(f)-2] == ">" {
			if _, err := os.Stat(filepath.Join(e.root, f[len(f)-1])); err != nil {
				kept = false
			}
		}
	}
	out["candidate_kept"] = kept

	runs, _ := filepath.Glob(filepath.Join(e.root, ".kogen/local/runs/*"))
	if len(runs) != 1 {
		t.Fatalf("want one run folder, found %v", runs)
	}
	run := runs[0]
	out["outcome"] = fmt.Sprint(e.jsonFile(filepath.Join(run, "result.json"))["outcome"])
	logText, _ := os.ReadFile(filepath.Join(run, "log.jsonl"))
	var partsEvents []any
	var failed []any
	for _, line := range strings.Split(string(logText), "\n") {
		var ev map[string]any
		if json.Unmarshal([]byte(line), &ev) != nil {
			continue
		}
		switch ev["event"] {
		case "review_parts":
			partsEvents = append(partsEvents, ev["parts"])
		case "executor_round_failed":
			failed = append(failed, ev["reason"])
		}
	}
	out["review_parts_events"] = partsEvents
	out["round_failed_reasons"] = failed

	rev := filepath.Join(run, "executor-review")
	authority, aerr := os.ReadFile(filepath.Join(rev, "review-1-authority.txt"))
	source, serr := os.ReadFile(filepath.Join(rev, "review-1-source.txt"))
	out["material"] = aerr == nil && serr == nil
	out["inline_exact"] = false
	if aerr == nil && serr == nil && len(reviewSIDs) == 1 {
		out["inline_exact"] = reviewPrompt[reviewSIDs[0]] == claudecode.ReviewConstraints+"\n\n"+string(authority)+"\n\n"+string(source)
	}

	// The parts the review recorded, checked against the prompts actually received.
	var material map[string]any
	if raw, err := os.ReadFile(filepath.Join(rev, "review-1-material.json")); err == nil {
		json.Unmarshal(raw, &material)
	}
	list, _ := material["review_parts"].([]any)
	out["parts"] = len(list)
	exact, contiguous, carried, headed, sizes, delivered := len(list) > 0, len(list) > 0, len(list) > 0, len(list) > 0, len(list) > 0, len(list) > 0
	var slices []string
	at := 0
	for i, item := range list {
		p, _ := item.(map[string]any)
		from, _ := p["from"].(float64)
		to, _ := p["to"].(float64)
		file, _ := p["file"].(string)
		sid, _ := p["session_id"].(string)
		pb, _ := p["prompt_bytes"].(float64)
		if int(from) != at || to < from || int(to) > len(source) {
			contiguous = false
			slices = append(slices, "")
			continue
		}
		at = int(to)
		slice := string(source[int(from):int(to)])
		slices = append(slices, slice)
		text, err := os.ReadFile(filepath.Join(rev, file))
		if file == "" || err != nil || !strings.Contains(string(text), slice) {
			carried = false
		}
		if !strings.HasPrefix(string(text), fmt.Sprintf("# Review part %d of %d\n", i+1, len(list))) {
			headed = false
		}
		prompt, ok := reviewPrompt[sid]
		if !ok || prompt != claudecode.ReviewConstraints+"\n\n"+string(authority)+"\n\n"+string(text) {
			exact = false
		}
		if !ok || int(pb) != len(prompt) {
			sizes = false
		}
		if d, _ := p["delivered"].(bool); !d && i < len(reviewSIDs) {
			delivered = false
		}
	}
	if at != len(source) {
		contiguous = false
	}
	out["parts_exact_prompts"] = exact
	out["parts_contiguous"] = contiguous
	out["parts_carry_slices"] = carried
	out["parts_headed"] = headed
	out["parts_prompt_bytes_recorded"] = sizes
	out["parts_delivered"] = delivered

	// Fixture blocks split across parts, and slices that end inside a line.
	var split []string
	for p, heading := range c.blocks {
		content := e.read(p)
		whole := false
		for _, s := range slices {
			if strings.Contains(s, heading+content) {
				whole = true
			}
		}
		if !whole {
			split = append(split, p)
		}
	}
	sort.Strings(split)
	out["blocks_split"] = split
	midLine := 0
	for i, s := range slices {
		if i < len(slices)-1 && !strings.HasSuffix(s, "\n") {
			midLine++
		}
	}
	out["slices_ending_mid_line"] = midLine
}
