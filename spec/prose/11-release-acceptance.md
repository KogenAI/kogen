# 11 Release acceptance

The release counts only when the installed product completes real features on real projects. It runs from a fresh login shell.

**REL-1 — Real use.** On each platform, a fresh user `HOME`, one rerunnable script that stops at the first failed check and prints a transcript with UTC times:

1. download the archive with `curl`, extract it, run `install.sh`; `kogen version` works from `/`;
2. `kogen provider login chatgpt` through the real browser; `kogen provider list` shows `chatgpt: signed in`;
3. clone the project fresh and run `kogen init`: it configures the project itself (SET-2); the script checks the configuration against the project's expected checks and acceptance runner, and changes it only where the project needs what `init` cannot know (a project's own flaky-test rerun, for example), committed;
4. shape a request that leaves one UI/UX choice open; answer any question it asks; the Intent is ready with its scenarios failing;
5. read the Intent and step files, then approve with the card's hash;
6. `kogen intent build <slug>`, send SIGINT during it: exit 130 within 15 seconds, no new commit; discard the listed edits;
7. `kogen intent build <slug>` again: at least one real tool call runs with the default configuration (LOOP-11) and the Build lands with `review: approved`; the transcript records whether a repair happened (not required);
8. without Kogen, run the project's own acceptance command and tests on the new commit; check the commit's subject, `Kogen-Intent:` trailer, missing AI attribution, signature exactly as that host's Git configuration says (signed on hosts where the user signs), and changed paths; read the saved review;
9. no Kogen process is alive and no token from `~/.kogen/credentials/chatgpt.json` appears in the project, `.kogen/local/` or logs;
10. `kogen uninstall`: `kogen` is gone; the project and `~/.kogen` are intact.

**REL-2 — Projects.** The example app in `examples/` (in the repository) and Kogen itself (REL-3). The feature for each is fixed in its request before the run. Real projects kept outside the repository, each with its own settings file passed to `test/live/real-use.sh` by path, are an external acceptance check: REL-1 runs on them before a release, and their result is reported, but REL-6 does not wait for it.

**REL-3 — Self-build.** In a disposable repository holding the candidate Kogen source with an ordinary Git baseline (its commits are test data), the installed Kogen shapes and builds one small Kogen change. The resulting source passes its deterministic suite, is packaged, installed into a separate prefix and run outside the checkout, where the change is observed directly. Its suite uses an isolated `HOME` and never starts live-provider acceptance itself. Self-build output enters the product only deliberately, followed by a new release acceptance.

**REL-4 — Deterministic suite.** Every scenario in `features/` except `@live` ones runs against the real application (the installed release where the Background says so), with a fake ChatGPT server and an isolated `HOME`, on both platforms, together with Kogen's own `go test ./...` (REL-7). At release no required scenario is pending, skipped, undefined or excluded, and `spec/check.sh` passes. Parsing the features and matching step patterns (what `check.sh` does) is not execution evidence; only running the scenarios is.

**REL-5 — Release from a commit.** A distributed release is built from a clean checkout of a commit, so it reports `kogen <sha8>` (CLI-10), and the full deterministic suite (REL-4) and packaging pass on that checkout first. Kogen does not create release commits.

**REL-6 — Ready.** REL-1 passes on both platforms for the example app and Kogen itself, REL-3 to REL-5 and REL-7 pass, and no wrong behavior, failing check, blocking review or interrupted run left a commit on the branch. (A commit undone under GIT-6 because a hook changed it was created and then removed from HEAD; it remains only in the reflog.)

**REL-7 — Kogen's own tests.** Kogen's own code follows `docs/testing-rules.md`: unit and integration tests (Go `testing` for the `kogen` program) plus the acceptance scenarios of this specification. `go test ./...` is part of the deterministic suite (REL-4) and passes on both platforms.

Scenarios: `features/11-release-acceptance.feature` (`@live`, run by the real-use script).
