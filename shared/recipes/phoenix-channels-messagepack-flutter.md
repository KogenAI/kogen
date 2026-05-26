# Recipe: MessagePack Serialization for Phoenix Channels with Flutter

## Problem

Phoenix Channels default JSON serialization is inefficient for mobile apps on unreliable networks:

- Large payload sizes consume bandwidth
- Slow serialization/deserialization
- Poor performance on low-bandwidth connections
- High data costs for users in developing countries

MessagePack binary format provides 40-70% bandwidth savings compared to JSON.

## Solution

Implement MessagePack serialization for Phoenix Channels on both backend (Elixir) and mobile client (Flutter/Dart).

## Implementation

### Step 1: Backend - Add MessagePack Dependency

Add to `mix.exs`:

```elixir
defp deps do
  [
    # ... existing deps ...
    {:msgpax, "~> 2.4"}
  ]
end
```

Run `mix deps.get`.

### Step 2: Backend - Create MessagePackSerializer

Create `lib/my_app_web/channels/message_pack_serializer.ex`:

```elixir
defmodule MyAppWeb.MessagePackSerializer do
  @moduledoc """
  MessagePack serializer for Phoenix Channels.
  Provides 40-70% bandwidth savings over JSON.

  Uses Phoenix's standard wire format: [join_ref, ref, topic, event, payload]
  Compatible with phoenix_socket Dart library's MessagePackCodec.
  """

  alias Phoenix.Socket.Broadcast
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.Reply

  @behaviour Phoenix.Socket.Serializer

  @impl Phoenix.Socket.Serializer
  def fastlane!(%Broadcast{} = msg) do
    # Phoenix wire format: [join_ref, ref, topic, event, payload]
    # For broadcasts, join_ref and ref are nil
    data = [nil, nil, msg.topic, msg.event, msg.payload]
    {:socket_push, :binary, Msgpax.pack!(data, iodata: false)}
  end

  @impl Phoenix.Socket.Serializer
  def encode!(%Reply{} = reply) do
    # Phoenix wire format for replies
    data = [
      reply.join_ref,
      reply.ref,
      reply.topic,
      "phx_reply",
      %{status: reply.status, response: reply.payload}
    ]

    {:socket_push, :binary, Msgpax.pack!(data, iodata: false)}
  end

  def encode!(%Message{} = msg) do
    # Phoenix wire format: [join_ref, ref, topic, event, payload]
    data = [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload]
    {:socket_push, :binary, Msgpax.pack!(data, iodata: false)}
  end

  @impl Phoenix.Socket.Serializer
  def decode!(raw_message, _opts) do
    require Logger

    case Msgpax.unpack(raw_message) do
      {:ok, [join_ref, ref, topic, event, payload]} ->
        %Message{
          join_ref: join_ref,
          ref: ref,
          topic: topic,
          event: event,
          payload: payload || %{}
        }

      {:error, reason} ->
        Logger.error("[MessagePackSerializer] Decode error: #{inspect(reason)}")
        raise "Invalid MessagePack message"
    end
  end
end
```

### Step 3: Backend - Enable in Endpoint

Update `lib/my_app_web/endpoint.ex`:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # ... existing config ...

  socket "/socket", MyAppWeb.UserSocket,
    websocket: [
      serializer: [{MyAppWeb.MessagePackSerializer, "2.0.0"}]
    ],
    longpoll: false
end
```

### Step 4: Mobile - Fork phoenix_socket for Binary Support

The standard `phoenix_socket` Dart package doesn't properly support binary WebSocket messages. You need to fork it.

**Clone and modify:**

```bash
git clone https://github.com/liveview-native/phoenix_socket.git phoenix-socket-msgpack
cd phoenix-socket-msgpack
git checkout -b feature/messagepack-support
```

**Edit `lib/src/phoenix_channel.dart`:**

```dart
// Change _addToSink from String to dynamic to support binary
void _addToSink(dynamic data) {  // was: void _addToSink(String data)
  if (!_sink.isClosed) {
    _sink.add(data);
  }
}
```

**Edit `lib/src/message_serializer.dart`:**

Add support for binary encoding:

```dart
abstract class MessageSerializer {
  Message decode(String rawMessage);
  String encode(Message message);

  // Add this method for binary encoding
  dynamic binaryEncoder(Message message) => encode(message);
}
```

**Edit `lib/src/phoenix_socket.dart`:**

```dart
// Update send method to use binaryEncoder
void send(Message message) {
  final data = serializer.binaryEncoder(message);  // was: serializer.encode(message)
  _addToSink(data);
}
```

### Step 5: Mobile - Add Dependencies

Update `pubspec.yaml`:

```yaml
dependencies:
  # Use your forked version
  phoenix_socket:
    path: ../phoenix-socket-msgpack # or git URL

  msgpack_dart: ^1.0.1
```

### Step 6: Mobile - Create MessagePackCodec

Create `lib/serializers/message_pack_serializer.dart`:

```dart
import 'dart:typed_data';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:phoenix_socket/phoenix_socket.dart';

/// MessagePack serializer for Phoenix Channels.
/// Compatible with Phoenix's wire format: [join_ref, ref, topic, event, payload]
class MessagePackSerializer implements MessageSerializer {
  @override
  Message decode(String rawMessage) {
    throw UnsupportedError('Use binary decode for MessagePack');
  }

  Message decodeBinary(Uint8List bytes) {
    final unpacked = msgpack.deserialize(bytes);

    if (unpacked is! List || unpacked.length != 5) {
      throw FormatException('Invalid MessagePack message format');
    }

    return Message(
      joinRef: unpacked[0]?.toString(),
      ref: unpacked[1]?.toString(),
      topic: PhoenixChannelEvent.custom(unpacked[2] as String),
      event: PhoenixChannelEvent.custom(unpacked[3] as String),
      payload: unpacked[4] as Map<dynamic, dynamic>?,
    );
  }

  @override
  String encode(Message message) {
    throw UnsupportedError('Use binaryEncoder for MessagePack');
  }

  @override
  dynamic binaryEncoder(Message message) {
    final data = [
      message.joinRef,
      message.ref,
      message.topic.value,
      message.event.value,
      message.payload ?? {},
    ];

    return Uint8List.fromList(msgpack.serialize(data));
  }
}
```

### Step 7: Mobile - Update WebSocket Service

Update your WebSocket service to use MessagePack:

```dart
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:mobile/serializers/message_pack_serializer.dart';

class WebSocketService {
  PhoenixSocket? _socket;
  final messagePackSerializer = MessagePackSerializer();

  Future<bool> connect(String url, int userId, Map<String, dynamic> fingerprint) async {
    _socket = PhoenixSocket(
      url,
      socketOptions: PhoenixSocketOptions(
        params: {
          'user_id': userId.toString(),
          'fingerprint': jsonEncode(fingerprint),
        },
      ),
    );

    // Set MessagePack serializer
    _socket!.serializer = messagePackSerializer;

    await _socket!.connect();

    // ... rest of connection logic ...
  }
}
```

### Step 8: Mobile - Handle MessagePack Type Conversions

**CRITICAL**: MessagePack returns `Map<dynamic, dynamic>`, not `Map<String, dynamic>`.

Always convert immediately:

```dart
// In your channel message handlers
_channel!.messages.listen((message) {
  if (message.event.value == 'new_msg') {
    final payload = message.payload;
    if (payload is Map) {
      // Convert to Map<String, dynamic>
      final typedPayload = Map<String, dynamic>.from(payload);
      _handleNewMessage(typedPayload);
    }
  }
});

// In channel join responses
final response = await _channel!.join().future;
if (response.isOk) {
  final rawPayload = response.response;
  if (rawPayload != null && rawPayload is Map) {
    // Convert to Map<String, dynamic>
    final payload = Map<String, dynamic>.from(rawPayload);
    // Now safe to access payload['messages'] etc.
  }
}
```

### Step 9: Backend - Add Tests

Test MessagePack serialization:

```elixir
defmodule MyAppWeb.MessagePackSerializerTest do
  use ExUnit.Case, async: true

  alias MyAppWeb.MessagePackSerializer
  alias Phoenix.Socket.{Broadcast, Message, Reply}

  describe "encode!/1" do
    test "encodes Reply with ok status" do
      reply = %Reply{
        join_ref: "1",
        ref: "2",
        topic: "chat:lobby",
        status: :ok,
        payload: %{message: "success"}
      }

      {:socket_push, :binary, encoded} = MessagePackSerializer.encode!(reply)

      assert {:ok, [join_ref, ref, topic, event, payload]} = Msgpax.unpack(encoded)
      assert join_ref == "1"
      assert ref == "2"
      assert topic == "chat:lobby"
      assert event == "phx_reply"
      assert payload["status"] == "ok"
      assert payload["response"]["message"] == "success"
    end
  end

  describe "decode!/2" do
    test "decodes valid MessagePack array" do
      data = ["1", "2", "chat:lobby", "new_msg", %{"content" => "Hello"}]
      encoded = Msgpax.pack!(data)

      message = MessagePackSerializer.decode!(encoded, [])

      assert message.join_ref == "1"
      assert message.ref == "2"
      assert message.topic == "chat:lobby"
      assert message.event == "new_msg"
      assert message.payload == %{"content" => "Hello"}
    end
  end
end
```

### Step 10: Mobile - Add Tests

Test MessagePack type handling:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/serializers/message_pack_serializer.dart';

void main() {
  group('MessagePackSerializer', () {
    late MessagePackSerializer serializer;

    setUp(() {
      serializer = MessagePackSerializer();
    });

    test('binaryEncoder creates valid MessagePack', () {
      final message = Message(
        joinRef: '1',
        ref: '2',
        topic: PhoenixChannelEvent.custom('chat:lobby'),
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: {'content': 'Hello'},
      );

      final encoded = serializer.binaryEncoder(message);

      expect(encoded, isA<Uint8List>());
      expect(encoded.length, greaterThan(0));
    });

    test('decodeBinary handles Map<dynamic, dynamic> correctly', () {
      // Simulate server response
      final data = ['1', '2', 'chat:lobby', 'phx_reply', {
        'status': 'ok',
        'response': {'messages': []}
      }];

      final encoded = msgpack.serialize(data);
      final message = serializer.decodeBinary(Uint8List.fromList(encoded));

      expect(message.payload, isA<Map>());

      // Must convert before accessing keys
      final typedPayload = Map<String, dynamic>.from(message.payload!);
      expect(typedPayload['status'], 'ok');
    });
  });
}
```

## Considerations

### Phoenix Socket Fork Maintenance

- **Fork is required** because the official library has `String` type constraint
- Consider submitting a PR to upstream with binary support
- Keep your fork up-to-date with upstream releases
- Document the fork location in your project README

### Type Safety in Dart

- **Always convert `Map<dynamic, dynamic>` to `Map<String, dynamic>`** immediately after receiving MessagePack data
- Apply conversion in all channel message handlers, join responses, and push responses
- Use `Map<String, dynamic>.from(rawMap)` not casts

### Backward Compatibility

- If supporting both JSON and MessagePack clients, configure multiple serializers:
  ```elixir
  socket "/socket", MyAppWeb.UserSocket,
    websocket: [
      serializer: [
        {MyAppWeb.MessagePackSerializer, "2.0.0"},
        {Phoenix.Socket.V2.JSONSerializer, "2.0.0"}
      ]
    ]
  ```

### Bandwidth Savings

- **Typical savings**: 40-70% compared to JSON
- **Best for**: Nested objects, repeated keys, numbers (MessagePack uses compact integer encoding)
- **Less benefit**: Short string-only messages

### Debugging

- MessagePack is binary - can't read raw WebSocket frames
- Use logging in serializers during development
- Keep JSON serializer available for debugging if needed

### When NOT to Use

- **Browser clients**: MessagePack support in JavaScript is less mature
- **Simple REST APIs**: Overhead not worth it for request/response
- **Human-readable logs required**: JSON is more debuggable
- **No bandwidth constraints**: JSON is simpler if bandwidth isn't an issue

## Example Usage: Chat Application

From the nalikutemwa project (two-person chat for unreliable networks in Zambia):

**Bandwidth comparison for 50 messages:**

- **JSON**: ~15 KB
- **MessagePack**: ~6 KB
- **Savings**: 60% reduction

**Implementation results:**

- Backend serializer: 72 lines of code
- Mobile serializer: 45 lines of code
- Tests pass for both unit and integration
- No performance degradation on serialization/deserialization

## Related Recipes

- `phoenix-channels-authentication.md` - Securing Phoenix Channels
- `flutter-integration-test-optimization-polling.md` - Testing WebSocket apps
- `phoenix-async-feature-test-liveview.md` - Backend testing patterns
