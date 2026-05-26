# phoenix_live_view - File Uploads

## Enabling Uploads

Initialize file uploads in the mount callback with `allow_upload/3`:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:uploaded_files, [])
   |> allow_upload(:avatar, accept: ~w(.jpg .jpeg .png), max_entries: 1, max_file_size: 5_000_000)}
end
```

**Options:**

- `accept` - list of accepted file extensions or MIME types
- `max_entries` - max number of files the user can select
- `max_file_size` - max size per file in bytes
- `progress` - custom channel for progress tracking
- `auto_upload` - upload on selection (default: false, user clicks submit)

## File Input Component

Render file inputs using `live_file_input`:

```heex
<form id="upload-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />
  <button type="submit">Upload</button>
</form>
```

This renders an `<input type="file">` bound to the upload configuration. The input automatically handles drag-and-drop.

## Enabling Drag & Drop

Add `phx-drop-target` to any container:

```heex
<div id="drop-zone" phx-drop-target={@uploads.avatar}>
  Drag files here or <a href="#">select files</a>
</div>
```

Users can drag files onto the div. The framework automatically adds them to the upload.

## Entry Management

Access entries (selected but not yet uploaded files) via `@uploads.avatar.entries`:

```heex
<div :for={entry <- @uploads.avatar.entries}>
  <div>
    <.live_img_preview entry={entry} />
    <p><%= entry.client_name %></p>
  </div>

  <progress value={entry.progress} max="100"><%= entry.progress %>%</progress>

  <button phx-click="cancel-upload" phx-value-ref={entry.ref}>Cancel</button>
</div>
```

Entry struct fields:

- `client_name` - original filename
- `progress` - upload progress percentage (0-100)
- `ref` - unique identifier for cancellation
- `errors` - validation error messages

## Validation

Validation runs as files are selected. Create a minimal handler:

```elixir
def handle_event("validate", _params, socket) do
  {:noreply, socket}
end
```

The framework validates file size and type automatically. Check errors in templates:

```heex
<ul>
  <li :for={error <- upload_errors(@uploads.avatar)}>
    <%= error %>
  </li>
</ul>

<ul>
  <li :for={entry <- @uploads.avatar.entries}>
    <li :for={error <- upload_errors(@uploads.avatar, entry)}>
      <%= error %>
    </li>
  </li>
</ul>
```

Errors include: file too large, file type not accepted, max entries exceeded.

## Processing Uploads

When the form submits, process completed uploads with `consume_uploaded_entries/3`:

```elixir
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
      dest = Path.join(Application.app_dir(:my_app, "priv/static/uploads"),
                       Path.basename(path))
      File.cp!(path, dest)
      {:ok, ~p"/uploads/#{Path.basename(dest)}"}
    end)

  {:noreply, update(socket, :uploaded_files, &(&1 ++ uploaded_files))}
end
```

The callback receives a map with `:path` (temp file location) and the entry struct. Return `{:ok, value}` to include in the result, or `{:error, reason}` to skip.

Temporary files are cleaned up automatically after the callback.

## Cancellation

Cancel individual entries before upload:

```elixir
def handle_event("cancel-upload", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :avatar, ref)}
end
```

This removes the entry from `@uploads.avatar.entries`.

## Direct-to-Cloud Uploads

For cloud storage (S3, GCS), use signed URLs instead of uploading through the server:

```elixir
def mount(_params, _session, socket) do
  {:ok, allow_upload(socket, :avatar,
    external: &get_signed_url/2,
    progress: MyApp.progress_handler())}
end

defp get_signed_url(entry, socket) do
  {:ok, url, fields} = S3.presigned_post(entry.client_name, entry.client_type)
  {:ok, url, fields}
end
```

The client posts directly to the cloud storage endpoint, bypassing the server. The `progress` callback tracks upload status.

## Live Reload During Development

Changes to uploaded files trigger live reload in development. Disable temporarily in `config/dev.exs`:

```elixir
config :your_app, YourAppWeb.Endpoint,
  code_reloader: false
```

## Production Considerations

**Multi-instance deployments:** Uploaded files exist only on the instance that received the upload. Other servers cannot access them.

**Solution:** Store uploads in a database (BLOB), cloud storage (S3/GCS), or shared network drive.

**Memory usage:** Large files consume server memory during upload. Use direct-to-cloud uploads for large files.

## Auto Upload

Enable automatic upload on file selection:

```elixir
allow_upload(:avatar, accept: ~w(.jpg), auto_upload: true)

def handle_event("save", _params, socket) do
  uploaded_files = consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
    {:ok, store_file(path)}
  end)
  {:noreply, assign(socket, :files, uploaded_files)}
end
```

Without auto_upload (default), files upload only when the form submits or you explicitly call `upload_entries/1`.

---

[← Back to main](phoenix_live_view-1.1.25.md)
**Version:** 1.1.25
