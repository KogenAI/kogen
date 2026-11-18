# Name the file and cause in context refusals

Slug: build-context-refusal-names-file-and-reason
Model: not applicable — the change only rewords a stateless refusal detail
Acceptance:
- .kogen/intents/build-context-refusal-names-file-and-reason/acceptance.feature
- features/steps/build-context-refusal-names-file-and-reason__steps.js

Every refusal of `kogen intent build <slug> --context <file>` names the absolute path of the file and the one cause that applies. The rendered line becomes `intent/context_unavailable: <absolute path>: <cause>`, for example `intent/context_unavailable: /tmp/work/absent.txt: not found`. The cause is the first that applies in this order: `not found` (the path does not exist), `not a regular file` (it exists but is a directory, a socket or another non-file), `unreadable` (the file cannot be opened or read), `larger than 262144 bytes`, `not valid UTF-8`, `blank` (empty or only whitespace). The path is the one `readDiagnostic` already resolves against the caller's working directory (not `--project`). This replaces the two old messages `file must be readable and regular` and `file must contain nonblank UTF-8 data of at most 262144 bytes` and the text `file is unreadable`; no alias of them remains.

Unchanged: exit code 2, the reason `context_unavailable`, the order of checks before any provider request, repository work or lock, the rule that a file of exactly 262144 bytes is accepted, which files are accepted, `intent/request_unavailable`, every other refusal, `build.Diagnostic`, the consumed kogen-build package and the protected files. No new option or configuration. The only files to change are `cli/main.go`, `cli/run_test.go` and `docs/troubleshooting.md`.

## Decisions
- The detail of the refusal is the absolute path, a colon, a space and exactly one cause from the ordered list above; the line has no other text and nothing else is printed. (source: request)
- The absolute path is the one `readDiagnostic` computes with `absFrom`, so a relative file name is resolved against the folder where kogen was run. (evidence: cli/main.go) (source: request)
- A failure of `os.Stat` other than a missing path is reported as `unreadable`, since the request lists no separate cause for it. (evidence: cli/main.go) (assumption: confirm that a stat failure other than not-exist, such as a permission error on a parent folder, should read `unreadable`) (source: request)
- `validateDiagnostic` stays as the acceptance predicate because `cli/context_test.go` tests it; the cause is classified only after it rejects the data, in the order size, UTF-8, blank. (evidence: cli/main.go; cli/context_test.go) (source: request)
- `docs/troubleshooting.md` gets one short entry for `context_unavailable` that lists the six causes and says the path is resolved against the folder where kogen was run. (evidence: docs/troubleshooting.md) (source: request)
- The pinned row in `TestRunRefusesBeforeAnythingStarts` is updated to the new line using `filepath.Join(dir, "absent.txt")`. (evidence: cli/run_test.go) (source: request)
- Acceptance exercises the real `run` entry by injecting a scratch Go test into package main through a `go test -overlay`, using the existing `runCaptured` helper, so it does not depend on test names the Build must invent. The unreadable cause has no scenario because a test run as root can read any file. (evidence: cli/run_test.go) (source: request)
- Context refusal detail is the absolute path, colon, space, and one ordered cause (not found, not a regular file, unreadable, larger than 262144 bytes, not valid UTF-8, blank). (decision: D1, round 1) (constraint: exit 2 and reason context_unavailable unchanged) (constraint: validateDiagnostic stays because cli/context_test.go tests it) (evidence: cli/main.go; cli/run_test.go; docs/troubleshooting.md; cli/context_test.go) (assumption: A stat failure other than not-exist is reported as unreadable; the request does not list it. A probe in this session ran the scratch overlay with the proposed main.go and showed all six fixtures produce exit 2 and the new lines; the exact-limit fixture reached the engine and returned environment/not_a_git_repo with exit 3.) (source: request)

## Source comparison
- Missing file: the line becomes `intent/context_unavailable: <abs>/absent.txt: not found` (request, scenario 1) — addressed in acceptance.feature, scenario "A missing file is named by its absolute path".
- Directory: `not a regular file` instead of the old combined message (request, scenario 2) — addressed in scenario "A directory is not reported as missing".
- 262145-byte file: `larger than 262144 bytes` (request, scenario 3) — addressed in scenario "The size limit is stated in bytes".
- Blank file and invalid UTF-8 file get `blank` and `not valid UTF-8` (request, scenario 4) — addressed in scenario "Blank and binary files get different causes".
- A file of exactly 262144 bytes is still accepted (request, scenario 5) — addressed in scenario "A file of exactly 262144 bytes is still accepted".
- `unreadable` cause: required by the request but has no scenario (root can read any file); implemented, not executed in acceptance.
- Troubleshooting entry (request) — addressed in scenario "The troubleshooting guide explains the refusal".
- Omitted by request: any change to accepted files, the 262144 limit, other refusals, `build.Diagnostic`, protected files, options or configuration.

## Tests
- A missing context file is named by its absolute path with `not found`: TestBuildContextRefusalNamesAbsolutePathWhenMissing in cli/run_test.go, and the updated pinned row in TestRunRefusesBeforeAnythingStarts (unit)
- A directory is `not a regular file`, not `not found`: TestBuildContextRefusalSaysNotARegularFile in cli/run_test.go (unit)
- A 262145-byte file is `larger than 262144 bytes`: TestBuildContextRefusalStatesTheByteLimit in cli/run_test.go (unit)
- A blank file is `blank` and a file of bytes ff fe is `not valid UTF-8`: TestBuildContextRefusalSeparatesBlankFromInvalidUtf8 in cli/run_test.go (unit)
- A file of exactly 262144 bytes is not refused by the context check: TestBuildContextAcceptsFileOfExactlyTheByteLimit in cli/run_test.go (unit)
- The troubleshooting guide lists the six causes and the working folder rule: the acceptance scenario "The troubleshooting guide explains the refusal" (scenario)

## Feasibility
- none
