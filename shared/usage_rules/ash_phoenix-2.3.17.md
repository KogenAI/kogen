# ash_phoenix

Ash Phoenix integrates the Ash framework with Phoenix web development. It provides form builders, LiveView utilities, generators, and domain-driven design patterns for building web applications with Ash resources instead of traditional context functions.

## Quick Start

### Prerequisites

- Complete Ash framework's getting started guide
- **Critical**: Select the option to create a new application with Phoenix pre-installed (Phoenix cannot be easily integrated afterward)

### Generate LiveView Interface

```bash
mix ash_phoenix.gen.live --domain Helpdesk.Support --resource Helpdesk.Support.Ticket
mix phx.server
```

### Basic Form Integration

```elixir
# Create a form
form = AshPhoenix.Form.for_create(resource, :create)

# Validate on user input
form = AshPhoenix.Form.validate(form, params)

# Submit form
case AshPhoenix.Form.submit(form) do
  {:ok, result} -> result
  {:error, form} -> form
end
```

## Core Concepts

### Forms as First-Class Citizens

- `AshPhoenix.Form` bridges Ash actions and Phoenix forms
- Handles validation, error management, and state tracking automatically
- Supports create, update, and destroy actions via `for_create/3`, `for_update/3`, `for_destroy/3`
- Fluent API for chaining operations

### Form Lifecycle

1. **Creation** - Initialize form for a specific action
2. **Rendering** - Display with Phoenix form components
3. **Validation** - Call `validate/3` on `phx-change` events (LiveView)
4. **Submission** - Execute `submit/2` on form submission

### Nested Forms

- Automatically managed through `manage_relationship` changes
- Configure with `:forms` option specifying cardinality (`:list` or `:single`)
- Supports dynamic addition/removal via `add_form/3` and `remove_form/3`
- Use sparse mode for explicit removal in complex relationships

### Form State Tracking

- `submitted_once?` - Delay error display until first submission
- `just_submitted?` - Detect immediate post-submission state
- `changed?` - Identify user modifications
- `touched_forms` - Track which fields users have interacted with

## Configuration

### Code Interfaces

Use code interfaces with `define` and `form do` blocks for cleaner action references:

```elixir
defmodule Post do
  define :create_form, action: :create
  define :update_form, action: :update
end
```

### Prepare Source

Apply defaults before validation:

```elixir
prepare_source(fn source, _ ->
  {:ok, Map.put(source, :author_id, current_user.id)}
end)
```

### Nested Form Configuration

```elixir
# In your action definition
form do
  forms do
    form :author, :list do
      sparse? true
      for :create_author
    end
  end
end
```

### Error Handling

- `post_process_errors/1` - Filter or remap errors after conversion
- `transform_errors/2` - Manual error manipulation before formatting
- Handle composite input types with custom error handlers

## Available Modules and Generators

### Core Modules

- `AshPhoenix.Form` - Resource form integration
- `AshPhoenix.Form.Auto` - Automatic nested form generation
- `AshPhoenix.FilterForm` - Complex filter form builders
- `AshPhoenix.LiveView` - Query synchronization in LiveView
- `AshPhoenix.AshEnum` - Enum type utilities

### Mix Tasks

- `mix ash_phoenix.gen.live` - Generate LiveView modules with resource integration
- `mix ash_phoenix.gen.html` - Generate Phoenix controllers and views
- `mix ash_phoenix.install` - Project installation and setup

## Best Practices

### Form Design

- Use `for_create`, `for_update`, `for_destroy` for appropriate lifecycle stages
- Apply `touch/2` and `update_params/3` for custom input handling
- Leverage sparse mode for managing nested forms with deletion
- Call `validate/3` on every input change (LiveView phx-change events)

### Error Display

- Check `submitted_once?` before displaying errors to avoid premature validation messages
- Use `errors/2` to access formatted error messages per field
- Implement custom error handlers for domain-specific validation feedback

### Working with Resources

- Call Ash resources and domains directly instead of context functions
- Use `Ash.Query` for querying and relationship handling
- Refer to resource definitions for available actions and relationships
- Implement authentication via AshAuthentication.Phoenix

### State Management

- Track form state through changed?, touched_forms, and submitted_once? flags
- Use just_submitted? to conditionally apply post-submission logic
- Store form state in socket assigns for LiveView persistence

### Learning Path

1. Master `AshPhoenix.Form` for basic CRUD operations
2. Explore nested forms for relational data
3. Learn `AshPhoenix.LiveView` for real-time synchronization
4. Study reference projects: Realworld app, tunez application from Ash book
5. Integrate authentication with AshAuthentication.Phoenix

---

**Version:** 2.3.17
**Source:** [hexdocs.pm/ash_phoenix](https://hexdocs.pm/ash_phoenix/)
**Generated:** 2025-11-04
