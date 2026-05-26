# phoenix_live_view - Form Handling and Data Binding

## Form Event Patterns

Phoenix LiveView provides two primary mechanisms for form interaction:

**phx-change:**
Fires on any input modification and receives all form field values in a map. Preferred pattern is handling input changes at form level rather than individual inputs. This allows validation against the complete form state rather than isolated fields.

```elixir
def handle_event("validate", %{"user" => params}, socket) do
  form =
    %User{}
    |> Accounts.change_user(params)
    |> to_form(action: :validate)
  {:noreply, assign(socket, form: form)}
end
```

**phx-submit:**
Triggers when the form submits, sent after phx-change if both are bound. Use phx-submit for operations with side effects like database writes. The server receives complete form data and can perform validation before persistence.

```elixir
def handle_event("save", %{"user" => params}, socket) do
  case Accounts.update_user(socket.assigns.user, params) do
    {:ok, user} ->
      {:noreply, assign(socket, user: user) |> put_flash(:info, "Saved")}
    {:error, changeset} ->
      {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end
end
```

## Template Form Structure

Forms bind with the `.form` component that wraps a changeset:

```heex
<.form let={f} for={@form} phx-change="validate" phx-submit="save">
  <%= text_input f, :name %>
  <%= email_input f, :email %>
  <%= error_tag f, :email %>
  <button>Save</button>
</.form>
```

The `let` binding unpacks form field helpers. All form fields automatically serialize to the map passed to handle_event. Error tags display validation errors from changeset as component state.

## Input-Level Customization

Individual inputs can override form-level binding with their own `phx-change` and `phx-target` attributes, though they must remain within a form element. This enables targeting specific components or LiveViews when needed:

```heex
<form phx-change="form_change">
  <input name="search" phx-change="search" phx-debounce="300" />
  <input name="filter" phx-change="apply_filter" />
</form>
```

Different inputs target different handler callbacks while remaining in the same form context.

## Error Handling and Field Validation

**Unused Field Tracking:**
When phx-change fires, fields the user hasn't interacted with receive parameters prefixed with `_unused_`. Use `Phoenix.Component.used_input?/1` to filter which errors display:

```heex
<.error_tag form={@form} field={:email} filter={used_input?(@form, :email)} />
```

This prevents showing validation errors for fields the user hasn't touched yet, improving UX. Errors display only after user interaction or form submission.

**Automatic Recovery:**
Forms with `id` attributes and `phx-change` bindings automatically recover input values after disconnections or LiveView crashes—unless explicitly disabled with `phx-auto-recover="ignore"`. LiveView maintains input state client-side and restores it after reconnection, providing resilience without explicit handling.

## Specialized Input Types

**Number Inputs:**
LiveView prevents change events for inputs with invalid values, deferring validation to browser native input validation. The server doesn't receive invalid number events—only valid numeric values trigger callbacks.

**Password Fields:**
Password inputs require explicit value assignment in templates for security reasons. LiveView doesn't auto-populate password fields from assigns, even if present in state.

```heex
<password_input form={@form} field={:password} value={@form[:password].value} />
```

**File Inputs:**
Standard input elements don't integrate directly with LiveView forms. Use `live_file_input` component with `allow_upload/3` for reactive file handling with validation and progress tracking.

## Form Utilities and Modifiers

**phx-disable-with:**
Disables the button and shows alternate text during submission:

```heex
<button phx-disable-with="Saving...">Save</button>
```

**phx-trigger-action:**
Submits the form normally via HTTP instead of phx-submit when specific conditions met. Useful for file downloads or redirects.

**phx-debounce/phx-throttle:**
Debounce delays event emission until the user stops typing (milliseconds or "blur" for blur event). Throttle limits event frequency to prevent server flooding from rapid input changes.

```heex
<input name="search" phx-change="search" phx-debounce="500" />
```

## Data Binding Best Practices

- Always handle `phx-change` and `phx-submit` at form level, not individual inputs
- Use changesets for validation to maintain single source of truth
- Filter error display with `used_input?` for better UX
- Leverage phx-debounce for expensive operations like search
- Validate client-side with HTML5 attributes, server-side with changesets
- Never rely solely on phx-auto-recover for critical data—persist to database

---

[← Back to main](phoenix_live_view-1.1.16.md)
**Version:** 1.1.16
