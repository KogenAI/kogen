defmodule Kogen.Testkit.Proc do
  @moduledoc "The testkit's single process adapter; test helpers spawn OS commands only through it."

  @spec cmd!(String.t(), [String.t()], keyword()) :: String.t()
  def cmd!(executable, args, opts) do
    case System.cmd(executable, args, Keyword.put(opts, :stderr_to_stdout, true)) do
      {output, 0} ->
        output

      {output, status} ->
        raise "#{executable} #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
