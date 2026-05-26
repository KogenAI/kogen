# Adding a Harness to OCG

OCG supports multiple LLM harnesses (currently `claude` and `pi`). Each harness is declared in a single manifest file. Adding or swapping a harness is `drop one manifest + make install`.

## Manifest = SSoT

Every harness's surface is declared in `harnesses/<harness>/manifest.yaml`. The manifest drives:

- Which generator to call (renders subagent `.md.j2` templates)
- Where agents land (`agents_dir`)
- Launcher scripts + their install destinations
- Zsh completions
- Per-mode model/effort/tools/system-prompt configuration
- Install/uninstall step declarations

## Directory Layout

```
harnesses/
  <harness>/
    manifest.yaml          ← SSoT (this doc walks every field)
    tools-header/          ← per-harness system prompt content (one file per mode)
      build.txt
      debug.txt
      shape.txt
      refactor.txt
    <harness>-build-system-prompt.txt    ← generated (concat of tools-header + shared body)
    <harness>-debug-system-prompt.txt    ← generated
    <harness>-shape-system-prompt.txt    ← generated
    <harness>-refactor-system-prompt.txt ← generated
    <launcher>.sh                        ← launcher scripts
    _<completion>                        ← zsh completion files
    dispatch.sh                          ← codegen-build dispatch (for build mode)
  shared/
    prompt-bodies/         ← shared system prompt body per mode (currently empty)
      build.txt
      debug.txt
      shape.txt
      refactor.txt
```

## manifest.yaml Field Reference

### Top-level

| Field | Type | Description |
|-------|------|-------------|
| `harness` | string | Harness name (must match directory name). |
| `agents_dir` | path | Where rendered subagent `.md` files are installed (e.g. `~/.claude/agents`). |
| `generator` | path (relative to CODEGEN_DIR) | Script that renders subagent templates. Currently both harnesses use `templates/generator/generate.sh`. |
| `prompts_dir` | path | (Pi only) Where slash-command prompts land (`~/.pi/agent/prompts`). |
| `prompts_source` | path | (Pi only) Source dir for prompts. |
| `prompts_install` | list | (Pi only) Specific files to install from `prompts_source`. |
| `settings_file` | path | (Claude only) Claude Code settings JSON destination. |
| `settings_source` | path | (Claude only) Source settings JSON. |
| `hooks_dir` | path | (Claude only) Where hook scripts are installed. |
| `hooks_source` | path | (Claude only) Source hook scripts directory. |
| `commands_dir` | path | (Claude only) Where slash commands are installed. |
| `commands_source` | path | (Claude only) Source commands directory. |

### `launchers` list

Each entry installs one executable to `~/.local/bin/`:

```yaml
launchers:
  - name: claude-build     # destination filename in ~/.local/bin/
    src: harnesses/claude/claude-build.sh   # source, relative to CODEGEN_DIR
```

### `completions` list

Zsh completion filenames (prefixed with `_`), installed from `harnesses/<harness>/`:

```yaml
completions:
  - _claude-build
  - _claude-shape
  - _claude-refactor
```

### `modes` map

One entry per launcher mode (`build`, `debug`, `shape`, `refactor`):

```yaml
modes:
  shape:
    model: opus                           # Model short-name (claude) or full ID (pi)
    effort: high                          # Effort level
    output_format: text                   # stream-json | text
    tools: [Agent, Bash, ...]             # Claude: --tools list. Pi: comma-separated string.
    extensions: [askuserquestion, ...]    # Pi only: --extension list
    system_prompt_file: harnesses/claude/claude-shape-system-prompt.txt
    tools_header: harnesses/claude/tools-header/shape.txt
    prompt_body: harnesses/shared/prompt-bodies/shape.txt
```

**`system_prompt_file`**: path (relative to CODEGEN_DIR) to the final assembled system prompt.
Loaded at runtime by launchers via `load-role.sh` (claude) or `cat` (pi).

**`tools_header`** + **`prompt_body`**: generate.sh concats these → `system_prompt_file`.
Currently `prompt_body` files are empty (full content in `tools_header`).
When harnesses converge on a shared body, extract common lines to `shared/prompt-bodies/<mode>.txt`
and keep only divergent tool-wrapping lines in `tools_header`.

**model / effort**: Claude launchers read these from `templates/generator/config.yaml` `roles.<mode>`
via `load-role.sh`. Pi launchers read them via `yq` directly from config.yaml.
Manifest lists them as documentation-of-record; config.yaml is authoritative at runtime.

### `install_steps` / `uninstall_steps`

Declarative record of what the install loop does. Not executed directly — `install.sh`
implements them. Use this as a checklist when adding new install behaviour.

## Generate + Install Flow

```
make install
  ↓ hook-parity (validates claude-code-settings.json)
  ↓ generate-pi-extension.sh (pi enforcement extension build)
  ↓ hook_registrations.py (regenerates claude-code-settings.json)
  ↓ install.sh
      ↓ source manifest-lib.sh
      ↓ generate.sh claude pi
          ↓ _generate_claude → templates/generated/claude-code/agents/*.md
          ↓ manifest_regenerate_prompts claude
              ↓ cat tools-header/build.txt shared/prompt-bodies/build.txt → claude-build-system-prompt.txt
              ↓ (repeated for debug, shape, refactor)
          ↓ _generate_pi → templates/generated/pi/agent/*.md
          ↓ manifest_regenerate_prompts pi
      ↓ harness loop (claude, pi):
          ↓ install agents, settings, hooks, commands, deps (claude)
          ↓ install agents, prompts (pi)
          ↓ manifest_launchers → install launchers
          ↓ manifest_completions → install zsh completions
```

## How to Add a New Harness

1. **Create `harnesses/<name>/manifest.yaml`** — copy claude or pi manifest, adjust all fields.

2. **Create `harnesses/<name>/tools-header/<mode>.txt`** for each mode — full system prompt content
   (or just the divergent header if sharing a body with another harness).

3. **Add launcher scripts** at `harnesses/<name>/<name>-<mode>.sh`.
   - Must exec `codegen-build --harness=<name>` (build mode) or call the LLM CLI directly.

4. **Add zsh completions** at `harnesses/<name>/_<name>-<mode>`.

5. **Add dispatch logic**:
   - `harnesses/<name>/dispatch.sh` — called by `codegen-build --harness=<name>`.
   - Wire into `codegen-build` and `harnesses/<harness>/dispatch.sh` per existing pattern.
   - Update `codegen-build_test.sh` test cases.

6. **Register the harness name** in `install.sh` arg-parse (`claude | pi | <name>` in case statement)
   and add a `<name>)` case in the harness install loop for any harness-specific install steps.

7. **Add generator support** in `generate.sh`:
   - Add `_generate_<name>()` function.
   - Add `<name>)` case in the main loop.

8. **Run `make install --harness=<name>`** — verify agents install, launchers land in `~/.local/bin/`,
   completions install.

9. **Run `make test && make rule-parity && make hook-parity`** — all must pass.

## System Prompt Authorship

System prompts live in `harnesses/<harness>/tools-header/<mode>.txt` and are assembled by
`manifest_regenerate_prompts` in `manifest-lib.sh`:

```bash
cat tools-header/<mode>.txt shared/prompt-bodies/<mode>.txt > <harness>-<mode>-system-prompt.txt
```

The `*-system-prompt.txt` files are committed as regenerated artifacts (content-stable;
`make install` rewrites only when content changes). Launchers load them at runtime:
- Claude: `load-role.sh` reads `config.yaml roles.<mode>.system_prompt_file`
- Pi: launchers directly `cat "$SYSTEM_PROMPT_FILE"`

## config.yaml Boundary

`templates/generator/config.yaml` owns model/effort/tools/`system_prompt_file` for claude
launchers (consumed by `load-role.sh`). The manifest's `modes.*` entries mirror these for
documentation and for pi launchers that read config.yaml directly.

Do NOT remove `roles.<mode>.system_prompt_file` from config.yaml — `load-role.sh` reads it.

## Parity Gates

After any manifest or install change, all gates MUST be green:

```bash
make test          # hook unit tests + harness-parity + pi npm tests
make rule-parity   # AGENTS.md / CLAUDE.md match template render
make hook-parity   # claude-code-settings.json matches hook_registrations.py output
```
