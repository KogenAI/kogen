# phoenix_live_view - Form Bindings and Input Handling

## Core Form Directives

Phoenix LiveView provides two primary directives for form handling:

**`phx-change`**: Handles real-time input changes, fires on every keystroke, value change, or select event. Preferred at the form level where all fields are submitted to the callback:

```heex
<.form for={@form} phx-change="validate">
  <.input type="text" field={@form[:username]} />
  <.input type="email" field={@form[:email]} />
</.form>
```

**`phx-submit`**: Manages form submission with side effects like database writes, API calls, or redirects:

```heex
<.form for={@form} phx-change="validate" phx-submit="save">
  <button type="submit">Save</button>
</.form>
```

## Server-Side Form Handling

### Validate Callback

Process real-time validation without side effects:

```elixir
def handle_event("validate", %{"user" => user_params}, socket) do
  changeset =
    socket.assigns.user
    |> User.changeset(user_params)
    |> Map.put(:action, :validate)

  {:noreply, assign(socket, form: to_form(changeset))}
end
```

**Best practice**: Set `Map.put(:action, :validate)` on the changeset to show all errors without unique constraint violations.

### Save Callback

Persist data after validation passes:

```elixir
def handle_event("save", %{"user" => user_params}, socket) do
  case User.create(socket.assigns.user, user_params) do
    {:ok, user} ->
      socket =
        socket
        |> put_flash(:info, "User created!")
        |> push_navigate(to: "/users/#{user.id}")
      {:noreply, socket}

    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

## Field-Specific Event Targeting

Override form-level events for specific inputs using `phx-change` and `phx-target`:

```heex
<.form for={@form} phx-change="validate">
  <.input field={@form[:name]} />
  <.input field={@form[:date]} phx-change="parse_date" />
</.form>
```

In the callback, identify the target via `_target`:

```elixir
def handle_event("validate", %{"_target" => ["user", "date"]} = params, socket) do
  # Custom date parsing logic
  {:noreply, socket}
end
```

## Error Feedback and Unused Inputs

LiveView sends `_unused_` prefixed parameters to distinguish fields the user has never interacted with. Use `Phoenix.Component.used_input?/1` to display errors only for fields the user has engaged:

```heex
<.input field={@form[:email]} />
<.error :if={used_input?(@form, :email)}>
  <%= error_tag(@form, :email) %>
</.error>
```

This pattern prevents validation errors from appearing on untouched fields, improving UX.

## Special Input Types

### Number Inputs

LiveView prevents change events from invalid number inputs, deferring to browser validation. The input doesn't fire `phx-change` until the value is numeric:

```heex
<input type="number" phx-change="update" />
```

**Alternative for better mobile UX**: Use `type="text"` with `inputmode="numeric"` pattern:

```heex
<input
  type="text"
  inputmode="numeric"
  pattern="[0-9]*"
  phx-change="update"
/>
```

### Password Inputs

Password field values are not re-rendered (browser security restriction). Always explicitly set value using `input_value()`:

```heex
<input
  type="password"
  name="password"
  value={input_value(@form, :password)}
  phx-change="validate"
/>
```

### File Inputs

Support reactive uploads with `live_file_input/1` component:

```heex
<.live_file_input upload={@uploads.avatar} />
```

Enable drag-and-drop via `phx-drop-target` attribute on a container element.

## Form Recovery and Reconnection

Forms with `phx-change` and `id` attributes automatically recover input values after client disconnections:

```heex
<.form id="my-form" for={@form} phx-change="validate">
  <!-- values restore automatically on reconnect -->
</.form>
```

**Disable recovery** when you need custom handling:

```heex
<.form phx-auto-recover="ignore" for={@form} phx-change="validate">
  <!-- manage recovery manually -->
</.form>
```

## Advanced Patterns

### Form Reset

Trigger `phx-change` with `type="reset"` button; the `_target` will contain the reset button name:

```heex
<form phx-change="validate">
  <input type="text" name="query" />
  <button type="reset" name="reset">Clear</button>
</form>
```

```elixir
def handle_event("validate", %{"_target" => ["reset"]}, socket) do
  {:noreply, assign(socket, form: to_form(initial_changeset()))}
end
```

### HTTP Form Submission

Submit forms to a controller after LiveView validation using `phx-trigger-action`:

```heex
<.form for={@form} phx-change="validate" phx-trigger-action={@trigger_submit} action="/api/users" method="post">
  <button type="submit">Submit to API</button>
</.form>
```

### JavaScript Event Integration

Trigger form events from JavaScript hooks:

```javascript
this.el.dispatchEvent(new Event("phx-change", { bubbles: true }));
```

Prevent submission with hooks:

```javascript
document.addEventListener("submit", (e) => {
  e.stopPropagation(); // Prevents phx-submit
});
```

---

[← Back to main](phoenix_live_view-1.1.28.md)
**Version:** 1.1.28
