# Acceptance suite

Run the deterministic acceptance scenarios against the installed release with:

```sh
npm test
```

Set `KOGEN_ARCHIVE` to use a specific release archive. Otherwise the suite uses the newest archive for the current platform in `dist/`, installs it once in a temporary prefix, and gives each scenario an isolated temporary home and fake ChatGPT servers. Run with Node 24 on `PATH`; set `KOGEN_TEST_PYTHON_BIN` if Python 3.13 is not at the default mise path. If there is no archive, the coordinator packages the current source, which needs Go on `PATH`. `@live` scenarios are excluded. Cucumber runs eight workers with separate homes and repositories. Coordinator hooks install one immutable program shared by the workers. Cucumber's built-in assignment rule keeps the `@GPT-2` login scenarios serial because they share the OAuth callback port. Only the Elixir fixture project's own Erlang VM gets `ERL_FLAGS` (two scheduler threads unless supplied). Real process argument/environment sampling runs only for scenarios asserting against it; process-group tracking and cleanup remain active for every scenario: project commands run under the kogen watchdog (the same binary re-executed with `__kogen_supervise`), and the driver signals a command's process group or the kogen process itself as the scenario says.

To retain built-in per-scenario and step timings, provide a JSON output path in an existing evidence directory:

```sh
npm test -- --format json:/absolute/path/to/evidence/acceptance.json
```

The probe-timeout scenario builds a Go test-only driver that shapes through the program's own packages, verifies the outgoing five-minute deadline, and shortens only that probe's deadline to 200 ms. The production executor supplies the real timeout result; the scenario checks process cleanup, scratch removal and continued shaping. Production defaults and release binaries are unchanged. This verifies the configured policy and timeout path together, not five minutes of wall-clock passage.

Installer scenarios get independent clones of the archive already extracted by the coordinator; file data is copied normally when filesystem cloning is unavailable. Each scenario still invokes the real installer. Only the missing-Node case redirects Node distribution requests to a temporary local HTTP fixture containing a tarball of the actual pinned Node installation running the suite. Real curl downloads the catalog and selected LTS archive, real tar extracts it, and the installed Node must report the fixture version. A newer non-LTS catalog entry checks selection. This removes external service availability from the deterministic suite; it does not qualify the live Node download service. The fixture has no cross-run cache.
