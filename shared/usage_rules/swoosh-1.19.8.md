# swoosh

Swoosh is an Elixir email library that streamlines email composition, delivery, and testing. It provides an adapter-based architecture supporting 25+ transactional email providers (SendGrid, Mailgun, Postmark, SMTP, etc.) with a composable, declarative API for building emails as data structures.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
defp deps do
  [{:swoosh, "~> 1.19"}]
end
```

### Basic Configuration

Define a mailer module:

```elixir
defmodule MyApp.Mailer do
  use Swoosh.Mailer, otp_app: :my_app
end
```

Configure in `config.exs`:

```elixir
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: "SG.your-key"
```

### Send an Email

```elixir
email = MyApp.UserEmail.welcome(user)
MyApp.Mailer.deliver(email)
```

## Core Concepts

### Adapter-Based Architecture

Adapters provide the transport layer. Configure once in your application settings, then Swoosh handles the integration automatically. Common adapters:

- **SendGrid** - Fast, reliable, scalable
- **Mailgun** - European support, good APIs
- **Postmark** - Developer-focused, high deliverability
- **SMTP** - Self-hosted, universal
- **Test** - For testing without API calls

### Email as Data Structures

Emails are composable structs built with a chainable API:

```elixir
email = Swoosh.Email.new()
  |> Swoosh.Email.from({"Sender Name", "sender@example.com"})
  |> Swoosh.Email.to("recipient@example.com")
  |> Swoosh.Email.subject("Welcome!")
  |> Swoosh.Email.html_body("<h1>Welcome</h1>")
  |> Swoosh.Email.text_body("Welcome")
```

Or with direct parameters:

```elixir
Swoosh.Email.new(
  from: {"Name", "email@example.com"},
  to: "recipient@example.com",
  subject: "Welcome!"
)
```

### Recipient Protocol

Custom recipient structs can be passed directly if they derive the `Recipient` protocol, eliminating manual conversion:

```elixir
defmodule User do
  defstruct [:email, :name]

  derive [Swoosh.Email.Recipient]
end

# Use directly
email |> Swoosh.Email.to(user)
```

## Configuration

### Module-Level Configuration

Override defaults in the mailer module itself:

```elixir
defmodule MyApp.Mailer do
  use Swoosh.Mailer,
    otp_app: :my_app,
    adapter: Swoosh.Adapters.Sendgrid,
    api_key: "SG.your-key"
end
```

### Runtime Configuration

Override config values per-delivery:

```elixir
MyApp.Mailer.deliver(email, domain: "custom.com")
```

### Environment-Specific Config

```elixir
# test.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Test

# prod.exs
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: System.fetch_env!("SENDGRID_API_KEY")
```

## Email Composition Functions

**Core builders:**

- `new()` / `new(opts)` - Create email struct
- `to(email)`, `cc(email)`, `bcc(email)` - Add recipients (append)
- `put_to(emails)`, `put_cc(emails)`, `put_bcc(emails)` - Replace recipients
- `from(email)` - Set sender (required)
- `reply_to(email)` - Set reply-to address
- `subject(text)` - Set subject line

**Content:**

- `html_body(html)` - Set HTML content
- `text_body(text)` - Set plain text content
- `header(key, value)` - Add custom email header
- `attachment(file)` - Attach files with automatic MIME detection

**Metadata:**

- `assign(key, value)` - Store template variables
- `put_private(key, value)` - Framework-specific metadata
- `put_provider_option(key, value)` - Adapter-specific settings

## Best Practices

### 1. Use Email Modules

Create dedicated modules for email types:

```elixir
defmodule MyApp.UserEmail do
  def welcome(user) do
    Swoosh.Email.new()
    |> Swoosh.Email.from({"MyApp", "noreply@myapp.com"})
    |> Swoosh.Email.to(user.email)
    |> Swoosh.Email.subject("Welcome to MyApp")
    |> Swoosh.Email.html_body("<h1>Hello #{user.name}</h1>")
  end

  def password_reset(user, token) do
    Swoosh.Email.new()
    |> Swoosh.Email.from({"MyApp Support", "support@myapp.com"})
    |> Swoosh.Email.to(user.email)
    |> Swoosh.Email.subject("Reset Your Password")
    |> Swoosh.Email.html_body(reset_html(user, token))
  end
end
```

### 2. Asynchronous Delivery

Avoid blocking requests with async sends:

```elixir
# Using Task.Supervisor
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  MyApp.Mailer.deliver(email)
end)

# Or with Oban job queue (recommended for production)
%{email: email}
|> MyApp.SendEmailJob.new()
|> Oban.insert()
```

### 3. Test Adapter in Tests

Enables email assertions without API calls:

```elixir
# config/test.exs
config :my_app, MyApp.Mailer, adapter: Swoosh.Adapters.Test

# In tests
test "sends welcome email" do
  user = create_user()
  MyApp.UserEmail.welcome(user) |> MyApp.Mailer.deliver()

  assert_email_sent subject: "Welcome to MyApp"
  assert_email_sent to: {nil, user.email}
end
```

### 4. Always Include Text Body

Provide both `html_body` and `text_body` for full compatibility:

```elixir
|> Swoosh.Email.html_body("<p>Hello</p>")
|> Swoosh.Email.text_body("Hello")
```

### 5. Handle Delivery Errors

```elixir
case MyApp.Mailer.deliver(email) do
  {:ok, metadata} -> {:ok, metadata}
  {:error, reason} -> {:error, "Email delivery failed: #{inspect(reason)}"}
end
```

### 6. Use Custom Headers Sparingly

Some adapters have header restrictions. Check adapter docs before using custom headers.

### 7. Recipient Lists

Support both strings and tuples for flexibility:

```elixir
# All valid
|> Swoosh.Email.to("recipient@example.com")
|> Swoosh.Email.to({"Name", "recipient@example.com"})
|> Swoosh.Email.to(["user1@example.com", "user2@example.com"])
```

---

**Version:** 1.19.8
**Elixir:** 1.13+
**Erlang OTP:** 24+
**Source:** [hexdocs.pm/swoosh](https://hexdocs.pm/swoosh/)
**Generated:** 2025-11-04
