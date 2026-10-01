defmodule Mix.Tasks.Kogen.Shape do
  use Mix.Task

  use Boundary, deps: [Kogen.Shaping, Mix]

  @shortdoc "Shapes an Intent headlessly: start, status, continue, approve or cancel"
  @moduledoc """
  Headless Shaping, the only way to shape. Every invocation prints exactly
  one JSON object line on stdout (diagnostics go to stderr) and exits `0`
  (accepted, replayed or status), `2` (refusal, with `error.code`) or `1`
  (internal failure).

      mix kogen.shape --brief FILE [--route ROUTE] [--interface NAME] [--request-id RID]
      mix kogen.shape ID
      mix kogen.shape ID --brief FILE [--interface NAME] [--request-id RID]
      mix kogen.shape ID --approve PRESENTATION [--interface NAME] [--request-id RID]
      mix kogen.shape ID --cancel [--request-id RID]

  Start mints the Intent ID (a UUIDv7, also the session ID), stores the brief
  and returns within seconds while a detached runner drives the configured
  Shaping Controller (`claude -p` or `codex exec`). Status reads the session
  without changing it: its state, open questions with recommendations and
  evidence, the current presentation (with its immutable proposal copy,
  audit report and complete `approve_command`) and pending inputs. A
  continue message (an answer, steer or feedback) reaches the running
  provider session or resumes the same one; a message never approves.
  `--approve` approves only the named, current, audited-ready presentation
  and moves the package to `approved/` without starting a Build. `--cancel`
  stops the running turn and keeps everything. Sessions are addressed only by
  ID; a Draft shaped before headless Shaping is refused
  (`legacy_draft_unsupported`). Callers with `KOGEN_ROLE` set are refused
  (`managed_role`). Inputs and approvals are `interface-attested`.
  """

  @impl Mix.Task
  def run(args) do
    stdout = Process.group_leader()
    Process.group_leader(self(), Process.whereis(:standard_error))
    {json, exit_code} = Kogen.Shaping.main(args)
    IO.puts(stdout, Jason.encode!(json))
    System.halt(exit_code)
  end
end
