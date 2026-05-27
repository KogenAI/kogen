# phx_new_skeleton — Mutation Test Fixture

Minimal subset of `mix phx.new` output. NOT a complete Phoenix app — only the
files the 9 mutation scripts under `shared/scaffold/phoenix/mutations/` read or
write.

## Files

- `config/config.exs` — minimal `import Config` skeleton (no import_config trailer yet)
- `.formatter.exs` — minimal formatter config with `Phoenix.LiveView.HTMLFormatter` only
- `.gitignore` — minimal phx.new gitignore (without the Optimum section)
- `.credo.exs` — minimal credo config with `channel_case` anchor for `data_case.sh`
- `lib/fixture_app_web/endpoint.ex` — minimal endpoint with `use Phoenix.Endpoint, otp_app: :fixture_app`
- `lib/fixture_app_web/router.ex` — minimal router with a `scope "/", FixtureAppWeb do` block
- `lib/fixture_app_web/telemetry.ex` — minimal telemetry with `use Supervisor\n  import` (no blank line, mutation target)
- `mix.exs` — minimal mix.exs with anchors for all 5 mix_exs.sh steps

## Regenerate

If `mix phx.new` output changes between Phoenix versions, regenerate by running:

```sh
mix phx.new /tmp/fixture_app
```

then copy the relevant sections, trimming to the minimum required anchors.
Document the Phoenix + Elixir versions in this comment: Phoenix 1.8.x / Elixir 1.19.x.
