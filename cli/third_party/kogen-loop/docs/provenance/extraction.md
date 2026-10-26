# External reference adoption and reconciliation

Extraction date: 26 October 2026. This is a fresh native Build adopting external
source, not a continuation of a prior checkpoint, native authorship, approval or
verification receipt. The archive is reference source only. Native checks and
acceptance independently exercise this adopted tree.

## Supplied inputs

- Archive: `/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-loop-extraction-20261026/sprint-30min/loop-reference.tar.gz`
- Archive SHA256: `95520d37e26377bff74794eb9faa5cd67d0228f9b65fcf8e04c7e12f93dbfd40`
- Manifest: `/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-loop-extraction-20261026/sprint-30min/loop-reference-manifest.json`
- Manifest SHA256: `65dc3a49a5f939ef5d761c2d6980184ae60f0c7dcfc47454f14ec405547fc51d`
- Original Kogen commit: `56eecd572a6e07184863939254a90d9a2dc44e96`
- License: Apache-2.0. `LICENSE` and `NOTICE` are retained byte-for-byte.

The full supplied manifest is preserved as
[loop-reference-manifest.json](loop-reference-manifest.json). The original
candidate README is preserved byte-for-byte as
[reference-README.md](reference-README.md).

## Reconciled deviations

- `README.md`: replaced the bootstrap foundation-only navigation and reference's
  native/current-consumer claims with maintained runnable-tree navigation,
  build/run/test commands and truthful local status. Bootstrap provenance
  (`go mod init kogen-loop`, standard-library choice, 26 October 2026) remains.
- `go.mod`: retained bootstrap `module kogen-loop` and `go 1.27.2` rather than
  overwriting with the archive's `go 1.27`. No dependencies added.
- `.gitignore`: retained bootstrap `.DS_Store`, `/bin/`, `/kogen-loop` and
  `.kogen/local/` rules instead of the reference's `/bin/` and `/dist/`.
- Root `main.go`: removed obsolete temporary bootstrap CLI; adopted
  `cmd/kogen-loop/main.go` is the real entrypoint.
- `docs/contract/loop-v1.md`: superseded external orchestrator-owned frozen
  status, unverified current consumer/golden-path statements and section 6's
  current sync/pin claims with local maintained status and historical integration
  context; clarified cancellation checks at response/call hook boundaries. The
  v1 caller guarantees remain unchanged; no Kogen-side synchronization machinery
  is implemented.
- `api/api.go`: require a JSON object and check for EOF after decoding it. The
  reference used `Decoder.More`, which accepts a trailing `]` or `}`; such a
  malformed task could start a session and send a provider request. `null` is
  now refused as `invalid_task`, not misclassified as an unsupported protocol.
- `loop/loop.go`: added context checks after host call hooks, after a call
  returns and before its result hook/output can be published, and at the end
  of a response batch before returning an ending or starting another request.
  Native acceptance exposed a deadline race:
  custody could kill a shell group, its tool call could return normally, and the
  engine would emit a result and start another request after the deadline.
  Cancellation now stops that path without a false ending or result. Review
  also reproduced cancelled `BeforeCall`/unhandled `HandleCall` hooks still
  performing file writes, and cancelled `AfterResponse`/`AfterCall` hooks
  returning no-call/terminal endings or starting another request. The checks
  stop these paths while preserving unchanged host error identity.
- Added `conformance/cancellation_regression_test.go` to cover cancellation during
  a call and from host hooks, asserting no later side effects, false endings,
  result publication or subsequent request. Added `api/task_regression_test.go`
  and `conformance/task_regression_test.go` for strict one-object decoding and
  actual CLI refusal before any session/request. All supplied tests remain
  unchanged.
- Added this reconciliation record and the two provenance copies above.

All other archive files were copied unchanged, including the CLI, conformance
source, tests and fixtures. In particular `provider/`,
`tools/` and `sys/` remain byte-identical, including compatibility texts and
catalog metadata. No delivery executor, speculative features, credential copying,
public release, global install, remote push or AGENTS.md was added. No current
consumer/pin or external verification receipt is claimed.

## Copied inventory

The manifest supplies each original file digest. Every archive path is listed
below, including the reconciled paths described above:

- `.gitignore`
- `LICENSE`
- `NOTICE`
- `README.md`
- `api/api.go`
- `cmd/kogen-loop/main.go`
- `conformance/harness_test.go`
- `conformance/library_test.go`
- `conformance/process_test.go`
- `conformance/testdata/multi_call_terminal_in_middle.json`
- `conformance/testdata/no_call.json`
- `conformance/testdata/terminal.json`
- `conformance/testdata/tool_result_cut.json`
- `conformance/testdata/usage_partial.json`
- `conformance/testdata/usage_unknown.json`
- `docs/contract/loop-v1.md`
- `go.mod`
- `loop/loop.go`
- `loop/session.go`
- `loop/usage.go`
- `provider/affinity_test.go`
- `provider/auth_test.go`
- `provider/cache.go`
- `provider/cache_test.go`
- `provider/caching_test.go`
- `provider/chat.go`
- `provider/chat_test.go`
- `provider/client.go`
- `provider/compatible_test.go`
- `provider/creds.go`
- `provider/creds_test.go`
- `provider/diagnostics_test.go`
- `provider/errors.go`
- `provider/helpers_test.go`
- `provider/inspect.go`
- `provider/jsonenc.go`
- `provider/keyfake_test.go`
- `provider/keys.go`
- `provider/keys_test.go`
- `provider/lock.go`
- `provider/lock_test.go`
- `provider/login.go`
- `provider/login_test.go`
- `provider/messages.go`
- `provider/messages_test.go`
- `provider/profiles.go`
- `provider/profiles.json`
- `provider/profiles_test.go`
- `provider/provider.go`
- `provider/respond.go`
- `provider/respond_test.go`
- `provider/stream.go`
- `provider/testdata/elixir_prompt_cache.json`
- `provider/token.go`
- `provider/transient_test.go`
- `provider/usage.go`
- `provider/wait_test.go`
- `provider/wire.go`
- `sys/error.go`
- `sys/sys.go`
- `sys/sys_test.go`
- `tools/conversation.go`
- `tools/conversation_test.go`
- `tools/cut_output_test.go`
- `tools/cut_test.go`
- `tools/defs.go`
- `tools/defs_test.go`
- `tools/documentation.go`
- `tools/documentation_test.go`
- `tools/git.go`
- `tools/git_test.go`
- `tools/helper_test.go`
- `tools/image.go`
- `tools/image_test.go`
- `tools/json.go`
- `tools/json_test.go`
- `tools/testdata/cut_golden.json`
- `tools/testdata/defs_golden.json`
- `tools/testdata/tools_golden.json`
- `tools/tools.go`
- `tools/tools_extra_test.go`
- `tools/tools_test.go`
