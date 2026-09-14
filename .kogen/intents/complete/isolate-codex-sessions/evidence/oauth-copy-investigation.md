# Codex authentication copying: evidence and decision boundary

Investigated 2026-09-10. Read-only official documentation research; no private
authentication files or logs were read, no login was initiated, and no real
refresh or revocation was exercised. Only this research note was created.

## What official documentation establishes

[Authentication](https://learn.chatgpt.com/docs/auth) documents browser login,
automatic token refresh, file-backed credentials under `CODEX_HOME`, and copying
an existing authentication cache as a headless-machine fallback. Copying is a
supported transfer technique; the page does not describe it as issuing a new
independent login.

[Maintain Codex account auth in CI/CD](https://learn.chatgpt.com/docs/auth/ci-cd-auth)
documents keeping Codex's updated authentication file after refresh. It limits
the workflow to one machine or serialized job stream, advises against concurrent
sharing, and identifies token rotation by another machine or concurrent job as
a reason refresh can stop working. Repeated restoration of the original seed
can discard newer credentials. The guide recommends API keys for ordinary CI;
this investigation does not propose changing Kogen's chosen account access.

## Implications for Kogen (inferences, not additional documented guarantees)

- **Copy once:** creates separate local files containing the same initial token
  bundle. It cannot honestly be called a new login or a guarantee of independent
  refresh/revocation. Continuing personal use alongside that copy introduces the
  rotation risk described above.
- **Shared file or synchronized reuse:** preserves a shared authentication
  lifecycle. A symlink avoids permanently stale snapshots but does not itself
  coordinate concurrent refresh. Kogen's project invocation lock cannot serialize
  independently launched personal Codex clients. Do not promise safe concurrent
  refresh without additional evidence.
- **Fresh login into Kogen-owned credential storage:** best fits the desire for
  separate local credential ownership and avoids deliberately duplicating the
  existing token bundle. It requires a one-time authentication interaction. The
  fetched docs do not guarantee independence from account-wide revocation,
  workspace policy changes or service-side session limits.

## Human decision

For authentication independence, recommend a fresh ChatGPT login for Kogen with
its own persisted credentials. If avoiding another login matters more, retain
explicitly shared ownership and acknowledge refresh coupling. Do not present
copy-once as equivalent to independently authenticating.

No implementation, approval, migration or forced-refresh test is authorized by
this note. Exact login command wiring is a separate CLI compatibility probe.
