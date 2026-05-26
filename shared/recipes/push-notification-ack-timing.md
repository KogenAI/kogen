# Recipe: ACK-Based Push Notification Timing

## Problem

When implementing push notifications for real-time apps with WebSocket connections, a naive approach sends push notifications for every event. This creates problems:

1. **Duplicate notifications**: Users get both WebSocket delivery AND push notification during active chat sessions
2. **Poor UX**: Notification spam while actively using the app
3. **Connection state lag**: Checking "is WebSocket connected?" has a 40-50 second detection gap on unreliable networks
4. **Multi-device scenarios**: User may receive message on one device but still get push on another device

Traditional approaches like "only send push if WebSocket disconnected" fail on unreliable networks where connection state is stale.

## Solution

Use an **ACK-based timing pattern** with cross-process coordination:

1. Server broadcasts event via WebSocket to all connected clients
2. Server starts a timer (e.g., 10 seconds) for that specific event
3. If recipient sends ACK within timeout → cancel timer, no push notification
4. If no ACK after timeout → send push notification
5. Broadcast ACKs across all user's sockets via PubSub (for multi-device)
6. Client deduplicates: suppress push if event already received via WebSocket

**Key insight**: Verify _actual receipt_ via ACK, not _connection state_.

## Implementation

### Backend: Phoenix Channel with Timer-Based Push

```elixir
defmodule BackendWeb.ChatChannel do
  use BackendWeb, :channel

  alias Backend.Push
  alias Backend.Accounts

  # Initialize timer tracking in socket state
  def join("chat:lobby", _params, socket) do
    socket = assign(socket, :pending_push_timers, %{})
    {:ok, socket}
  end

  # Broadcast message and start push timer
  def handle_in("new_msg", %{"content" => content}, socket) do
    message = Backend.Chat.create_message(%{
      content: content,
      sender_user_id: socket.assigns.user_id
    })

    # Broadcast to all connected clients
    broadcast!(socket, "new_msg", %{
      id: message.id,
      content: message.content,
      sender_user_id: message.sender_user_id,
      inserted_at: message.inserted_at
    })

    # Start push timer for recipient
    socket = start_message_push_timer(socket, message)

    {:reply, {:ok, %{id: message.id}}, socket}
  end

  # Handle ACK and cancel push timer
  def handle_in("msg_delivered", %{"message_id" => message_id}, socket) do
    Backend.Chat.mark_delivered(message_id)

    # Cancel local timer
    socket = cancel_push_timer(socket, {:message, message_id})

    # Broadcast ACK via PubSub to cancel timers on other sockets
    Phoenix.PubSub.broadcast(
      Backend.PubSub,
      "push_acks:#{recipient_user_id(message_id)}",
      {:cancel_push_timer, {:message, message_id}}
    )

    broadcast!(socket, "msg_delivered", %{
      message_id: message_id,
      delivered_at: DateTime.utc_now()
    })

    {:noreply, socket}
  end

  # Listen for ACKs from other sockets
  def handle_info({:cancel_push_timer, timer_key}, socket) do
    socket = cancel_push_timer(socket, timer_key)
    {:noreply, socket}
  end

  # Timer expired - send push notification
  def handle_info({:send_push, {:message, message_id}}, socket) do
    message = Backend.Chat.get_message(message_id)
    recipient = Accounts.get_user(message.recipient_user_id)

    # Determine platform and token
    {platform, token} = if recipient.apns_token do
      {:ios, recipient.apns_token}
    else
      {:android, recipient.fcm_token}
    end

    if token do
      Push.send_message_notification(platform, token, %{
        message_id: message.id,
        content: message.content,
        sender_name: "User #{message.sender_user_id}",
        is_reply: message.reply_to_id != nil
      })
    end

    # Remove timer from tracking
    socket = assign(socket, :pending_push_timers,
      Map.delete(socket.assigns.pending_push_timers, {:message, message_id}))

    {:noreply, socket}
  end

  defp start_message_push_timer(socket, message) do
    recipient_user_id = if message.sender_user_id == 1, do: 2, else: 1

    # Only start timer if recipient exists and might need push
    if recipient_user_id do
      timer_ref = Process.send_after(
        self(),
        {:send_push, {:message, message.id}},
        :timer.seconds(10)
      )

      pending_timers = socket.assigns.pending_push_timers
      updated_timers = Map.put(pending_timers, {:message, message.id}, timer_ref)

      assign(socket, :pending_push_timers, updated_timers)
    else
      socket
    end
  end

  defp cancel_push_timer(socket, timer_key) do
    pending_timers = socket.assigns.pending_push_timers

    case Map.get(pending_timers, timer_key) do
      nil ->
        socket
      timer_ref ->
        Process.cancel_timer(timer_ref)
        assign(socket, :pending_push_timers, Map.delete(pending_timers, timer_key))
    end
  end

  defp recipient_user_id(message_id) do
    # Determine recipient from message
    message = Backend.Chat.get_message(message_id)
    if message.sender_user_id == 1, do: 2, else: 1
  end
end
```

### Mobile: Automatic ACK Sending

```dart
class ChatService {
  final WebSocketService _wsService;
  final Set<String> _receivedMessageIds = {};

  void _setupChannelListeners() {
    _channel!.on('new_msg', (payload) {
      final message = ChatMessage.fromJson(
        Map<String, dynamic>.from(payload as Map)
      );

      // Only send ACK for messages from others (not own messages)
      if (message.senderUserId != _userId) {
        _sendDeliveryAcknowledgment(message.id);
        _receivedMessageIds.add(message.id);
      }

      _messagesController.add(message);
    });
  }

  void _sendDeliveryAcknowledgment(String messageId) {
    _channel?.push('msg_delivered', {'message_id': messageId});
  }
}
```

### Mobile: Push Notification Deduplication

```dart
class PushNotificationService {
  Function(String type, Map<String, dynamic> data)? onPushReceived;

  void _handlePushMessage(RemoteMessage message) {
    final data = message.data;
    final type = data['type'] as String?;
    final messageId = data['message_id'] as String?;

    if (type == null || messageId == null) {
      debugPrint('Push missing type or message_id field');
      return;
    }

    // Notify ChatService for deduplication check
    if (onPushReceived != null) {
      onPushReceived!(type, Map<String, dynamic>.from(data));
    }
  }
}

class ChatService {
  final Set<String> _receivedMessageIds = {};
  final PushNotificationService _pushService;

  void initialize() {
    // Set up push notification deduplication
    _pushService.onPushReceived = (type, data) {
      final messageId = data['message_id'] as String?;

      if (messageId == null) return;

      // Suppress notification if already received via WebSocket
      if (_receivedMessageIds.contains(messageId)) {
        debugPrint('Suppressing duplicate push for message $messageId');
        return;
      }

      // Show notification - message not yet received via WebSocket
      _showPushNotification(type, data);
    };
  }
}
```

### Backend: Push Context for Sending Notifications

```elixir
defmodule Backend.Push do
  alias Pigeon.FCM.Notification, as: FCMNotification
  alias Pigeon.APNS.Notification, as: APNSNotification

  def send_message_notification(platform, token, %{
    message_id: message_id,
    content: content,
    sender_name: sender_name,
    is_reply: is_reply
  }) do
    title = "New message from #{sender_name}"
    body = if is_reply, do: "Replied: #{content}", else: content
    data = %{"type" => "message", "message_id" => message_id}

    send_notification(platform, token, title, body, data)
  end

  defp send_notification(:ios, token, title, body, data) do
    notification =
      ""
      |> APNSNotification.new(token, "chat.yourapp")
      |> APNSNotification.put_alert(%{"title" => title, "body" => body})
      |> APNSNotification.put_sound("default")
      |> APNSNotification.put_badge(1)
      |> APNSNotification.put_custom(data)

    case Backend.Push.APNS.push(notification) do
      %{response: :success} -> :ok
      %{response: :bad_device_token} -> {:error, :invalid_token}
      %{response: reason} -> {:error, :push_failed}
    end
  end

  defp send_notification(:android, token, title, body, data) do
    notification = FCMNotification.new(
      {:token, token},
      %{"title" => title, "body" => body},
      data
    )

    case Backend.Push.FCM.push(notification) do
      %{response: :success} -> :ok
      %{response: :invalid_registration} -> {:error, :invalid_token}
      %{response: reason} -> {:error, :push_failed}
    end
  end
end
```

## Considerations

### Timer Duration

- **Too short** (< 5s): May send push even when WebSocket is healthy but slow
- **Too long** (> 15s): User waits too long for notification when truly offline
- **Recommended**: 10 seconds balances reliability and responsiveness
- **Adjust based on**: Your network conditions and user expectations

### Multi-Device Coordination

- **Problem**: User A has 2 devices, both connected. Message delivered on Device 1, but Device 2's socket also has a timer.
- **Solution**: Broadcast ACKs via Phoenix.PubSub to all user's sockets
- **Subscribe pattern**: Each socket subscribes to `push_acks:#{user_id}` topic on join
- **Broadcast on ACK**: When any socket receives ACK, broadcast to cancel timers on all user's sockets

### Memory Management

- **Timer cleanup**: Process.send_after timers are automatically cancelled when channel process crashes
- **Manual cleanup**: Always remove timer refs from socket.assigns map after cancellation or timeout
- **Socket state size**: Track only active timers, remove completed ones immediately

### Event Types

Apply this pattern to different event types with unique timer keys:

- Messages: `{:message, message_id}`
- Reactions: `{:reaction, message_id, reactor_user_id}`
- Each event type may have different timeout durations

### Client-Side Deduplication

- **Track received IDs**: Maintain `Set<String>` of message IDs received via WebSocket
- **Check on push**: When push notification arrives, check if ID already in set
- **Suppress if duplicate**: Don't show notification or update UI if already received
- **Memory bounds**: Consider clearing old IDs after reasonable time period (e.g., 1 hour)

### Platform Differences

- **iOS**: Uses native APNs tokens, may have 2-10 second delay after permission grant
- **Android**: Uses FCM tokens, available immediately
- **Handle both**: Backend accepts platform parameter, routes to correct push service

## When to Use This Pattern

✅ **Good fit:**

- Real-time chat/messaging apps with WebSocket + push notifications
- Apps where users actively use the app but also need offline notifications
- Multi-device scenarios where users may be online on multiple devices
- Unreliable networks where connection state is often stale

❌ **Not needed:**

- Apps with only push notifications (no WebSocket)
- Apps where push is always desired (e.g., breaking news alerts)
- Single-device only apps where multi-socket coordination isn't needed
- Apps with highly reliable networks where connection state is trustworthy

## When NOT to Use This Pattern

- **Simple notification-only apps**: If you don't have real-time WebSocket delivery, just send push notifications immediately
- **Always-notify requirements**: If users want notifications even while actively using the app (e.g., stock price alerts)
- **Batch processing**: If events are batched/aggregated rather than individual real-time messages

## Example Usage

This pattern was successfully used in a two-person chat app for unreliable Zambian networks:

- **Problem**: 40-50 second WebSocket disconnect detection gap caused duplicate notifications
- **Solution**: ACK-based timing with 10s timeout
- **Results**:
  - No duplicate notifications during active chat sessions
  - Push notifications arrive within 10s when truly offline
  - Works correctly in multi-device scenarios (user online on iPhone + Android)
  - Client-side deduplication handles edge cases

## Related Recipes

- Push Notification Setup (FCM/APNs configuration)
- Phoenix PubSub for Cross-Process Coordination
- WebSocket Connection State Management
