# expo

Expo is an Elixir library for working with expo notifications, providing a clean API for sending push notifications to Expo-managed mobile applications.

## Quick Start

Add expo to your `mix.exs`:

```elixir
def deps do
  [
    {:expo, "~> 1.1.1"}
  ]
end
```

Basic usage for sending notifications:

```elixir
# Send a notification
Expo.send_notification(
  to: "push_token_from_client",
  title: "Hello",
  body: "This is a notification"
)

# With more options
Expo.send_notification(
  to: "push_token_from_client",
  title: "Title",
  body: "Message body",
  data: %{"userId" => "123"},
  badge: 1,
  sound: "default"
)
```

## Core Concepts

### Push Tokens

Expo push tokens are strings that identify a device and app combination. They're obtained from the Expo client SDK on mobile devices and passed to your backend.

### Notification Structure

Notifications contain:

- **to**: Push token(s) - string or list of strings
- **title**: Notification title
- **body**: Notification message body
- **data**: Custom data object (arbitrary key-value pairs)
- **badge**: Badge count
- **sound**: Sound to play ("default", "notification" or custom)
- **ttl**: Time to live in seconds
- **expiration**: Unix timestamp for expiration
- **priority**: "default", "normal", or "high"

### Response Handling

`send_notification/1` returns `{:ok, response}` or `{:error, reason}`:

```elixir
case Expo.send_notification(to: token, body: "Test") do
  {:ok, response} ->
    IO.inspect(response.id)  # Ticket ID
  {:error, reason} ->
    IO.inspect(reason)
end
```

Use ticket IDs to later query notification delivery status.

## Configuration

Configure Expo in `config/config.exs`:

```elixir
config :expo,
  access_token: System.get_env("EXPO_ACCESS_TOKEN")
```

Alternatively, pass token per request:

```elixir
Expo.send_notification(
  to: token,
  body: "Test",
  access_token: "your_token"
)
```

### Access Token

Obtain from https://expo.io/settings/access-tokens. Typically stored as environment variable `EXPO_ACCESS_TOKEN`.

## Best Practices

### Batch Operations

For multiple recipients, pass a list to `to`:

```elixir
tokens = ["token1", "token2", "token3"]
Expo.send_notification(
  to: tokens,
  title: "Batch Message",
  body: "Sent to multiple users"
)
```

Expo will handle batching efficiently.

### Error Handling

Handle different failure types:

```elixir
case Expo.send_notification(to: token, body: msg) do
  {:ok, response} ->
    Logger.info("Sent: #{response.id}")
  {:error, :invalid_token} ->
    Logger.warn("Invalid token: #{token}")
  {:error, :device_not_registered} ->
    # Remove token from database
  {:error, reason} ->
    Logger.error("Failed: #{inspect(reason)}")
end
```

### Deduplication & Idempotency

Use `id` field to prevent duplicate notifications:

```elixir
Expo.send_notification(
  to: token,
  body: "Message",
  id: "unique_message_id_123"
)
```

### TTL Management

Set appropriate TTL for notification persistence:

```elixir
Expo.send_notification(
  to: token,
  body: "Time-sensitive",
  ttl: 300  # 5 minutes
)
```

### Custom Data

Pass arbitrary data to client app:

```elixir
Expo.send_notification(
  to: token,
  title: "Order Update",
  body: "Your order is ready",
  data: %{
    "orderId" => "order_123",
    "screen" => "orders"
  }
)
```

### Token Validation

Always validate tokens before sending. Invalid tokens should be removed from your database.

## Common Pitfalls

- **Missing Access Token**: Configure `EXPO_ACCESS_TOKEN` environment variable or pass in each request
- **Expired Tokens**: Tokens can become invalid; implement token refresh on client side
- **Invalid JSON in Data**: Ensure `data` field contains valid JSON-serializable values
- **Network Timeouts**: Wrap requests in timeout logic for production reliability
- **Rate Limiting**: Be aware of Expo API rate limits; implement backoff strategies

## Version Notes

v1.1.1 is a stable release with support for standard Expo push notification features. Check Expo's official API docs for any breaking changes when upgrading from earlier versions.

---

**Version:** 1.1.1  
**Source:** https://github.com/tonyforeman/expo  
**Generated:** 2026-06-17
