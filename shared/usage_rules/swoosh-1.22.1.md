# swoosh

Swoosh is an Elixir email library for composing, delivering, and testing emails with support for 40+ email service providers and adapters.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:swoosh, "~> 1.22"}
```

For API-based adapters (SendGrid, Mailgun, Postmark, etc.), configure an HTTP client:

```elixir
config :swoosh, :api_client, Swoosh.ApiClient.Hackney
```

For SMTP-based adapters, add `gen_smtp`:

```elixir
{:gen_smtp, "~> 1.0"}
```

### Basic Configuration

In `config/config.exs`:

```elixir
config :myapp, MyApp.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: System.get_env("SENDGRID_API_KEY")
```

Define a mailer module:

```elixir
defmodule MyApp.Mailer do
  use Swoosh.Mailer, otp_app: :myapp
end
```

### Sending Email

```elixir
alias Swoosh.Email

email =
  Email.new()
  |> Email.to({"Recipient", "recipient@example.com"})
  |> Email.from({"Sender", "sender@example.com"})
  |> Email.subject("Hello World")
  |> Email.html_body("<h1>Welcome!</h1>")
  |> Email.text_body("Welcome!")

MyApp.Mailer.deliver(email)
```

## Core Concepts

### Email Builder

Use the `Swoosh.Email` module to construct emails with a fluent builder API:

- `Email.new()` — Create new email
- `Email.to()`, `Email.cc()`, `Email.bcc()` — Add recipients
- `Email.from()` — Set sender
- `Email.subject()` — Set subject line
- `Email.html_body()`, `Email.text_body()` — Set message content
- `Email.attachment()` — Add file attachments
- `Email.assign()` — Store custom data for template rendering

### Adapters

Swoosh ships with adapters for major providers:

- **API-based**: SendGrid, Mailgun, Postmark, Mandrill, SparkPost, etc.
- **SMTP**: Standard SMTP, Amazon SES, AmazonSES
- **Development**: `Local` (in-memory preview), `Test` (for testing), `Sandbox` (async-safe feature tests)

### Recipients Protocol

Implement `Swoosh.Email.Recipient` protocol to support custom struct recipients:

```elixir
defimpl Swoosh.Email.Recipient, for: User do
  def format(user) do
    {user.name, user.email}
  end
end
```

## Configuration

### Development Environment

Use `Swoosh.Adapters.Local` to preview emails in a web UI without sending:

```elixir
config :myapp, MyApp.Mailer,
  adapter: Swoosh.Adapters.Local
```

Mount the preview plug in your router:

```elixir
forward "/dev/mailbox", Plug.Swoosh.MailboxPreview
```

Visit `http://localhost:4000/dev/mailbox` to see sent emails.

### Test Environment

Use `Swoosh.Adapters.Test` for synchronous unit tests:

```elixir
config :myapp, MyApp.Mailer,
  adapter: Swoosh.Adapters.Test
```

Use `Swoosh.Adapters.Sandbox` for async-safe feature tests and ExUnit doctests.

### Telemetry

Swoosh emits telemetry events for monitoring:

- `:start` — Delivery started
- `:stop` — Delivery completed
- `:exception` — Delivery failed

Configure handlers:

```elixir
:telemetry.attach("swoosh-logger", [:swoosh, :deliver], &log_event/4, nil)
```

## Best Practices

### Async Delivery

Avoid blocking on email sends. Use Task supervisors or job queues like Oban:

```elixir
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn ->
  MyApp.Mailer.deliver(email)
end)
```

Or with Oban:

```elixir
%{email: email}
|> MyApp.EmailWorker.new()
|> Oban.insert()
```

### Template Rendering

Assign template variables and render with Phoenix or another template engine:

```elixir
email
|> Email.assign(:user, user)
|> Email.html_body(render_body(template, email.assigns))
```

### Attachments

Attach files with `Email.attachment/2`:

```elixir
email
|> Email.attachment(File.stream!("path/to/file"))
|> Email.attachment(Swoosh.Attachment.new("filename.pdf", binary_content))
```

### Error Handling

Always handle delivery failures:

```elixir
case MyApp.Mailer.deliver(email) do
  {:ok, metadata} -> :ok
  {:error, reason} -> log_error(reason)
end
```

### Configuration Best Practices

- Store API keys in environment variables, never in code
- Use different adapters per environment (Local for dev, Test for test, API adapter for prod)
- Set reasonable timeouts for API calls
- Monitor delivery telemetry for production issues
- Test email formatting with `Swoosh.Adapters.Test` before integrating

---

**Version:** 1.22.1  
**Source:** [GitHub - swoosh/swoosh](https://github.com/swoosh/swoosh), [HexDocs](https://hexdocs.pm/swoosh/)  
**Generated:** 2026-04-25
