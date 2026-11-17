# Name the folder in project-less read answers

Slug: read-command-project-answers-name-the-folder
Model: not applicable — the change only rewrites an error text and a document; there is no state to model
Acceptance:
- .kogen/intents/read-command-project-answers-name-the-folder/acceptance.feature
- features/steps/read-command-project-answers-name-the-folder__steps.js

Today `kogen intent list`, `kogen intent inspect`, `kogen intent preflight`, `kogen intent usage` and `kogen context --project`, run where Kogen finds no project, print one JSON line whose `error.detail` is the bare reason code (`"detail":"not_project"` or `"detail":"project_unavailable"`), because `discover` in cli/facts.go returns the reason and `response` writes `"detail": reason`. The sibling unknown-run answer (`runNotFound`) already carries a sentence and is the model for the style.

After the change the answer keeps `error.reason`, `error.class` (`environment`), `paths`, `kind`, null `checkout`, null `data` and exit code 3, and `error.detail` stops being the bare reason code.
For `not_project` it becomes the absolute folder that was looked at (the `--project` value made absolute, or the current folder when there is none), then ` is not a Kogen project: no Git checkout with .kogen/project.yaml here; run kogen init in the project folder, or pass --project with its path`.
For `project_unavailable` it becomes the `--project` value made absolute, then ` is not a readable directory; pass --project with the path of the project folder`.
No field is added to the error object. `completion`, `__complete`, a successful `context` outside a project (exit 0, `project: false`), the unknown-run answer and the `invalid_argument` answers stay as they are.

Constraints from the request: the engine commands (`kogen intent shape`, `approve`, `build` and the others) keep the refusal `environment/project_unavailable` followed by the path, as in cli/run_test.go; no new option, flag or setting; no change to kogen-coordinator, kogen-shaping or the other components.

`docs/troubleshooting.md` is corrected. The program prints, through `RequireIntentDir`, the first line `intent/not_found: Intent does not exist: ` followed by the slug and the searched folder in parentheses, then an indented line starting `kogen intent list shows existing Intents;` that also names the command that shapes a new Intent, and an indented `did you mean:` line when a similar Intent exists. So the Intent-not-found entry shows `intent/not_found: Intent does not exist: is-even (looked in .kogen/intents/is-even)` and a second line starting `kogen intent list shows existing Intents;`, without the remark that it names no next command; the inspect-outside-a-project entry says the answer is one JSON line whose `error.detail` names the folder and says to run `kogen init` there or pass `--project`; the two bullets in "Output that looks wrong" about `intent/not_found` and raw `not_project` JSON are removed, the other bullets stay. `spec/reference/checkout-facts.md`, next to the lines about absent and unavailable projects, says that `error.detail` of a `not_project` or `project_unavailable` answer names the folder and the next step.

## Decisions
- The path is made absolute with `filepath.Abs`, falling back to the given value if that fails; a shared `projectDetail(reason, project)` builds both sentences and `response` gains a detail-taking variant used by `localRead` and `usageCommand`. (decision: D1, round 1) (evidence: cli/facts.go; cli/usage.go) (source: request)
- Acceptance drives the built kogen binary, not Go test names the Build would have to invent; the Go unit tests named in Tests are added by the Build in cli/facts_test.go with the existing helpers `factProject` and `captureStdout`, using `t.TempDir()` for folders that are not projects. (decision: D2, round 1) (evidence: features/steps/k-cli-inspect-unknown-run-names-next-command__steps.js; cli/facts_test.go) (source: request)

## Source comparison
- Expected 1 and 2 (details of `not_project` and `project_unavailable`, fields kept, exit 3): addressed by scenarios 1-8 in acceptance.feature.
- Expected 3 (other answers unchanged): the successful project-less `context` is checked in scenario 8; the rest is untouched code.
- Expected 4 and 5 (troubleshooting.md and checkout-facts.md): addressed by scenario 9.

## Tests
- A folder that is not a Git checkout names itself: TestProjectAnswersNameTheFolderThatIsNotAGitCheckout in cli/facts_test.go (unit)
- A Git checkout without project.yaml gets the same sentence: TestProjectAnswersNameAGitCheckoutWithoutProjectConfig in cli/facts_test.go (unit)
- A missing project folder is named: TestProjectAnswersNameAMissingProjectFolder in cli/facts_test.go (unit)
- The troubleshooting document is current: TestProjectAnswersDocumentIsCurrent in cli/facts_test.go (regression)
- Every read command names the folder through the real CLI: the scenarios in acceptance.feature (scenario)

## Feasibility
- none
