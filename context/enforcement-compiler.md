# Enforcement Compiler — Registry, Pattern Dialects, Install Workflow

## Enforcement Compiler

`templates/generator/enforcement_compiler.py` generates enforcement hook scripts from a declarative registry (`shared/enforcement/registry.yaml`). Two entry kinds:

- **`kind: denial`** (default when `kind` absent) — generates ENTIRE `.sh`/`.ts` files (header + body). `generated: true` means `make install` OVERWRITES the whole file. Only 2 CLAUDE `.sh` files are owned this way (verify: `grep -c 'kind: denial' shared/enforcement/registry.yaml`).
- **`kind: registration`** — does NOT generate any file body. Header-only: `hook_registrations.py --emit-headers` reads these entries and injects the `# HOOK-MANIFEST:` block into the existing hand-written `.sh`, leaving body bytes identical. 56 behavioral hooks use this path (verify: `grep -c 'kind: registration' shared/enforcement/registry.yaml`).

Both kinds coexist in `shared/enforcement/registry.yaml`. The compiler skips `kind: registration` entries entirely — they have no `match`/`message` and are not denial rules.

**Content-matching hooks are always `kind: registration`** — the compiler's `source` axis supports only `COMMAND` (`.tool_input.command`) and `FILE_PATH` (the file path); neither reaches Edit/Write CONTENT (`.tool_input.new_string` / `.tool_input.content`). A hook that must inspect the text being written (e.g. `no-silent-failure` scanning for swallow tokens, `context-curator-guard` scanning path + projected line count) is hand-authored: `kind: registration` header + a hand-written body reading content directly from `$RAW_INPUT` via jq (bash) or `event.input` (Pi TS). Adding a `source: CONTENT` compiler template is a larger shared-codepath change (touches `parse_input` for every hook) and is not required — the hand-authored precedent is the sanctioned default for this class.

### Compiler Axes

**Source axis** — what the guard pattern matches:

- `source: COMMAND` — matches the bash command being executed
- `source: FILE_PATH` — matches the file path argument to Write/Edit

**Mode axis** — matching logic:

- `mode: deny` (default) — if pattern matches → deny; default is pass-through
- `mode: allowlist` — if pattern does NOT match → deny; default is allow; valid for both COMMAND and FILE_PATH sources

**Role axis** — scope by agent:

- `signal: AGENT_TYPE` — gate-guard on `$CLAUDE_ROLE` or `$PI_ROLE`; check proceeds only for listed role(s)
- `bypass_roles: [list]` — launcher-mode values (debug, shape, ops, …) that exit 0 immediately before role/match gates (from `resolve_role()` which folds `CLAUDE_ROLE > PI_ROLE`); emits prelude sourcing `_role.sh` (bash) or env-reading process.env (TS); placement: after `parse_input`, before AGENT_TYPE gate

**Harness axis** — deployment target (Claude Code, Pi, or both):

- `harnesses: claude` (or `pi` or `all`) — determines which harness(es) own the hook. Verified bidirectionally: registry `harnesses: all` with a working pi `.ts` file is a drift if the registry was hand-maintained before compiler widening. Always audit both directions (registry→files AND files→registry) when migrating hand-wired hooks to generated blocks.

### Template Forms

| Source    | Mode      | Body Template                                                                                         | Role Gate                          |
| --------- | --------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------- |
| COMMAND   | deny      | `if grep -qE '<pattern>' <<< "$COMMAND"; then deny; fi`                                               | AGENT_TYPE guard wraps entire body |
| COMMAND   | allowlist | `if grep -qE '<pattern>' <<< "$COMMAND"; then exit 0; fi; deny`                                       | AGENT_TYPE guard wraps entire body |
| FILE_PATH | allowlist | Multi-tool switch (Write/Edit); each arm: `if grep -qE '<pattern>' <<< "$FILE_PATH"; then exit 0; fi` | AGENT_TYPE guard wraps entire body |

All forms compose with `bypass_roles` prelude (if specified): the bypass exits early, skipping both role and match gates.

### Registry Fields

| Field          | Type   | Purpose                                                                                                                                        | Default  |
| -------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| `id`           | string | Hook filename slug (kebab-case); MUST match both `.sh` (Claude) and `.ts` (Pi) filenames — compiler contract is `id == filename`, no overrides | —        |
| `kind`         | string | `denial` (full-file generation) or `registration` (header-only injection)                                                                      | `denial` |
| `generated`    | bool   | Compiler owns the output; `make install` regenerates it. Only valid for `kind: denial`                                                         | —        |
| `event`        | string | Hook event (PreToolUse, SubagentStop, Stop)                                                                                                    | —        |
| `source`       | string | COMMAND or FILE_PATH                                                                                                                           | COMMAND  |
| `mode`         | string | deny or allowlist                                                                                                                              | deny     |
| `tool_guard`   | string | Canonical registry form; rendered to hook header as `matcher:`. Tool name (Bash, Write, Edit, …)                                               | —        |
| `match`        | string | Single regex-neutral pattern (mutually exclusive with `match_all`). Only for `kind: denial`                                                    | —        |
| `match_all`    | list   | AND-logic pattern list (mutually exclusive with `match`). Only for `kind: denial`                                                              | —        |
| `message`      | string | Denial reason shown to agent. Only for `kind: denial`                                                                                          | —        |
| `signal`       | string | Hook signal (none, AGENT_TYPE, …)                                                                                                              | none     |
| `role`         | string | Role scope: `*` (all) or pipe-separated (e.g., committer\|reviewer)                                                                            | `*`      |
| `bypass_roles` | list   | Launcher-mode values (debug, shape, ops) that exit before gates                                                                                | —        |
| `harnesses`    | string | Canonical form: `claude` or `pi` (registry enum). Rendered to hook header as `claude_code` or `pi`. Deployment target (all, claude, pi)        | all      |
| `rationale`    | string | Hook rationale text (optional, supports multi-line via YAML block scalar `\|`). For `kind: registration` only                                  | —        |
| `canonicalize` | string | Path canonicalization (repo_relative); FILE_PATH only                                                                                          | —        |
| `surface`      | string | Rendered as `# surface: {surface}` header comment (e.g., `user_global`); documents hook exposure scope                                         | —        |

### Pattern Dialect

Registry patterns use dialect-neutral syntax; compiler translates to target:

| Pattern  | Bash (ERE)    | JavaScript          |
| -------- | ------------- | ------------------- |
| `\s`     | `[[:space:]]` | `\s` (pass-through) |
| `\b`     | `\b`          | `\b`                |
| `(a\|b)` | `(a\|b)`      | `(a\|b)`            |

FORBIDDEN: backreferences (`\1`, `\2`), lookahead/lookbehind (`(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`).

### Installation Workflow

1. `make install` → runs `enforcement_compiler.py`
2. Compiler reads `shared/enforcement/registry.yaml`
3. For each `kind: denial` entry with `generated: true`, emits:
   - Bash hook → `harnesses/claude/hooks/<id>.sh` (chmod +x)
   - TypeScript hook → `harnesses/pi/pi-extensions/enforcement/src/hooks/<id>.ts`
4. Compiler collects pi-registerable ids: union of `kind: denial` entries with `emit_ts: true` AND `kind: registration` entries where `harnesses ∈ {all,pi}` AND the corresponding `.ts` file exists at `pi-hooks-dir/<id>.ts`. Compiler invokes `_update_index(index_ts_path, register_ids)` to update Pi `index.ts` GENERATED block (BEGIN/END markers) with sorted hook imports + registrations.
   - **Existence guard**: only emit `import`/`register` for an id whose `.ts` file actually exists. Prevents broken imports for `harnesses: all` entries whose pi twin hasn't been written yet (transient state during development).
   - **`--pi-hooks-dir` argument**: passed to compiler explicitly (Makefile) so existence guard checks the REAL hooks directory. Without it, tests copying `index.ts` to `/tmp` would have `index_path.parent == /tmp`, causing the guard to check the wrong path and generate a smaller block. Both `make install` and `make enforce-registry-parity` must use the same `--pi-hooks-dir` path for idempotency.
   - **Marker-replace branch**: if committed `index.ts` already contains `// BEGIN-GENERATED-ENFORCEMENT-BLOCK` and `// END-GENERATED-ENFORCEMENT-BLOCK` markers, the compiler replaces content BETWEEN markers only — it does NOT auto-remove hand-written import/register lines OUTSIDE the markers. One-time manual cleanup required after widening the generated set; thereafter file is idempotent.
5. **`hook_registrations.py --emit-headers` reads `kind: registration` entries → injects `# HOOK-MANIFEST:` header into each hand-written `.sh` (body unchanged).** CRITICAL: `render_header()` must NOT include a trailing `#` terminator line — `inject_header()` preserves the terminator from the original file body. Header span is injected idempotently via mktemp/cmp/mv.
6. `hook_registrations.py` rescans hook source dirs and rewrites `claude-code-settings.json` + pi manifest entries
7. Committed generated files must be byte-identical to compiler output → `make enforce-registry-parity` gate (part of `make test`) verifies this
8. Committed hook headers must match registry entries → `make hook-header-parity` gate (part of `make test`) verifies this

**Order dependency**: emit-headers (step 5) MUST run before hook-parity (step 6) so the settings generated from hook headers reflect the freshly-injected headers. Reversed order → stale settings.

**Widening the generated set**: when migrating hand-maintained hook registrations to generated blocks (e.g., pi `index.ts` registration imports), audit the change bidirectionally BEFORE widening the filter:

- Registry→files: which entries have `harnesses: all|pi` but NO corresponding `.ts` file? (over-claimed entries; existence guard prevents broken imports)
- Files→registry: which `.ts` files exist but have `harnesses: claude`? (under-claimed entries; flip to match living code)

The generated set is rarely purely additive; drops are silent runtime breaks if undetected.

### Header Injection Implementation Details

**`hook_registrations.py --emit-headers` and `--check-headers` modes:**

- `render_header(entry)` — builds the canonical `# HOOK-MANIFEST:` block from a `kind: registration` entry. **CRITICAL**: do NOT include a trailing `#` line in the rendered output — `inject_header()` preserves the file's original terminator (blank `#` or first non-`#` line). Including a terminator in the render causes apparent header drift on the first parity check.
- `inject_header(script_path, header_text)` — rewrites ONLY the header span (from `# HOOK-MANIFEST:` to the original terminator) in an existing hook script, leaving body bytes identical. Uses mktemp/cmp/mv for idempotency (re-running with unchanged input → no file touch).
- `--emit-headers` — injects freshly-rendered headers into all migrated hooks. Must run before `hook_registrations.py` default mode (step 6) to ensure settings are derived from the new headers.
- `--check-headers` — regenerates headers to /tmp and diffs vs committed `.sh` files. Used by `make hook-header-parity` gate to verify headers match the registry.
- Token mapping: registry stores `claude` (enum), but header field is `claude_code` (hook script format). Renderer maps `claude` → `claude_code` when emitting. Parser already accepts both via `hook_registrations.py`'s `VALID_HARNESSES` (currently `{"claude_code", "pi"}`) — distinct from `enforcement_compiler.py`'s own `_VALID_HARNESSES = ("all", "claude", "pi")` (registry-enum validation, different module, different value set/naming).
- Multi-line `rationale`: stored in registry as YAML block scalar (`|`); renderer emits `# rationale:` first line + `#   ` (indent) continuation lines. Parity diff catches any byte drift on round-trip.

## Enforcement Compiler — Renderer-Neutral Regex Tokens

`enforcement_compiler.py` `_to_bash` does a literal `.replace(r"\s", "[[:space:]]")` — this fires inside character classes too, corrupting nested brackets. When defining regex patterns in `shared/enforcement/registry.yaml` that compile to both bash ERE and JavaScript regex, avoid `\s` inside char classes (`[^&\s]`, `[\s]`) — they become `[^&[[:space:]]]` (broken) in bash. Use `\S` instead (negated class that round-trips identically across both renderers): `match: "[^&]*\\S+"` → bash: `[^&]*\S+`; JS: `/[^&]*\S+/`. Verify by testing both `_to_bash` and `_to_ts` renderers on the pattern.

## Pitfalls

- **Registry `generated: true` means compiler-owned** — hooks with `generated: true` + no `kind: registration` have compiler-owned bodies. Hand-editing .sh/.ts directly causes registry-parity DRIFT. Fix: edit shared compiler template, let compiler regenerate all siblings sharing that template.
- **Compiler templates regenerate all siblings** — Template fix regenerates all; reverting siblings re-triggers DRIFT. Accept symmetric regeneration.
- **Multi-value `role: "a\|b"` compiler case-arm join breaks `hook_registrations.py` role-parity** — bash case-arm emitter must join multi-value role tokens with `" \| "` (space-padded); a bare `a\|b)` join leaves non-last tokens unmatched → `make hook-parity` fails. Fix is compiler-side.
- **Hook alphabetical id ordering in settings.json** — `hook_registrations.py --output-settings` generates entries in alphabetical id order. Hand-inserted registry entries in the wrong order cause hook-parity diff on `make install`. Remedy: sort new entries alphabetically in `registry.yaml` OR reorder and re-run `make install`.

## Trigger Keywords

enforcement_compiler.py, registry.yaml, kind: denial, kind: registration, renderer-neutral regex tokens, pattern dialect, COMMAND/FILE_PATH source, hook generation, negated class, bash vs TS renderer parity, registry generated compiler-owned, compiler template regeneration, hook alphabetical ordering
