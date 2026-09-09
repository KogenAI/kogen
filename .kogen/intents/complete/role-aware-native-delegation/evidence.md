# Complete evidence: Route native delegation by role

- Candidate id: `85114c810a4872cc1868420fefa0dc7fae201e13`
- Developer session id: `01a08642-8657-7ff1-887a-d3808890871d`
- Reviewer session id: `01a0864c-eb54-77c2-a1b2-2f5e09ad2275`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-09T13:13:00Z`
- session_id: `01a08642-8657-7ff1-887a-d3808890871d`
- output tail:
  ```
  mix format --check-formatted
mix compile --warnings-as-errors --force
Compiling 8 files (.ex)
Generated kogen app
mix credo --strict
Checking 31 source files ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.09 seconds (0.01s to load, 0.08s running 69 checks on 31 files)
251 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Running ExUnit with seed: 697427, max_cases: 24
Excluding tags: [:live]

...............................................................................................
Finished in 65.4 seconds (0.1s async, 65.3s sync)

Result: 95 passed, 3 excluded
  ```

## Declared targets

(none beyond `check`)

## Reviewer Verdict (structured, schema-valid)

```json
{"findings":[],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)
