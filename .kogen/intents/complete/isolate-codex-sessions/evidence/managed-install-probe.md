# Managed Codex installation and relocation probe

Observed 2026-09-10 on Darwin 25.6.0 arm64. The active `PATH` executable was
`/Users/almirsarajcic/.local/share/mise/installs/node/24.20.0/bin/codex`, which
reported `codex-cli 0.154.0`. The acquisition tool was npm 11.19.0 with Node
v24.20.0; Node/npm were probe-acquisition tools, not a demonstrated Kogen
runtime dependency.

## Registry metadata and package structure

Queried:

```sh
npm view @openai/codex@0.154.0 version scripts os cpu engines dist --json
npm view @openai/codex@0.154.0 dependencies optionalDependencies --json
npm view @openai/codex@0.154.0-darwin-arm64 version os cpu dist --json
```

The exact wrapper package was `@openai/codex@0.154.0`, with no package scripts,
Node engine `>=16`, no ordinary dependencies, and optional platform packages.
Its registry integrity was
`sha512-FV/x1OHXYv/ifjf3mXj9ThTTAWcUZN6cGIRQRhRxkKNOPuImu1WW0c8ev1vUkE9XGH90dEnYG1tBjIkxRikg0w==`.

The selected platform distribution was `@openai/codex@0.154.0-darwin-arm64`,
with platform integrity
`sha512-HP/vJCH/t2hB9Kg6hotN9UglClJ6/z584fal5lEP14C9gNAgAQS4/kTQC7l5V+BA3TqwDPwINSjul28cX8AYXg==`,
7 files, and unpacked size 290,230,067 bytes. Its native executable was:

```text
vendor/aarch64-apple-darwin/bin/codex
```

The platform package also contains sibling native resources, including `rg`,
`codex-code-mode-host`, and bundled `zsh`; deployment must preserve the whole
platform vendor tree rather than copy only the executable.

## Installation and relocation

After inspecting package metadata, installed the exact wrapper package only in
a fresh private `/tmp` directory:

```sh
npm install --prefix <temp>/staging --ignore-scripts --no-package-lock --no-save \\
  --omit=dev @openai/codex@0.154.0
```

The install added two packages and selected the arm64 platform optional package.
No package-install script was available or run. Directly launched the native
platform executable under `env -i` with private `HOME`, `CODEX_HOME`, and
`PATH=/usr/bin:/bin`:

```sh
<native>/vendor/aarch64-apple-darwin/bin/codex --version
<native>/vendor/aarch64-apple-darwin/bin/codex login --help
```

Both succeeded and reported `codex-cli 0.154.0` before relocation. Moved the
entire `codex-darwin-arm64` package directory to another location in the same
private temporary tree and reran those exact commands; both again succeeded.
No credential command, provider turn, or personal auth/configuration was used.

## Negative controls

- An intentionally incomplete synthetic staging tree had no native executable.
- `npm install` of the non-existent requested version `@openai/codex@0.154.0-not-a-release`
  exited 1 in a separate empty prefix. The previously relocated native binary
  still reported `codex-cli 0.154.0` afterward.

This proves only this platform/version's package acquisition and native-tree
relocation behavior. It does not establish an atomic updater design, signature
verification policy, cross-platform support, login/onboarding behavior, or
provider authentication.
