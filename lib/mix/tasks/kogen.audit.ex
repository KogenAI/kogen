defmodule Mix.Tasks.Kogen.Audit do
  use Mix.Task
  use Boundary, deps: [Kogen.ShapingAudit, Mix]

  @shortdoc "Audits a Shaping Draft or Approved package"
  @moduledoc """
  `mix kogen.audit [--route <name>] <slug>` audits one Draft or Approved
  package with the deterministic Shaping checks and writes its report.

  `mix kogen.audit --status <slug>` reports whether the latest report is
  `current`, `stale` or `missing` without auditing again.

  `mix kogen.audit --confirm <slug>` is an explicit external request for the
  one extra counted auditor attempt after the normal slug/HEAD/route budget
  is exhausted. The attempt is reserved before dispatch; a failed,
  unavailable or interrupted attempt consumes the grant. An exact retry
  replays its recorded result and never launches another attempt.
  It cannot be combined with `--auditor`, `--status` or `--stop-hook`.

  `mix kogen.audit --stop-hook` dispatches the Codex Shaping Controller Stop decision and
  writes exactly one JSON decision to the hook output path.

  The task only delegates to `Kogen.ShapingAudit.main/1` and halts with its
  exit code.
  """

  @impl Mix.Task
  def run(args) do
    System.halt(Kogen.ShapingAudit.main(args))
  end
end
