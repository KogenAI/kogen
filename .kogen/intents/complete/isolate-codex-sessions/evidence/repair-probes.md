# Bounded repair probes after the latest failed Build

Same shaping visit: 2026-09-10T09:50:00.754357Z. These probes ran on the
unaccepted working implementation at main/bf68fd70, not on a newly assessed
committed baseline. Original provenance is unchanged. Shaper requested further
probing/investigation and repair of this Intent before resuming Build their way.

No production code, personal credentials, installation defaults, stashes or Build
state were changed. Probe scripts/fixtures and native output remain private under
`.kogen/runtime/reshaping-native-probe/`, `pty-probe-55406/`, and
`handoff_failure_yaml_probe/`. Only this concise evidence belongs in the Intent.
Provider calls used the already configured shared Kogen login, configured root
model gpt-6-astra/low, and a requested native scout gpt-5.6-luna/low. They were
focused probes, not repository gates or an accepting Review.

## Effective environment: negative controls

Using the real Environment.prepare output, a synthetic caller HOME, one set XDG
variable and three absent XDG variables, the 0.154.0 native runtime received
private discovery HOME/XDG and explicit shell_environment_policy settings.
A tiny Python command printed only HOME, CODEX_HOME, the four XDG values and an
added PROBE_SET sentinel. Both login=true and login=false commands retained the
private paths and lacked PROBE_SET. Removing probe-only ignore-user-config did
not correct it. Disabling unified_exec also did not correct it. Disabling
code_mode_host left tools unavailable; assigning a shell wrapper through SHELL
did not select that wrapper. None is a demonstrated repair.

The exact official 0.153.4 macOS arm64 distribution was staged privately through
the installer (no default activation). The same focused environment probe failed
there too. Therefore simply selecting the earlier version is not established as
a fix, and this evidence does not justify changing the initial release.

The current official configuration reference documents shell_environment_policy
as the subprocess control. Documentation/accepted flags do not establish effective
code-mode tool behavior: https://learn.chatgpt.com/docs/config-file/config-reference

## Native local execution process: positive control and limits

A temporary process from the exact same managed distribution ran:

    codex exec-server --listen ws://127.0.0.1:<ephemeral-port>

Its HOME/XDG represented the synthetic caller; its CODEX_HOME remained the same
Kogen scope and provider overrides remained sanitized. Only the private model
process received that owned URL in CODEX_EXEC_SERVER_URL. The shell receipt then
showed caller HOME/XDG (including absence) and the selected Kogen CODEX_HOME.
Both login modes passed. A command invoking /bin/sh inside the default shell
also inherited the correct environment.

A subsequent production-like probe used the tracked project hooks, an intentionally
requested make check denial, a bounded Stop-owned fixture Check, and a native
scout. Root, helper and hook JSON files all parsed and matched caller HOME/XDG
and selected CODEX_HOME. Root/helper catalog reports included the synthetic
project skill and excluded the synthetic personal skill. The gate request was
blocked by actual PreToolUse. No repository aggregate gate ran.

An exact Developer resume with a fresh owned executor endpoint returned the same
correct environment. Two passed Stop records matched that Developer session.
This demonstrates resume can receive a new owned endpoint; it is not evidence of
complete Build/Review/update integration or arbitrary concurrent operations.

IMPORTANT PROBE CORRECTION: preliminary runs added --ignore-user-config and
--ephemeral, unlike production. Their gate request ran. Repeating without those
flags restored actual hook denial locally AND with the executor. Do not cite that
preliminary result as an executor hook bypass. Do not add those flags to production
as an assumed equivalent isolation solution.

The tool-level explicit shell=/bin/sh request succeeds locally but was rejected
with the remote executor (which reported support for zsh). Invoking /bin/sh -c
inside the default shell works; these are not equivalent tool APIs. This observed
capability difference must be disclosed to the Shaper, not silently called full
native parity.

Local no-provider service probes established:

- Closing its owned stdin does not stop the local WebSocket service.
- --exit-on-stdin-close and its true-valued environment form require remote
  registration/environment-id; they do not solve the local lifetime.
- Explicit terminate/wait/kill ownership is required. All probe servers were stopped.
- WebSocket handshakes with browser Origin headers were rejected (403), while
  a no-Origin local client received unauthenticated 101. Loopback is not local
  client authentication. No remote registration was attempted.
- This is an experimental native command and CODEX_EXEC_SERVER_URL was not found
  in the stable public environment reference. It is a demonstrated candidate,
  not a documented stable guarantee or an accepted architectural decision yet.

## PTY completion and cleanup

A read-only worker reproduced a natural marker/exit race: Ctrl-C write raised
EIO after child terminal exit, then group signaling raised EPERM, preventing the
old driver from writing any receipt. A direct-owned PID kill plus bounded WNOHANG
wait successfully reaped a synthetic child. Group permission behavior varied by
race/context; no universal explanation for EPERM is claimed.

A temporary corrected driver (not production code) was tested with natural marker
exit, a quiet child ignoring INT/TERM, missing-marker timeout, forced group EPERM
and forced total signal denial followed by child self-exit. Each produced a
receipt and completed within a bound. Success required marker plus proven reap;
missing marker returned failure. A denied signal followed by observed natural
exit was distinguished from an unreaped child, rather than automatically hidden.

The root used that driver, with terminal cursor-query handling, for a real native
interactive Shaping turn. Observed: driver exit 0, marker true, child reaped,
native_exit -15 after owned termination. A deliberately terminated interactive
TUI need not exit 0 for a valid marker-and-cleanup probe. This proves one real
interactive path, not all descendants or crash cleanup. The existing outer test
supervisor remains the final descendant-cleanup owner; product update cannot
assume that a test-only supervisor exists.

A preliminary worker note incorrectly placed escalation inside the read-ready
branch. Source inspection corrected that assertion; do not implement a fix for
that nonexistent indentation problem. The actual issues are EIO/EPERM handling,
reap-before-signal, bounded cleanup and unconditional receipts.

## Continuation YAML

YamlElixir.read_from_file parsed the original fixture, rejected the retained
continuation at line 11/column 11, and parsed a private copy changing only four
spaces before shaping.effort to two. Original id, slug, shaping and shaped_against
values remained equal; exactly one complete continuation remained. The new
continuation list itself was not malformed.

The live Expect probe currently accepts substring shaping_continuations: before
it has parsed the file. Parsing before scripted approval and requesting a bounded
same-session correction preserves a real Shaper and the existing provenance
oracle. Automatic launcher rewriting or swallowing invalid YAML would not.

## Python prerequisite diagnostics

The public source checkout at original HEAD did not declare Python 3.11+. The
failed implementation added that prerequisite to README. Current shell python3
is /usr/bin/python3 3.9.6; import tomllib fails. /opt/homebrew/bin/python3 3.14.3
works. The production native_settings.py imports tomllib before its error handler;
State.native_projects! converts any nonzero script result into “unexpected
configuration”, misreporting the interpreter failure as a file problem.

Inspecting only shared config's top-level keys with the newer interpreter found
projects and tui, both recognized by the new parser. Environment.prepare then
succeeded with the newer Python first in PATH. No configuration deletion was
necessary. The permanent Python support decision remains with the Shaper;
interpreter failure and invalid file content must have distinct diagnostics.

### Subsequent accepted provisioning and verification

Later patch selection: after the Shaper installed 3.14.7 globally, the project
pin was updated to 3.14.7. `mise exec -- python3` reports that version and the
tomllib parse succeeds. The repeated Kogen status command could not run because
the current checkout no longer contains that Mix task; this is not a Python
failure. The successful status observation below belongs to the earlier working
implementation and must not be attributed to this later checkout.

The Shaper explicitly authorized installing/requiring necessary Python via mise
without older-version compatibility. Added project mise.toml selecting Python
3.14.3; minimum requirement remains 3.11+ for tomllib. Initial mise 2026.3.0 chose
a freethreaded archive and failed with missing lib directory. Updating mise to
2026.9.4 and repeating `mise use --pin python@3.14.3` installed the standard
distribution successfully. No global Python selection was changed.

`mise exec -- python3` reports 3.14.3 from mise's installed runtime and imports/
parses with tomllib successfully. `mise exec -- mix kogen.codex.status` exits zero,
reports managed 0.154.0 and configured shared native login. These are prerequisite
checks, not remote/model entitlement or a full Build gate. Build can use
`mise exec -- mix kogen.build isolate-codex-sessions` to select this already
installed project runtime even when shell activation has not updated PATH.
Keep the project mise.toml available in the checkout used for that command.

## Continued engineering investigation after Shaper direction

The Shaper directed the controller to resolve internals autonomously rather than
asking them to select an executor. A further real 0.154.0 command probe disabling
both shell_zsh_fork and unified_exec_zsh_fork still returned private HOME/XDG in
both login modes, with the policy set sentinel absent. Native features list
labels unified_exec_zsh_fork removed; accepting a disable argument does not
establish that it controls the effective runtime.

An independent expert demonstrated credential-free native stdio execution using
an isolated environments.toml and app-server environment/info. The executor
received synthetic caller HOME; closing the app-server input ended both processes.
This is a promising no-network-listener primitive. CLI/TUI integration and
concurrent account-scope configuration are separate questions still being probed;
do not extrapolate app-server success into a completed integration.

Subsequent expert probes confirmed ordinary CLI exec provisions the named stdio
default without a special flag. Two concurrent app-servers shared one static
registry/wrapper, used distinct caller markers, and both reaped their children.
After provisioning, native skills/list included account, project and each model
process's private-home sentinel, excluding both caller-personal sentinels and the
other invocation's private sentinel. Artifacts remain in
`.kogen/runtime/reshaping-native-probe/stdio-discovery/summary.json` and the adjacent
`probe_stdio_discovery.py`. The actual model/helper turn catalog is a separate
acceptance assertion. These observations support selecting stdio over TCP while
retaining, not relaxing, the existing real compatibility runner requirements.

Probe correction: the credential-free CLI startup test attempted to force an
unreachable local provider endpoint, but native WebSocket transport ignored that
override and attempted unauthenticated OpenAI connections (401). The expert stopped
the owned process group and did not repeat it. No credentials were supplied and no
inference succeeded. Do not describe that particular startup check as network-free.

## Earlier semantic positive fixture is already corrected

Before that audit, the final credential-free protocol check used native stdio
initialize/initialized, process/start and process/read to run an actual Python
receipt. It retained caller HOME, selected synthetic CODEX_HOME, two set XDG paths,
one empty-string XDG value and one absent XDG value. Process and owner exited zero.
Native login --help exited zero; login status returned the expected Not logged in
and exit 1 for the empty synthetic scope. Artifacts: stdio-contract/summary.json,
process-responses.json, probe_stdio_contract.py and probe_stdio_process.py under
the same private probe directory. No provider requests or shared-account edits.

Do not use app-server command/exec as proof of named-environment tool routing:
that method is host-local and reports local environment is not configured with
include_local=false. Direct executor protocol receipts prove subprocess inheritance;
the Build's real model-tool fixture must prove named routing. This remains an
explicit acceptance requirement, not an already-passed check.

A focused worker audit traced the old Reviewer rework to real missing controls,
not a reason to soften Review. Current test/support/scenario_semantic.ex rejects
extra role-routing arguments and tests worktree/index content divergence; the
corrected fixture now implements both. The retained latest semantic-corrected-
review.json under live-evidence/primitives-47499-698-1789038140779776959 records
accept with all three scenarios satisfied, paired with rework for the incomplete
candidate. Preserve these fixes and controls; no additional product choice or
new semantic-fixture redesign is required for that historical failure.
