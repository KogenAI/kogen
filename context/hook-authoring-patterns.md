# Hook Authoring Patterns — How to Write & Test a Hook

How-to patterns for authoring Claude Code hook scripts in `harnesses/claude/hooks/`: test authoring, Stop/SubagentStop authoring, hooks-lib usage, output protocol, gate-verdict flow, registration mechanics, bash micro-patterns. AUTHORING companion to `context/hooks.md` (INVENTORY/catalog — which hooks exist, what each guard does, sources/tests/registrations). This file: "how do I build/test a hook?"; `context/hooks.md`: "which hooks exist / what does guard X do?".

For the per-hook inventory table, hook-event taxonomy, key paths, and the Pitfalls reference index → `context/hooks.md`.

## Hook Relocation & Porting

**[shared] Diff-scanning hook scope independence — when widening diff source** — When relocating a hook from staged-only (`git diff --cached`) to working-tree (`git diff HEAD`) scope, preserve the file-extension scope (`.ex`/`.exs`) independently. Widening the diff SOURCE is orthogonal to narrowing the diff TARGET files. A hook that scans string-literal patterns in source diffs will false-positive on its OWN test-fixture files (`.sh`/`.ts` test scripts constructing the same literal text) if file-type scoping is dropped — self-referential blast radius, especially dangerous for hooks that develop/test themselves in the same repo they protect. Always gate content scans to target file type BEFORE pattern matching. **Fast diagnostic**: `git diff HEAD --name-only` cross-referenced against the hook's scoping predicate confirms whether the predicate (not detection logic) is the defect.

## Hook Bypass Patterns & Signal Handling

**Role-based bypass**: Some hooks need to distinguish between orchestrator launcher modes (`claude-build`, `claude-ops`, `claude-debug`, etc.) — these use the `signal` field in their registration. The most common signal is `CLAUDE_ROLE_FAMILY`, which maps the outer-session launcher mode to a role name via `resolve_role()` from `_role.sh`. Examples:

- `orchestrator-no-source-edit.sh` — `signal: CLAUDE_ROLE_FAMILY` — sources `_role.sh`, calls `resolve_role()`. If `_role == "ops"`, bypass the hook (ops needs full write access on live boxes).

**Static enforcement of signal/body coupling**: At `make test`/`make install`, `validate_signal()` in `hook_registrations.py` greps the body for either `resolve_role()` or `is_build_mode()` — if neither is present on a `signal: CLAUDE_ROLE_FAMILY` hook, validation fails. Registry and header must stay synchronized; flipping the signal without updating the body (or vice versa) causes validation failure. This ensures signal declarations and role branching stay in sync.

**Signal: none (role-blind)**: Hooks without a signal field fire unconditionally for all launcher modes. Examples:

- `stop-spin-guard.sh` — `signal: AGENT_TYPE` — scoped to developer-\* roles; fires on every SubagentStop but exits 0 (allow) when AGENT_TYPE is not a developer role variant.
- `stop-gate-failure-breaker.sh` — `signal: AGENT_TYPE` — scoped to developer-\* roles; reads session-log `FAILED ❌` count + cross-checks `gate_result_verdict`; blocks at ≥3 failures with verdict=failed.

**Fail-open principle**: When a hook cannot determine the required state (missing transcript, unreadable log file), it exits 0 → allow the action. Blocking on missing evidence is worse than missing evidence of an error. Example: `curator-before-committer.sh` exits 0 if no log found (orchestrator may spawn committer before any log is written). The orchestrator prompt is the primary enforcer; the hook is a backstop.

See `context/launcher-hook-matrix.md` for a table of per-hook bypass and fail-open behavior per launcher mode.

## Developer Self-Gate Counter Behavior

`developer-no-self-gate.sh` tracks developer CI invocations per session via counter file (`/tmp/<sentinel>-self-gate-${session_id}.count`). Counted: `mix test`, `mix format`, `make ci`, `make test`. Bare `mix credo` (not combined with test/ci) is EXEMPT. Cap is MODE-DEPENDENT: legacy (non-loop) 3; under the Elixir loop (`CODEGEN_LOOP=1`) progress-bounded, hard ceiling 15. At the cap, further attempts are denied — hand off to orchestrator. Plan CI invocations strategically; running `make test` or `make hook-parity` repeatedly burns the budget.

**Authoring rule — a denial states the rule it enforced.** A bare-verdict deny ("hard ceiling reached") with no counted set/exemption/ceiling forces re-derivation from source → wrong guesses become durably wrong `--learned` entries. Every deny message MUST name: (1) what's counted, (2) what's exempt, (3) which ceiling fired. Parity test derives the counted set from matcher source (never hardcoded) — see `developer-no-self-gate-message-parity_test.sh`.

## Resolver Hoisting & Self-Describing Counter Pattern

Hoist idempotent resolver calls (e.g., `session_log_from_transcript`) to the top of the hook function and assign to a single variable — eliminates redundant subprocess forks and fixes the value for the entire invocation.

**Self-describing counter files**: Store the scope key in the counter file itself (first line = step-log path, second line = retry count). When the resolver returns empty due to transcript JSONL flush lag, the hook reads the prev-step scope from line1 and keeps the counter in scope without resetting.

## SubagentStop Fix-Up Hooks — Minimal Pattern & Parity

For SubagentStop hooks that always exit 0 (fix-up, never block), the minimal pattern is:

1. Parse stdin (JSON)
2. STOP_HOOK_ACTIVE loop guard → exit 0 if already active (prevent re-entry)
3. AGENT_TYPE case statement → exit 0 if matcher doesn't match
4. cd CWD (fallback to CLAUDE_PROJECT_DIR/$PWD if empty)
5. Conditional action (e.g., `grep -q '^format:' Makefile` → `make format`)
6. exit 0

Example: `curator-format.sh` (runs `make format` on markdown edits by context-curator). No ledger, no git-diff, no LLM-signal — single-purpose formatters use the whole tree (idempotent operation).


## Hook Test Authoring Patterns

New bash hook tests (`*_test.sh`) are auto-discovered by `run-tests.sh` — zero wiring, runs automatically in `make test`'s `hooks` stage. If a test is ALSO a named direct Makefile target (e.g. `prompt-content-parity`), it must have exactly ONE owner: add its path to `HOOK_DEDUP_EXCLUDE` in `run-all-tests.sh` (threads to `HOOK_TEST_EXCLUDE`, dropping it from auto-discovery that run). `run-all-tests_test.sh` asserts the set-equality and fails on drift. Standalone `run-tests.sh` (var unset) still runs the full population.

### Test Helper Functions — Assertion Patterns & BSD Compatibility

When adding assertion helpers (e.g., `assert_file_contains` / `assert_file_absent`):

1. **Use `grep -qF -- "$pattern"`** — `--` terminates option parsing on BSD + GNU; required for CLI-flag-shaped patterns (e.g., `--setting-sources`, `--no-extensions`).
2. **Update `pass_count`/`fail_count`** — so `run-tests.sh` summary parsing (`N passed, N failed`) works; helpers in outer scope propagate totals automatically.
3. **Negative-assertion caveat** — `grep -qF` exits 1 on missing file (same as "absent"), so false-pass silently when target is deleted. Acceptable for committed files (e.g., `harnesses/` launchers); document if reused elsewhere.

Example (`call-dispatch_test.sh`): fn wraps `grep -qF -- "$search_string" "$file_path"`, incrementing `pass_count`/`fail_count`, printing `FAIL: '<str>' not found in <file>` on miss.

**Coverage minimum**: every guard ≥14 cases, DENY+ALLOW — silent failures (grep partial, null crash, missing `//`) caught by tests not review. **Optional-pipeline** (both FORBID bare skip): (a) guaranteed dep (node/prettier/yq) — assert presence, fail loud on absence; (b) genuinely-optional (e.g. app omits `assets.deploy`) — check fs+config preconditions, assert ABSENCE-path fallback/no-op, not bare skip. **Hermeticity**: role-reading guards tested via `env -u CLAUDE_ROLE bash "$GUARD"`. **Markdown headings** in LLM output: case-insensitive `~r/##\s+heading/i` (capitalisation varies).

## Carve-Out Twin Rule — An ALLOW Fixture Requires a DENY Twin Crossing Its Axis

`pre-commit-guard`'s codegen-log carve-out had Test 23 (heredoc body mentions "git commit" →
ALLOW) + Test 24 (bare `git commit`, no token → DENY) — both always green, neither crossed "token
present" with "gated action is REAL". That crossed cell (token present + a real, chained `git
commit`) was the actual bypass: a spelling-anchored check, not an invocation-anchored one.

|                       | token present            | token absent  |
| --------------------- | ------------------------- | ------------- |
| **real gated action** | ← untested cell (the bug) | negative twin |
| **carve-out use**     | positive twin             | n/a           |

**Rule**: an ALLOW fixture on a carve-out REQUIRES a paired DENY twin crossing that axis — same
fixture, token still present, gated action made real. Comment what frame the pair excludes (e.g.
"not routed through codegen-log — command word is git"). Applies to helper predicates
(`is_codegen_log_write`) and role-scoped hooks alike — for the latter the crossed cell is a
wrong-role call with the gated condition present, still allowed (the hook's job).

No mechanical gate — a scanner can only assert a twin EXISTS, not that it tests the right cell.
Enforced by review + a one-time severity-ranked sweep (severe: history/gate/log-integrity hooks;
ergonomics-tier covered transitively by the helper's matrix in `hooks-lib_test.sh`). Runs both
directions: an over-narrow carve-out (denying a legitimate use) is the same missing cell, opposite corner.

## Hook Coverage Verification — Emoji Verdict Lines as Ground Truth

Count emoji lines as ground truth for verdict coverage, not branch count. Grep the hook for all lines containing `ALL CLEAR ✅`, `FAILED ❌`, or `INCONCLUSIVE ⚠️` — each is a verdict-emission point. Verify each emoji line is accompanied by the matching gate action (e.g., `_stamp_gated clear` before `append_ve_section "ALL CLEAR ✅"`). The emoji strings are the observable contract the reviewer can verify independently.

**Test authoring best practice**: Assert on in-repo source/artifact files (e.g., `harnesses/claude/commands/ready.md.j2`), NOT install paths (e.g., `~/.claude/`). Ensures hermeticity — test depends on repo state alone. See `context/test-harness.md` § Hermetic Bash Test Assertion Pattern.

**Hook deny/block message testing**: Substrings in deny messages become **immutable constraints** — any tightening must preserve asserted substrings or tests fail. Before editing messages, grep paired `_test.sh` for all `assert_contains` / `grep -q` assertions and preserve them.

**prompt-content-parity test scope**: Asserts only shape-mode sentinels (`ASK-GATE: product forks only`, `INTERACTION-AUDIT`) in baked `claude-shape-system-prompt.txt`. Edits to other prompts without sentinels don't break this test. New sentinel → update `harnesses/claude/hooks/prompt-content-parity_test.sh`. Standalone Makefile target (not auto-discovered); focuses on committed rule-text parity.

**Subagent-included rule files**: Assert on SOURCE files (e.g., `shared/rules/stacks/phoenix/reviewer.md`), NOT baked paths. Use `grep -qF` for sentinels; backticks kept literal (shell-escape with `\``). Hermetic test requires in-repo source only. **Hand-authored prompts** (e.g., `usage-rules-system-prompt.txt`) without parity sentinels are not covered — confirm via `grep -c "filename" prompt-content-parity_test.sh` before assuming sync needed.

## Hand-Authored Hook Script Structure & Registration

**Two types of hook ownership**:

1. **`kind: denial` (generated: true)** — `enforcement_compiler.py` OVERWRITES the entire `.sh` file at `make install`. Do NOT hand-edit these files.
2. **`kind: registration` (or deferred)** — the hand-authored `.sh` body is source of truth. The `HOOK-MANIFEST:` header block is generated from `registry.yaml`; deny/block message text lives inline in the `.sh` body, NOT the registry.

**Settings.json is auto-generated from HOOK-MANIFEST headers**: `hook_registrations.py:collect_hooks()` globs `harnesses/claude/hooks/*.sh`, parses the `# HOOK-MANIFEST:` header block, and `regenerate_settings()` writes `harnesses/claude/claude-code-settings.json` entries sorted **alphabetically by filename within each event**. Settings entries are NOT hand-edited; they are generated at `make install` and committed as the single source of truth for hook registration. Workflow: (1) write/edit `.sh` with correct HOOK-MANIFEST header, (2) run `make install` to regenerate settings.json, (3) commit both the `.sh` AND the regenerated settings.json together. `make hook-parity` compares committed settings.json against freshly-generated; divergence fails the gate. Hand-editing settings.json breaks parity checks.

**"GENERATED FROM registry.yaml — DO NOT EDIT" banner**: Refers ONLY to the auto-generated `HOOK-MANIFEST:` header block (lines up to the `# ---` terminator) — NOT the script body below it. The header carries structured metadata (event, tool_guard, signal, timeout); the body is hand-authored and editable. `kind: registration`-only hooks (grep the name in `registry.yaml` to confirm) are fully editable (e.g., `orchestrator-read-discipline.sh`, `stop-resume.sh`). **Header preservation**: `inject_header()` in `hook_registrations.py` rewrites ONLY the header span from registry and leaves the body byte-identical across `make install` cycles — safe to edit the body directly.

**When to edit registry.yaml**: Change header values (event, tool_guard, role, signal, harnesses) → run `make install --emit-headers`. Change body deny strings → edit `.sh` directly, no registry change needed.

**Trigger-flag patterns for role-keyed Multi-Condition Guards**: When a hand-authored hook must dispatch based on both AGENT_TYPE (role) AND a path-based condition (e.g., pitch vs context vs project-context), use the trigger-flag pattern: declare flags for each condition (e.g., `is_pitch=0 is_context_dir=0`) after initial variable extraction, populate flags via `case "$rel_path" in ... ;;` blocks, then use the flags in an early-allow gate (`if [ "$flag1" -eq 0 ] && [ "$flag2" -eq 0 ]; then return 0`). This centralizes the path-test logic, avoids duplication across role branches, and makes the structure consistent. Example: `subagent-read-discipline.sh` uses `is_pitch=0` + `is_context_dir=0` flags with a single early-allow gate; each role branch then tests `if [ "$is_pitch" -eq 1 ]; then deny ...; exit 0; fi` without duplicating the path-normalisation logic. Benefit: future additions of similar path conditions (e.g., a new `is_recipe_dir` flag) slot in with a new case block + one gate-width expansion, not a structural rewrite of all role branches.

**HOOK-MANIFEST `Rules:` comment sync when deny is widened**: When you extend a hook's deny logic to cover a new condition (e.g., widening `developer.md` Read deny from `context/` to include `codegen/pitches/`), update the `# HOOK-MANIFEST:` header block's `Rules:` comment field (the human-readable list of rules this hook enforces) in the same edit. The comment describes the deny conditions for reviewers + readers; drifting comment ↔ behavior creates confusion. Update the comment, then run `make install` (the header is hand-authored, so the comment update persists). No registry entry change needed unless the header field names changed (unlikely for comment-only updates).

**Anchor patterns in deny messages — substring vs. leading-token**: When a guard uses `grep` to match command text, choose the anchor appropriately:

- **Leading-anchor** (`^` or `^[[:space:]]*(verb1|verb2)`) — when the dangerous token is ALWAYS the leading verb (e.g., `cat file | grep`, `find . -path`, `git stash`). Examples: `no-cat-pipe.sh`, `no-git-stash.sh`.
- **Substring-match** (no anchor, or `|` in middle of pattern) — when the dangerous token can appear anywhere (e.g., command redirect/append `echo ... >> $TRANSCRIPT_PATH`, file path reference `cp ... ~/.claude/projects/`). Example: `orchestrator-read-discipline.sh` transcript-forge guard uses substring for tokens like `TRANSCRIPT_PATH`, `.jsonl`, `.claude/projects/` because they appear in redirect destinations, not leading positions. If you use leading-anchor on a redirect/append command, you will miss the violation because the dangerous token is not leading.

## Stop Hook Authoring Patterns & Error Classification

Stop hooks fire when the session ends. The primary pattern for Stop hooks that auto-recover from transient errors is **error classification** — examine error text and classify into three mutually-exclusive categories:

1. **Hard failure** — unrecoverable errors (4xx, auth, invalid key). Do NOT retry.
2. **Rate limit** — API throttle (429). Do NOT retry (let user wait).
3. **Retryable** — self-healing transient errors (stream timeout, connection reset, API 5xx, socket errors, etc.). Emit `block` decision to auto-resume.

**Transient error matching**: Use a regex pattern matching common error strings. The `stop-resume.sh` hook matches:

- Stream/connection errors: `Stream idle timeout`, `Unable to connect`, `FailedToOpenSocket`, `ConnectionRefused`, `connection reset`, `socket hang up`, `ETIMEDOUT`, `context deadline exceeded`
- API server errors: `API Error: 500`, `API Error: 502`, `API Error: 503`, `API Error: 504`, `overloaded_error`, `Internal server error`, `upstream connect error`
- **Edit-conflict transient errors** (self-healing when subagent re-reads): `File has been modified since read`, `has been unexpectedly modified` — both forms occur in Claude Code issues #3513, #33856, #48390

**Retry cap**: When classified as retryable, increment a session-scoped counter file (e.g., `/tmp/claude-resume-${session_id}.count`). Cap at 8 attempts — on the 9th occurrence, allow (exit 0, no block) to prevent infinite loops. Clean up the counter file on hard failure or rate limit (non-retryable paths).

**Edit-conflict self-healing**: "File has been modified since read" errors self-heal on re-read; cap-8 ceiling prevents wedging when conflict persists.

**Hook test cleanup**: Counter files MUST be cleaned via `cleanup()` trap before each test suite — without cleanup, counters persist across `make test` re-runs. Example from `stop-resume_test.sh`:

```bash
cleanup() {
  rm -f /tmp/claude-resume-sess-t1.count /tmp/claude-resume-sess-t10.count /tmp/claude-resume-sess-t11.count
}
trap cleanup EXIT
cleanup  # clean any leftovers from previous suite runs before tests start
```

## SubagentStop Hook Authoring Patterns

Contract: source `harnesses/claude/hooks/lib/hooks-lib.sh`, use `parse_input` to extract AGENT_TYPE and TRANSCRIPT_PATH, call `block "$reason"` to emit `{"decision":"block","reason":...}` on stdout. Same envelope as Stop hooks.

### Last-Match Pattern — Re-Spawned Section Body Extraction

When a role is re-spawned in the same cycle, the session log appends `## <role> Section (pass N)` headers instead of reusing the bare header. Hooks that validate section bodies (e.g., `subagent-retrospective-guard.sh`) must extract and validate the LAST matching block, not the first.

**Bash awk implementation — single-pass reset-on-match**:

```bash
section_body=$(awk "
    /^## /{
        if (match(\$0, \"^${section_header//\//\\/}\")) {
            in_section = 1
            body = \"\"
            next
        }
        if (in_section) { in_section = 0 }
    }
    in_section {
        body = body \$0 \"\\n\"
    }
    END { printf \"%s\", body }
" "$log_file" 2>/dev/null)
```

Key: On every matching header (including `(pass N)` suffix), RESET `body = ""` to discard the prior block. Non-matching `^## ` headers close the current section but do NOT open a new one. Single `/^## /` rule with inner `match()` collapses the two-rule form (separate enter/exit rules) into one pass. Existing single-block logs return the block unchanged; re-spawned multi-block logs return only the last.

**TypeScript implementation — reset-on-match accumulator**:

```typescript
function extractSectionBody(content: string, header: string): string {
  const lines = content.split("\n");
  let result: string[] = [];
  let inSection = false;

  for (const line of lines) {
    if (line.startsWith(header)) {
      // New matching block (incl. "(pass N)") — reset to keep only the last.
      inSection = true;
      result = [];
      continue;
    }
    if (inSection && /^## /.test(line)) {
      inSection = false;
      continue;
    }
    if (inSection) {
      result.push(line);
    }
  }
  return result.join("\n");
}
```

Key: `line.startsWith(header)` is a prefix test, so `"## developer-phoenix-backend Section (pass 2)".startsWith("## developer-phoenix-backend Section")` returns true. On each match, reset `result = []` to discard prior blocks. Return the last-accumulated body. TS `startsWith` and awk prefix-match (no trailing `$` anchor) both handle `(pass N)` variants without regex changes — only the accumulator-reset logic changes from "first-wins" to "last-wins".

**Interaction with other guards**: Sibling hooks (e.g., `session-log-no-duplicate-section.sh`) use end-anchored patterns like `^## .+ Section$` to detect duplicate bare headers — the `$` anchor exempts `(pass N)` suffixes from denial, so re-spawning does not trigger false duplicates.

**Harness scoping**: `harnesses: all` (default) deploys to every harness. Use `harnesses: claude_code` to scope a hook to Claude only.

**Role matching**: Manifest glob role (e.g., `developer-*`) → hook body MUST contain matching case/grep — `validate_role_match` in `hook_registrations.py` enforces this.

**Transcript analysis**: Parse `$TRANSCRIPT_PATH` JSONL via jq for cross-call patterns (e.g., consecutive same-role developer spawns). Transcript is session-bound and self-cleaning.

**Stop hook placement relative to retry-counter logic**: When a Stop hook measures some condition (e.g., `gate_result_verdict == clear` + `git status --porcelain` is dirty) and wants to block, place the measurement+block BEFORE any existing retry-counter increment. Do NOT increment the counter in the new branch — let control flow exit via the new block. This design keeps a circuit-breaker's 2-strike livelock-cap unaffected: the new guard signals one clean "go commit" action per mid-cycle stop without consuming strikes. Example: `stop-gate-failure-breaker.sh`'s dirty-tree-style block sits before the final Increment counter anchor; it exits before reaching the counter logic. All prior skip-guards have already exited, so reaching the new block implies the measurement is certain.

### Full Claude Code Event Catalog

Codegen registers `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `SubagentStop`, `Stop`, `SessionEnd`. Other events unused. Full schema: https://code.claude.com/docs/en/hooks

## Multi-Hook Composition Testing

Multiple hooks on the same event → **first-deny-wins**: pipe the same input through each hook in registration order; composed verdict = `deny` if ANY hook denies, else `allow`.

**Pattern** (from `mode-matrix_test.sh`): parse `settings.json` via jq to enumerate registered hooks dynamically; strip `$HOME/.claude/hooks/` prefix to locate repo-source hooks; build test payload via `jq -n`; invoke each hook as real subprocess with controlled env; assert with `assert_eq`. Use mktemp dirs per test; absolute paths in JSONL Write entries. Do NOT mock hook internals — real subprocess invocation catches cross-hook interaction bugs.

**One hook = one concern.** Universal hooks (no-cat-pipe, pre-commit) fire every role; role-specific (debug-bash-safety, reviewer-guard) gate role boundaries only. ❌ mix universal+role checks in one file ✅ separate files/registrations.

**Measurement vs enforcement**: two hooks coexist on same event/matcher without ordering deps IF upstream MEASURES (appends verdict, never blocks) and downstream ENFORCES (reads measurement, blocks at threshold) — e.g. `static-site-build-check.sh` measures; downstream reader enforces. Distinct per-blocker counter files avoid clobbering. Under the Elixir loop, gate measurement+retry-cap are both owned by `LoopGate.run_gate`/`OrchestrationLoop.invoke_with_retry`, not cooperating hooks.

## Hooks-Lib Patterns

### `session_log_from_transcript` — Callers Must Guard Existence

`session_log_from_transcript` extracts the last `Write|Edit|MultiEdit` file_path matching `codegen/logging/.*\.md$` from the JSONL transcript. **Does NOT verify disk existence.** When a Write is DENIED, the tool_use entry is still logged — the function returns that path even though the file was never created. Callers must guard `! -e <path>` after calling.

### Ad-Hoc Payload Field Reading via `RAW_INPUT`

`parse_input` deliberately does not export Edit/Write payload fields (e.g., `new_string`, `old_string`, `content`). Use ad-hoc `jq` on `$RAW_INPUT` (exported by `parse_input`):

```bash
new_string=$(jq -r '.tool_input.new_string // ""' <<< "$RAW_INPUT")
old_string=$(jq -r '.tool_input.old_string // ""' <<< "$RAW_INPUT")
content=$(jq -r '.tool_input.content // ""' <<< "$RAW_INPUT")
```


### `deny()` Requires Explicit `exit 0`

`deny()` emits JSON to stdout and **returns** — does NOT exit. Every call site must follow with `exit 0`:

```bash
if [ ! -e "$log_path" ]; then
    deny "Log does not exist"
    exit 0  # MANDATORY — without this, control falls through to next branch
fi
```

Missing `exit 0` → fallthrough; deny JSON is emitted but subsequent logic runs with unintended side-effects.

### POSIX File-Test Ordering — `! -e` Before `! -r`

Both `[ ! -e <path> ]` and `[ ! -r <path> ]` are true for non-existent paths. Test `! -e` FIRST to distinguish absent vs exists-but-unreadable:

```bash
if [ ! -e "$log_path" ]; then
    deny "Log file not found"
    exit 0
elif [ ! -r "$log_path" ]; then
    exit 0  # exists but unreadable → fail-open
fi
```

Reversing (testing `! -r` before `! -e`) makes the absent-file branch unreachable.

### `split_command_segments` — Escaped Quotes & Glob-Safe Splitting

Consumes `\"` inside a dq region as an escaped PAIR (no toggle) — not a quote-close; fixes phantom fail-closed denies on balanced strings (e.g. `grep -n "deny \"" file` mis-denied as "recursive rm"). Unbalanced quotes still fail closed. `strip_git_global_opts`/`command_word_of_segment`/`segment_argv_of` (bash-only) scope `set -f` around word-split so `*`/`?` never glob-expand against caller cwd; each restores the caller's prior noglob state.

## Hook Output Protocol

Hook scripts communicate decisions via JSON on stdout. Shape varies by event type.

**Decision field (top-level `decision`)** — applies to: `Stop`, `SubagentStop`, `PreCompact`, `UserPromptSubmit`, `PostToolUse`:

```json
{
  "decision": "block",
  "reason": "Human-readable explanation shown to the model"
}
```

Omitting `decision` (or exiting 0 with no JSON) means "proceed". Non-zero exit code also blocks.

**PreToolUse — permission decision** — uses `hookSpecificOutput.permissionDecision`:

```json
{
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "reason": "Denied by no-git-stash.sh: git stash is forbidden"
  }
}
```

Valid `permissionDecision` values:

| Value   | Meaning                                           |
| ------- | ------------------------------------------------- |
| `allow` | Explicitly allow this tool call                   |
| `deny`  | Block this tool call, surface reason to model     |
| `ask`   | Escalate to user for interactive approval         |
| `defer` | No opinion — let Claude Code apply default policy |

**Events codegen does not yet use** — for `PreCompact`, `PermissionRequest`, `PostCompact`, `SubagentStart`, and other unregistered events, verify the exact field shape against https://code.claude.com/docs/en/hooks before relying on them. Codegen has not exercised these events in production; the protocol above is confirmed only for the events in the registered subset.

## Gate Verdict Flow

```
SubagentStop fires → gate-select.sh picks stack →
  the Elixir loop's dev-gate step (mix test) OR static-site-build-check.sh (npm run build) →
  writes codegen/gate-pending/gate-result.json (structured verdict file) →
  appends "ALL CLEAR ✅" / "FAILED ❌" / "INCONCLUSIVE ⚠️ <class>" to step log ## dev-gate Section
```

Orchestrator reads verdict before deciding next delegation.

**Structured result file** (`<project>/codegen/gate-pending/gate-result.json`):

- Written by `write_gate_result` (from `harnesses/claude/hooks/lib/gate-result.sh`) on every gate branch to `<project>/codegen/gate-pending/gate-result.json` (created at session start by gate-select.sh)
- **Path**: Always in `codegen/gate-pending/` subdirectory, not at `codegen/` root. Hooks that read gate result must use `$project_dir/codegen/gate-pending/gate-result.json`
- Fields: `gate`, `mode`, `verdict` (clear|failed|inconclusive), `exit_code`, `execution_evidence`, `expected_segments`, `render_verdict`, `classification`, `started_at`, `ended_at`, `session_id`, `log`, `runner_found`

**Gate declaration** (`<project>/.claude/gate-config.sh`, sourced by `gate-select.sh`):

```sh
GATE_COMMAND="make ci"   # REQUIRED — exact gate command for this app
GATE_MODE="short"        # OPTIONAL — short|long; else derived by gate_mode_for
GATE_TIMEOUT=900          # OPTIONAL — seconds; else derived by gate_timeout_for
```

This is the ONE source. There is no per-cycle override and no stack-guessing default: a missing config file or empty `GATE_COMMAND` prints `__GATE_UNRESOLVED__:<reason>` and the caller must block or raise. A malformed `GATE_MODE`/`GATE_TIMEOUT` is also `__GATE_UNRESOLVED__` — never a silent fall-back to the heuristic, which would hide the typo. All three variables are pre-cleared before the config is sourced, so a stale caller env var cannot masquerade as a declaration.

**Gate Scope — Codegen Output Only**: Gates validate the _generated harness and codegen artifacts_ (e.g., hook unit tests, scaffold output compilation in test_harness). Gates do NOT validate downstream project state, symlink health, or consumer setup. Downstream validation belongs in the consuming app's own CI — that is where `curator-guard` will catch stale symlinks and fail loudly. This one-way boundary keeps codegen focused on artifact generation and prevents coupling to consumer-specific paths or assumptions.

## Hook Placement & Interception Points

New guards can be added to codegen by following established patterns:

**Claude Code** (`harnesses/claude/hooks/`)

- `PreToolUse` on `Agent` tool + `tool_input.subagent_type == "name"` match — intercepts subagent spawning (e.g., `curator-before-committer.sh` blocks committer spawn)
- `PreToolUse` on any tool — blocks arbitrary tool calls (e.g., `no-git-stash.sh` blocks `git stash`)
- `SubagentStop` — fires when a subagent completes, for post-agent logic (e.g., the loop's dev-gate step appends gate verdict)
- `Stop` — fires at session end for final guards

Hooks use consistent file naming, test patterns (`*_test.sh`), and fail-open semantics (missing state → allow). **Path resolution note**: When a hook reads the original `filePath` from its input (not a resolved relative form), the hook receives the raw path as written by the tool — for relative test paths this equals the repo-relative form; for absolute paths with symlinks it is not automatically resolved. Both forms correctly trigger tier-cap segment patterns (e.g., `/_core/`, `/roles/`, `/stacks/`) since these substrings appear in the path string regardless of symlink resolution. Verify test data contains the exact path strings that will be matched by the hook's regex pattern.

## Coordinating Regex Patterns Across Multiple Files

When a guard pattern (e.g., session-log filename schema) is encoded in many places — hand-authored hook bodies, registry `match:` fields (generate `.sh`/`.ts` files), and a schema doc — **all occurrences must widen together or gates contradict mid-cycle**. `shared/rules/_core/session-log.md` is canonical ("hooks and guards match against this"). When widening a character class: (1) grep the FULL pattern across `harnesses/`, `shared/enforcement/registry.yaml`, `shared/rules/_core/` — not just the pitch's "files to change" list; (2) edit the schema doc FIRST (it's the authority, stale = lies to future readers); (3) edit every occurrence — registry edits → `make install` → generated files refresh → `make test` confirms sync; (4) test both allow (new fixture) AND deny (existing fixture, confirms anchors preserved).

Applies to any widely-encoded schema (e.g., session-log slug class in 9 places: hand-authored+registry-driven+doc siblings). Post-edit grep confirms zero old-class hits.

## Clean-Tree Gate at SHIPPED Signal

`clean-tree-before-ship.sh` blocks the ship-mv (`codegen/pitches/ready/<slug>.md` → `shipped/<slug>.md`) when `git status --porcelain` is non-empty, preventing a pitch from shipping while orphaned cycle output sits uncommitted. Fail-open outside a git repo. Dirty/untracked file blocks with file list. No allowlist; gitignore unwanted files. The loop's own asserts (`OrchestrationLoop` clean-tree + exactly-one-commit checks) enforce "one commit/cycle capturing ALL output" unconditionally, independent of this hook.

## Transcript Lag & Discovery Pattern

`session_log_from_transcript()` in `hooks-lib.sh` discovers logs via: (1) Write/Edit/MultiEdit file_path match, (2) Bash `codegen-log` commands, (3) Managed-build disk fallback. Interactive sessions rely on transcript evidence.

**Fallback-After-Early-Return Bug**: Unconditional early-return hides fallback code. Fix: initialize `result=""` upfront; guard only the jq scan to allow fallback execution:
```bash
local result=""
if [ -n "${TRANSCRIPT_PATH:-}" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    result=$(jq -r '...' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
fi
# fallback block executes regardless; returns result
printf '%s' "$result"
```
Test both jq path (readable JSONL) and fallback path (empty/unreadable).

**Transcript flush lag**: Hook reads pre-Edit JSONL snapshot → missing session-log entry. Mitigation: when transcript-resolver returns empty, apply fallback disk-scan.

## Bash Symlink Resolution Fail-Open Discipline

Use THREE independent guards (NOT a single `&&` chain — early exit skips downstream guards):

```bash
if [ ! -L "$link" ]; then exit 0; fi           # (1) symlink absent → fail-open
resolved=$(readlink -f "$link" || true)
if [ -z "$resolved" ]; then exit 0; fi          # (2) unresolvable → fail-open
git_root=$(git -C "$resolved" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$git_root" ]; then exit 0; fi          # (3) not a git repo → fail-open
# All three guards passed; proceed with checks
```

Missing (1) → operates on empty variable; (2) → stale `$resolved` from prior loop; (3) → unhandled git error non-zero exit.

## Tool-Header Prose vs. Runtime Enforcement

`tools-header/*.txt` document boundaries; **claims MUST match runtime denials**. Mismatch (e.g., prose denies `rm/mv` but runtime doesn't) breeds misdiagnosis. Verify against `registry.yaml` + hooks before editing prose; docs are not code.

## Hook Pattern Coverage — Sibling Condition Enforcement (Rule J)

Hooks with two independent conditions (`case` + `[[ ]]`) must widen together. Mismatch = silent divergence. After widening one condition, widen the sibling. Test with a non-base family member (e.g., `developer-phoenix-frontend` ALLOW + BLOCK, not just `developer-phoenix-backend`) to prove both widened.

## Testing External Binary Calls — PATH Stub Pattern

Write fake binary to temp dir, prepend PATH. Stub records args to marker file; tests assert invocation. Clean via trap.

## Bypass Green-From-Birth Detection

ALLOW test passes under both old (skip) and new (process-then-allow) paths — green-from-birth trap. Pair ALLOW with BLOCK (same path, missing input). BLOCK fails under old, passes under new → proves bypass widened.

## Doc-Root vs Resolution-Root Split — RED-Proof Test Idiom

A hook mirroring a PROJECTED doc into a temp dir (e.g. `context-factcheck-edit-gate.sh`) must NOT pass that mirror as scan-lib `repo_root` — empty mirror falsely denies every valid path claim. Split via env var (`FACTCHECK_DOC_ROOT`): doc body reads mirror; `repo_root` stays real tree; unset → both default to `repo_root`. RED-proof pair: real path + real root → ALLOW; path nowhere → DENY (ALLOW alone can't tell "resolves" from "fails open").

## Three-Class Fetch-Pointer Guard Architecture

`rule-self-ref-no-fetch_test.sh` detects three classes for fetch pointers (`[nav-word] \`path/to/rule.md\`` in subagent templates): (a) **self-ref** — target co-inlined in the SAME template, redundant; (b) **dangling** — target doesn't exist under `shared/rules/`; (c) **unloadable** — target exists but isn't co-inlined in that template (unreachable at runtime). `check_template`/`run_fixture_check` stay in sync: file exists (passes b) → check `included_basenames[]`; absent → flag (c).

Nav-word set (see/read/per/check/via/apply/from/at/in/→) must precede the backtick to trigger detection — `Check \`rule.md\`` flags it, `If \`rule.md\` detected` does not.

## Block-the-Stop Pattern — Enforce at the Only Moment the Role Is Warm

A post-hoc check that re-invokes a FINISHED role to repair an omission cannot win: a cold re-invoke has no memory of the work it did, and a warm `--resume` only works if the resume prompt and the validator it's re-checked against share ONE source of truth (drift = unwinnable — see `role-retrospective-before-stop`'s deleted predecessor, which asked for bare text but validated a literal header).

**Pattern**: gate on `Stop` BEFORE the role's turn ends. A blocking `Stop` hook's `{"decision":"block",...}` pushes the role back into its OWN still-live session — no teardown, no re-invoke. Claude can block (warns on stderr).

Corollary: a marker a hook keys on MUST be a typed structured field both writer and checker read the same way — never markdown text one side generates and the other re-parses heuristically. See `role-retrospective-before-stop` + `codegen-log section --learned`.

## Hook Registration Mechanics — Registry-Driven Header Sync

HOOK-MANIFEST edits require BOTH `.sh` AND `registry.yaml` to update:

1. **Source of truth**: `registry.yaml` holds canonical values (event, tool_guard, role, signal, timeout)
2. **Auto-generation**: `make install` → injects header from registry, generates settings.json from headers
3. **Consistency check**: `make hook-parity` diffs committed settings.json vs. freshly-generated; divergence fails

**Workflow**: Edit `registry.yaml` → `make install` (regen header+settings.json) → commit both. Never hand-edit settings.json — rebuilt from manifest, wiping stray keys.

**Threading new fields (e.g., `timeout`)**: Register in `registry.yaml` → `render_header()` emits to header (when set) → `parse_manifest()` reads (conditional) → `build_hook_entry()` adds to JSON (conditional only). Prevents spurious keys in siblings, keeps parity green.

`kind: registration` hooks preserve hand-authored bodies. `kind: denial` (`generated: true`) hooks have ENTIRE `.sh` regenerated at `make install` — do not hand-edit.

## Trigger Keywords

how to write a hook, SubagentStop fix-up, Stop hook authoring, hook test authoring, hooks-lib, output protocol, gate verdict flow, hook registration, transcript lag, kind: registration vs denial, hook layering, measurement vs enforcement, DENY+ALLOW, ≥14 cases, hook relocation, diff-scanning hook scope, hook porting, diff source widening, file-extension scope, scope independence, self-referential blast radius, test-fixture false-positive
