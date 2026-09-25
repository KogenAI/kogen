Code.require_file("../support/route_config.ex", __DIR__)

defmodule Kogen.ConfigurationSupportContractTest do
  use ExUnit.Case, async: true

  @config_path ".kogen/config.yaml"
  @readme Path.expand("../../README.md", __DIR__) |> File.read!()

  # The default stays the clean Claude route in this Build; flipping it to the
  # Claude-dominant hybrid is a separate follow-up.
  test "the tracked config keeps the clean claude route as default_route" do
    assert {:ok, default} = Kogen.Intent.read_config(@config_path)
    assert {:ok, explicit} = Kogen.Intent.read_config(@config_path, "claude")

    assert default == explicit
    assert default.route == "claude"
    assert default.harness == "claude"
  end

  # The existing clean routes keep their exact bytes; the hybrids are additive.
  test "the tracked config keeps main's clean route bytes and adds only the two hybrids" do
    tracked = File.read!(@config_path)

    main_clean = """
    default_route: claude
    routes:
      claude:
        harness: claude
        shaping:   {model: claude-opus-5-5, effort: medium}
        developer: {model: claude-opus-5-5, effort: medium}
        reviewer:  {model: claude-opus-5-5, effort: medium}
        helpers:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
          expert: {model: claude-opus-5-5, effort: high}
      codex:
        harness: codex
        shaping:   {model: gpt-6-sol, effort: medium}
        developer: {model: gpt-6-sol, effort: medium}
        reviewer:  {model: gpt-6-sol, effort: high}
        helpers:
          scout:  {model: gpt-6-luna, effort: low}
          worker: {model: gpt-6-luna, effort: high}
          expert: {model: gpt-6-sol, effort: high}
    """

    assert String.starts_with?(tracked, main_clean)
    assert String.ends_with?(tracked, "outer_resumptions: 2\nverification_retries: 2\n")

    {:ok, data} = YamlElixir.read_from_string(tracked)

    assert data["routes"] |> Map.keys() |> Enum.sort() ==
             ~w(claude claude-dominant-adversarial-codex codex codex-dominant-adversarial-claude)

    assert Enum.count(data["routes"], fn {_name, route} -> route["harness"] == "codex" end) == 1

    for hybrid <- ~w(claude-dominant-adversarial-codex codex-dominant-adversarial-claude) do
      refute Map.has_key?(data["routes"][hybrid], "harness")
    end

    for {_name, route} <- data["routes"] do
      refute Map.has_key?(route, "auditor")
    end
  end

  # Codex-only live owners and the shaping-evaluation driver resolve the one
  # route with a top-level codex harness; the hybrids declare none.
  test "the four-route config still resolves exactly one top-level codex route" do
    assert %{route: "codex", harness: "codex"} = Kogen.RouteConfig.codex_route!(@config_path)

    root = Path.join(System.tmp_dir!(), "kogen-codex-route-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "config.yaml")

    tracked = File.read!(@config_path)
    [_before, codex_body] = String.split(tracked, "  codex:\n", parts: 2)
    [codex_body, _hybrids] = String.split(codex_body, "  # Hybrid routes", parts: 2)

    second = "  second-codex:\n" <> codex_body <> "  # Hybrid routes"
    File.write!(path, String.replace(tracked, "  # Hybrid routes", second, global: false))

    assert_raise RuntimeError, ~r/exactly one route with harness codex/, fn ->
      Kogen.RouteConfig.codex_route!(path)
    end
  end

  test "the tracked config exposes the four-route role-to-harness matrix" do
    matrix =
      for route <-
            ~w(claude codex claude-dominant-adversarial-codex codex-dominant-adversarial-claude),
          into: %{} do
        assert {:ok, config} = Kogen.Intent.read_config(@config_path, route)
        {route, config.roles}
      end

    all = fn harness ->
      %{
        shaping: harness,
        developer: harness,
        reviewer: harness,
        expert: harness
      }
    end

    assert matrix == %{
             "claude" => all.("claude"),
             "codex" => all.("codex"),
             "claude-dominant-adversarial-codex" => %{
               shaping: "claude",
               developer: "claude",
               reviewer: "codex",
               expert: "codex"
             },
             "codex-dominant-adversarial-claude" => %{
               shaping: "codex",
               developer: "codex",
               reviewer: "claude",
               expert: "claude"
             }
           }

    for {_route, roles} <- matrix do
      refute Map.has_key?(roles, :auditor)
    end

    {:ok, claude_dominant} =
      Kogen.Intent.read_config(@config_path, "claude-dominant-adversarial-codex")

    assert claude_dominant.shaping == %{model: "claude-opus-5-5", effort: "medium"}
    assert claude_dominant.developer == %{model: "claude-opus-5-5", effort: "medium"}
    assert claude_dominant.reviewer == %{model: "gpt-6-sol", effort: "high"}
    assert claude_dominant.expert == %{model: "gpt-6-sol", effort: "high"}
    refute Map.has_key?(claude_dominant, :auditor)

    reviewer = Kogen.Intent.role_config(claude_dominant, :reviewer)
    assert reviewer.harness == "codex"
    assert reviewer.helpers.scout == %{model: "gpt-6-luna", effort: "low"}
    assert reviewer.helpers.worker == %{model: "gpt-6-luna", effort: "high"}
    assert reviewer.helpers.expert == %{model: "gpt-6-sol", effort: "high"}

    developer = Kogen.Intent.role_config(claude_dominant, :developer)
    assert developer.harness == "claude"

    assert developer.helpers == %{
             scout: %{model: "claude-sonnet-5", effort: "low"},
             worker: %{model: "claude-sonnet-5", effort: "medium"}
           }

    {:ok, codex_dominant} =
      Kogen.Intent.read_config(@config_path, "codex-dominant-adversarial-claude")

    assert codex_dominant.developer == %{model: "gpt-6-sol", effort: "medium"}
    assert codex_dominant.reviewer == %{model: "claude-opus-5-5", effort: "medium"}
    assert codex_dominant.expert == %{model: "claude-opus-5-5", effort: "high"}
    refute Map.has_key?(codex_dominant, :auditor)

    for clean <- ~w(claude codex) do
      {:ok, config} = Kogen.Intent.read_config(@config_path, clean)
      assert config.expert == config.helpers.expert
      refute Map.has_key?(config, :auditor)
    end

    assert Kogen.Intent.role_config(codex_dominant, :reviewer).helpers.scout.model ==
             "claude-sonnet-5"

    assert Kogen.Intent.role_config(codex_dominant, :shaping).helpers.worker.model == "gpt-6-luna"
  end

  test "the tracked config keeps the clean Claude route unchanged" do
    assert {:ok, config} = Kogen.Intent.read_config(@config_path, "claude")

    assert config.route == "claude"
    assert config.harness == "claude"
    assert config.shaping == %{model: "claude-opus-5-5", effort: "medium"}
    assert config.developer == %{model: "claude-opus-5-5", effort: "medium"}
    assert config.reviewer == %{model: "claude-opus-5-5", effort: "medium"}
    assert config.helpers.scout == %{model: "claude-sonnet-5", effort: "low"}
    assert config.helpers.worker == %{model: "claude-sonnet-5", effort: "medium"}
    assert config.helpers.expert == %{model: "claude-opus-5-5", effort: "high"}
    assert config.outer_resumptions == 2
    assert config.verification_retries == 2
  end

  test "the tracked config resolves the codex route with the exact profiles" do
    assert {:ok, config} = Kogen.Intent.read_config(@config_path, "codex")

    assert config.route == "codex"
    assert config.harness == "codex"
    assert config.shaping == %{model: "gpt-6-sol", effort: "medium"}
    assert config.developer == %{model: "gpt-6-sol", effort: "medium"}
    assert config.reviewer == %{model: "gpt-6-sol", effort: "high"}
    assert config.helpers.scout == %{model: "gpt-6-luna", effort: "low"}
    assert config.helpers.worker == %{model: "gpt-6-luna", effort: "high"}
    assert config.helpers.expert == %{model: "gpt-6-sol", effort: "high"}
    assert config.outer_resumptions == 2
    assert config.verification_retries == 2
  end

  test "the production config consumer accepts supported values and rejects missing and foreign authority" do
    root = Path.join(System.tmp_dir!(), "kogen-config-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "config.yaml")

    File.write!(path, """
    default_route: primary
    routes:
      primary:
        harness: codex
        shaping: {model: shape, effort: low}
        developer: {model: develop, effort: medium}
        reviewer: {model: review, effort: high}
        helpers:
          scout: {model: scout, effort: low}
          worker: {model: worker, effort: medium}
          expert: {model: expert, effort: high}
    outer_resumptions: 2
    verification_retries: 1
    """)

    assert {:ok, config} = Kogen.Intent.read_config(path)
    assert config.route == "primary"
    assert config.developer == %{model: "develop", effort: "medium"}
    assert config.helpers.worker.model == "worker"

    assert {:error, "unknown route: missing; available routes: primary"} =
             Kogen.Intent.read_config(path, "missing")

    File.write!(path, """
    default_route: primary
    routes:
      primary:
        harness: codex
    outer_resumptions: 2
    verification_retries: 1
    """)

    assert {:error, reason} = Kogen.Intent.read_config(path)
    assert reason =~ "missing required key: routes.primary.shaping"

    File.write!(path, "harness: codex\n")

    assert {:error,
            "config.yaml uses the replaced flat configuration shape (top-level harness and roles); define default_route and routes instead"} =
             Kogen.Intent.read_config(path)
  end

  test "provider denial shim is executable and records attempted access outside the fixture" do
    root = Path.expand("../..", __DIR__)
    shim = Path.join(root, "test/support/codex")
    assert File.regular?(shim)
    assert {:ok, stat} = File.stat(shim)
    assert Bitwise.band(stat.mode, 0o111) != 0

    receipt =
      Path.join(System.tmp_dir!(), "provider-denied-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm(receipt) end)

    {_output, status} =
      System.cmd(shim, ["exec"],
        env: [{"KOGEN_PROVIDER_DENIAL_RECEIPT", receipt}],
        stderr_to_stdout: true
      )

    assert status != 0
    assert File.read!(receipt) =~ "PATH-SHIM-CODEX-INVOKED: exec"
  end

  test "README documents routes, --route selection, default_route, flat-shape refusal and route recording" do
    assert @readme =~ "routes"
    assert @readme =~ "default_route"
    assert @readme =~ "--route <name>"
    assert @readme =~ "mix kogen.shape"
    assert @readme =~ "mix kogen.build"

    assert @readme =~
             "top-level `harness:` and roles, no `routes`) is refused before launch"

    assert @readme =~ "shaping.route"
    assert @readme =~ "resolves its route once and freezes it"
    assert @readme =~ "build-summary.json"
  end

  test "README no longer claims a single global harness is what the config names" do
    refute @readme =~ "the configured harness"
    refute @readme =~ "This repository's current\nconfiguration"
  end
end
