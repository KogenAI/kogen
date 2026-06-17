# phoenix_live_view - Forms & User Input

## Form Bindings Overview

Phoenix LiveView provides two primary bindings for form interactions:

- `phx-change` - Real-time input changes for validation and updates
- `phx-submit` - Form submission handling

## phx-change Binding

Captures real-time form input changes and sends them to the server.

```elixir
<.form for={@form} phx-change="validate" phx-submit="save">
  <.input field={@form[:email]} type="email" />
  <.input field={@form[:password]} type="password" />
  <button type="submit">Save</button>
</.form>

def handle_event("validate", %{"user" => params}, socket) do
  changeset = User.changeset(%User{}, params)
  {:noreply, assign(socket, form: to_form(changeset))}
end
```

### phx-change Behavior

**Loading State:** When a change event fires, both the input and parent form receive the `phx-change-loading` CSS class.

```css
.phx-change-loading {
  opacity: 0.5;
  pointer-events: none;
}
```

**Target Identification:** The server receives a `"_target"` parameter identifying which field triggered the change:

```elixir
def handle_event("validate", %{"_target" => ["user", "email"]} = params, socket) do
  # Handle email field change specifically
  {:noreply, assign(socket, form: to_form(changeset))}
end
```

**Focused Input Protection:** LiveView never overwrites focused input values, even if server updates deviate from client state. This preserves user experience during rapid typing.

### Form Recovery

Forms with `id` attributes automatically recover input values after disconnection:

```html
<.form for={@form} id="user_form" phx-change="validate">
  <!-- Values are restored on reconnect -->
</.form>
```

**Customization:**

- `phx-auto-recover="ignore"` - Disable recovery for this form
- `phx-auto-recover="ignore"` on individual inputs - Disable for specific fields

## phx-submit Binding

Handles form submission when users click a submit button.

```elixir
<.form for={@form} phx-submit="save">
  <.input field={@form[:name]} />
  <button type="submit">Save</button>
</.form>

def handle_event("save", %{"user" => params}, socket) do
  case Accounts.create_user(params) do
    {:ok, user} ->
      {:noreply, push_navigate(socket, to: "/users/#{user.id}")}
    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

## Form Handling Pattern

**Two-Phase Approach:**

1. **Validation Phase (phx-change):** Real-time validation displays errors as user types
2. **Submission Phase (phx-submit):** Actual data persistence

```elixir
defmodule MyApp.UserLive.Form do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(Ecto.Changeset.new(%{})))}
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset = User.changeset(%User{}, params)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.create_user(params) do
      {:ok, user} ->
        {:noreply, push_navigate(socket, to: "/users")}
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <.form for={@form} phx-change="validate" phx-submit="save">
      <.input field={@form[:email]} type="email" />
      <.input field={@form[:password]} type="password" />
      <.error :for={err <- @form.errors}>
        {err}
      </.error>
      <button type="submit" disabled={!@form.valid?}>Create</button>
    </.form>
    """
  end
end
```

## Individual Input Events

Inputs can have their own event bindings:

```html
<input type="text" phx-change="search" phx-debounce="300" />
<input type="checkbox" phx-change="toggle_option" />
```

**Event Options:**

- `phx-debounce="300"` - Delay change events by 300ms
- `phx-throttle="1000"` - Limit change events to once per second
- `phx-blur` - Event on input blur
- `phx-focus` - Event on input focus

## Error Handling

Use `Phoenix.Component.used_input?/1` to display errors only for fields users have interacted with:

```elixir
<.input field={@form[:email]} type="email" />
<.error :if={used_input?(@form, :email) and @form[:email].errors}>
  {elem(@form[:email].errors |> Enum.at(0), 0)}
</.error>
```

## Working with Changesets

Form bindings work seamlessly with Ecto changesets:

```elixir
def handle_event("validate", %{"user" => params}, socket) do
  changeset = User.changeset(socket.assigns.user, params)
  # Mark as in-flight; errors show but data isn't saved
  {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
end
```

**Key Points:**

- Pass `action: :validate` to show validation errors without marking as committed
- Use `to_form/2` to convert changesets to form structures
- Changesets track which fields changed via `changed_for?/2`

## Form Composition

Combine form components for nested structures:

```elixir
<.form for={@user_form} phx-submit="save">
  <.input field={@user_form[:name]} />

  <.inputs_for :let={f} field={@user_form[:addresses]}>
    <.input field={f[:street]} />
    <.input field={f[:city]} />
  </.inputs_for>

  <button type="submit">Save</button>
</.form>
```

## Best Practices

**Validate on Change:** Provide immediate feedback during data entry for better UX.

**Debounce Expensive Validations:** Use `phx-debounce` for operations hitting the server frequently.

**Preserve Form State:** Keep forms in assigns even after successful submission to support "create and continue" patterns.

**Show Field Hints:** Display relevant error messages only when needed.

```elixir
<.input field={@form[:email]} />
<.error :if={used_input?(@form, :email)}>
  {translate_error(@form[:email].errors)}
</.error>
```

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
