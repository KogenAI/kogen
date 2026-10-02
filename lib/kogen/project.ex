defmodule Kogen.Project do
  @moduledoc "Loads and validates `.kogen/project.yaml` for an explicit checkout root."
  use Boundary, deps: [Kogen.Contracts], exports: []

  alias Kogen.Contracts.Project

  @type load_error :: %{line: pos_integer() | nil, message: String.t()}

  @spec load(Path.t()) :: {:ok, Project.t()} | {:error, [load_error()]}
  def load(checkout_root), do: Kogen.Project.Loader.load(checkout_root)
end
