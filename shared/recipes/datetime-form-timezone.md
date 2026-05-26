# Recipe: Timezone-Aware Datetime Form Handling in Phoenix

## Problem

Handling datetime input in web forms presents multiple challenges:

- HTML datetime-local inputs are not well supported across browsers
- Users expect to input dates/times in their local timezone but server needs UTC
- Form validation needs to handle invalid date/time combinations
- Editing existing datetimes requires splitting back into separate date/time fields
- Frontend needs to capture the user's timezone automatically

## Solution

Split datetime into separate date and time inputs, capture timezone on client-side, merge and validate server-side, handle edge cases gracefully.

## Implementation

### 1. Schema Design

Store UTC datetime and timezone separately:

```elixir
schema "interviews" do
  field :scheduled_at, :utc_datetime
  field :end_time, :utc_datetime
  field :timezone, :string

  timestamps(type: :utc_datetime)
end
```

### 2. Form Component with Virtual Fields

```elixir
def render(assigns) do
  ~H"""
  <.simple_form
    for={@form}
    phx-hook="TimezoneDetector"
    phx-target={@myself}
    phx-change="validate"
    phx-submit="save"
  >
    <div class="grid grid-cols-2 gap-4">
      <.input
        field={@form[:scheduled_at_date]}
        type="date"
        label={dgettext("jobs", "Date")}
        required
      />
      <.input
        field={@form[:scheduled_at_time]}
        type="time"
        label={dgettext("jobs", "Start Time")}
        required
      />
    </div>

    <div class="grid grid-cols-2 gap-4">
      <.input
        field={@form[:end_date]}
        type="date"
        label={dgettext("jobs", "End Date")}
        required
      />
      <.input
        field={@form[:end_time_field]}
        type="time"
        label={dgettext("jobs", "End Time")}
        required
      />
    </div>

    <!-- Hidden timezone field -->
    <input
      type="hidden"
      name={@form[:timezone].name}
      id="entity_timezone"
      value={@form[:timezone].value || ""}
    />
  </.simple_form>
  """
end
```

### 3. Client-Side Timezone Detection

```javascript
// TimezoneDetector hook
export default {
  mounted() {
    // Auto-detect user's timezone
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const timezoneInput = document.getElementById("entity_timezone");

    if (timezoneInput && !timezoneInput.value) {
      timezoneInput.value = timezone;
      // Trigger validation to capture timezone
      this.el.dispatchEvent(new Event("change", { bubbles: true }));
    }
  },
};
```

### 4. Server-Side Datetime Merging

```elixir
def handle_event("validate", %{"entity" => entity_params}, socket) do
  params = merge_datetime_params(entity_params)

  changeset =
    socket.assigns.entity
    |> Entity.changeset(params)
    |> Map.put(:action, :validate)

  {:noreply, assign_form(socket, changeset)}
end

defp merge_datetime_params(params) do
  scheduled_at = build_datetime(
    params["scheduled_at_date"],
    params["scheduled_at_time"]
  )

  end_time = build_datetime(
    params["end_date"] || params["scheduled_at_date"],
    params["end_time_field"]
  )

  params
  |> Map.drop(["scheduled_at_date", "scheduled_at_time", "end_date", "end_time_field"])
  |> Map.put("scheduled_at", scheduled_at)
  |> Map.put("end_time", end_time)
end

defp build_datetime(nil, _time), do: nil
defp build_datetime(_date, nil), do: nil
defp build_datetime("", _time), do: nil
defp build_datetime(_date, ""), do: nil

defp build_datetime(date, time) do
  with {:ok, date} <- Date.from_iso8601(date),
       {:ok, time} <- Time.from_iso8601(time <> ":00") do
    DateTime.new!(date, time, "Etc/UTC")
  else
    _error -> nil
  end
end
```

### 5. Editing Existing Datetimes

```elixir
def update(%{entity: entity} = assigns, socket) do
  # Split existing datetimes into form fields for editing
  edit_attrs = extract_datetime_fields(entity)
  changeset = Entity.changeset(entity, edit_attrs)

  {:ok, assign_form(socket, changeset)}
end

defp extract_datetime_fields(%Entity{} = entity) do
  %{}
  |> maybe_add_scheduled_at_fields(entity.scheduled_at)
  |> maybe_add_end_time_fields(entity.end_time)
end

defp maybe_add_scheduled_at_fields(attrs, nil), do: attrs

defp maybe_add_scheduled_at_fields(attrs, scheduled_at) do
  {date, time} = {DateTime.to_date(scheduled_at), DateTime.to_time(scheduled_at)}

  time_string = time
    |> Time.to_iso8601()
    |> String.slice(0, 5)

  attrs
  |> Map.put("scheduled_at_date", Date.to_iso8601(date))
  |> Map.put("scheduled_at_time", time_string)
end
```

### 6. Validation with Future Date Check

```elixir
def changeset(entity, attrs) do
  entity
  |> cast(attrs, [:scheduled_at, :end_time, :timezone])
  |> validate_required([:scheduled_at, :end_time, :timezone])
  |> validate_time_range()
  |> validate_future_date()
end

defp validate_time_range(changeset) do
  validate_change(changeset, :end_time, fn :end_time, end_time ->
    case get_change(changeset, :scheduled_at) do
      nil -> []
      scheduled_at ->
        if DateTime.compare(end_time, scheduled_at) == :gt do
          []
        else
          [end_time: "must be after the scheduled start time"]
        end
    end
  end)
end

defp validate_future_date(changeset) do
  validate_change(changeset, :scheduled_at, fn :scheduled_at, scheduled_at ->
    if DateTime.compare(scheduled_at, DateTime.utc_now()) == :gt do
      []
    else
      [scheduled_at: "must be in the future"]
    end
  end)
end
```

## Considerations

### When to Use

- Any form that needs precise datetime input
- Applications with international users across timezones
- When you need better browser compatibility than datetime-local
- Forms where users expect to input local time

### When NOT to Use

- Simple date-only inputs (use date type)
- Internal tools where timezone doesn't matter
- When datetime-local input is sufficient for your use case

### Performance Considerations

- Client-side timezone detection adds minimal overhead
- Server-side datetime parsing is lightweight
- Consider caching user timezone in session for repeated forms

### Pitfalls to Avoid

- **Don't validate datetime in client timezone** - Always convert to UTC first
- **Handle nil values gracefully** - Users may submit partial forms
- **Don't assume timezone detection works** - Provide fallback
- **Test edge cases** - Invalid dates, midnight transitions, DST changes
- **Don't forget form submission** - Merge datetimes on both validate and submit

## Example Usage

From interview scheduling feature where employers need to schedule meetings with job seekers across different timezones.

```elixir
# The form handles timezone-aware scheduling
<.live_component
  module={InterviewFormComponent}
  id="schedule-interview"
  job_application={@job_application}
  current_user={@current_user}
  edit_interview={@edit_interview}
/>
```

## Related Recipes

- phoenix-dual-mode-component.md - For components that work in both create/edit modes
- phoenix-param-normalization.md - For safe parameter handling patterns
