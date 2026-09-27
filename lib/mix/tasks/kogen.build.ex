defmodule Mix.Tasks.Kogen.Build.SignalHandler do
  @moduledoc false
  # Traps SIGHUP (closing the terminal) and SIGTERM for `mix kogen.build`:
  # both reach OTP's `:erl_signal_server` once `:os.set_signal/2` asks for
  # `:handle` (probed: SIGTERM already reaches OTP's graceful shutdown by
  # default; SIGHUP needs this to be caught at all). Ctrl-C (SIGINT) is not
  # in this family — `:os.set_signal(:sigint, _)` is rejected by the VM — so
  # it is covered only by `mise.toml`'s `ELIXIR_ERL_OPTIONS=+Bd` (exit at
  # once, no BREAK menu) plus the supervisor's own parent-death watchdog,
  # never by this handler.
  @behaviour :gen_event

  @impl :gen_event
  def init(control), do: {:ok, control}

  @impl :gen_event
  def handle_event(signal, control) when signal in [:sighup, :sigterm] do
    Kogen.ProcessCustody.release(control)
    System.halt(1)
  end

  def handle_event(_signal, control), do: {:ok, control}

  @impl :gen_event
  def handle_call(_request, control), do: {:ok, :ok, control}

  @impl :gen_event
  def handle_info(_message, control), do: {:ok, control}
end

defmodule Mix.Tasks.Kogen.Build do
  use Mix.Task
  use Boundary, deps: [Kogen.Build, Kogen.ProcessCustody, Mix]

  @shortdoc "Runs the Kogen Build loop for an Approved Intent"
  @moduledoc """
  `mix kogen.build [--route <name>] <slug>` drives the Approved Intent at
  `.kogen/intents/approved/<slug>` through Develop, Check, declared targets,
  Review, bounded Rework, and one ordinary Git Commit. The whole Build runs on
  the named route from `.kogen/config.yaml`, or on its `default_route` without
  `--route`.

  The Build runs in its own Candidate worktree and harness home outside the
  repository (`mix kogen.candidates` lists kept ones). This task is the only
  place that reads the process working directory, once, to find the control
  checkout (a main worktree, never a linked one); `Kogen.Build.run/3` gets it
  explicitly. A rerun continues the kept Candidate of the continuation set
  when its evidence is intact, or refuses with an inspection action.

  SIGHUP (closing the terminal) and SIGTERM tear down every process group
  this Build recorded on its lock, release the lock and exit, through
  `Mix.Tasks.Kogen.Build.SignalHandler`. Ctrl-C is covered separately, by
  `mise.toml`'s `ELIXIR_ERL_OPTIONS=+Bd` and the process-custody watchdogs,
  since the BEAM break handler cannot run Elixir cleanup on Ctrl-C.
  """

  @usage "usage: mix kogen.build [--route <name>] <slug>"

  @impl Mix.Task
  def run(args) do
    case parse(args) do
      {:ok, route, slug} -> build(slug, route)
      :usage -> fail(@usage)
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: [route: :string]) do
      {[], [slug], []} when slug != "" -> {:ok, nil, slug}
      {[route: route], [slug], []} when route != "" and slug != "" -> {:ok, route, slug}
      _usage -> :usage
    end
  end

  defp build(slug, route) do
    control = File.cwd!()
    trap_signals(control)

    case Kogen.Build.run(slug, route, control) do
      :ok -> :ok
      {:error, reason} -> fail(reason)
    end
  end

  defp trap_signals(control) do
    :os.set_signal(:sighup, :handle)
    :os.set_signal(:sigterm, :handle)
    :gen_event.add_handler(:erl_signal_server, Mix.Tasks.Kogen.Build.SignalHandler, control)
  end

  defp fail(reason) do
    IO.puts(:stderr, reason)
    System.halt(1)
  end
end
