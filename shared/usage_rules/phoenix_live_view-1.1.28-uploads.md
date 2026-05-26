# phoenix_live_view - File Uploads and Streaming

## File Upload Fundamentals

Phoenix LiveView enables interactive file uploads with built-in features: accept specifications, reactive entry management, drag-and-drop support, and progress tracking.

### Enable Uploads During Mount

Use `allow_upload/3` to configure upload handlers:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:uploaded_files, [])
   |> allow_upload(:avatar,
       accept: ~w(.jpg .jpeg .png),
       max_entries: 2,
       max_file_size: 10_000_000
     )
  }
end
```

**Configuration options:**

- **`:accept`** (required) — List of allowed file extensions (e.g., `~w(.jpg .png)`)
- **`:max_entries`** — Maximum files allowed; 1 by default
- **`:max_file_size`** — Size limit in bytes
- **`:auto_upload`** — When true, upload begins immediately without button press

### Render Upload Input

Use the `live_file_input/1` component within a form; **you must bind `phx-change` and `phx-submit` on the form**:

```heex
<form id="upload-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />
  <button type="submit">Upload</button>
</form>
```

Enable drag-and-drop by adding `phx-drop-target` to a container:

```heex
<div phx-drop-target={@uploads.avatar}>
  <.live_file_input upload={@uploads.avatar} />
</div>
```

### Display Upload Progress and Errors

Iterate through entries in `@uploads.avatar.entries` to show status:

```heex
<ul>
  <%= for entry <- @uploads.avatar.entries do %>
    <li>
      <%= entry.client_name %>
      <progress max="100" value={entry.progress}></progress>

      <%= for error <- upload_errors(@uploads.avatar, entry) do %>
        <p class="error"><%= upload_error_to_string(error) %></p>
      <% end %>
    </li>
  <% end %>
</ul>
```

**Entry attributes:**

- `entry.client_name` — Original file name
- `entry.progress` — Upload percentage (0–100)
- `entry.ref` — Internal reference for file identification
- `entry.valid?` — true if file meets accept/size constraints

## Process Uploaded Files

### Validation Handler

Implement a minimal validation callback (server-side validation occurs automatically):

```elixir
def handle_event("validate", _params, socket) do
  {:noreply, socket}
end
```

LiveView automatically validates file types and sizes against `allow_upload/3` configuration.

### Consume Uploaded Entries

Within the `phx-submit` callback, call `consume_uploaded_entries/3` to process files:

```elixir
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
      dest_dir = Application.app_dir(:my_app, "priv/static/uploads")
      File.mkdir_p!(dest_dir)

      dest = Path.join(dest_dir, "#{UUID.uuid4()}_#{entry.client_name}")
      File.cp!(path, dest)

      {:ok, "/uploads/#{Path.basename(dest)}"}
    end)

  {:noreply, update(socket, :uploaded_files, &(&1 ++ uploaded_files))}
end
```

**Key points:**

- `path` is a temporary file that exists only within this callback
- Files are auto-cleaned up after callback completes
- Return `{:ok, value}` or `{:error, reason}` per file
- `consume_uploaded_entry/3` processes a single file for more control

### Single Entry Consumption

For granular control over individual uploads:

```elixir
def handle_event("save", _params, socket) do
  [entry | _] = socket.assigns.uploads.avatar.entries

  case consume_uploaded_entry(socket, entry, fn %{path: path} ->
    {:ok, File.read!(path)}
  end) do
    {:ok, contents} ->
      {:noreply, assign(socket, :file_contents, contents)}
    {:error, error} ->
      {:noreply, put_flash(socket, :error, "Upload failed")}
  end
end
```

## Collection Streaming

Streams manage large client-side collections without server-side resource overhead, useful for infinite scrolling or pagination.

### Stream Configuration

Create a stream in mount with DOM ID generation:

```elixir
def mount(_params, _session, socket) do
  {:ok, stream(socket, :items, [])}
end
```

In the template, enable streaming with `phx-update="stream"`:

```heex
<ul id="items" phx-update="stream">
  <li :for={{item_id, item} <- @streams.items} id={item_id}>
    <%= item.name %>
  </li>
</ul>
```

### Stream Operations

**Append or prepend items:**

```elixir
def handle_info({:new_item, item}, socket) do
  {:noreply, stream_insert(socket, :items, item)}
end

def handle_info({:new_item, item}, socket) do
  {:noreply, stream_insert(socket, :items, item, at: 0)}
end
```

**Delete items:**

```elixir
def handle_event("delete", %{"id" => id}, socket) do
  {:noreply, stream_delete(socket, :items, id)}
end
```

**Limit stream size:**

```elixir
stream_insert(socket, :items, item, at: -1, limit: 10)
```

Negative limits prune from the beginning; positive from the end. This prevents UI overwhelming when processing continuous updates.

## Important Considerations

### Storage Limitations

**Single-instance only**: Writing directly to disk with `File.cp!/2` works for development and single-instance deployments. Multi-instance applications must use:

- External storage services (AWS S3, Google Cloud Storage)
- Database storage
- CDN services

### Development Behavior

The `live_reload` feature reloads your application when files are added to `priv/static/uploads`. Disable if this causes issues:

```elixir
# config/dev.exs
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    patterns: [...]  # exclude upload directories
  ]
```

---

[← Back to main](phoenix_live_view-1.1.28.md)
**Version:** 1.1.28
