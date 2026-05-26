# Elixir Hex Library Release

**Problem**: Releasing a Hex library requires a specific commit structure, tag, and publish sequence — doing it wrong produces a mangled history or a botched package.
**When**: Releasing any new version of an in-house Elixir library to Hex.pm.
**See also**: `/release-new-version` slash command (full interactive walkthrough)

## Solution

Two commits, always in this order:

```bash
# Commit 1 — implementation (all feature/fix files, README if updated)
git add lib/ test/ README.md
git commit -m "Descriptive message about what changed and why"

# Commit 2 — release (CHANGELOG + version bump only)
git add CHANGELOG.md mix.exs
git commit -m "Release X.Y.Z"

# Tag and push
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

Then publish manually:

```bash
mix hex.build   # verify package contents first
mix hex.publish
```

## Commit Rules

- Release commit contains **only** `CHANGELOG.md` and `mix.exs` — nothing else
- Implementation commit contains everything else — no CHANGELOG, no version bump
- Release commit message is exactly `Release X.Y.Z` — no body, no trailers
- No `Co-Authored-By` trailer on either commit

## CHANGELOG Format

```markdown
## X.Y.Z (YYYY-MM-DD)

- Added `FooCheck` to detect ...
- Fixed `BarCheck` false positive when ...
```

One blank line between version sections. Date is today's date in UTC.

## Drop Draft

Save to `drops/[package]_[version].md`. Two formats:

**Single change** (one fix/check): `[package] version X.Y.Z was released.`

**Multiple changes**: one summary sentence naming what was added, e.g. `We added 4 new Credo checks: skipped tests, empty setup blocks, dev-machine defaults, and case-true-false patterns.`

Both always end with the changelog block and the hex.pm URL:

````
# [package] vX.Y.Z

[summary sentence]

```markdown
## X.Y.Z (YYYY-MM-DD)

- Added ...
````

https://hex.pm/packages/[package]

```

Save a separate `drops/[package]_[version].tweet.md` with the tweet text + the elixirdrops.net URL on the next line (fill the drop ID after posting). Tweet text = first two sentences of the drop body, **≤ 257 chars** (Twitter URLs cost ~23 chars, total must be ≤ 280).

## Gotchas

- Never run `mix hex.publish` automatically — always let the human verify with `mix hex.build` first
- Tag goes on the release commit, not the implementation commit
- Drop must start with `# [package] vX.Y.Z` title — dropping it is the most common format miss
- Don't use "why someone should care" paragraphs for minor/patch releases — a crisp summary sentence is enough
```
