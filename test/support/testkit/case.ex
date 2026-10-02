defmodule Kogen.Testkit.Case do
  @moduledoc "Async ExUnit case template with an isolated system temporary directory per test."

  use ExUnit.CaseTemplate

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true

      setup do
        tmp_dir = Kogen.Testkit.Temp.create!()
        on_exit(fn -> File.rm_rf!(tmp_dir) end)
        {:ok, tmp_dir: tmp_dir}
      end
    end
  end
end
