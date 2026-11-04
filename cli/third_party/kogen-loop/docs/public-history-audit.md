# Public history audit

Audited HEAD: `f1cdbfee76cbd6e1776450adb99558e348aaaa59`. This inventory is delivered to the owner for a separate decision; history was not rewritten.

## Method and limitations

Read-only `git rev-list --all` enumerated locally reachable commits; `git grep -I -i -E` searched each commit snapshot for user and runner paths and identities, private setup and mirror indicators, and local delivery or unavailable workspace indicators. Each row is a distinct commit, repository-relative file and category; snapshots may repeat an unchanged finding. Categories are indicators, not a claim that each occurrence is secret. Literal values are intentionally omitted. Binary content, commit metadata, deleted content not present in reachable snapshots, unadvertised or inaccessible refs, and remote-only history were not examined. Only locally available refs were audited; inaccessible remote refs cannot be enumerated from this clone.

| Commit | File | Category |
| --- | --- | --- |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `README.md` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `README.md` | private setup or mirror |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `docs/provenance/extraction.md` | personal or machine identity |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `02e797252ffd1cdc29d50d58615d1ab64c601cd8` | `features/steps/standalone_loop.js` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `CHANGELOG.md` | private setup or mirror |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `README.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `README.md` | private setup or mirror |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `contract/README.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `docs/provenance/extraction.md` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `features/steps/standalone_loop.js` | personal or machine identity |
| `05a4ccb8e5b86bfec82e8c1c018146c2d0172ea5` | `tools/read_contain_test.go` | personal or machine identity |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `0665b58672de4c43522e7e33fd426339c129618c` | `README.md` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `README.md` | private setup or mirror |
| `0665b58672de4c43522e7e33fd426339c129618c` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `docs/provenance/extraction.md` | personal or machine identity |
| `0665b58672de4c43522e7e33fd426339c129618c` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `0665b58672de4c43522e7e33fd426339c129618c` | `features/steps/standalone_loop.js` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `README.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `README.md` | private setup or mirror |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `docs/provenance/extraction.md` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `features/steps/standalone_loop.js` | personal or machine identity |
| `07f21da9919415e1d688adcbb734f6eee1f79859` | `tools/read_contain_test.go` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `CHANGELOG.md` | private setup or mirror |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `README.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `README.md` | private setup or mirror |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `contract/README.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `docs/provenance/extraction.md` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `features/steps/standalone_loop.js` | personal or machine identity |
| `0c49f870c9c948541f3bfd470023959b4ed93b78` | `tools/read_contain_test.go` | personal or machine identity |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `README.md` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `README.md` | private setup or mirror |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `docs/provenance/extraction.md` | personal or machine identity |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `102a72f7b266218ebcd8975a17541efa1e2ff8c6` | `features/steps/standalone_loop.js` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `CHANGELOG.md` | private setup or mirror |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `README.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `README.md` | private setup or mirror |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `docs/provenance/extraction.md` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `features/steps/standalone_loop.js` | personal or machine identity |
| `166ec7f3748f5155d999487753cbec8ff5a0135a` | `tools/read_contain_test.go` | personal or machine identity |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `README.md` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `README.md` | private setup or mirror |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `docs/provenance/extraction.md` | personal or machine identity |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `16f350797b997e0dcde06a5ca3f602ea9a64830d` | `features/steps/standalone_loop.js` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `README.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `README.md` | private setup or mirror |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `docs/provenance/extraction.md` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `features/steps/standalone_loop.js` | personal or machine identity |
| `16f89745ca6a93101b89ab8af7d20c3a85f65b69` | `tools/read_contain_test.go` | personal or machine identity |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `1857100e0d925508372037915ce12374d8ce77f0` | `README.md` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `README.md` | private setup or mirror |
| `1857100e0d925508372037915ce12374d8ce77f0` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `docs/provenance/extraction.md` | personal or machine identity |
| `1857100e0d925508372037915ce12374d8ce77f0` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `1857100e0d925508372037915ce12374d8ce77f0` | `features/steps/standalone_loop.js` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `CHANGELOG.md` | private setup or mirror |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `README.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `README.md` | private setup or mirror |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `docs/provenance/extraction.md` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `features/steps/standalone_loop.js` | personal or machine identity |
| `1a3eb18f2675d3cbb6f3220ea4cfc7cd9e9f49aa` | `tools/read_contain_test.go` | personal or machine identity |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `README.md` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `README.md` | private setup or mirror |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `docs/provenance/extraction.md` | personal or machine identity |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `1b8ef1fd9e702977b0ce6c4f2e02329a80c3dd64` | `features/steps/standalone_loop.js` | personal or machine identity |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `README.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `README.md` | private setup or mirror |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `docs/provenance/extraction.md` | personal or machine identity |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `2136ebb58a69bdd6280e9f3968efd28cb2c2f6b8` | `features/steps/standalone_loop.js` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `CHANGELOG.md` | private setup or mirror |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `README.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `README.md` | private setup or mirror |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `docs/provenance/extraction.md` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `features/steps/standalone_loop.js` | personal or machine identity |
| `262e88d05f4dc3478f8be84d84d71eae86bf759b` | `tools/read_contain_test.go` | personal or machine identity |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `README.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `README.md` | private setup or mirror |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `docs/provenance/extraction.md` | personal or machine identity |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `2dd4c9b1ec2848ab0447295b5f1dbb5749f4b648` | `features/steps/standalone_loop.js` | personal or machine identity |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `README.md` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `README.md` | private setup or mirror |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `docs/provenance/extraction.md` | personal or machine identity |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `2ea31bf5438f0bdde537848f678a7331c5fe2a2a` | `features/steps/standalone_loop.js` | personal or machine identity |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `README.md` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `README.md` | private setup or mirror |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `docs/provenance/extraction.md` | personal or machine identity |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `2ed6c54d765858cf9147299fb62fd58624ee1714` | `features/steps/standalone_loop.js` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `CHANGELOG.md` | private setup or mirror |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `README.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `README.md` | private setup or mirror |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `docs/provenance/extraction.md` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `features/steps/standalone_loop.js` | personal or machine identity |
| `2fc1eb7fb1992307be0ff72fd7004d9ea5f45847` | `tools/read_contain_test.go` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `CHANGELOG.md` | private setup or mirror |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `README.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `README.md` | private setup or mirror |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `contract/README.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `docs/provenance/extraction.md` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `features/steps/standalone_loop.js` | personal or machine identity |
| `3372dcfd45bf28deeb8379618a094a032f4930d8` | `tools/read_contain_test.go` | personal or machine identity |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `README.md` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `README.md` | private setup or mirror |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `docs/provenance/extraction.md` | personal or machine identity |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `33e7f4ec8ba899fc4aa621127379e5cb26b77648` | `features/steps/standalone_loop.js` | personal or machine identity |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `README.md` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `README.md` | private setup or mirror |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `docs/provenance/extraction.md` | personal or machine identity |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `3572eaf88fa28b4a8557c0a5692d9e04d8ff135e` | `features/steps/standalone_loop.js` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `README.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `README.md` | private setup or mirror |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `docs/provenance/extraction.md` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `features/steps/standalone_loop.js` | personal or machine identity |
| `38e08ea37eaa566bd1491129532c3a1cb64b5551` | `tools/read_contain_test.go` | personal or machine identity |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `README.md` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `README.md` | private setup or mirror |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `docs/provenance/extraction.md` | personal or machine identity |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `3fd044335f8b03904873a389d9248ebb92ddd44c` | `features/steps/standalone_loop.js` | personal or machine identity |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `README.md` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `README.md` | private setup or mirror |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `docs/provenance/extraction.md` | personal or machine identity |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `48840cb0bb2a7e8ab3f9ae80f1d1ee98ad2092dc` | `features/steps/standalone_loop.js` | personal or machine identity |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `README.md` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `README.md` | private setup or mirror |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `docs/provenance/extraction.md` | personal or machine identity |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `4afed06da64e348a5a65db6e550f81b65cbe0235` | `features/steps/standalone_loop.js` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `CHANGELOG.md` | private setup or mirror |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `README.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `README.md` | private setup or mirror |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `docs/provenance/extraction.md` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `features/steps/standalone_loop.js` | personal or machine identity |
| `4ed1bf19060211234d2252b1f48a4edd7688112e` | `tools/read_contain_test.go` | personal or machine identity |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `README.md` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `README.md` | private setup or mirror |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `docs/provenance/extraction.md` | personal or machine identity |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `4ef6df0d84784c37d3bbe5090c7b05ada810ae65` | `features/steps/standalone_loop.js` | personal or machine identity |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `README.md` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `README.md` | private setup or mirror |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `docs/provenance/extraction.md` | personal or machine identity |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `59d1cfe95535969762ffefd4453206db15846a9e` | `features/steps/standalone_loop.js` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `CHANGELOG.md` | private setup or mirror |
| `6b82843b031973362a41368861cc324cd508158b` | `README.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `README.md` | private setup or mirror |
| `6b82843b031973362a41368861cc324cd508158b` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `docs/provenance/extraction.md` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `6b82843b031973362a41368861cc324cd508158b` | `features/steps/standalone_loop.js` | personal or machine identity |
| `6b82843b031973362a41368861cc324cd508158b` | `tools/read_contain_test.go` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `README.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `README.md` | private setup or mirror |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `docs/provenance/extraction.md` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `features/steps/standalone_loop.js` | personal or machine identity |
| `733b50d79945fca21639ba6c10bb5208310e867d` | `tools/read_contain_test.go` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `README.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `README.md` | private setup or mirror |
| `74330074243c591cead80da15fb1ffaba74458d9` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `docs/provenance/extraction.md` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `74330074243c591cead80da15fb1ffaba74458d9` | `features/steps/standalone_loop.js` | personal or machine identity |
| `74330074243c591cead80da15fb1ffaba74458d9` | `tools/read_contain_test.go` | personal or machine identity |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `README.md` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `README.md` | private setup or mirror |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `docs/provenance/extraction.md` | personal or machine identity |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `7468a4cba91830f0c7616c41bef02562e0ac806c` | `features/steps/standalone_loop.js` | personal or machine identity |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `README.md` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `README.md` | private setup or mirror |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `docs/provenance/extraction.md` | personal or machine identity |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `765c4fd2145e10ed342329ffcf06cbae6b519f7c` | `features/steps/standalone_loop.js` | personal or machine identity |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `README.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `README.md` | private setup or mirror |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `docs/provenance/extraction.md` | personal or machine identity |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `83c22247ebbe190ebd1793a762de95f07602c9d5` | `features/steps/standalone_loop.js` | personal or machine identity |
| `84c427d558119a223e973dc111bc17a441db254b` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `84c427d558119a223e973dc111bc17a441db254b` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `84c427d558119a223e973dc111bc17a441db254b` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `84c427d558119a223e973dc111bc17a441db254b` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `84c427d558119a223e973dc111bc17a441db254b` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `84c427d558119a223e973dc111bc17a441db254b` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `84c427d558119a223e973dc111bc17a441db254b` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `84c427d558119a223e973dc111bc17a441db254b` | `README.md` | local delivery or unavailable workspace |
| `84c427d558119a223e973dc111bc17a441db254b` | `README.md` | private setup or mirror |
| `84c427d558119a223e973dc111bc17a441db254b` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `84c427d558119a223e973dc111bc17a441db254b` | `docs/provenance/extraction.md` | personal or machine identity |
| `84c427d558119a223e973dc111bc17a441db254b` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `84c427d558119a223e973dc111bc17a441db254b` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `84c427d558119a223e973dc111bc17a441db254b` | `features/steps/standalone_loop.js` | personal or machine identity |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `README.md` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `README.md` | private setup or mirror |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `docs/provenance/extraction.md` | personal or machine identity |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `85c31a558f4929e2476d8940a9b53aa96774fb00` | `features/steps/standalone_loop.js` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `CHANGELOG.md` | private setup or mirror |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `README.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `README.md` | private setup or mirror |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `contract/README.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `docs/provenance/extraction.md` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `features/steps/standalone_loop.js` | personal or machine identity |
| `877094733d4c1dbd54bd9c2526ad88b414618f97` | `tools/read_contain_test.go` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `README.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `README.md` | private setup or mirror |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `docs/provenance/extraction.md` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `features/steps/standalone_loop.js` | personal or machine identity |
| `8a2fcdaefb6b6d40308c88da83b5d18cebd686ad` | `tools/read_contain_test.go` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `CHANGELOG.md` | private setup or mirror |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `README.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `README.md` | private setup or mirror |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `contract/README.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `docs/provenance/extraction.md` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `features/steps/standalone_loop.js` | personal or machine identity |
| `932c462bdf193c808fbe822c03008622ac79d3e4` | `tools/read_contain_test.go` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `CHANGELOG.md` | private setup or mirror |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `README.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `README.md` | private setup or mirror |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `docs/provenance/extraction.md` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `features/steps/standalone_loop.js` | personal or machine identity |
| `9402b2d22f0a58872fa25a98c8837228dbbc6279` | `tools/read_contain_test.go` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `README.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `README.md` | private setup or mirror |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `docs/provenance/extraction.md` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `features/steps/standalone_loop.js` | personal or machine identity |
| `98a02aba769e6721d84914a09ccf3cd89c5e8e67` | `tools/read_contain_test.go` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `CHANGELOG.md` | private setup or mirror |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `README.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `README.md` | private setup or mirror |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `contract/README.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `docs/provenance/extraction.md` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `features/steps/standalone_loop.js` | personal or machine identity |
| `99b4b3c903d85774a69fb9b69496de02a7f9e17b` | `tools/read_contain_test.go` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `README.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `README.md` | private setup or mirror |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `docs/provenance/extraction.md` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `features/steps/standalone_loop.js` | personal or machine identity |
| `99d858a9843081f6c7848a80749cf37a95ed0167` | `tools/read_contain_test.go` | personal or machine identity |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `README.md` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `README.md` | private setup or mirror |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `docs/provenance/extraction.md` | personal or machine identity |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `9c079e170f89ae547348bbd8f90b7702436ba50b` | `features/steps/standalone_loop.js` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `CHANGELOG.md` | private setup or mirror |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `README.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `README.md` | private setup or mirror |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `docs/provenance/extraction.md` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `features/steps/standalone_loop.js` | personal or machine identity |
| `9dbfeba51c4c8ac1779d923f426f9bc2c7ae91af` | `tools/read_contain_test.go` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `CHANGELOG.md` | private setup or mirror |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `README.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `README.md` | private setup or mirror |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `docs/provenance/extraction.md` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `features/steps/standalone_loop.js` | personal or machine identity |
| `9e90bf5606e3b64a1536f93b438a1313a6dd3bbd` | `tools/read_contain_test.go` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `CHANGELOG.md` | private setup or mirror |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `README.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `README.md` | private setup or mirror |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `docs/provenance/extraction.md` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `features/steps/standalone_loop.js` | personal or machine identity |
| `a0a4c0ec17869a54ae9f13c6c8cd88ad755836bc` | `tools/read_contain_test.go` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `CHANGELOG.md` | private setup or mirror |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `README.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `README.md` | private setup or mirror |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `contract/README.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `docs/provenance/extraction.md` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `features/steps/standalone_loop.js` | personal or machine identity |
| `a44e934aae3badecefb40286650fea571d79e7b5` | `tools/read_contain_test.go` | personal or machine identity |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `README.md` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `README.md` | private setup or mirror |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `docs/provenance/extraction.md` | personal or machine identity |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `a8253e4fbdae14abae0f9921f9a3049ac86ff3ca` | `features/steps/standalone_loop.js` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `CHANGELOG.md` | private setup or mirror |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `README.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `README.md` | private setup or mirror |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `contract/README.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `docs/provenance/extraction.md` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `features/steps/standalone_loop.js` | personal or machine identity |
| `ad664c567d2cb4d93e6acc5e68365ef2f60d3f86` | `tools/read_contain_test.go` | personal or machine identity |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `README.md` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `README.md` | private setup or mirror |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `docs/provenance/extraction.md` | personal or machine identity |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `ad913c7483a458e1bb634fe6287fd3cbe92e7d6e` | `features/steps/standalone_loop.js` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `CHANGELOG.md` | private setup or mirror |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `README.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `README.md` | private setup or mirror |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `contract/README.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `docs/provenance/extraction.md` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `features/steps/standalone_loop.js` | personal or machine identity |
| `ae0d82d6e713729883ea163cad80545b52479d6e` | `tools/read_contain_test.go` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `CHANGELOG.md` | private setup or mirror |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `README.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `README.md` | private setup or mirror |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `docs/provenance/extraction.md` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `features/steps/standalone_loop.js` | personal or machine identity |
| `af456d56c52e9e8a012bff8ca1b88e2df1990cf8` | `tools/read_contain_test.go` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `CHANGELOG.md` | private setup or mirror |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `README.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `README.md` | private setup or mirror |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `docs/provenance/extraction.md` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `features/steps/standalone_loop.js` | personal or machine identity |
| `b099dfa1d6a98edcfcfce561f4e0abbb4b7536e1` | `tools/read_contain_test.go` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `README.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `README.md` | private setup or mirror |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `docs/provenance/extraction.md` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `features/steps/standalone_loop.js` | personal or machine identity |
| `b4a4185ffab264be46d71ebffd701b5e6a7f9ba4` | `tools/read_contain_test.go` | personal or machine identity |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `README.md` | local delivery or unavailable workspace |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `README.md` | private setup or mirror |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `docs/provenance/extraction.md` | personal or machine identity |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b782019d21d0054a8a0ac3f16d49a22d78f57f0b` | `features/steps/standalone_loop.js` | personal or machine identity |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `README.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `README.md` | private setup or mirror |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `docs/provenance/extraction.md` | personal or machine identity |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b80fefb2fad584d9035b0c80ffe6888cee90ea89` | `features/steps/standalone_loop.js` | personal or machine identity |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `README.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `README.md` | private setup or mirror |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `docs/provenance/extraction.md` | personal or machine identity |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b8a4046884d27786a8117e9c48b919d68883a4cf` | `features/steps/standalone_loop.js` | personal or machine identity |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `README.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `README.md` | private setup or mirror |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `docs/provenance/extraction.md` | personal or machine identity |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b97ee735e2fc47eeda963c09a17a7867b4772e4d` | `features/steps/standalone_loop.js` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `README.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `README.md` | private setup or mirror |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `docs/provenance/extraction.md` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `features/steps/standalone_loop.js` | personal or machine identity |
| `b998f2ad6b797999705e5c55c49fa29053c8a03a` | `tools/read_contain_test.go` | personal or machine identity |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `README.md` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `README.md` | private setup or mirror |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `docs/provenance/extraction.md` | personal or machine identity |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `b9e36b4aa26f8b56b4676fce2accc9a5840a7801` | `features/steps/standalone_loop.js` | personal or machine identity |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `README.md` | local delivery or unavailable workspace |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `docs/provenance/extraction.md` | personal or machine identity |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` | `features/steps/standalone_loop.js` | personal or machine identity |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `README.md` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `README.md` | private setup or mirror |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `docs/provenance/extraction.md` | personal or machine identity |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `bd627aa9cb82c04cfd4571949ebb48d58fb2b682` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `CHANGELOG.md` | private setup or mirror |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `README.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `README.md` | private setup or mirror |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `docs/provenance/extraction.md` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c013f252d8dfd195960d532adb4c5dddc18fc6c2` | `tools/read_contain_test.go` | personal or machine identity |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `README.md` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `README.md` | private setup or mirror |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `docs/provenance/extraction.md` | personal or machine identity |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c231b0796dcacf77a9a51918d00f66bb47aa8235` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `README.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `README.md` | private setup or mirror |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `docs/provenance/extraction.md` | personal or machine identity |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c4308cbf5820f5aaba8fd032f18a0feff113b696` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `README.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `README.md` | private setup or mirror |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `docs/provenance/extraction.md` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c4920e9ad4f565eb6f7c045dbff8aa2323d79036` | `tools/read_contain_test.go` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `CHANGELOG.md` | private setup or mirror |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `README.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `README.md` | private setup or mirror |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `docs/provenance/extraction.md` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c6e2360290d4d8f7e124d68c4e656b38fb350d32` | `tools/read_contain_test.go` | personal or machine identity |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `README.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `README.md` | private setup or mirror |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `docs/provenance/extraction.md` | personal or machine identity |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c6e67a551759b33ce38ae0c65676ad0f98a37ce9` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `README.md` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `README.md` | private setup or mirror |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `docs/provenance/extraction.md` | personal or machine identity |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c7e8331fd2b4dbf3ae716eba4d93aab792a8c9f6` | `features/steps/standalone_loop.js` | personal or machine identity |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `README.md` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `README.md` | private setup or mirror |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `docs/provenance/extraction.md` | personal or machine identity |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `c803feab3ae3ff96a8d15848765058c97907f64d` | `features/steps/standalone_loop.js` | personal or machine identity |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `README.md` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `README.md` | private setup or mirror |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `docs/provenance/extraction.md` | personal or machine identity |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `ca698de64c41c183d56e76ad9da121a06c762dbe` | `features/steps/standalone_loop.js` | personal or machine identity |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `README.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `README.md` | private setup or mirror |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `docs/provenance/extraction.md` | personal or machine identity |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `e1b160cea7ca81003af87738b5be1d7e8771d351` | `features/steps/standalone_loop.js` | personal or machine identity |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `README.md` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `README.md` | private setup or mirror |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `docs/provenance/extraction.md` | personal or machine identity |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `e5054c849478ddd0ed1bd2bc38f768f3cd7bd200` | `features/steps/standalone_loop.js` | personal or machine identity |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `README.md` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `README.md` | private setup or mirror |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `docs/provenance/extraction.md` | personal or machine identity |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `e8ac5fa3f0df77df8725755b21d5fe3c77916d7b` | `features/steps/standalone_loop.js` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `CHANGELOG.md` | private setup or mirror |
| `eed48c49d853150650523625638e4c9e05a32520` | `README.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `README.md` | private setup or mirror |
| `eed48c49d853150650523625638e4c9e05a32520` | `contract/README.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `docs/provenance/extraction.md` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `eed48c49d853150650523625638e4c9e05a32520` | `features/steps/standalone_loop.js` | personal or machine identity |
| `eed48c49d853150650523625638e4c9e05a32520` | `tools/read_contain_test.go` | personal or machine identity |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `README.md` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `README.md` | private setup or mirror |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `docs/provenance/extraction.md` | personal or machine identity |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `ef0f215f6682391dd11dba6a3902c30c0ddd0cd6` | `features/steps/standalone_loop.js` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/project.yaml` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `.kogen/project.yaml` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `CHANGELOG.md` | private setup or mirror |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `README.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `README.md` | private setup or mirror |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `contract/README.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `docs/provenance/extraction.md` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `features/steps/standalone_loop.js` | personal or machine identity |
| `f1cdbfee76cbd6e1776450adb99558e348aaaa59` | `tools/read_contain_test.go` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `CHANGELOG.md` | private setup or mirror |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `README.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `README.md` | private setup or mirror |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `docs/provenance/extraction.md` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `features/steps/standalone_loop.js` | personal or machine identity |
| `f2e30a42de2bca5269e43b79e5191702ecc3f986` | `tools/read_contain_test.go` | personal or machine identity |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `README.md` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `README.md` | private setup or mirror |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `docs/provenance/extraction.md` | personal or machine identity |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `f47ec9fe03a192da91c0e40a47cf2865cde46da7` | `features/steps/standalone_loop.js` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/k-contracts-loop/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/k-contracts-loop/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `CHANGELOG.md` | private setup or mirror |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `README.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `README.md` | private setup or mirror |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `contract/README.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `docs/provenance/extraction.md` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `features/steps/standalone_loop.js` | personal or machine identity |
| `f4f617f460aa484b8897bd0fdbe49d05ffb95f67` | `tools/read_contain_test.go` | personal or machine identity |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `README.md` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `README.md` | private setup or mirror |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `docs/provenance/extraction.md` | personal or machine identity |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `f7b8f70179dd172426339b961c133a35ab5bc5e3` | `features/steps/standalone_loop.js` | personal or machine identity |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `README.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `README.md` | private setup or mirror |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `docs/provenance/extraction.md` | personal or machine identity |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `f942878ac94b3c8d8f588b35a3a79b4c44aae8eb` | `features/steps/standalone_loop.js` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/anthropic-invalid-diagnostics/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-bounded-shell-wait/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-changelog-from-commits/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-parallel-tests-sys/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-parallel-tests-sys/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-review-default-text/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-shell-utf8/intent.md` | private setup or mirror |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-shell-wait-seam-rest/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-shell-wait-seam/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-shell-wait-seam/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-stop-at-green/intent.md` | private setup or mirror |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-streamidle/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-sys-groups-mac/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-tool-overlap/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-workspace-snapshot/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l-workspace-snapshot/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l7-v01-prep/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/l7-v01-prep/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/provider-stream-conformance/acceptance.feature` | private setup or mirror |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/provider-stream-conformance/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/provider-stream-conformance/intent.md` | private setup or mirror |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/standalone-loop/acceptance.feature` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/standalone-loop/acceptance.feature` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/standalone-loop/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/standalone-loop/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/timeout-custody-liveness/intent.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `.kogen/intents/timeout-custody-liveness/intent.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `CHANGELOG.md` | private setup or mirror |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `README.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `README.md` | private setup or mirror |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `docs/provenance/extraction.md` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `docs/provenance/extraction.md` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `features/steps/l_parallel_tests_sys.js` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `features/steps/l_parallel_tests_sys.js` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `features/steps/provider_stream_conformance.js` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `features/steps/standalone_loop.js` | local delivery or unavailable workspace |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `features/steps/standalone_loop.js` | personal or machine identity |
| `fe2bcd7e3fe059fc5ac8c3a792168f988b495057` | `tools/read_contain_test.go` | personal or machine identity |
