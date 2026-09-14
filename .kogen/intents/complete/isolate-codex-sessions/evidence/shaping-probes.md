# Bounded isolation probes

Observed 2026-09-10, approximately 04:00–04:08 UTC. Installed CLI:
codex-cli 0.153.4. Live root profile: gpt-6-astra, low. Repository inspected:
clean main at 4d7a2402eb9b5941a2993a502e7ea1c6abac407b.

All probes ran in a separately initialized Git fixture under ignored
.kogen/runtime/isolation-shaping-5a5j58fz. Its Git top-level was asserted before
live execution. Only fixture files and ignored runtime material were written;
the real repository's implementation and personal configuration were unchanged.

## Findings

| Probe | Observation |
| --- | --- |
| CLI help | exec and exec resume support ignore-user-config; the interactive TUI does not list it. Its help describes auth as still using CODEX_HOME. |
| Feature controls | disable plugins and disable apps were accepted; feature output showed both false while hooks remained true. |
| Private CODEX_HOME, ordinary HOME | debug prompt-input still included personal /Users/almirsarajcic/.agents/skills and the fixture's project skill. Personal .codex/skills were absent. |
| Same with skip_host_skill_discovery | No observed change: personal skills still appeared. This flag is not a demonstrated solution. |
| Private process HOME and CODEX_HOME | Personal .agents and personal .codex skill paths were absent; PROJECT_SKILL_SENTINEL from the fixture remained visible. |
| Existing login via auth.json symlink | codex login status exited 0 and reported ChatGPT authentication; no credential contents were printed. |
| Live start and exact resume | Both exited 0 with turn.completed. The tracked Kogen Stop hook passed twice with the same session id, 01a0897a-befb-7591-8353-c4b4a04ab019. |
| Hook environment before restoration | Hook HOME was the private process home despite shell_environment_policy.set.HOME pointing at the ordinary home. Hooks need their own narrow restoration. |
| Corrected tool-environment live probe | Shell printed ordinary HOME and XDG_CONFIG_HOME, retaining private CODEX_HOME. The wrapped tracked Stop hook also used ordinary HOME and passed. Session id: 01a0897f-1f61-7921-9add-28baac60f83a. |
| Synthetic credential write | In entirely synthetic source/owned directories, login --with-api-key exited 0, preserved the auth symlink and updated the synthetic target. This used a fake string, not the account's credentials. |

The live hook records contained target check, status passed, matching session
identity and the expected fixture output probe-check-passed. The check target
only echoed that marker; it did not run the full repository check or live suite.

## Setup and reproduction outline

1. Create an ignored disposable directory with separate fixture, codex-home and
   user-home children. Initialize and commit the fixture; assert its Git root.
2. Add a README and a project-local skill with a unique marker. Copy the tracked
   hooks.json, check.sh and verification_policy.py into the fixture. Provide a
   small real check target and ignore its .kogen/runtime output.
3. In codex-home generate only file credential-store selection and trust for
   the exact fixture path. Link only auth.json to the existing file-backed
   login for the authenticated probe. Do not copy the personal config directory.
4. Compare codex --disable plugins --disable apps debug prompt-input with an
   ordinary versus private process HOME. Inspect presence/absence booleans for
   skill paths and the project marker; do not publish the raw personal prompt.
5. Use codex exec and exec resume with the configured model/effort, hooks
   enabled and the existing bypass flags. Ask for a marker and no tools. Inspect
   turn.completed plus the actual Kogen verification records.
6. Configure shell_environment_policy.set with the caller HOME and its intended
   tool XDG environment. A fixture wrapper records hook HOME and invokes the
   unchanged tracked Stop script. Compare before and after restoring hook HOME.
7. For the focused shell probe, pass KOGEN_ROLE=developer, the exact fixture
   KOGEN_PROJECT_ROOT and normalized KOGEN_VERIFICATION_TARGETS containing both
   check and live. Ask for only HOME/CODEX_HOME/XDG_CONFIG_HOME, not the whole
   environment. Inspect command output and Stop evidence.
8. Test auth writes only in synthetic directories with fake credential strings;
   compare bridge/source structure without printing values. Remove the real
   credential bridge after the bounded probe, leaving the source untouched.

## Corrections and limits

Two preliminary shell probes were blocked by Kogen's real PreToolUse policy:
the first omitted verification targets and the second omitted the mandatory
live entry. Their Stop checks still passed. These were fixture setup errors,
not successful shell-environment evidence. The corrected probe supplied the
normal Kogen policy environment and executed the command successfully. One
model's prose mislabeled the denial as automatic approval review; the actual
stderr identified Kogen's PreToolUse policy.

No forced OAuth refresh, interactive TUI turn or native helper was run in this
bounded probe. Synthetic credential saving is evidence of observed write
behavior, not proof of every token-refresh path. Fake launch tests and these
primitives cannot replace the full live acceptance scenarios.

Read-only repository research identified lib/kogen/harness.ex as the shared
launch point but found separate environment injection in Shaping's Port path,
Developer run_turn and Reviewer launch. Existing harness role/argument tests,
Stop-hook tests and disposable live lifecycle are the relevant seams. An
independent expert found no documented personal skill-root exclusion that
preserves ordinary process HOME; per-skill disable inventories would leave
dynamic-discovery questions. The real private-HOME probe resolved that design
uncertainty without installing another Codex binary.

Raw local probe output remains ignored and is not part of this Intent. This
note is the maintained, credential-free evidence summary.
