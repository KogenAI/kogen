# phoenix_live_view - Uploads & File Handling

## File Upload Overview

Phoenix LiveView provides built-in file upload functionality with progress tracking, client-side validation, and both direct-to-server and external cloud uploads. Uploads are reactive—entries populate in an `@uploads` assign as files are selected.

## Basic Upload Implementation

### 1. Enable Uploads on Mount

Use `allow_upload/3` to configure upload specifications:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> assign(:uploaded_files, [])
   |> allow_upload(:avatar,
     accept: ~w(.jpg .jpeg .png),
     max_entries: 2,
     max_file_size: 10_000_000)}  # 10MB
end
```

Options:

- `accept`: List of file extensions or MIME types
- `max_entries`: Maximum number of files (default: 1)
- `max_file_size`: Maximum bytes per file
- `auto_upload`: Auto-upload without waiting for form submit (default: false)
- `progress_event`: Send progress events to the LiveView

### 2. Render File Input

Use the `live_file_input/1` component within a form:

```heex
<.form id="upload-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />
  <button type="submit" phx-disable-with="Uploading...">Upload</button>
</.form>
```

The `.live_file_input` component renders a standard file input with special handling for uploads. The form must have both `phx-change` and `phx-submit` bindings.

Drag-and-drop support:

```heex
<div phx-drop-target={@uploads.avatar.ref}>
  Drag and drop files here
</div>
```

### 3. Handle Validation

Implement a validation event handler. Validation occurs automatically based on `allow_upload/3` constraints:

```elixir
def handle_event("validate", _params, socket) do
  # Validation happens automatically
  # Optional: check custom conditions
  {:noreply, socket}
end
```

Access upload entries to show progress:

```heex
<.form id="upload-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />

  <!-- Show upload progress -->
  <%= for entry <- @uploads.avatar.entries do %>
    <div>
      <p>{entry.client_name}</p>
      <progress value={entry.progress} max="100"><%= entry.progress %>%</progress>
    </div>
  <% end %>

  <!-- Show errors -->
  <%= for err <- upload_errors(@uploads.avatar) do %>
    <p class="error">{error_to_string(err)}</p>
  <% end %>

  <button type="submit">Save</button>
</.form>
```

### 4. Process Uploads

When the form submits, call `consume_uploaded_entries/3` to persist files:

```elixir
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
      dest = Path.join(priv_dir(), Path.basename(path))
      File.cp!(path, dest)
      {:ok, ~p"/uploads/#{Path.basename(dest)}"}
    end)

  {:noreply, update(socket, :uploaded_files, &(&1 ++ uploaded_files))}
end

defp priv_dir() do
  Application.app_dir(:my_app, "priv/static/uploads")
end
```

The function receives:

- `%{path: path}` — Temporary file path
- `entry` — Upload entry metadata

Return `{:ok, value}` to store in assigns, `{:error, reason}` to reject.

## Advanced Features

### Progress Events

For custom progress tracking, configure progress events:

```elixir
allow_upload(:video,
  accept: ~w(.mp4 .avi),
  max_file_size: 100_000_000,
  progress: :progress)
```

Handle progress events:

```elixir
def handle_info({:progress, ref, %{loaded: loaded, total: total}}, socket) do
  if loaded == total do
    {:noreply, socket}
  else
    percent = round(loaded / total * 100)
    {:noreply, socket}
  end
end
```

### Auto-Upload

Skip the submit button for immediate uploads:

```elixir
allow_upload(:avatar, accept: ~w(.jpg), auto_upload: true)
```

Handle auto-uploaded entries:

```elixir
def handle_event("validate", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
      dest = Path.join(priv_dir(), Path.basename(path))
      File.cp!(path, dest)
      {:ok, ~p"/uploads/#{Path.basename(dest)}"}
    end)

  {:noreply, update(socket, :uploaded_files, &(&1 ++ uploaded_files))}
end
```

### External Cloud Uploads

For production, upload directly to cloud storage (S3, Google Cloud, etc.) via signed URLs:

```elixir
allow_upload(:avatar,
  accept: ~w(.jpg .png),
  external: {:s3, config})
```

Configure S3 uploader:

```elixir
defmodule MyAppWeb.S3Uploader do
  def sign(entry) do
    # Return signed URL for direct browser upload
  end
end
```

The browser uploads directly to S3; your server only records the final URL.

## Important Considerations

### File Size Validation

Size validations happen server-side during chunk reception. While client metadata can't be trusted, the `max_file_size` constraint is enforced as each chunk arrives—rejecting oversized uploads before full transfer.

### Storage Strategy

**Development**: Direct-to-disk storage works fine:

```elixir
File.cp!(path, dest)
```

**Production**: Local storage has serious limitations. For distributed deployments:

1. **Database**: Store file content in the database

```elixir
MyApp.Document.create(%{content: File.read!(path)})
```

2. **Centralized storage**: S3, Google Cloud, or similar

```elixir
{:ok, _pid} = ExAws.S3.put_object(bucket, key, File.read!(path)) |> ExAws.request()
```

3. **Message queue**: Upload asynchronously via background jobs

```elixir
Oban.insert(UploadJob.new(%{path: path, user_id: user_id}))
```

### Multiple Instances

"If you are running multiple instances of your application, the uploaded file will be stored only in one of the instances." Use centralized storage or a load balancer that routes file requests to the upload server.

### Entry Metadata

Each upload entry contains:

```elixir
%Phoenix.LiveView.UploadEntry{
  name: "photo.jpg",           # Field name
  uuid: "1234-abcd",           # Unique ID
  ref: "phx-Fk3h8...",         # Internal ref
  upload_ref: "phx-FZnl0...",  # Upload ref
  client_name: "photo.jpg",    # Browser filename
  client_type: "image/jpeg",   # MIME type
  client_size: 12345,          # Bytes
  done?: false,                # Complete?
  progress: 0..100             # Upload %
}
```

## Error Handling

Display validation errors:

```heex
<%= for err <- upload_errors(@uploads.avatar) do %>
  <p class="error">
    <%= case err do %>
      <% :too_large -> %>
        File too large (max 10MB)
      <% :not_accepted -> %>
        Invalid file type
      <% :too_many_files -> %>
        Max 2 files allowed
      <% _ -> %>
        Upload failed
    <% end %>
  </p>
<% end %>
```

Server-side error handling in `consume_uploaded_entries`:

```elixir
consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
  case process_file(path) do
    {:ok, url} -> {:ok, url}
    {:error, reason} -> {:error, reason}
  end
end)
```

## Common Patterns

**Multiple upload fields**:

```elixir
def mount(_params, _session, socket) do
  {:ok,
   socket
   |> allow_upload(:avatar, accept: ~w(.jpg .png))
   |> allow_upload(:documents, accept: ~w(.pdf .doc), max_entries: 10)}
end
```

**Preview uploaded images**:

```heex
<.form phx-submit="save" phx-change="validate">
  <.live_file_input upload={@uploads.avatar} />

  <%= for entry <- @uploads.avatar.entries do %>
    <img src={Phoenix.LiveView.upload_preview(entry)} alt="Preview" />
  <% end %>
</.form>
```

---

[← Back to main](main-index.md)
**Version:** 1.1.32
