defmodule Kogen.Build.Workspace do
  @moduledoc """
  Candidate worktrees and per-Build harness homes: one linked Git worktree and
  one harness home per Build, outside the repository, in Kogen's own directory.

  A Candidate lives at `<workspaces-root>/<project-id>/<slug>-<build-id>/` on
  branch `kogen/<slug>/<build-id>`, its harness home at
  `<workspaces-root>/<project-id>/harness/<build-id>/` and its owner record at
  `<workspaces-root>/<project-id>/candidates/<build-id>.json`.
  `<workspaces-root>` is `~/Library/Application Support/Kogen/build-workspaces`
  unless `KOGEN_WORKSPACES_ROOT` is set; `<project-id>` is the SHA-256 of the
  expanded control path (`Kogen.ClaudeCode.project_id/1`). Every function
  takes the control root explicitly; nothing here reads the process working
  directory.

  Creation is `create/2`, the one place a later seeding step can extend. The
  Candidate receives a plain recursive copy of control `deps/`, no `_build/`,
  and the controller's frozen Approved bytes; nothing else from control's
  ignored state. Publication fast-forwards the admitted branch only when it
  has not moved and control is clean. Only a published Candidate is removed
  automatically (never its harness home); every other one is kept for the
  Shaper and removed by `remove/3` (`mix kogen.candidates.remove`).
  """

  @schema_version 1
  @approved_base ".kogen/intents/approved"
  @lock_path ".kogen/build.lock"
  @harness_dirs ["claude", "codex", "raw-log"]

  @type candidate :: %{required(atom()) => term()}

  @doc "The workspaces root; `KOGEN_WORKSPACES_ROOT` overrides the Kogen default."
  @spec root() :: Path.t()
  def root do
    case System.get_env("KOGEN_WORKSPACES_ROOT") do
      value when is_binary(value) and value != "" ->
        Path.expand(value)

      _ ->
        Path.join(System.user_home!(), "Library/Application Support/Kogen/build-workspaces")
    end
  end

  @doc """
  The project id: SHA-256 of the expanded control path, the same id the login
  selectors use (`Kogen.ClaudeCode.project_id/1`).
  """
  @spec project_id(Path.t()) :: String.t()
  def project_id(control),
    do: :crypto.hash(:sha256, Path.expand(control)) |> Base.encode16(case: :lower)

  @doc "This control checkout's directory under the workspaces root (canonical once it exists)."
  @spec project_dir(Path.t()) :: Path.t()
  def project_dir(control), do: canonical(Path.join(root(), project_id(control)))

  @doc "The Candidate branch for a slug and build id."
  @spec branch(String.t(), String.t()) :: String.t()
  def branch(slug, build_id), do: "kogen/#{slug}/#{build_id}"

  @doc "The owner record path for a build id."
  @spec owner_path(Path.t(), String.t()) :: Path.t()
  def owner_path(control, build_id),
    do: Path.join([project_dir(control), "candidates", build_id <> ".json"])

  @doc "The harness home path for a build id."
  @spec harness_home(Path.t(), String.t()) :: Path.t()
  def harness_home(control, build_id),
    do: Path.join([project_dir(control), "harness", build_id])

  @doc "The control build lock path."
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(control), do: Path.join(control, @lock_path)

  @doc """
  The spaceless per-Build temp dir under the controller's canonical system
  temp dir, or an error naming a system temp dir that contains a space.
  """
  @spec temp_dir(String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def temp_dir(build_id) do
    base = canonical(System.tmp_dir!())
    path = Path.join(base, "kogen-build-" <> build_id)

    if String.contains?(path, [" ", "\t", "\n"]),
      do:
        {:error,
         "the controller's system temp dir must be spaceless for the per-Build temp dir: #{base}"},
      else: {:ok, path}
  end

  @doc "The canonical, symlink-resolved form of an existing path; the expanded path otherwise."
  @spec canonical(Path.t()) :: Path.t()
  def canonical(path) do
    expanded = Path.expand(path)

    case System.cmd("/bin/realpath", [expanded], stderr_to_stdout: true) do
      {out, 0} -> String.trim_trailing(out, "\n")
      _ -> expanded
    end
  rescue
    _ -> Path.expand(path)
  end

  @doc """
  Creates the Candidate and harness home for an admitted Build, before any
  provider launch.

  `admission` holds `:control`, `:slug`, `:build_id`, `:intent_id`, `:title`,
  `:branch` and `:commit` (the admitted branch and commit), and `:bindings`,
  the recorded credential bindings resolved from control before admission,
  which the owner record names from its first write, before any harness
  process starts. `approved_entries`
  are the Build's frozen Approved package entries, written to the Candidate's
  ignored `.kogen/intents/approved/<slug>/`.

  A pre-existing path, branch, owner record, harness home or temp dir, a
  missing control `deps/`, or a failed `git worktree add` refuses admission
  and removes only what this call created. A failure after the worktree
  exists keeps it, with its owner record marked stopped, and names it.
  """
  @spec create(map(), list()) :: {:ok, candidate()} | {:error, String.t()}
  def create(admission, approved_entries) do
    control = Path.expand(admission.control)
    build_id = admission.build_id

    with :ok <- mkdir_p(Path.join(root(), project_id(control))),
         project = project_dir(control),
         {:ok, tmp_dir} <- temp_dir(build_id) do
      candidate = %{
        path: Path.join(project, "#{admission.slug}-#{build_id}"),
        branch: branch(admission.slug, build_id),
        build_id: build_id,
        slug: admission.slug,
        title: admission.title,
        intent_id: admission.intent_id,
        control: control,
        admitted_branch: admission.branch,
        admitted_commit: admission.commit,
        owner_path: Path.join([project, "candidates", build_id <> ".json"]),
        harness_home: Path.join([project, "harness", build_id]),
        tmp_dir: tmp_dir,
        bindings: Map.get(admission, :bindings, []),
        started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      admit(candidate, approved_entries)
    end
  end

  defp admit(candidate, approved_entries) do
    with :ok <- absent_path(candidate.path, "Candidate worktree path"),
         :ok <- absent_path(candidate.owner_path, "Candidate owner record"),
         :ok <- absent_path(candidate.harness_home, "Candidate harness home"),
         :ok <- absent_path(candidate.tmp_dir, "Build temp dir"),
         :ok <- absent_branch(candidate.control, candidate.branch),
         :ok <- same_project_records(candidate.control),
         {:ok, deps} <- control_deps(candidate.control),
         :ok <- write_owner(candidate, "running", nil, [:exclusive]),
         :ok <- create_private_dirs(candidate),
         :ok <- add_worktree(candidate) do
      populate(candidate, deps, approved_entries)
    end
  end

  # Created fresh and empty, never with hardlinks: a hardlink inside a granted
  # tree would let a role write the linked file.
  defp create_private_dirs(candidate) do
    with :ok <- mkdir_p(Path.dirname(candidate.harness_home)),
         :ok <- private_mkdir(candidate.harness_home),
         :ok <- harness_dirs(candidate.harness_home),
         :ok <- private_mkdir(candidate.tmp_dir) do
      :ok
    else
      {:error, reason} ->
        undo_created(candidate)
        {:error, "could not create the Build's harness home or temp dir: #{reason}"}
    end
  end

  defp harness_dirs(home) do
    Enum.reduce_while(@harness_dirs, :ok, fn name, :ok ->
      case private_mkdir(Path.join(home, name)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp private_mkdir(path) do
    case File.mkdir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not create #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Only what this admission created: its owner record, harness home and temp
  # dir. Nothing that existed before is touched.
  defp undo_created(candidate) do
    File.rm(candidate.owner_path)
    File.rm_rf(candidate.harness_home)
    File.rm_rf(candidate.tmp_dir)
  end

  defp populate(candidate, deps, approved_entries) do
    with :ok <- copy_deps(deps, Path.join(candidate.path, "deps")),
         :ok <- write_approved_copy(candidate, approved_entries) do
      {:ok, candidate}
    else
      {:error, reason} ->
        update_status(candidate, "stopped: admission")

        {:error,
         "Candidate admission failed after the worktree was created: #{reason}; " <>
           retained_description(candidate)}
    end
  end

  defp absent_path(path, label) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, "#{label} already exists and is never reused: #{path}"}
      {:error, reason} -> {:error, "could not inspect #{label} #{path}: #{inspect(reason)}"}
    end
  end

  defp absent_branch(control, branch) do
    case git(control, ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch]) do
      {:ok, _} -> {:error, "Candidate branch already exists and is never reused: #{branch}"}
      {:error, _} -> :ok
    end
  end

  # A record naming another control root under this project id means a hash
  # collision or tampering; admission stops rather than sharing the directory.
  defp same_project_records(control) do
    control
    |> owner_records()
    |> Enum.find(fn
      {:ok, record} -> record["control_root"] != control
      {:error, _path, _reason} -> false
    end)
    |> case do
      nil ->
        :ok

      {:ok, record} ->
        {:error,
         "Candidate owner record #{record["build_id"]} under this project id names another control root: #{record["control_root"]}"}
    end
  end

  defp control_deps(control) do
    deps = Path.join(control, "deps")

    if File.dir?(deps),
      do: {:ok, deps},
      else:
        {:error,
         "control deps/ is missing at #{deps}; run `mix deps.get` in the control checkout before building (no network fallback)"}
  end

  defp add_worktree(candidate) do
    case git(candidate.control, [
           "worktree",
           "add",
           "--quiet",
           "-b",
           candidate.branch,
           candidate.path,
           candidate.admitted_commit
         ]) do
      {:ok, _} ->
        :ok

      {:error, output} ->
        undo_created(candidate)
        # A partially created path is this admission's own; a pre-existing
        # one was refused above and never reaches this point.
        File.rm_rf(candidate.path)
        {:error, "git worktree add failed for #{candidate.path}: #{output}"}
    end
  end

  # A plain recursive copy (never `cp -l`): a hardlink inside the Candidate
  # would let a role write the control file it links.
  defp copy_deps(source, destination) do
    case System.cmd("/bin/cp", ["-R", source <> "/", destination], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, _} -> {:error, "could not copy control deps/: #{String.trim(out)}"}
    end
  end

  defp write_approved_copy(candidate, entries) do
    directory = approved_dir(candidate)

    case File.lstat(directory) do
      {:error, :enoent} ->
        write_entries(directory, entries)

      # A checkout that tracks its Approved package already holds it; only the
      # frozen bytes are acceptable.
      {:ok, %{type: :directory}} ->
        if package_entries(directory, "") == entries,
          do: :ok,
          else: {:error, "Candidate Approved copy differs from the frozen package: #{directory}"}

      _ ->
        {:error, "Candidate Approved copy already exists: #{directory}"}
    end
  end

  defp package_entries(root, relative) do
    path = Path.join(root, relative)
    stat = File.lstat!(path)

    case stat.type do
      :directory ->
        [
          {relative, :directory, stat.mode}
          | path
            |> File.ls!()
            |> Enum.sort()
            |> Enum.flat_map(&package_entries(root, Path.join(relative, &1)))
        ]

      :regular ->
        [{relative, :regular, stat.mode, File.read!(path)}]

      other ->
        [{relative, other}]
    end
  end

  @doc "The Candidate's ignored Approved copy."
  @spec approved_dir(candidate()) :: Path.t()
  def approved_dir(candidate), do: Path.join([candidate.path, @approved_base, candidate.slug])

  @doc "Writes frozen package entries under `directory`, then restores directory modes."
  @spec write_entries(Path.t(), list()) :: :ok | {:error, String.t()}
  def write_entries(directory, entries) do
    File.mkdir_p!(directory)

    Enum.each(entries, fn
      {relative, :directory, _mode} ->
        File.mkdir_p!(Path.join(directory, relative))

      {relative, :regular, mode, bytes} ->
        path = Path.join(directory, relative)
        File.write!(path, bytes)
        File.chmod!(path, Bitwise.band(mode, 0o7777))
    end)

    entries
    |> Enum.reverse()
    |> Enum.each(fn
      {relative, :directory, mode} ->
        File.chmod!(Path.join(directory, relative), Bitwise.band(mode, 0o7777))

      _entry ->
        :ok
    end)
  rescue
    error in File.Error -> {:error, Exception.message(error)}
  end

  @doc "The credential bindings the Candidate's owner record names on disk."
  @spec recorded_bindings(candidate()) :: {:ok, [map()]} | {:error, String.t()}
  def recorded_bindings(candidate) do
    with {:ok, bytes} <- File.read(candidate.owner_path),
         {:ok, %{"credential_bindings" => bindings}} when is_list(bindings) <-
           Jason.decode(bytes) do
      {:ok, bindings}
    else
      _ -> {:error, "Candidate owner record #{candidate.owner_path} names no credential bindings"}
    end
  end

  @doc "Updates the owner record status, with the Candidate commit when one exists."
  @spec update_status(candidate(), String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def update_status(candidate, status, commit \\ nil),
    do: write_owner(candidate, status, commit, [])

  defp write_owner(candidate, status, commit, modes) do
    record = %{
      "schema_version" => @schema_version,
      "build_id" => candidate.build_id,
      "intent_id" => candidate.intent_id,
      "slug" => candidate.slug,
      "title" => candidate.title,
      "control_root" => candidate.control,
      "worktree_path" => candidate.path,
      "branch" => candidate.branch,
      "admitted_branch" => candidate.admitted_branch,
      "admitted_commit" => candidate.admitted_commit,
      "harness_home" => candidate.harness_home,
      "credential_bindings" => candidate.bindings,
      "started_at" => candidate.started_at,
      "status" => status,
      "candidate_commit" => commit
    }

    path = candidate.owner_path
    bytes = Jason.encode_to_iodata!(record, pretty: true)

    with :ok <- mkdir_p(Path.dirname(path)) do
      if modes == [:exclusive],
        do: exclusive_owner(path, bytes),
        else: replace_owner(path, bytes)
    end
  end

  defp exclusive_owner(path, bytes) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        IO.binwrite(io, bytes)
        File.close(io)

      {:error, reason} ->
        {:error, "could not create Candidate owner record #{path}: #{inspect(reason)}"}
    end
  end

  defp replace_owner(path, bytes) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, bytes),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "could not update Candidate owner record #{path}: #{inspect(reason)}"}
    end
  end

  @doc "The tracking-record `candidate` block."
  @spec record_block(candidate(), String.t(), String.t() | nil) :: map()
  def record_block(candidate, disposition, commit \\ nil) do
    %{
      "worktree_path" => candidate.path,
      "branch" => candidate.branch,
      "admitted_branch" => candidate.admitted_branch,
      "admitted_commit" => candidate.admitted_commit,
      "control_root" => candidate.control,
      "harness_home" => candidate.harness_home,
      "owner_record" => candidate.owner_path,
      "credential_bindings" => candidate.bindings,
      "disposition" => disposition,
      "candidate_commit" => commit
    }
  end

  @doc "The stop-message description of a kept Candidate."
  @spec retained_description(candidate(), keyword()) :: String.t()
  def retained_description(candidate, opts \\ []) do
    flag = if Keyword.get(opts, :discard_accepted, false), do: " --discard-accepted", else: ""

    "Candidate kept: slug #{candidate.slug}, build id #{candidate.build_id}, worktree #{candidate.path}, " <>
      "branch #{candidate.branch}, harness home #{candidate.harness_home}; remove it with " <>
      "`mix kogen.candidates.remove #{candidate.build_id}#{flag}`"
  end

  @doc "Removes the per-Build temp dir; called at every Build exit."
  @spec remove_temp_dir(candidate()) :: :ok
  def remove_temp_dir(candidate) do
    File.rm_rf(candidate.tmp_dir)
    :ok
  end

  @doc """
  Copies the harness home's `raw-log/` into the controller's own
  `KOGEN_RAW_LOG_DIR`, when one is set. Called at every Build exit.
  """
  @spec copy_raw_log(candidate()) :: :ok
  def copy_raw_log(candidate) do
    source = Path.join(candidate.harness_home, "raw-log")

    case System.get_env("KOGEN_RAW_LOG_DIR") do
      dir when is_binary(dir) and dir != "" ->
        if File.dir?(source) do
          File.mkdir_p(dir)
          File.cp_r(source, dir)
        end

        :ok

      _ ->
        :ok
    end
  end

  # -- Publication -----------------------------------------------------------

  @doc """
  Fast-forwards the admitted branch in control to the Candidate `commit`.

  Requires control still attached to the admitted branch, the branch still at
  the admitted commit, a clean control checkout and no blinding index flags;
  otherwise returns `{:refused, reason, current_commit}` with control unchanged.
  The fast-forward (`git merge --ff-only`) updates control's index and working
  tree; control HEAD, tree and clean status are asserted afterwards.
  """
  @spec fast_forward(candidate(), String.t()) ::
          :ok | {:refused, String.t(), String.t() | nil} | {:error, String.t()}
  def fast_forward(candidate, commit) do
    control = candidate.control
    current = branch_commit(control, candidate.admitted_branch)

    with :ok <- attached_to(control, candidate.admitted_branch, current),
         :ok <- unmoved(candidate, current),
         :ok <- clean_control(control, current),
         :ok <- no_index_flags(control, current),
         :ok <- merge_ff_only(control, commit, current) do
      assert_published(control, commit)
    end
  end

  defp attached_to(control, branch, current) do
    case git(control, ["symbolic-ref", "--short", "-q", "HEAD"]) do
      {:ok, ^branch} -> :ok
      {:ok, other} -> {:refused, "control checkout is on branch #{other}, not #{branch}", current}
      {:error, _} -> {:refused, "control checkout HEAD is detached, not on #{branch}", current}
    end
  end

  defp unmoved(candidate, current) do
    if current == candidate.admitted_commit,
      do: :ok,
      else:
        {:refused,
         "branch #{candidate.admitted_branch} moved from #{candidate.admitted_commit} to #{current || "(missing)"}",
         current}
  end

  defp clean_control(control, current) do
    case git(control, ["--no-optional-locks", "status", "--porcelain"]) do
      {:ok, ""} ->
        :ok

      {:ok, status} ->
        {:refused, "control checkout is not clean (git status --porcelain: #{status})", current}

      {:error, output} ->
        {:refused, "could not read control status: #{output}", current}
    end
  end

  defp no_index_flags(control, current) do
    case Kogen.Git.reject_candidate_blinding_index_flags(control) do
      :ok -> :ok
      {:error, reason} -> {:refused, "control index: #{reason}", current}
    end
  end

  defp merge_ff_only(control, commit, current) do
    case git(control, ["merge", "--ff-only", "--no-edit", "--quiet", commit]) do
      {:ok, _} ->
        :ok

      {:error, output} ->
        case branch_commit(control, "HEAD") do
          ^current -> {:refused, "fast-forward failed: #{output}", current}
          moved -> {:error, "fast-forward failed after moving HEAD to #{moved}: #{output}"}
        end
    end
  end

  defp assert_published(control, commit) do
    with {:ok, ^commit} <- git(control, ["rev-parse", "HEAD"]),
         {:ok, tree} <- git(control, ["rev-parse", commit <> "^{tree}"]),
         {:ok, ^tree} <- git(control, ["rev-parse", "HEAD^{tree}"]),
         {:ok, ""} <- git(control, ["--no-optional-locks", "status", "--porcelain"]) do
      :ok
    else
      other ->
        {:error,
         "control checkout does not match the published commit #{commit} after fast-forward: #{inspect(other)}"}
    end
  end

  @doc """
  Removes a published Candidate: `git worktree remove` without `--force`, then
  `git branch -d`, then its owner record. The harness home is kept. Refusal
  keeps the Candidate.
  """
  @spec remove_published(candidate()) :: :ok | {:error, String.t()}
  def remove_published(candidate) do
    with {:ok, _} <- git(candidate.control, ["worktree", "remove", candidate.path]),
         {:ok, _} <- git(candidate.control, ["branch", "-d", candidate.branch]) do
      File.rm(candidate.owner_path)
      :ok
    else
      {:error, output} -> {:error, output}
    end
  end

  @doc "The commit an admitted branch (or `HEAD`) points at in `control`, or nil."
  @spec branch_commit(Path.t(), String.t()) :: String.t() | nil
  def branch_commit(control, rev) do
    ref = if rev == "HEAD", do: "HEAD", else: "refs/heads/" <> rev

    case git(control, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
      {:ok, sha} -> sha
      {:error, _} -> nil
    end
  end

  # -- Candidate commands ----------------------------------------------------

  @doc """
  This project's owner records, as `{:ok, record}` or `{:error, path, reason}`,
  with the effective status: a `running` record counts only while this
  project's build lock is held by a live Build with that build id.
  """
  @spec list(Path.t()) :: [{:ok, map()} | {:error, Path.t(), String.t()}]
  def list(control) do
    control = Path.expand(control)

    control
    |> owner_records()
    |> Enum.map(fn
      {:ok, record} -> {:ok, Map.put(record, "status", effective_status(control, record))}
      error -> error
    end)
  end

  defp owner_records(control) do
    directory = Path.join(project_dir(control), "candidates")

    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.map(&read_owner(Path.join(directory, &1)))

      {:error, _} ->
        []
    end
  end

  defp read_owner(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"schema_version" => @schema_version} = record} <- Jason.decode(bytes),
         true <- Path.basename(path, ".json") == record["build_id"],
         true <- Enum.all?(~w(control_root worktree_path branch status), &is_binary(record[&1])) do
      {:ok, record}
    else
      _ -> {:error, path, "malformed or mismatched owner record"}
    end
  end

  defp effective_status(control, %{"status" => "running"} = record) do
    if live_lock?(control, record["build_id"]), do: "running", else: "stopped: interrupted"
  end

  defp effective_status(_control, record), do: record["status"]

  @doc """
  True when this project's build lock is held by a live Build with `build_id`.
  The lock holds `{"pid": <os pid>, "build_id": <id>}`.
  """
  @spec live_lock?(Path.t(), String.t()) :: boolean()
  def live_lock?(control, build_id) do
    with {:ok, bytes} <- File.read(lock_path(control)),
         {:ok, %{"pid" => pid, "build_id" => ^build_id}} when is_integer(pid) <-
           Jason.decode(bytes) do
      match?(
        {_, 0},
        System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
      )
    else
      _ -> false
    end
  end

  @doc """
  Removes one of this project's Candidates on the Shaper's request: its
  worktree (forced), branch (`-D`), harness home and owner record. Refuses a
  running Candidate, a Candidate whose commit is not reachable from its
  admitted branch without `discard_accepted`, an id that is not this
  project's, and a path that is not under this project's directory, does not
  match its owner record or is not registered in this repository's worktree
  list. Returns the lines naming what it removed.
  """
  @spec remove(Path.t(), String.t(), keyword()) :: {:ok, [String.t()]} | {:error, String.t()}
  def remove(control, build_id, opts \\ []) do
    control = Path.expand(control)
    discard? = Keyword.get(opts, :discard_accepted, false)

    with :ok <- safe_id(build_id),
         path = owner_path(control, build_id),
         {:ok, record} <- owned_record(path, control, build_id),
         :ok <- not_running(control, record),
         :ok <- owned_path(control, record),
         :ok <- registered(control, record),
         :ok <- reachable(control, record, discard?) do
      delete(control, record, path)
    end
  end

  defp safe_id(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id),
      do: :ok,
      else: {:error, "refused: #{inspect(id)} is not a Candidate build id"}
  end

  defp owned_record(path, control, build_id) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        case read_owner(path) do
          {:ok, %{"control_root" => ^control} = record} ->
            {:ok, record}

          {:ok, record} ->
            {:error,
             "refused: Candidate #{build_id} belongs to another control checkout (#{record["control_root"]})"}

          {:error, _path, reason} ->
            {:error, "refused: Candidate #{build_id} has a #{reason}: #{path}"}
        end

      _ ->
        {:error, "refused: no Candidate #{build_id} for this project"}
    end
  end

  defp not_running(control, record) do
    if effective_status(control, record) == "running",
      do:
        {:error,
         "refused: Candidate #{record["build_id"]} is running (its Build holds the build lock)"},
      else: :ok
  end

  defp owned_path(control, record) do
    base = project_dir(control)
    path = record["worktree_path"]
    expected = Path.join(base, "#{record["slug"]}-#{record["build_id"]}")
    home = Path.join([base, "harness", record["build_id"]])

    cond do
      Path.expand(path) != path or not String.starts_with?(path, base <> "/") ->
        {:error,
         "refused: Candidate #{record["build_id"]} path #{path} is not under this project's workspace directory #{base}"}

      path != expected or record["branch"] != branch(record["slug"], record["build_id"]) ->
        {:error,
         "refused: Candidate #{record["build_id"]} path or branch does not match its owner record"}

      record["harness_home"] not in [nil, home] ->
        {:error,
         "refused: Candidate #{record["build_id"]} harness home does not match its owner record"}

      symlinked?(base, path) ->
        {:error, "refused: Candidate #{record["build_id"]} path #{path} traverses a symlink"}

      true ->
        :ok
    end
  end

  defp symlinked?(base, path) do
    base
    |> Path.split()
    |> length()
    |> then(&Enum.drop(Path.split(path), &1))
    |> Enum.scan(base, &Path.join(&2, &1))
    |> Enum.any?(&match?({:ok, %{type: :symlink}}, File.lstat(&1)))
  end

  defp registered(control, record) do
    case git(control, ["worktree", "list", "--porcelain"]) do
      {:ok, listing} ->
        if Enum.any?(worktree_entries(listing), &registered_entry?(&1, record)),
          do: :ok,
          else:
            {:error,
             "refused: Candidate #{record["build_id"]} worktree #{record["worktree_path"]} on #{record["branch"]} is not registered in this repository's git worktree list"}

      {:error, output} ->
        {:error, "refused: could not list worktrees: #{output}"}
    end
  end

  defp worktree_entries(listing) do
    listing
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      block |> String.split("\n", trim: true) |> Map.new(&worktree_field/1)
    end)
  end

  defp worktree_field(line) do
    case String.split(line, " ", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, true}
    end
  end

  defp registered_entry?(entry, record) do
    entry["worktree"] == record["worktree_path"] and
      entry["branch"] == "refs/heads/" <> record["branch"]
  end

  defp reachable(_control, _record, true), do: :ok

  defp reachable(control, record, false) do
    tip = branch_commit(control, record["branch"])
    admitted = "refs/heads/" <> record["admitted_branch"]
    holds_commit? = tip != nil and tip != record["admitted_commit"]

    reachable? =
      not holds_commit? or
        match?({:ok, _}, git(control, ["merge-base", "--is-ancestor", tip, admitted]))

    if reachable?,
      do: :ok,
      else:
        {:error,
         "refused: Candidate #{record["build_id"]} holds commit #{tip} that is not reachable from #{record["admitted_branch"]}; pass --discard-accepted to delete it"}
  end

  defp delete(control, record, owner) do
    path = record["worktree_path"]
    home = Path.join([project_dir(control), "harness", record["build_id"]])

    with {:ok, _} <- git(control, ["worktree", "remove", "--force", path]),
         {:ok, _} <- git(control, ["branch", "-D", record["branch"]]) do
      home_line =
        if File.exists?(home) do
          File.rm_rf!(home)
          ["removed harness home #{home}"]
        else
          []
        end

      File.rm(owner)

      {:ok,
       ["removed worktree #{path}", "removed branch #{record["branch"]}"] ++
         home_line ++ ["removed owner record #{owner}"]}
    else
      {:error, output} ->
        {:error, "refused: could not remove Candidate #{record["build_id"]}: #{output}"}
    end
  end

  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
