---
description: Release a new version of an Elixir library (CHANGELOG, version bump, tag, hex publish reminder, drop draft)
argument-hint: [version e.g. 0.2.0] [branch=main] [--no-push]
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

Also parse the argument string for an optional push target and push mode, used in STEP 6.
These are independent of word order and position in the argument string:

- **Branch**: if the caller supplied a second word that is not `--no-push` (e.g. `develop`), that is
  the push branch. Otherwise default to `main` — this is the byte-identical default behavior when no
  branch is given.
- **`--no-push` flag**: if present anywhere in the argument string, STEP 6 commits and tags locally but
  does NOT run either push — it prints the exact push commands for the caller to run under its own git
  discipline instead.

Show: current version, proposed new version, commits that informed decision, and the resolved push
branch (+ note if `--no-push` was given). Ask to confirm.

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

Commit and tag always run locally:

```bash
git add CHANGELOG.md mix.exs
git commit -m "Release X.X.X"
git tag vX.X.X
```

Then push, targeting the branch resolved in STEP 2 (default `main` when the caller gave none):

- **Default (no `--no-push`)**: run the pushes.

  ```bash
  git push origin <branch>
  git push origin vX.X.X
  ```

- **`--no-push` given**: do NOT run either push command. Instead print them as a ready-to-copy block
  and tell the user the release commit + tag are local-only — they own running the push (e.g. through
  their own ff-only / review-gated git-write flow):

  ```
  Release committed and tagged locally. Push when ready:

    git push origin <branch>
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
