# Kogen command

This crate provides the small Rust `kogen` command edge. It validates the
selected Git checkout, then passes workflow commands to Kogen's existing Mix
engine. The engine remains the owner of sessions, approvals, workflow state,
and relative input path admission.

## Build and link locally

From the Kogen source checkout, build and link the binary for this machine:

```sh
cargo build --release --locked --manifest-path native/kogen-cli/Cargo.toml --target-dir _build/cargo
ln -sfn "$PWD/_build/cargo/release/kogen" ~/.local/bin/kogen
```

The link points at this checkout's build output. Rebuild after changing the
crate. This is a local development recipe; it does not describe a production
installer or release process.

## Run a command

The target defaults to the Git checkout in the directory where you run
`kogen`. Use `--project PATH` to target another checkout without changing
directories. The engine defaults to the Kogen checkout used to build the
binary; `--engine PATH` or `KOGEN_ENGINE_ROOT` selects another engine
checkout. `--engine` takes precedence over the environment variable.

```sh
kogen shape start --brief ./brief.md
kogen shape status SESSION_ID
kogen --project /path/to/project shape start --brief ./brief.md
kogen --project /path/to/project shape status SESSION_ID
kogen build SLUG
kogen result SESSION_ID
```

Relative paths such as `--brief ./brief.md` are passed unchanged to the engine
with the canonical directory where `kogen` was invoked. The engine resolves
them during admission. The target and engine must resolve to different
directories.

The Shaping lifecycle is grouped under `shape`: `start`, `input`, `present`,
`approve`, `status`, `cancel` and `resume`. These names map to the existing
engine operations, with their remaining arguments passed through unchanged.
`build` and `result` stay top-level engine operations.

Run `kogen`, `kogen --help` or `kogen help` for top-level help. Each public
command also has static help, for example `kogen shape --help`,
`kogen shape start --help`, `kogen build --help` and `kogen result --help`.
Help does not require a valid project or engine checkout and never starts the
engine.

Flat Shaping aliases such as `kogen status SESSION_ID` and
`kogen input SESSION_ID --file FILE` remain temporarily accepted for the E08
client. They are hidden from the primary help and are compatibility only;
they will be removed after the E08 client adopts the grouped commands. New
callers should use `kogen shape status SESSION_ID` and
`kogen shape input SESSION_ID --file FILE`. The legacy
`kogen shape --brief FILE` start form also remains accepted during this
transition.

Workflow commands emit one JSON result on stdout; diagnostics go to stderr.
`result SESSION_ID` reads the committed Complete summary for a published
Build on the selected project's current history, or the Shaping status while
no committed result exists. It never repairs or resumes work.
