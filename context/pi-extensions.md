# Pi Extensions Domain — Pi TypeScript Extensions

The pi-extensions domain covers the TypeScript npm packages that extend the Pi harness with custom tool implementations. Each extension is an independent npm package under `harnesses/pi/pi-extensions/<name>/` with its own `package.json`, `src/`, and compiled output. `generate-pi-extension.sh` scaffolds new extensions from a template in `templates/shared/pi-extensions/`.

Current extensions: `askuserquestion` (interactive user prompts), `enforcement` (rule enforcement at runtime), `subagents` (agent delegation bridge), `web-utils` (HTTP/web helpers). Pi build mode now also loads `askuserquestion`, `subagents`, and `enforcement` by default; `codegen-build --harness=pi` treats the written gate result as the success gate.

## Components

| File / Dir                                        | Purpose                                                        |
| ------------------------------------------------- | -------------------------------------------------------------- |
| `harnesses/pi/pi-extensions/askuserquestion/`     | Implements `AskUserQuestion` tool for Pi harness               |
| `harnesses/pi/pi-extensions/askuserquestion/src/` | TypeScript source                                              |
| `harnesses/pi/pi-extensions/enforcement/`         | Rule enforcement extension (blocks disallowed patterns)        |
| `harnesses/pi/pi-extensions/subagents/`           | Subagent delegation bridge for Pi                              |
| `harnesses/pi/pi-extensions/web-utils/`           | HTTP fetch, web search helpers                                 |
| `harnesses/pi/pi-extensions/web-utils/src/`       | TypeScript source                                              |
| `templates/generator/generate-pi-extension.sh`    | Scaffolds a new extension from template                        |
| `templates/shared/pi-extensions/`                 | Extension scaffold template (package.json, tsconfig, src stub) |

## Key Paths

```
harnesses/pi/pi-extensions/
  askuserquestion/
    index.ts, package.json, src/
  enforcement/
    package.json, src/          ← no root-level index.ts; entry is under src/
  subagents/
    index.ts, package.json, src/
  web-utils/
    index.ts, package.json, src/
templates/generator/generate-pi-extension.sh
templates/shared/pi-extensions/
```

## Integration Points

- **harnesses**: Pi launchers (`pi-build.sh`, etc.) reference compiled extensions; extension changes require rebuild (`npm run build` inside extension dir)
- **core**: `install.sh` pi install steps include extension compilation and installation
- **development**: `make test` may include pi extension type-checks; `npm install` required in each extension dir after dep changes

## Dev Workflow

Adding a new extension:

1. `generate-pi-extension.sh <name>` — scaffolds from template
2. Implement in `src/`
3. `npm install && npm run build` in extension dir
4. Register in `harnesses/pi/manifest.yaml` install_steps if needed

## Event Handler Architecture — Tool Call vs Session Shutdown

Pi has two event families with **asymmetric blocking capability**:

| Event Type         | Can block? | Return contract                                                |
| ------------------ | ---------- | -------------------------------------------------------------- |
| `tool_call`        | **YES**    | Return `deny(reason)` to block; return `undefined` to allow    |
| `session_shutdown` | **NO**     | Observe-only; emit `process.stderr.write(...)`; return nothing |

`tool_call` (PreToolUse equivalent) can block execution. `session_shutdown` covers both Claude Stop and SubagentStop events and is observe-only — `block()` result is ignored by the Pi runtime on shutdown. This asymmetry differs from Claude's per-event blocking capability. Established convention by existing twins: `session_shutdown` twins emit stderr warnings, NEVER `block()`. Build success is still fail-closed at the wrapper: `codegen-build` reads the gate-result JSON written into `codegen/gate-pending/` after Pi exits. Under the deterministic Elixir orchestration loop (unconditional for every build), each role runs as a separate main-agent invocation, so `session_shutdown` twins matched to a specific role/subagent-completion condition are dead in the build path — they remain live only for non-build modes (debug/shape/ops/experiment) that still spawn subagents.

## Tool Call Event Handler — Pi Tool Name Lowercasing

Pi `tool_call` event handlers receive `event.toolName` as **lowercase pipe-separated** values (`"bash"`, `"write"`, `"edit"`, `"subagent"`), not CamelCase. A single `pi.on("tool_call", ...)` event handler branches on `event.toolName` to route to tool-specific logic. Do NOT register separate handlers per tool — use one handler with internal branching:

```typescript
pi.on("tool_call", (event) => {
  const toolNames = event.toolName.split("|");
  if (toolNames.includes("bash")) {
    /* ... */
  }
  if (toolNames.includes("edit")) {
    /* ... */
  }
});
```

A `tool_call` handler matching subagent spawns receives `event.toolName == "subagent"` (lowercase, singular). MultiEdit tool collapses to `edit` in event matchers (use `write|edit`, never `multiedit`).

## AskUserQuestion — Headless (`!ctx.hasUI`) Behaviour

When Pi is invoked without a UI context (`ctx.hasUI === false`), the `askuserquestion` extension **deregisters** the tool via `pi.setActiveTools(...)` and returns a cancelled response with text `"Error: ask_user_question requires an interactive session. The tool has been disabled for this session."`. This is a runtime backstop — the extension cannot write files, it has no pitch path or write method in `ctx`.

The durable `## Questions` artifact is written by the **agent** (not the extension), via the `## Headless mode (non-interactive)` clause baked into each investigative mode's shared prompt body (`harnesses/shared/prompt-bodies/{shape,refactor,ops,debug}.txt`). The agent writes unresolved decisions as a `## Questions` block in the in-scope pitch file directly; the extension only prevents a blocking tool-call loop.

## Step Log Discovery — Disk Scan vs Transcript Scan

Pi has **NO TRANSCRIPT_PATH** — there is no JSONL transcript available to inspection hooks. Discovery of active session logs or pitches relies entirely on **disk scan** — `readdirSync()` + `statSync()` to find the file with the most recent mtime in the `codegen/logging/` or `codegen/pitches/` directory.

This approach is **structurally immune** to the transcript-scan bug in Claude Code's `session_log_from_transcript`: when a Write is DENIED, the disk scan sees no file created and returns undefined (no log found) → fail-open behavior. Claude Code's Bash transcript-scan, by contrast, extracts the path from the JSONL log and returns it even when creation was denied, requiring explicit `! -e` guards at call sites. Pi avoids this footprint entirely via disk-based discovery.

**Consequence for porting Claude hooks to Pi**: Hooks that depend on transcript inspection (e.g., "developer-\* Agent was called without a step log Write") cannot be ported with full fidelity. Pi twins degrade to reduced-fidelity observe-only heuristics — e.g., "logging dir exists and is recent, but contains zero canonical logs" — and MUST document the gap in a file header comment. The honest move is always: reduced-fidelity twin + explicit documentation, never a fake full-parity implementation.

## Enforcement Hook Registration — Pi index.ts

Pi enforcement hooks are registered in `harnesses/pi/pi-extensions/enforcement/src/index.ts` via an auto-generated block (marked with `// BEGIN-GENERATED-ENFORCEMENT-BLOCK` and `// END-GENERATED-ENFORCEMENT-BLOCK`). The compiler (`enforcement_compiler.py`) generates this block from the registry (`shared/enforcement/registry.yaml`).

**Single-source-of-truth contract**:

- Registry `id` MUST match the `.ts` filename (e.g., `pitch-format-validator` → `pitch-format-validator.ts`)
- Compiler collects all `kind: registration` entries where `harnesses ∈ {all,pi}` AND the corresponding `.ts` file exists
- Compiler also collects all `kind: denial` entries with `emit_ts: true`
- Union of both lists → sorted id set → auto-generated import + register block in `index.ts`
- **Existence guard**: only emit import for ids whose `.ts` file actually exists (prevents broken imports when `harnesses: all` is declared before pi twin is written)
- **MANDATORY Pi twin for `harnesses: all`**: When a hook's registry entry declares `harnesses: all` (or `pi`), `validate_pi_ts_handlers()` runs at `make install` and requires the matching `.ts` file to exist. Install **FAILS** (hard stop, not a warning) if the Pi handler is missing. This is not optional — every `harnesses: all` hook MUST have both `.sh` and `.ts` implementations before installation completes. If you are authoring a new `harnesses: all` hook, write the `.ts` twin BEFORE running `make install` or the build will abort with a missing-handler error.

**Hand-maintained imports outside the block**: none currently — the prior deferred hook (`context-index-parity`, NOT-YET-MIGRATED) was deleted along with its 2 role:-unset siblings; enforcement moved to `context-factcheck-edit-gate` (a normal `kind: registration` entry, generated block) and the in-loop `run_curator_doc_check` step. If a future hook is deferred (commented-out registry entry), its import/register call must be hand-maintained outside the markers, same pattern as before.

**Idempotency and cleanup**: When widening the generated set (e.g., flipping registry `harnesses: claude` → `all` for 4 hooks, adding 7 new registrations), the marker-replace compiler branch only rewrites content BETWEEN markers — it does NOT auto-delete hand-written imports outside the markers. One-time manual cleanup is required after widening; thereafter re-running `make install` produces an idempotent block with zero diff.

## Agent Identity Detection

Pi enforcement hooks detect agent roles via environment variables only:

- **Role/type**: `process.env.AGENT_TYPE` (e.g., `"developer-phoenix-backend"`, `"reviewer-phoenix"`, empty for orchestrator)
- **Agent ID**: `process.env.AGENT_ID` (populated for subagents; empty for orchestrator and top-level roles)
- **Orchestrator-level gate**: `AGENT_TYPE` is empty **AND** `AGENT_ID` is empty (both conditions required)
- **ops-mode bypass**: No `resolveRole()` helper exists in hook-helpers.ts. Inline the bypass by reading `process.env.PI_ROLE ?? process.env.CLAUDE_ROLE === "ops"` directly in the hook file.

**Why no `resolveRole()` helper**: The helper lives in the shared lib, which is sibling-pitch territory for feature-only twins (file-only, no lib changes). Each hook inlines its own bypass pattern to avoid touching the shared library.

## Test Isolation — Node 22+ Concurrent `describe()` Children

Node 22+ runs `describe()` children (`it()` blocks) concurrently by default. When tests use `process.chdir()`, this pollutes the process-global working directory across concurrent siblings. Fix: add `{ concurrency: 1 }` option to `describe()` calls to serialize when process-global state (cwd, env vars, streams) is involved:

```typescript
describe("hook-name", { concurrency: 1 }, () => {
  it("test 1", () => {
    process.chdir(tmpDir);
    // ...
    process.chdir(originalCwd);
  });
  it("test 2", () => {
    // will not run until test 1 completes
  });
});
```

Applies to enforcement hooks and any extension tests that manipulate `process.cwd()` or process environment.

**Stream capture scope**: When tests capture stderr/stdout to verify error handling (e.g., warnings), move capture to test-body scope rather than `beforeEach`/`afterEach` hooks. This ensures each test owns its capture window and avoids cross-test pollution under parallel runners. Restore streams in both resolve and reject paths to prevent leakage on assertion failure.

**macOS symlink path normalization**: `os.tmpdir()` returns `/var/folders/...` but `fs.realpathSync` resolves to `/private/var/folders/...` — this symlink mismatch breaks `repoRelative()` when test CWD is set to the non-canonical tmpDir. Workaround: use relative paths in file-path test stubs instead of absolute paths; relative paths are unaffected by the symlink resolution mismatch.

## Harness Drift Patterns

Registry entries claiming `harnesses: claude` are NOT automatically inspected for Pi twins. A hook with both Claude `.sh` and Pi `.ts` implementations but registry `harnesses: claude` is a drift bug: the pi code is never registered, remaining dead code. Conversely, a Pi `.ts` without a registry entry is unregistered (missing imports in `index.ts`).

**Detection**: Audit bidirectionally when changing harness scope:

- **Registry→Files**: which registry entries claim `all|pi` but have NO `.ts` file? Over-claimed (transient during development; prevent broken imports via existence guard).
- **Files→Registry**: which `.ts` files exist but have registry `claude`? Under-claimed (stale registry; flip to match living code; update any stale rationale lines, e.g., "Agent tool not present in Pi harness" when a working twin exists).

Examples of stale rationale: When a hook has registry `harnesses: claude` + `tool_guard: Agent` + rationale "Agent tool not present in Pi harness", but a pi `.ts` twin exists with matcher `tool_call`/`subagent`, the rationale is false. Flip the registry to `harnesses: all` and update the rationale to reflect the pi behavior (e.g., "Pi twin registers on tool_call/subagent").

## Worktree Isolation — Reduced-Fidelity Pi Twin

Pi's `seedPhoenixBuild()` in subagents/src/runs/shared/worktree.ts seeds Phoenix dependencies (`deps` symlink + `_build` copy under same-commit guard) for worktree isolation. The Pi implementation is **reduced-fidelity**: it seeding only and does NOT allocate a fresh port per worktree. Port allocation in Claude is handled via `WorktreeCreate` hook's call to `allocate_phoenix_port()` from `resource_manager.sh`, which maintains a project-scoped registry of in-use ports. Pi's `seedPhoenixBuild()` registers seeded paths as `syntheticPaths` (returned by `createSingleWorktree`'s setup hook), but has **no port-allocation registry backend**. The Pi harness manages ports externally (outside hook scope). When porting Claude's `WorktreeCreate` hook logic to Pi, seed the `_build` + `deps` internally in `createSingleWorktree` and document the port gap in a header comment.

## Subagents Extension — `/loop` Slash Command

The `subagents` extension ships a `/loop` slash command (src/slash/loop-command.ts) that provides an interactive self-firing recurring-poll story for `pi-ops` and `pi-debug`.

| Aspect                    | Detail                                                                                                                                                                               |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Command syntax            | `/loop [5m\|30s] <prompt>` or `/loop stop`                                                                                                                                           |
| Interval grammar          | Optional leading `\d+(s\|m)` token (e.g., `30s`, `5m`); default 5 minutes                                                                                                            |
| Headless (`!ctx.hasUI`)   | Emits a detect-and-tell message; arms NO interval (explicit limitation, not a silent fallback)                                                                                       |
| Interactive (`ctx.hasUI`) | Confirms cadence via notify, fires first tick immediately via `pi.sendMessage({triggerTurn:true})`, arms `setInterval` stored in `state.loopTimers`                                  |
| Cancel                    | `/loop stop` or Esc key — both call `clearInterval` and remove from `state.loopTimers`                                                                                               |
| Session cleanup           | `session_shutdown` clears all `loopTimers` (observe-only; non-blocking)                                                                                                              |
| Fidelity note             | In-session interval only — no cron, no cross-session persistence, no `Monitor` line-stream parity (honest reduced-fidelity twin vs Claude's `CronCreate`/`Monitor`/`ScheduleWakeup`) |

Timer deps are injected via a `LoopDeps` interface (`{setInterval, clearInterval}`) for hermetic unit testing without real timers. Tests live in test/unit/loop-command.test.ts (runs on TS source directly via `node --experimental-strip-types --test`; no build step needed).

## Pitfalls

- **Each extension is an independent npm package** — `npm install` must be run per-extension, not at repo root
- **`package-lock.json` files are per-extension** — commit them; they are the reproducibility guarantee
- **`package-lock.json` churn is normal** — subagents/package-lock.json and web-utils/package-lock.json may appear dirty when different npm versions resolve deps differently; do not panic-commit these changes without intentional npm updates
- **TypeScript compile errors block Pi harness** — extension build failures prevent Pi from loading the tool
- **Extension structure varies** — `enforcement` has no root-level `index.ts` (entry is under `src/`); all four extensions have a `src/` subdirectory; do not assume a uniform layout at root level across all four extensions
- **`\z` anchor (PCRE) not supported in JS regex** — JavaScript regex treats `\z` as literal `z`. When porting regex from Bash/Ruby, replace end-of-string anchors with string-split patterns: `text.split(header)` + `slice` to find section boundary instead of `(?=\n###)` lookahead anchors. If the regex has a fallback pattern, the bug is masked in tests but creates a latent over-match edge case.
- **Markdown section body extraction** — avoid `\z`-anchored regex for extracting markdown section bodies. Prefer string-split pattern: `split("## ")[N]` then slice to the next `\n## ` boundary. This avoids both regex limitations and makes intent explicit.
- **[shared] JS `\s` vs bash grep** — JS `\s` crosses newlines; bash grep per-line. Use `[ \t]` for same-line-only whitespace parity.
- **Pi enforcement tests run against compiled dist, not source** — Pi extension tests for enforcement hooks must run against compiled `dist/*.test.js`, NOT `.ts` source files directly. Pattern: `npm run build && npm test`. Running `node --test src/...ts` fails with `ERR_MODULE_NOT_FOUND` even after build.
- **Stale compiled dist/ test artifacts survive src deletion** — Fix: `rm -rf dist &&` as first step of build script.
- **Makefile npm-ext race** — Parallel `make test`: both `subagents-integration` + npm-ext loop target `subagents/dist/`. Fix: serialize build BEFORE pids fan-out. Each npm leaf (`npm-ext`, `subagents-integration`, `mcp-server`) captures its own status via an explicit `if ! out=$(...); then ...; fi` conditional rather than a bare `out=$(...)`/`rc=$?` pair — the latter aborts the whole arm under `set -e` before `rc=$?` runs, silently skipping sibling leaves in the same loop.
- **Pi guard scope** — Use `projectDir` (repo tested), not `codegenDir` (checker location); codegenDir checks skip every run.
- **Pi test `git commit` + global `commit.gpgsign=true`** — Parallel npm-ext tests MUST call `git config commit.gpgsign false` per tmpDir setup to isolate from global config.

## Trigger Keywords

pi-extension, askuserquestion, enforcement, web-utils, subagents extension, npm, TypeScript, generate-pi-extension.sh, markdown section split, string-split pattern
