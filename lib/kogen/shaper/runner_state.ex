defmodule Kogen.Shaper.Runner.State do
  @moduledoc false

  @enforce_keys [:request, :project, :opts]
  defstruct [
    :request,
    :project,
    :opts,
    history: [],
    failure_text: nil,
    turn_offset: 0,
    repairs: 0,
    calls: []
  ]

  @type t :: %__MODULE__{
          request: Kogen.Shaper.Request.t(),
          project: Kogen.Contracts.Project.t(),
          opts: Kogen.Harness.Opts.t(),
          history: [map()],
          failure_text: String.t() | nil,
          turn_offset: non_neg_integer(),
          repairs: non_neg_integer(),
          calls: [Kogen.Harness.ShapeCall.t()]
        }
end
