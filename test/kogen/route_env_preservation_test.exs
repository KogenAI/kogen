defmodule Kogen.RouteEnvPreservationTest do
  use ExUnit.Case, async: true

  test "test helper preserves the selected route and offline/live evidence context in a child VM" do
    source =
      Path.join(
        System.tmp_dir!(),
        "kogen-route-env-child-#{System.pid()}-#{System.unique_integer([:positive])}.exs"
      )

    File.write!(source, """
    defmodule Kogen.RouteEnvChildProbe do
      use ExUnit.Case, async: true

      test "inherited route evidence survives test helper" do
        assert System.get_env("KOGEN_ROUTE") == "codex-dominant-adversarial-claude"
        assert System.get_env("KOGEN_PROVIDERS_DENIED") == "1"
        assert System.get_env("KOGEN_LIVE_LOG_DIR") == "/tmp/live-evidence-probe"
      end
    end
    """)

    on_exit(fn -> File.rm(source) end)

    assert {:ok, output} =
             Kogen.IsolatedCase.run(source, "test inherited route evidence survives test helper",
               env: [
                 {"KOGEN_ROUTE", "codex-dominant-adversarial-claude"},
                 {"KOGEN_PROVIDERS_DENIED", "1"},
                 {"KOGEN_LIVE_LOG_DIR", "/tmp/live-evidence-probe"}
               ]
             )

    assert output =~ "Result: 1 passed"
  end
end
