# Per-Build harness home and credentials: source read and probe (2026-09-25)

Driver-delegated Shaping visit. Question: can each Build get its own harness
home without copying credentials and without losing a login? README rule:
"Claude Code keeps each scope's login in the macOS Keychain keyed by the scope
path, so never move or rename a scope directory" (`README.md:369-373` at
`2909f557`).

Runtimes read: managed Claude Code `2.1.281-darwin-arm64` and managed Codex
`0.156.1-darwin-arm64` under `~/Library/Application Support/Kogen/`.
Probes ran from a disposable directory under
`/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/probe/`
(paths with spaces), with `env -i` plus only `PATH`, `USER`, `LOGNAME`,
`TERM`, `HOME` (real unless stated) and the variables named below. Only
`loggedIn`/`authMethod` metadata was printed; no credential value was read.

## Claude Code source (strings of the managed binary)

The Keychain lookup (minified, verbatim apart from elisions):

```js
function aw(){let n=process.env.CLAUDE_SECURESTORAGE_CONFIG_DIR;
  if(n!==void 0)return(n||l(a(),".claude")).normalize("NFC");return we()}
function CL(n=""){let e=process.env.CLAUDE_SECURESTORAGE_CONFIG_DIR,
  t=e!==void 0?!e:!process.env.CLAUDE_CONFIG_DIR,
  r=e!==void 0?e.normalize("NFC"):we(),
  o=t?"":`-${c("sha256").update(r).digest("hex").substring(0,8)}`;
  return`Claude Code${dn().OAUTH_FILE_SUFFIX}${n}${o}`}
... security find-generic-password -a "${USER}" -w -s "${CL("-credentials")}"
```

and the OAuth refresh lock:

```js
let F=aw(); await ce().mkdir(F); ... lockfilePath: Id(e,".oauth_refresh.lock")
```

So:

1. The Keychain item is `Claude Code-credentials-<sha256(dir)[0:8]>` for account
   `$USER`, where `dir` is `CLAUDE_SECURESTORAGE_CONFIG_DIR` when set, else
   `CLAUDE_CONFIG_DIR`.
2. The refresh lock lives in the same `dir`. Every process that names the same
   secure-storage dir serializes refreshes of that one login through one lock,
   whatever its `CLAUDE_CONFIG_DIR` is.
3. `CLAUDE_SECURESTORAGE_CONFIG_DIR=""` (set but empty) drops the suffix and
   selects the **personal** unsuffixed item `Claude Code-credentials`.
4. Sessions (`projects/<encoded cwd>/<id>.jsonl`), `.claude.json`, backups and
   other state stay under `CLAUDE_CONFIG_DIR`.

Kogen's `ClaudeCode.environment/2` (`lib/kogen/claude_code.ex:79-95`) removes
the prefixes `ANTHROPIC_`, `CLAUDE_CODE_`, `CLAUDE_CONFIG_DIR`, `CLAUDECODE`
and two names. `CLAUDE_SECURESTORAGE_CONFIG_DIR` matches none of them, so an
inherited value reaches every Kogen Claude launch today.

## Probe results (`claude auth status`, no model call)

| Case | HOME | CLAUDE_CONFIG_DIR | CLAUDE_SECURESTORAGE_CONFIG_DIR | loggedIn |
|---|---|---|---|---|
| A | real | shared scope | unset | true (claude.ai) |
| B | private dir | shared scope | unset | **false** |
| C | private dir | fresh dir | unset | false |
| D | private dir | fresh dir | shared scope | **false** |
| D2 | real | fresh per-Build dir | shared scope | **true** (claude.ai) |
| E | real, private TMPDIR and XDG_* | shared scope | unset | true |
| F | real | fresh dir | `""` (empty) | **true: the personal login** |

`security list-keychains` with a private `HOME` lists only
`/Library/Keychains/System.keychain`; with the real `HOME` it lists the login
keychain first. **A per-launch `HOME` loses the Claude login** (B, D), even
with the right scope. That is why Kogen's Codex adapter can use a private
`HOME` (file credentials in `CODEX_HOME`) but Claude Code cannot.

Case F confirms item 3: the unsuffixed personal item exists on this host, and
an inherited empty variable authenticates a Kogen launch with it.

## Probe results (real model calls, bounded)

With real `HOME`, `CLAUDE_CONFIG_DIR=<probe>/per build cfg`,
`CLAUDE_SECURESTORAGE_CONFIG_DIR=<shared scope>`, cwd `<probe>/cand dir`
(a git repo whose path contains spaces), `--strict-mcp-config
--setting-sources project --max-turns 1 --output-format json`:

1. `claude-sonnet-5`, "Reply with exactly the word: ok": `is_error: false`,
   `result: ok`, session `3f72815e-…`.
2. `--resume 3f72815e-…` in the same cwd and config dir: `is_error: false`,
   same session id, the model recalled its earlier reply.
3. `claude-opus-5-5` at `CLAUDE_CODE_EFFORT_LEVEL=low`: `is_error: false`,
   `modelUsage` names only `claude-opus-5-5`.

The transcript was written to
`<per build cfg>/projects/-private-tmp-...-probe-cand-dir/3f72815e-….jsonl`;
nothing new appeared under the shared scope's `projects/`. The per-Build
`.claude.json` has no `oauthAccount`, so `auth status` shows no email, but
`loggedIn`/`authMethod` (all Kogen reads) are correct and model calls work.
Reported notional cost for the three calls: about $0.18 of subscription usage.

## Codex (source)

Kogen launches Codex with `cli_auth_credentials_store="file"`
(`lib/kogen/codex/environment.ex` `config_args/5`), so the login is
`auth.json` inside `CODEX_HOME` (the scope). The 0.156.1 binary exposes
`CODEX_HOME` and `CODEX_SQLITE_HOME` but no separate auth-home variable
(strings of the binary). Codex rollouts also live under `CODEX_HOME`. Kogen
already gives every Codex selection a private operation root with its own
`HOME`, `XDG_*` and sqlite (`Kogen.Codex.open/2` → `State.operation!/1`;
`Environment.prepare/6`), and shell tools get the caller's `HOME` back through
the executor entrypoint. A per-Build Codex home therefore means: that
operation root is created inside the Build's harness home, while `CODEX_HOME`
stays the scope, referenced by path. Splitting `auth.json` out would need a
copy, which Kogen never makes.

## Design consequence (adopted in the Draft)

- A Build's harness home is `<workspaces-root>/<project-id>/harness/<build-id>/`,
  outside both the Candidate and control.
- Claude roles of that Build: `CLAUDE_CONFIG_DIR=<harness home>/claude`,
  `CLAUDE_SECURESTORAGE_CONFIG_DIR=<the scope path resolved from control at
  admission>`, real `HOME`. The login is referenced, never copied, moved or
  renamed, and refreshes share the scope's lock with Shaping sessions.
- Every Claude launch (Build, Shape, login, status) removes an inherited
  `CLAUDE_SECURESTORAGE_CONFIG_DIR` and sets it explicitly (the scope path for
  a Build; for scope-native launches it equals `CLAUDE_CONFIG_DIR`, which gives
  the same Keychain item as today).
- Codex roles of that Build: the operation root lives in `<harness home>/codex`;
  `CODEX_HOME` stays the scope.
- Readiness for a Build runs `claude auth status` with the Build's own launch
  environment, so a future Claude Code that drops the override fails closed
  before any model launch ("not logged in"), and no Keychain item is touched.
- `CLAUDE_SECURESTORAGE_CONFIG_DIR` is an undocumented Claude Code variable.
  The Claude Code runtime-upgrade workflow must re-run cases A, D2 and F.
