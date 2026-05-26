# Tidewave MCP Verification

**Problem**: Adding non-existent config options, function calls, or module usage causes runtime errors or silent misconfiguration.
**When**: Using any library function, config key, or module you haven't used before in this codebase — or when the behavior is unclear from types alone.
**See also**: none

## Solution

Run this 3-step sequence before writing the code:

1. `mcp__tidewave__get_docs` — read the module or function docs
2. `mcp__tidewave__search_package_docs` — search for usage examples in the package docs
3. `mcp__tidewave__project_eval` — verify the call works in the live running project

**When to use**: unknown library behaviour, new config option, unfamiliar module, any function whose signature you'd otherwise guess.

**When to skip**: well-known Phoenix/Ecto/Elixir stdlib patterns you have used in this codebase before (e.g., `Ecto.Changeset.cast/4`, `Phoenix.LiveView.assign/3`).

## Gotchas

- `project_eval` requires the dev server to be running — it evaluates code in the live BEAM node.
- If `get_docs` returns nothing, try `search_package_docs` with the module name as the query before concluding the function doesn't exist.
- Never skip verification just because a function name looks plausible — Elixir library APIs change between minor versions and config keys are not validated at compile time.
