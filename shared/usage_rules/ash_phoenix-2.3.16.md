# ash_phoenix

ash_phoenix provides utilities for seamless integration between Ash resources and Phoenix applications, enabling fluid form handling, LiveView support, and resource-based workflows.

## Quick Start

### Installation

ash_phoenix requires Phoenix with pre-installed configuration. Add to `mix.exs`:

```elixir
{:ash_phoenix, "~> 2.3"}
```

### Generate LiveView Scaffolding

Use the built-in generator to scaffold views:

```bash
mix ash_phoenix.gen.live --domain Helpdesk.Support --resource Helpdesk.Support.Ticket
mix phx.server
```

This generates starter views and routes that serve as a foundation for further customization.

## Core Concepts

### Resource-First Development

Unlike traditional Phoenix, ash_phoenix emphasizes calling directly into Ash resources and domains instead of context functions:

```elixir
# Instead of: Helpdesk.Support.get_ticket(id)
# Use: Helpdesk.Support.Ticket |> Ash.Query.filter(id: ^id) |> Ash.read!()
```

### Form Lifecycle

Forms follow a standard workflow:

1. **Create** - Initialize with `AshPhoenix.Form.for_create/3` or `for_update/3`
2. **Render** - Use `Phoenix.Component.form` components
3. **Validate** - Call `validate/3` on `phx-change` events
4. **Submit** - Execute `submit/2` with parameters
5. **Handle** - Redirect on success or reassign form on failure

### Form State Tracking

Forms maintain lifecycle flags:

- `submitted_once?` - Prevents error display on initial interaction
- `just_submitted?` - Triggers UI effects that clear on changes
- `changed?` - Indicates modifications from original state
- `touched_forms` - MapSet of modified nested form keys

## Configuration

### Form Creation Options

Standard parameters for form creation:

- `:actor` - User performing the action (authorization)
- `:domain` - Ash domain module
- `:as` - Form name in submitted parameters (default: "form")
- `:params` - Initial values with defaults
- `:prepare_source` - Pre-processes changesets before validation
- `:transform_params` - Post-processes parameters before submission

### Nested Forms

Support relational and embedded data:

```elixir
AshPhoenix.Form.for_create(Post, :create,
  forms: [
    comments: [
      type: :list,              # :list or :single
      sparse?: true,            # Explicit removal vs omission
      create_action: :create,
      update_action: :update,
      data: related_comments
    ]
  ]
)
```

**Sparse mode:** Uses primary keys instead of indices, simplifying deeply nested updates.

### Error Handling

**Post-process errors** - Transform errors after standard conversion:

```elixir
post_process_errors: fn form, path, {field, kind, meta} ->
  # Return modified triple or nil to filter out error
  {field, kind, meta}
end
```

**Transform errors** - Manual transformation before formatting for custom error types.

### Compound Types

For composite types like `Ash.Money`, manually decompose fields:

```elixir
# Render separate inputs for amount and currency
<input name={@form[:amount].name <> "[amount]"} />
<input name={@form[:amount].name <> "[currency]"} />
```

Use `post_process_errors` to map composite field errors to individual inputs.

## Best Practices

### Form Validation Pattern

Use `validate/3` continuously during interaction (on `phx-change` events):

```elixir
def handle_event("validate", %{"form" => params}, socket) do
  form = AshPhoenix.Form.validate(socket.assigns.form, params)
  {:noreply, assign(socket, form: form)}
end
```

### Submission Pattern

Execute `submit/2` to run the Ash action:

```elixir
def handle_event("submit", _, socket) do
  case AshPhoenix.Form.submit(socket.assigns.form) do
    {:ok, record} -> {:noreply, redirect(socket, to: "/success")}
    {:error, form} -> {:noreply, assign(socket, form: form)}
  end
end
```

### Nested Form Management

- Use `add_form/3` to dynamically add nested forms
- Call `remove_form/3` explicitly in non-LiveView contexts
- Leverage `sparse?: true` for complex nested structures with multiple edits

### Learning Path

1. Complete the **Ash getting started guide** first (select Phoenix pre-installed option)
2. Study **Query operations** via Ash.Query for read operations
3. Understand **Action management** for create/update workflows
4. Explore **Authentication** with Ash Authentication Phoenix
5. Extend with **APIs** using AshJsonApi or AshGraphql

### Real-World Examples

Refer to project examples:

- **Tunez** - Full-stack Ash + Phoenix application
- **Realworld** - Multi-language example implementation

---

**Version:** 2.3.16
**Source:** [hexdocs.pm/ash_phoenix](https://hexdocs.pm/ash_phoenix/)
**Generated:** 2025-10-28
