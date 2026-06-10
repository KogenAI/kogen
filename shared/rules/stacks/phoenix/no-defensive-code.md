# No Defensive Code

**Discriminating test**: does the branch (a) enumerate a boundary-enumerated value, or (b) preserve the error with `reraise`/tagged tuple? If yes → allowed. Anything that swallows, silences, or substitutes a fallback for an unexpected condition → forbidden.

## Forbidden

- **Silent fallback on unexpected input** — `_ -> nil` or `_ -> []` in a `case` over an internal enum. Hides the bug; caller receives a valid-looking value and proceeds. Use `_ -> raise "unexpected #{inspect(v)}"` or remove the arm.
- **`rescue Exception`/`rescue _`** without `reraise` — swallows all errors including bugs. Only legitimate shape is `rescue e in File.Error -> reraise e, __STACKTRACE__` or equivalent that preserves the original error (see carve-out 2).
- **`|| default` on a function that should never return nil** — e.g., `get_user!(id) || %User{}`. Bang fns raise on not-found; `||` masks the raise and produces a ghost struct.
- **`try/rescue` around pure business logic** — if the code inside cannot legitimately raise in normal operation, the rescue arm is dead code that hides future regressions.
- **Catch-all `handle_info` arms that silently `:noreply`** — in application modules (not OTP libraries). Log + drop is better; see carve-out 1 for the OTP exception.
- **Defensive swallows on internal error paths** — returning `nil`, `[]`, or `""` instead of propagating `{:error, reason}`. Allowed: `{:ok, val} -> {:ok, val}; {:error, reason} -> {:error, reason}` — preserving the tagged tuple is correct; substituting a fallback is not.

## Allowed Carve-Outs

1. **OTP `handle_info` catch-all in GenServer** — OTP delivers system messages (`{:EXIT, ...}`, `{:nodedown, ...}`) unpredictably. A catch-all that logs and noreply is legitimate. Use `Logger.warning/2` (not `Logger.debug`) for unexpected messages; bare `:noreply` is still forbidden.
2. **`File.Error` rescue + reraise** — I/O genuinely fails at runtime. Catch only `File.Error` (or the specific exception), re-raise with original stacktrace. See `_core.md` TOCTOU retry pattern for the one shape where a single retry before reraise is acceptable.
3. **`Phoenix.Token.verify/4` always returns tagged tuple** — `Phoenix.Token.verify/4` never raises on invalid token/salt/signature; all error cases return `{:error, reason}`. Wrapping it in `try/rescue` is defensive code and forbidden. Use bare `case` on the return value: `case Phoenix.Token.verify(key, token, salt) do {:ok, value} -> ...; {:error, _reason} -> ... end`.
4. **Boundary validation on external input** — params from HTTP requests, webhooks, or user-supplied data MAY be validated with a fallback (`||`, `Map.get/3` with default, changeset error). The boundary is the controller or plug layer; inside contexts and schemas, treat data as already validated.

## Coverage Corollary

Uncovered branch → ask: "does this arm swallow an unexpected condition?" If yes, delete it — don't add a `coveralls-ignore`. Coverage gaps on defensive fallbacks are the symptom; the fix is removal. When a branch is genuinely unreachable-in-test (TOCTOU rescue, Erlang coverage artifact, OTP system message arm), apply `# coveralls-ignore-start/stop` per the "Coveralls Ignores in case Arms" section in `testing.md`. Do not apply coverage pragmas to arms that could be deleted.

_If you're adding a branch "just in case," it's defensive — delete it._
