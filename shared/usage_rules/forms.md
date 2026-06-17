# phoenix_live_view - Form Handling

## Form Structure Basics

Forms in LiveView use the `.form` component with a changeset, providing real-time validation and error tracking:

```heex
<.form for={@form} id="item-form" phx-change="validate" phx-submit="save">
  <.input type="text" field={@form[:title]} label="Title" />
  <.input type="email" field={@form[:email]} label="Email" />
  <.input type="file" field={@form[:avatar]} label="Avatar" />

  <.button type="submit" phx-disable-with="Saving...">
    Save Item
  </.button>
</.form>
```

The `.form` component generates the form element, field attributes, and error handling. The `.input` component renders labels, error messages, and input validation.

## Event Handling Pattern

### Validation Event

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, :form, to_form(%{"title" => "", "email" => ""}))}
end

def handle_event("validate", params, socket) do
  changeset =
    MySchema.changeset(%MySchema{}, params)
    |> Map.put(:action, :validate)

  {:noreply, assign(socket, :form, to_form(changeset))}
end
```

The `action: :validate` tells Ecto to run all validations without persisting.

### Save/Submit Event

```elixir
def handle_event("save", params, socket) do
  case MyContext.create_item(params) do
    {:ok, item} ->
      {:noreply,
       socket
       |> put_flash(:info, "Item created!")
       |> push_navigate(to: ~p"/items/#{item}")}

    {:error, changeset} ->
      {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
```

On success, redirect or update state. On error, re-render with validation errors.

## Error Display Strategy

LiveView doesn't show validation errors until the user interacts with a field—preventing premature feedback:

```elixir
def handle_event("validate", params, socket) do
  changeset = MySchema.changeset(%MySchema{}, params)
  # The .input component uses this mechanism internally
  {:noreply, assign(socket, :form, to_form(changeset))}
end
```

The `.input` component automatically uses `Phoenix.Component.used_input?/1` to determine which errors display—only showing errors for fields the user has touched.

For custom error handling:

```heex
<.input field={@form[:email]} />
<%= if used_input?(@form, :email) and @form.errors[:email] do %>
  <p class="error">{error_to_string(@form.errors[:email])}</p>
<% end %>
```

## Special Input Cases

### Number Inputs

Browsers clear invalid number inputs, causing unexpected behavior. Avoid `type="number"` on inputs you'll validate server-side.

```heex
<!-- ❌ Problem: Browser clears invalid entries -->
<input type="number" name="age" />

<!-- ✅ Better: Use numeric inputmode for better UX -->
<input type="text" inputmode="numeric" pattern="[0-9]*" name="age" />
```

The `.input` component handles this automatically for numeric types.

### Password Inputs

For security, password values aren't automatically re-rendered after updates. You must explicitly manage the value:

```heex
<!-- ❌ Won't show value after server update -->
<input type="password" />

<!-- ✅ Correct: Explicitly bind -->
<input type="password" name="password" value={@password} />
```

In real applications, avoid re-rendering password values unless absolutely necessary.

### File Inputs

File inputs use a special component and only work with `phx-change` and `phx-submit`:

```heex
<.form for={@form} phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />
  <button type="submit">Upload</button>
</.form>
```

The file content itself isn't returned to the server until the form submits. See [Uploads & File Handling](uploads.md) for full details.

## Nested Forms

For associations and nested data (e.g., user with multiple addresses):

```heex
<.form for={@form} phx-submit="save">
  <.input field={@form[:name]} />

  <.inputs_for :let={address_form} field={@form[:addresses]}>
    <.input field={address_form[:street]} />
    <.input field={address_form[:city]} />
  </.inputs_for>

  <button type="submit">Save</button>
</.form>
```

The `.inputs_for` component handles nested changesets and automatically manages hidden fields for deletions.

## Form Recovery

Forms with `phx-change` and an `id` attribute automatically recover input values after disconnections:

```heex
<.form id="my-form" phx-change="validate" phx-submit="save">
  <!-- After reconnection, form values are restored via phx-change -->
  <input name="title" />
</form>
```

LiveView stores form data in memory and resubmits the `phx-change` event upon reconnection, restoring the form state.

For multi-step forms or custom recovery:

```heex
<form phx-auto-recover="recovery-data">
  <!-- Custom recovery logic -->
</form>
```

## Client-Side Behavior

### Loading States

During `phx-change`:

- Input receives `phx-change-loading` CSS class

During `phx-submit`:

- Form becomes read-only (`[disabled]` on inputs)
- Submit buttons disable
- Receives `phx-submit-loading` CSS class

### Event Triggers

Submit button text changes:

```heex
<button type="submit" phx-disable-with="Saving...">
  Save
</button>

<!-- During submit: -->
<!-- <button type="submit" disabled>Saving...</button> -->
```

Restore on acknowledgment.

### Preventing Double Submission

LiveView prevents accidental duplicate submissions by:

1. Disabling the submit button
2. Setting read-only on inputs
3. Waiting for server acknowledgment

Don't prevent form submission in client-side hooks unless you have a specific reason.

## HTTP Form Submission

For forms that need to submit to HTTP routes (file downloads, redirects):

```heex
<.form for={@form} phx-change="validate" phx-submit="validate"
       phx-trigger-action={@trigger_submit} action={~p"/items/import"} method="post">
  <.input field={@form[:file]} type="file" />
  <button type="submit">Import</button>
</.form>
```

After LiveView-side validation, set `@trigger_submit = true` to submit to the HTTP route:

```elixir
def handle_event("validate", params, socket) do
  case validate_import(params) do
    {:ok, _} -> {:noreply, assign(socket, :trigger_submit, true)}
    {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
  end
end
```

## Common Patterns

**Dependent field updates**:

```elixir
def handle_event("validate", params, socket) do
  params = update_dependent_field(params)
  changeset = MySchema.changeset(%MySchema{}, params)
  {:noreply, assign(socket, :form, to_form(changeset))}
end

defp update_dependent_field(params) do
  # Auto-fill or modify fields based on other inputs
  Map.update(params, "slug", nil, &slugify/1)
end
```

**Async validation**:

```elixir
def handle_event("validate", params, socket) do
  {:noreply, assign(socket, :validating, true)}
end

def handle_info({:validation_result, changeset}, socket) do
  {:noreply, assign(socket, form: to_form(changeset), validating: false)}
end
```

---

[← Back to main](main-index.md)
**Version:** 1.1.32
