# Role write boundary on macOS: probes (2026-09-25)

Driver-delegated Shaping visit, after the Shaper's "Keep it in #5" (BLD-12 stays in
this Intent). The question: which mechanism makes every Build role process tree
(Claude Code and Codex, their helpers, hooks including Stop and its `make`
descendants) physically unable to write outside the Build's worktree, harness home,
temp dir and retained-evidence paths, on this host?

Host: macOS 26.6.2 (25G83), arm64. Runtimes: managed Claude Code 2.1.281, managed Codex
0.156.1. All probes ran under `/private/tmp/claude-501/kogen-prep5b/probe/` (several paths
contain a space). No repository source was changed. The probe scripts, their raw
outputs and the rendered profiles are in `write-boundary-probe/`. The kernel's denial
log was read with
`log show --predicate 'eventMessage CONTAINS "deny(1) file-write"'`.

Paid usage: probes 4, 5, 13 and 16 made real Claude Code calls (claude-sonnet-5 at low
effort, about $0.09 + $0.07 + $0.06 + $0.30). The real Codex probe (19) is gated on the
absence of `~/Areas/Kogen/kogen/.kogen/build.lock` (lesson 10). Its status is at the end.

**Load incident.** Probes 9 and 16 ran Kogen's whole `make check` (probe 16 ran it
through its Stop hook, repeatedly) while a Build was running in the main checkout. The
driver reported a load average of 19 to 23, and the Build's timed offline tests timed
out. Every probe process was stopped at once. After that only reads and edits were
done while the lock existed.

## Mechanism chosen

`/usr/bin/sandbox-exec -p <profile> <harness> <args>` around every Build role launch.
It is a macOS Seatbelt profile applied by the kernel at exec. Every descendant
inherits it, and the kernel refuses to replace it from inside. Profile shape
(`write-boundary-probe/profile-*.sb`):

```scheme
(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath "<Candidate>") (subpath "<harness home>") (subpath "<Build temp>")
  (subpath "<KOGEN_RAW_LOG_DIR, when set>")
  (subpath "<Claude scope>/.oauth_refresh.lock")
  (literal "<login keychain>") (prefix "<login keychain>.sb-")
  (subpath "<Codex scope>")                         ; Codex-using routes
  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/tty") (literal "/dev/ptmx")
  (literal "/dev/dtracehelper") (regex #"^/dev/fd/[0-9]+$") (regex #"^/dev/ttys[0-9]+$"))
(deny file-write*                                   ; inside the Codex scope
  (literal "<scope>/hooks.json") (subpath "<scope>/plugins") (subpath "<scope>/rules")
  (subpath "<scope>/config.d") (literal "<scope>/AGENTS.md") (literal "<scope>/AGENTS.override.md")
  (literal "<scope>/environments.toml") (subpath "<scope>/agents") (literal "<scope>/.kogen-owned"))
(allow process-exec (with no-sandbox) (literal "/bin/ps"))
(deny lsopen)
(deny appleevent-send)
```

## Results

| # | Probe | Result |
|---|---|---|
| 1 | Basics (`probe1-basics.sh`) | Inside, harness-home and temp writes succeed. Outside writes fail with EPERM ("Operation not permitted") for a direct `sh` write, a Python child, a `make` grandchild, a `/tmp/…` alias of an outside path, a symlink in the Candidate pointing outside, hardlink creation to an outside file, renaming an outside file in, unlink, chmod, touch (utimes), xattr and mkdir. A daemonized background child that outlives its parent is also refused. |
| 2 | Nesting (`probe2-nesting.sh`) | Inside a profile, `sandbox-exec` with the **identical** profile and parameters succeeds. Any different profile, narrower, wider or allow-default, fails with `sandbox_apply: Operation not permitted` (exit 71). Unconfined, the same allow-default profile applies (exit 0). So the kernel self-test "apply `(version 1)(allow default)` to `/usr/bin/true`" exits 71 only inside a sandbox, and a nested fixture Build can't apply its own boundary inside a role's. |
| 3 | Claude Code readiness inside the profile | `claude --version` works. `claude auth status` with the per-Build `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR=<shared scope>`: `loggedIn: true, claude.ai`. No denials. |
| 4 | Real Claude turn, default temp | Write tool inside: ok. Write tool outside: `EPERM ... open '<outside>/write-outside.txt.tmp...'`. The Stop hook's `make` writes inside (exit 0) and is refused outside (exit 1). **Every Bash call failed**: Claude Code's Bash tool creates `/private/tmp/claude-501/<cwd>` (default `CLAUDE_CODE_TMPDIR` is `/tmp`), which is refused. |
| 5 | Same with `CLAUDE_CODE_TMPDIR=<harness home>/tmp` | Write inside ok, Bash inside ok. Write, Bash, the helper agent (`kogen-worker` subagent) and Python to `$HOME` outside are all refused with EPERM. The Stop hook's `make` is refused outside. Remaining denials are the user's zsh rc (`~/.zcompdump`, `~/.cache/oh-my-zsh`, mise state) and zsh here-document temp files in `/private/tmp/zsh*`. The turn is unaffected. |
| 6 | Linked worktree of a Kogen clone as Candidate: git and mix | `git status` and `git diff` work. `git add`, `commit`, `stash` and `checkout -b` fail (`Unable to create '<control>/.git/worktrees/cand/index.lock': Operation not permitted`). `git update-ref` fails (refs lock), and so does `git config` (config lock). Writes to control's tracked file and `.git/` fail. `MIX_ENV=test mix compile` works (cold, deps copied). |
| 7 | `mix test` inside the profile | `/bin/ps` exec fails: setuid binaries can't run inside a sandbox (`execvp() of '/bin/ps' failed: Operation not permitted`). It is used by `lib/kogen/codex/state.ex:160`, `test/support/isolated_process.py:41` and `priv/kogen/codex/compatibility/*.py`. Fixed with `(allow process-exec (with no-sandbox) (literal "/bin/ps"))`, and a later outside write is still refused. The pty tests then needed `/dev/ptmx`. After both, `harness_role_test` (5), `codex_environment_test` (13), `claude_code_harness_test` (17), `shape_task_test` (16) and `build_preconditions_test` (300) pass identically inside and outside. |
| 8 | setuid list | `/bin/ps`, `/usr/bin/{top,sudo,su,login,at,atq,atrm,batch,crontab,newgrp,quota}`, traceroute, authopen and security_authtrampoline are all setuid. Inside the profile none can exec, which closes the `sudo`, `crontab` and `at` routes. Only `/bin/ps` is re-allowed, and it writes nothing. |
| 9 | Kogen's whole `make check` at `363c20af` in a linked-worktree Candidate | Unconfined: exit 2, 800/805, 120 s. Inside the profile: exit 2, 800/805, 113 s. **The same five tests fail** in both, because of the spaced `TMPDIR` this probe used (`two_outer_resumptions` x2, `lifecycle` offline lifecycle, `harness_contract` codex adapter, `verification_policy` production PreToolUse). One denial was logged, from a test splicing an unquoted spaced path. Conclusion: today's suite doesn't need writes outside the grants, and the per-Build temp dir must be spaceless. |
| 10 | Codex 0.156.1 inside the profile, disposable `CODEX_HOME`, no credential | `--version` works. `login status` gives "Not logged in" (expected). `exec` reaches the API (401). On startup Codex writes into `CODEX_HOME`: `config.toml`, the state and log DBs, `sessions/`, `skills/.system`, `thread-writer-locks/`, `.tmp/plugins-clone*`, `installation_id` and `tmp/arg0`. **`codex sandbox -- …` inside the profile fails with `sandbox_apply: Operation not permitted`**, so Codex's own Seatbelt can't nest, and Kogen keeps `--dangerously-bypass-approvals-and-sandbox`. Unconfined, the same `codex sandbox` works and denies a Candidate write under its read-only default. |
| 11 | `mkdir` of an existing, non-granted directory | `EEXIST`, not EPERM. So Claude Code's `mkdir(<secure-storage dir>)` before taking its refresh lock is harmless. Creating the lock itself needs the grant. |
| 12 | Keychain write inside the profile (`security add-generic-password -U`, throwaway item) | Refused (exit 161). The kernel logs `deny file-write-create ~/Library/Keychains/login.keychain-db.sb-…`: keychain item writes happen in the writing process. A Claude Code OAuth refresh inside a role would lose the rotated token. With the login keychain file and its `.sb-` temp files granted (12b), add and update succeed, and any other file in `~/Library/Keychains/` is still refused. The throwaway item was deleted. |
| 13 | **The paid-proof mechanism** (real Claude, $0.06) | A fixture repo's own `.claude/settings.json` SessionStart hook, loaded through `--setting-sources project`, ran in the real Claude Code process tree on a fresh `-p` turn **and** on the exact `--resume`. Each time the write into the Candidate succeeded (`inside_exit: 0`) and the write into the control checkout's ignored `.kogen/runtime/` was refused (`outside_exit: 1`, kernel `deny file-write-create …/control/.kogen/runtime/escape-<pid>`). The transcript landed in the per-Build config dir. Receipts were written to the granted retained-evidence dir. |
| 14 | Non-canonical grant | A grant given as `/tmp/...`, an alias of `/private/tmp/...`, never matches: the write inside is refused. Grants must be canonical, or roles fail (closed). |
| 15 | Here-documents | zsh with only `TMPDIR` fails ("can't create temp file for here document"), because zsh uses `TMPPREFIX` (default `/tmp/zsh`). With `TMPPREFIX=<temp>/zsh` it works, and so does process substitution. `/bin/bash` and `/bin/sh` (bash 3.2) work when the cwd is the Candidate, but not from an outside cwd. |
| 16 | Real Claude turn with Kogen's own `--settings` on a Kogen Candidate ($0.30) | **Partly invalid.** Outside a real Build, Kogen's PreToolUse policy hook blocked every Bash call ("required verification policy targets are missing"), and the Stop hook repeatedly ran the whole `make check` (the load incident). Valid observations: the Write tool into the control checkout was refused (`EPERM … open '<control>/probe-control-write.txt.tmp…'`); the Stop hook's `make check` ran inside the profile and wrote only to the Candidate's `.kogen/runtime/`; nothing appeared in control or in the Claude scope. |
| 17 | Indirect escapes | `launchctl bootstrap gui/<uid> <plist in Candidate>` fails with exit 5 and `launchctl submit` with exit 1. The unconfined control of the same bootstrap ran the job and created the outside file, which was then booted out and removed. `open -a …` **succeeded** without a rule (it activated Terminal once), so the profile denies `lsopen`: with the rule, `open` fails with error -54. `osascript` Apple Events to Finder fail with `(deny appleevent-send)` (-600); the unconfined control works. |
| 18 | Codex scope carve-outs on a scope-shaped directory | Allowed: a rollout write, a history append, a `config.toml` write, and an `auth.json` refresh by write-and-rename. Refused: creating `hooks.json` (directly or by rename), `plugins/`, `rules/`, `config.d/` and `AGENTS.md`; overwriting or renaming away `environments.toml`; overwriting `agents/kogen_boundary.toml` or renaming `agents/`; deleting `.kogen-owned`. |

## Why not the alternatives

- **Harness permission layers** (Claude Code `permissions` and `sandbox`, Codex
  `--sandbox workspace-write`). They govern tool calls, not the harness process's own
  writes. Probe 4 shows the Write tool's write comes from the `claude` process itself.
  Kogen runs both harnesses with bypass flags. Codex's Seatbelt can't nest (probe 10).
  Changing Claude settings is off-limits for this Build (D9).
- **Deny-default profile.** It was tried 2026-09-18/19 in `prevent-intent-mutation`
  (archived evidence under `.kogen/runtime/shaping-followups/archive/drafts/prevent-intent-mutation/`).
  It needed `system-socket`, `file-ioctl` and more before a real turn worked. The
  Shaper's rule concerns writes.
- **Running the controller's verification inside the boundary.** That attempt failed
  47 tests on 2026-09-19, because nested fixture Builds couldn't apply their own
  profile (probe 2 confirms the kernel rule). Under Intent #4 the controller runs
  `make` itself, unconfined, so fixture Builds apply their own boundary.

## Codex with the real scope (probe 19, ran 23:28 after build.lock and the coordinator's RUNNING flag cleared)

`probe19-codex-real.sh` launched managed Codex 0.156.1 (gpt-6-luna, low) the way Kogen launches a
Codex role, inside the Codex rendering of the profile (`profile-codex-probe.sb`). `CODEX_HOME` was
the shared Kogen scope; the private HOME, XDG dirs, sqlite and executor entrypoint were under a probe
harness home; Kogen's flags were used, including both bypass flags. Results (`probe19.out`):

- `login status`: logged in (ChatGPT) inside the profile.
- Fresh turn completed (`turn.completed`). Its shell writes into the Candidate and the harness home
  exited 0. The write into the control checkout failed with `zsh:1: operation not permitted`, and
  `git -C <control> update-ref` failed with `Unable to create …/.git/refs/heads/escape.lock`.
- The exact resume of thread `01a0da41-…` completed ("resumed").
- The kernel denial log shows **only** those two refused attempts. Codex's own writes (rollouts,
  history, state databases, locks, bookkeeping in the scope; operation state in the harness home)
  all fell inside the grants.
- The scope's top-level entries were unchanged. Control had no new file and no new ref.

## Codex project SessionStart hook (probe 20, the Codex paid-proof mechanism)

`probe20-codex-sessionstart.sh` is probe 19 plus a fixture-only `.codex/hooks.json` with Kogen's PreToolUse Bash
entry and one `SessionStart` entry. Real Codex 0.156.1 ran the hook on the fresh `exec` and on
`exec resume`. Each run wrote its `TMPDIR` receipt (`inside_exit: 0`). The write into the control's
`.kogen/runtime/boundary-escape/` was refused (`outside_exit: 1`, and the kernel logged
`deny file-write-create …/boundary-escape/escape-<pid>`). The escape dir stayed empty, and the scope's
top-level entries were unchanged (`probe20.out`).
