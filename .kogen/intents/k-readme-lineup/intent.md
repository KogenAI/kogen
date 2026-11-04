# Cut README to one screen with the repo lineup

Slug: k-readme-lineup
Model: not applicable — a documentation-only change: README.md is rewritten and its other sections move unchanged into new docs/ files; no program state or executable behavior changes
Acceptance:
- .kogen/intents/k-readme-lineup/acceptance.feature
- features/steps/k-readme-lineup__readme.js

README.md is far too long for a first visit (499 lines) and has no picture of how the Kogen repositories fit together. This Intent cuts README.md to one screen (fewer than 120 lines) with exactly these parts: what Kogen is, install, a quickstart, and "Kogen repositories" (a Mermaid lineup diagram and a 9-row table), followed by a "More" list. Every other part of the current README moves unchanged (byte-identical heading text and body) into new files under docs/, each linked from the "More" list, so no content is lost.

Only README.md changes and four docs files are added: `docs/overview.md`, `docs/using-kogen.md`, `docs/readiness-and-custody.md` and `docs/contributing.md`. No existing docs file, spec file, code, test, packaging script or `.kogen/project.yaml` is edited. No program behavior changes.

### The new README.md

Its headings, outside code fences, are exactly these, in this order, and there are no others (no `###` subheadings): `# Kogen`, `## Install`, `## Quickstart`, `## Kogen repositories`, `## More`. It has fewer than 120 lines.

1. `# Kogen` (what Kogen is): exactly the current first paragraph, unchanged: This repository is `kogen`, the command-line program that is Kogen's small core. It takes one requested feature through Shape, Build, Verify, Review and Commit in your own Git repository. For Kogen as a whole, see [kogen.dev](https://kogen.dev).
2. `## Install`: one paragraph: Development prereleases are published at https://github.com/KogenAI/kogen/releases, and `packaging/install-kogen.sh` installs them into `~/.local` without administrator rights. It runs on macOS on Apple Silicon and on Linux x86-64 with glibc. To build and install from source instead, you need Git, and Go 1.27 and Node 24 from `.tool-versions` (for example with [mise](https://mise.jdx.dev)). After that paragraph comes the current Getting started build-from-source `sh` block, copied exactly: the eight lines from `git clone https://github.com/KogenAI/kogen` through `kogen provider login chatgpt                   # signs in through your browser`, comments included.
3. `## Quickstart`: the current sentence "Then, in a Git repository of your own with at least one commit (a Build needs a clean working tree, so keep the request file outside the repository, or commit it):" with its leading "Then, i" changed to "I". Then the current four-line `sh` block (`kogen init`, `kogen intent shape my-feature ../request.md`, `kogen intent approve my-feature`, `kogen intent build my-feature`), copied exactly with its comments. Then the line: For a step-by-step guide from install to your first landed feature, see [docs/getting-started.md](docs/getting-started.md); `kogen help` lists every command.
4. `## Kogen repositories`: one sentence: `kogen` pins the component repositories at exact versions in `cli/go.mod` and assembles them into one program; kogen-loop is kept as a pinned copy in `cli/third_party/kogen-loop/`. Then the README's only fenced `mermaid` block, with exactly the diagram text in acceptance.feature (each line indented two spaces after the first):
   - `flowchart TD`
   - `kogen[kogen] -->|assembles| coordinator[kogen-coordinator]`
   - four edges `coordinator -->|drives| shaping[kogen-shaping]` / `build[kogen-build]` / `review[kogen-review]` / `verification[kogen-verification]`
   - `shaping -->|runs through| executor[kogen-executor]`, and `build`, `review` and `verification -->|runs through| executor`
   - `executor -->|runs| loop[kogen-loop]`
   - `setup[kogen-setup] -->|sets up| projects[your projects]`

   Then a Markdown table with header `| Repository | Responsibility | Link |`, separator `| --- | --- | --- |` and exactly the 9 rows of acceptance.feature, in this order: kogen, kogen-coordinator, kogen-shaping, kogen-build, kogen-review, kogen-verification, kogen-executor, kogen-loop, kogen-setup. Each link cell is `[KogenAI/<repo>](https://github.com/KogenAI/<repo>)`. Cell text must not contain `|`.
5. `## More`: a bullet list, exactly:
   - `- [Overview](docs/overview.md): the five steps, providers and Claude Code, status, specification, folder map, contact and license`
   - `- [Using Kogen](docs/using-kogen.md): getting started, checkout facts, usage, approval step limits and stale approval cards`
   - `- [Readiness, continuity and evidence](docs/readiness-and-custody.md): clean final readiness, private working continuity and source provenance, native image evidence`
   - `- [Contributing](docs/contributing.md): development setup and checks`

### The moved content

Each new docs file starts with its title line, a blank line, then its moved sections in their current README order. Each moved section keeps its current `## <heading>` line and its body byte-identical, from the line after the heading up to the next heading, without surrounding blank lines. Sections are separated by one blank line, and each file ends with a newline.

- `docs/overview.md`, title `# Overview`. The title's body is the current README's introduction, unchanged: everything after `# Kogen` and before `## Status` (from "This repository is `kogen`..." through "...Linux and release real-use gates remain separate."). Then `## Status`, `## Specification`, `## Folder map`, `## Contact` and `## License`. `## Contact` keeps its whole current body, including the `--context` diagnostic-data paragraph that follows `contact@kogen.dev`.
- `docs/using-kogen.md`, title `# Using Kogen`: `## Getting started`, `## Checkout facts and completion`, `## Prompt reuse and retained usage`, `## Approval step limits and refusal diagnostics`, `## Recovering stale approval cards`.
- `docs/readiness-and-custody.md`, title `# Readiness, continuity and evidence`: `## Clean final readiness`, `## Private working continuity and source provenance`, `## Selected native image evidence`.
- `docs/contributing.md`, title `# Contributing`: `## Development`.

Moved text is verbatim, so its relative links (for example `docs/configuration.md` or `cli/third_party/kogen-loop/README.md`) stay byte-identical even though they were written relative to the repository root. Do not rewrite them: the request requires the sections unchanged and verbatim. The moved text contains no home-directory paths, so the configured `no-home-paths` check over docs/ stays green.

## Decisions
- README.md has exactly the parts what Kogen is, Install, Quickstart, "Kogen repositories", then a "More" list linking the moved content; fewer than 120 lines. (source: request)
- The Mermaid lineup: kogen assembles kogen-coordinator; the coordinator drives kogen-shaping, kogen-build, kogen-review and kogen-verification; those run through kogen-executor; the executor runs kogen-loop; kogen-setup sets up projects (drawn as an edge to a "your projects" node). (source: request)
- The 9-row table (repository, one-line responsibility, link) covers kogen, kogen-coordinator, kogen-shaping, kogen-build, kogen-review, kogen-verification, kogen-executor, kogen-loop and kogen-setup, in that order. (source: request)
- Every other current README section, including the long introduction and License/Contact, moves unchanged into docs/ files linked from "More". They are grouped by theme into four new files with the headings above; the introduction moves under the heading "Overview". (source: request)
- Responsibility wording comes from each component repository's own README first line (shortened to its first clause where that line is a paragraph); kogen's comes from this README's first line. (source: request)

## Source comparison
- Addressed: "one screen with exactly these parts: what Kogen is, install, a quickstart, and Kogen repositories" -> README.md parts 1-4 and scenario 1 (headings exactly, fewer than 120 lines, intro paragraph, Install/Quickstart literals). The "More" list is the request's own required link list.
- Addressed: Mermaid lineup diagram -> part 4 and scenario 2 (exactly one fenced `mermaid` block, in "Kogen repositories", with the pinned text). External observation during shaping, not a Kogen probe record: mermaid 11.17.2 `mermaid.parse` (under jsdom) accepted this exact diagram as `flowchart-v2` and rejected a deliberately unclosed one. GitHub renders `mermaid` fences with Mermaid; its bundled version is not pinned here.
- Addressed: 9-row table -> part 4 and scenario 3 (exact header and rows).
- Addressed: "every other current README section moves unchanged into files under docs/, each linked from a More list" and "every section removed ... exists verbatim in a docs/ file reachable by a link from the README" -> "The moved content" and scenario 4. Scenario 4 checks the heading text and the SHA-256 of each of the 15 current section bodies (introduction under "Overview", plus the 14 `##` sections) inside the docs/ files the "More" list links. The hashes were computed from the current README with the step's own section splitter. Scratch observer controls: a known-good layout passed 4/4 scenarios, the unchanged README failed 4/4, and an altered Status body and an unlinked docs file were both rejected.
- Addressed: "the existing acceptance and spec checks pass" -> no code, spec or test edits. No configured check reads the root README's content (spec/tools/check.mjs reads spec/README.md; Go tests and scenarios write their own fixture READMEs), and nothing links into root README anchors. Covered by the configured `spec`, `cucumber`, `go-test` and `no-home-paths` checks (Tests: existing).
- Conflicting source / omission: the Studio architecture brief kogen-component-landscape-20261026 r17 is not available in this checkout or on this machine; only the request references it. The responsibilities therefore come from the request's second named source, the first line of each component README at the version `cli/go.mod` pins (kogen-coordinator e26a4d75cdcc, kogen-shaping f04edcea9896, kogen-build b9990a3d0903, kogen-review e5005fa1daf8, kogen-verification f0884fde435a, kogen-executor 97892f55ed4f, kogen-setup 9316891471b5), the pinned `cli/third_party/kogen-loop/README.md`, and this README's first line for kogen.
- Consequence of the verbatim rule: relative links inside moved sections keep their repository-root form and resolve differently from docs/; the request's "unchanged"/"verbatim" wins over link rewriting.
- Superseded: the current README's long introduction and all 14 `##` sections leave README.md (moved, not deleted). The Install block and Quickstart lines are copies of current Getting started content, which also stays complete in docs/using-kogen.md.
- Literal: kogen-loop link `https://github.com/KogenAI/kogen-loop` (its module is published under github.com/KogenAI, as the Go module cache shows); the other links are the github.com/KogenAI URLs the current Folder map uses.

## Tests
- README.md is one screen: exactly # Kogen, Install, Quickstart, Kogen repositories and More, fewer than 120 lines, with the intro paragraph, install and quickstart commands: acceptance.feature scenario "The README is one screen with exactly what Kogen is, install, a quickstart, the repositories and More" (scenario)
- "Kogen repositories" has the lineup as the README's only fenced mermaid block with the pinned diagram: acceptance.feature scenario "Kogen repositories draws the lineup as a Mermaid diagram" (scenario)
- "Kogen repositories" has the 9-row repository/responsibility/link table: acceptance.feature scenario "Kogen repositories lists the nine repositories with their responsibility and link" (scenario)
- Every section removed from the README is verbatim in a docs/ file linked from the More list: acceptance.feature scenario "Every section removed from the README is verbatim in a docs file linked from More" (scenario)
- The existing acceptance and spec checks still pass: unchanged configured checks `spec`, `cucumber`, `go-test` and `no-home-paths` (existing)

## Feasibility
- none
