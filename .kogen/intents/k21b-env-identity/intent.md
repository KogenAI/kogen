# Accept a Git identity from the environment

Slug: k21b-env-identity
Model: not applicable — a stateless identity check
Acceptance:
- .kogen/intents/k21b-env-identity/acceptance.feature
- features/steps/k21b_env_identity_steps.js

The Build start check (`checked` in cli/build/build.go) and `kogen doctor`'s `git` check (cli/doctor) accept the identity when Git can produce both an author and a committer identity from config or the environment. Add a Repo method in cli/git/git.go (leave `Identity()` unchanged: approve keeps requiring a named person from config) that runs `git -c user.useConfigOnly=true var GIT_AUTHOR_IDENT` and `git -c user.useConfigOnly=true var GIT_COMMITTER_IDENT` and is true only when both exit 0 (probed: with useConfigOnly an unconfigured identity exits 128, author-only env makes the committer call exit 128, all four variables make both succeed). Build and doctor use it instead of `Identity()`. The refusal message (`environment/git_identity_missing`, same text) is unchanged; doctor fails with its existing text and fix when missing. For ok, doctor's detail may name the author identity. No new flag, no network. Builds with a configured identity are unchanged.

## Decisions
- Both author and committer identities must be producible, config-only (no hostname guessing) (source: request)
- Approve is unchanged (source: request)

## Source comparison
- Build check uses git var author and committer under user.useConfigOnly=true: addressed (cli/build/build.go, new git method).
- doctor git check uses same rule: addressed (cli/doctor/doctor.go).
- Approve unchanged: addressed; Identity() kept.
- Acceptance: env-only passes (Build and doctor), author-only refuses/fails, guessed refused: addressed in scenarios. The commit using the environment identity relies on Git itself reading the same variables; the scenario asserts the Build proceeds past start rather than a full landed commit.
- All configured checks pass: addressed by existing checks.

## Tests
- Env-only identity accepted by Build start and doctor: acceptance scenarios 1-2 (scenario)
- Author-only env refused/fail: scenarios 3-4 (scenario)
- Auto-guessed identity refused: scenario 5 (scenario)
- New git method accepts config, env-only; refuses author-only and none: unit test in cli/git/git_test.go (unit)
- Existing Build refusal and Approve behavior unchanged: existing Build and approve tests (existing)

## Feasibility
- Git behavior probed: useConfigOnly var exits 128 when unconfigured or committer missing, 0 with env. (probe 1: exit 0, 0.1 s)
