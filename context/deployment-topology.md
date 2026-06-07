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

See `install.sh`, `uninstall.sh`, `update_ai_tools.sh` — all use this idiom at line 1. Launcher scripts (`harnesses/claude/*.sh`, `harnesses/pi/*.sh`) use `${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}` because they are installed copies (symlinked to `~/bin/` or `/usr/local/bin/`) and are no longer physically adjacent to the repo root — they cannot derive the root from their own location.

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

`OCG_CODEGEN_DIR` is NOT the primary mechanism. `BASH_SOURCE` derivation is primary (used by `install.sh`, `uninstall.sh`, `update_ai_tools.sh`). Launchers fall back to it via `${OCG_CODEGEN_DIR:-$HOME/Areas/Optimum/codegen}` because they cannot self-derive from their installed location.

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
