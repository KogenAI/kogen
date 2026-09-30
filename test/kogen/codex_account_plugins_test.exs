defmodule Kogen.Codex.AccountPluginsTest do
  use ExUnit.Case, async: true

  alias Kogen.Codex.AccountPlugins

  @sha "788a818fbb9596869c7a487554507cb8bdca17584b8671112b23f9e225ba35c8"
  @fp "b95d4844be810bfecbeef75c92e197938cb3e2641c7065001574405f5fbdbb1e"
  @now ~U[2026-09-29 12:00:00Z]
  @recorded "2026-09-29T10:06:45.403464+00:00"
  @remote [
    "github@openai-curated-remote",
    "figma@openai-curated-remote",
    "stripe@openai-curated-remote"
  ]

  defp opts(extra \\ []),
    do:
      Keyword.merge(
        [runtime: Kogen.ManagedRuntimeReady.codex_version(), executable_sha256: @sha, now: @now],
        extra
      )

  defp native(mode, extra \\ %{}) do
    on? = String.ends_with?(mode, "-on")

    Map.merge(
      %{
        "mode" => mode,
        "runtime" => Kogen.ManagedRuntimeReady.codex_version(),
        "executable_sha256" => @sha,
        "recorded_at" => @recorded,
        "installed_apps" => 11,
        "enabled_apps" => if(on?, do: 12, else: 0),
        "callable_apps" => if(on?, do: 12, else: 0),
        "installed_plugin_count" => if(on?, do: 10, else: 0),
        "remote_enabled_plugins" => if(on?, do: @remote, else: []),
        "discovery" =>
          if(on?,
            do: %{"timeout" => true},
            else: %{"id" => 2, "result" => %{"data" => [], "nextCursor" => nil}}
          ),
        "account_fingerprint" => @fp
      },
      extra
    )
  end

  defp model(surface, extra \\ %{}) do
    Map.merge(
      %{
        "surface" => surface,
        "session_id" => "sess-1",
        "runtime" => Kogen.ManagedRuntimeReady.codex_version(),
        "executable_sha256" => @sha,
        "recorded_at" => @recorded,
        "flags" => %{"apps" => false, "plugins" => false},
        "visible_plugins" => [],
        "visible_apps" => []
      },
      extra
    )
  end

  defp eval(receipts, extra \\ []) do
    observations =
      Enum.flat_map(receipts, fn receipt ->
        {:ok, list} = AccountPlugins.parse(receipt)
        list
      end)

    AccountPlugins.evaluate(observations, opts(extra))
  end

  defp native_status(result), do: result["surfaces"]["native_discovery"]

  test "native discovery is excluded with positive control and disabled observation" do
    result = eval([native("managed-on"), native("managed-off")])
    assert %{"status" => "excluded"} = native_status(result)
    # Other surfaces are never derived from it.
    assert result["status"] == "unproven"
    assert result["unproven_surfaces"] == ~w(helper interactive resume root)
  end

  test "probe summary shape inherits top-level runtime, sha and time" do
    summary = %{
      "recorded_at" => @recorded,
      "runtime" => Kogen.ManagedRuntimeReady.codex_version(),
      "executable_sha256" => @sha,
      "observations" =>
        Enum.map(["managed-off", "managed-on"], fn m ->
          native(m) |> Map.drop(~w(runtime executable_sha256 recorded_at))
        end)
    }

    assert %{"status" => "excluded"} = native_status(eval([summary]))
  end

  test "disabled observation alone is unproven" do
    assert %{"status" => "unproven", "reason" => "no_positive_control"} =
             native_status(eval([native("managed-off")]))
  end

  test "positive control for a different account does not count" do
    on = native("managed-on", %{"account_fingerprint" => "other"})
    assert %{"status" => "unproven"} = native_status(eval([on, native("managed-off")]))
  end

  test "timed out or errored disabled discovery is unproven" do
    on = native("managed-on")

    for discovery <- [%{"timeout" => true}, %{"id" => 2, "error" => %{"code" => -32_603}}] do
      off = native("managed-off", %{"discovery" => discovery})
      assert %{"status" => "unproven"} = native_status(eval([on, off]))
    end
  end

  test "stale observations are unproven" do
    result = eval([native("managed-on"), native("managed-off")], now: ~U[2026-10-20 00:00:00Z])
    assert %{"status" => "unproven", "reason" => "stale_observation"} = native_status(result)

    # A stale positive control alone also blocks exclusion.
    stale_on = native("managed-on", %{"recorded_at" => "2026-09-01T00:00:00+00:00"})
    assert %{"status" => "unproven"} = native_status(eval([stale_on, native("managed-off")]))
  end

  test "executable sha or runtime mismatch is unproven" do
    on = native("managed-on")

    off = native("managed-off", %{"executable_sha256" => String.duplicate("0", 64)})

    assert %{"status" => "unproven", "reason" => "executable_sha256_mismatch"} =
             native_status(eval([on, off]))

    off = native("managed-off", %{"runtime" => "0.157.0"})

    assert %{"status" => "unproven", "reason" => "runtime_version_mismatch"} =
             native_status(eval([on, off]))

    on = native("managed-on", %{"executable_sha256" => String.duplicate("0", 64)})
    assert %{"status" => "unproven"} = native_status(eval([on, native("managed-off")]))
  end

  test "disabled observation with a callable app is leaked" do
    off = native("managed-off", %{"callable_apps" => 1})
    result = eval([native("managed-on"), off])
    assert %{"status" => "leaked"} = native_status(result)
    assert result["status"] == "leaked"
    assert result["leaked_surfaces"] == ["native_discovery"]
  end

  test "stale native leakage content is unproven until its observation is fresh" do
    stale_off =
      native("managed-off", %{
        "enabled_apps" => 1,
        "recorded_at" => "2026-09-01T00:00:00+00:00"
      })

    result = eval([native("managed-on"), stale_off])
    assert %{"status" => "unproven", "reason" => "stale_observation"} = native_status(result)
    assert result["leaked_surfaces"] == []
  end

  test "a synthetic visible_plugins file alone proves nothing" do
    assert {:error, :unrecognized_receipt} = AccountPlugins.parse(%{"visible_plugins" => []})

    result = AccountPlugins.evaluate([], opts())
    assert result["status"] == "unproven"
    assert result["unproven_surfaces"] == Enum.sort(AccountPlugins.surfaces())
  end

  test "model-visible helper observation naming a control plugin is leaked" do
    helper = model("helper", %{"visible_plugins" => ["github"]})
    result = eval([native("managed-on"), helper])

    assert %{"status" => "leaked", "visible_enabled_plugins" => ["github"]} =
             result["surfaces"]["helper"]

    assert result["status"] == "leaked"
  end

  test "stale or foreign model leakage content is unproven until binding and freshness pass" do
    control = native("managed-on")

    for invalid <- [
          %{"recorded_at" => "2026-09-01T00:00:00+00:00"},
          %{"runtime" => "0.157.0"},
          %{"session_id" => ""}
        ] do
      helper = model("helper", Map.merge(%{"visible_plugins" => ["github"]}, invalid))
      result = eval([control, helper])

      assert %{"status" => "unproven"} = result["surfaces"]["helper"]
      assert result["leaked_surfaces"] == []
    end

    fresh = eval([control, model("helper", %{"visible_plugins" => ["github"]})])

    assert %{"status" => "leaked", "visible_enabled_plugins" => ["github"]} =
             fresh["surfaces"]["helper"]
  end

  test "empty root observation with binding and control excludes only root" do
    result = eval([native("managed-on"), native("managed-off"), model("root")])
    assert %{"status" => "excluded"} = result["surfaces"]["root"]
    assert %{"status" => "unproven"} = result["surfaces"]["helper"]
    assert result["status"] == "unproven"
    assert result["unproven_surfaces"] == ~w(helper interactive resume)
  end

  test "model observation without control, binding, or flags is unproven" do
    assert %{"status" => "unproven", "reason" => "no_positive_control"} =
             eval([model("root")])["surfaces"]["root"]

    on = native("managed-on")

    assert %{"reason" => "executable_sha256_mismatch"} =
             eval([on, model("root", %{"executable_sha256" => "bad"})])["surfaces"]["root"]

    assert %{"reason" => "effective_flags_not_disabled"} =
             eval([on, model("root", %{"flags" => %{"apps" => true}})])["surfaces"]["root"]

    assert %{"reason" => "missing_session_id"} =
             eval([on, model("root", %{"session_id" => ""})])["surfaces"]["root"]
  end

  test "all surfaces demonstrated gives overall excluded" do
    models = Enum.map(~w(root helper resume interactive), &model/1)
    result = eval([native("managed-on"), native("managed-off") | models])
    assert result["status"] == "excluded"
    assert result["unproven_surfaces"] == []
  end

  test "bundled skill names do not affect the result" do
    bundled = ~w(imagegen openai-docs plugin-creator skill-creator skill-installer)
    helper = model("helper", %{"visible_plugins" => [], "skills" => bundled})
    without = eval([native("managed-on"), model("helper")])
    with_skills = eval([native("managed-on"), helper])
    assert without == with_skills
    assert with_skills["surfaces"]["helper"]["status"] == "excluded"
  end

  test "read_dir records receipt hashes and ignores unrecognized files" do
    dir = Path.join(System.tmp_dir!(), "acct-plugins-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "a.json"), Jason.encode!(native("managed-on")))
    File.write!(Path.join(dir, "b.json"), Jason.encode!(native("managed-off")))
    File.write!(Path.join(dir, "c.json"), ~s({"visible_plugins": []}))

    result = AccountPlugins.evaluate_dir(dir, opts())
    assert %{"status" => "excluded"} = native_status(result)

    assert [%{"recognized" => true, "sha256" => <<_::binary-size(64)>>}, _, c] =
             result["receipts"]

    assert c["recognized"] == false

    assert AccountPlugins.evaluate_dir(dir <> "-none", opts())["status"] == "unproven"
    assert AccountPlugins.evaluate_dir(nil, opts())["receipts"] == []
  end
end
