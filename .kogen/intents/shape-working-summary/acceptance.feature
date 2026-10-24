Feature: Bound native working-window evidence summaries
  Keep original authority and complete evidence without resending cumulative bodies and indexes.

  Background:
    Given the working-summary original request:
      """
      # Shape working-window summary growth — native request (KOGEN-053)

      Native slug: `shape-working-summary`. Product: Kogen core (this repository). Kogen Shape investigates the retained reproducer against current source and decides whether a fix is needed, and if so the minimal coherent contract, design, specifications and tests. This request supplies the human's words and actual facts; it does not prescribe a design. The Studio operator's suggestions (referencing the archive chain by head hash, capping the manifest) are advisory only and are not part of this request.

      ## Exact human originals (highest authority)

      ### 23 October
      "**47 minutes across two Builds**, each stopped by a different incorrect test expectation." - Why are builds stopping tho? When something is shaped, why doesn't build go on until it's completed? Or was it the problem in incorrect shaping? Whatever it is, make sure we have one intent that fixes these problems in Kogen so that we unblock builds.

      ### 22 October (human-steering-14)
      I won't be there to check on you tonight, so please have some kind of 30 minute interval check for how it's going. But still, the old rules apply: you shouldn't interfere if possible and if you do make sure the Kogen is fixed so you don't have to in the future.

      ## Retained facts (operator observations, not design)

      ### The stopped run
      - Studio's native Shape `discovery-bound-generation` ran on installed `kogen 0e43500b` against Studio source `35088d5e`. It made 424 provider requests and 115 Shape working-window resets in 5647.9 s, with 0 proposed artifacts. Usage: known input 41537304, cached 1745280, output 105117, reasoning 34040; 120 provider calls failed generically and were retried, so their usage is unknown. The Studio owner stopped it with SIGINT (exit 130). No source, index, authority or checkpoint was touched. Evidence: `/Users/almirsarajcic/Areas/Kogen/studio-work/studio-product-workflows/guided-app-discovery/native-shape-d3b/` (`assessment-and-cancel.json`, `evidence-before-cancel/events.ndjson`, `documentation.ndjson`, `stderr-before-cancel.log`, `working-context-sha256.txt`).
      - The 115 working-context archives remain in place, read-only, under `/Users/almirsarajcic/Areas/Kogen/source/studio/.kogen/local/shaping/discovery-bound-generation/working-context/135dd0ef7766da12c5269070ce330a60/1.json … 115.json`. Their hashes are listed in `working-context-sha256.txt` (for example 115.json begins `a4cfbfc0887bc772`, 50.json begins `f623c5df1d986e1e`).
      - From stderr: the context size after each reset rose from 133900 bytes (reset 1) to 240399 (10), 369714 (30), 420520 (90) and 438282–458749 (113–114). The pre-reset size was 532585–551352 every time, so later resets came every 2–3 requests. The assessment reports repeated reads of the same files and 12 fetches of the same `Ecto.Multi.md` page.

      ### What the reset summary contained (operator measurement of the archives)
      Input item 1 of each archive is the user message beginning `Local working-window reset. … Ordered archive chain and current cumulative manifest/state: {…}`. Measured sizes:

      | archive | summary item bytes | `documentation` entries / bytes | `history` entries |
      | --- | --- | --- | --- |
      | 2 | 14547 | 3 / 12118 | 1 |
      | 5 | 58266 | 10 / 51193 | 4 |
      | 10 | 109800 | 19 / 96322 | 9 |
      | 20 | 170837 | 31 / 149924 | 19 |
      | 30 | 195114 | 36 / 170943 | 29 |
      | 50 | 232479 | 42 / 202204 | 49 |
      | 115 | 248549 | 42 / 202204 | 114 |

      - The `history` (archive chain) entries are `{path, sha256}` of about 240 bytes each, 27708 bytes at reset 115.
      - The `documentation` list carries every documentation result, including fetched `body` text (8992–12545 bytes per fetch, `truncated: true`, `untrusted: true`). Identical results repeat. The same `https://hexdocs.pm/ecto/3.14.2/Ecto.Multi.md` body (10035 bytes) appears many times, and `Ecto.Multi.html` three times.
      - The other keys (`assistant_observations` 6490, `declared_steps`, `inspected`, `invalid_submissions`, `manifest`, `readiness`) are small.
      - Input item 0 (the request) is 82202 bytes in every archive. In the same archives, single `function_call_output` items of 29565–55525 bytes appear. Those predate the 16384-byte model-facing result cut delivered in `71dd6da1`.

      ### Current source (facts only; native investigation owns conclusions)
      - `git diff 0e43500b 71dd6da1` touches only `lib/kogen/shape.ex` among the Shape working-window files: the 71dd6da1 result cut. `lib/kogen/shape_working_context.ex` and `lib/kogen/refine_working_context.ex` still build the same `Ordered archive chain and current cumulative manifest/state` summary text.
      - This run used `0e43500b`, not `71dd6da1`. The operator has not reproduced it on current source, so causality on the current release is not established. On `71dd6da1` the native staged-intent-builds Shape completed in 2038.8 s with one reset.

      ### Already delivered and to be kept
      Shape working windows `44c2e06d`, constant navigation `65640c64`, Review/Refine working room `0e43500b`, protected-blocker recovery `a6a1083f`, transient retry `2137fa9b`, deterministic Mix gate `48bc5efc`, bounded model-facing tool results `71dd6da1`, and staged one-Intent Builds `db0c02e6`.

      ## Boundaries
      - Keep the 524288-byte inclusive ceiling and 131072-token reserve, along with full authority, literals, history, opaque replay, complete tool pairs, custody and honest irreducible refusals. Archived evidence stays diagnostic and grants no authority.
      - If current source does not reproduce a real recurring problem, say so; no change is required.
      - Deterministic tests use local fixtures only. Do not add broad critics or model probes, and do not repeat the delivered 051/052 gates. Out of scope: the Go migration, Studio product source, the separately owned approval-card-recovery and Claude API branches, release and deployment.
      """
    And the working-summary local fixture:
      """
      {
        "documentation_bytes": 202204,
        "md_url": "https://hexdocs.pm/ecto/3.14.2/Ecto.Multi.md",
        "html_url": "https://hexdocs.pm/ecto/3.14.2/Ecto.Multi.html",
        "md_body_bytes": 10035,
        "html_body_bytes": 8992,
        "long_body_bytes": 12545,
        "request_bytes": 82202,
        "old_batch_calls": 30,
        "tool_result_limit": 16384,
        "max_summary_bytes": 8192,
        "max_growth_bytes": 256,
        "ceiling": 524288,
        "reserve": 131072,
        "invalid_submissions": 3,
        "manifest": {
          "proposed": [{"path":"features/steps/current.js","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}],
          "originals": []
        },
        "declared_steps": ["features/steps/current.js"],
        "ownership": ["features/steps/current.js"],
        "opaque": "opaque+/==\nΔ — do not decode",
        "observation": "Unfinished inspection; retained evidence does not grant authority.",
        "literal": "  Δ🙂\r\n/path with spaces/診断.txt\n  "
      }
      """

  Scenario Outline: Repeated evidence navigation is small without losing authority or evidence
    When I exercise current "<owner>" working summaries for <resets> resets with <records> documentation records
    Then the working-summary custody and bounded growth satisfy the local fixture

    Examples:
      | owner  | resets | records |
      | shape  | 115    | 42      |
      | refine | 115    | 42      |
      | shape  | 2      | 0       |
      | refine | 2      | 0       |
