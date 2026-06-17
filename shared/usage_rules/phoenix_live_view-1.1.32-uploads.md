# phoenix_live_view - File Uploads & Media

## File Upload Overview

Phoenix LiveView provides built-in support for interactive file uploads with progress tracking, validation, and drag-and-drop functionality. The upload system validates files on both client and server, provides real-time progress updates, and supports consuming uploads after user submission.

## Enabling Uploads

Enable uploads during `mount/3` using `allow_upload/3`:

```elixir
def mount(_params, _session, socket) do
  {:ok, allow_upload(socket, :avatar, accept: ~w(.jpg .jpeg .png), max_file_size: 9_000_000)}
end
```

### Upload Configuration Options

```elixir
allow_upload(socket, :files,
  accept: ~w(.pdf .doc .docx),           # Accepted file types
  max_entries: 5,                        # Maximum number of files
  max_file_size: 10_000_000,            # Max size in bytes
  auto_upload: false,                   # Manual upload trigger
  progress: :upload_progress,           # Callback for progress events
  external: &presigned_url/2            # External storage handler
)
```

## Upload Form Markup

Use the `live_file_input` component to render upload inputs:

```elixir
<.form for={@form} phx-submit="save" phx-change="validate">
  <.live_file_input upload={@uploads.avatar} />

  <button type="submit" disabled={!Enum.empty?(@uploads.avatar.errors)}>
    Upload
  </button>
</.form>
```

### Drag and Drop

Enable drag-and-drop with `phx-drop-target`:

```html
<div phx-drop-target="{@uploads.files}">
  Drag files here or click to select <.live_file_input upload={@uploads.files}
  />
</div>
```

## Progress Tracking

Access upload progress through `@uploads.field_name.entries`:

```elixir
def render(assigns) do
  ~H"""
  <div>
    {for entry <- @uploads.avatar.entries do}
      <div>
        <p>{entry.client_name}</p>
        <progress value={entry.progress} max="100" />
        <span>{entry.progress}%</span>
      </div>
    {/for}
  </div>
  """
end

def handle_event("validate", _params, socket) do
  {:noreply, socket}
end
```

### Entry Properties

Each upload entry provides:

```elixir
entry.client_name    # Original filename from client
entry.progress       # Current upload progress (0-100)
entry.errors         # Validation errors
entry.ref            # Unique entry reference
entry.client_type    # MIME type from client
```

### Error Handling

Display upload errors to users:

```elixir
<.error :for={err <- @uploads.avatar.errors}>
  {err}
</.error>

<div :for={entry <- @uploads.avatar.entries}>
  <p>{entry.client_name}</p>
  <button phx-click="cancel_upload" phx-value-ref={entry.ref}>
    Cancel
  </button>
</div>

def handle_event("cancel_upload", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :avatar, ref)}
end
```

## Processing Completed Uploads

After form submission, consume uploaded entries using `consume_uploaded_entries/3`:

```elixir
def handle_event("save", _params, socket) do
  consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
    dest = Path.join("priv/static/uploads", Path.basename(path))
    File.cp!(path, dest)
    {:ok, dest}
  end)
  |> case do
    {[path], socket} ->
      {:noreply, assign(socket, avatar_path: path)}
    {_paths, socket} ->
      {:noreply, assign(socket, error: "Upload failed")}
  end
end
```

### Entry Processing Parameters

`consume_uploaded_entries/3` passes two arguments to the callback:

```elixir
consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
  path          # Temporary file path (valid until callback returns)
  entry.ref     # Unique reference
  entry.client_name  # Original filename
  entry.client_type  # MIME type
  {:ok, result}     # Return processed result
end)
```

## Production Considerations

**Storage Limitations:** Storing uploads directly on disk has limitations when running multiple application instances. Each instance maintains separate uploads, causing distributed upload loss.

**Recommended Approaches:**

1. **Database Storage:** Store binary data in database with metadata:

```elixir
def handle_event("save", _params, socket) do
  consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
    data = File.read!(path)
    {:ok, avatar} = Accounts.create_avatar(%{
      user_id: socket.assigns.user_id,
      filename: entry.client_name,
      content_type: entry.client_type,
      data: data
    })
    {:ok, avatar}
  end)
end
```

2. **Cloud Storage (S3, etc.):** Use presigned URLs for direct uploads:

```elixir
def allow_upload(socket, :avatar) do
  allow_upload(socket, :avatar,
    accept: ~w(.jpg .jpeg .png),
    max_file_size: 9_000_000,
    external: &get_s3_presigned_url/2
  )
end

defp get_s3_presigned_url(ref, _entry) do
  bucket = Application.get_env(:my_app, :s3_bucket)
  key = "uploads/#{Ecto.UUID.generate()}"

  {:ok, presigned_url} = ExAws.S3.presigned_url(:put_object, bucket, key)
  {:ok, presigned_url, %{"key" => key}}
end
```

3. **External Uploads Handler:** Configure external upload service:

```elixir
allow_upload(socket, :avatar,
  accept: ~w(.jpg .jpeg .png),
  max_file_size: 9_000_000,
  external: &my_upload_handler/2
)

defp my_upload_handler(ref, _entry) do
  # Generate upload URL
  {:ok, upload_url, signed_options}
end
```

## Multiple File Uploads

Handle multiple files in a single field:

```elixir
allow_upload(socket, :documents,
  accept: ~w(.pdf),
  max_entries: 10,
  max_file_size: 50_000_000
)

def handle_event("save", _params, socket) do
  uploaded_files = consume_uploaded_entries(socket, :documents, fn %{path: path}, entry ->
    dest = Path.join("priv/static/uploads", Path.basename(path))
    File.cp!(path, dest)
    {:ok, %{filename: entry.client_name, path: dest}}
  end)

  case uploaded_files do
    {files, socket} when is_list(files) ->
      # Store metadata for files
      {:noreply, assign(socket, files: files)}
    {_files, socket} ->
      {:noreply, assign(socket, error: "Upload failed")}
  end
end
```

## Auto Upload

Upload files immediately without waiting for form submission:

```elixir
allow_upload(socket, :avatar,
  accept: ~w(.jpg .jpeg .png),
  auto_upload: true
)

def handle_event("validate", %{"_target" => ["avatar"]}, socket) do
  consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
    # Process immediately
    {:ok, store_file(path, entry)}
  end)
  |> case do
    {[result], socket} ->
      {:noreply, assign(socket, avatar: result)}
    {[], socket} ->
      {:noreply, socket}
  end
end
```

## Best Practices

**Validate File Types:** Use `accept` option to restrict file types. Always validate server-side as well:

```elixir
@allowed_types ~w(.jpg .jpeg .png .gif)

def validate_upload(entry) do
  case Path.extname(entry.client_name) do
    ext when ext in @allowed_types -> :ok
    _ -> :error
  end
end
```

**Set Reasonable Size Limits:** Prevent abuse with strict file size and entry count limits:

```elixir
allow_upload(socket, :avatar,
  max_file_size: 9_000_000,  # 9 MB
  max_entries: 1             # Single file only
)
```

**Provide Clear Feedback:** Show upload progress, errors, and success states clearly to users.

**Handle Cleanup:** Remove temporary files after processing:

```elixir
def handle_event("save", _params, socket) do
  consume_uploaded_entries(socket, :files, fn %{path: path}, _entry ->
    try do
      data = File.read!(path)
      {:ok, process_file(data)}
    after
      File.rm!(path)
    end
  end)
end
```

---

[← Back to main](phoenix_live_view-1.1.32.md)  
**Version:** 1.1.32
