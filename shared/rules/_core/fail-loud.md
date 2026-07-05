# Fail Loud — Universal

Codegen values failing loud. Language-agnostic across Elixir, TS/JS, Bash, Python. Stack-specific deep-dives: the masking-default fail-fast test (defaults) and the Elixir no-defensive-code discipline (swallows) extend this.

## Forbidden

- **NEVER swallow** — `catch {}` / `except: pass` / `rescue _` / `2>/dev/null || true` that drops an error you did not enumerate. An unexpected condition MUST surface (raise, return error, non-zero exit), never vanish.
- **NEVER silent-default a required input** — a value the op needs to be CORRECT (model, credential, mode/env switch, routing key, target id) MUST fail when absent, never fall back to `""` / `nil` / `0` / `"unknown"` / a plausible-but-wrong constant.
- **NEVER fail open by default** — when an operation cannot determine the safe answer, the default is to STOP/deny/error, not proceed permissively. (Carve-out below for hook fail-open.)
- **NEVER green-on-red** — a check/gate/test reporting success while the underlying thing failed. Exit code, verdict, and log MUST agree. No `|| true` on a command whose failure is the signal.
- **NEVER catch wider than expected** — catch the specific error you handle; let everything else propagate. Bare/`Exception`/`*` catches that include bugs are forbidden.
- **NEVER mislabel a failure** — do not print `ALL CLEAR ✅` / `passed` for a FAILED result. Label MUST match actual outcome.
- **NEVER demote required → optional without a consumer** — do not make a required field optional/nullable just to silence an error; relax only when a real caller legitimately omits it.

## Allowed Carve-Outs

- **Sourced hook helpers** — bash helpers sourced into a `set -e` launcher use `set -uo pipefail` (no `-e`) and end fail-open steps with `|| true`. INTENTIONAL fail-open: a hook failing open lets the agent proceed rather than wedging the session. The only deliberate non-zero is a final `return 1` on a genuine not-found error.
- **Observe-only Stop twins** — a Stop-event hook that only observes/records (never blocks) may swallow its own errors so it cannot wedge Stop.
- **Fail-loud-non-blocking on optional observability** — when a feature is entirely optional (can be disabled by omitting an env var or flag) and its FAILURE is observable-only (not correctness-required), emit loud stderr but do NOT change exit code — preserves the outer operation's exit code while surfacing the problem. Example: optional transcript capture fails → print error to stderr, still exit 0 so the build succeeds. The entire feature can be disabled (no observability needed), making the failure non-critical rather than masked.
- **Boundary validation on external input** — HTTP params, webhooks, user-supplied data MAY apply a fallback/default at the boundary layer. Inside core logic, treat data as already validated.
- **Genuinely-optional knobs** — timeouts, backoffs, pool sizes, feature flags, display formats: the default IS the intended value, not a mask.

## Discriminating Test

"If this branch/default/catch fires in prod, does the system do the WRONG thing silently — or surface the problem?" Silent-wrong → forbidden. Surfaces → allowed.
