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

The Go tool layer offers an opt-in per-call `tools.Tools.ShellTimeout` (nonpositive is unbounded). Build shell definitions with that instance's `Definition` method and pass the same instance to `loop.Round.Tools`; see the [caller contract](docs/contract/loop-v1.md#caller-owned-shell-duration-go-tools-only). Proven timeout is tool feedback, unlike cancellation or the standalone whole-round `deadline_seconds` (already a context deadline). `RunContext`/`CallContext` forward optional custody cancellation for positive timeouts; the loop forwards its actual context and still terminates its round groups. Observed Session interruption wins, then context cancellation/deadline, then observation failure or proven timeout; hook errors keep their precedence. Native membership observation includes zombies on Darwin (numeric `KERN_PROC_PGRP`) and Linux. Linux first uses `kill(-pgid, 0)` as a monotone presence witness: success or `EPERM` means the group is present, with no readable `/proc` needed, and `pgid <= 1` is rejected before any kill. `ESRCH` alone never proves absence: Linux then enumerates `/proc` (zombies, state Z, included) and reads the group after the final `)` of each `stat`. Entries that vanish (`ENOENT`/`ESRCH`) are skipped; unreadable entries (`EPERM`/`EACCES`) and malformed `stat` are remembered, and a later membership witness wins over them. Without a witness, any remembered error or listing failure is an observation failure; only `ESRCH` plus a complete error-free scan with no member is absent. A `hidepid=1`/noaccess mount makes final confirmation fail rather than report absence; with `hidepid=2` (invisible) a hidden live member still cannot become absent because kill is a presence witness. Status as of 27 October 2026: research had reproduced the `ESRCH` defect on Linux; this correction was source-qualified on Darwin and cross-built, with Linux runtime proof pending at delivery. A cross-build does not prove lifecycle behavior. Other platforms return `sys.ErrTimeoutObservation` after timeout signalling/teardown. Failed observation returns an empty result and that stopping error even without a context, never tool feedback. This library-only option adds no CLI/task setting and is not adopted by Kogen here.

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

At initial adoption, this tree adopted an external reference into a fresh native Build. External extraction history is not native authorship, approval or verification. At that first delivery, no current Kogen consumer, synchronized copy or digest pin was claimed here. No public release, global install, remote push or Kogen synchronization was part of that initial delivery.

Published and pinned baseline observed on 27 October 2026, when this continuation started: public `origin` (`git@github.com:KogenAI/kogen-loop.git`) `main` was `bbf3fdd6d2e79b96eab6af23bcd6d66212893388`, and Kogen `main` at `bb663a593fb3499c2e3c86ffc27847f8ea0860cc` vendored this module through `cli/third_party/kogen-loop`, pinned in `cli/loop-pin.json` with `source_head` `bbf3fdd6d2e79b96eab6af23bcd6d66212893388`, 88 files and digest `4e1332b9f0aa686d76040466a965a43a5169ba9295631cf7bb9b8f62fb946638`. Later commits reach Kogen only when Kogen updates its own vendored copy and pin. This change does not modify Kogen, its vendored copy or its pin, install anything globally or switch a runtime.

Provider/tool/sys bytes deliberately retain compatibility residues: Kogen-named credential paths, user agents, environment variables (`KOGEN_PROVIDER_URL`, `KOGEN_AUTH_URL`, `KOGEN_LOG_LEVEL`, `__kogen_supervise`), catalog metadata, model-facing texts and optional callback seams. They do not give this library ownership of Kogen delivery policy. Generic path prevention and hooks are caller-provided primitives.

## Bootstrap provenance

26 October 2026: the runnable bootstrap selected the standard-library CLI route and used `go mod init kogen-loop`; Cobra and Viper were not selected. The bootstrap's module and Go 1.27.2 metadata remain. Its temporary root `main.go` is replaced by `cmd/kogen-loop`. The [reconciliation record](docs/provenance/extraction.md) distinguishes that bootstrap and this fresh native Build from the external reference's history.
