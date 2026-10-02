defmodule Kogen.State.Event do
  @moduledoc "A decoded run-journal event used by Kernel reports."

  @enforce_keys [:event]
  defstruct [
    :event,
    :stage,
    :class,
    :reason,
    :detail,
    :status,
    :approval_commit,
    :base_sha,
    :ledger,
    :receipts,
    :model,
    :effort,
    :tokens
  ]

  @type t :: %__MODULE__{
          event: String.t(),
          stage: String.t() | nil,
          class: String.t() | nil,
          reason: String.t() | nil,
          detail: String.t() | nil,
          status: term(),
          approval_commit: String.t() | nil,
          base_sha: String.t() | nil,
          ledger: term(),
          receipts: term(),
          model: String.t() | nil,
          effort: String.t() | nil,
          tokens: term()
        }
end
