# ash - Notifications & Side Effects

## Notifiers Overview

Notifiers enable you to respond to create, update, and destroy actions on resources. Their key advantage: "Notifiers are called after the current transaction is committed," preventing race conditions where other processes try to access newly created records before the transaction closes.

Notifiers are designed for "at most once" side effects—scenarios where it's acceptable if the effect occasionally fails without affecting the primary operation.

## Use Cases for Notifiers

Common scenarios where notifiers are appropriate:

- Publishing to Phoenix PubSub to notify LiveViews of changes
- Sending analytics events
- Real-time notifications to other application components
- Updating caches or search indices
- Logging events to external systems
- Triggering webhooks

## When NOT to Use Notifiers

If an event absolutely must occur, consider alternatives:

- **Oban**: Commit background jobs within the same transaction as your changes
- **Reactor**: A framework designed for writing "sagas" with native Ash integration
- **Validations**: For blocking operations that should prevent the action

Use these alternatives when failures must be prevented or operations must be guaranteed.

## Implementing Notifiers

### Built-in PubSub Notifier

```elixir
defmodule MyApp.Posts.Post do
  use Ash.Resource

  attributes do
    uuid_primary_key :id
    attribute :title, :string
    attribute :content, :string
  end

  actions do
    create :create do
      accept [:title, :content]
      notifiers [Ash.Notifier.PubSub]
    end

    update :update do
      accept [:title, :content]
      notifiers [Ash.Notifier.PubSub]
    end

    destroy :destroy do
      notifiers [Ash.Notifier.PubSub]
    end
  end
end
```

### Custom Notifier Implementation

Implement the `Ash.Notifier` behavior:

```elixir
defmodule MyApp.Notifiers.SendEmailNotifier do
  use Ash.Notifier

  def notify(notification) do
    # notification contains:
    # - resource: The resource being changed
    # - action: The action executed
    # - actor: The user performing the action
    # - data: The record(s) affected

    case notification do
      %{action: %{name: :register}} ->
        send_welcome_email(notification.data)

      %{action: %{name: :order_placed}} ->
        send_order_confirmation(notification.data)

      _ ->
        :ok
    end

    :ok
  end

  defp send_welcome_email(user) do
    MyApp.Emails.send_welcome(user)
  end

  defp send_order_confirmation(order) do
    MyApp.Emails.send_order_confirmation(order)
  end
end
```

### Using Custom Notifiers

Three ways to attach notifiers:

#### Resource-level (as extension)

```elixir
use Ash.Resource, notifiers: [MyApp.Notifiers.SendEmailNotifier]
```

#### For specific actions

```elixir
actions do
  create :register do
    notifiers [MyApp.Notifiers.SendEmailNotifier]
  end
end
```

#### Without compile-time dependencies

```elixir
use Ash.Resource, simple_notifiers: [MyApp.Notifiers.SendEmailNotifier]
```

## Notification Content

Notifiers receive an `Ash.Notifier.Notification` struct:

```elixir
defmodule MyApp.Notifiers.LogNotifier do
  use Ash.Notifier

  def notify(%{
    resource: resource,
    action: action,
    actor: actor,
    data: data,
    old_data: old_data
  }) do
    Logger.info("Action #{action.name} on #{inspect(resource)}", %{
      actor: inspect(actor),
      new: inspect(data),
      old: inspect(old_data)
    })
    :ok
  end
end
```

Fields available:

- **`resource`** - The Ash resource module
- **`action`** - The action being executed
- **`actor`** - The user/actor performing the action
- **`data`** - The record(s) created/updated/destroyed
- **`old_data`** - Previous state (for updates)

## Important Constraints

### Notifiers Should Be Fast

Notifiers should not do intensive synchronous work—they block the response to the client:

```elixir
# ❌ Don't block with slow operations
defmodule MyApp.Notifiers.BadNotifier do
  use Ash.Notifier

  def notify(notification) do
    # Don't download large files
    {:ok, file} = HTTPClient.get("https://api.example.com/large-file.bin")

    # Don't perform expensive calculations
    expensive_analysis(notification.data)

    :ok
  end
end

# ✅ Delegate heavy work to background jobs
defmodule MyApp.Notifiers.GoodNotifier do
  use Ash.Notifier

  def notify(notification) do
    # Enqueue work in Oban
    MyApp.ProcessFileJob.new(%{data_id: notification.data.id})
    |> Oban.insert()

    :ok
  end
end
```

### No Side Effect Guarantees

Notifiers are best-effort. If the notifier fails, the primary operation succeeds:

```elixir
# Notifier might fail and message won't be sent
# but the record is still created
defmodule MyApp.Notifiers.PubSubNotifier do
  use Ash.Notifier

  def notify(notification) do
    # This might fail - that's okay for notifiers
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "posts:created",
      {:post_created, notification.data}
    )
    :ok
  rescue
    _error -> :ok  # Fail gracefully
  end
end
```

## Advanced Patterns

### Conditional Notifications

```elixir
defmodule MyApp.Notifiers.ConditionalNotifier do
  use Ash.Notifier

  def notify(%{action: %{name: :create}, data: user}) do
    if should_send_welcome_email?(user) do
      MyApp.Emails.send_welcome(user)
    end
    :ok
  end

  def notify(_), do: :ok

  defp should_send_welcome_email?(user) do
    user.status == :active and user.email_verified?
  end
end
```

### Composing Notifiers

```elixir
defmodule MyApp.Notifiers.CompositeNotifier do
  use Ash.Notifier

  @notifiers [
    MyApp.Notifiers.LogNotifier,
    MyApp.Notifiers.PubSubNotifier,
    MyApp.Notifiers.WebhookNotifier
  ]

  def notify(notification) do
    Enum.each(@notifiers, &apply(&1, :notify, [notification]))
    :ok
  end
end

# Use in resource
use Ash.Resource, notifiers: [MyApp.Notifiers.CompositeNotifier]
```

### Accessing Related Data

Load relationships in notifiers for enriched context:

```elixir
defmodule MyApp.Notifiers.EmailNotifier do
  use Ash.Notifier

  def notify(%{action: %{name: :create}, data: post}) do
    # Load author information
    post = Ash.load!(post, :author)

    # Use author data in email
    MyApp.Emails.send_new_post_notification(post.author, post)
    :ok
  end

  def notify(_), do: :ok
end
```

---

[← Back to main](ash-3.7.6.md)
**Version:** 3.7.6
