# Pinned local package

`scripts/package-local.py` creates an immutable, curated package for the
existing local bundle-transfer route. It does not push, upload, contact a
provider, or modify the source checkout. Run it from the Kogen checkout root.
The command requires a clean checkout, a full commit pin, and a new absolute
output path outside the checkout and iCloud Drive:

Packaging needs mise, Python 3.11 or newer, Git, and Cargo/Rust 1.97 or newer.
Cargo runs offline, so any locked Rust crates must already be available locally.

```sh
mise exec -- python scripts/package-local.py \
  --source /path/to/kogen \
  --source-sha 0123456789abcdef0123456789abcdef01234567 \
  --output /tmp/kogen-package-01234567
```

Use the full commit ID from `git rev-parse HEAD`; the abbreviated value above
is only a shape example. The output directory must not exist. The source HEAD
must match the pin and its tracked or untracked worktree must be clean. The
builder also refuses Git assume-unchanged or skip-worktree index flags. It
clears inherited Git repository variables, reads source blobs from the pinned
commit, and compiles the Rust release binary from the extracted source archive
with Cargo offline and locked.

The output contains `kogen-source.tar.gz`, `kogen-source.bundle`, `kogen`, and
`manifest.json`. The archive is a curated source snapshot, not an identical
copy of the whole repository. The bundle contains the same curated files in a
single synthetic commit; that commit is not the original source commit and has
no source history. The manifest binds the package to the original commit and
tree, lists every included Git blob and SHA-256, hashes the archive, bundle,
binary, and configuration/prompt interfaces, and records tool versions. It
sets `qualified` to `false` and `live_receipt` to `null`. A separate selected
qualification receipt is required for any stronger claim.

The builder compares the synthetic bundle tree with the archive's included
Git blob IDs before building, verifies the bundle, and runs `kogen --help` as
a provider-free smoke check. It does not run the Mix engine or full gate.

To use the bundle as a local Git transfer artifact, verify and clone its
synthetic package ref. The engine root is the `kogen-source` subdirectory:

```sh
git bundle verify /path/to/kogen-source.bundle
git clone --branch package /path/to/kogen-source.bundle /tmp/kogen-bundle
# Engine root: /tmp/kogen-bundle/kogen-source
```

The allowlist includes the engine, Rust CLI, maintained documentation and
workflows, check scripts, toolchain files, `.kogen/config.yaml`, the five
engine-owned custom role prompts, and `runtime/kh/lib` plus its `mix.exs` when
present in the pinned tree. It excludes `.kogen/intents/**`, `.kogen/runtime/**`,
`.codex/**`, product and runtime tests, runtime provenance records,
dependency/build directories, and ignored or untracked worktree state. The
package does not include credentials, caches, sessions, runtime transcripts,
or private grader fixtures.

## Startup

`./kogen --help` is a provider-free smoke check and does not need an engine.
For engine commands, extract `kogen-source.tar.gz` and use the extracted
`kogen-source` directory as the engine root. The binary's compiled default
points at its temporary build snapshot, so always pass `--engine` explicitly.
The target project and engine must be different directories.

The engine requires Elixir 1.20, Erlang/OTP 29, and its locked Mix dependencies.
After extracting the source, prepare dependencies and compile the engine in
that directory before invoking the Rust CLI. Use the same `MIX_ENV` for compile
and startup; the packaged CLI starts Mix with `--no-compile`:

```sh
cd /path/to/kogen-source
MIX_ENV=dev mix deps.get
MIX_ENV=dev mix compile
cd /path/to/target-project
MIX_ENV=dev /path/to/package/kogen --project "$PWD" \
  --engine /path/to/kogen-source status SESSION_ID
```

The `runtime/kh` path is carried as local source so a Kogen pin that declares
it as a Mix path dependency can compile it from the transferred tree. In the
source pin `48107fe1`, `runtime/kh` is still a standalone Mix project and the
top-level Kogen app does not yet dispatch through `Kh.Session`. For that pin,
its provider-free leaf compile is:

```sh
cd /path/to/kogen-source/runtime/kh
MIX_ENV=dev mix compile
```

That compile checks only the standalone runtime source. It does not prove the
role adapter or Kogen engine uses the runtime.

`mix deps.get` may need network access to obtain locked dependencies. For
offline startup, the destination must already have the required locked Mix
dependencies available and compiled for its Elixir/OTP host. Materialize those
dependencies after extracting the source; they are deliberately not part of
this package. If they are missing, the Rust command cannot start the engine.
The Rust build itself uses `cargo build --offline --locked`; it fails rather
than fetching a missing crate. Cargo caches, Mix dependencies, and `_build`
output are never copied into the package.

The build output is a local packaging snapshot only. No full gate, provider
dispatch, lifecycle acceptance, or live proof runs while packaging; use the
separately selected offline qualification receipt when one is available.

The package completes when `manifest.json` exists and its file hashes match
the package files. On an error or Ctrl-C the builder removes its partial output.
If the source pin is stale or the worktree is dirty, clean or commit the source,
read its new full SHA, and choose a new output path. If offline Cargo lacks a
locked crate, prepare that crate in the local Cargo cache and retry with a new
output path; the builder never reuses or overwrites a prior package.
