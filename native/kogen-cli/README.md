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

The target is an explicit Git checkout. The engine defaults to the Kogen
checkout used to build the binary; `--engine PATH` or `KOGEN_ENGINE_ROOT`
selects another engine checkout. `--engine` takes precedence over the
environment variable.

```sh
kogen --project /path/to/project shape --brief ./brief.md
kogen --project /path/to/project status SESSION_ID
```

Relative paths such as `--brief ./brief.md` are passed unchanged to the engine
with the canonical directory where `kogen` was invoked. The engine resolves
them during admission. The target and engine must resolve to different
directories.

Run `kogen --help` for the retained headless command forms. Arguments after a
command are passed through to the engine, which owns command-specific options
and behavior.
