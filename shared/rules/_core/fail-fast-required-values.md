# Fail-Fast on Required Values — No Masking Defaults

A default is MASKING (remove → fail fast) when ALL three hold:

1. **Required, not optional** — backs a value the op needs to be CORRECT (model, credential/secret, env/mode switch, routing/intent key, target/bucket id). NOT a timeout/backoff/flag/pool-size/display knob.
2. **Sentinel papers over absence** — fallback is `""`, `nil`, `"unknown"`, `0`, a hardcoded plausible-but-wrong value, or a DIFFERENT-ENVIRONMENT value (e.g. `"sandbox"`).
3. **Proceeds wrong** — missing real value → code keeps going, yields silently-wrong/insecure/financially-wrong output instead of an obvious crash.

**LEGITIMATE (keep)**: default IS the intended prod value (timeouts, backoffs, flags, pool sizes); genuinely-optional param; test-injection seam (`fun` defaults); display/format knob.

## Grep Tells

- `Keyword.get(opts, KEY, DEFAULT)` / `Map.get(args, KEY, DEFAULT)` for a required param
- `Application.get_env(_, KEY, DEFAULT)` / `System.get_env(KEY, DEFAULT)` where DEFAULT is a secret/mode/host/price sentinel
- `expr || SENTINEL` where nil means failure
- `_ -> SENTINEL` / `rescue _ -> SENTINEL` swallowing required data

## Judgment Test (the non-grep part)

"If this default fires in prod, does the system do the WRONG thing silently, or the RIGHT thing?"
Wrong → masking. Right → keep. Grep finds candidates; this question decides.

## Fix Mechanisms

1. **Per-call required opt** → `Keyword.fetch!` / `Map.fetch!` at the passing boundary (outside any blanket rescue).
2. **Required prod config** → `config/runtime.exs` `required_env` / feature partial-raise; read via `Application.fetch_env!`, never a read-site sentinel.
3. **External-envelope required field** → `Map.fetch!` / pattern-match-and-fail.

---

**developer**: MUST NOT write a masking default.
**reviewer**: MUST flag masking defaults using the 3-part test above. See also `stacks/phoenix/no-defensive-code.md` for the related error-swallowing rule (distinct concept — defaults vs swallows).
