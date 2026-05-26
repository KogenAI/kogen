# phoenix_live_view - File Uploads and Streams

## File Upload Setup

Enable uploads during component mount using `allow_upload/3`:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:uploaded_files, [])
   |> allow_upload(:avatar,
       accept: ~w(.jpg .jpeg .png),
       max_entries: 1,
       max_file_size: 9_000_000)}
end
```

Configuration options:

- `accept` - File extensions or MIME types allowed
- `max_entries` - Maximum number of files in single upload
- `max_file_size` - Maximum file size in bytes
- `auto_upload` - Auto-upload without form submission (default false)
- `progress` - Handle upload progress events
- `chunk_size` - Size of chunks for large files

## Template and Form Integration

Use `live_file_input` component with form bindings for validation:

```heex
<form id="upload-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />

  <div :for={entry <- @uploads.avatar.entries}>
    <progress value={entry.progress} max="100" />
  </div>

  <button type="submit" disabled={not Enum.empty?(@uploads.avatar.entries)}>
    Upload
  </button>
</form>
```

**Critical requirement:** Always bind `phx-submit` and `phx-change` on forms containing file uploads. LiveView uses these to validate entries and manage upload state.

The `live_file_input` component automatically:

- Detects file selection from input element
- Supports drag-and-drop with `phx-drop-target` attribute
- Manages upload progress
- Handles errors and validation

## Validation Handler

Implement `handle_event` for "validate" event even if no custom logic needed:

```elixir
def handle_event("validate", _params, socket) do
  {:noreply, socket}
end
```

The framework automatically validates against your `allow_upload` specifications. Entry errors (size violations, type mismatches) populate in `@uploads.avatar.entries[index].errors` automatically.

## Upload Progress Tracking

Access upload progress through entries:

```heex
<div :for={entry <- @uploads.avatar.entries}>
  <span><%= entry.client_name %></span>
  <progress value={entry.progress} max="100" />
  <span :if={Enum.any?(entry.errors)}>
    <%= Enum.join(entry.errors, ", ") %>
  </span>
</div>
```

Common entry fields:

- `client_name` - Original filename from client
- `progress` - Upload progress 0-100
- `errors` - List of validation errors
- `valid?` - Whether entry passes all validations

## Processing Uploads

After form submission, consume uploaded entries using `consume_uploaded_entries/3`:

```elixir
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
      dest = Path.join(
        Application.app_dir(:my_app, "priv/static/uploads"),
        Path.basename(path)
      )
      File.cp!(path, dest)
      {:ok, ~p"/uploads/#{Path.basename(dest)}"}
    end)

  {:noreply,
   socket
   |> update(:uploaded_files, &(&1 ++ uploaded_files))
   |> put_flash(:info, "Files uploaded successfully")}
end
```

The callback function receives:

- `path` - Temporary file path on server
- `entry` - Upload entry with metadata

Return `{:ok, value}` to associate with file, or `{:error, reason}` to reject.

## Drag-and-Drop

Enable drag-and-drop on elements using `phx-drop-target`:

```heex
<div phx-drop-target={@uploads.avatar.ref} class="upload-zone">
  Drag files here or click to select
</div>

<.live_file_input upload={@uploads.avatar} class="hidden" />
```

The upload reference (`.ref`) connects the drop target to the file input. Dropped files automatically register in the upload's entry list.

## Large File and Streaming Considerations

**For large files:**

- Set `chunk_size` appropriately for network conditions
- Implement progress tracking UI for user feedback
- Use external storage (S3, Cloudinary) instead of local filesystem

**Stream Processing:**

```elixir
def handle_event("save", _params, socket) do
  consume_uploaded_entries(socket, :csv, fn %{path: path}, _entry ->
    # Process file in chunks instead of loading entirely
    stream_file(path)
    {:ok, "processed"}
  end)

  {:noreply, put_flash(socket, :info, "File processed")}
end
```

## Production Considerations

- Never store uploads to local filesystem in production—use S3, CloudFront, or CDN
- Register upload directories in `static_paths/0` in endpoint config if serving locally
- Validate file content server-side, not just extensions
- Implement virus scanning for user-uploaded files
- Set reasonable max file sizes to prevent resource exhaustion
- Implement rate limiting to prevent upload spam

## Streams for Large Collections

**stream/4** enables efficient handling of large lists with minimal DOM operations:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> stream(:posts, fetch_initial_posts())}
end
```

Insert and delete individual items without re-rendering entire list:

```elixir
def handle_event("delete", %{"id" => id}, socket) do
  stream_delete(socket, :posts, id)
  {:noreply, socket}
end

def handle_event("add", %{"title" => title}, socket) do
  post = create_post(title)
  stream_insert(socket, :posts, post)
  {:noreply, socket}
end
```

Template rendering:

```heex
<ul phx-update="stream" id="posts">
  <li :for={{_id, post} <- @streams.posts} id={"post-#{post.id}"}>
    <%= post.title %>
  </li>
</ul>
```

Streams maintain database query efficiency for pagination and infinite scroll patterns.

---

[← Back to main](phoenix_live_view-1.1.16.md)
**Version:** 1.1.16
