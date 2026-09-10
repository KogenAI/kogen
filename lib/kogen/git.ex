defmodule Kogen.Git do
  @moduledoc """
  The Candidate tree identity, ordinary Git publication, and the
  post-Commit mutation assertions. Never depends on `Kogen.Harness`: this
  module must be able to compute and publish a Candidate whether or not any
  provider was ever involved.

  Every command is run through plain `git`/`sh`, never assuming `.git` is a
  directory (a linked worktree's `.git` is a file; ordinary `git` commands
  already resolve this correctly on their own).
  """
  use Boundary, deps: []

  @doc "Raw `git status --porcelain` output."
  def status_porcelain! do
    {out, 0} = System.cmd("git", ["--no-optional-locks", "status", "--porcelain"])
    out
  end

  @doc "True when the worktree has no staged, unstaged, or untracked changes."
  def clean_worktree? do
    status_porcelain!() == ""
  end

  @doc "The attached branch name, or `{:error, reason}` on a detached HEAD."
  def current_branch do
    case System.cmd("git", ["symbolic-ref", "--short", "-q", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _code} -> {:error, "detached HEAD"}
    end
  end

  @doc """
  The Candidate id: the tree hash from `git write-tree` on a private copy of
  the real index, followed by `git add -A`. This includes deliberately staged
  ignored files while still capturing ordinary untracked files and honoring
  `.gitignore`, and never touches the real index.
  """
  @spec candidate_id() :: {:ok, String.t()} | {:error, String.t()}
  def candidate_id do
    with :ok <- reject_candidate_blinding_index_flags() do
      tmp_dir = tmp_directory!("index")
      tmp_index = Path.join(tmp_dir, "index")
      env = [{"GIT_INDEX_FILE", tmp_index}]

      try do
        with {index_path, 0} <-
               System.cmd("git", ["rev-parse", "--git-path", "index"], stderr_to_stdout: true),
             :ok <- File.cp(String.trim(index_path), tmp_index),
             {_out, 0} <- System.cmd("git", ["add", "-A"], env: env, stderr_to_stdout: true),
             {tree, 0} <- System.cmd("git", ["write-tree"], env: env, stderr_to_stdout: true) do
          {:ok, String.trim(tree)}
        else
          {:error, reason} -> {:error, "could not copy Git index: #{:file.format_error(reason)}"}
          {out, code} when is_binary(out) and is_integer(code) -> {:error, String.trim(out)}
        end
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  @doc "Stages the final tree and confirms only Kogen lifecycle paths differ from the Candidate."
  @spec stage_and_verify_candidate(String.t(), String.t() | [String.t()]) ::
          :ok | {:error, term()}
  def stage_and_verify_candidate(candidate_tree, allowed_prefixes) do
    with :ok <- reject_candidate_blinding_index_flags(),
         {_out, 0} <- System.cmd("git", ["add", "-A"], stderr_to_stdout: true),
         {staged_tree, 0} <- System.cmd("git", ["write-tree"], stderr_to_stdout: true) do
      assert_tree_diff_only(candidate_tree, String.trim(staged_tree), allowed_prefixes)
    else
      {:error, _reason} = error -> error
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  @doc "Confirms the current staged tree exactly matches the expected Candidate tree."
  @spec assert_staged_tree(String.t()) :: :ok | {:error, String.t()}
  def assert_staged_tree(expected_tree) do
    with :ok <- reject_candidate_blinding_index_flags(),
         {staged_tree, 0} <- System.cmd("git", ["write-tree"], stderr_to_stdout: true) do
      assert_expected_tree("staged", expected_tree, String.trim(staged_tree))
    else
      {:error, _reason} = error -> error
      {out, _code} -> {:error, "could not read staged Git tree: #{String.trim(out)}"}
    end
  end

  @doc "Confirms the current HEAD tree exactly matches the expected Candidate tree."
  @spec assert_head_tree(String.t()) :: :ok | {:error, String.t()}
  def assert_head_tree(expected_tree) do
    with :ok <- reject_candidate_blinding_index_flags(),
         {head_tree, 0} <- System.cmd("git", ["rev-parse", "HEAD^{tree}"], stderr_to_stdout: true) do
      assert_expected_tree("HEAD", expected_tree, String.trim(head_tree))
    else
      {:error, _reason} = error -> error
      {out, _code} -> {:error, "could not read HEAD Git tree: #{String.trim(out)}"}
    end
  end

  @doc """
  Ordinary `git add -A` plus `git commit -F` on the current branch. `body`
  and `trailers` (a list of `{key, value}` pairs) are rendered as a
  conventional trailing paragraph so `git interpret-trailers --parse` finds
  them. Returns `{:ok, head_sha}` or `{:error, reason}`.
  """
  @spec commit(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, String.t()}
  def commit(subject, body, trailers) do
    with :ok <- reject_candidate_blinding_index_flags() do
      case System.cmd("git", ["add", "-A"], stderr_to_stdout: true) do
        {_out, 0} ->
          commit_message!(render_commit_message(subject, body, trailers))

        {out, _code} ->
          {:error, String.trim(out)}
      end
    end
  end

  @doc """
  Commits an index already staged and verified by `stage_and_verify_candidate/2`.

  The message contains only the subject and its trailers; publication evidence
  belongs in the Complete Intent rather than a generated commit body.
  """
  @spec commit_staged(String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, String.t()}
  def commit_staged(subject, trailers) do
    with :ok <- reject_candidate_blinding_index_flags() do
      trailer_lines = Enum.map_join(trailers, "\n", fn {k, v} -> "#{k}: #{v}" end)
      message = Enum.join([subject, trailer_lines], "\n\n")
      tmp_dir = tmp_directory!("commit-msg")
      msg_file = Path.join(tmp_dir, "message")

      try do
        with :ok <- File.write(msg_file, message),
             result <- System.cmd("git", ["commit", "-F", msg_file], stderr_to_stdout: true) do
          case result do
            {_out, 0} -> head_sha()
            {out, _code} -> {:error, String.trim(out)}
          end
        else
          {:error, reason} ->
            {:error, "could not write commit message: #{:file.format_error(reason)}"}
        end
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  @doc "The current `HEAD` commit sha."
  @spec head_sha() :: {:ok, String.t()} | {:error, String.t()}
  def head_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _code} -> {:error, String.trim(out)}
    end
  end

  @doc """
  Resets the index back to `HEAD` (a plain, ordinary `git reset`) without
  touching the working tree. Used to undo a `git add -A` whose subsequent
  `git commit` failed, so a retried Build sees the same clean-index state
  as before the failed attempt.
  """
  @spec unstage_all() :: :ok
  def unstage_all do
    System.cmd("git", ["reset"], stderr_to_stdout: true)
    :ok
  end

  @doc """
  Asserts that every path differing between `candidate_tree` and `HEAD`
  starts with one of `allowed_prefixes` (the Intent lifecycle directories). Any
  other differing path means the Commit's tree does not match the reviewed
  Candidate everywhere else, and the Build must abort.
  """
  @spec assert_commit_diff_only(String.t(), String.t() | [String.t()]) ::
          :ok | {:error, {:paths_outside_allowed, [String.t()]}}
  def assert_commit_diff_only(candidate_tree, allowed_prefixes) do
    assert_tree_diff_only(candidate_tree, "HEAD", allowed_prefixes)
  end

  defp assert_tree_diff_only(left, right, allowed_prefixes) do
    case System.cmd("git", ["diff", "--name-only", "-z", left, right], stderr_to_stdout: true) do
      {out, 0} ->
        bad =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.reject(&allowed_path?(&1, List.wrap(allowed_prefixes)))

        if bad == [], do: :ok, else: {:error, {:paths_outside_allowed, bad}}

      {out, _code} ->
        {:error, {:git_diff_failed, String.trim(out)}}
    end
  end

  defp allowed_path?(path, prefixes), do: Enum.any?(prefixes, &String.starts_with?(path, &1))

  defp assert_expected_tree(_location, expected_tree, expected_tree), do: :ok

  defp assert_expected_tree(location, expected_tree, actual_tree) do
    {:error,
     "#{location} Git tree differs from expected Candidate (#{expected_tree} -> #{actual_tree})"}
  end

  defp commit_message!(message) do
    tmp_dir = tmp_directory!("commit-msg")
    msg_file = Path.join(tmp_dir, "message")

    try do
      File.write!(msg_file, message)

      case System.cmd("git", ["commit", "-F", msg_file], stderr_to_stdout: true) do
        {_out, 0} -> head_sha()
        {out, _code} -> {:error, String.trim(out)}
      end
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp render_commit_message(subject, body, trailers) do
    trailer_lines = Enum.map_join(trailers, "\n", fn {k, v} -> "#{k}: #{v}" end)
    Enum.join([subject, "", body, "", trailer_lines], "\n")
  end

  @doc """
  Refuses Candidate-sensitive work when the real index has assume-unchanged or
  skip-worktree entries, without clearing those flags or changing the index.
  """
  @spec reject_candidate_blinding_index_flags() :: :ok | {:error, String.t()}
  def reject_candidate_blinding_index_flags do
    case System.cmd("git", ["ls-files", "-v", "-z"], stderr_to_stdout: true) do
      {out, 0} ->
        flagged =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.filter(&candidate_blinding_index_flag?/1)
          |> Enum.map(&format_candidate_blinding_index_flag/1)

        if flagged == [] do
          :ok
        else
          {:error,
           "Candidate identity refused: Git index contains assume-unchanged or skip-worktree flags: " <>
             Enum.join(flagged, ", ")}
        end

      {out, _code} ->
        {:error, "could not inspect Git index flags: #{String.trim(out)}"}
    end
  end

  defp candidate_blinding_index_flag?(<<flag, ?\s, _path::binary>>)
       when flag in ?a..?z or flag == ?S,
       do: true

  defp candidate_blinding_index_flag?(_entry), do: false

  defp format_candidate_blinding_index_flag(<<flag, ?\s, path::binary>>) do
    kind = if flag == ?S, do: "skip-worktree", else: "assume-unchanged"
    "#{kind}: #{path}"
  end

  # `unique_integer/1` is unique only inside this BEAM VM. Put every temporary
  # Git artifact in an atomically-created, PID-qualified private directory so
  # separate Kogen processes cannot select the same path.
  defp tmp_directory!(label), do: create_tmp_directory!(label, 0)

  defp create_tmp_directory!(label, attempts) when attempts < 10 do
    name =
      "kogen-#{label}-#{System.pid()}-#{:erlang.unique_integer([:positive, :monotonic])}"

    path = Path.join(System.tmp_dir!(), name)

    case File.mkdir(path) do
      :ok ->
        File.chmod!(path, 0o700)
        path

      {:error, :eexist} ->
        create_tmp_directory!(label, attempts + 1)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create private temporary directory", path: path
    end
  end

  defp create_tmp_directory!(label, _attempts) do
    raise "could not create a unique private temporary directory for #{label}"
  end
end
