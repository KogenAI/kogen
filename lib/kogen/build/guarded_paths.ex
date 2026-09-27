defmodule Kogen.Build.GuardedPaths do
  @moduledoc """
  Controller-memory snapshot used to check Candidate topology against Approved guards.

  Capture reads only the root it is given (the Candidate in a Build), so
  ignored files written in the control checkout during a Build never reach
  it. Git's own configuration and exclude file are located through
  `git rev-parse --git-path`, because a linked worktree's `.git` is a file:
  a Candidate's `config` and `info/exclude` are control's. A change to them
  during the Build is an environment event, not the Candidate's; only a
  change of the ignored state of Candidate paths through the exclude file
  stops the Build.
  """

  @volatile ~w(.kogen/runtime .kogen/build.lock .kogen/codex .codex/sessions _build deps cover .elixir_ls)

  @config_message "Git configuration or ignore policy changed during Developer turn"
  @violation_prefix "Candidate changed paths outside Approved guards: "
  @exclude_prefix "Control's .git/info/exclude changed the ignored state of Candidate paths: "

  # Hook registrations, hook scripts and the loaded agent configuration: an
  # unguarded change to any of them is never reworked.
  @protected ~w(.codex/hooks/** .codex/hooks.json .codex/config.toml .claude/settings.json
                .claude/hooks/** .claude/agents/** .claude/commands/** .claude/skills/**)

  # Control's shared Git files: a change to them is an environment event of
  # the Build, never a Candidate change.
  @shared [".git/config", ".git/info/exclude"]

  def capture(root) do
    with {:ok, head} <- git(root, ["rev-parse", "HEAD^{tree}"]),
         head = String.trim(head),
         {:ok, files} <- config_files(root),
         {:ok, config} <- snapshot_files(root, files),
         {:ok, ignored} <- ignored_manifest(root),
         {:ok, tracked} <- tracked_modes(root, head) do
      {:ok,
       %{
         root: Path.expand(root),
         head_tree: head,
         files: files,
         config: config,
         exclude_start: config[".git/info/exclude"],
         ignored: ignored,
         tracked: tracked,
         dirs: known_dirs(Map.keys(tracked) ++ Map.keys(ignored))
       }}
    end
  end

  # `{label, path}` pairs: Git's own files through `--git-path`, the tracked
  # policy files at the worktree root. `.gitignore` is not here: it is an
  # ordinary guarded path (scenario `declared-gitignore-edit`), checked like
  # any other tracked file through `changed_paths/3`, not frozen here.
  defp config_files(root) do
    with {:ok, config} <- git_path(root, "config"),
         {:ok, exclude} <- git_path(root, "info/exclude") do
      {:ok,
       [
         {".git/config", config},
         {".git/info/exclude", exclude},
         {".gitmodules", Path.join(root, ".gitmodules")}
       ]}
    end
  end

  defp git_path(root, name) do
    with {:ok, out} <- git(root, ["rev-parse", "--git-path", name]),
         do: {:ok, Path.expand(String.trim(out), root)}
  end

  @doc """
  Compares the Candidate with `snapshot` and returns `{result, snapshot,
  env_events}`.

  `result` is `:ok`, `{:rework, paths}` (unguarded paths an ordinary
  Developer turn left behind) or `{:stop, category, message}`; terminal
  findings win. The returned snapshot carries the current bytes of control's
  `.git/config` and `.git/info/exclude`, so each change of them is one
  `%{file:, before:, after:}` event (sha256 digests, `nil` for a missing
  file) and is never reported twice; the head tree, the ignored-file
  manifest and the Build-start exclude bytes stay as captured.
  """
  def check(snapshot, guards) when is_map(snapshot) and is_list(guards) do
    case snapshot_files(snapshot.root, snapshot.files) do
      {:ok, config} ->
        events =
          for file <- @shared, config[file] != snapshot.config[file] do
            %{file: file, before: digest(snapshot.config[file]), after: digest(config[file])}
          end

        refreshed = %{snapshot | config: Map.merge(snapshot.config, Map.take(config, @shared))}
        {classify(refreshed, config, guards), refreshed, events}

      {:error, reason} ->
        {{:stop, "integrity", reason}, snapshot, []}
    end
  end

  defp classify(snapshot, config, guards) do
    with :ok <- same_policy(config, snapshot),
         :ok <- same_ignored_state(snapshot, config),
         {:ok, paths} <- changed_paths(snapshot.root, snapshot.head_tree, snapshot.ignored) do
      paths |> Enum.reject(&allowed?(&1, guards)) |> invalid()
    else
      {:stop, _category, _message} = stop -> stop
      {:error, reason} -> {:stop, "integrity", reason}
    end
  end

  # `.gitmodules` is the Candidate's own Git policy file.
  defp same_policy(config, snapshot) do
    if config[".gitmodules"] == snapshot.config[".gitmodules"],
      do: :ok,
      else: {:stop, "git-policy", @config_message}
  end

  defp invalid([]), do: :ok

  defp invalid(paths) do
    cond do
      Enum.any?(paths, fn path -> Enum.any?(@protected, &matches?(path, &1)) end) ->
        {:stop, "protected-path", violation_message(paths)}

      # Only the root `.gitignore`; a nested one is an ordinary stray path.
      ".gitignore" in paths ->
        {:stop, "git-policy", violation_message(paths)}

      true ->
        {:rework, paths}
    end
  end

  @doc "The stray-path message listing `paths`."
  def violation_message(paths), do: @violation_prefix <> Enum.join(paths, ", ")

  # After control's exclude file changed, an untracked Candidate path whose
  # ignored state differs between the current and the Build-start exclude
  # (the Candidate's own `.gitignore` files apply under both) would be
  # verified in the worktree but left out of `git add -A`, so the Candidate
  # id and publication. Guarded or not, that is terminal.
  defp same_ignored_state(%{exclude_start: start} = snapshot, config) do
    if config[".git/info/exclude"] == start do
      :ok
    else
      case ignored_state_changes(snapshot, start) do
        {:ok, []} -> :ok
        {:ok, paths} -> {:stop, "git-policy", @exclude_prefix <> Enum.join(paths, ", ")}
        {:error, _} = error -> error
      end
    end
  end

  defp ignored_state_changes(snapshot, start) do
    {_label, current} = List.keyfind(snapshot.files, ".git/info/exclude", 0)

    before =
      Path.join(System.tmp_dir!(), "kogen-exclude-#{System.unique_integer([:positive])}")

    File.write!(before, start_bytes(start))

    try do
      with {:ok, now} <- ignored_with(snapshot.root, current),
           {:ok, then} <- ignored_with(snapshot.root, before) do
        {:ok,
         (now -- then)
         |> Enum.concat(then -- now)
         |> Enum.reject(&volatile?/1)
         |> Enum.uniq()
         |> Enum.sort()}
      end
    after
      File.rm(before)
    end
  end

  defp start_bytes({:file, bytes}), do: bytes
  defp start_bytes(_missing), do: ""

  # `--exclude-standard` spelled out with `exclude` in place of
  # `.git/info/exclude`: per-directory `.gitignore` files, the user's global
  # excludes, then `exclude`.
  defp ignored_with(root, exclude) do
    files = Enum.filter(global_excludes(root) ++ [exclude], &File.regular?/1)

    args =
      ["ls-files", "--others", "--ignored", "--exclude-per-directory=.gitignore", "-z"] ++
        Enum.map(files, &("--exclude-from=" <> &1))

    with {:ok, out} <- git(root, args), do: {:ok, String.split(out, <<0>>, trim: true)}
  end

  defp global_excludes(root) do
    case git(root, ["config", "--path", "--get", "core.excludesFile"]) do
      {:ok, path} when path != "" ->
        [Path.expand(String.trim(path), root)]

      _unset ->
        base =
          System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home() || "/", ".config")

        [Path.join(base, "git/ignore")]
    end
  end

  @doc """
  The rework listing of `paths`, sorted: each untracked path collapsed to its
  topmost directory that did not exist at capture and holds no guarded
  change, paired with its action: `:delete`, or `{:restore, mode}` for a
  path tracked in the head tree, `mode` being `"755"` for a 100755 entry and
  `"644"` otherwise.
  """
  def rework_items(snapshot, paths, guards) do
    allowed =
      case changed_paths(snapshot.root, snapshot.head_tree, snapshot.ignored) do
        {:ok, changed} -> Enum.filter(changed, &allowed?(&1, guards))
        {:error, _} -> []
      end

    paths
    |> Enum.map(&collapse(&1, snapshot, allowed))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path ->
      case snapshot.tracked[path] do
        nil -> {path, :delete}
        "100755" -> {path, {:restore, "755"}}
        _mode -> {path, {:restore, "644"}}
      end
    end)
  end

  defp collapse(path, snapshot, allowed) do
    path
    |> ancestors()
    |> Enum.find(path, fn dir ->
      not MapSet.member?(snapshot.dirs, dir) and
        not Enum.any?(allowed, &String.starts_with?(&1, dir <> "/"))
    end)
  end

  defp ancestors(path) do
    parts = Path.split(path)
    for n <- 1..(length(parts) - 1)//1, do: parts |> Enum.take(n) |> Path.join()
  end

  defp known_dirs(paths), do: paths |> Enum.flat_map(&ancestors/1) |> MapSet.new()

  defp tracked_modes(root, tree) do
    with {:ok, out} <- git(root, ["ls-tree", "-r", "-z", tree]) do
      {:ok,
       out
       |> String.split(<<0>>, trim: true)
       |> Map.new(fn entry ->
         [meta, path] = String.split(entry, "\t", parts: 2)
         {path, meta |> String.split(" ") |> hd()}
       end)}
    end
  end

  defp digest({:file, bytes}), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  defp digest(_missing), do: nil

  defp changed_paths(root, tree, frozen_ignored) do
    args = [
      "-c",
      "diff.external=",
      "-c",
      "diff.trustExitCode=false",
      "-c",
      "core.fsmonitor=false",
      "diff",
      "--raw",
      "-z",
      "--no-renames",
      tree,
      "--"
    ]

    with {:ok, raw} <- git(root, args),
         {:ok, untracked} <- git(root, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, ignored} <- ignored_manifest(root) do
      tracked = raw |> String.split(<<0>>, trim: true) |> raw_paths()

      ignored_changes =
        (Map.keys(ignored) ++ Map.keys(frozen_ignored))
        |> Enum.uniq()
        |> Enum.filter(&(ignored[&1] != frozen_ignored[&1]))

      extras = String.split(untracked, <<0>>, trim: true) ++ ignored_changes
      {:ok, (tracked ++ extras) |> Enum.reject(&volatile?/1) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp raw_paths(entries),
    do:
      entries
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        [_metadata, path] -> [path]
        _ -> []
      end)

  # credo:disable-for-lines:38 Credo.Check.Refactor.Nesting
  defp ignored_manifest(root) do
    with {:ok, output} <-
           git(root, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]) do
      output
      |> String.split(<<0>>, trim: true)
      |> Enum.reject(&volatile?/1)
      |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
        full = Path.join(root, path)

        case File.lstat(full) do
          {:ok, %{type: :regular, mode: mode}} ->
            case File.read(full) do
              {:ok, bytes} ->
                {:cont, {:ok, Map.put(acc, path, {mode, :crypto.hash(:sha256, bytes)})}}

              {:error, reason} ->
                {:halt, {:error, "could not read ignored path #{path}: #{inspect(reason)}"}}
            end

          {:ok, %{type: :symlink, mode: mode}} ->
            {:cont, {:ok, Map.put(acc, path, {mode, File.read_link!(full)})}}

          {:ok, _} ->
            {:cont, {:ok, acc}}

          {:error, :enoent} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, "could not inspect ignored path #{path}: #{inspect(reason)}"}}
        end
      end)
    end
  end

  defp snapshot_files(_root, files) do
    Enum.reduce_while(files, {:ok, %{}}, fn {path, full}, {:ok, acc} ->
      value =
        case File.read(full) do
          {:ok, bytes} -> {:file, bytes}
          {:error, :enoent} -> :missing
          {:error, reason} -> {:error, reason}
        end

      case value do
        {:error, reason} -> {:halt, {:error, "could not snapshot #{path}: #{inspect(reason)}"}}
        _ -> {:cont, {:ok, Map.put(acc, path, value)}}
      end
    end)
  end

  defp allowed?(path, guards), do: Enum.any?(guards, &matches?(path, &1))

  defp matches?(path, guard) do
    regex =
      guard |> Regex.escape() |> String.replace("\\*\\*", ".*") |> String.replace("\\*", "[^/]*")

    Regex.match?(Regex.compile!("^" <> regex <> "$"), path)
  end

  defp volatile?(path),
    do:
      path in ["erl_crash.dump", ".DS_Store"] or
        Enum.any?(@volatile, &(path == &1 or String.starts_with?(path, &1 <> "/"))) or
        String.contains?(path, "__pycache__")

  defp git(root, args) do
    # Repository configuration is an admitted input, not authority to hide a
    # mode-only Candidate change. Force mode comparison for every query used
    # to construct or compare the frozen topology.
    args = ["-c", "core.filemode=true" | args]

    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
