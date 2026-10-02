defmodule KogenChecks.Check.FailOpenWithTest do
  use Credo.Test.Case

  alias KogenChecks.Check.FailOpenWith

  test "flags catch-all and error-to-literal success fallbacks" do
    """
    defmodule X do
      def catch_all(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          _ -> false
        end
      end

      def error_default(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          {:error, _reason} -> []
        end
      end
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(FailOpenWith)
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end

  test "allows no else and explicit error propagation or translation" do
    """
    defmodule X do
      def no_else(value), do: with({:ok, result} <- fetch(value), do: result)

      def translated(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          {:error, :missing} -> {:error, {:missing, value}}
          {:error, reason} -> {:error, {:read, reason}}
        end
      end

      def preserve(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          error -> error
        end
      end
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(FailOpenWith)
    |> refute_issues()
  end

  test "does not scan tests" do
    """
    defmodule X do
      def f do
        with :ok <- call() do
          :ok
        else
          _ -> :ok
        end
      end
    end
    """
    |> to_source_file("test/build/x_test.exs")
    |> run_check(FailOpenWith)
    |> refute_issues()
  end
end
