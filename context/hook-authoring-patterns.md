# Hook Authoring Patterns — How to Write & Test a Hook

How-to patterns for authoring Claude Code hook scripts in `harnesses/claude/hooks/`: test authoring, Stop/SubagentStop authoring, hooks-lib usage, output protocol, gate-verdict flow, registration mechanics, and the bash micro-patterns guards rely on. This is the AUTHORING companion to `context/hooks.md` (the hook INVENTORY/catalog — which hooks exist, what each guard does, where sources/tests/registrations live). Read this file for "how do I build/test a hook?"; read `context/hooks.md` for "which hooks exist / what does guard X do?".

For the per-hook inventory table, hook-event taxonomy, key paths, and the Pitfalls reference index → `context/hooks.md`.

## Hook Bypass Patterns & Signal Handling

**Role-based bypass**: Some hooks need to distinguish between orchestrator launcher modes (`claude-build`, `claude-ops`, `claude-debug`, etc.) — these use the `signal` field in their registration. The most common signal is `CLAUDE_ROLE_FAMILY`, which maps the outer-session launcher mode to a role name via `resolve_role()` from `_role.sh`. Examples:

- `orchestrator-no-source-edit.sh` — `signal: CLAUDE_ROLE_FAMILY` — sources `_role.sh`, calls `resolve_role()`. If `_role == "ops"`, bypass the hook (ops needs full write access on live boxes).
- `pitch-shipped-before-stop.sh` — `signal: CLAUDE_ROLE_FAMILY` — checks `_role == "dashboard-build"` (dashboard CI manages the shipped/ move post-merge) OR `CODEGEN_NO_AUTOSHIP=1` env override (operator explicit suppression).
- `step-log-section-before-spawn.sh` — `signal: CLAUDE_ROLE_FAMILY` — sources `_role.sh`, calls `resolve_role()`. Bypassed for `debug`, `shape`, and `ops` (investigative modes spawn Explore subagents without a step log). Enforces step-0 log creation and per-agent section headers in all other modes.

**Static enforcement of signal/body coupling**: The generator validates signal-to-body consistency at `make test` / `make install` time via `validate_signal()` in `hook_registrations.py`. When a hook's HOOK-MANIFEST header declares `signal: CLAUDE_ROLE_FAMILY`, the validator greps the `.sh` body for a `resolve_role()` call — if absent, validation fails loud. Similarly, the registry entry must match the header: flipping the signal in `registry.yaml` without adding the call to the body, OR vice versa, causes validation to fail. This coupling ensures that signal declarations and in-body role branching stay synchronized; either both flip together or the generator detects the inconsistency.

**Signal: none (role-blind)**: Hooks without a signal field fire unconditionally for all launcher modes. Examples:

- `stop-cycle-guard.sh` — `signal: none` — blocks premature stop in all modes.
- `stop-spin-guard.sh` — `signal: AGENT_TYPE` — scoped to developer-\* roles; fires on every SubagentStop but exits 0 (allow) when AGENT_TYPE is not a developer role variant.
- `stop-gate-failure-breaker.sh` — `signal: AGENT_TYPE` — scoped to developer-\* roles; reads session-log `FAILED ❌` count + cross-checks `gate_result_verdict`; blocks at ≥3 failures with verdict=failed.

**Fail-open principle**: When a hook cannot determine the required state (missing transcript, unreadable log file), it exits 0 → allow the action. Blocking on missing evidence is worse than missing evidence of an error. Examples: `step-log-section-before-spawn.sh` exits 0 if transcript is unreadable or log is absent; `curator-before-committer.sh` exits 0 if no log found (orchestrator may spawn committer before any log is written). The orchestrator prompt is the primary enforcer; the hook is a backstop.

See `context/launcher-hook-matrix.md` for a table of per-hook bypass and fail-open behavior per launcher mode.

## Developer Self-Gate Counter Behavior

`developer-no-self-gate.sh` tracks developer CI invocations per session via counter file (`/tmp/<sentinel>-self-gate-${session_id}.count`). Each Bash invocation matching `make *`, `mix test`, `mix credo`, or `mix format` increments the counter. At limit (3), further attempts are denied — hand off to orchestrator. Plan CI invocations strategically; running `make test` or `make hook-parity` repeatedly burns the budget.

## Resolver Hoisting & Self-Describing Counter Pattern

Hoist idempotent resolver calls (e.g., `session_log_from_transcript`) to the top of the hook function and assign to a single variable — eliminates redundant subprocess forks and fixes the value for the entire invocation.

**Self-describing counter files**: Store the scope key in the counter file itself (first line = step-log path, second line = retry count). When the resolver returns empty due to transcript JSONL flush lag, the hook reads the prev-step scope from line1 and keeps the counter in scope without resetting. Pattern: `stop-cycle-guard.sh` two-line counter format.

## SubagentStop Fix-Up Hooks — Minimal Pattern & Parity

For SubagentStop hooks that always exit 0 (fix-up, never block), the minimal pattern is:

1. Parse stdin (JSON)
2. STOP_HOOK_ACTIVE loop guard → exit 0 if already active (prevent re-entry)
3. AGENT_TYPE case statement → exit 0 if matcher doesn't match
4. cd CWD (fallback to CLAUDE_PROJECT_DIR/$PWD if empty)
5. Conditional action (e.g., `grep -q '^format:' Makefile` → `make format`)
6. exit 0

Example: `curator-format.sh` (runs `make format` on markdown edits by context-curator). No ledger, no git-diff, no LLM-signal — single-purpose formatters use the whole tree (idempotent operation).

**Pi mirror parity for SubagentStop target checks**: When a Bash hook checks for Makefile target presence (e.g., `grep -q '^format:'`), the Pi TypeScript mirror must also verify the target exists via regex match (`/^format:/m.test(readFileSync(...))`), not just `fs.existsSync(Makefile)` alone. File presence is weaker than target presence — a Makefile without the target causes `make` to fail with "No rule to make target", which a non-fatal catch swallows instead of short-circuiting cleanly. Guard both implementations with the target check.

## Hook Test Authoring Patterns

New bash hook tests (`*_test.sh`) are auto-discovered by `run-tests.sh` — they run automatically as part of `make test`'s `hooks` stage. When a hook test is also registered as a named Makefile target (e.g., `prompt-content-parity`), the test runs **twice** per `make test` cycle (auto-discovery + explicit prerequisite) — idempotent, not a defect.

### Test Helper Functions — Assertion Patterns & BSD Compatibility

When adding assertion helpers (e.g., `assert_file_contains` / `assert_file_absent`):

1. **Use `grep -qF -- "$pattern"`** — `--` terminates option parsing on BSD + GNU; required for CLI-flag-shaped patterns (e.g., `--setting-sources`, `--no-extensions`).
2. **Update `pass_count`/`fail_count`** — so `run-tests.sh` summary parsing (`N passed, N failed`) works; helpers in outer scope propagate totals automatically.
3. **Negative-assertion caveat** — `grep -qF` exits 1 on missing file (same as "absent"), so false-pass silently when target is deleted. Acceptable for committed files (e.g., `harnesses/` launchers); document if reused elsewhere.

**Example** (from `call-dispatch_test.sh`):

```bash
assert_file_contains() {
  local file_path="$1" search_string="$2"
  if grep -qF -- "$search_string" "$file_path"; then
    pass_count=$((pass_count + 1))
    return 0
  else
    fail_count=$((fail_count + 1))
    printf "FAIL: '%s' not found in %s\n" "$search_string" "$file_path" >&2
    return 1
  fi
}
```

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

**Mirrored predicate sync — when two hooks share a forbidden-set list**: When two separate hand-authored hooks enforce the same deny condition based on shared predicate values (e.g., `step-log-section-before-spawn.sh` forbidden-type skip guard checking against `Plan/general-purpose/statusline-setup/empty/Explore`, and `operator-subagent-allowlist.sh` deny list covering the same set), keeping both sources synchronized is error-prone — one can drift while the other isn't. Pattern: add a regression test case to the paired `*_test.sh` that asserts (1) skip fires for each value in the forbidden set, AND (2) legal values outside the set still demand headers/deny as intended. This paired test is the contract that guards against divergence. When changing either predicate, verify both hook source files side-by-side before committing; the test ensures one cannot be widened without the other.

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

Contract: source `lib/hooks-lib.sh`, use `parse_input` to extract AGENT_TYPE and TRANSCRIPT_PATH, call `block "$reason"` to emit `{"decision":"block","reason":...}` on stdout. Same envelope as Stop hooks.

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

**Harness scoping**: `harnesses: all` (default) REQUIRES a matching `.ts` Pi handler or `make install` fails. Use `harnesses: claude_code` to skip Pi parity check.

**Role matching**: Manifest glob role (e.g., `developer-*`) → hook body MUST contain matching case/grep — `validate_role_match` in `hook_registrations.py` enforces this.

**Transcript analysis**: Parse `$TRANSCRIPT_PATH` JSONL via jq for cross-call patterns (e.g., consecutive same-role developer spawns). Transcript is session-bound and self-cleaning.

**Managed-build fail-closed pattern**: Guard hard constraints with `CODEGEN_BUILD_NON_INTERACTIVE` check — allow fail-open in interactive mode. Pattern:

```bash
if [ -z "$log_file" ]; then
    if [ -n "${CODEGEN_BUILD_NON_INTERACTIVE:-}" ]; then
        debug_log "gate" "BLOCK: managed build but no session log"
        block "Managed build but no session log is discoverable."
        exit 0
    fi
    debug_log "gate" "skip: no log in transcript (interactive fail-open)"
    exit 0
fi
```

This preserves the interactive fail-open contract (silent allow when state unrecoverable) while enforcing fail-closed in managed builds where all required state should be preestablished. The `CODEGEN_BUILD_NON_INTERACTIVE` flag is set by `dispatch.sh` and similar non-interactive entrypoints; interactive mode never sets it, so the interactive branch always executes.

**Stop hook placement relative to retry-counter logic**: When a Stop hook measures some condition (e.g., `gate_result_verdict == clear` + `git status --porcelain` is dirty) and wants to block, place the measurement+block BEFORE any existing retry-counter increment. Do NOT increment the counter in the new branch — let control flow exit via the new block. This design keeps the circuit-breaker's 2-strike livelock-cap unaffected: the new guard signals one clean "go commit" action per mid-cycle stop without consuming strikes. Example: stop-cycle-guard.sh's dirty-tree block sits before the final Increment counter anchor; it exits before reaching the counter logic. All prior skip-guards have already exited, so reaching the new block implies the measurement is certain.

### Full Claude Code Event Catalog

Codegen registers `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `SubagentStop`, `Stop`, and `SessionEnd` (inline). All other events (`SessionStart`, `Setup`, `UserPromptSubmit`, `UserPromptExpansion`, `PermissionRequest`, `PermissionDenied`, `PreCompact`, `PostCompact`, `SubagentStart`, `Notification`) are unused. Full event schema: https://code.claude.com/docs/en/hooks

## Multi-Hook Composition Testing

Multiple hooks on the same event → **first-deny-wins**: pipe the same input through each hook in registration order; composed verdict = `deny` if ANY hook denies, else `allow`.

**Pattern** (from `mode-matrix_test.sh`): (1) parse `settings.json` via jq to enumerate registered hooks dynamically; (2) strip `$HOME/.claude/hooks/` prefix to locate repo-source hooks; (3) build test payload via `jq -n`; (4) invoke each hook as real subprocess with controlled env; (5) assert expectations with `assert_eq`.

Use mktemp dirs per test; absolute paths in JSONL Write entries. Do NOT mock hook internals — real subprocess invocation catches cross-hook interaction bugs.

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

**Pi equivalent**: read from `event.input` directly (typed, no jq). Reference: `session-log-section-integrity.ts` lines 71–75. **Fail-open**: jq errors or missing fields default to `""` via `// ""`.

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
  phoenix-dev-gate.sh (mix test) OR static-site-build-check.sh (npm run build) →
  writes codegen/gate-pending/gate-result.json (structured verdict file) →
  appends "ALL CLEAR ✅" / "FAILED ❌" / "INCONCLUSIVE ⚠️ <class>" to step log ## dev-gate Section
```

Orchestrator reads verdict before deciding next delegation.

**Structured result file** (`<project>/codegen/gate-pending/gate-result.json`):

- Written by `write_gate_result` (from `lib/gate-result.sh`) on every gate branch to `<project>/codegen/gate-pending/gate-result.json` (created at session start by gate-select.sh)
- **Path**: Always in `codegen/gate-pending/` subdirectory, not at `codegen/` root. Hooks that read gate result must use `$project_dir/codegen/gate-pending/gate-result.json`
- Fields: `gate`, `mode`, `verdict` (clear|failed|inconclusive), `exit_code`, `execution_evidence`, `expected_segments`, `render_verdict`, `classification`, `started_at`, `ended_at`, `session_id`, `log`, `runner_found`
- `build-no-success-before-commit.sh` reads `verdict` field — requires `clear` before allowing BUILD_RESULT signal
- `stop-cycle-guard.sh` reads `verdict` field — blocks if verdict ≠ clear (see § stop-cycle-guard Verdict Semantics)
- `step-log-completeness.sh` reads `verdict` field — `clear` enables completion even without log ALL CLEAR marker

**Gate JSON block format** (new — `gate-select.sh` parses gate-json fence in `## Plan`):

```gate-json
{
  "command": "make ci",
  "mode": "short",
  "timeout": 900
}
```

Gate-json block scoping: block is parsed ONLY when it immediately follows the `**Gate**:` line (up to one blank line); example/documentation blocks elsewhere in the plan body are ignored. This prevents format documentation from being misidentified as the authoritative gate spec. Prose `**Gate**: make ci` still accepted as fallback for backward compat.

**Gate Scope — Codegen Output Only**: Gates validate the _generated harness and codegen artifacts_ (e.g., hook unit tests, scaffold output compilation in test_harness). Gates do NOT validate downstream project state, symlink health, or consumer setup. Downstream validation belongs in the consuming app's own CI — that is where `curator-guard` will catch stale symlinks and fail loudly. This one-way boundary keeps codegen focused on artifact generation and prevents coupling to consumer-specific paths or assumptions.

## Hook Placement & Interception Points

New guards can be added to codegen by following established patterns:

**Claude Code** (`harnesses/claude/hooks/`)

- `PreToolUse` on `Agent` tool + `tool_input.subagent_type == "name"` match — intercepts subagent spawning (e.g., `curator-before-committer.sh` blocks committer spawn)
- `PreToolUse` on any tool — blocks arbitrary tool calls (e.g., `no-git-stash.sh` blocks `git stash`)
- `SubagentStop` — fires when a subagent completes, for post-agent logic (e.g., `phoenix-dev-gate.sh` appends gate verdict)
- `Stop` — fires at session end for final guards (e.g., `step-log-completeness.sh` checks log integrity before exit)

**Pi harness** (`harnesses/pi/pi-extensions/enforcement/src/hooks/`)

- `tool_call` on `"subagent"` tool name — Pi mirror of Claude's `Agent` PreToolUse matchers (e.g., `curator-before-committer.ts`)
- `tool_call` on any tool name — Pi mirror of Claude's PreToolUse guards
- `subagent_stop` — Pi mirror of Claude's SubagentStop
- `tool_use_error` — Pi error handling (no strict Claude equivalent)

Both harnesses use the same hook file naming, same test patterns (`*_test.sh` / `*_test.ts`), and fail-open semantics (missing state → allow). **Pi path resolution note**: When a Pi hook reads the original `filePath` from `event.input` (not a resolved relative form), the hook receives the raw path as written by the tool — for relative test paths this equals the repo-relative form; for absolute paths with symlinks it is not automatically resolved. Both forms correctly trigger tier-cap segment patterns (e.g., `/_core/`, `/roles/`, `/stacks/`) since these substrings appear in the path string regardless of symlink resolution. Verify test data contains the exact path strings that will be matched by the hook's regex pattern.

## Coordinating Regex Patterns Across Multiple Files

When a guard pattern (e.g., session-log filename schema) is encoded in 9 places — 4 hand-authored hook bodies, 2 registry `match:` fields (which generate 3 `.sh`/`.ts` files), and 1 schema doc — **all occurrences must widen together or gates contradict mid-cycle**. Rule: `shared/rules/_core/session-log.md` is the canonical schema document ("hooks and guards match against this"). When widening a character class (e.g., session-log slug from `[a-z0-9-]` to `[a-z0-9_-]`):

1. **Always grep the full pattern** across `harnesses/`, `shared/enforcement/registry.yaml`, and `shared/rules/_core/` to catch hand-authored + registry-driven + documented siblings (not just the "files to change" list from the pitch).
2. **Edit the schema doc first** — it is the authority. Leaving it stale makes the doc lie to future readers.
3. **Edit all 9 occurrences** — registry edits → `make install` → generated files refresh → `make test` sees all in sync.
4. **Test both allow and deny** — new fixtures (e.g., underscore-slug allow) AND existing deny fixtures (to confirm structure anchors preserved).

Pattern applies to any widely-encoded schema (e.g., session-log slug class encoded in 9 places across hand-authored + registry-driven + documented siblings). Post-edit grep confirms zero old-class hits.

## Clean-Tree Gate at SHIPPED Signal

`build-no-success-before-commit.sh` enforces clean working tree before BUILD_RESULT: success. Flow: commit found (commit-ts > start-ts) → gate verdict clear → `git status --porcelain` empty → allow. Any dirty/untracked file blocks with list of uncommitted files. No allowlist; add unwanted files to `.gitignore` before commit. Enforces "one commit per cycle capturing ALL output" rule.

## Transcript Lag & Discovery Pattern

Hook scripts discover the active session/step log via `session_log_from_transcript()` in `hooks-lib.sh`. Two modes:

**Interactive sessions**: strict transcript-bound — scans `$TRANSCRIPT_PATH` JSONL for most recent Write/Edit/MultiEdit targeting `codegen/logging/*.md`. Returns empty if absent.

**Managed build workers** — two independent fallback branches when transcript returns empty:

1. **OCG_APPS_ROOT**: scans `$CWD/codegen/logging/*.md` by mtime (dashboard-box managed workers)
2. **CODEGEN_BUILD_NON_INTERACTIVE**: scans `$CWD/codegen/logging/` unconditionally (non-interactive dispatch)

Transcript hit skips both fallbacks. Dual-gate catches slow-Node transcript flush lag (observed: Node 20). **11 production consumers** inherit the fallback.

**Portable mtime sorting**: `ls -t glob | head -1` — `find -printf` NOT portable to BSD find (macOS).

### Fallback-After-Early-Return Bug Pattern

Fallback behind unconditional early-return = unreachable fallback. Common mistake: test fixture creates readable-but-empty file (passes `[ ! -r ]` guard) — actual bug path (absent/empty/unreadable) still untested. Verify fixtures satisfy the EARLY-RETURN condition, not just a related one.

**Fix pattern**: Replace unconditional early-return with a conditional that SKIPS ONLY the transcript scan but FALLS THROUGH to the fallback block. Initialize result upfront, guard only the jq scan:

```bash
local result=""
if [ -n "${TRANSCRIPT_PATH:-}" ] && [ -r "$TRANSCRIPT_PATH" ]; then
    result=$(jq -r '...' "$TRANSCRIPT_PATH" 2>/dev/null | tail -n 1)
fi
# ... fallback block (lines 283–305) unchanged, executes regardless ...
printf '%s' "$result"
```

Test both: skip-jq path (empty `TRANSCRIPT_PATH`) and fallback path (managed env, disk log exists).

**Transcript lag causing false blocks**: Hook read a JSONL snapshot predating the Edit → re-running forces new transcript entry. Mitigation: apply fallback disk-scan when transcript-bound resolver returns empty.

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

`tools-header/*.txt` files document Bash mutation boundaries in agent prompts. **Documented deny-list claims MUST match enforced denials at runtime.** Prose claiming Bash denies `rm/mv/touch/mkdir` when runtime only denies cat-pipes breeds hook-denial misdiagnosis.

**Verified enforcement for shape mode:**

- **Denied**: cat-pipes (`no-cat-pipe.sh`), git-history mutation (`no-git-stash` + git-ops allowlist)
- **NOT denied** at Bash layer: file ops (`rm`, `mv`, `touch`, `mkdir`) — Write/Edit boundary enforced at tool level by `orchestrator-no-source-edit.sh` (scoped to `codegen/pitches/`)

When tightening tool-header prose, verify against `shared/enforcement/registry.yaml` and source hooks — do NOT trust prose alone. Tools-header files are documentation, not code; false claims cause misdiagnosis.

## Hook Pattern Coverage — Sibling Condition Enforcement (Rule J)

When a hook file has TWO independent conditions affecting the same logic path (e.g., `subagent-retrospective-guard.sh`: in-script `case` matcher AND header-selection `[[ ]]`), they must widen in lockstep. Mismatch silently diverges — one family member matches the matcher but misses the selection.

**After widening a glob in one condition, immediately widen the sibling.** Test both paths with a non-phoenix family member (e.g., `planner-static`) — a `planner-phoenix`-only test cannot distinguish whether both conditions widened.

**Example**: `subagent-retrospective-guard.sh` planner family widen requires: (1) `case "$AGENT_TYPE"` → `planner*` glob; (2) header-selection `[[ ]]` → same glob; (3) registry entry (forward-compat). Pair a `planner-static` ALLOW test with a BLOCK test (missing retrospective) to prove both conditions widened.

**Pattern**: identify sibling conditions → widen ALL to same glob form → add ALLOW + BLOCK tests for a non-base family member.

## Testing External Binary Calls — PATH Stub Pattern

Stub binaries (e.g., `sleep`, `curl`): write fake in temp, prepend PATH. Stub records args to marker; tests assert invocation. Clean via trap.

## Bypass Green-From-Birth Detection (Test Coverage Strategies for Hook Widening)

When bypass widens (e.g., literal `planner` → `planner*`), an ALLOW test passes under both old (skip) and new (process-then-allow) paths — green-from-birth trap.

**Pattern**: Pair ALLOW with a BLOCK case (same path, missing input). Old code: both skip (both allow). New code: BLOCK processes and emits deny. BLOCK failing under old but passing under new proves the bypass widened.

**Example** (`subagent-retrospective-guard.sh`): `planner-phoenix` without retrospective → BLOCK (proves processing); with retrospective → ALLOW (proves valid bypass).

## Retrospective Placement Constraint — Awk Section Extraction

`subagent-retrospective-guard.sh` uses `awk` to extract the retrospective section. **Critical constraint**: `### What I Learned This Step` CANNOT appear anywhere inside a `## Plan` body that contains nested `## ` literals — awk terminates at the first `## ` encountered, even inside fenced code blocks.

**Rule**: Retrospective MUST sit at the TOP of `## Plan`, immediately after the header, BEFORE any nested `## ` literals (fenced or prose).

**Why**: Awk's `/^## / && NR > start_line { exit }` cannot distinguish fence boundaries. Example:

````bash
## Plan

```markdown
## Example Header in Code
...
````

### What I Learned This Step

...

```

Awk terminates at `## Example Header` (inside the fence), never reaching the retrospective.

**Solution**: Place all fenced/formatted content AFTER the retrospective block, or place retrospective immediately after `## Plan` before any code examples.

## Hook Registration Mechanics — Registry-Driven Header Sync

HOOK-MANIFEST edits require BOTH `.sh` AND `registry.yaml` to update:

1. **Source of truth**: `registry.yaml` holds canonical values (event, tool_guard, role, signal, timeout)
2. **Auto-generation**: `make install` → injects header from registry, generates settings.json from headers
3. **Consistency check**: `make hook-parity` diffs committed settings.json vs. freshly-generated; divergence fails

**Workflow**: Edit `registry.yaml` → `make install` (regenerates header + settings.json) → commit both. Never hand-edit settings.json — `regenerate_settings()` rebuilds from manifest, wiping stray keys.

**Threading new fields (e.g., `timeout`)**: Register in `registry.yaml` → `render_header()` emits to header (when set) → `parse_manifest()` reads (conditional) → `build_hook_entry()` adds to JSON (conditional only). Prevents spurious keys in sibling hooks, keeps parity green.

`kind: registration` hooks preserve hand-authored bodies across edits. `kind: denial` (`generated: true`) hooks have ENTIRE `.sh` regenerated at `make install` — do not hand-edit.
```
