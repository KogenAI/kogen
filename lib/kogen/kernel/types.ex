defmodule Kogen.Kernel.Types.ApprovalPreview do
  @moduledoc false

  @enforce_keys [:approval, :intent, :project_root, :origin, :git_env]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          approval: Kogen.State.Approval.t(),
          intent: Kogen.Contracts.Intent.t(),
          project_root: Path.t(),
          origin: Path.t(),
          git_env: %{String.t() => String.t()}
        }
end

defmodule Kogen.Kernel.Types.IntentStatus do
  @moduledoc false

  @enforce_keys [:slug, :status, :run_id, :landed_sha]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          status: Kogen.State.status(),
          run_id: String.t() | nil,
          landed_sha: String.t() | nil
        }
end

defmodule Kogen.Kernel.CLI.Args do
  @moduledoc false

  defstruct [
    :command,
    :project,
    :origin,
    :base,
    :model,
    :effort,
    :by,
    positionals: [],
    yes: false,
    json: false
  ]

  @type t :: %__MODULE__{
          command: atom(),
          project: Path.t() | nil,
          origin: Path.t() | nil,
          base: String.t() | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          by: String.t() | nil,
          positionals: [String.t()],
          yes: boolean(),
          json: boolean()
        }
end
