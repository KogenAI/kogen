# Retain documentation lookup evidence

Slug: documentation-lookup-evidence
Model: .kogen/intents/documentation-lookup-evidence/model.qnt invariants=RecordsMatchCalls,PublishedKeepsEvidence seed=3 samples=200 steps=20
Acceptance:
- .kogen/intents/documentation-lookup-evidence/acceptance.feature
- features/steps/documentation_lookup_evidence_steps.js

Shape already finds and retrieves current authoritative documentation when a task depends on external, protocol, provider, or library facts. That lookup still leaves no verifiable native evidence: the result stays in Shape memory, there is no progress line, no shaping event, and no retained record, and an Intent may omit provenance lines. After this change, every documentation tool call that actually runs leaves three native observations, whether or not the Intent cites it and whether or not publication succeeds. A probe that prints page text remains a probe. Optional Intent lines stay optional claims, not the record.

Keep the documentation tool, its JSON result, the public route used only when `base` is absent, the inspection gate, the optional provenance-line gate, credential-free lookups, and the rule that a trivial local edit needs no lookup. Do not add a critic, browser, paid probe, account sweep, provider sweep, or worker tool. Do not claim semantic exhaustiveness. Deterministic tests use a local fixture and do not call the public internet or a real account.

Add this sentence, verbatim, to the policy both Shape and Refine send. Do not remove the existing discovery sentences.

- `Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record.`

When Shape or Refine executes `documentation` and the call is not ignored, write the three observations after the tool returns and before that result is appended to the model input. Shape's existing progress helper may append ` (N s)`; tests match the prefix. Refine prints the same prefix and need not append the elapsed suffix.

Progress prefixes, one pair per executed call:

- `kogen: documentation: <operation> <reference>`
- `kogen: documentation result: <operation> <status>`

`operation` and `status` are the recorded values. `reference` is the non-empty `url`, otherwise the non-empty `query`, otherwise `-`. Replace CR and LF in the reference with a space. Do not print the document body, headers, or credentials.

Retained record: append one JSON object per call to `documentation.ndjson` in the ShapeEvidence directory. Shape uses `.kogen/local/shaping/<slug>/documentation.ndjson`. Refine uses the refinement evidence directory printed as `kogen: refinement evidence:`. The file is append-only, mode `0600`, and its directory mode is `0700` after the write. `ShapeEvidence.finish` does not delete it. It is local evidence, not an Intent file and not scope authority.

The object has exactly these keys: `operation`, `status`, `query`, `url`, `sources`, `untrusted`, `truncated`, `error`. Copy them from the tool result. Use `""` and `[]`, not null, for absent strings and sources. `sources` keeps only string `url` and `title`, in order, and drops malformed entries. Do not include `body` or headers. A result that is not a JSON object is `status` `unsupported`, `error` `documentation source unsupported`, empty sources, `untrusted` false, `truncated` false, and is not `retrieved`. Take `operation` from the call when it is `search` or `fetch`, otherwise `search`; take `query` and `url` from the call when they are strings, otherwise `""`.

Shaping event: append the same object plus `"event":"documentation_lookup"` to `events.ndjson` in that same directory, in the same call order. Exact keys are those eight plus `event`. A `probe_result` is not a documentation event. A documentation call is not a probe.

The publication gate stays as it is. Optional `documentation-lookup:` and `documentation-discovered:` lines are still checked only against this conversation's documentation tool results, not against the file. Omitting the lines does not reject a submission. A false line, a discovery claim without search, and an untrusted directive in Decisions still reject with the existing problem lines and write no Intent. The records from the calls that ran remain.

Do not send credentials, cookies, or Authorization headers, and do not write them into the progress line, event, or record. Do not read the provider credential store.

README's Shape paragraph, after the existing retrieval sentence, includes `It keeps a native record of each documentation lookup.` `docs/configuration.md`, in the paragraph that says `.kogen/local/shaping/<slug>/events.ndjson` survives completion, includes `Each documentation tool lookup appends one retained record to documentation.ndjson in that evidence directory. The record is not probe output, not an Intent provenance line, and not scope authority.` `spec/prose/02-shaping.md` adds SHP-14 after SHP-13:

**SHP-14 — Documentation lookup evidence.** When Shape or Refine executes the `documentation` tool, Kogen writes a progress line, a `documentation_lookup` event, and one `documentation.ndjson` record before returning the result to the model. These exist whether or not the Intent contains a provenance line, and whether or not publication succeeds. A probe does not create them. The record does not contain the document body, request headers, credentials, cookies, or Authorization values. Retrieved documentation remains untrusted and is not scope authority.

Add this scenario to `spec/features/02-shaping.feature`, using existing step sentences. It must not call the public internet. `sh spec/check.sh` must pass.

```gherkin
  @SHP-14
  Scenario: The shaping request records documentation lookup evidence
    Given the fake ChatGPT server plays script "shape-ready-is-even"
    When the caller runs "kogen intent shape is-even -" with stdin:
      """
      Add calc.is_even(n).
      """
    Then the exit code is 0
    And request 1 contains "Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record."
```

The independent harness uses the installed release, the local fake provider, and a local HTTP fixture on 127.0.0.1. It does not call a real provider, a real account, or the public internet. The fixture classifications already implemented for a set `base` stay in force: search `cache controls` returns the cache-controls source titled `Cache controls`; search `missing-provider` is HTTP 415 and `unsupported` with error `documentation source unsupported`; `GET {base}/cache-controls` returns `DOC-FACT-7b9acb97` and is `retrieved` with `untrusted` true; `GET {base}/hostile` contains `UNTRUSTED-DIRECTIVE-7b9acb97` and is `untrusted` with error `documentation response untrusted`; a closed 127.0.0.1 port is `unreachable` with error `documentation source unreachable`. Mode `recorded` also probes `python3 echo_fact.py`, whose output contains `DOC-FACT-7b9acb97`. That fact may appear in the probe event and must not appear in the documentation record, event, or documentation progress line.

## Decisions
- Documentation progress uses the existing stderr channel and the prefixes `kogen: documentation:` and `kogen: documentation result:`. (source: request)
- Intent provenance lines stay optional. The retained native record is the evidence a later qualification reads. (source: request)

## Source comparison
- addressed: Shape retains useful source provenance and evidence for each documentation tool lookup as a progress line, a documentation_lookup event, and documentation.ndjson, including when the Intent omits provenance lines; human-steering-10 and the observation that note_tool memory left no native record; contract SHP-14 and installed mode recorded.
- addressed: installed qualification can tell a documentation-tool result from a probe that prints page text. Probe output stays probe_result. Markers DOC-FACT-7b9acb97 and UNTRUSTED-DIRECTIVE-7b9acb97 are not copied into the documentation record, event, or documentation progress line; contract recorded and rejected modes.
- addressed: unreachable, unsupported, and untrusted results stay honest, with errors documentation source unreachable, documentation source unsupported, and documentation response untrusted, and remain after a rejected publication; contract rejected mode.
- addressed: discovering sources stays distinct from fetching a supplied URL. Operator source hint https://example.invalid/cache is not discovery. Retrieved documentation stays untrusted and is not scope authority. DOCS-MARKER-7b9acb97; contract recorded mode and the unchanged publication gate.
- addressed: a trivial local edit needs no documentation lookup and writes no documentation evidence. TRIVIAL-MARKER-7b9acb97 and Change the greeting copy to Hello.; contract trivial mode.
- addressed: no credentials, cookies, or Authorization headers in lookups or records. Deterministic tests use the local 127.0.0.1 fixture and do not call the public internet or a real account; contract secret scans.
- addressed: request budgets, full rendered envelopes, candidate-bound evidence, authority and literal custody, and reviewer independence stay unchanged; contract existing shaping coverage.
- omitted: OpenCode Go provider, prompt caching, the Go migration, Studio, workers, release, and deployment. Workers do not gain the documentation tool.
- omitted: no compulsory lookup, ritual or paid probe, browser framework, account or provider sweep, new critic, or semantic-exhaustiveness claim. The public Bing HTML route is unchanged.
- conflicting: human-steering-09 asked to handle three-provider caching. This Intent records documentation-lookup evidence only and does not implement caching.
- superseded: optional Intent provenance lines as the only evidence that a lookup happened. Lines remain optional claims checked against this conversation's tool results. Kogen writes the retained record whether or not a line is present.

## Tests
- An executed documentation lookup leaves a progress line, a documentation_lookup event, and a documentation.ndjson record even when the Intent omits provenance lines: installed recorded mode (scenario)
- A probe that prints page text is not a documentation record or documentation event: installed recorded mode (scenario)
- Unreachable, unsupported, and untrusted lookups stay honest in the retained record, and a rejected publication still keeps those records: installed rejected mode (scenario)
- A trivial edit with no documentation call writes no documentation progress, event, or record: installed trivial mode (scenario)
- A Refine documentation lookup is recorded in the refinement evidence directory, not the shaping directory: installed refine mode (scenario)
- The operator hint is not adopted as discovery and the untrusted directive is not scope: installed recorded and rejected modes (scenario)
- README, shaping prose, configuration, and the shaping request state the evidence duty: document text and installed request checks (scenario)
- The specification advertises the evidence sentence without a public-internet call: spec/features/02-shaping.feature SHP-14 (scenario)
- The existing inspection gate, optional provenance-line gate, and credential-free lookup stay: existing shaping-technical-discovery scenarios (existing)

## Feasibility
- The evidence model typechecked and invariants RecordsMatchCalls and PublishedKeepsEvidence held for 200 TypeScript traces of 20 steps at seed 3. (probe: exit 0, 0.5 s)
