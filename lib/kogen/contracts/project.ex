defmodule Kogen.Contracts.Project do
  @moduledoc "A project's root, checks, protected paths, and domain map."

  alias Kogen.Contracts.CheckSpec

  @enforce_keys [:root, :name, :checks, :setup, :fix, :diagnose, :protected_paths, :domains]
  defstruct @enforce_keys ++ [env: %{}]

  @type diagnostic :: %{required(:glob) => String.t(), required(:argv) => [String.t()]}
  @type t :: %__MODULE__{
          root: Path.t(),
          name: String.t(),
          checks: [CheckSpec.t()],
          setup: [CheckSpec.t()],
          fix: [CheckSpec.t()],
          diagnose: [diagnostic()],
          protected_paths: [String.t()],
          domains: %{optional(String.t()) => [String.t()]},
          env: %{optional(String.t()) => String.t()}
        }
end
