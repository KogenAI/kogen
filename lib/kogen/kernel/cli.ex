defmodule Kogen.Kernel.CLI do
  @moduledoc "The escript entry point for the Kogen command line."

  @usage """
  Usage: kogen <command>

  Commands:
    intent check
    approve
    build
    status
    version
  """

  @spec main([String.t()]) :: no_return()
  def main(["--help"]) do
    IO.write(@usage)
    System.halt(0)
  end

  def main(_args) do
    IO.write(@usage)
    System.halt(2)
  end
end
