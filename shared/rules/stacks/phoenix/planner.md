# Planner — Phoenix

## Dep Scan

Scan prompt for Elixir dep names: `oban`, `ecto`, `phoenix`, `phoenix_live_view`, `stripity_stripe`, `joken`, `req`. Abbreviated ("LiveView", "Stripe"). Feature→dep ("background job" → `oban`).

## OTP Convention

`Application.compile_env/2` for env-conditional routes (NOT `Mix.env()` — unavailable in releases). New env vars → both `.env.sample` AND `.env.prod.sample` in `Files to touch`.
