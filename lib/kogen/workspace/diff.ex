defmodule Kogen.Workspace.Diff do
  @moduledoc false

  alias Kogen.Workspace.Checkout
  alias Kogen.Workspace.Git

  @spec diff(Path.t(), String.t(), %{String.t() => String.t()}) ::
          {:ok, binary()} | {:error, term()}
  def diff(path, base_sha, git_env) do
    if Git.valid_worktree_path?(path) and Checkout.valid_sha?(base_sha) do
      Checkout.with_private_index(path, git_env, &tree_diff(path, base_sha, &1))
    else
      {:error, :invalid_path}
    end
  end

  defp tree_diff(path, base_sha, index_env) do
    with {:ok, _output} <- git_ok(path, ["read-tree", "HEAD"], index_env),
         {:ok, _output} <- git_ok(path, ["add", "-A", "--", "."], index_env),
         {:ok, tree} <- git_ok(path, ["write-tree"], index_env) do
      # Git.run reads the full log; keep the patch out of the bounded Proc output tail.
      git_ok(
        path,
        ["diff", "--no-ext-diff", "--no-textconv", "--no-color", base_sha, Git.trim_line(tree)],
        index_env
      )
    end
  end

  defp git_ok(path, argv, git_env), do: Git.status_ok(Git.run(path, argv, git_env), :git_failed)
end
