# phoenix - Security & Best Practices

## Critical Vulnerabilities & Mitigations

### Remote Code Execution (RCE)

Never pass untrusted user input to code evaluation or system execution functions:

**Dangerous:**

```elixir
Code.eval_string(user_input)
System.cmd("sh", ["-c", user_command])
:os.cmd(user_cmd)
```

**Safer alternatives:**

- Use pre-approved command whitelist
- Sanitize and validate all inputs
- Use Plug.Crypto.non_executable_binary_to_term instead of :erlang.binary_to_term to "prevent the creation of executable terms at runtime"

```elixir
# Safe deserialization
case Plug.Crypto.non_executable_binary_to_term(binary) do
  {:ok, term} -> handle_term(term)
  :error -> handle_invalid_term()
end
```

### SQL Injection

Ecto's query syntax provides built-in protection. Always parameterize external input:

**Dangerous:**

```elixir
query = "SELECT * FROM posts WHERE title = '#{user_input}'"
Repo.query!(query)
```

**Safe:**

```elixir
# Using Ecto.Query DSL (preferred)
import Ecto.Query
query = Post |> where([p], p.title == ^user_input)
Repo.all(query)

# Using raw SQL with parameters
Repo.query!("SELECT * FROM posts WHERE title = $1", [user_input])

# Fragment with placeholders
from(p in Post, where: fragment("? = ?", p.title, ^user_input))
```

Ecto's `^` (pin) operator binds parameters safely to prevent injection.

### Server-Side Request Forgery (SSRF)

Never construct URLs from user input for HTTP requests. Internal services (databases, Redis, metadata endpoints) become exploitation targets:

**Dangerous:**

```elixir
url = "http://#{user_host}:#{user_port}/data"
HTTPoison.get(url)
```

**Mitigations:**

- Validate and whitelist allowed domains
- Never allow user input to override base URLs in HTTP clients
- Block access to internal IP ranges (127.0.0.1, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
- Use environment variables for service URLs, never user input

```elixir
# Whitelist approach
allowed_hosts = ["api.example.com", "data.example.com"]
case url_host_valid?(user_url, allowed_hosts) do
  true -> HTTPoison.get(user_url)
  false -> {:error, :invalid_host}
end
```

### Cross-Site Scripting (XSS)

Phoenix escapes output by default. Avoid the `raw/1` function with user input:

**Dangerous:**

```html
<div><%= raw(user_input) %></div>
```

**Safe:**

```html
<!-- Phoenix automatically escapes -->
<div><%= @user_input %></div>

<!-- For intentional HTML from trusted sources only -->
<div><%= raw(sanitized_html) %></div>
```

**File upload risk:**
Validate `content-type` rigorously to prevent HTML files from executing as scripts:

```elixir
def upload_file(conn, %{"file" => file}) do
  case verify_content_type(file.content_type) do
    :ok -> save_file(file)
    :error -> {:error, "Invalid file type"}
  end
end

defp verify_content_type(type) do
  allowed = ["image/jpeg", "image/png", "application/pdf"]
  if Enum.member?(allowed, type), do: :ok, else: :error
end
```

Never trust the `content-type` header alone; inspect file contents for validation.

### Broken Access Control

Use `conn.assigns.current_user` for authorization decisions, never accept user-submitted identifiers:

**Dangerous:**

```elixir
def edit(conn, %{"user_id" => user_id}) do
  user = Repo.get(User, user_id)
  render(conn, :edit, user: user)
end
```

An attacker can edit any user by changing the URL parameter.

**Safe:**

```elixir
def edit(conn, _params) do
  user = conn.assigns.current_user
  render(conn, :edit, user: user)
end
```

Always retrieve the current user from session/token, not request parameters.

### Mass Assignment

Ecto's explicit `cast/3` function mitigates mass assignment vulnerabilities. Only allow necessary fields:

**Safe pattern:**

```elixir
defmodule User do
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name])  # Only these fields accepted from params
    |> validate_required([:email])
  end
end
```

The `cast/3` function ignores any extraneous fields in `attrs`, preventing privilege escalation (e.g., user cannot set `is_admin: true`).

### Cross-Site Request Forgery (CSRF)

Phoenix includes the `:protect_from_forgery` plug by default in the browser pipeline. State-changing operations must use POST/PUT/PATCH requests with CSRF tokens:

**Router configuration:**

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_flash
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end
```

**Template form:**

```html
<.form :let={f} for={@changeset} action={~p"/users"}>
  <!-- CSRF token automatically included -->
  <.input field={f[:email]} type="email" />
  <.button>Save</.button>
</.form>
```

Never perform state-changing operations with GET requests; always require POST/PUT/PATCH with valid CSRF tokens.

## Secure Defaults

### Password Storage

Never store passwords as plain text. Use a library like `bcrypt_elixir`:

```elixir
defmodule User do
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> put_password_hash()
  end

  defp put_password_hash(%{valid?: true, changes: %{password: password}} = changeset) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset
end
```

### Session Configuration

Configure secure session cookies:

```elixir
# config/prod.exs
config :hello, HelloWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  https: [
    port: 443,
    cipher_suite: :strong,
    keyfile: System.get_env("KEYFILE"),
    certfile: System.get_env("CERTFILE")
  ],
  secure_cookies: true,
  same_site: "Strict"
```

### Rate Limiting

Prevent brute force and DoS attacks with rate limiting:

```elixir
plug Plug.RateLimit,
  rate_limit: 100,
  window_time: 60
```

### Security Headers

Phoenix's `put_secure_browser_headers` plug adds essential security headers:

```
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
X-XSS-Protection: 1; mode=block
Content-Security-Policy: ...
```

## Code Review for AI-Generated Content

> Proper judgement on the security of code has become more important than ever with AI-assisted development. Validate all generated code critically against these guidelines, especially for authentication, authorization, and data access patterns.

- Review all user input handling for injection vulnerabilities
- Verify access control uses authenticated user context, not request parameters
- Check that state-changing operations protect against CSRF
- Validate database queries use parameterized approaches
- Ensure sensitive operations are logged for audit trails

## Best Practices

- **Enable HTTPS in production**: Use TLS/SSL for all connections
- **Regularly update dependencies**: Keep Phoenix, Plug, and Ecto versions current
- **Use environment variables**: Store secrets in env vars, never hardcode
- **Implement logging**: Log authentication attempts, failures, and admin actions
- **Validate input rigorously**: Whitelist expected input rather than blacklisting dangerous patterns
- **Test security**: Include security-focused tests for authorization, injection, and CSRF scenarios

---

[← Back to main](phoenix-1.8.8.md)  
**Version:** 1.8.8
