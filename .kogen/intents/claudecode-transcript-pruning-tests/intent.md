# Test Claude Code transcript pruning contract

Slug: claudecode-transcript-pruning-tests
Model: not applicable — this adds unit tests of an existing single-pass pruning function, not new state or transitions
Acceptance:
- .kogen/intents/claudecode-transcript-pruning-tests/acceptance.feature
- features/steps/claudecode-transcript-pruning-tests__steps.js

Add focused regression tests in the new file `cli/internal/claudecode/transcripts_test.go` for `pruneTranscripts` and its `transcriptReport`. `cli/internal/claudecode/transcripts.go` is in scope as the interface under test; it needs no edit. Keep all existing tests. Nothing is replaced or removed. Do not change pruning policy, retention or entry limits.

## Decisions
- The tests call `pruneTranscripts(configDir, now, retention, sessionID)` directly on a temporary config directory whose `projects/<working-directory-folder>/` holds the fixtures, with file modification times set explicitly relative to a fixed `now`, and compare the returned `transcriptReport` struct. (evidence: cli/internal/claudecode/transcripts.go; cli/internal/claudecode/update_test.go) (source: request)
- An expired `<uuid>.jsonl` regular file in a working-directory folder is removed, and the report records `removed` as the number of such files and `removedBytes` as the sum of their sizes. Use more than one removed file, of different sizes, so a count or size miscounted per file is detected. (evidence: cli/internal/claudecode/transcripts.go) (source: request)
- The current session's transcript (passed as `sessionID`) even when older than retention, a fresh `<uuid>.jsonl` transcript, and an expired `.jsonl` file whose name is not a UUID all remain in place with their content intact; the report shows only the fresh transcript as `kept`. (evidence: cli/internal/claudecode/transcripts.go) (source: request)
- A symlink named like a UUID transcript that points to an expired transcript is neither followed nor removed: the link remains a symlink, its target keeps its content, and the report records nothing for it. The target is an expired UUID transcript in a subdirectory of the working-directory folder, which is never itself a candidate, so only the link can be affected. (evidence: cli/internal/claudecode/transcripts.go) (source: request)
- Verify test strength using the real package test binary and temporary mutants of `transcripts.go`, with no preselected new test names. (decision: D1, round 1) (constraint: Require a failing assertion in transcripts_test.go, not a build failure or panic.) (evidence: cli/internal/claudecode/transcripts.go; .kogen/project.yaml; cli/go.mod) (source: request)
- Shaper choice for acceptance harness safety only: bound the initial Go build at 85000 ms, each warmed mutation build at 12000 ms and each test binary run at 5000 ms, within Cucumber step timeouts of 95000 ms and 110000 ms. These are harness deadlines, not product requirements. (decision: D2, round 1) (evidence: .kogen/project.yaml) (assumption: Neither the request nor the configuration establishes these deadline values.) (source: request)

## Source comparison
- Addressed: `ev-1702f58c` identifies the gap: `pruneTranscripts` has no direct tests in `cli/internal/claudecode`. The outcome and Tests below add coverage only. (evidence: cli/internal/claudecode/transcripts.go)
- Addressed: request acceptance 1 maps to **Report an expired transcript removal**; the acceptance rejects a test that omits report accounting (removed count, removed bytes).
- Addressed: request acceptance 2 maps to **Keep the current, fresh and non-UUID transcripts**; the acceptance rejects tests that never check excluded files.
- Addressed: request acceptance 3 maps to **Leave a symlink to an expired transcript alone**; the acceptance rejects tests that never check symlinks, including implementations that treat a symlink as a regular transcript or examine it through its target.
- Out of scope and preserved: pruning policy, retention and entry limits are not changed or tested.

## Tests
- Expired UUID transcripts are removed and the report records their count and total byte size: seed two expired transcripts of different sizes in two folders and compare the file system and the full report (unit)
- The current session transcript, a fresh transcript and a non-UUID JSONL file remain: seed all three in one folder and compare their presence, content and the report (unit)
- A symlink to an expired transcript is not followed or removed: seed a UUID-named link to an expired transcript below the folder and check the link, the target and the report (unit)

## Feasibility
- The configured Cucumber runner supplies Node and runs from the repository root. The observer compiles `./internal/claudecode` from `cli` with `go test -trimpath -c -o <temporary binary>` and an optional Go overlay, then runs the native binary from the package directory. Mutants of `transcripts.go` and weakened test bodies are confined to temporary overlays. In an external scratch copy, the good control passed and caught all eight mutants and the bad control left each category's mutants alive.
- evidence: {"id":"transcript-pruning-observer","kind":"observer","inputs":[".kogen/intents/claudecode-transcript-pruning-tests/controls.json","cli/internal/claudecode/transcripts.go","cli/go.mod"],"observers":["features/steps/claudecode-transcript-pruning-tests__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/claudecode-transcript-pruning-tests__steps.js good","exit":0,"output":"Transcript pruning tests caught every mutation.\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/claudecode-transcript-pruning-tests__steps.js bad","exit":1,"output":"Incomplete transcript pruning tests let the corresponding mutations survive.\n"}]}
