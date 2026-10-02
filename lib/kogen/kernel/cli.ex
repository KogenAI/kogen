defmodule Kogen.Kernel.CLI do
  @moduledoc "The escript entry point for the Kogen command line."
  use Boundary, deps: [Kogen.Contracts, Kogen.Kernel], exports: []

  alias Kogen.Kernel.CLI.Args
  alias Kogen.Kernel.CLI.Arguments
  alias Kogen.Kernel.CLI.Runner

  @usage """
  Usage: kogen <command> [arguments] --project <checkout> [options]

  Commands:
    intent check <path>   Parse and lint an Intent
    approve <slug>        Review and record an Intent approval (--by, --yes)
    build <slug>          Build and land an approved Intent (--model, --effort)
    status                Show Intent state (--json for JSON)
    report <slug>         Show the latest run report (--json)
    reconcile <run-id>    Reconcile a run after a crash
    version               Show the Kogen version

  Common options:
    --origin <repo>       Git repository used for approval and landing
    --base <branch>       Target branch (default: main)
  """

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {status, output} = execute(argv)
    IO.write(output)
    System.halt(status)
  end

  @spec execute([String.t()]) :: {non_neg_integer(), String.t()}
  def execute(argv) do
    case Arguments.parse(argv) do
      {:ok, %Args{command: command} = args} -> dispatch(command, args)
      {:error, reason} -> {2, "kogen: #{reason}\n\n#{@usage}"}
    end
  end

  defp dispatch(:help, _args), do: {0, @usage}
  defp dispatch(_command, %Args{} = args), do: Runner.run(args)
end
