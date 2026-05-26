# Combobulate Stripe Paywall Recipe

Accept one-time payments in Combobulate-hosted app. App owners connect their Stripe account via OAuth; users pay directly to connected account. Platform handles everything — no Stripe keys in your app.

> **See also**: `COMBOBULATE_SERVICES.md` for APP_ID/API_KEY embedding conventions.

---

## Prerequisites

1. App must be built with `has_stripe: true` in its config.
2. After build, Combobulate sends a WhatsApp message with Stripe connect link. Click it to link Stripe account.

---

## Buy Button (JavaScript)

Add to any page to trigger Stripe Checkout session:

```html
<button id="buy-btn" data-price-cents="1000" data-product="Premium Access">
  Buy Now
</button>

<script>
  const APP_ID = "{{APP_ID}}"; // paste real APP_ID from APP CREDENTIALS block in system prompt
  const API_KEY = "{{API_KEY}}"; // paste real API_KEY from APP CREDENTIALS block in system prompt

  document.getElementById("buy-btn").addEventListener("click", async () => {
    const btn = document.getElementById("buy-btn");
    btn.disabled = true;
    btn.textContent = "Loading...";

    const resp = await fetch(
      `https://app.combobulate.dev/api/payments/${APP_ID}/checkout`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${API_KEY}`,
        },
        body: JSON.stringify({
          price_cents: parseInt(btn.dataset.priceCents),
          product_name: btn.dataset.product,
          user_email: null, // optional: pre-fill email
          success_url: `${window.location.origin}/success?session_id={CHECKOUT_SESSION_ID}`,
          cancel_url: window.location.href,
        }),
      },
    );

    if (resp.status === 402) {
      alert("Payments not set up yet — contact the site owner.");
      btn.disabled = false;
      btn.textContent = "Buy Now";
      return;
    }

    const data = await resp.json();
    window.location.href = data.session_url;
  });
</script>
```

---

## Success Page

After payment, Stripe redirects to your `success_url` with `?session_id=...`. Verify payment:

```html
<!-- /success.html -->
<div id="status">Verifying payment...</div>

<script>
  const APP_ID = "{{APP_ID}}"; // paste real APP_ID from system prompt
  const API_KEY = "{{API_KEY}}"; // paste real API_KEY from system prompt

  const params = new URLSearchParams(window.location.search);
  const sessionId = params.get("session_id");

  if (!sessionId) {
    document.getElementById("status").textContent = "No session found.";
  } else {
    fetch(
      `https://app.combobulate.dev/api/payments/${APP_ID}/status?session_id=${sessionId}`,
      { headers: { Authorization: `Bearer ${API_KEY}` } },
    )
      .then((r) => r.json())
      .then((data) => {
        const el = document.getElementById("status");
        el.textContent = data.completed
          ? "Payment confirmed! Thank you."
          : "Payment not yet confirmed — please wait a moment and refresh.";
      });
  }
</script>
```

---

## PaymentGate Plug (Phoenix apps)

Gate any Phoenix route behind a completed payment:

```elixir
# lib/my_app_web/plugs/payment_gate.ex
defmodule MyAppWeb.PaymentGate do
  @moduledoc """
  Plug that checks whether the current session has a completed purchase.
  Redirects to the buy page if not.
  """

  import Plug.Conn
  import Phoenix.Controller

  @app_id Application.compile_env!(:my_app, :combobulate_app_id)
  @api_key Application.compile_env!(:my_app, :combobulate_api_key)
  @platform_url "https://app.combobulate.dev"

  def init(opts), do: opts

  def call(conn, _opts) do
    session_id = get_session(conn, :payment_session_id)

    if session_id && paid?(session_id) do
      conn
    else
      conn
      |> redirect(to: "/buy")
      |> halt()
    end
  end

  defp paid?(session_id) do
    url = "#{@platform_url}/api/payments/#{@app_id}/status?session_id=#{session_id}"

    case Req.get(url, headers: [{"Authorization", "Bearer #{@api_key}"}]) do
      {:ok, %{status: 200, body: %{"completed" => true}}} -> true
      _other -> false
    end
  end
end
```

Wire in router:

```elixir
# lib/my_app_web/router.ex
pipeline :paid do
  plug MyAppWeb.PaymentGate
end

scope "/members", MyAppWeb do
  pipe_through [:browser, :paid]
  get "/", MembersController, :index
end
```

Store session_id after Stripe redirects:

```elixir
# lib/my_app_web/controllers/success_controller.ex
def index(conn, %{"session_id" => session_id}) do
  conn
  |> put_session(:payment_session_id, session_id)
  |> render(:index)
end
```

---

## Webhook Setup

Stripe sends `checkout.session.completed` events to:

```
POST https://app.combobulate.dev/api/payments/:app_id/webhook
```

Handled automatically by platform — no webhook code needed in your app.

---

## Notes

- `price_cents` is in the smallest currency unit (cents for USD). `1000` = $10.00.
- Automatic tax (VAT/GST) is enabled on all sessions.
- `{CHECKOUT_SESSION_ID}` in `success_url` is replaced by Stripe automatically.
- Replace every `{{APP_ID}}` and `{{API_KEY}}` with real values from APP CREDENTIALS block in system prompt. Do not leave template placeholders in shipped code.
- See `COMBOBULATE_SERVICES.md` for full embedding pattern.
