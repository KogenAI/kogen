defmodule CodegenTestHarness.Stacks.Phoenix.NoEctoScaffoldTest do
  @moduledoc """
  Asserts that `codegen-scaffold create --no-ecto` produces a compilable
  Phoenix app with a health controller free of Ecto references.
  """

  use ExUnit.Case, async: true

  alias CodegenTestHarness.Assertions
  alias CodegenTestHarness.Fixtures

  @moduletag :slow
  @moduletag timeout: 6_600_000

  setup do
    parent = Fixtures.isolated_tmp_dir()
    {:ok, parent: parent}
  end

  test "--no-ecto scaffold compiles and health controller has no Ecto refs", %{parent: parent} do
    app_dir = Fixtures.run_no_ecto_scaffold(parent, slug: "no_ecto_app")

    # --no-ecto scaffold generates no Repo module
    refute File.exists?(Path.join(app_dir, "lib/no_ecto_app/repo.ex")),
           "expected no repo.ex under --no-ecto scaffold"

    # health controller must have Ecto references stripped
    controller = Path.join(app_dir, "lib/no_ecto_app_web/controllers/health_controller.ex")

    assert File.exists?(controller),
           "expected health_controller.ex to exist at #{controller}"

    content = File.read!(controller)

    refute content =~ ~r/SQL\.query!/,
           "health_controller.ex must not contain SQL.query! under --no-ecto"

    refute content =~ ~r/alias Ecto\.Adapters\.SQL/,
           "health_controller.ex must not contain alias Ecto.Adapters.SQL under --no-ecto"

    # app must compile cleanly
    Assertions.assert_mix_compiles!(app_dir)

    # generated health controller test must pass (DB-independent 200 check)
    {out, code} =
      System.cmd(
        "mix",
        ["test", "test/no_ecto_app_web/controllers/health_controller_test.exs"],
        cd: app_dir,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert code == 0, out
  end
end
