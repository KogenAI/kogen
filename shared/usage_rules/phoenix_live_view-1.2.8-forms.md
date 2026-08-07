# phoenix_live_view - Form Bindings & Validation

## Core Form Events

Phoenix LiveView handles form interactions through two primary events:

### phx-change

Fires when any form input changes, sending all form fields to the LiveView callback:

```heex
<form id="user-form" phx-change="validate">
  <input type="text" name="user[name]" />
  <input type="email" name="user[email]" />
</form>
```

- **Triggers**: On every input change
- **Data sent**: All form fields serialized
- **Use case**: Real-time validation, dynamic form updates
- **Recovery**: Forms with `phx-change` and an `id` attribute automatically recover input values after reconnection by retriggering the change event

### phx-submit

Triggered on form submission (button click or Enter key):

```heex
<form id="user-form" phx-change="validate" phx-submit="save">
  <input type="text" name="user[name]" required />
  <button type="submit">Save</button>
</form>
```

- **Triggers**: On form submission
- **Use case**: Operations with significant side effects (saving data, redirecting)
- **Best practice**: Use both `phx-change` for validation and `phx-submit` for actual save

## Key phx- Attributes

| Attribute             | Purpose                                          | Example                                |
| --------------------- | ------------------------------------------------ | -------------------------------------- |
| `phx-change`          | Captures input changes                           | `<form phx-change="validate">`         |
| `phx-submit`          | Handles form submission                          | `<form phx-submit="save">`             |
| `phx-target`          | Routes events to specific components             | `phx-target={@myself}`                 |
| `phx-disable-with`    | Swaps button text during submission              | `phx-disable-with="Saving..."`         |
| `phx-trigger-action`  | Submits form over HTTP after LiveView validation | `phx-trigger-action={@trigger_submit}` |
| `phx-auto-recover`    | Specifies custom recovery event                  | `phx-auto-recover="form_changed"`      |
| `phx-no-unused-field` | Disables sending of `_unused_` parameters        | `phx-no-unused-field`                  |
| `phx-drop-target`     | Enables drag-and-drop file uploads               | `phx-drop-target={@myself}`            |

## Error Feedback Pattern

LiveView sends `_unused_` parameters to indicate untouched fields. Use `Phoenix.Component.used_input?/1` to show errors only for fields the user has interacted with:

```heex
<form id="form" phx-change="validate" phx-submit="save">
  <div>
    <input type="email" name="user[email]" value={@email} />
    <%= if used_input?(@form.source, :email) and @form.errors[:email] do %>
      <span class="error"><%= translate_error(@form.errors[:email]) %></span>
    <% end %>
  </div>
</form>
```

This approach prevents showing validation errors for fields the user hasn't touched yet, improving UX.

## Special Input Handling

### Number Inputs

LiveView prevents change events for invalid entries. The browser's native validation guides users without requiring server interaction.

### Password Inputs

Password values are never reused by LiveView for security. You must explicitly set the `:value` attribute if you want to repopulate the field:

```heex
<input type="password" name="user[password]" value={@password} />
```

### File Inputs

Support reactive uploads with drag-and-drop via `phx-drop-target`:

```heex
<form phx-change="validate" phx-drop-target={@myself}>
  <.live_file_input upload={@uploads.avatar} />
</form>
```

## Form Submission Control

### phx-disable-with

Prevents double submissions by disabling the button during submission:

```heex
<button type="submit" phx-disable-with="Saving...">Save</button>
```

Changes button appearance and text while the form processes, re-enabling on completion or error.

### phx-trigger-action

Converts a LiveView form to an HTTP form submission after validation:

```elixir
def handle_event("save", params, socket) do
  # Validate
  if valid?(params) do
    {:noreply, assign(socket, :trigger_submit, true)}
  else
    {:noreply, assign(socket, :trigger_submit, false)}
  end
end
```

```heex
<form phx-change="validate" phx-submit="save" phx-trigger-action={@trigger_submit}>
  ...
</form>
```

When `phx-trigger-action` is true, the form submits as HTTP POST instead of LiveView event.

## Event Handler Implementation

```elixir
def handle_event("validate", %{"user" => user_params}, socket) do
  changeset = User.changeset(%User{}, user_params)
  {:noreply, assign(socket, form: to_form(changeset))}
end

def handle_event("save", %{"user" => user_params}, socket) do
  case save_user(socket.assigns.current_user, user_params) do
    {:ok, user} ->
      {:noreply, assign(socket, :user, user)}
    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

---

[← Back to main](phoenix_live_view-1.2.8.md)
**Version:** 1.2.8
