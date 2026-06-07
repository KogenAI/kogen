# Deployment Topology

Where codegen runs, what the root path is per machine/OS, and the rules that follow from multi-location reality.

## Current Locations

| Location                              | OS    | Codegen root                                        |
| ------------------------------------- | ----- | --------------------------------------------------- |
| combobulate prod                      | Linux | `<OPERATOR_FILL: combobulate prod codegen root>`    |
| combobulate staging                   | Linux | `<OPERATOR_FILL: combobulate staging codegen root>` |
| dashboard box (Hetzner CCX13, Ubuntu) | Linux | `~/apps/codegen`                                    |
| operator Macs                         | macOS | `~/Areas/Optimum/codegen`                           |

## Trajectory

Narrowing to combobulate (prod + staging) and the Hetzner dashboard box as the primary production locations. Operator Macs remain for local development. Expect the Linux locations to dominate in CI/CD and automated operations.

## Cardinal Rule

Root differs per machine AND OS — NOTHING hardcodes it. Every script that needs the repo root derives `CODEGEN_DIR` from its own location via `BASH_SOURCE`:

```bash
CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

See `install.sh`, `uninstall.sh`, `update_ai_tools.sh` — all use this idiom at line 1. Launcher scripts installed to `~/bin/` or `/usr/local/bin/` are no longer physically adjacent to the repo root and use one of two derivation strategies depending on launcher type.

## Symlink Resolution Mechanics (Critical for `harnesses/` symlink traversal)

When `harnesses/` is symlinked from `$SCRIPT_DIR` (install target) back to the codegen repo root, path traversal via `..` is context-sensitive:

- **`cd symlink/..`** — resolves `..` relative to the symlink's LOCATION (not its target). If symlink is `~/bin/harnesses → /path/to/repo/harnesses`, then `cd ~/bin/harnesses/.. → ~/bin`, NOT `/path/to/repo`.
- **`cd -P symlink && cd ..`** — `-P` flag forces physical path resolution. Traversing the symlink target's real parent correctly. This is the portable pattern for symlink-aware launchers.

Non-build launchers (shape, refactor, debug, ops) that derive `CODEGEN_DIR` via the installed `harnesses/` symlink MUST use `cd -P` to avoid landing in `~/bin` instead of the repo root.

- **Build launchers** (`claude-build.sh`, `pi-build.sh`): resolve the `codegen-build` binary as a sibling of `$SCRIPT_DIR` (co-installed in the same directory). No repo-root walk needed.
- **Non-build launchers** (shape, refactor, debug, ops, etc.): 3-branch `CODEGEN_DIR` derivation:
  1. `OCG_CODEGEN_DIR` env override if set (escape hatch)
  2. Installed-flat: follow the `harnesses/` symlink from `$SCRIPT_DIR` to derive the repo root
  3. In-repo checkout fallback: `$SCRIPT_DIR/../..`
- **`dispatch.sh`**: derives repo root via `$(cd "$SCRIPT_DIR/../.." && pwd -P)`, walking the physical path of the installed `harnesses/` symlink.

## Install Targets vs Source Location

| Artifact type | Install target                | Source                                       |
| ------------- | ----------------------------- | -------------------------------------------- |
| Agent prompts | `~/.claude/agents/*.md`       | `shared/subagents/*.md.j2`                   |
| Hook scripts  | `~/.claude/hooks/*.sh`        | `harnesses/claude/hooks/`                    |
| Settings      | `~/.claude/settings.json`     | `harnesses/claude/claude-code-settings.json` |
| Launchers     | `~/bin/` or `/usr/local/bin/` | `harnesses/claude/`, `harnesses/pi/`         |
| Pi extensions | `~/.pi/`                      | `harnesses/pi/pi-extensions/`                |

`~/.claude/`, `~/.pi/`, `/usr/local/bin/` (or `~/bin/`) are install TARGETS — where `make install` writes artifacts. They are NOT where source lives. Source lives in the codegen repo root (which differs per machine).

## OCG_CODEGEN_DIR Override

`OCG_CODEGEN_DIR` is an escape-hatch environment variable for edge cases — e.g., when a launcher script is symlinked to a location that cannot resolve back to the repo root, or in CI environments where the repo is checked out at a non-standard path. Set it in your shell profile:

```bash
export OCG_CODEGEN_DIR=/path/to/codegen   # override only when BASH_SOURCE derivation is unavailable
```

`OCG_CODEGEN_DIR` is NOT the primary mechanism. `BASH_SOURCE` derivation is primary (used by `install.sh`, `uninstall.sh`, `update_ai_tools.sh`). For non-build launchers, `OCG_CODEGEN_DIR` is branch 1 of 3 in the `CODEGEN_DIR` derivation; if unset the launcher walks the `harnesses/` symlink (branch 2) or falls back to `$SCRIPT_DIR/../..` (branch 3). Build launchers (`claude-build.sh`, `pi-build.sh`) do not need it — they resolve the `codegen-build` sibling binary directly from `$SCRIPT_DIR`.

Cross-reference: `shared/rules/shared/shell-script-discipline.md` — "Derive Root, Never Hardcode" section.

---

## Trigger Keywords

deployment, server, prod, staging, dashboard box, Hetzner, CODEGEN_DIR, OCG_CODEGEN_DIR, hardcode, BASH_SOURCE, multi-location, install target vs source, codegen root, where does codegen run

---

## Update When Changing

Update this file when:

- A new server or machine is added to the codegen install roster
- The dashboard box path changes
- A new install target directory is added
- The `OCG_CODEGEN_DIR` override semantics change
