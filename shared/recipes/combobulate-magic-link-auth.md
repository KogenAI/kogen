# Combobulate Magic Link Auth

Shows how a Phoenix user app adds passwordless authentication via Combobulate platform. App uses `mix phx.gen.auth` to scaffold auth system, then swaps email delivery to call platform instead of sending emails directly. Session verification uses platform's RSA public key — no credentials stored in app.

## Problem

Phoenix apps need user auth but:

- Shouldn't hold email credentials (SMTP, Mailgun, etc.)
- Need passwordless/magic-link login (no passwords to manage)
- Want JWT-based sessions verifiable without calling back to platform

## Solution

1. Scaffold with `mix phx.gen.auth` (passwordless variant)
2. Replace `UserNotifier` to call platform magic link endpoint
3. Add `FetchCurrentUser` plug verifying JWTs with platform's public key

## Step 1 — Generate auth scaffold

```bash
mix phx.gen.auth Accounts User users --no-binary-id
mix ecto.migrate
```

Creates `UserToken`, `User`, `UserAuth` plug, session/registration LiveViews, and `UserNotifier` module for email delivery.

## Step 2 — Replace UserNotifier

Swap `lib/my_app/accounts/user_notifier.ex` to call platform magic link endpoint:

```elixir
defmodule MyApp.Accounts.UserNotifier do
  @platform_url "https://app.combobulate.dev"
  @app_id "<APP_ID>"      # use real APP_ID from APP CREDENTIALS block in system prompt
  @api_key "<API_KEY>"    # use real API_KEY from APP CREDENTIALS block in system prompt

  def deliver_login_link(user, url) do
    Req.post!(
      "#{@platform_url}/api/auth/#{@app_id}/request",
      json: %{email: user.email},
      headers: [{"Authorization", "Bearer #{@api_key}"}]
    )
    {:ok, %{to: user.email, body: url}}
  end
end
```

> Platform sends the email — app only triggers request. Magic link goes directly to `https://app.combobulate.dev/api/auth/:app_id/verify?token=...` and returns JWT on success.

## Step 3 — Add FetchCurrentUser plug

After user clicks magic link, platform returns JWT. App exchanges this for session by verifying JWT with platform's RSA public key:

```elixir
defmodule MyAppWeb.Plugs.FetchCurrentUser do
  import Plug.Conn

  @platform_url "https://app.combobulate.dev"
  @app_id "<APP_ID>"   # use real APP_ID from APP CREDENTIALS block in system prompt

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- verify_jwt(token) do
      assign(conn, :current_user, %{email: claims["sub"]})
    else
      _ -> assign(conn, :current_user, nil)
    end
  end

  defp verify_jwt(token) do
    with {:ok, pub_pem} <- fetch_public_key(),
         signer = Joken.Signer.create("RS256", %{"pem" => pub_pem}),
         {:ok, claims} <- Joken.verify(token, signer) do
      {:ok, claims}
    end
  end

  defp fetch_public_key do
    case Req.get("#{@platform_url}/api/auth/#{@app_id}/public_key") do
      {:ok, %{status: 200, body: %{"public_key" => pem}}} -> {:ok, pem}
      _ -> {:error, :unavailable}
    end
  end
end
```

> Cache the public key in ETS or a GenServer — don't fetch on every request.

## Step 4 — Handle the callback route

After magic link click, platform verifies token and returns JWT. Add callback LiveView or controller to receive JWT and establish session:

```elixir
# In router.ex
get "/auth/callback", AuthCallbackController, :callback

# In auth_callback_controller.ex
def callback(conn, %{"token" => jwt}) do
  conn
  |> put_session(:jwt, jwt)
  |> redirect(to: ~p"/dashboard")
end
```

## Platform endpoints used

| Endpoint                                 | Purpose                                   |
| ---------------------------------------- | ----------------------------------------- |
| `POST /api/auth/:app_id/request`         | Trigger magic link email                  |
| `GET /api/auth/:app_id/verify?token=...` | Verify token → returns JWT                |
| `GET /api/auth/:app_id/public_key`       | Fetch RSA public key for JWT verification |

### Request format for magic link

`POST https://app.combobulate.dev/api/auth/:app_id/request`

Headers: `Authorization: Bearer <api_key>`
Body: `{"email": "user@example.com"}`

Response: `{"ok": true}` (always — no email enumeration)

### JWT claims

```json
{
  "sub": "user@example.com",
  "app_id": "<app_id>",
  "jti": "<unique session id>",
  "iss": "combobulate",
  "exp": 1234567890
}
```

## Where to find APP_ID and API_KEY

- `APP_ID`: UUID from `apps` table (`id` column)
- `API_KEY`: Auto-generated in `api_key` column (unique per app)

Both provided in `APP CREDENTIALS` block of system prompt at build time. Copy into module attributes verbatim — do NOT leave `<APP_ID>` / `<API_KEY>` placeholders in source files.

## Related Recipes

- `combobulate-transactional-email.md` — sending transactional email via platform
- `COMBOBULATE_SERVICES.md` — service recipe conventions for all platform integrations
