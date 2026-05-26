# Phoenix 1.8.1 - Security & Vulnerability Prevention

## Critical Vulnerabilities

### Remote Code Execution (RCE)

Never pass untrusted input to dangerous functions:

```elixir
# DANGEROUS - Never do this
Code.eval_string(user_input)
:os.cmd(user_input)
:erlang.binary_to_term(user_data)

# SAFE - Use non-executable alternatives
Plug.Crypto.non_executable_binary_to_term(binary)
```

The `safe: true` option in binary_to_term only prevents atom creation but fails to block executable terms. Always use the non-executable variant for untrusted data.

### SQL Injection

Phoenix applications using Ecto are protected by default. String interpolation in `fragment()` queries causes compilation errors:

```elixir
# DANGEROUS - This fails at compile time
from u in User,
  where: fragment("SELECT * FROM users WHERE email = #{email}")

# SAFE - Use parameterized queries
from u in User,
  where: fragment("SELECT * FROM users WHERE email = ?", ^email)

# SAFE - Use Ecto's DSL
from u in User,
  where: u.email == ^email
```

Always parameterize raw SQL using placeholders (`$1`, `$2` for PostgreSQL) rather than string interpolation.

### Server-Side Request Forgery (SSRF)

Occurs when applications construct HTTP requests from user input. Cloud metadata services become attack vectors:

```elixir
# DANGEROUS - User controls URL
url = params["url"]
HTTPoison.get(url)

# DANGEROUS - Base URL doesn't guarantee safety
HTTPoison.get("https://api.example.com", params)
client = HTTPClient.new(base_url: "https://api.example.com")
HTTPClient.get(client, params["endpoint"])  # Can be overridden
```

Avoid user-controlled URLs in HTTP requests when possible. If required, validate against a whitelist of allowed domains and use URL parsing libraries to prevent override attacks.

### Cross-Origin Resource Sharing (CORS)

Overly permissive CORS policies create serious risks:

```elixir
# DANGEROUS - Allows any origin
cors_plug = CORSPlug.init(origins: ~r/^http.*/)

# SAFE - Whitelist trusted domains
cors_plug = CORSPlug.init(
  origins: ["https://trusted1.example.com", "https://trusted2.example.com"]
)
```

Only whitelist specific, trusted domains explicitly. Avoid patterns like `~r/^http.*/` that permit any origin.

## Authorization & Data Protection

### Broken Access Control

Never accept user input for authorization decisions:

```elixir
# DANGEROUS - Accept user-supplied user ID
def show(conn, %{"user_id" => user_id}) do
  user = Repo.get(User, user_id)
  render(conn, "show.html", user: user)
end

# SAFE - Use authenticated user from conn
def show(conn, %{"user_id" => user_id}) do
  current_user = conn.assigns.current_user
  user = Repo.get(User, user_id)

  unless user.id == current_user.id do
    raise Plug.Conn.NotFoundError
  end

  render(conn, "show.html", user: user)
end
```

Always use `conn.assigns.current_user` from the session rather than parameters.

### Mass-Assignment Vulnerabilities

Explicitly define castable parameters in changesets:

```elixir
# DANGEROUS - Casts all parameters
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email, :is_admin])
  |> validate_required([:name, :email])
end

# SAFE - Only cast non-sensitive fields
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email])
  |> validate_required([:name, :email])
end

# Separate changeset for admin operations
def admin_changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email, :is_admin])
  |> validate_required([:name, :email])
end
```

Never include `:is_admin` or privilege fields in public registration/update changesets.

### Cross-Site Scripting (XSS)

User input is escaped by default in Phoenix templates. The `raw/1` function bypasses this protection:

```elixir
# SAFE - Default escaping
<%= @post.title %>      <!-- Escaped -->
<%= @post.body %>       <!-- Escaped -->

# DANGEROUS - Raw HTML unescaped
<%= raw(@user_content) %>

# File uploads - DANGEROUS
def create(conn, %{"file" => %{content_type: type, body: body}}) do
  # DANGEROUS - Use user-supplied content type
  write_file(body, content_type: type)
end

# SAFE - Validate content type
def create(conn, %{"file" => file}) do
  content_type = get_safe_content_type(file)
  write_file(file.body, content_type: content_type)
end
```

Never use `raw/1` on user content. Validate file content types, don't trust user-supplied values.

### Cross-Site Request Forgery (CSRF)

Phoenix includes automatic CSRF protection via the `:protect_from_forgery` plug in the default browser pipeline:

```elixir
# In router.ex
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_flash
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

# In templates - CSRF token required
<form method="post" action="/posts">
  <input type="hidden" name="_csrf_token" value={get_csrf_token()}>
  <input type="text" name="title">
  <button type="submit">Create</button>
</form>
```

State-changing operations must use POST requests, never GET. Using GET for mutations creates "action re-use" CSRF vulnerabilities where attackers can trigger actions by embedding image tags.

```elixir
# DANGEROUS - GET for state change
get "/posts/:id/delete", PostController, :delete

# SAFE - POST for state change
delete "/posts/:id", PostController, :delete
```

## Secrets & Configuration

Store sensitive data in environment variables loaded via `config/runtime.exs`:

```elixir
# DANGEROUS
config :hello, database_password: "super_secret"

# SAFE - Load from environment
config :hello, database_password: System.get_env("DB_PASSWORD")
```

Never hardcode credentials. Use runtime configuration with environment variables.

## Best Practices Summary

- Always use parameterized queries with Ecto
- Never accept user input for authorization decisions
- Use `raw/1` only on application-controlled content
- Implement CSRF protection on all state-changing operations
- Validate and whitelist file uploads
- Use non-executable binary deserialization
- Escape all user input by default in templates
- Store secrets in environment variables
- Implement rate limiting for authentication endpoints
- Use HTTPS in production
- Keep dependencies updated
- Regularly audit security-sensitive code paths

---

[← Back to main](phoenix-1.8.1.md)
**Version:** 1.8.1
