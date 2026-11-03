# Give Shape probes the caller's Mix and Hex homes

Slug: k-probe-mix-home
Model: not applicable — the change selects a probe's environment and links a disposable directory; it has no meaningful product state machine
Acceptance:
- .kogen/intents/k-probe-mix-home/acceptance.feature
- features/steps/k_probe_mix_home_steps.js
- features/steps/k_probe_mix_home_driver.go

Since 95a6947 ("Strip caller secrets from Shape probes") a Shape probe runs with an allowlisted environment (PATH, LANG, LANGUAGE, LC_*, GOROOT, GOPATH, GOTOOLDIR, MISE_DATA_DIR, MISE_CONFIG_DIR, MISE_CACHE_DIR, ASDF_DIR, ASDF_DATA_DIR, plus KOGEN_NODE/KOGEN_QUINT/KOGEN_CUCUMBER from Probe.Tools) and HOME set to a private empty home. Mix finds its Hex archive through MIX_HOME (default `~/.mix`) and Hex finds its cache through HEX_HOME (default `~/.hex`). Neither is passed and both defaults sit under the real home, so in an Elixir repository every probe that compiles, packages or runs the app stops with `Mix requires the Hex package manager to fetch dependencies` … `** (Mix) Could not find an SCM for dependency :<dep> from <Project>.MixProject`. After this fix a Shape probe in an Elixir repository can use the toolchain the caller installed, Hex included, the same way a Go repository's probe can use its toolchain. It still gets no credentials, tokens or shell startup files from the caller. The fix is in Kogen-owned code, in `probeEnv` and `Probe.Run` in `cli/verify/probe.go`. Every native probe route (Shape, Refine and declared evidence checks) already goes through that code. Do not edit `cli/third_party/kogen-loop/**` or `cli/loop-pin.json`.

The new rules read the caller environment from the caller `sys.Session` (`s.Env`/`s.Getenv`), never from the ambient process environment:

- **Caller's Mix home**: the caller's `MIX_HOME` when it is nonempty, otherwise `<caller HOME>/.mix` when the caller's `HOME` is nonempty. If that path is an existing directory, the probe's environment gets `MIX_HOME=<that path>`. That is the caller's own directory, shared the way GOPATH is, so the probe sees the installed Hex archive in `archives/`. Otherwise the probe gets no `MIX_HOME`.
- **Caller's Hex home**: the caller's `HEX_HOME` when it is nonempty, otherwise `<caller HOME>/.hex` when `HOME` is nonempty. The installed Hex 2.6.0 resolves its cache, config and data homes from `HEX_HOME` alone, and its `hex.config` holds API keys and repository auth keys. So the probe never gets the caller's Hex home itself. If the caller's Hex home is an existing directory, `Probe.Run` creates a fresh private directory for this probe (for example `os.MkdirTemp("", "kogen-probe-hex-")`). That directory is outside the scratch copy and outside the private probe HOME. In it Kogen creates symbolic links named `packages` (the package tarball cache) and `cache.bin` (the registry cache), each pointing to the caller Hex home's entry of that name and only when that entry exists. The probe's environment gets `HEX_HOME=<private directory>`. No other entry is linked, copied or created there, in particular not `hex.config`. Otherwise the probe gets no `HEX_HOME`.
- The private Hex directory is removed on every return of `Probe.Run`, like the private home: success, errors, refusals (for example a probe file outside the scratch copy) and caller interrupts. Removal must not follow its links, so the caller's Hex home and Mix home keep their files.
- The private probe HOME is still created empty: nothing is placed in it. Every other caller variable stays excluded, including `HEX_API_KEY`, other `HEX_*` and `MIX_*` variables, tokens, credential-store selectors and shell or tool startup selectors. The rest of the probe is unchanged: the allowlist above, scratch overlays, warm copies, the result format, the 5-minute limit, process-group and foreign-kill protection, interrupt following, the caller Session's environment and every non-probe command.

The probe can still reach absolute paths. This contract claims no filesystem isolation, the same as before.

## Decisions
- No new command, flag or option, and no timeout, retry or limit change. (source: request)
- Fix it in Kogen without weakening the secret-stripping guarantee: the probe gets the caller's Hex archive and Hex package cache, never the caller's `hex.config`, `HEX_API_KEY` or any other caller secret variable. (source: request)

## Source comparison
- Addressed: Problem. MIX_HOME/HEX_HOME are not passed and their defaults sit under the real home. Covered by the Mix home rule (explicit `MIX_HOME`, or the `~/.mix` default from the caller's HOME) and by the Hex home rule (explicit `HEX_HOME`, or the `~/.hex` default), and exercised by both Examples rows of the acceptance outline.
- Addressed: the reproduced failure text `Mix requires the Hex package manager to fetch dependencies` / `Could not find an SCM for dependency`. On the unchanged tree the acceptance probe fails with exactly that output (status 1) for the fixture dependency `kogen_probe_dep`.
- Addressed: Need, "exactly as a Go repository's probe can use its toolchain". The caller's Mix home is passed like GOPATH. The Hex cache is shared through links in a private HEX_HOME because the real Hex home also holds credentials (`hex.config`).
- Addressed: Need, "still passing no credentials, tokens or shell startup files" and "do not weaken the secret-stripping guarantee". `hex.config` is not reachable through the probe's HEX_HOME. `HEX_API_KEY` and an unrelated caller secret variable are absent. Existing tests TestShapeProbeMinimalEnvironment, TestShapeProbeMinimalEnvironmentHomeIsRemovedOnEveryReturn and TestShapeProbeMinimalEnvironmentWiring still pass unchanged: the probe home stays empty and the caller's home path is not shown when it holds no Mix or Hex home.
- Addressed: Acceptance evidence. One fast scenario: a minimal Mix fixture with one Hex dependency already fetched, the caller's Mix and Hex homes outside the probe's home, the probe compiles, and no caller secret variable is seen. It is written as one Scenario Outline with two rows: homes named by MIX_HOME/HEX_HOME (the reported MacBook setup, `MIX_HOME=<home>/.mix`), and the defaults under the caller's HOME. The configured checks pass.
- Omitted: the MacBook Studio evidence paths (`<work>/src/s-browser-waits/.kogen/local/shaping/s-browser-waits/events.ndjson`, kogen v0.1.0-dev.69d09e1c, S-BROWSER-WAITS) are historical motivation and are not inputs to any test.
- Omitted: MIX_XDG/XDG_* home resolution, MIX_ARCHIVES and other Mix/Hex variables. The request names only MIX_HOME and HEX_HOME with their `~/.mix`/`~/.hex` defaults.
- Superseded: Shape escalating the failure as an "authentication or security handoff" question (EXIT=5) is the symptom. No Shape prompt or question change is made.

## Tests
- A probe in a Mix project with an already fetched Hex dependency compiles when the caller's Mix and Hex homes are named by MIX_HOME/HEX_HOME outside the caller's HOME, and when they are the `~/.mix`/`~/.hex` defaults under the caller's HOME. It sees the Hex package cache, never `hex.config`, `HEX_API_KEY` or `KOGEN_PROBE_CALLER_SECRET`, and the caller's Hex home keeps exactly its files: add the acceptance Scenario Outline through the real `verify.RunProbe` (regression)
- Mix home and Hex home selection, with both outcomes (caller home directory exists / does not exist, explicit variable / HOME default): add TestShapeProbeMixAndHexHomes in ./verify using `Probe.Run` with fixture caller homes in temporary directories. Assert the `MIX_HOME` value and the absence of `MIX_HOME`/`HEX_HOME` when the caller has no such directory. Assert that `$HEX_HOME` lists only `packages` and `cache.bin` (and only those present) and lacks `hex.config`. Assert that the private Hex directory is removed after success and after a refused probe, that the caller's Hex home files are unchanged, and that the probe HOME stays empty (integration)
- Caller secrets stay stripped and existing probe behavior is unchanged: TestShapeProbeMinimalEnvironment, TestShapeProbeMinimalEnvironmentHomeIsRemovedOnEveryReturn, TestShapeProbeMinimalEnvironmentWiring and the other probe tests pass unchanged (existing)
- The configured checks keep passing without weakened commands, protection or settings: run the unchanged `.kogen/project.yaml` checks during Build verification (existing)

## Feasibility
- none
