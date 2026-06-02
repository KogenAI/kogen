# POSIX Symlinks, Caddy Routing, File Operations

Cross-project patterns for atomic symlink swaps, Caddy handler ordering, and filesystem edge cases.

## Atomic POSIX Symlink Swap

Replace a symlink target atomically without a window where the link is missing.

**Pattern** (Linux, macOS, POSIX):

```erlang
defp swap_current_symlink(app_path, target_basename) do
  current_path = Path.join(app_path, "current")
  tmp_path = Path.join(app_path, "current.tmp.#{System.unique_integer([:positive])}")

  case :file.make_symlink(target_basename, tmp_path) do
    :ok ->
      case :file.rename(tmp_path, current_path) do
        :ok ->
          :ok

        {:error, reason} ->
          File.rm(tmp_path)
          {:error, "atomic symlink swap failed: #{reason}"}
      end

    {:error, reason} ->
      {:error, "ln -sfn failed: #{reason}"}
  end
end
```

**Why**: `:file.rename(tmp, current)` atomically replaces an existing symlink (or file) at `current` with the contents of `tmp`. No intermediate state where `current` is missing. Improves on `rm current; ln -s target current` which has a missing-link window → broken until symlink recreated.

**Coverage**: Error arms (`:file.make_symlink` failure, `:file.rename` failure, cleanup) are operational-only (require filesystem injection) — justified with `# coveralls-ignore-start: <reason>` pragmas. Guard lines are covered in normal tests.

## Caddy file_server + pass_thru + Static Response 404

Caddy's `file_server` handler returns HTTP 200 with an empty body when a requested path is absent, instead of delegating to the next handler.

**Problem**: A route with only a `file_server` handler → path miss → blank 200 (no 404).

**Solution**: Add `"pass_thru" => true` to the `file_server` config map AND append a terminal `static_response` 404 handler LAST in the route's `handle` list.

```elixir
# In Caddy JSON config
%{
  "handler" => "file_server",
  "root" => "/var/www/site",
  "pass_thru" => true          # Fall through on path miss
}

# Terminal handler (MUST be last, after file_server, redirects, snippets, etc.):
%{"handler" => "static_response", "status_code" => 404}
```

**Handler list order**: Handlers execute in list order. When appending a 404:

1. Build initial `handlers` list (e.g., `[www_redirect, file_server]`)
2. Append 404 LAST: `handlers ++ [not_found_handler]` → `[www_redirect, file_server, not_found_404]`
3. Verify `List.last(route["handle"])["handler"] == "static_response"` in tests

If prepends (snippets, redirects) add handlers first, they come BEFORE the 404 in the final list — 404 must still be appended last to ensure it's the fallback.

**Without `pass_thru: true`**: file_server matches the handler → returns blank 200 regardless of whether the path exists.

**Without terminal 404**: file_server + `pass_thru: true` falls through, but with no subsequent handler → Caddy emits blank 200.

**Both required**: `pass_thru` allows fall-through; terminal 404 catches it and returns proper status.

## File.mkdir_p! Edge Case — Parent Is a File

`File.mkdir_p!(path)` creates all parent directories. If a path component that SHOULD be a directory is a file instead, the call fails with `"not a directory"`.

**Symptom**: Test runs a first time (creates `partci55/user_files` as directory). An aborted test run or concurrent process later removes the dir but leaves a file at that path (e.g., `partci55/user_files` as a file). Next test run tries `File.mkdir_p!(partci55/user_files/subdir)` → fails.

**Mitigation**: Before `mkdir_p`, remove the path if it's a file (not a directory):

```elixir
defp ensure_dir!(path) do
  case File.lstat(path) do
    {:ok, %{type: :regular}} -> File.rm_rf!(path)  # Path is a file, remove it
    {:ok, %{type: :directory}} -> :ok               # Already a dir, OK
    {:error, :enoent} -> :ok                        # Doesn't exist, OK
    _ -> :ok
  end

  File.mkdir_p!(path)
end
```

**Note**: Use `File.lstat/1` (not `File.stat/1`) to detect symlinks without following them. `File.lstat` returns `:symlink` type; `File.stat` follows.

## Symlink Detection Without Following

Detect whether a path is a symlink without following the link target.

```elixir
defp symlink?(path) do
  case File.lstat(path) do
    {:ok, %{type: :symlink}} -> true
    _ -> false
  end
end
```

**Why `lstat` not `stat`**: `File.stat/1` follows symlinks and returns info about the TARGET; `File.lstat/1` returns info about the link itself, including type `:symlink`.

**Use case**: Walking a directory tree (e.g., `SourceTree.list/2` scanning for file extensions) to exclude external symlinks (e.g., OCG-shared files symlinked into a provisioned app) without false-positive scans on the link target.
