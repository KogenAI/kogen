# Phoenix File Upload HTML Labels and Character Counters

**Problem**: File upload triggers and character counters fire unnecessary server events instead of using native browser behavior.
**When**: Adding a styled file upload button or a character counter input to a Phoenix LiveView form.
**See also**: none

## Solution

**File uploads** — use an HTML `<label for="...">` pointing to the hidden `<.live_file_input>`. The label click opens the OS file picker natively; no `phx-click` or JS hook needed.

```heex
<.live_file_input upload={@uploads.avatar} class="hidden" id="avatar-input" />
<label for="avatar-input" class="cursor-pointer btn">Upload photo</label>
```

**Character counters** — track count server-side via `phx-keyup` with debounce. Store the length in socket assigns; render it inline.

```heex
<textarea
  phx-keyup="validate"
  phx-debounce="300"
  name="body"
  maxlength="280"
><%= @form[:body].value %></textarea>
<span><%= @char_count %>/280</span>
```

```elixir
def handle_event("validate", %{"body" => body}, socket) do
  {:noreply, assign(socket, char_count: String.length(body))}
end
```

## Gotchas

- `phx-debounce` goes on the **field**, not the `<.form>` wrapper (per Phoenix docs).
- `live_file_input` renders its own `id`; pass `id` explicitly if you need to target it with a label.
