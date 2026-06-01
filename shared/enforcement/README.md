# shared/enforcement/registry.yaml — Schema Reference

Declarative registry of enforcement denial rules. Single source of truth for hook
generation across Claude Code (bash `.sh`) and Pi (TypeScript `.ts`) harnesses.

## File Location

`shared/enforcement/registry.yaml`

## Field Reference

| Field        | Type            | Required | Description                                                                     |
| ------------ | --------------- | -------- | ------------------------------------------------------------------------------- |
| `id`         | string          | yes      | Kebab-case slug. Becomes output filename (`no-cat-pipe` → `no-cat-pipe.sh/.ts`) |
| `generated`  | bool            | yes      | `true` = compiler owns output files. `false` = hand-authored, compiler skips.   |
| `event`      | string          | yes      | Claude Code hook event: `PreToolUse`, `SubagentStop`, `Stop`                    |
| `tool_guard` | string          | yes      | Tool name that triggers the check: `Bash`, `Write`, `Edit`, etc.                |
| `match`      | string          | cond     | Single regex-neutral pattern. Mutually exclusive with `match_all`.              |
| `match_all`  | list of strings | cond     | All patterns must match (AND logic). Mutually exclusive with `match`.           |
| `message`    | string          | yes      | Denial reason shown to the agent verbatim.                                      |
| `surface`    | string          | yes      | Hook surface: `user_global`, `project`, etc.                                    |
| `signal`     | string          | yes      | Hook signal: `none`, `AGENT_TYPE`, etc.                                         |
| `role`       | string          | yes      | Role scope. `"*"` = all roles.                                                  |
| `harnesses`  | string          | yes      | Which harnesses deploy this hook: `all`, `claude`, `pi`.                        |

Either `match` or `match_all` must be present — not both, not neither.

## Regex-Neutral Pattern Rules

Registry patterns use a dialect-neutral subset of regex:

- `\s` — whitespace (NOT `[[:space:]]` — that is bash-ERE only; compiler translates)
- `\b` — word boundary (supported in bash ERE and JS)
- `(a|b)` — alternation (both dialects)
- `[^|]` — negated character class (both dialects)
- `\.` — escaped literal dot (both dialects)

### Dialect Translation (by compiler)

| Registry | Bash (ERE)    | TypeScript/JS |
| -------- | ------------- | ------------- |
| `\s`     | `[[:space:]]` | `\s`          |
| `\b`     | `\b`          | `\b`          |

### FORBIDDEN Patterns in Registry

These constructs are not portable across dialects and are rejected by the compiler:

- Backreferences: `\1`, `\2`, etc.
- Lookahead: `(?=…)`, `(?!…)`
- Lookbehind: `(?<=…)`, `(?<!…)`

## Compiler

`templates/generator/enforcement_compiler.py`

Invocation:

```
python3 templates/generator/enforcement_compiler.py \
  --registry shared/enforcement/registry.yaml \
  --bash-out harnesses/claude/hooks \
  --ts-out harnesses/pi/pi-extensions/enforcement/src/hooks \
  --index harnesses/pi/pi-extensions/enforcement/src/index.ts
```

- Reads registry via `yq -o=json '.'`
- Translates patterns per target dialect
- Emits bash hooks with `HOOK-MANIFEST:` headers (for `hook_registrations.py`)
- Emits TypeScript hooks with `HANDLER_META` + `register()` export
- Updates the `// GENERATED-ENFORCEMENT-BLOCK` markers in `index.ts`

## Parity Verification

`make enforce-registry-parity` compiles to `/tmp` and diffs against committed files.
Wired into `make test:` — runs before hook tests.

## Adding a New Denial Rule

1. Add an entry to `registry.yaml` with `generated: true`.
2. Run `make install` — compiler generates the `.sh` and `.ts` files.
3. Run `make test` — parity check verifies output matches registry.
4. Commit registry + generated files together.

## Hand-Authored Hooks

Set `generated: false` (or omit the entry entirely). The compiler skips entries
with `generated: false`. Hand-authored hooks live in:

- `harnesses/claude/hooks/<id>.sh`
- `harnesses/pi/pi-extensions/enforcement/src/hooks/<id>.ts`
