# Recipe: Phoenix Dual-Mode Component Pattern

## Problem

Phoenix applications often need components that work in multiple contexts - for example, a form component that can be used both in a modal overlay and as a full-page form. The component needs to adapt its navigation behavior, styling, and user interactions based on the context without duplicating code.

## Solution

Create a single component with a `:mode` assign that conditionally renders different behaviors and styling based on the context. Use pattern matching and guards to handle mode-specific logic cleanly.

## Implementation

### 1. Component with Mode Detection

```elixir
defmodule MyAppWeb.JobFormComponent do
  use MyAppWeb, :live_component

  def mount(socket) do
    {:ok, socket}
  end

  def update(assigns, socket) do
    # Default to modal mode if not specified
    mode = Map.get(assigns, :mode, :modal)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:mode, mode)}
  end

  def render(assigns) do
    ~H"""
    <div class={container_class(@mode)}>
      <.form
        for={@changeset}
        phx-submit="save"
        phx-target={@myself}
        class="space-y-6"
      >
        <!-- Form fields go here -->
        <.input field={@changeset[:title]} label="Job Title" />
        <.input field={@changeset[:description]} type="textarea" label="Description" />

        <div class="flex justify-end space-x-3">
          <.button
            type="button"
            variant="secondary"
            phx-click="cancel"
            phx-target={@myself}
          >
            Cancel
          </.button>
          <.button type="submit" variant="primary">
            Save Job
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  # Mode-specific styling
  defp container_class(:modal), do: "p-6"
  defp container_class(:page), do: "max-w-2xl mx-auto p-8"

  # Handle save - mode affects navigation
  def handle_event("save", %{"job" => job_params}, socket) do
    case Jobs.create_job(socket.assigns.company, job_params) do
      {:ok, job} ->
        maybe_navigate(socket, job)

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  # Handle cancel - different behavior per mode
  def handle_event("cancel", _params, socket) do
    maybe_cancel(socket)
  end

  # Mode-specific navigation after successful save
  defp maybe_navigate(socket, job) do
    case socket.assigns.mode do
      :modal ->
        send(self(), {:job_created, job})
        {:noreply, socket}

      :page ->
        {:noreply,
         socket
         |> put_flash(:info, "Job created successfully")
         |> push_navigate(to: socket.assigns.return_to)}
    end
  end

  # Mode-specific cancel behavior
  defp maybe_cancel(socket) do
    case socket.assigns.mode do
      :modal ->
        send(self(), :cancel_job_form)
        {:noreply, socket}

      :page ->
        {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
    end
  end
end
```

### 2. Usage in Modal Context

```elixir
defmodule MyAppWeb.JobLive.Index do
  use MyAppWeb, :live_view

  def render(assigns) do
    ~H"""
    <div>
      <.button phx-click="new_job">New Job</.button>

      <.modal :if={@show_modal} id="job-modal">
        <.live_component
          module={MyAppWeb.JobFormComponent}
          id="job-form"
          mode={:modal}
          company={@company}
          changeset={@changeset}
        />
      </.modal>
    </div>
    """
  end

  def handle_info({:job_created, job}, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> put_flash(:info, "Job created successfully")
     |> update(:jobs, &[job | &1])}
  end

  def handle_info(:cancel_job_form, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end
end
```

### 3. Usage in Full-Page Context

```elixir
defmodule MyAppWeb.JobLive.New do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    changeset = Jobs.change_job(%Job{})

    {:ok,
     socket
     |> assign(:changeset, changeset)
     |> assign(:company, socket.assigns.current_user.company)}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <.header>
        Create New Job
        <:subtitle>Fill in the details for your job posting</:subtitle>
      </.header>

      <.live_component
        module={MyAppWeb.JobFormComponent}
        id="job-form"
        mode={:page}
        company={@company}
        changeset={@changeset}
        return_to={~p"/company/jobs"}
      />
    </div>
    """
  end
end
```

## Considerations

### Benefits

- **Code reuse**: Single component handles multiple contexts
- **Consistent behavior**: Form validation and logic identical across contexts
- **Maintainability**: Changes to form logic update both modal and page versions
- **Type safety**: Pattern matching on modes catches invalid configurations

### When to Use This Pattern

- ✅ Forms that need to work in modals and full pages
- ✅ Components with context-dependent navigation
- ✅ UI elements that need different styling based on container
- ✅ When you have 2-3 distinct usage contexts

### When NOT to Use This Pattern

- ❌ When contexts are very different (better to create separate components)
- ❌ Simple components that don't need context awareness
- ❌ When mode logic makes component overly complex
- ❌ More than 3-4 modes (consider separate components instead)

### Common Pitfalls

- **Forgetting default mode**: Always provide a sensible default
- **Complex conditional rendering**: Keep mode-specific logic in separate functions
- **Missing mode validation**: Use pattern matching to catch invalid modes
- **Inconsistent prop requirements**: Different modes shouldn't require different props

### Testing Strategy

```elixir
defmodule MyAppWeb.JobFormComponentTest do
  use MyAppWeb.ConnCase

  test "modal mode sends message on save" do
    # Test modal-specific behavior
  end

  test "page mode navigates on save" do
    # Test page-specific behavior
  end

  test "styling differs between modes" do
    # Test mode-specific CSS classes
  end
end
```

## Example Usage

This pattern was successfully applied in the job-posting-figma feature to migrate from modal-only forms to supporting both modal and full-page contexts:

```elixir
# Before: Modal-only component
def handle_event("save", params, socket) do
  # Always sent message to parent LiveView
  send(self(), {:saved, result})
end

# After: Dual-mode component
def handle_event("save", params, socket) do
  case socket.assigns.mode do
    :modal -> send(self(), {:saved, result})
    :page -> push_navigate(socket, to: return_path)
  end
end
```

The migration maintained backward compatibility while adding full-page support, allowing gradual transition from modal to page-based workflows.

## Related Recipes

- [Phoenix LiveView Testing Patterns](./phoenix-liveview-testing-patterns.md)
- [Phoenix Component Migration with Backward Compatibility](./phoenix-component-migration.md)
