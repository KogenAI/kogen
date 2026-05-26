# ash_state_machine

Ash State Machine is an extension for the Ash framework that enables building finite state machines within Ash resources. It provides structured state management with automatic validation of state transitions and action-based state changes.

## Quick Start

### Installation

Add to `mix.exs`:

```elixir
{:ash_state_machine, "~> 0.2.12"}
```

### Basic Setup

Enable the extension in your resource:

```elixir
defmodule MyApp.Resource do
  use Ash.Resource,
    extensions: [AshStateMachine]

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
  end
end
```

## Core Concepts

### States and Initial State

Define available states and which state new resources start in:

```elixir
state_machine do
  initial_states [:pending, :draft]
  default_initial_state :pending
end
```

- **initial_states**: All possible states the resource can be in
- **default_initial_state**: State assigned to newly created resources

### Transitions

Specify which actions trigger state changes and their allowed paths:

```elixir
state_machine do
  transitions do
    transition :begin, from: :pending, to: [:started, :cancelled]
    transition :complete, from: :started, to: [:completed, :archived]
  end
end
```

Each transition defines:

- **Action name**: The Ash action that triggers the transition
- **from**: Source state(s)
- **to**: Possible destination states

### State Changes in Actions

Use `transition_state/2` to change state during action execution:

```elixir
actions do
  update :begin do
    change transition_state(:started)
  end

  update :retry do
    change transition_state(:pending)
  end
end
```

For conditional transitions, implement custom change modules:

```elixir
defmodule ConditionalStateChange do
  use Ash.Resource.Change

  def change(changeset, _opts) do
    case determine_destination(changeset) do
      :approved -> Ash.Changeset.change(changeset, :state, :approved)
      :rejected -> Ash.Changeset.change(changeset, :state, :rejected)
    end
  end

  defp determine_destination(changeset), do: :approved
end

actions do
  update :review do
    change ConditionalStateChange
  end
end
```

### Custom State Attribute

Override the default `:state` attribute:

```elixir
state_machine do
  state_attribute(:status)
end
```

Or declare it manually with custom constraints:

```elixir
attributes do
  attribute :status, :atom do
    constraints one_of: [:pending, :active, :completed]
  end
end

state_machine do
  state_attribute(:status)
end
```

## Configuration

### State Machine DSL

```elixir
state_machine do
  # Define available states
  initial_states [:pending, :active, :completed]
  default_initial_state :pending

  # Override state attribute name (default: :state)
  state_attribute(:custom_state)

  # Define allowed transitions
  transitions do
    transition :activate, from: :pending, to: :active
    transition :deactivate, from: :active, to: :pending
    transition :finish, from: :active, to: :completed
  end
end
```

### Helper Functions

**possible_next_states(resource)**
Returns all possible next states regardless of action:

```elixir
Ash.StateMachine.possible_next_states(MyResource)
# Returns: [:active, :archived, :cancelled]
```

**possible_next_states(resource, action)**
Returns possible states for a specific action:

```elixir
Ash.StateMachine.possible_next_states(MyResource, :activate)
# Returns: [:active]
```

**transition_state(destination_state)**
Change used in actions to transition state:

```elixir
change transition_state(:completed)
```

## Best Practices

### Design Pattern: Event-Driven Workflow

Structure transitions around business events rather than arbitrary state changes:

```elixir
state_machine do
  initial_states [:draft]
  default_initial_state :draft

  transitions do
    transition :submit, from: :draft, to: :submitted
    transition :approve, from: :submitted, to: :approved
    transition :publish, from: :approved, to: :published
    transition :reject, from: :submitted, to: :draft
  end
end
```

### Validation and Guards

Enforce business rules using action validations before state transitions:

```elixir
actions do
  update :submit do
    validate required(:title)
    validate required(:description)
    change transition_state(:submitted)
  end
end
```

### State Attribute Declaration

Always be explicit about state attribute type:

```elixir
attributes do
  attribute :state, :atom do
    constraints one_of: [:pending, :active, :completed]
    default :pending
  end
end
```

### Visualization

Generate flow charts to document state machines:

```bash
mix ash_state_machine.generate_flow_charts
```

This creates visual diagrams of state transitions for all resources with state machines.

### Conditional Logic

For complex decision logic, separate state determination from the change:

```elixir
defmodule ProcessEligibility do
  def eligible_for_approval?(changeset) do
    changeset.changes[:priority] == :high or
    changeset.changes[:days_pending] >= 7
  end
end

actions do
  update :review do
    change fn changeset, _context ->
      if ProcessEligibility.eligible_for_approval?(changeset) do
        transition_state(:approved).change(changeset, [])
      else
        transition_state(:pending).change(changeset, [])
      end
    end
  end
end
```

---

**Version:** 0.2.12
**Source:** [hexdocs.pm/ash_state_machine](https://hexdocs.pm/ash_state_machine/)
**Generated:** 2025-10-28
