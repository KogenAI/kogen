package build

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"kogen/agent"
	"kogen/executor"
	"kogen/executor/claudecode"
	"kogen/project"
)

// The frozen `build --context` diagnostic reaches the builder's first prompt and every
// independent reviewer, whichever executors serve the build and review roles.

const builderSentinel = "builder-claim-sentinel"

// extCombo is one pairing of builder and reviewer executors: native, or the claude-code fake.
type extCombo struct {
	name                string
	extBuild, extReview bool
}

var extCombos = []extCombo{
	{"native/native", false, false},
	{"native/external", false, true},
	{"external/native", true, false},
	{"external/external", true, true},
}

// useRoles selects claude-code for the build and/or review role, commits the configuration and
// approves again. Neither external role leaves the project as it is.
func (e *env) useRoles(extBuild, extReview bool) {
	e.t.Helper()
	if !extBuild && !extReview {
		return
	}
	path := filepath.Join(e.root, ".kogen/project.yaml")
	b, err := os.ReadFile(path)
	if err != nil {
		e.t.Fatal(err)
	}
	text := string(b)
	if extBuild {
		re := regexp.MustCompile(`(?m)^  build:\n(    .*\n)+`)
		if !re.MatchString(text) {
			e.t.Fatalf("project.yaml lacks the build role:\n%s", text)
		}
		text = re.ReplaceAllString(text, "  build:\n    executor: claude-code\n    model: claude-sonnet-5-5\n    effort: high\n")
	}
	if extReview {
		re := regexp.MustCompile(`(?m)^  review:\n(    .*\n)+`)
		if !re.MatchString(text) {
			e.t.Fatalf("project.yaml lacks the review role:\n%s", text)
		}
		text = re.ReplaceAllString(text, "  review:\n    executor: claude-code\n    model: claude-opus-5-5\n    effort: xhigh\n")
	}
	writeFile(e.t, path, text, 0o644)
	e.run("git", "add", ".kogen/project.yaml")
	e.run("git", "commit", "-qm", "claude-code roles")
	e.approve()
}

// touchSource changes or deletes the diagnostic's original source file: it is a label, not
// something the Build may read again.
func touchSource(t *testing.T, path, how string) {
	t.Helper()
	switch how {
	case "changed":
		writeFile(t, path, "the original source was edited after the Build began\n", 0o644)
	case "deleted":
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
	}
}

// runCombo runs a complete Build of the fixture with the given executors. The native builder
// and reviewer are scripted through the local provider, the external ones through the fake
// executor; both finish with the same candidate. A non-empty source is changed (or deleted)
// by the builder while it works.
func runCombo(t *testing.T, e *env, c extCombo, d *Diagnostic, sourceHow string) (*lineupExec, int) {
	t.Helper()
	e.useRoles(c.extBuild, c.extReview)
	f := newLineupExec(t)
	f.build = func(n int, root string, in executor.Input) (executor.RoundResult, error) {
		if d != nil && sourceHow != "" {
			touchSource(t, d.SourcePath, sourceHow)
		}
		lineupWriteApp(t, root, "candidate\n")
		return executor.RoundResult{Claim: builderSentinel}, nil
	}
	f.review = func(n int, root string, in executor.Input, task executor.Task) (executor.RoundResult, error) {
		return executor.RoundResult{Structured: verdictJSON("approve")}, nil
	}
	if !c.extBuild {
		var script []any
		if d != nil && sourceHow != "" {
			cmd := "rm -f '" + d.SourcePath + "'"
			if sourceHow == "changed" {
				cmd = "printf 'the original source was edited after the Build began\\n' > '" + d.SourcePath + "'"
			}
			script = append(script, "shell", map[string]any{"command": cmd})
		}
		script = append(script, "write_file", map[string]any{"path": "app.txt", "content": "candidate\n"}, "finish", map[string]any{"summary": builderSentinel})
		e.prov.then(e.prov.calls(script...))
	}
	if !c.extReview {
		e.prov.then(submit(e.prov, "approve"))
	}
	start, offset := e.head(), e.prov.count()
	a := e.build(withLineup(f), func(in *Input) { in.Context = d })
	if a.exit != 0 || a.err != nil {
		t.Fatalf("%s: exit %d err %v\n%s", c.name, a.exit, a.err, a.shown())
	}
	eq(t, c.name+" commits", e.commitsSince(start), "1")
	return f, offset
}

// plainText is everything a native request carries as text, in order.
func plainText(req map[string]any) string {
	var all strings.Builder
	for _, it := range requestInput(req) {
		m, _ := it.(map[string]any)
		switch c := m["content"].(type) {
		case string:
			all.WriteString(c)
			all.WriteString("\n")
		case []any:
			for _, b := range c {
				if bm, ok := b.(map[string]any); ok {
					if s, ok := bm["text"].(string); ok {
						all.WriteString(s)
						all.WriteString("\n")
					}
				}
			}
		}
	}
	return all.String()
}

// hasUserMessage reports whether the request carries a user message that is exactly content.
func hasUserMessage(req map[string]any, content string) bool {
	for _, it := range requestInput(req) {
		if m, _ := it.(map[string]any); m["role"] == "user" && m["content"] == content {
			return true
		}
	}
	return false
}

// builderSaw and reviewerSaw return the materials the two roles were given first.
func builderSaw(t *testing.T, e *env, f *lineupExec, c extCombo, offset int) string {
	t.Helper()
	if c.extBuild {
		tasks := f.starts[executor.RoleBuild]
		if len(tasks) != 1 {
			t.Fatalf("%s: %d build tasks", c.name, len(tasks))
		}
		return tasks[0].Brief.Stable + "\n\n" + tasks[0].Brief.Dynamic
	}
	return plainText(e.prov.requests()[offset])
}

func reviewerSaw(t *testing.T, e *env, f *lineupExec, c extCombo) string {
	t.Helper()
	if c.extReview {
		tasks := f.starts[executor.RoleReview]
		if len(tasks) != 1 {
			t.Fatalf("%s: %d review tasks", c.name, len(tasks))
		}
		return tasks[0].Brief.Stable + "\n\n" + tasks[0].Brief.Dynamic
	}
	reqs := e.prov.reviewRequests()
	if len(reqs) == 0 {
		t.Fatalf("%s: the native reviewer made no request", c.name)
	}
	return plainText(reqs[0])
}

// checkDelivery asserts that the reviewer received the exact labelled diagnostic message and
// nothing of the builder's own conversation.
func checkDelivery(t *testing.T, e *env, f *lineupExec, c extCombo, offset int, d *Diagnostic) {
	t.Helper()
	want := d.message()["content"].(string)
	if !strings.Contains(want, "Source: "+d.SourcePath+"\nSHA-256: "+d.SHA256+"\nDiagnostic text follows:\n"+d.Text+"\n") {
		t.Fatalf("%s: the expected message is not the labelled diagnostic: %q", c.name, want)
	}
	review := reviewerSaw(t, e, f, c)
	if strings.Count(review, want) != 1 {
		t.Fatalf("%s: the review has the exact diagnostic message %d times", c.name, strings.Count(review, want))
	}
	if !c.extReview && !hasUserMessage(e.prov.reviewRequests()[0], want) {
		t.Fatalf("%s: the native review does not carry the diagnostic as its own user message", c.name)
	}
	lacks(t, c.name+" review", review, builderSentinel)
	if c.extBuild {
		eq(t, c.name+" builder rounds", len(f.rounds(executor.RoleBuild)), 1)
	}
	build := builderSaw(t, e, f, c, offset)
	if strings.Count(build, want) != 1 {
		t.Fatalf("%s: the builder's first prompt has the exact diagnostic message %d times", c.name, strings.Count(build, want))
	}
}

func TestContextExternalReviewMatrix(t *testing.T) {
	t.Parallel()
	for _, c := range extCombos {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			for _, how := range []string{"", "changed", "deleted"} {
				t.Run("source "+how, func(t *testing.T) {
					t.Parallel()
					e := newEnv(t)
					text := "Earlier candidate failed at line 3 — Δ🙂\r\nnot approval or old green proof\n"
					d := &Diagnostic{Text: text, SourcePath: filepath.Join(e.aux, "context.md"), SHA256: digestOf(text)}
					writeFile(t, d.SourcePath, text, 0o644)
					f, offset := runCombo(t, e, c, d, how)
					checkDelivery(t, e, f, c, offset, d)
				})
			}
			t.Run("recovery handoff", func(t *testing.T) {
				t.Parallel()
				e, id := blocked(t, "printf 'candidate raw\\n' > filtered")
				output := filepath.Join(physical(t, t.TempDir()), "archive")
				if r := e.recover(id, output); r.exit != 0 || r.err != nil {
					t.Fatalf("recover: exit %d\n%s", r.exit, r.shown())
				}
				raw, err := os.ReadFile(filepath.Join(output, "context.md"))
				if err != nil {
					t.Fatal(err)
				}
				text := string(raw)
				contains(t, "handoff", text, "BUILDER-REPORTED and unproven.")
				contains(t, "handoff", text, "archive "+output)
				contains(t, "handoff", text, "blocker.json SHA-256 ")
				contains(t, "handoff", text, "checkpoint.json SHA-256 ")
				d := &Diagnostic{Text: text, SourcePath: filepath.Join(output, "context.md"), SHA256: digestOf(text)}
				if err := d.Validate(); err != nil {
					t.Fatal(err)
				}
				f, offset := runCombo(t, e, c, d, "")
				checkDelivery(t, e, f, c, offset, d)
				// The archive is diagnostic data only: the candidate is the new Build's own.
				lacks(t, "committed filtered", strings.ToLower(e.gitOut("show", "HEAD:filtered")), "candidate raw")
			})
		})
	}
}

// ---- the first prompt of the real Claude Code adapter ----

// fakeClaudeScript is a minimal `claude`: it answers --version and auth status, keeps every
// prompt it receives on stdin, writes the candidate and ends the round successfully.
func fakeClaudeScript(state string) string {
	return `#!/bin/sh
state='` + state + `'
case "$1" in
--version) echo "2.1.306 (Claude Code)"; exit 0;;
auth) echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}'; exit 0;;
esac
sid=''; prev=''
for a in "$@"; do
  if [ "$prev" = "--session-id" ] || [ "$prev" = "--resume" ]; then sid=$a; fi
  prev=$a
done
n=1; if [ -f "$state/calls" ]; then n=$(( $(cat "$state/calls") + 1 )); fi
echo $n > "$state/calls"
cat > "$state/prompt-$n.bin"
printf 'candidate\n' > app.txt
cwd=$(pwd -P)
printf '{"type":"system","subtype":"init","cwd":"%s","session_id":"%s","mcp_servers":[],"model":"claude-sonnet-5-5","permissionMode":"acceptEdits","apiKeySource":"none","claude_code_version":"2.1.306"}\n' "$cwd" "$sid"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"%s","result":"done","terminal_reason":"completed","stop_reason":"end_turn","permission_denials":[]}\n' "$sid"
`
}

// withClaudeProcess provides the real Claude Code adapter on the scripted process.
func withClaudeProcess(t *testing.T) (func(*Input), string) {
	t.Helper()
	dir := physical(t, t.TempDir())
	state := filepath.Join(dir, "state")
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "claude")
	writeFile(t, bin, fakeClaudeScript(state), 0o755)
	return func(in *Input) {
		in.External = func(project.Role) (executor.Executor, error) {
			return claudecode.New(claudecode.Options{Binary: bin, HookCommand: []string{"/bin/true"}}), nil
		}
	}, state
}

func TestContextExternalFirstPrompt(t *testing.T) {
	t.Parallel()
	text := "Previous candidate failed at line 3 — \xf0\x9f\x99\x82\nnot approval, a plan or current proof\n"
	text = strings.ToValidUTF8(text, "")
	for _, withContext := range []bool{true, false} {
		t.Run(fmt.Sprintf("context %v", withContext), func(t *testing.T) {
			t.Parallel()
			e := newEnv(t)
			e.useRoles(true, false)
			provide, state := withClaudeProcess(t)
			d := &Diagnostic{Text: text, SourcePath: "/inaccessible/label", SHA256: digestOf(text)}
			if !withContext {
				d = nil
			}
			a := e.build(provide, func(in *Input) { in.Context = d })
			if a.exit != 0 || a.err != nil {
				t.Fatalf("exit %d err %v\n%s", a.exit, a.err, a.shown())
			}
			raw, err := os.ReadFile(filepath.Join(state, "prompt-1.bin"))
			if err != nil {
				t.Fatal(err)
			}
			prompt := string(raw)
			contains(t, "prompt", prompt, "# Protected paths")
			if d == nil {
				lacks(t, "prompt", prompt, "Caller diagnostic data")
				return
			}
			want := d.message()["content"].(string)
			if strings.Count(prompt, want) != 1 {
				t.Fatalf("the first prompt has the exact labelled diagnostic %d times:\n%.600s", strings.Count(prompt, want), prompt)
			}
			// It follows the authority and precedes the dynamic evidence, as in the native opening.
			if strings.Index(prompt, "# Protected paths") > strings.Index(prompt, want) {
				t.Fatal("the diagnostic precedes the authority")
			}
			contains(t, "prompt", prompt, want+"\n\n# Files\n\n")
			if n, _ := os.ReadFile(filepath.Join(state, "calls")); strings.TrimSpace(string(n)) != "1" {
				t.Fatalf("calls %q: the diagnostic must not depend on a later round", n)
			}
		})
	}
}

// ---- the native bytes and the omitted context ----

// reviewBody is the first request body of the native reviewer, exactly as received.
func reviewBody(t *testing.T, e *env) string {
	t.Helper()
	reqs, bodies := e.prov.requests(), e.prov.rawRequests()
	for i, req := range reqs {
		if text := requestInstructions(req); text == agent.Prompt(agent.Reviewer) || text == reviewerPrompt(true) {
			return string(bodies[i])
		}
	}
	t.Fatal("no native review request")
	return ""
}

var conversationID = regexp.MustCompile(`conversation-[0-9a-f]{16}`)

var gitObjectName = regexp.MustCompile(`\b[0-9a-f]{40}\b|(start HEAD )[0-9a-f]{7,40}\b`)

// normalized replaces only what a temporary repository makes nondeterministic: its folders,
// the run, the conversation ids and the Git object names. The prompt text is untouched.
func normalized(e *env, text string) string {
	for _, id := range e.runIDs() {
		text = strings.ReplaceAll(text, id, "<run>")
	}
	for from, to := range map[string]string{e.root: "<root>", e.aux: "<aux>", e.home: "<home>"} {
		text = strings.ReplaceAll(text, from, to)
	}
	text = conversationID.ReplaceAllString(text, "conversation-<id>")
	return gitObjectName.ReplaceAllString(text, "${1}<git-object>")
}

// openings are the first request or prompt of the builder and of the reviewer, as the roles
// receive them: native requests are the complete bodies the provider received.
func openings(t *testing.T, c extCombo, d *Diagnostic) map[string]string {
	t.Helper()
	e := newEnvIn(t, physical(t, t.TempDir()), physical(t, t.TempDir()), physical(t, t.TempDir()),
		[]string{"GIT_AUTHOR_DATE=2026-10-22T00:00:00Z", "GIT_COMMITTER_DATE=2026-10-22T00:00:00Z"})
	f, offset := runCombo(t, e, c, d, "")
	out := map[string]string{}
	if c.extBuild {
		task := f.starts[executor.RoleBuild][0]
		out["builder.stable"], out["builder.dynamic"] = task.Brief.Stable, task.Brief.Dynamic
	} else {
		out["builder"] = string(e.prov.rawRequests()[offset])
	}
	if c.extReview {
		task := f.starts[executor.RoleReview][0]
		out["reviewer.stable"], out["reviewer.dynamic"] = task.Brief.Stable, task.Brief.Dynamic
	} else {
		out["reviewer"] = reviewBody(t, e)
	}
	for k, v := range out {
		out[k] = normalized(e, v)
	}
	return out
}

// diagnosticOf is the diagnostic every native-bytes case supplies.
func diagnosticOf() *Diagnostic {
	text := "Earlier candidate failed at line 3 — Δ🙂\r\nnot approval or old green proof\n"
	return &Diagnostic{Text: text, SourcePath: "/diagnostic/context.md", SHA256: digestOf(text)}
}

// sameBytes fails with the first difference of two texts.
func sameBytes(t *testing.T, name, got, want string) {
	t.Helper()
	if got == want {
		return
	}
	i := 0
	for i < len(got) && i < len(want) && got[i] == want[i] {
		i++
	}
	cut := func(s string) string { return fmt.Sprintf("%q", s[max(0, i-80):min(len(s), i+80)]) }
	t.Fatalf("%s differs at byte %d (%d bytes, want %d):\n got ...%s\nwant ...%s", name, i, len(got), len(want), cut(got), cut(want))
}

// TestContextExternalNativeBytes: the native opening requests (with and without the
// diagnostic) and the omitted-context requests of every executor pairing are byte for byte
// what they were before the diagnostic reached external roles (testdata/context-external-golden.json,
// recorded from the unfixed Build); only the folders, run, conversation and Git object names are normalized.
func TestContextExternalNativeBytes(t *testing.T) {
	t.Parallel()
	raw, err := os.ReadFile("testdata/context-external-golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden map[string]map[string]string
	if err := json.Unmarshal(raw, &golden); err != nil {
		t.Fatal(err)
	}
	d := diagnosticOf()
	for _, c := range extCombos {
		t.Run(c.name+" without context", func(t *testing.T) {
			t.Parallel()
			want := golden[c.name+" without context"]
			got := openings(t, c, nil)
			eq(t, "parts", len(got), len(want))
			for part, text := range got {
				sameBytes(t, part, text, want[part])
			}
		})
		if c.extBuild {
			continue
		}
		t.Run(c.name+" with context", func(t *testing.T) {
			t.Parallel()
			want := golden[c.name+" with context"]
			got := openings(t, c, d)
			eq(t, "parts", len(got), len(want))
			for part, text := range got {
				sameBytes(t, part, text, want[part])
			}
		})
	}
	// An external builder gets exactly the omitted-context brief plus the diagnostic message,
	// and its reviewer, native or external, exactly what the native builder's reviewer gets.
	for _, c := range extCombos {
		if !c.extBuild {
			continue
		}
		t.Run(c.name+" with context", func(t *testing.T) {
			t.Parallel()
			plain, got := golden[c.name+" without context"], openings(t, c, d)
			sameBytes(t, "builder.stable", got["builder.stable"], plain["builder.stable"]+d.message()["content"].(string))
			sameBytes(t, "builder.dynamic", got["builder.dynamic"], plain["builder.dynamic"])
			if c.extReview {
				return
			}
			sameBytes(t, "reviewer", got["reviewer"], golden["native/native with context"]["reviewer"])
		})
	}
}
