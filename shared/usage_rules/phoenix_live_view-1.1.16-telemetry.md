# phoenix_live_view - Telemetry and Performance Monitoring

## Telemetry Events Overview

Phoenix LiveView exposes telemetry events across the entire lifecycle, enabling performance monitoring, debugging, and observability. Each event follows the three-phase pattern: `:start`, `:stop`, and `:exception`.

**Event Structure:**

```elixir
:telemetry.attach(
  "my_handler",
  [:phoenix, :live_view, :mount, :stop],
  &MyApp.Telemetry.handle_event/4,
  nil
)

def handle_event(event, measurements, metadata, config) do
  # event: [:phoenix, :live_view, :mount, :stop]
  # measurements: %{duration: 150000, system_time: 1699564800000}
  # metadata: %{socket: socket, params: params, session: session}
end
```

## LiveView Lifecycle Events

### Mount Events

Fired during `mount/3` callback execution:

- **`[:phoenix, :live_view, :mount, :start]`** - Mount started
- **`[:phoenix, :live_view, :mount, :stop]`** - Mount completed
- **`[:phoenix, :live_view, :mount, :exception]`** - Mount failed

```elixir
def handle_event(
  [:phoenix, :live_view, :mount, :stop],
  %{duration: duration},
  %{socket: socket},
  _
) do
  if duration > 500_000 do  # 500ms threshold
    Logger.warning("Slow mount in #{socket.view}: #{div(duration, 1000)}ms")
  end
end
```

Measurements include `system_time` (timestamp in microseconds) and `duration` (elapsed time in microseconds). Metadata includes socket, params, and session information.

### Params Handling Events

Fired during `handle_params/3` callback:

- **`[:phoenix, :live_view, :handle_params, :start]`**
- **`[:phoenix, :live_view, :handle_params, :stop]`**
- **`[:phoenix, :live_view, :handle_params, :exception]`**

Use to monitor URL parameter processing and filtering performance. Important for identifying slow query parameter handling or expensive data loading on patches.

### Event Handling Events

Fired during `handle_event/3` callback:

- **`[:phoenix, :live_view, :handle_event, :start]`**
- **`[:phoenix, :live_view, :handle_event, :stop]`**
- **`[:phoenix, :live_view, :handle_event, :exception]`**

Metadata includes event name, parameters, and socket. Use to track event processing performance and identify expensive event handlers causing UI lag.

### Rendering Events

Fired during template rendering:

- **`[:phoenix, :live_view, :render, :start]`**
- **`[:phoenix, :live_view, :render, :stop]`**
- **`[:phoenix, :live_view, :render, :exception]`**

Critical for identifying rendering bottlenecks. Long render times directly impact diff calculation and client-side rendering performance.

## LiveComponent Events

Components emit similar events during their lifecycle:

### Component Update Events

- **`[:phoenix, :live_component, :update, :start]`**
- **`[:phoenix, :live_component, :update, :stop]`**
- **`[:phoenix, :live_component, :update, :exception]`**

Metadata includes component module and assigns. Use to monitor component re-render frequency and update performance.

### Component Event Handling

- **`[:phoenix, :live_component, :handle_event, :start]`**
- **`[:phoenix, :live_component, :handle_event, :stop]`**
- **`[:phoenix, :live_component, :handle_event, :exception]`**

### Component Destruction

- **`[:phoenix, :live_component, :destroyed]`**

Fired when component removed from DOM. Single-phase event (no start/stop). Use for cleanup notifications.

## Performance Monitoring Implementation

**Basic Logger Handler:**

```elixir
def attach_logger do
  :telemetry.attach_many(
    "app_logger",
    [
      [:phoenix, :live_view, :mount, :exception],
      [:phoenix, :live_view, :handle_event, :exception],
      [:phoenix, :live_view, :render, :exception]
    ],
    &__MODULE__.log_exception/4,
    nil
  )
end

def log_exception(event, measurements, metadata, _config) do
  %{kind: kind, reason: reason, stacktrace: stacktrace} = metadata
  Logger.error("LiveView error in #{event}: #{inspect(reason)}",
    error: {kind, reason, stacktrace})
end
```

**Performance Threshold Alerts:**

```elixir
def attach_slow_request_monitor do
  :telemetry.attach_many(
    "slow_requests",
    [
      [:phoenix, :live_view, :mount, :stop],
      [:phoenix, :live_view, :handle_event, :stop],
      [:phoenix, :live_view, :render, :stop]
    ],
    &__MODULE__.check_duration/4,
    %{threshold: 500_000}  # 500ms
  )
end

def check_duration(_event, %{duration: duration}, _metadata, %{threshold: threshold}) do
  if duration > threshold do
    Logger.warning("Slow operation: #{div(duration, 1000)}ms")
  end
end
```

## Metrics Collection

**Using Telemetry Metrics:**

```elixir
defmodule MyApp.Telemetry do
  def metrics do
    [
      Telemetry.Metrics.counter("phoenix.live_view.mount.start"),
      Telemetry.Metrics.histogram("phoenix.live_view.mount.stop",
        unit: {:microsecond, :millisecond}),
      Telemetry.Metrics.histogram("phoenix.live_view.render.stop",
        unit: {:microsecond, :millisecond}),
      Telemetry.Metrics.counter("phoenix.live_view.mount.exception")
    ]
  end
end
```

Integration with Prometheus, Datadog, or other metrics systems requires implementing handlers that translate telemetry events to system-specific metrics.

## Error Tracking Context

Exception events provide kind, reason, and stacktrace in metadata:

```elixir
def handle_exception(event, _measurements, %{kind: kind, reason: reason, stacktrace: stacktrace}, _) do
  Sentry.capture_exception(reason,
    stacktrace: stacktrace,
    extra: %{event: event}
  )
end
```

Integrate with error tracking services (Sentry, Rollbar) to automatically capture and report exceptions.

## Best Practices

- **Start early:** Attach handlers during application startup in supervision tree
- **Use filtering:** Attach handlers to specific event paths rather than all events
- **Avoid blocking:** Keep handler code quick to prevent event processing from impacting performance
- **Correlate data:** Use socket/component IDs to correlate events across requests
- **Log strategically:** Log exceptions and slow operations, not every event
- **Monitor memory:** Track attach/detach to prevent memory leaks from accumulating handlers

---

[← Back to main](phoenix_live_view-1.1.16.md)
**Version:** 1.1.16
