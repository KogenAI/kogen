---
description: Release a new version of an Elixir library (CHANGELOG, version bump, tag, hex publish reminder, drop draft)
argument-hint: [version e.g. 0.2.0]
---

Release a new version of the current Elixir library. Walk through each step carefully, pausing for confirmation before irreversible actions.

## STEP 1: Gather Context

```bash
# Get current version and last tag
grep '@version' mix.exs
git tag --sort=-v:refname | head -5
git log $(git describe --tags --abbrev=0)..HEAD --oneline --no-merges
```

Also read `CHANGELOG.md` and `mix.exs` to understand the current state.

## STEP 2: Determine New Version

If the user provided a version in the argument, use it. Otherwise, inspect commits since the last tag:

- Breaking changes or new public API → bump minor (0.1.x → 0.2.0)
- Bug fixes and small improvements → bump patch (0.1.x → 0.1.y)
- Major redesign → bump major

Show the user: current version, proposed new version, and the commits that informed the decision. Ask to confirm before continuing.

## STEP 3: Generate Changelog Entries

Read git log since the last tag and convert commits into changelog bullet points:

- Skip commits that are just "Release X.X.X"
- Rephrase commit messages to past tense, third-person style (e.g., "Add 6 readability checks" → "Added 6 readability checks to automate code review")
- Group if there are many related items
- Keep them concise — one line each, matching the existing style in CHANGELOG.md

Show the proposed changelog section to the user and ask to confirm or edit before writing.

## STEP 4: Update Files

Once the user confirms the changelog content:

1. Update `CHANGELOG.md`:
   - Add new version section at the top: `## X.X.X (YYYY-MM-DD)` using today's date
   - Add the bullet points
   - Ensure there's a blank line between sections

2. Update version in `mix.exs`:
   - Change `@version "old"` to `@version "new"`

Show a diff of both changes before writing.

## STEP 5: Run Tests

```bash
# Use make ci if Makefile exists, otherwise mix test
[ -f Makefile ] && make ci || mix test
```

If tests fail, stop and report. Do not continue until tests pass.

## STEP 6: Commit, Tag, Push Tag

```bash
git add CHANGELOG.md mix.exs
git commit -m "Release X.X.X"
git tag vX.X.X
git push origin vX.X.X
```

Show the exact commands and ask for confirmation before running them. These are irreversible.

## STEP 7: Hex Publish Reminder

Do NOT run `mix hex.publish` automatically. Instead, tell the user:

```
Ready to publish! Run manually:

  mix hex.build   # verify the package contents first
  mix hex.publish
```

Remind them to check the package contents with `mix hex.build` before publishing.

## STEP 8: Draft an ElixirDrop

Generate a drop draft for the new release. A drop is a short post on elixirdrops.net.

Version release drops follow a minimal format — look at these real examples for reference:

- Simple patch/minor: just the title + CHANGELOG block verbatim + hex link (https://elixirdrops.net/d/Etz2fMBY)
- Significant release with new features: title + CHANGELOG block + brief context on what makes it notable (https://elixirdrops.net/d/tKiW18hc)
- First release of a library: title + problem/motivation + code example + links (https://elixirdrops.net/d/AsEtmHUq)

**Choose the right format based on release significance:**

For patch/minor version updates (most common):

````
# [package] vX.X.X

[package] version X.X.X was released.

```markdown
## X.X.X (YYYY-MM-DD)

- Changelog entry one
- Changelog entry two
```

https://hex.pm/packages/[package]
````

For significant releases with notable new features, add 1-2 sentences before the changelog block explaining what's compelling about this release and why developers should care.

For a first-ever release, use the fuller format with a problem statement and code example (see `/write-drop` for that).

Always end with the hex.pm package URL. Optionally add GitHub and hexdocs links.

Save the drop draft as a markdown file in `./drops/[package]_[version].md` (e.g. `drops/optimum_credo_0_2_0.md`).

## STEP 9: Twitter Hook

The Twitter hook IS the opening sentence of the drop — they must match exactly. No separate section in the file.

Rules from real examples:

- 1-2 plain sentences, no hashtags, no emojis
- Direct and factual tone
- For significant releases, lead with the "why someone should care" angle
- The elixirdrops.net link auto-generates a rich card — no need to describe it
- Keep well under 280 characters to leave room for the link (~30 chars)
- No "Check it out", no "🧵", no marketing fluff

Examples:

- Simple: `optimum_gen_infra version 0.1.5 was released.`
- Notable (two paragraphs):

  ```
  We needed some additional Credo checks, so we created our own.

  Check out how to set them up and use them.
  ```

- Context-first: `Following recent improvements we've made to our workflows using AI agents and Tidewave, we've released a new version of our infra generator for Phoenix and regular Elixir apps.`

After presenting the drop, show the tweet text separately (it's just the first line of the drop) as a ready-to-copy block. Ask the user if they want to adjust the wording.
