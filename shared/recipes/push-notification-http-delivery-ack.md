# Recipe: HTTP Delivery Acknowledgment for Push Notifications

## Problem

Mobile apps using push notifications need to acknowledge message delivery even when the app is backgrounded or terminated. WebSocket connections are unavailable in these states (iOS kills WebSocket ~30s after backgrounding, Android may kill app entirely). Without an HTTP fallback, delivery status never updates when messages arrive via push notification.

## Solution

Provide an HTTP endpoint that push notification handlers (iOS Notification Service Extension, Android background handler) can call to acknowledge delivery. This complements WebSocket-based ACKs for when the app is active.

## Implementation

### Step 1: Add HTTP Delivery Endpoint

```elixir
# lib/your_app_web/controllers/delivery_controller.ex
defmodule YourAppWeb.DeliveryController do
  @moduledoc """
  Controller for handling message delivery acknowledgment via HTTP.

  Used by mobile Notification Service Extensions (iOS) and background message
  handlers (Android) to acknowledge message delivery when a push notification
  is received, even when the app is not open.
  """

  use YourAppWeb, :controller

  alias YourApp.Chat

  require Logger

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"id" => message_id} = params) do
    with {:ok, _user_id} <- validate_user_id(params),
         {:ok, validated_id} <- validate_message_id(message_id),
         {:ok, message} <- mark_and_broadcast(validated_id) do
      success_response(conn, message)
    else
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp validate_user_id(%{"user_id" => user_id}) when is_integer(user_id) do
    # Adjust validation for your user ID schema
    {:ok, user_id}
  end

  defp validate_user_id(%{"user_id" => user_id}) when is_binary(user_id) do
    case Integer.parse(user_id) do
      {id, ""} -> {:ok, id}
      _other -> {:error, :invalid_user_id}
    end
  end

  defp validate_user_id(_params), do: {:error, :invalid_user_id}

  defp validate_message_id(message_id) do
    case Ecto.UUID.cast(message_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_message_id}
    end
  end

  defp mark_and_broadcast(message_id) do
    case Chat.mark_message_delivered(message_id) do
      {:ok, message} ->
        broadcast_delivery(message)
        {:ok, message}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp broadcast_delivery(message) do
    YourAppWeb.Endpoint.broadcast("chat:lobby", "msg_delivered", %{
      delivered_at: DateTime.to_iso8601(message.delivered_at),
      message_id: message.id
    })
  end

  defp success_response(conn, message) do
    conn
    |> put_status(:ok)
    |> json(%{
      delivered_at: DateTime.to_iso8601(message.delivered_at),
      message_id: message.id,
      success: true
    })
  end

  defp error_response(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not_found", success: false})
  end

  defp error_response(conn, :invalid_message_id) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_message_id", success: false})
  end

  defp error_response(conn, :invalid_user_id) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "invalid_user_id", success: false})
  end
end
```

### Step 2: Add Route

```elixir
# lib/your_app_web/router.ex
scope "/api", YourAppWeb do
  pipe_through :api

  # ... other routes

  # HTTP delivery acknowledgment for push notification handlers
  post "/messages/:id/delivered", DeliveryController, :create
end
```

### Step 3: Context Function for Delivery

```elixir
# lib/your_app/chat.ex
defmodule YourApp.Chat do
  alias YourApp.Chat.Message
  alias YourApp.Repo

  @doc """
  Marks a message as delivered via HTTP (for push notification handlers).
  Returns {:ok, message} or {:error, :not_found}.
  """
  def mark_message_delivered(message_id) do
    case Repo.get(Message, message_id) do
      nil ->
        {:error, :not_found}

      message ->
        # Only update if not already delivered
        if is_nil(message.delivered_at) do
          message
          |> Ecto.Changeset.change(%{delivered_at: DateTime.utc_now()})
          |> Repo.update()
        else
          {:ok, message}
        end
    end
  end
end
```

### Step 4: Android Background Handler

```dart
// lib/services/push_notification_service.dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Extract message data
  final messageId = message.data['message_id'];
  final recipientUserId = message.data['recipient_user_id'];

  if (messageId != null && recipientUserId != null) {
    // Call HTTP delivery ACK endpoint
    try {
      final response = await http.post(
        Uri.parse('https://your-api.com/api/messages/$messageId/delivered'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'user_id': int.parse(recipientUserId)}),
      );

      if (response.statusCode == 200) {
        print('✅ Delivery ACK sent for message $messageId');
      } else {
        print('⚠️ Delivery ACK failed: ${response.statusCode}');
      }
    } catch (e) {
      print('❌ Delivery ACK error: $e');
    }
  }
}

class PushNotificationService {
  static Future<void> initialize() async {
    // Register background handler BEFORE any message listeners
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // ... rest of initialization
  }
}
```

### Step 5: iOS Notification Service Extension (Optional)

**Note**: iOS NSE is complex and requires proper Apple Developer Portal setup. For MVP, Android background handler may be sufficient.

```swift
// NotificationService/NotificationService.swift
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                            withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let messageId = content.userInfo["message_id"] as? String,
              let recipientUserId = content.userInfo["recipient_user_id"] as? String else {
            contentHandler(request.content)
            return
        }

        // Call HTTP delivery ACK endpoint
        let url = URL(string: "https://your-api.com/api/messages/\(messageId)/delivered")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["user_id": Int(recipientUserId)!])

        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                os_log("Delivery ACK response: %d", httpResponse.statusCode)
            }
            contentHandler(content)
        }.resume()
    }
}
```

### Step 6: Backend Push Payload Configuration

```elixir
# Include recipient_user_id in push notification payload
defp build_notification(message, recipient_user) do
  %{
    "message_id" => message.id,
    "recipient_user_id" => recipient_user.id,  # Required for HTTP ACK
    "sender_id" => message.sender_user_id,
    "content" => truncate_content(message.content),
    # iOS-specific
    "mutable-content" => 1  # Required for iOS NSE to intercept
  }
end
```

## Considerations

### Critical Requirements

- **Include message_id**: Push payload must include message_id for ACK endpoint
- **Include recipient_user_id**: Required for validation in HTTP endpoint
- **Idempotent ACK**: Handle duplicate ACKs gracefully (check if already delivered)
- **Broadcast after HTTP ACK**: Broadcast delivery confirmation to WebSocket clients
- **iOS mutable-content**: Set to 1 for iOS NSE to intercept notification

### When to Use This Pattern

✅ **Use when:**

- App uses push notifications for message delivery
- Need delivery status updates when app is backgrounded/terminated
- WebSocket connection unreliable or unavailable in background
- Two-way communication (not just one-way broadcasts)

❌ **Don't use when:**

- App is always-foreground (e.g., kiosk app)
- Delivery status not important (one-way broadcasts only)
- Using third-party chat SDK (they handle this)

### Platform Limitations

**iOS**:

- NSE requires proper Apple Developer Portal configuration
- NSE may not be invoked if notification shown while app foreground
- 30-second execution time limit for NSE
- Complex to debug (use os_log, not print)

**Android**:

- Background handler works reliably
- OEM battery optimization may kill app entirely
- Firebase background handler must be top-level function
- Requires @pragma('vm:entry-point') annotation

### Testing Strategy

```elixir
# test/your_app_web/controllers/delivery_controller_test.exs
defmodule YourAppWeb.DeliveryControllerTest do
  use YourAppWeb.ConnCase

  describe "POST /api/messages/:id/delivered" do
    test "marks message as delivered and returns success", %{conn: conn} do
      message = insert(:message, delivered_at: nil)

      conn = post(conn, ~p"/api/messages/#{message.id}/delivered", %{
        "user_id" => message.recipient_user_id
      })

      assert %{
        "success" => true,
        "message_id" => message_id,
        "delivered_at" => delivered_at
      } = json_response(conn, 200)

      # Verify database updated
      updated = Repo.get!(Message, message.id)
      refute is_nil(updated.delivered_at)
    end

    test "returns error for invalid message_id", %{conn: conn} do
      conn = post(conn, ~p"/api/messages/invalid-uuid/delivered", %{
        "user_id" => 1
      })

      assert %{"error" => "invalid_message_id"} = json_response(conn, 400)
    end

    test "returns error for non-existent message", %{conn: conn} do
      uuid = Ecto.UUID.generate()
      conn = post(conn, ~p"/api/messages/#{uuid}/delivered", %{
        "user_id" => 1
      })

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
```

## Example Usage

From the nalikutemwa staging feature:

```dart
// Android background handler (works reliably)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final messageId = message.data['message_id'];
  final recipientUserId = message.data['recipient_user_id'];

  if (messageId != null && recipientUserId != null) {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/messages/$messageId/delivered'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'user_id': int.parse(recipientUserId)}),
    );
    // Result: Delivery status updated even when app terminated
  }
}
```

**Result**: Android users see delivery status update immediately when push notification arrives, even when app is terminated. iOS NSE deferred to future work due to Apple Developer Portal complexity.

## Related Recipes

- push-notification-ack-timing.md - When to send push notifications
- phoenix-channels-messagepack-flutter.md - WebSocket-based ACKs for foreground
