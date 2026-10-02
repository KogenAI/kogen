defmodule KogenChecks.Check.BroadRescueTest do
  use Credo.Test.Case

  alias KogenChecks.Check.BroadRescue

  test "flags bare and Exception rescues without reraise" do
    """
    defmodule R do
      def a do
        x()
      rescue
        e -> {:error, e}
      end

      def b do
        try do
          x()
        rescue
          _ in [RuntimeError] -> :ok
        catch
          _, _ -> nil
        end
      end
    end
    """
    |> to_source_file("lib/kogen/x/r.ex")
    |> run_check(BroadRescue)
    |> assert_issues(fn issues -> assert length(issues) == 3 end)
  end

  test "allows narrow rescue and reraise" do
    """
    defmodule R do
      def a do
        File.read!("x")
      rescue
        e in [File.Error] -> {:error, e.reason}
      end

      def b do
        x()
      rescue
        e -> reraise e, __STACKTRACE__
      end
    end
    """
    |> to_source_file("lib/kogen/x/r.ex")
    |> run_check(BroadRescue)
    |> refute_issues()
  end
end
