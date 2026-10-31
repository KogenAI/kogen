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

`capabilities` is offline and needs no credentials. `run` reads exactly one strict JSON task and emits only v1 JSONL events on stdout; see the contract for a task example and exit codes. Signing in is the caller's responsibility. Existing provider credential paths (`~/.kogen/credentials/<provider>.json`) remain compatible; no credentials are migrated or bundled. The one exception is `openai-compatible`: its saved key now carries the `origin` it was logged in for (`Client.LoginWithBaseURL`) and is sent only there, so a key saved earlier must be saved again; see the [contract](docs/contract/loop-v1.md).

The CLI supports private atomic transcript resume (`session_resume: "transcript"`), not Kogen checkpoints. Subagents are unsupported. History is never clipped: a request over the input window is first condensed (older complete exchanges become a model-written summary beside the exact task, the user's messages and the recent exchanges, disclosed by a `context.condensed` event), and only a request that cannot be made to fit is refused with `context_budget_exceeded` before sending. Missing usage is null, not estimated. Tool text is bounded to 16384 UTF-8 bytes (first 4096 kept); intercepted host outputs remain host-owned. These limits are fixed, not options: the 524288-byte input window (a smaller model-family bound still applies), the documentation tool's 16384-byte result and 8388608-byte response prefix, the provider's own parallel tool-call behavior and three default cache breakpoints. Cancellation and deadlines terminate shell process groups, including one that is still starting, before returning, and every round ends the groups it started whether it succeeds or fails (background processes live between its calls).

Without response or call hooks the engine overlaps independent tool calls: a complete streamed call starts before the response ends, native reads and writes to provably distinct files run concurrently, and shell, probe and unknown calls are ordered against everything. History keeps the original call order and nothing is published until the validated response has all its results; see the [contract](docs/contract/loop-v1.md). It is the default, not an option.

Shell calls yield after one second with a handle for a still-running command; retrieval waits at most one second and returns cumulative output. Yielding does not kill the command; round cleanup still stops it. The lower-level `sys.Options.Timeout` and its custody observation are independent `sys` options. See the [caller contract](docs/contract/loop-v1.md#shell-time-limit). The standalone whole-round `deadline_seconds` is a context deadline. Native membership observation includes zombies on Darwin (numeric `KERN_PROC_PGRP`) and Linux. Linux first uses `kill(-pgid, 0)` as a monotone presence witness: success or `EPERM` means the group is present, with no readable `/proc` needed, and `pgid <= 1` is rejected before any kill. `ESRCH` alone never proves absence: Linux then enumerates `/proc` (zombies, state Z, included) and reads the group after the final `)` of each `stat`. Entries that vanish (`ENOENT`/`ESRCH`) are skipped; unreadable entries (`EPERM`/`EACCES`) and malformed `stat` are remembered, and a later membership witness wins over them. Without a witness, any remembered error or listing failure is an observation failure; only `ESRCH` plus a complete error-free scan with no member is absent. A `hidepid=1`/noaccess mount makes final confirmation fail rather than report absence; with `hidepid=2` (invisible) a hidden live member still cannot become absent because kill is a presence witness. Status as of 27 October 2026 (history): research had reproduced the `ESRCH` defect on Linux; this correction was source-qualified on Darwin and cross-built, with Linux runtime proof pending at delivery. A cross-build does not prove lifecycle behavior. Commit `c7e8331` fixed two Linux test flakes; both tests passed 50/50 on eu2. Other platforms return `sys.ErrTimeoutObservation` after timeout signalling/teardown. Failed observation returns an empty result and that stopping error even without a context, never tool feedback.

Reads are root-contained: `read_file`, `view_image` and the `path` of `list_files`/`search_text` refuse `~`, absolute paths outside `Tools.Root`, `..` escapes and symlinks leaving the root (see the [contract](docs/contract/loop-v1.md#root-contained-reads)); this is not a shell sandbox.

Process groups: `sys.Options.KillGroupOnExit` (opt-in) sweeps a command's group after it ends; `RefuseForeignKill` refuses `pkill`/`killall` and kills of pids this run did not create (the `shell` tool enables it). Neither reaches processes that left the group (`setsid`, daemons), and the filter is a text filter, not a sandbox; see the [contract](docs/contract/loop-v1.md).

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
| `loop/` | Round engine, hooks, input budget and transcript sessions |
| `provider/` | Provider wire formats, caching, retries, streams and credentials |
| `tools/` | Generic tools, model-facing definitions, replay and output bounds |
| `sys/` | Process groups, supervision, cancellation and typed errors |
| `cmd/kogen-loop/` | Real standalone CLI entrypoint |
| `conformance/` | Library/process tests and recorded exchanges |
| `docs/contract/` | Maintained caller contract |
| `docs/provenance/` | External source history and reconciliation |

## Local status and compatibility

At initial adoption, this tree adopted an external reference into a fresh native Build. External extraction history is not native authorship, approval or verification. At that first delivery (historical), no current Kogen consumer, synchronized copy or digest pin was claimed here. No public release, global install, remote push or Kogen synchronization was part of that initial delivery.

Published and pinned baseline observed on 27 October 2026, when this continuation started: public `origin` (`git@github.com:KogenAI/kogen-loop.git`) `main` was `bbf3fdd6d2e79b96eab6af23bcd6d66212893388`, and Kogen `main` at `bb663a593fb3499c2e3c86ffc27847f8ea0860cc` vendored this module through `cli/third_party/kogen-loop`, pinned in `cli/loop-pin.json` with `source_head` `bbf3fdd6d2e79b96eab6af23bcd6d66212893388`, 88 files and digest `4e1332b9f0aa686d76040466a965a43a5169ba9295631cf7bb9b8f62fb946638`. Later commits reach Kogen only when Kogen updates its own vendored copy and pin. This change does not modify Kogen, its vendored copy or its pin, install anything globally or switch a runtime.

Current status, 28 October 2026: see the [CHANGELOG](CHANGELOG.md) for the unreleased v0.1.0 contents up to commit `07f21da`, and the commit history for later changes; `loop.Version` is `0.1.0-dev`. Commit `c7e8331` fixed two Linux test flakes; both tests passed 50/50 on eu2. No v0.1 tag has been created and nothing is published by this preparation.

Changes are recorded in their commit messages, not in CHANGELOG.md: a change does not add a CHANGELOG.md entry; its commit subject and body state what changed.

Provider/tool/sys bytes deliberately retain compatibility residues: Kogen-named credential paths, user agents, environment variables (`KOGEN_PROVIDER_URL`, `KOGEN_AUTH_URL`, `KOGEN_LOG_LEVEL`, `__kogen_supervise`), catalog metadata, model-facing texts and optional callback seams. They do not give this library ownership of Kogen delivery policy. Generic path prevention and hooks are caller-provided primitives.

## Bootstrap provenance

26 October 2026: the runnable bootstrap selected the standard-library CLI route and used `go mod init kogen-loop`; Cobra and Viper were not selected. The bootstrap's module and Go 1.27.2 metadata remain. Its temporary root `main.go` is replaced by `cmd/kogen-loop`. The [reconciliation record](docs/provenance/extraction.md) distinguishes that bootstrap and this fresh native Build from the external reference's history.
