defmodule Kogen.Snapshot do
  @moduledoc """
  The candidate (VER-10) as a Git tree: every tracked file and every untracked file not ignored,
  with content and mode, except other uncommitted Intents' whole folders. It is built in a temporary
  index seeded from the start HEAD, so the user's index is untouched until the commit (GIT-4)
  and nothing staged before the Build slips in.
  """
  alias Kogen.Git

  @doc "The tree id of the candidate, built on the start HEAD's tree."
  def tree(root, start, excluded) do
    index = Kogen.tmp_path("kogen-index")

    try do
      env = [{"GIT_INDEX_FILE", index}]
      excludes = Enum.map(excluded, &":(exclude,literal)#{&1}")
      Git.ok!(root, ["read-tree", start], env: env)
      Git.ok!(root, ["add", "-A", "--", "." | excludes], env: env)
      root |> Git.ok!(["write-tree"], env: env) |> String.trim()
    after
      File.rm(index)
    end
  end

  @doc "Paths that differ between two trees."
  def changed(root, a, b) do
    root
    |> Git.ok!(["diff", "--name-only", "-z", "--no-renames", a, b])
    |> String.split("\0", trim: true)
  end

  @doc "The unified diff between two trees."
  def diff(root, a, b), do: Git.ok!(root, ["diff", "--no-color", "--no-ext-diff", a, b])
end
