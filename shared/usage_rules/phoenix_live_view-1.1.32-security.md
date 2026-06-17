# phoenix_live_view - Security & Best Practices

## Authentication & Authorization Model

Phoenix LiveView's security model combines HTTP request validation with stateful connection protection. Unlike stateless REST APIs, LiveViews maintain server-side state via WebSocket.

### Authentication Layer

Authentication identifies users through credentials or third-party services. Store the authenticated user ID in the session:

```elixir
def create(conn, %{"user" => params}) do
  case Accounts.authenticate(params) do
    {:ok, user} ->
      conn
      |> put_session(:user_id, user.id)
      |> redirect(to: "/dashboard")

    {:error, _} ->
      render(conn, "login.html")
  end
end
```

### Authorization in LiveView

Since WebSocket navigation bypasses plugs, verify authorization in `mount/3` and every `handle_event/3`:

```elixir
def mount(_params, session, socket) do
  case session["user_id"] do
    nil ->
      {:error, {:redirect, to: "/"}}

    user_id ->
      user = Accounts.get_user!(user_id)
      {:ok, assign(socket, :current_user, user)}
  end
end

def handle_event("delete-item", %{"id" => id}, socket) do
  item = Items.get_item!(id)

  # Always verify authorization
  if item.user_id == socket.assigns.current_user.id do
    Items.delete!(item)
    {:noreply, assign(socket, :items, Items.list())}
  else
    {:noreply, put_flash(socket, :error, "Not authorized")}
  end
end
```

**Critical**: Never rely on client-side checks or UI hiding. Always verify on the server.

## live_session Security Boundaries

Group LiveViews that share authentication requirements:

```elixir
live_session :authenticated, on_mount: MyAppWeb.UserAuth do
  live "/dashboard", DashboardLive
  live "/profile", ProfileLive
  live "/settings", SettingsLive
end

live_session :admin, on_mount: MyAppWeb.AdminAuth do
  live "/admin", AdminDashboardLive
  live "/admin/users", UsersLive
end
```

Navigation **within** a `live_session` uses WebSocket (skips plugs). Navigation **between** `live_session` groups forces a full page reload (security boundary).

This means authorization checks MUST happen in `on_mount` hooks—not in plugs alone.

## on_mount Hooks

Run authentication/authorization before `mount/3`:

```elixir
defmodule MyAppWeb.UserAuth do
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user_id ->
        user = Accounts.get_user!(user_id)
        {:cont, assign_new(socket, :current_user, fn -> user end)}
    end
  end
end

defmodule MyAppWeb.AdminAuth do
  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/login")}

      user_id ->
        user = Accounts.get_user!(user_id)

        # Check admin role
        if user.role == :admin do
          {:cont, assign_new(socket, :current_user, fn -> user end)}
        else
          {:halt, redirect(socket, to: "/")}
        end
    end
  end
end
```

Use `assign_new/3` to avoid redundant database queries across nested LiveViews.

## Session Persistence During Disconnections

When users logout or lose permissions, WebSocket connections persist until page reload. Implement session IDs to force reconnection:

```elixir
# In auth controller
def logout(conn, _params) do
  user_id = get_session(conn, :user_id)

  # Invalidate the session ID, forcing reconnection
  MyApp.PubSub.broadcast("session:#{user_id}", {:logout})

  conn
  |> delete_session(:user_id)
  |> redirect(to: "/")
end
```

Client-side handling:

```elixir
def mount(_params, session, socket) do
  socket = assign_new(socket, :current_user, fn -> get_user(session) end)

  if connected?(socket) do
    user_id = socket.assigns.current_user.id
    Phoenix.PubSub.subscribe(MyApp.PubSub, "session:#{user_id}")
  end

  {:ok, socket}
end

def handle_info({:logout}, socket) do
  {:noreply, push_navigate(socket, to: "/login")}
end
```

## Data Validation & Sanitization

Always validate and sanitize user input:

```elixir
def handle_event("create", params, socket) do
  case MyContext.create_item(params) do
    {:ok, item} ->
      {:noreply, assign(socket, :items, [item | socket.assigns.items])}

    {:error, changeset} ->
      {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

Use Ecto changesets for validation:

```elixir
defmodule MyApp.Item do
  use Ecto.Schema

  schema "items" do
    field :title, :string
    field :body, :string
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:title, :body])
    |> validate_required([:title])
    |> validate_length(:title, min: 3, max: 200)
  end
end
```

## File Upload Security

**Client metadata is untrusted** but size constraints are enforced server-side:

```elixir
# Size validated at chunk reception
allow_upload(:avatar,
  accept: ~w(.jpg .png),
  max_file_size: 10_000_000)  # Enforced server-side

def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
      # Verify file actually matches constraints
      {:ok, file_size} = File.stat(path)

      if file_size.size > 10_000_000 do
        {:error, "File too large"}
      else
        # Process safely
        dest = generate_safe_path(entry)
        File.cp!(path, dest)
        {:ok, dest}
      end
    end)

  {:noreply, socket}
end
```

Use whitelists for accepted file types:

```elixir
@allowed_extensions ~w(.jpg .jpeg .png)

def validate_upload(entry) do
  if Path.extname(entry.client_name) in @allowed_extensions do
    {:ok, entry}
  else
    {:error, :invalid_type}
  end
end
```

For production, store uploads in cloud storage (S3, etc.) not on the application server.

## Common Pitfalls

### 1. Trusting Client Data

```elixir
# ❌ WRONG - User can fake their role
def handle_event("delete", %{"role" => role}, socket) do
  if role == "admin" do
    delete_item()
  end
end

# ✅ CORRECT - Verify from session/database
def handle_event("delete", _params, socket) do
  if socket.assigns.current_user.role == :admin do
    delete_item()
  end
end
```

### 2. Forgetting Authorization Checks

```elixir
# ❌ WRONG - No permission check
def handle_event("view", %{"user_id" => id}, socket) do
  user = Accounts.get_user!(id)
  {:noreply, assign(socket, :viewing_user, user)}
end

# ✅ CORRECT - Verify permission
def handle_event("view", %{"user_id" => id}, socket) do
  user = Accounts.get_user!(id)

  # Only admins or the user themselves can view
  if socket.assigns.current_user.role == :admin or
     socket.assigns.current_user.id == id do
    {:noreply, assign(socket, :viewing_user, user)}
  else
    {:noreply, put_flash(socket, :error, "Not authorized")}
  end
end
```

### 3. Exposing Sensitive Data

```elixir
# ❌ WRONG - Returns all user data to client
def mount(_params, _session, socket) do
  {:ok, assign(socket, :user, get_current_user())}
end

# ✅ CORRECT - Only include what's needed
def mount(_params, _session, socket) do
  user = get_current_user()
  {:ok, assign(socket, current_user: %{id: user.id, name: user.name})}
end
```

### 4. Missing Rate Limiting

Add rate limiting for expensive operations:

```elixir
def handle_event("search", params, socket) do
  case ratelimit(:search, socket.assigns.current_user.id) do
    :ok ->
      results = search_items(params["q"])
      {:noreply, assign(socket, :results, results)}

    :rate_limited ->
      {:noreply, put_flash(socket, :error, "Too many requests")}
  end
end
```

## Deployment Considerations

### State Management

Use URL parameters for UI state (shareable, cacheable):

```heex
<.link patch={~p"/?page=2&sort=date"}>Next Page</.link>
```

Persist meaningful data to database:

```elixir
def handle_event("mark-read", %{"message_id" => id}, socket) do
  message = Messages.get!(id)
  Messages.update!(message, %{read_at: DateTime.utc_now()})
  {:noreply, socket}
end
```

### Automatic Reconnection

LiveView automatically reconnects with exponential backoff (immediate, 2s, 5s, etc.). Load balancers route reconnections to available servers. Form state is automatically recovered.

### Multiple Instances

For distributed deployments:

- Use `Phoenix.PubSub` for cross-instance communication
- Store state in database, not memory
- Use sticky sessions or stateless design patterns

---

[← Back to main](phoenix_live_view-1.1.32.md)
**Version:** 1.1.32
