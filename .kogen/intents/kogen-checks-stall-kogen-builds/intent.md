# Make installed-binary tests hermetic and fast

Slug: kogen-checks-stall-kogen-builds
Model: not applicable — test-only change to how kogen's own Go tests obtain a release and drive login; no product state or behaviour changes
Acceptance:
- .kogen/intents/kogen-checks-stall-kogen-builds/acceptance.feature
- features/steps/kogen-checks-stall-kogen-builds__installed.js

Kogen's checks are run by contributors and by every Kogen Build on the kogen repository: at baseline and again each round. Two kinds of Go tests make those checks slow or flaky. `TestInstalledKeyLoginUnderPipesAndATerminal` (cli/login_installed_test.go) runs the `python3` it finds on PATH. When that is a mise shim and Python is not installed, mise installs core:python@3.13.16 and checks its GitHub artifact attestation. When the host's IP is rate-limited, the check fails with "403 API rate limit exceeded" and the Build stops (Build a96714c8, 29 Oct 2026: six "exit status 1" failures at baseline). The tests that use `cli/internal/testrelease` run `packaging/package.sh` again for each test, and up to twice in the isolation tests. On e746e82 (MacBook, 2 Nov), TestBaselinePackagingIsolation took 259 s, and the four TestUsageLimit*Round2/Round3 tests took 383 s together (133, 126, 67 and 56 s).

This change touches only tests. Product code, `packaging/package.sh`, `packaging/install.sh`, the installer and the product's attestation verification for real installs stay byte-for-byte unchanged. There is no new CLI command, flag, config key or environment variable. No assertion is deleted or weakened. Nothing adds a retry or a sleep, or raises any timeout, limit or deadline. All regression inputs are synthetic.

### 1. Hermetic installed-login test

`TestInstalledKeyLoginUnderPipesAndATerminal` keeps its name, its subtest names (`<provider> piped invalid UTF-8` and `<provider> terminal` for opencode-go, anthropic and openai-compatible, which go test reports as `TestInstalledKeyLoginUnderPipesAndATerminal/opencode-go_piped_invalid_UTF-8` and so on) and its final check that the openai-compatible subtests ran exactly twice. It still builds kogen from the package source with `go build -o <temp>/kogen .`, using the `go` on PATH, and drives that built binary. The Python drivers (`pipedLoginScript` and `terminalLoginScript`) are replaced by Go test code that uses only the Go standard library. That code runs no python, interpreter, shell or toolchain other than the Go that runs the test. It uses no cgo and no new module: `cli/go.mod` and `cli/go.sum` are protected and stay unchanged. The `python3` lookup and its `t.Skip` are removed, so the test always runs on the supported platforms (macOS and Linux; build-tag the test and its helpers `darwin || linux`). The pseudo-terminal comes from `/dev/ptmx` through `syscall` ioctls:
- macOS: TIOCPTYGRANT, TIOCPTYUNLK and TIOCPTYGNAME, with termios through `syscall.TIOCGETA`/`TIOCSETA`.
- Linux: TIOCSPTLCK and TIOCGPTN, opening `/dev/pts/N`, with termios through `TCGETS`/`TCSETS`.

Put these in OS-specific `_test.go` helpers.

Every Python assertion stays, with the same inputs, order and limits: 15 s per login process, 10 s for the echo to be disabled, polled every 10 ms, and a 50 ms window for reading the echo from the master. In detail:
- Piped, per provider, with HOME a fresh temporary directory and the credential at `$HOME/.kogen/credentials/<provider>.json`:
  - For openai-compatible only, the base-URL line `https://a.example/v1\n` comes first.
  - `SYNTHETIC_ORIGINAL_KEY\n` exits 0.
  - For openai-compatible, the saved file contains `"origin":"https://a.example"` and the key.
  - `SYNTHETIC_INVALID_\xff\n` exits 4.
  - Its combined output contains `provider/login` (anthropic) or `provider/login_failed` (the others), and does not contain `SYNTHETIC_INVALID_`.
  - The credential bytes are unchanged.
- Terminal, per provider, with the modes in order success→0, empty→4, SIGINT→130, SIGTERM→143, SIGHUP→129:
  - The binary's stdin is the pty slave, and its stdout and stderr are pipes.
  - Write the URL line, if there is one, to the master.
  - Wait until ECHO is off on the slave. If the process exits first, fail with `login exited before private input`. After 10 s, fail with `login never disabled echo`.
  - Then send the key line, send an empty line, or signal the process.
  - Check the exit code. Fail with `terminal was not restored` unless the slave's termios equals the state before. Check that the stdout and stderr do not contain `SYNTHETIC_TERMINAL_KEY`. If the master is readable within 50 ms, fail with `key was echoed` when up to 4096 bytes read from it contain the key.
  - In modes other than success, the credential bytes are unchanged. In success for openai-compatible, the file contains the origin and the key.
  - Always kill a still-running process, restore the slave's termios and close both ends.

Failure messages keep the Python texts quoted above verbatim. Every exit-code failure carries the mode or step, the exit code and the login's stdout and stderr, as the Python tuples did. For example, the invalid piped failure includes the stdout `opencode-go: key saved (not verified)` when the input was wrongly accepted.

### 2. One shared release per package test run

`cli/internal/testrelease` provides the release to the tests that need it. Each Go test process (one package test run, including every `-count` iteration) runs `packaging/package.sh` at most once. The cli main package runs it once and `cli/buildprogram` runs it once. Every release-using test reuses that single archive: TestAssemblyUsesThePinnedComponents, TestUsageLimitResumeInstalledRound2/Round3, TestUsageLimitPackagingIsolationRound2/Round3, TestBaselinePerBaseInstalled and TestBaselinePackagingIsolation. The release is made once, lazily (for example with `sync.Once`), like today's `Fixture` followed by `Package`:
1. Copy the current source into a disposable git checkout: `Copy`, then `git init`, `git add`, and a commit as Fixture <fixture@example.invalid>.
2. Append the uncommitted marker `\nCurrent source isolation marker.\n` to its `docs/testing-rules.md`.
3. Snapshot `git status --porcelain --untracked-files=all`.
4. Package from a further copy, keeping the existing check that the archive's `docs/testing-rules.md` equals the checkout's marked file (`packaged source differs`).
5. Require the checkout's status to equal the snapshot, failing with `status changed: before %q after %q`.
6. Seed the checkout's `dist/` with a byte copy of the archive and `sentinel.txt` (`sentinel bytes`), `chmod 0555`, and snapshot the status, the `dist` mtime and the bytes as today.

The shared archive lives in a temporary directory that the test process owns, outside any checkout. It is mode 0444 and is removed after `m.Run()`: add a TestMain to the cli main package, and extend the existing `cli/buildprogram` TestMain. Tests never write to the shared archive or the disposable checkout. They extract and install into their own `t.TempDir()`, and a test that needs a changed release first copies it into its own directory. If the one packaging fails, every release-using test that asks for the release fails with that recorded failure's message (for example `packaged source differs`) as its own test failure. The process is never aborted before the tests run.

The usage-limit tests stop passing `--version usage-limit-round<N>`: no assertion reads the version, and the label only kept per-test archives distinct. The isolation tests (TestUsageLimitPackagingIsolationRound2/3 and TestBaselinePackagingIsolation) run their installed workflow from the shared release. Afterwards they apply the existing check to the disposable checkout: status unchanged, the `dist` entries exactly the release and the sentinel, the mtime unchanged, the release and sentinel bytes unchanged, and the shared archive bytes unchanged. `git --no-optional-locks status` may be used for these read-only checks. All installed-workflow assertions in these tests stay as they are.

### What each changed test catches

Each changed test gets a one-line comment naming the defect it catches:
- `TestInstalledKeyLoginUnderPipesAndATerminal`: login custody of the built binary under pipes and a terminal. It catches invalid UTF-8 saved as a replacement key, a terminal not restored, an echoed key and changed saved credentials.
- `TestAssemblyUsesThePinnedComponents`: a release executable with unpinned or replaced components.
- `TestUsageLimitResumeInstalledRound2`/`3`: usage-limit stop and resume across rounds on the real installed binary.
- `TestUsageLimitPackagingIsolationRound2`/`3` and `TestBaselinePackagingIsolation`: packaging or an installed workflow that writes into the source checkout, or a release that does not carry the current uncommitted source.
- `TestBaselinePerBaseInstalled`: per-base baseline reuse on the installed binary.

The acceptance scenarios break the implementation on purpose, in scratch copies only, and require these tests to fail. A broken login custody (key input in `cli/third_party/kogen-loop/provider/keys.go`) must fail the login test. A synthetic `intent resume` failure in `cli/main.go` must fail TestUsageLimitResumeInstalledRound2 on the shared installed release. A `package.sh` that ships stale testing rules must fail both buildprogram installed tests.

Delivery evidence, which is not an approval gate: the Build reports the before/after wall time of `GOFLAGS=-trimpath go test -json -count=1 . ./buildprogram` in `cli`, on the same host and load, with one packaging per package run after the change.

## Decisions
- No UI, CLI or configuration change. The work is limited to kogen's Go tests, `cli/internal/testrelease` and test-only TestMain set-up. Product attestation verification and the installer are unchanged. (source: request)
- No assertion is deleted or weakened, and there are no retries, sleeps, raised timeouts, limits or deadlines. Host safety: only processes the tests start are stopped, there is no synthetic load, and only temporary directories are used. (source: request)

## Source comparison
- Addressed: K-LOGINNET, the installed-login test that needs GitHub through the `python3` toolchain lookup when the IP is rate-limited (Build a96714c8; cli/login_installed_test.go:74). Section 1 replaces Python with stdlib Go drivers. Acceptance "passes with GitHub unreachable" runs it with a refusing HTTP(S) proxy and with PATH `python3`/`python` failing like the rate-limited shim. Acceptance "fails when login custody regresses" shows that a broken login still fails it.
- Addressed: K-TEST-RELEASE-FIXTURE, where each test packages a real release (259 s; 383 s). Section 2 makes one shared read-only release per package test run, and tests that would change it use their own copies. The acceptance scenarios for the cli and buildprogram packages count `npm ci` in `lib/quint`, which runs once per packaging, and require exactly one per package run.
- Addressed: each changed test keeps its defect, with deliberately broken implementations (login custody, resume, stale packaged source) failing it in acceptance. The per-test defect comments are listed in "What each changed test catches".
- Addressed: the before/after wall time is delivery evidence, because elapsed time on a shared host is not a portable threshold. "All configured checks pass" is Kogen's configured gate, including `go-test`, which runs all of the changed tests, including Round3 and the installed tests that acceptance does not run.
- Preserved: the Must-stay items (attestation, assertions, no retries, sleeps or raised limits, no new options, synthetic regressions) and host safety, in the Decisions above.
- Superseded: the per-test `testrelease.Package`/`Fixture` packaging, the `--version usage-limit-round<N>` labels and the Python driver strings in login_installed_test.go.

## Tests
- The installed-login test never reaches GitHub or a PATH interpreter: rewrite TestInstalledKeyLoginUnderPipesAndATerminal's drivers in stdlib Go. Acceptance runs it with a refusing proxy and failing PATH python3/python, and requires all six subtests to pass (regression)
- Login custody is still proven against the built binary: acceptance breaks key input in a scratch copy and requires the three piped subtests to fail with `<provider>: key saved (not verified)` and the three terminal subtests to fail with `terminal was not restored` (regression)
- One release per cli package test run: acceptance runs TestAssemblyUsesThePinnedComponents with TestUsageLimitPackagingIsolationRound2, requires both to pass and exactly one packaging (integration)
- One release per buildprogram package test run: acceptance runs TestBaselinePerBaseInstalled with TestBaselinePackagingIsolation, requires both to pass and exactly one packaging (integration)
- The shared installed release still carries the current source to the usage-limit test: acceptance makes `intent resume` fail in a scratch copy, then requires TestUsageLimitResumeInstalledRound2 to fail with `synthetic resume regression`, TestAssemblyUsesThePinnedComponents to pass and exactly one packaging (regression)
- Stale packaged source is still refused through the shared release: acceptance makes package.sh ship stale testing rules, then requires both buildprogram installed tests to fail with `packaged source differs` after exactly one packaging (regression)
- Installed usage-limit, packaging isolation, baseline per-base and assembly behaviour stays proven: keep every assertion of TestUsageLimitResumeInstalledRound2/Round3, TestUsageLimitPackagingIsolationRound2/Round3, TestBaselinePerBaseInstalled, TestBaselinePackagingIsolation and TestAssemblyUsesThePinnedComponents, passing in the configured go-test check (existing)

## Feasibility
- A stdlib-only Go pseudo-terminal works on macOS: `/dev/ptmx` with TIOCPTYGRANT/TIOCPTYUNLK/TIOCPTYGNAME through `syscall.Syscall(SYS_IOCTL)` gave `/dev/ttys002`, and `syscall.TIOCGETA` read its ECHO flag before and after a child ran `stty` on it. (scratch probe: exit 0, about 1 s)
- On this host, one `sh packaging/package.sh` in a scratch source copy took 6.9 s, and the focused cli installed tests took 25.7 s in one run. The six acceptance runs start together, in scratch copies under the temporary directory, so they do not take the Go suite lock that the host's go shim applies to work trees.
- evidence: {"id":"installed-observers","kind":"observer","inputs":["features/steps/kogen-checks-stall-kogen-builds__installed.js"],"observers":["features/steps/kogen-checks-stall-kogen-builds__installed.js"],"checks":[{"name":"good","command":"node features/steps/kogen-checks-stall-kogen-builds__installed.js --control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/kogen-checks-stall-kogen-builds__installed.js --control bad","exit":1,"output":"rejected\n"}]}
