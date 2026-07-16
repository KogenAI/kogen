defmodule CodegenTestHarness.InfraAbort do
  @moduledoc """
  Raised when a check fails for a reason **no developer edit could fix** —
  an environment or repo-state problem (poisoned DB state, unsatisfiable
  scan, missing runtime dependency, inherited orientation-doc drift), not
  a code defect.

  This is the generalized form of `LoopGate`'s pre-existing
  `static_render_deps_preflight!/1` raise (a missing render-check
  dependency is "an infra abort, not a gate verdict"): the same posture,
  widened from one preflight check to any check the loop runs.

  Raising this (instead of re-invoking a developer/curator role, or
  laundering the fault into a `:failed` gate verdict) stops the loop from
  spending a rework cycle — and its $ budget — on a fault the next
  developer attempt cannot possibly resolve. See pitch
  `no-developer-rework-on-unfixable-fault`.
  """

  defexception [:message, :reason]

  @impl true
  def exception(reason) when is_binary(reason) do
    %__MODULE__{
      message:
        "INFRA ABORT: #{reason} — this is an environment or repo-state problem, not something a developer re-run can fix.",
      reason: reason
    }
  end
end
