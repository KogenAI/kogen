---
description: Release a new version of an Elixir library (CHANGELOG, version bump, tag, hex publish reminder, drop draft)
argument-hint: [version e.g. 0.2.0]
---

Release new version of current Elixir library. Pause for confirmation before irreversible actions.

## STEP 1: Gather Context

```bash
grep '@version' mix.exs
git tag --sort=-v:refname | head -5
git log $(git describe --tags --abbrev=0)..HEAD --oneline --no-merges
```

Also read `CHANGELOG.md` and `mix.exs`.

## STEP 2: Determine New Version

If user provided version in argument, use it. Otherwise inspect commits since last tag:

- Breaking changes or new public API → bump minor (0.1.x → 0.2.0)
- Bug fixes and small improvements → bump patch (0.1.x → 0.1.y)
- Major redesign → bump major

Show: current version, proposed new version, commits that informed decision. Ask to confirm.

## STEP 3: Generate Changelog Entries

Read git log since last tag. Convert commits to changelog bullet points:

- Skip "Release X.X.X" commits
- Rephrase to past tense, third-person (e.g., "Added 6 readability checks")
- Group related items
- Keep concise — one line each, matching existing CHANGELOG.md style

Show proposed section and ask to confirm or edit.

## STEP 4: Update Files

1. Update `CHANGELOG.md`:
   - Add at top: `## X.X.X (YYYY-MM-DD)` using today's date
   - Add bullet points
   - Blank line between sections

2. Update version in `mix.exs`: `@version "old"` → `@version "new"`

Show diff before writing.

## STEP 5: Run Tests

```bash
[ -f Makefile ] && make ci || mix test
```

Stop and report if tests fail.

## STEP 6: Commit, Tag, Push

Show exact commands and ask for confirmation before running — these are irreversible.

```bash
git add CHANGELOG.md mix.exs
git commit -m "Release X.X.X"
git tag vX.X.X
git push origin main
git push origin vX.X.X
```

- Do NOT add `Co-Authored-By` trailer
- Release commit must only contain `CHANGELOG.md` and version bump

## STEP 7: Hex Publish Reminder

Do NOT run `mix hex.publish` automatically. Tell user:

```
Ready to publish! Run manually:

  mix hex.build   # verify package contents first
  mix hex.publish
```

## STEP 8: Draft ElixirDrop

Generate drop draft. Version release drops:

- Simple patch/minor: title + CHANGELOG block verbatim + hex link
- Significant release with new features: title + CHANGELOG + brief context
- First release: title + problem/motivation + code example + links

Save as `./drops/[package]_[version].md`.

## STEP 9: Twitter Hook

IS the opening sentence of the drop — must match exactly.

Rules:

- 1-2 plain sentences, no hashtags, no emojis
- Direct and factual
- Well under 280 characters (leave room for link ~30 chars)
- No "Check it out", no marketing fluff

Present tweet text separately as ready-to-copy block. Ask if user wants to adjust.
