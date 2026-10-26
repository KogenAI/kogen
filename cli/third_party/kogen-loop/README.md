# kogen-loop

Standalone Go agent-loop library and CLI, using only the standard library. It repeats model requests → tool calls/results until a terminal call (default `finish`) or a no-call answer. An ending is a model claim, never proof of completion: the host decides what counts as done. Kogen retains delivery policy; this component does not execute shaping, approval, verification, review, commits or checkpoints.

## Start here

- [Caller contract v1](docs/contract/loop-v1.md): library `loop/v1`, process protocol `kogen-loop/v1`, strict tasks, events, errors, usage and cancellation.
- [Public schema (`api/`)](api/) and [engine (`loop/`)](loop/): independently callable Go interfaces, optional host hooks and standalone sessions.
- [Conformance tests and recorded fixtures](conformance/): offline library and built-process behavior.
- [Testing rules](docs/testing-rules.md).
- [Apache-2.0 license](LICENSE) and [NOTICE](NOTICE).
- [Extraction and reconciliation record](docs/provenance/extraction.md), [full reference manifest](docs/provenance/loop-reference-manifest.json), and [original candidate README](docs/provenance/reference-README.md).

## Build and run

Use Go 1.27.2 (see `go.mod`). No Cobra, Viper or third-party module dependencies are selected.

```sh
go build -o bin/kogen-loop ./cmd/kogen-loop
bin/kogen-loop capabilities --json
bin/kogen-loop run --task task.json
bin/kogen-loop run --task - < task.json
```

`capabilities` is offline and needs no credentials. `run` reads exactly one strict JSON task and emits only v1 JSONL events on stdout; see the contract for a task example and exit codes. Signing in is the caller's responsibility. Existing provider credential paths (`~/.kogen/credentials/<provider>.json`) remain compatible; no credentials are migrated or bundled.

The CLI supports private atomic transcript resume (`session_resume: "transcript"`), not Kogen checkpoints. Subagents and compaction are unsupported. The default context policy refuses over-budget requests rather than clipping them. Missing usage is null, not estimated. Tool text is bounded to 16384 UTF-8 bytes; intercepted host outputs remain host-owned. Cancellation and deadlines terminate shell process groups before returning.

## Test

Tests use recorded/fake providers and private test credentials, not paid model calls:

```sh
go test -race ./...
go test ./conformance -count=1
go vet ./...
go build -o /dev/null ./...
```

## Folder map

| Path | Purpose |
| --- | --- |
| `api/` | Public v1 tasks, events, capabilities and usage |
| `loop/` | Round engine, hooks, context policy and transcript sessions |
| `provider/` | Provider wire formats, caching, retries, streams and credentials |
| `tools/` | Generic tools, model-facing definitions, replay and output bounds |
| `sys/` | Process groups, supervision, cancellation and typed errors |
| `cmd/kogen-loop/` | Real standalone CLI entrypoint |
| `conformance/` | Library/process tests and recorded exchanges |
| `docs/contract/` | Maintained caller contract |
| `docs/provenance/` | External source history and reconciliation |

## Local status and compatibility

This tree adopts an external reference into a fresh native Build. External extraction history is not native authorship, approval or verification. No current Kogen consumer, synchronized copy or digest pin is claimed here. No public release, global install, remote push or Kogen synchronization is part of this delivery.

Provider/tool/sys bytes deliberately retain compatibility residues: Kogen-named credential paths, user agents, environment variables (`KOGEN_PROVIDER_URL`, `KOGEN_AUTH_URL`, `KOGEN_LOG_LEVEL`, `__kogen_supervise`), catalog metadata, model-facing texts and optional callback seams. They do not give this library ownership of Kogen delivery policy. Generic path prevention and hooks are caller-provided primitives.

## Bootstrap provenance

26 October 2026: the runnable bootstrap selected the standard-library CLI route and used `go mod init kogen-loop`; Cobra and Viper were not selected. The bootstrap's module and Go 1.27.2 metadata remain. Its temporary root `main.go` is replaced by `cmd/kogen-loop`. The [reconciliation record](docs/provenance/extraction.md) distinguishes that bootstrap and this fresh native Build from the external reference's history.
