# Result Reporting (MANDATORY)

For user-app build runtime sessions (interactive fallback) and any role invocation whose final message reports build status.

Final message MUST contain exactly one fenced JSON block + NOTHING after:

```json
{ "status": "success" }
```

or

```json
{ "status": "failed", "reason": "<short reason>" }
```

## Rules

- ` ```json ` fenced block (lowercase `json`)
- Block last in final message — no prose/hashes/farewells after closing ` ``` `
- `status` exactly `"success"` or `"failed"`
- Failure: `reason` single sentence (<200 chars)
- At most ONE block. Second one → recorded failed.
- ❌ Emit before the deterministic commit step reports done.

`{"status":"success"}` requires ALL: (1) session log + all subagent sections; (2) CI passed (`ALL CLEAR ✅`); (3) quality approved (Phoenix only); (4) git commit made.
