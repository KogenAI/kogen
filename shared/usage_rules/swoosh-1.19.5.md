# swoosh

Swoosh is an Elixir email composition and delivery library supporting 25+ email providers with flexible configuration, testing utilities, and async/telemetry integration.

**Requirements:** Elixir 1.13+ and Erlang OTP 24+

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
def deps do
  [
    {:swoosh, "~> 1.19"}
  ]
end
```

### Basic Email Sending

```elixir
# Create a mailer module in your app
defmodule MyApp.Mailer do
  use Swoosh.Mailer, otp_app: :my_app
end

# Send an email
email =
  new()
  |> to({"recipient@example.com", "Recipient Name"})
  |> from({"noreply@example.com", "MyApp"})
  |> subject("Welcome!")
  |> html_body("<h1>Welcome to MyApp</h1>")
  |> text_body("Welcome to MyApp")

MyApp.Mailer.deliver(email)
```

### Configuration

In `config/config.exs`:

```elixir
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.SendGrid,
  api_key: System.get_env("SENDGRID_API_KEY")
```

Or use local development mode:

```elixir
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Local
```

## Core Concepts

### Email Builder API

Swoosh uses pipe-friendly builder functions to construct emails:

- **`new()`** - Start email composition
- **`to/2`** - Add recipient(s): `to("user@example.com")` or `to({"user@example.com", "Name"})`
- **`from/2`** - Set sender
- **`cc/2`, `bcc/2`** - Add copied recipients
- **`reply_to/2`** - Set reply address
- **`subject/2`** - Email subject
- **`html_body/2`** - HTML content
- **`text_body/2`** - Plain text fallback
- **`attachment/2`** - Include file: `attachment(Path.expand("file.pdf"))`
- **`custom_headers/2`** - Add custom headers

Multiple recipients: `to([{"user1@example.com", "User 1"}, "user2@example.com"])`

### Adapters

Supported adapters include SendGrid, Mailgun, Postmark, SMTP, Amazon SES, Gmail, Brevo, SparkPost, and local testing. Each requires specific configuration credentials (API keys, SMTP credentials).

Use environment variables for credentials in production.

### HTTP Client Configuration

Default HTTP client is Hackney. Switch to Finch or Req:

```elixir
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.SendGrid,
  api_key: "key",
  client: Finch  # or :req
```

## Configuration

### Development Setup

```elixir
# config/dev.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Local

# Access sent emails at /dev/mailbox in your Phoenix app
# Requires adding to router:
forward "/dev/mailbox", Plug.Swoosh.MailboxPreview
```

### Production Setup

```elixir
# config/prod.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.SendGrid,
  api_key: System.get_env("SENDGRID_API_KEY")
```

### Test Configuration

```elixir
# config/test.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Test
```

## Best Practices

### Testing Emails

Use `Swoosh.TestAssertions` in tests:

```elixir
import Swoosh.TestAssertions

# Assert email was sent
assert_email_sent(
  html_body: ~r/Welcome/,
  to: [{"user@example.com", "User"}]
)

# Assert specific email
email = Swoosh.TestAssertions.sent_emails() |> Enum.at(0)
assert email.subject == "Welcome!"
```

### Async Delivery

Send emails asynchronously to avoid blocking requests:

```elixir
# Using Task.Supervisor
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  MyApp.Mailer.deliver(email)
end)

# Or use job queues like Oban:
Email.deliver_job.new(%{"email_id" => email.id})
|> Oban.insert()
```

### Telemetry Integration

Attach telemetry handlers to monitor email delivery:

```elixir
:telemetry.attach("swoosh", [:swoosh, :deliver, :*],
  &handle_telemetry_event/4, nil)

defp handle_telemetry_event(event, measurements, metadata, _config) do
  case event do
    [:swoosh, :deliver, :ok] -> Logger.info("Email sent")
    [:swoosh, :deliver, :error] -> Logger.error("Send failed: #{metadata.error}")
  end
end
```

### Email Templates

Use Phoenix views or EEx templates for dynamic email content:

```elixir
html_body(email, MyApp.EmailView.render("welcome.html", %{name: user.name}))
text_body(email, MyApp.EmailView.render("welcome.text", %{name: user.name}))
```

### Recipient Protocol

Implement custom structs compatible with recipient functions:

```elixir
defimpl Swoosh.Email.Recipient, for: MyApp.User do
  def recipient(user) do
    {user.email, user.name}
  end
end

# Then use directly: to(user)
```

### Bulk Email Delivery

Send multiple emails efficiently:

```elixir
emails = [email1, email2, email3]
MyApp.Mailer.deliver_many(emails)
```

### Error Handling

```elixir
case MyApp.Mailer.deliver(email) do
  {:ok, metadata} -> Logger.info("Email sent: #{inspect(metadata)}")
  {:error, reason} -> Logger.error("Failed: #{inspect(reason)}")
end
```

---

**Version:** 1.19.5
**Source:** [hexdocs.pm/swoosh](https://hexdocs.pm/swoosh/)
**Generated:** 2025-10-28
