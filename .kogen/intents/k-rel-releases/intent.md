# Add tested release archives and installer

Slug: k-rel-releases
Model: not applicable — shell packaging and CI wiring with no meaningful state machine
Acceptance:
- .kogen/intents/k-rel-releases/acceptance.feature
- features/steps/k_rel_releases_steps.js

Kogen gets four-platform release archives, a checksum file, a one-line installer and a CI workflow that builds, tests on native runners and creates a draft release. The existing host build and install path behaves as before. Nothing publishes a release.

Interfaces (decided here):
- `sh packaging/package.sh [--target <t>] [--version <v>]`: t is one of darwin-arm64, darwin-x86_64, linux-x86_64, linux-arm64 (anything else: message `package: unknown target <t>`, exit 2). Without `--target` it builds the host platform (uname mapping: aarch64 and arm64 are arm64; x86_64 and amd64 are x86_64), as today. The Go binary is built with CGO_ENABLED=0 and GOOS/GOARCH for the target; Quint and Cucumber npm packages are installed with `--ignore-scripts` as now, and no network is used beyond `npm ci`. `TARGET` holds the target name plus newline. With `--version <v>` the archive is `dist/kogen-<v>-<target>.tar.gz`, `lib/VERSION` is `kogen <v> (<date>)` (date as today) and VERSION.json version is `<v>`; without it the version logic is unchanged. The last stdout line is the archive path, as today.
- `sh packaging/install.sh`: accepts all four platforms (uname -m aarch64 maps to arm64, amd64 to x86_64), still refuses a mismatching TARGET with `install: this archive is for <target>, not <platform>` (exit 1) before writing anything, and still uses a Node 22+ from PATH or else downloads the Node LTS dist; the added dist names are darwin-x64 (darwin-x86_64) and linux-arm64.
- `sh packaging/release.sh --version <v> --output <dir>`: refuses (nonzero, message containing `clean`, before building or writing anything to `<dir>`) when git reports uncommitted or untracked changes under LICENSE NOTICE cli packaging docs; the caller is responsible for checking out the tag. Otherwise runs package.sh `--version <v> --target <t>` for all four targets and writes into `<dir>` exactly: the four `kogen-<v>-<target>.tar.gz`, `SHA256SUMS` (lines `<sha256>  <archive name>`, accepted by `sha256sum -c` run in `<dir>`; falls back to `shasum -a 256` where sha256sum is missing) and `install-kogen.sh` (copied from `packaging/install-kogen.sh`). The version string is used verbatim as the release tag and archive version, e.g. `v0.1.0`.
- `packaging/install-kogen.sh` (POSIX sh): `[--version <tag>] [--prefix <dir>] [--from <dir>]`. Detects the platform as above. Without `--from` it downloads `kogen-<tag>-<target>.tar.gz` and `SHA256SUMS` from `https://github.com/KogenAI/kogen/releases/download/<tag>/`; without `--version` the tag is `tag_name` from `https://api.github.com/repos/KogenAI/kogen/releases/latest`. With `--from <dir>` it copies those two files from the folder instead (`--version` is then required). It verifies the archive's sha256 against its SHA256SUMS line and on mismatch prints `install-kogen: checksum mismatch for <archive> ...; refusing to install` and exits nonzero before extracting or touching the prefix. It extracts into a `mktemp -d` directory under `${TMPDIR:-/tmp}`, removed on every exit (trap), runs the archive's `install.sh --prefix <prefix>` (default `$HOME/.local`), then prints `kogen version`'s output. It never uses sudo and writes only to the prefix and that temp directory.
- `kogen --version` prints exactly what `kogen version` prints, exit 0 (the Go parser already maps it; the stale 'moved: use kogen version' text does not appear in the code, so this must simply remain true); `kogen version` is unchanged.
- `.github/workflows/release.yml`: triggers `push` with `tags: ['v*']` and `pull_request`. Jobs: `build` (ubuntu, push only) runs `packaging/release.sh --version "$GITHUB_REF_NAME"` once and uploads the output as an artifact; `install-check` (needs build, push only) with `strategy.matrix.include` entries `{target, runner}` = linux-x86_64/ubuntu-24.04, linux-arm64/ubuntu-24.04-arm, darwin-arm64/macos-14, darwin-x86_64/macos-13, `runs-on: ${{ matrix.runner }}`, downloads the artifact, runs `sh install-kogen.sh --from <dir> --version "$GITHUB_REF_NAME" --prefix <tmp>`, checks `kogen --version` second field equals the tag and `kogen help` exits 0; `pr-check` (pull_request only, runs-on ubuntu-24.04) does the same build (placeholder version such as v0.0.0-pr) and install check for linux-x86_64 only; `draft-release` (needs install-check, push only, `permissions: contents: write`) runs `gh release create "$GITHUB_REF_NAME" --draft` with the four archives, SHA256SUMS and install-kogen.sh, using only `secrets.GITHUB_TOKEN` (as GH_TOKEN). No step publishes, edits or un-drafts a release.

## Decisions
- The version string given to `--version` is used verbatim as tag and archive version (source: request)
- `--from` requires `--version` (source: request)
- Tests build in a disposable clean git copy so dirty working trees do not matter, and create no tags or pushes (source: request)
- Job names are build, install-check, pr-check, draft-release (source: request)

## Source comparison
- Targets, TARGET file, cross-compile, ignore-scripts, install.sh four platforms and Node dists: addressed in the package.sh/install.sh interfaces; scenarios 1 and 6 (target and binary arch via ELF/Mach-O header, install.sh refusal).
- release.sh with SHA256SUMS and install-kogen.sh: addressed; scenarios 2 and 3. 'Clean tagged checkout': the script enforces cleanliness only; tag existence is not checked because tests may not create tags (narrower than the literal wording, deliberate).
- install-kogen.sh download, checksum, --from, no sudo, temp cleanup, version print: addressed; scenarios 4 and 5 test the --from path; the GitHub download and latest-release API paths are untested (no network in tests).
- `kogen --version`: addressed; already implemented in cli/main.go, asserted in scenario 4 against the installed binary.
- CI workflow: addressed; scenario 7 parses the YAML. Native runner execution is not testable locally.
- Must stay: host path unchanged (existing archive scenarios and checks); no secrets other than GITHUB_TOKEN, no publishing: asserted in scenario 7.
- Host build without --target on darwin-x86_64/linux-arm64 hosts: covered by the shared target mapping, not separately tested.

## Tests
- package.sh --target builds four archives with right TARGET and binary OS/arch: scenario 1 (scenario)
- release.sh writes four archives, SHA256SUMS, install-kogen.sh; sha256sum -c accepts: scenario 2 (scenario)
- release.sh refuses a dirty checkout: scenario 3 (scenario)
- install-kogen.sh --from installs the host archive, kogen --version equals kogen version, temp dir removed: scenario 4 (scenario)
- tampered archive refused before extraction, prefix untouched: scenario 5 (scenario)
- install.sh refuses another target's archive: scenario 6 (scenario)
- workflow YAML jobs, triggers, matrix, draft-only, token-only: scenario 7 (scenario)
- kogen --version behavior stays: scenario 4 plus the existing Go parse test (existing)

## Feasibility
- none
