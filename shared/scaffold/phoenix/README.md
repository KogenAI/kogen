# Phoenix Scaffold

Standalone entrypoint to scaffold a Phoenix app without the build platform.

## Prerequisites

- Elixir + Mix (`mix --version`)
- `phx_new` archive installed (`mix archive | grep phx_new`)
- Node.js + npm
- Python 3 (for multi-line mutation scripts)

## Usage

```bash
# 1. Run phx.new first (the platform does this before calling scaffold.sh)
mix phx.new my_app --app my_app --module MyApp \
  --binary-id --no-mailer --no-dashboard --no-agents-md --no-version-check --install

# 2. Run scaffold.sh against the generated dir
bash scaffold/phoenix/scaffold.sh my_app /path/to/my_app
```

### Flags

| Flag               | Default | Description                                    |
| ------------------ | ------- | ---------------------------------------------- |
| `--elixir-version` | 1.19.5  | Elixir version for .tool-versions / .mise.toml |
| `--node-version`   | 24.14.0 | Node version                                   |
| `--otp-version`    | 28.4.1  | OTP version                                    |

## What scaffold.sh does

1. Renders 14 `.eex` templates from `templates/` into `<target_dir>/`
2. Runs 9 mutation scripts from `mutations/` in fixed order:
   `mix_exs.sh` → `config_exs.sh` → `prod_exs.sh` → `formatter_exs.sh` → `gitignore.sh`
   → `router.sh` → `endpoint.sh` → `telemetry.sh` → `data_case.sh`
3. Creates `priv/plts/.keep`

All mutations are idempotent — re-running on an already-scaffolded dir is safe.

## Byte-for-byte parity promise

The output of `scaffold.sh` must be byte-identical to what `mix optimum.gen.infra` + 8
platform patch fns produce, EXCEPT:

- No AppSignal block in `config/config.exs`, `config/runtime.exs`, `config/prod.exs`
- No `rel/overlays/bin/server` (phx.gen.release not run)

## Phoenix-version bump procedure

When upgrading Phoenix:

1. Run `mix phx.new smoke_app /tmp/smoke_app --binary-id --no-mailer --no-dashboard --no-agents-md --no-version-check --install`
2. Run `bash scaffold.sh smoke_app /tmp/smoke_app`
3. Run `cd /tmp/smoke_app && mix deps.get && mix compile`
4. Verify all checks pass
5. Update `@elixir_version`/`@otp_version`/`@node_version` defaults in `scaffold.sh` and in the platform's app module
6. Commit both repos
