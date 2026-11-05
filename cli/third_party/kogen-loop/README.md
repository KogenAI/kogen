# kogen-loop

kogen-loop is a standard-library Go library and standalone CLI for an agent loop. It sends model requests, executes tool calls, returns results and repeats until a terminal call or a no-call answer. An ending is a model claim, not proof of completion; the host decides what counts as done. [Kogen](https://github.com/KogenAI/kogen) uses the library and owns its own delivery policy. Learn more at https://kogen.dev.

## Build and run

Install Go 1.27.2 (see `go.mod`), then clone and build:

```sh
git clone https://github.com/KogenAI/kogen-loop.git
cd kogen-loop
go build -o bin/kogen-loop ./cmd/kogen-loop
bin/kogen-loop capabilities --json
bin/kogen-loop run --task task.json
bin/kogen-loop run --task - < task.json
```

The module has no third-party dependencies. `capabilities --json` works offline without credentials. `run` reads one strict JSON task and emits v1 JSON Lines events on stdout; provider requests require appropriate credentials. See the [caller contract](docs/contract/loop-v1.md) for task examples, authentication compatibility, limits, events and exit codes.

## Test

Tests use recorded or fake providers and do not require paid model calls:

```sh
go test ./...
go test -race ./...
go test ./conformance -count=1
go vet ./...
go build -o /dev/null ./...
```

`go run scripts/slowtests.go` reports, on demand, each package's wall time and every test that takes 2 s or longer, and exits non-zero when such a test is not listed with its reason in `scripts/slowtests-allowlist.txt`. It is not part of `go test ./...`.

## Navigation

- [Caller contract v1](docs/contract/loop-v1.md): API, process protocol, tools, errors and cancellation.
- [Schema](api/) and [engine](loop/): Go interfaces, hooks and sessions.
- [Conformance tests](conformance/) and [consumer contract suite](contract/).
- [Extraction and reconciliation](docs/provenance/extraction.md), [reference manifest](docs/provenance/loop-reference-manifest.json) and [historical reference README](docs/provenance/reference-README.md).
- [History audit](docs/public-history-audit.md).
- [Apache-2.0 license](LICENSE) and [NOTICE](NOTICE).

For inquiries: contact@kogen.dev.
