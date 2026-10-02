# Kogen

Kogen is an AI-agent software-building system written in Elixir. A human approves a short Markdown Intent; Kogen builds it in an isolated checkout with an LLM Developer loop, verifies the result with deterministic checks, and lands it on the main branch.

This repository is the single Mix application that forms Kogen's core. The current work is the P0/T1 foundation: shared contracts, strict domain boundaries, the developer checks and testkit, and the command-line entry point. Later work fills each domain behind its facade.

## Start here

- [Contracts](lib/kogen/contracts.ex) defines the shared structs and ports.
- [Domain facades](lib/kogen/) own the dependency map and document each domain.
- [Makefile](Makefile) owns the local quality gate and fast domain loop.
- [Custom Credo checks](tools/kogen_checks/) owns Kogen-specific static checks.

## Repository map

| Path | Contents |
| --- | --- |
| `lib/kogen/` | Contracts, domain facades, and the future core modules |
| `test/` | ExUnit tests and the `Kogen.Testkit` support boundary |
| `tools/kogen_checks/` | The local Credo check package and its tests |

## Domains

| Domain | Responsibility | Depends on |
| --- | --- | --- |
| Contracts | Shared value types and port behaviours | — |
| Proc | Bounded operating-system process execution | Contracts |
| Project | Project configuration and check definitions | Contracts |
| Intent | Human-authored Intent loading and validation | Contracts |
| Provider | Model-provider requests and responses | Contracts |
| Build | Developer loop and candidate lifecycle | Contracts |
| Workspace | Isolated checkout and worktree operations | Contracts, Proc |
| State | Persisted build state and receipts | Contracts, Workspace |
| Checks | Deterministic verification and check results | Contracts, Proc, Workspace, Project |
| Harness | Provider-backed Developer orchestration | Contracts, Proc, Provider, Project |
| Kernel | CLI and cross-domain coordination | Every domain above |

## Run the checks

Use the pinned toolchain from `mise.toml`:

```sh
mise exec -- mix deps.get
make check
make check-fast D=contracts
```

`make check` runs formatting, the guard, strict compilation, xref, Credo, tests, and Dialyzer. `make check-fast D=<domain>` scopes Credo and ExUnit to one domain after compiling the app.

## Toolchain and layout

Elixir 1.20.4-otp-29 and Erlang/OTP 29.1.1 are pinned in `mise.toml`. The repository is one Mix app named `kogen`; domain modules live in `lib/kogen/`, tests in `test/`, test support in `test/support/`, and local static-analysis checks in `tools/kogen_checks/`.
