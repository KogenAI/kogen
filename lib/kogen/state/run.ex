defmodule Kogen.State.Run do
  @moduledoc "The persisted identity and lifecycle of one Build run."

  defmodule Landing do
    @moduledoc false

    @enforce_keys [:approval_commit, :run_id, :expected_parent, :final_tree, :candidate_commit]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            approval_commit: String.t(),
            run_id: String.t(),
            expected_parent: String.t(),
            final_tree: String.t(),
            candidate_commit: String.t()
          }
  end

  @enforce_keys [
    :id,
    :dir,
    :slug,
    :intent_sha256,
    :target_branch,
    :approval_commit,
    :status,
    :landing
  ]
  defstruct @enforce_keys ++ [owner_os_pid: nil]

  @type status :: :running | :landed | :failed | :parked
  @type t :: %__MODULE__{
          id: String.t(),
          dir: Path.t(),
          slug: String.t(),
          intent_sha256: String.t(),
          target_branch: String.t(),
          approval_commit: String.t() | nil,
          status: status(),
          landing: Landing.t() | nil,
          owner_os_pid: pos_integer() | nil
        }
end
