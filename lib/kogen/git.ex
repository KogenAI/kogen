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
    {out, 0} = System.cmd("git", ["status", "--porcelain"])
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

  @doc "Stages the final tree and confirms only Kogen lifecycle paths differ from the Candidate."
  @spec stage_and_verify_candidate(String.t(), String.t() | [String.t()]) ::
          :ok | {:error, term()}
  def stage_and_verify_candidate(candidate_tree, allowed_prefixes) do
    with {_out, 0} <- System.cmd("git", ["add", "-A"], stderr_to_stdout: true),
         {staged_tree, 0} <- System.cmd("git", ["write-tree"], stderr_to_stdout: true) do
      assert_tree_diff_only(candidate_tree, String.trim(staged_tree), allowed_prefixes)
    else
      {out, _code} -> {:error, String.trim(out)}
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
    case System.cmd("git", ["add", "-A"], stderr_to_stdout: true) do
      {_out, 0} ->
        trailer_lines = Enum.map_join(trailers, "\n", fn {k, v} -> "#{k}: #{v}" end)
        message = Enum.join([subject, "", body, "", trailer_lines], "\n")
        tmp_dir = tmp_directory!("commit-msg")
        msg_file = Path.join(tmp_dir, "message")

        try do
          File.write!(msg_file, message)
          result = System.cmd("git", ["commit", "-F", msg_file], stderr_to_stdout: true)

          case result do
            {_out, 0} -> head_sha()
            {out, _code} -> {:error, String.trim(out)}
          end
        after
          File.rm_rf(tmp_dir)
        end

      {out, _code} ->
        {:error, String.trim(out)}
    end
  end

  @doc "Commits an index already staged and verified by `stage_and_verify_candidate/2`."
  @spec commit_staged(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | {:error, String.t()}
  def commit_staged(subject, body, trailers) do
    trailer_lines = Enum.map_join(trailers, "\n", fn {k, v} -> "#{k}: #{v}" end)
    message = Enum.join([subject, "", body, "", trailer_lines], "\n")
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
