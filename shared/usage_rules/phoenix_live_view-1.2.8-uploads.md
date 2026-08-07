# phoenix_live_view - File Uploads

## Overview

Phoenix LiveView provides built-in support for interactive file uploads with progress tracking. It enables both direct server uploads and direct-to-cloud external uploads, with automatic validation and reactive UI updates.

## Key Features

- **Accept Specification**: Define accepted file types, maximum entries, and file size limits
- **Reactive Entries**: Automatically update upload progress and errors in real-time
- **Drag-and-Drop**: Support drag-and-drop functionality via `phx-drop-target` attribute
- **External Storage**: Handles both server-side and cloud storage options

## Implementation Steps

### 1. Enable Uploads During Mount

Configure uploads using `allow_upload/3`, specifying constraints:

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

Options:

- `accept`: File extensions or MIME types allowed
- `max_entries`: Maximum number of files per upload
- `max_file_size`: Maximum bytes per file
- `external`: Atom for external upload handler (AWS S3, etc.)
- `progress`: Hook to track upload progress

### 2. Render File Input

Use the `live_file_input` component with form binding:

```heex
<form id="upload-form" phx-change="validate" phx-submit="save">
  <.live_file_input upload={@uploads.avatar} />

  <!-- Show uploaded file info -->
  <div :for={entry <- @uploads.avatar.entries}>
    <div><%= entry.client_name %></div>
    <progress value={entry.progress} max="100">
      <%= entry.progress %>%
    </progress>

    <!-- Show upload errors -->
    <div :for={err <- upload_errors(@uploads.avatar, entry)}>
      <p class="error"><%= error_to_string(err) %></p>
    </div>
  </div>

  <button type="submit">Upload</button>
</form>
```

### 3. Handle Validation Events

Implement event handler for upload validation:

```elixir
def handle_event("validate", _params, socket) do
  {:noreply, socket}
end
```

This minimal handler triggers automatic validation against specified constraints (file type, size, count).

### 4. Process Uploads in Submission

Use `consume_uploaded_entries/3` to persist files after validation:

```elixir
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
      dest = Path.join("priv/uploads", "avatar_#{entry.uuid}.jpg")
      File.cp!(path, dest)
      {:ok, dest}
    end)

  {:noreply,
    socket
    |> assign(:uploaded_files, uploaded_files)
    |> assign(:uploads, %{})
  }
end
```

### 5. Enable Drag-and-Drop

Add `phx-drop-target` to enable drag-and-drop uploads:

```heex
<form id="upload-form" phx-change="validate" phx-drop-target={@myself}>
  <.live_file_input upload={@uploads.avatar} />
</form>
```

Users can now drag files from file system directly onto the form.

## Error Handling

### Upload Errors

Check for errors after upload attempt:

```elixir
defp error_to_string(:too_large), do: "File is too large"
defp error_to_string(:not_accepted), do: "File type not accepted"
defp error_to_string(:too_many_files), do: "Too many files"
```

### Helper Functions

- `upload_errors(@uploads.field, entry)`: List errors for specific file
- `upload_errors(@uploads.field)`: All errors for upload field

## Storage Considerations

### Server-Side Storage (Direct to Disk)

Storing uploads directly on disk has limitations in production, especially with multiple application instances:

**Problems:**

- Single instance setup: Lost on redeploy
- Multiple instances: Files only on one server
- Scaling issues: Separate storage service needed for load balancing

```elixir
dest = Path.join("priv/uploads", "file_#{entry.uuid}")
File.cp!(path, dest)
```

**When to use**: Development, small single-server deployments

### Cloud Storage (Recommended)

For production, store files in external services:

```elixir
def handle_event("save", _params, socket) do
  uploaded_files =
    consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
      {:ok, url} = upload_to_s3(path, entry)
      {:ok, url}
    end)

  {:noreply, assign(socket, :uploaded_files, uploaded_files)}
end
```

**Benefits:**

- Scales across multiple instances
- Persistent storage
- CDN integration available
- Automatic backups

### External Uploader Configuration

Configure external uploaders (AWS S3, etc.) at mount:

```elixir
allow_upload(:avatar,
  accept: ~w(.jpg .jpeg .png),
  external: :s3,
  max_entries: 2
)
```

The external handler manages direct browser-to-cloud uploads with signed URLs.

## Progress Tracking

Access upload progress in template:

```heex
<div :for={entry <- @uploads.avatar.entries}>
  <div class="filename"><%= entry.client_name %></div>
  <progress value={entry.progress} max="100"></progress>
  <span><%= entry.progress %>% uploaded</span>
</div>
```

Entry properties:

- `client_name`: Original filename from browser
- `progress`: Current upload percentage (0-100)
- `ref`: Unique reference for this upload

---

[← Back to main](phoenix_live_view-1.2.8.md)
**Version:** 1.2.8
