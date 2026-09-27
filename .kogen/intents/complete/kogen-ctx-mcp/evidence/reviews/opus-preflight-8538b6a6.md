**Verdict: ready**

I found no blocking issues. I checked every file in the draft, including `evidence/`, against develop 8538b6a6 using only reads. I didn't build anything or run any tests myself; the "all pass" claims rest on the draft's own probe outputs, checked against the landed code and tests.

**What I checked, all confirmed:**
- **Citations match the landed code.** In `native/kogen-ctx/src/main.rs`: `USAGE` is at :13, `usage()` at :14-17, `parse()` at :368-453 (command match :373-378, `--limit` rejection :404-405, positional rejection :441-443), `main()` at :454-701 (`home()` :459, `root()` :463, `refresh()` :467). The query dispatches are at :471/:491/:512/:568/:655, the unmatched `--focus` exit at :593, `we()` at :182-188, `init`/busy timeout at :175-177, schema checks at :214/:229, and `BEGIN IMMEDIATE`/`COMMIT` at :225/:360. The pinned usage lines are at `ctx_elixir_test.exs:18` and `ctx_map_test.exs:176`. E4 really has 20 command lines and H4 has 4. A5 (`ctx_index_test.exs:173,201`) and C8 (`ctx_search_test.exs:108`) check only the `usage: kogen-ctx` prefix, and none of their cases uses `mcp`. The Candidate diff lines 1483/1489/1575 hold `mcp_reply`/`run_mcp`/`run_capture`, and `drafts/kogen-ctx-tool/` exists. `CtxFixture.run/5`, `index_path/2` and `binary/0` match `test/support/ctx_fixture.ex:166-282`, and `Kogen.ProjectScope.canonical/1` is public, as A5 already uses it.
- **Expected outputs are right.** Every CLI output in T1 and T2 (`evidence/probe/landed-cli-outputs.txt`) equals the landed pins line for line:
  - `search the` = C1, `search "Mix lock"` = C4, `search stray --limit 2` = C3.
  - `symbols Shop.Cart.total` and `symbols Shop --limit 1` = E2.
  - `refs Shop.Tax.add` and `refs Shop.Cart --limit 2` = E3.
  - `map --tokens 25` = H2, and `map --focus test/shop_test.exs` = H3 (7 blocks, 32 lines).
  - `map --tokens 64 --focus lib/shop/` gives the tax and cart blocks, then `... 5 more files`. The draft's budget arithmetic (80 + 135 = 215 bytes; adding format's 69 → 71 tokens > 64) is correct.
  - T3's runtime error follows A6's `index_path(ro, root)` prefix pattern (`ctx_index_test.exs:225-230`).
  - M1's reply ids, the error codes (-32602/-32601/-32700/-32600), the protocol-version echo and fallback, and id 11's `isError: true` with `USAGE + "\n"` all hold against the probe server (`mcp.rs`).
- **MCP replies equal the landed CLI outputs.** T1 and T2 first pin the CLI output to the landed values, then require the MCP `text` to equal it exactly with `isError: false`. So the parity check can't pass by comparing two empty strings. The one empty output ("Shop Cart") is asserted explicitly.
- **Streaming stdin is tested through a Port.** M3 uses `Port.open` with `{:line, …}` and waits for each reply before writing the next request. `mcp-eof-probe-output.txt` shows M3 failing against a read-all-stdin variant while M1 and M2 pass. M4 goes through `CtxFixture.run/5`, whose stdin stays open, so it also proves the server exits before reading stdin.
- **Landed tests:** only E4's `usage!/3` and H4 change, and both files are guarded. Every other landed ctx test, `readme_guidance_test.exs` and `ctx_fixture.ex` stays unedited, and nothing in them depends on the change.
- **affected_paths ⊆ guards:** both scenarios' `affected_paths` fall inside `may_change_guarded_paths`. `README.md` is guarded but not in any `affected_paths`, which the subset rule allows.
- **Build constraints hold:** no change to `Cargo.toml` or `Cargo.lock` (D4's SHA `2ef6860e…` stays), `CARGO_STAGES` matches `scripts/check/offline.py:37-40`, and `serde_json` is already a declared dependency.

**Notes (non-blocking):**
1. **F3 isn't mentioned in INTENT.md.** `ctx_elixir_test.exs:269-291` fails on any `.rs` file under `src/` containing `"Shop`, `"Tax"`, `"Format"` and similar. A Developer who adds Rust unit tests to `mcp.rs` with `json!({"query":"Shop.Cart.total"})` breaks F3. INTENT lists F3 as must-pass, so `make check` would catch it, but one sentence in "Starting point" would save a loop.
2. **The probe script asserts less than the evidence says.** `mcp_probe.exs` only prints the outside-checkout M4 result (`:125-126`), checks just the T3 error prefix (`:110`), and in T1/T2 checks CLI↔MCP parity but not the pinned lines. The captured outputs show the full assertions would pass, but "implements M1…T3 as specified" (`probe-preflight-8538b6a6.md:24`) overstates it.
3. **Some Outcome clauses have no test:** an object with an `id` but no string `method` → -32600 with that id, blank lines ignored, and `mcp` with HOME and KOGEN_CTX_HOME unset → exit 1. The probe server handles all three.
4. **Small nits:**
   - The probe patch's `pub(crate) const USAGE` is unneeded, since `mcp.rs` never uses it. It's harmless.
   - "stdout split on `\n`, trimmed" (`INTENT.md:146`) should say `trim: true`.
   - T2's "H2's --tokens 64 lines" is a different command line from the one being run. The lines are identical and spelled out, so it's fine.

I couldn't write the plan file or call ExitPlanMode because neither tool is available in this session, so this reply is the whole review. Separately, the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before its tools work. It wasn't needed here.
