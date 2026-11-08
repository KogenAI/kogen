# Ship the getting-started guide in the archive

Slug: release-archive-ships-getting-started
Model: not applicable — packaging copies files and checks links; the change has no state or interacting rules
Acceptance:
- .kogen/intents/release-archive-ships-getting-started/acceptance.feature
- features/steps/release-archive-ships-getting-started__archive.js

The release archive built by `sh packaging/package.sh`, and so the installed copy under `~/.local/lib/kogen/docs`, ships `docs/getting-started.md` and every file it links, its README links the guide and states in two lines that every Kogen command can be driven without a terminal, and a new release check fails the packaging when a file the shipped README links, directly or through another shipped Markdown file, is missing from the archive. Today `packaging/package.sh` copies only `docs/testing-rules.md` and `docs/configuration.md`, `packaging/README.md` neither links the guide nor shows the scripted form of `shape`, and nothing checks links, so a fresh agent that read only the installed files found no guide and reported that the flow "is interactive". `install.sh` already copies the whole archive `docs/` folder and stays unchanged.

## What changes

1. **Shipped docs.** `packaging/package.sh` copies into the archive's `docs/`: `getting-started.md`, `testing-rules.md`, `configuration.md`, `usage.md`, `model-family-qualification.md` and the whole `presets/` folder (five `.yaml` files). This is exactly the closure of what the shipped README reaches: README -> `docs/getting-started.md` -> `docs/configuration.md` (a backticked path) and `docs/presets/anthropic-only.yaml` (a backticked path) -> `usage.md`, `model-family-qualification.md` and the presets (Markdown links). Today `configuration.md` ships with those links dangling. No other `docs/` file is added. The header comment of `packaging/package.sh` lists the shipped docs accurately.

2. **README.** `packaging/README.md` keeps its current content and gains:
   - in the Use section, after the line about `kogen help`, one sentence containing the link `[docs/getting-started.md](docs/getting-started.md)` (a step-by-step guide from install to the first landed feature);
   - a new section `## Without a terminal`, placed immediately before `## License`, holding exactly these two non-blank lines (and nothing else besides blank lines):

     Line 1: ``Every Kogen command can be driven without a terminal: `kogen intent shape` takes its answers as `<n>: <letter>` lines on standard input or in a file (`printf '1: a\n' | kogen intent shape my-feature -`), and `kogen intent approve` takes the card hash (`kogen intent approve my-feature <sha256>`).``

     Line 2: ``Exit statuses: `0` means ready, `5` means needs approval (the card or the questions wait for you), any other nonzero status means refused, and the error line names why.``

   These are true of the current CLI: shape and approve with the hash exit 0, a shape that stops on questions and `approve` without a hash exit 5, and not-ready or other refusals exit nonzero other than 5 (see `docs/checkout-facts.md`, `docs/using-kogen.md`).

3. **Release check.** A new script `packaging/check-archive.cjs`, run as `node packaging/check-archive.cjs <path>`, where `<path>` is either the archive's top-level folder (the folder holding `README.md`, `docs/`, `bin/`) or a `.tar.gz` archive. For a `.tar.gz` it extracts into a temporary directory (removed afterwards) and checks the archive's single top-level folder.
   - Starting from `README.md` at the root, it collects the relative references of each Markdown file it reaches: inline links `](target)` with any `#fragment` or `?query` removed, skipping targets that start with a URL scheme (`http:`, `https:`, `mailto:` …) and pure `#anchor` targets, resolved against the folder of the linking file; and backticked tokens of the form `` `docs/<path>.md` `` or `` `docs/<path>.yaml` `` (letters, digits, `_`, `.`, `/`, `-` in the path), resolved against the archive root. Text inside fenced code blocks is ignored. Every reached `.md` file is followed once; other targets are only checked for presence.
   - A reference is satisfied only by a regular file at that path inside the archive root.
   - Exit 0, when every reference is satisfied: prints `archive links ok: <n> linked files present` on standard output (`<n>` is the number of distinct referenced files, README excluded).
   - Exit 1, when any reference is unsatisfied (including a missing `README.md`): prints `archive link check failed:` on standard error, then one line `  missing <path> (linked from <file>)` for every unsatisfied reference, that is for every linking file separately, with `<path>` and `<file>` relative to the archive root using `/`. Exit 2 for a usage error (no or an unreadable `<path>`).
   - `packaging/package.sh` runs `node packaging/check-archive.cjs "$work"` on the assembled archive folder after its `docs/` and `README.md` are in place and before the folder is archived, with the check's output sent to standard error so the script's final standard-output line stays the archive path. When the check fails, `package.sh` exits nonzero and publishes no `dist/*.tar.gz`. `packaging/release.sh` builds through `package.sh`, so every release archive is checked.

4. **Specification.** In `spec/prose/10-install-and-uninstall.md`, INS-2 lists the shipped docs (`docs/getting-started.md`, `docs/testing-rules.md`, `docs/configuration.md`, `docs/usage.md`, `docs/model-family-qualification.md`, `docs/presets/`) and states that packaging fails when a file linked from the shipped README, directly or through shipped Markdown, is missing from the archive. In `spec/features/10-install-and-uninstall.feature`, the scenario that already asserts `{home}/.local/lib/kogen/docs/configuration.md` exists gains one line asserting `{home}/.local/lib/kogen/docs/getting-started.md` exists, using the existing step sentence.

Nothing else changes: not `install.sh`, `release.sh`, the version or identity algorithm, archive modes, `docs/getting-started.md` itself, or the root `README.md`.

## Decisions
- The README's two lines name the scripted form of shape (`<n>: <letter>` on standard input or a file), approval by the card hash and the three exit meanings (0 ready, 5 needs approval, other nonzero refused); their exact wording is fixed above so acceptance can inspect it. (source: request)
- The release check follows links transitively through shipped Markdown and recognises backticked `docs/...` paths, because the guide names `docs/configuration.md` and `docs/presets/anthropic-only.yaml` in backticks rather than as links, and `configuration.md` links `usage.md`, `model-family-qualification.md` and the presets. Shipping only `getting-started.md` would leave the guide's own references dangling. (source: request)
- The check is a standalone script that `package.sh` runs before archiving, so it protects every release and can be run on any archive folder or `.tar.gz` by a test. It lives beside `package.sh` and is not shipped in the archive. (source: request)
- The new README section is called `## Without a terminal` and sits before `## License` so the Use section's command list stays as it is. (source: request)

## Source comparison
- Addressed: `package.sh` copies `docs/getting-started.md` and the docs it links (item 1, scenario 1).
- Addressed: `packaging/README.md` links the guide and states the scripted form in two lines (item 2, scenario 2).
- Addressed: a release check fails when a file the shipped README links is missing from the archive (item 3, scenarios 3 and 4).
- Addressed: a test removing a linked file from the archive makes the check fail (scenario 3 removes files from the extracted archive and from a repacked archive; scenario 4 removes one from the source copy so `package.sh` itself refuses).
- Interpretation: "the other docs it links" is the closure that the shipped README and guide reach (item 1), including the guide's backticked `docs/` paths; the three exit statuses of the request are 0, 5 and any other nonzero status.
- Omitted deliberately: shipping every `docs/` file, changing the CLI's exit statuses or `install.sh`, and editing the guide.

## Tests
- The archive holds `docs/getting-started.md` and every file it reaches, the guide byte-equal to the checkout's: build the real archive with `sh packaging/package.sh` and inspect it (integration)
- The shipped README links the guide and has the two-line `## Without a terminal` section with the scripted shape form, the card hash and the three exit meanings: inspect the packaged README (integration)
- The release check passes the intact archive folder and archive and fails with `missing <path> (linked from <file>)` when the guide, `docs/configuration.md`, `docs/usage.md` or `docs/presets/anthropic-only.yaml` is removed, from a folder and from a repacked `.tar.gz`: run `packaging/check-archive.cjs` on the extracted real archive (scenario)
- `package.sh` refuses to publish an archive missing a linked file: run it on a checkout copy without `docs/presets/anthropic-only.yaml` and observe the nonzero exit, the named missing link and no archive (scenario)
- The installed copy lists the guide: one added `exists` line in the existing install scenario of `spec/features/10-install-and-uninstall.feature` (integration)

## Feasibility
- Link closure of the current docs, computed on the checkout's `docs/` plus a README linking the guide, reaches exactly README.md, the five `docs/` Markdown files named above and the five presets with no missing file. (probe 1: local node script, exit 0, 0.1 s)
