# kogen-loop

kogen-loop is Kogen's native agent loop. It sends model requests, runs the model's tool calls in a working directory and repeats until the model ends a round. It works on its own, without Kogen.

It owns the generic machinery:
- provider connections and sign-in;
- request wire formats, prompt caching, retries and streaming;
- usage reporting;
- the file, search, shell and image tools;
- tool-result bounds;
- the conversation items;
- the round engine.

It owns no delivery policy. Shaping, approval, protected baselines, verification, review, commits and checkpoints belong to [Kogen](https://github.com/KogenAI/kogen), which uses this module as a library. Kogen also drives other harnesses, such as Claude Code, through its own executor adapters.

A round ending is the model's claim, never proof of completion. Callers decide what counts as done.

## Start here

- [Caller contract v1](docs/contract/loop-v1.md): the Go library API (`loop`), the standalone process protocol (`kogen-loop run`, JSON Lines), capabilities, versioning, events, results, errors, usage, cancellation and session resume.
- [`api/`](api/): the versioned public schema types and constants. The contract owner changes these deliberately, with a version bump rule.
- [`conformance/`](conformance/): recorded fixtures and expected event sequences that every change must keep passing.

## Status

Local development component, created 26 October 2026 during the kogen/kogen-loop extraction. There's no published remote, release or tag. Kogen consumes an in-tree synchronized copy (`cli/third_party/kogen-loop/`) pinned by digest in `cli/loop-pin.json`.

## Use

You need Go 1.27 (see Kogen's `.tool-versions`). The module uses the standard library only.

```sh
go test -race ./...
go build -o bin/kogen-loop ./cmd/kogen-loop
bin/kogen-loop capabilities --json
bin/kogen-loop run --task task.json        # JSON Lines events on stdout; see the contract
```

Credentials are compatible with Kogen's own `~/.kogen/credentials/<provider>.json` store. The loop reads them where it needs them and never copies or proxies them. Signing in stays `kogen provider login <provider>`.

## Folder map

| Path | What |
| --- | --- |
| `api/` | Public protocol v1: task, event, result, error, usage and capability types; version constants |
| `loop/` | Round engine: request → tool calls → tool results until a terminal tool or a no-call answer; hooks and policies for callers |
| `provider/` | Provider transport, sign-in/credential store, wire rendering, cache identity, retry, stream accumulation, usage |
| `tools/` | Generic tools and their model-facing definitions, result cut, conversation item helpers, JSON encoding |
| `sys/` | Process groups, sessions, interruption and typed errors |
| `cmd/kogen-loop/` | Standalone CLI over `loop` and `api` |
| `conformance/` | Fixtures and expected event sequences for the caller contract |
| `docs/contract/` | The caller contract |

## Known Kogen-named residues

The move kept Kogen's bytes deliberately, for compatibility. Nothing was parameterized yet:
- **Credential store and sign-in identity:** `~/.kogen/credentials`, `host-id`, referrer `kogen`, the user agent `kogen/<version>` and the `run kogen provider login …` hints.
- **Environment variables:** the `KOGEN_PROVIDER_URL`, `KOGEN_AUTH_URL` and `KOGEN_LOG_LEVEL` seams, and `__kogen_supervise`.
- **Kogen policy still in `provider`:** `.kogen/project.yaml` selector text in refusals, the qualification catalog (`Classify`, `OfficialText`, `profiles.json` qualifications/evidence) and the `Status` lines of `kogen provider list`.
- **Model-facing tool texts:** "approved acceptance baseline", "Shape documentation lookup" and the `probe` callback seam.

Splitting or parameterizing these is a later, explicit change. It must default to the current bytes.

## Provenance and license

Apache-2.0, Copyright 2026 Optimum Tech, LLC (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). `sys`, `provider` and `tools` were moved from Kogen at commit `56eecd572a6e07184863939254a90d9a2dc44e96`. Ideas adapted from upstream harnesses must be recorded in NOTICE with source, revision and license; none has been copied yet.
