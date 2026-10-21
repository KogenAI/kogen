defmodule Kogen.Git do
  @moduledoc "Read-mostly Git plumbing. Commits go through `Kogen.Bridge.exec/3` so hooks and signing run as the user configured them."
  alias Kogen.Error

  def run(root, args, opts \\ []) do
    opts =
      if Process.get(:kogen_read_only_git),
        do: Keyword.put(opts, :env, [{"GIT_OPTIONAL_LOCKS", "0"}]),
        else: opts

    args =
      if Process.get(:kogen_read_only_git), do: ["-c", "core.fsmonitor=false" | args], else: args

    System.cmd("git", args, [cd: root, stderr_to_stdout: true] ++ opts)
  end

  @doc "Runs a Git command that must succeed; its output."
  def ok!(root, args, opts \\ []) do
    case run(root, args, opts) do
      {out, 0} -> out
      {out, n} -> raise "git #{Enum.join(args, " ")} failed (status #{n}): #{String.trim(out)}"
    end
  end

  @doc """
  The repository root containing `dir`, expressed through the caller's own path when it is a
  symlinked form of the real one, or nil outside a work tree.
  """
  def root(dir) do
    case run(dir, ["rev-parse", "--show-toplevel"]) do
      {top, 0} -> logical_root(Path.expand(dir), String.trim(top))
      _ -> nil
    end
  end

  @doc "The repository root containing `dir`, or `environment/not_a_git_repo` (SET-1)."
  def root!(dir),
    do:
      root(dir) ||
        Kogen.Error.raise!("environment", "not_a_git_repo", "#{dir}; run git init first", 3)

  defp logical_root(dir, top) do
    cond do
      real(dir) == real(top) -> dir
      dir == "/" -> top
      true -> logical_root(Path.dirname(dir), top)
    end
  end

  defp real(path) do
    case System.cmd("pwd", ["-P"], cd: path) do
      {p, 0} -> String.trim(p)
      _ -> path
    end
  end

  def head(root) do
    case run(root, ["rev-parse", "--verify", "-q", "HEAD"]) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  @doc "`Name <email>` from the user's Git configuration, or nil when user.name or user.email is unset."
  def identity(root) do
    with {name, 0} when name != "\n" <- run(root, ["config", "--get", "user.name"]),
         {email, 0} when email != "\n" <- run(root, ["config", "--get", "user.email"]),
         {ident, 0} <- run(root, ["var", "GIT_AUTHOR_IDENT"]),
         [_, who] <- Regex.run(~r/^(.*>) \d+ [+-]\d{4}$/, String.trim(ident)) do
      who
    else
      _ -> nil
    end
  end

  def identity!(root) do
    identity(root) ||
      Error.raise!(
        "environment",
        "git_identity_missing",
        "configure git user.name and user.email",
        3
      )
  end

  @doc "Paths with uncommitted changes (staged, unstaged or untracked and not ignored), relative to the root."
  def changed_paths(root, pathspec \\ []) do
    ok!(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--"] ++ pathspec)
    |> String.split("\0", trim: true)
    |> parse_status([])
  end

  defp parse_status([], acc), do: Enum.reverse(acc)
  # A rename changes both paths; a copy leaves its source untouched.
  defp parse_status([<<x, y, " ", path::binary>>, from | rest], acc)
       when x == ?R or y == ?R,
       do: parse_status(rest, [from, path | acc])

  defp parse_status([<<x, y, " ", path::binary>>, _from | rest], acc)
       when x == ?C or y == ?C,
       do: parse_status(rest, [path | acc])

  defp parse_status([<<_x, _y, " ", path::binary>> | rest], acc),
    do: parse_status(rest, [path | acc])

  @doc "The content of `path` in `rev`, or nil."
  def show(root, rev, path) do
    case run(root, ["show", "#{rev}:#{path}"]) do
      {out, 0} -> out
      _ -> nil
    end
  end

  @doc "The operation in progress (merge, rebase, cherry-pick, revert), or nil (AUT-5)."
  def operation_in_progress(root) do
    git_dir = root |> ok!(["rev-parse", "--absolute-git-dir"]) |> String.trim()

    Enum.find_value(
      [
        {"MERGE_HEAD", "merge"},
        {"rebase-merge", "rebase"},
        {"rebase-apply", "rebase"},
        {"CHERRY_PICK_HEAD", "cherry-pick"},
        {"REVERT_HEAD", "revert"}
      ],
      fn {file, op} -> if File.exists?(Path.join(git_dir, file)), do: op end
    )
  end
end
