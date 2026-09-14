# Synthetic Codex authentication-file probe

Observed 2026-09-10 with the executable resolved from `PATH`:
`/Users/almirsarajcic/.local/share/mise/installs/node/24.20.0/bin/codex`.
Reported version: `codex-cli 0.154.0`.

## Method

Read `codex login --help` and `codex logout --help`, then ran only `codex login`
`--with-api-key` and `codex logout` in fresh directories created by `mktemp -d`
under `/tmp/kogen-synthetic-auth.*`. Each invocation used `env -i`, a private
`HOME` and `CODEX_HOME`, a private `config.toml` selecting
`cli_auth_credentials_store = "file"`, a minimal executable `PATH`, and a
clearly fake API-key value supplied on stdin. No provider turn was started. No
real authentication file was read, copied, linked, modified, or named.

The probe printed only exit statuses and file-type/equality booleans. Source and
replacement synthetic values differed for the copy/link comparison.

## Results

| Arrangement | `login --with-api-key` | `logout` |
| --- | --- | --- |
| Separate private auth file | Exit 0; created a regular `auth.json`. | Exit 0; removed that `auth.json`. |
| Copy-once auth file | Exit 0; target remained a regular file. The synthetic source stayed byte-equal to its pre-replacement snapshot. | Exit 0; removed only the copied target. Source remained byte-equal and regular. |
| Symlinked auth file | Exit 0; bridge remained a symlink, and its synthetic target differed from its pre-replacement snapshot. | Exit 0; removed the symlink itself. The synthetic target remained a regular file. |

## Implications and limits

For this CLI/version and file credential-store configuration, API-key login
follows a symlink and writes its target; logout removes the link rather than the
target. A copied file is independent of its original source.

This is **API-key file-write and logout evidence only**. It is not evidence that
ChatGPT OAuth token refresh, access-token login, keychain/encrypted stores,
interactive device login, or future Codex versions preserve the same behavior.
