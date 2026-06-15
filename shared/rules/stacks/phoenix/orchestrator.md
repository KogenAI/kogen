# Orchestrator — Phoenix Stack

## Sanctioned Gate Commands

- `make ci` — full. All steps.
- `make predeploy` — pre-deploy. NEVER per-commit gate.
- `make llm`, `make llm-phoenix` — pre-deploy components. Not direct gates.

## Extension → Agent

| Extension                      | Agent                      |
| ------------------------------ | -------------------------- |
| `.ex`/`.exs` (lib/<app>/)      | developer-phoenix-backend  |
| `.ex`/`.exs` (lib/<app>\_web/) | developer-phoenix-frontend |
| `.heex`                        | developer-phoenix-frontend |
| `.js` (assets/js/)             | developer-phoenix-frontend |
| `*_test.exs` (backend)         | developer-phoenix-backend  |
| `*_test.exs` (web/live)        | developer-phoenix-frontend |
| `priv/repo/migrations/`        | developer-phoenix-backend  |

## Routing per Slice

Read `## Slices` from plan. Per slice in order:

- `backend` → `developer-phoenix-backend` (incl. data layer)
- `frontend` → `developer-phoenix-frontend`

Backend before frontend.

## INCONCLUSIVE (Phoenix-specific)

| Classification    | Action                                                              |
| ----------------- | ------------------------------------------------------------------- |
| `pool-exhaustion` | Ask user to free DB or wait 60s; re-delegate dev (cap 1 retry).     |
| `seed-missing`    | Run `CODEGEN_VE_GATE=rebuild-seed-then make llm-phoenix`; re-deleg. |
| `partial-gate`    | Re-delegate dev with missing command as gate. No commit on partial. |

## LLM Test Failures

All gate failures fixed. No "pre-existing" exemption.

## Coverage Gap

`make ci` fails on coverage → log contains report. Delegate dev (only) to read `cover/excoveralls.json` and add minimal tests; re-spawn re-fires gate.

❌ Add `--cover`/`coveralls` to PD prompts. ❌ Orchestrator reads `cover/excoveralls.json`.

## Server Restart

Hot reload: `.ex`, `.heex`, JS/CSS, migrations, tests. Restart: `config/*.exs`, Oban workers, GenServer/Supervisor, `mix deps.get`.
