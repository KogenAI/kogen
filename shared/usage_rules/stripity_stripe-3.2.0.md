# stripity_stripe

Stripity Stripe is an Elixir library providing comprehensive integration with the Stripe payment processing API. It enables secure payment handling, subscription management, and financial transaction processing in Elixir applications with idiomatic bindings and full support for Stripe's Payment Intents and Setup Intents workflows.

## Quick Start

### Installation

Add to your `mix.exs`:

```elixir
{:stripity_stripe, "~> 3.2"}
```

### Basic Configuration

Set your Stripe API key in `config/config.exs`:

```elixir
config :stripity_stripe, api_key: System.get_env("STRIPE_SECRET")
```

Alternative configurations:

```elixir
# Direct string
config :stripity_stripe, api_key: "sk_test_abc123..."

# MFA tuple (module, function, args)
config :stripity_stripe, api_key: {MyApp.Secrets, :stripe_key, []}

# Anonymous function
config :stripity_stripe, api_key: fn -> System.get_env("STRIPE_SECRET") end
```

### Making Your First API Call

```elixir
{:ok, customer} = Stripe.Customer.create(%{email: "user@example.com"})
{:error, reason} = Stripe.PaymentIntent.create(%{amount: 2000, currency: "usd"})
```

All functions return `{:ok, result}` or `{:error, reason}` tuples.

## Core Concepts

### Payment Intents (Recommended)

Payment Intents represent a single transaction with built-in fraud detection, SCA/3D Secure support, and idempotency. Always use Payment Intents for new implementations.

```elixir
# Create intent on backend, pass client_secret to frontend
{:ok, intent} = Stripe.PaymentIntent.create(%{
  amount: 5000,
  currency: "usd",
  customer: customer_id
})

# Confirm intent with payment method (frontend sends client_secret + method)
{:ok, intent} = Stripe.PaymentIntent.confirm(intent.id, %{payment_method: method_id})
```

### Setup Intents

Setup Intents save payment methods for future charging without immediately processing a payment. Create a new SetupIntent each time users reach your payment page.

```elixir
{:ok, setup_intent} = Stripe.SetupIntent.create(%{
  customer: customer_id,
  payment_method_types: ["card"]
})

# Frontend uses client_secret to confirm with payment method
# Later: charge using saved payment method
{:ok, payment_intent} = Stripe.PaymentIntent.create(%{
  amount: 3000,
  currency: "usd",
  customer: customer_id,
  payment_method: saved_method_id,
  off_session: true
})
```

### Object Expansion

Retrieve related nested objects directly instead of receiving only IDs:

```elixir
# Without expansion: customer is an ID string
{:ok, payment_intent} = Stripe.PaymentIntent.retrieve(intent_id)

# With expansion: customer is a full Customer object
{:ok, payment_intent} = Stripe.PaymentIntent.retrieve(intent_id, expand: ["customer"])
```

## Configuration

### Connection Pool

Tune HTTP connection behavior:

```elixir
config :stripity_stripe, :pool_options,
  timeout: 5_000,
  max_connections: 10

# Disable pooling entirely
config :stripity_stripe, use_connection_pool: false
```

### Timeouts and Retries

Configure Hackney HTTP client behavior:

```elixir
config :stripity_stripe, hackney_opts: [
  {:connect_timeout, 1000},
  {:recv_timeout, 5000}
]

config :stripity_stripe, :retries,
  max_attempts: 3,
  base_backoff: 500,
  max_backoff: 2_000
```

### API Version

Stripe allows pinning to specific API versions:

```elixir
config :stripity_stripe, api_version: "2023-10-16"
```

## Best Practices

**Use Payment Intents, not legacy tokens** — Token-based payments lack SCA/3D Secure support and are restricted in Europe. Always prefer Payment Intents and SetupIntents for new features.

**Create fresh SetupIntents on each session** — Don't reuse SetupIntent objects across user sessions. Create a new one each time the payment page loads.

**Pass required parameters as function arguments** — Only optional parameters go in keyword lists. Required parameters should be explicit function arguments for clarity.

**Optimize expansion usage** — Use the `:expand` option strategically to avoid oversized API responses. Expand only when you need the full nested object.

**Handle errors gracefully** — Pattern-match on `{:error, reason}` tuples. Common errors include invalid tokens, insufficient funds, and 3D Secure failures.

**Implement idempotency keys** — For critical operations, include an idempotency key to prevent duplicate charges from network retries.

```elixir
{:ok, charge} = Stripe.Charge.create(%{
  amount: 1000,
  currency: "usd",
  source: token_id
}, idempotency_key: "unique-charge-#{user_id}-#{timestamp}")
```

**Store customer IDs** — Always save the Stripe customer ID in your database. Use it for future charges and subscription management rather than storing payment methods directly.

---

**Version:** 3.2.0
**Source:** [hexdocs.pm/stripity_stripe](https://hexdocs.pm/stripity_stripe/)
**Generated:** 2026-04-25
