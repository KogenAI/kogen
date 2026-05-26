# phoenix_live_view - Form Bindings & Validation

## Form Events: phx-change & phx-submit

Two primary events handle forms: `phx-change` for real-time updates (as the user types) and `phx-submit` for final submission.

```html
<.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
  <.input type="text" field={@form[:username]} />
  <.input type="email" field={@form[:email]} />
  <button>Save</button>
</.form>
```

**phx-change** fires whenever any form field changes, sending all field values to the server. Use this for live validation and progressive feedback.

**phx-submit** fires on form submission (button click or Enter), typically for persistence. It receives the full form data.

Both events include all form field values as a map: `%{"user" => %{"username" => "alice", "email" => "alice@example.com"}}`

## Validation Callback

Handle `phx-change` to update a changeset without persisting:

```elixir
@impl true
def handle_event("validate", %{"user" => params}, socket) do
  form = %User{}
    |> Accounts.change_user(params)
    |> to_form(action: :validate)

  {:noreply, assign(socket, form: form)}
end
```

The `action: :validate` tells the changeset to run validations but not database checks. `to_form/1` converts the changeset to a form struct compatible with the `.form` component.

Use `Phoenix.Component.used_input?/1` in templates to display errors only on fields the user has modified:

```heex
<.input field={@form[:email]} />
<.error :if={used_input?(@form, :email)}>
  <%= inspect(@form[:email].errors) %>
</.error>
```

## Submit Callback

Handle `phx-submit` for persistence and navigation:

```elixir
@impl true
def handle_event("save", %{"user" => user_params}, socket) do
  case Accounts.create_user(user_params) do
    {:ok, user} ->
      {:noreply,
       socket
       |> put_flash(:info, "User created successfully")
       |> redirect(to: ~p"/users/#{user}")}
    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset))}
  end
end
```

On success, use `redirect/2` for full page reload or `push_navigate/2` to switch LiveViews. On error, re-assign the form with the failed changeset so errors display.

## Form Recovery

Forms with both `id` and `phx-change` automatically recover input values after disconnections by re-triggering validation. The server's changeset validation repopulates form state without data loss.

Disable auto-recovery with `phx-auto-recover="ignore"` if you want user inputs lost on reconnect.

## Input Events & Targeting

Trigger specific callbacks for individual inputs:

```heex
<.input
  field={@form[:email]}
  phx-change="validate-email"
  phx-target={@myself}
/>
```

`phx-target={@myself}` sends the event to the current component instead of the parent LiveView.

## File Uploads in Forms

Combine `phx-change` and `phx-submit` with `live_file_input`:

```heex
<.form for={@form} id="upload-form" phx-change="validate" phx-submit="save">
  <.input type="text" field={@form[:name]} />
  <.live_file_input upload={@uploads.avatar} />
  <button type="submit">Save</button>
</.form>
```

The `phx-change` event fires as files are selected. Validate the form including file entries:

```elixir
def handle_event("validate", %{"user" => params}, socket) do
  form = %User{}
    |> Accounts.change_user(params)
    |> Map.put(:action, :validate)
    |> to_form()

  {:noreply, assign(socket, form: form)}
end
```

## Button Behavior During Submission

Use `phx-disable-with` to show loading state:

```heex
<button phx-disable-with="Saving...">Save</button>
```

The button disables and displays "Saving..." during submission. The form gets the CSS class `phx-submit-loading` for styling.

## Client-Side Input Management

The JavaScript client maintains focus for the currently focused input—the server never overwrites it during updates. This prevents jarring cursor jumps while typing. After submission, all inputs briefly become read-only to prevent double-submission.

## Nested Inputs

Use `.inputs_for` for handling Ecto associations:

```heex
<.inputs_for :let={f} field={@form[:addresses]}>
  <.input type="text" field={f[:street]} />
  <.input type="text" field={f[:city]} />
</.inputs_for>
```

This component automatically manages hidden fields for `_destroy` and association IDs.

---

[← Back to main](phoenix_live_view-1.1.25.md)
**Version:** 1.1.25
