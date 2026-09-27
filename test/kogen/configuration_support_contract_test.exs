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

  # The tracked config validates through the reader's whole-config mode: every
  # route is normalized, not only the selected one, so a broken route in it
  # still fails `check`. This checks behavior, not bytes: the default route
  # resolves, every named route resolves with the harness and model each role
  # needs, hybrids use role-level harnesses, and the retry-policy keys are
  # integers. Appending a key, reordering keys or adding a fifth valid route
  # to a copy still passes; a broken route in a copy still fails.
  test "the tracked config validates in whole-config mode and resolves every route's roles" do
    tracked = File.read!(@config_path)

    assert {:ok, default} = Kogen.Intent.validate_config(@config_path)
    assert default.route == "claude"
    assert default.harness == "claude"

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

    for route <-
          ~w(claude codex claude-dominant-adversarial-codex codex-dominant-adversarial-claude) do
      assert {:ok, config} = Kogen.Intent.read_config(@config_path, route)
      assert is_binary(config.harness)
      assert is_integer(config.outer_resumptions)
      assert is_integer(config.verification_retries)
      assert is_integer(config.offline_retries)
    end
  end

  test "an appended key, reordered keys, and a fifth valid route all pass whole-config validation" do
    root =
      Path.join(System.tmp_dir!(), "kogen-config-reorder-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    appended = Path.join(root, "appended.yaml")
    File.write!(appended, File.read!(@config_path) <> "\n# a harmless trailing comment\n")
    assert {:ok, _config} = Kogen.Intent.validate_config(appended)

    reordered = Path.join(root, "reordered.yaml")

    File.write!(reordered, """
    verification_retries: 2
    outer_resumptions: 2
    offline_retries: 4
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
    default_route: claude
    """)

    assert {:ok, reordered_config} = Kogen.Intent.validate_config(reordered)
    assert reordered_config.route == "claude"

    fifth_route = Path.join(root, "fifth-route.yaml")

    File.write!(fifth_route, """
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
      fifth:
        harness: claude
        shaping:   {model: claude-opus-5-5, effort: medium}
        developer: {model: claude-opus-5-5, effort: medium}
        reviewer:  {model: claude-opus-5-5, effort: medium}
        helpers:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
          expert: {model: claude-opus-5-5, effort: high}
    outer_resumptions: 2
    verification_retries: 2
    offline_retries: 4
    """)

    assert {:ok, _config} = Kogen.Intent.validate_config(fifth_route)
    assert {:ok, fifth} = Kogen.Intent.read_config(fifth_route, "fifth")
    assert fifth.route == "fifth"

    broken_route = Path.join(root, "broken-route.yaml")

    File.write!(broken_route, """
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
      other:
        harness: claude
    outer_resumptions: 2
    verification_retries: 2
    offline_retries: 4
    """)

    assert {:error, reason} = Kogen.Intent.validate_config(broken_route)
    assert reason =~ "missing required key: routes.other"

    assert {:ok, selected} = Kogen.Intent.read_config(broken_route, "claude")
    assert selected.route == "claude"

    assert {:error, selecting_reason} = Kogen.Intent.read_config(broken_route, "other")
    assert selecting_reason =~ "missing required key: routes.other"
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
    assert config.developer == %{model: "gpt-6-sol", effort: "high"}
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
    offline_retries: 4
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
    offline_retries: 4
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
