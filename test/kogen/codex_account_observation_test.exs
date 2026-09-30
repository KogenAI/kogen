defmodule Kogen.Codex.AccountObservationTest do
  @moduledoc """
  The production native account/remote plugin observation, against a fake
  app-server speaking the pinned runtime's JSON-RPC: the positive control
  and the exact-production disabled session, their scope/launch binding,
  and the live-compatibility acceptance that refuses anything but a
  demonstrated native exclusion.
  """
  use ExUnit.Case, async: true

  alias Kogen.Codex.{AccountObservation, Compatibility}

  @fake Path.expand("../support/fake_codex_app_server.py", __DIR__)
  @production ~w(--disable apps --disable plugins --disable shell_snapshot -c tool_output_token_limit=4000)

  setup do
    root = Path.join(System.tmp_dir!(), "kogen-acct-obs-#{System.unique_integer([:positive])}")
    home = Path.join(root, "scope-home")
    cwd = Path.join(root, "fixture")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, home: home, cwd: cwd}
  end

  defp context(%{home: home, root: root}, mode, args) do
    %{
      executable: @fake,
      args: args,
      env: [
        {"CODEX_HOME", home},
        {"FAKE_ACCOUNT_MODE", mode},
        {"FAKE_APP_SERVER_PIDS", Path.join(root, "pids")}
      ],
      runtime_identity: %{
        "version" => Kogen.ManagedRuntimeReady.codex_version(),
        "executable" => @fake
      }
    }
  end

  defp observe(ctx, mode, args \\ @production) do
    context = context(ctx, mode, args)
    dir = Path.join(ctx.root, "observations-#{mode}")

    receipts =
      AccountObservation.observe(context, ctx.cwd, context.runtime_identity, dir,
        init_timeout: 5,
        request_timeout: 2
      )

    {context, receipts, Compatibility.account_plugin_verdict(context, ctx.cwd, receipts)}
  end

  defp native(verdict), do: verdict["surfaces"]["native_discovery"]

  test "the observer never writes plugins into the shared scope and copies only its inputs",
       ctx do
    File.write!(Path.join(ctx.home, "auth.json"), ~s({"k":1}))
    File.write!(Path.join(ctx.home, "config.toml"), "")
    File.mkdir_p!(Path.join(ctx.home, "plugins/cache"))
    {_context, receipts, _verdict} = observe(ctx, "normal")
    assert Enum.all?(receipts, &(&1["error"] == nil)), inspect(receipts)
    assert Enum.any?(receipts, &(&1["mode"] == "scope-on"))
    assert Enum.all?(receipts, &(&1["codex_home"] == ctx.home))

    assert File.ls!(Path.join(ctx.home, "plugins")) == ["cache"]
    assert File.ls!(Path.join(ctx.home, "plugins/cache")) == []
    assert Enum.sort(File.ls!(ctx.home)) == ["auth.json", "config.toml", "plugins"]

    real = Path.join(ctx.home, "plugins/cache/m/p/plugin.json")
    File.mkdir_p!(Path.dirname(real))
    File.write!(real, "{}")
    {_context, receipts, _verdict} = observe(ctx, "normal")
    assert Enum.all?(receipts, &(&1["error"] == nil)), inspect(receipts)
    assert File.read!(real) == "{}"
  end

  test "a scope without plugins stays without plugins after observing", ctx do
    {_context, receipts, _verdict} = observe(ctx, "normal")
    assert Enum.all?(receipts, &(&1["error"] == nil)), inspect(receipts)
    assert File.ls!(ctx.home) == []
  end

  test "the positive control and the exact-production disabled session demonstrate native exclusion",
       ctx do
    {context, receipts, verdict} = observe(ctx, "normal")

    assert native(verdict)["status"] == "excluded"
    assert native(verdict)["control_mode"] == "scope-on"

    off = Enum.find(receipts, &(&1["mode"] == "scope-off"))
    on = Enum.find(receipts, &(&1["mode"] == "scope-on"))

    # The disabled session ran exactly the production arguments; the control
    # differs only in the two flags and shares the launch binding and scope.
    assert off["args_sha256"] == AccountObservation.args_sha256(context.args)
    assert off["launch_binding"] == on["launch_binding"]
    assert off["codex_home"] == ctx.home and on["codex_home"] == ctx.home
    assert off["account_fingerprint"] == on["account_fingerprint"]

    assert on["remote_enabled_plugins"] ==
             ~w(github@openai-curated-remote figma@openai-curated-remote)

    assert {off["enabled_apps"], off["callable_apps"], off["installed_plugin_count"]} == {0, 0, 0}
    assert off["discovery"]["result"]["data"] == []
    assert on["discovery"] == %{"timeout" => true}, "the control's catalog fetch is not needed"
    refute inspect(receipts) =~ "example.invalid", "account secrets are never recorded"

    # Written receipts are digest-bound and the servers were reaped.
    for receipt <- receipts do
      digest = Base.encode16(:crypto.hash(:sha256, File.read!(receipt["path"])), case: :lower)
      assert digest == receipt["sha256"]
    end

    for pid <- ctx.root |> Path.join("pids") |> File.read!() |> String.split("\n", trim: true) do
      assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0, "app-server #{pid} outlived its observation"
    end

    # Model-visible surfaces are not derived from native discovery.
    for surface <- ~w(root helper resume interactive) do
      assert verdict["surfaces"][surface]["status"] == "unproven"
    end
  end

  test "a disabled session that still exposes a callable app or plugin is a leak", ctx do
    {_context, _receipts, verdict} = observe(ctx, "leak")
    assert native(verdict)["status"] == "leaked"
  end

  test "missing, inconclusive or unbound observations stay unproven", ctx do
    assert %{"status" => "unproven", "reason" => "discovery_timeout"} =
             ctx |> observe("timeout") |> elem(2) |> native()

    assert %{"status" => "unproven", "reason" => "no_positive_control"} =
             ctx |> observe("no-remote") |> elem(2) |> native()

    assert %{"status" => "unproven", "reason" => "codex_home_mismatch"} =
             ctx |> observe("home") |> elem(2) |> native()

    # A server that never answers yields no counts at all, not zeros.
    {_context, receipts, verdict} = observe(ctx, "crash")
    assert native(verdict)["status"] == "unproven"
    off = Enum.find(receipts, &(&1["mode"] == "scope-off"))
    assert off["enabled_apps"] == nil and off["remote_enabled_plugins"] == nil
  end

  test "production arguments that do not disable apps and plugins are never observed as production",
       ctx do
    args = ~w(--disable shell_snapshot)
    {_context, receipts, verdict} = observe(ctx, "normal", args)

    assert [%{"mode" => "scope-off", "error" => error}] = receipts
    assert error =~ "do not disable apps and plugins"
    assert native(verdict)["status"] == "unproven"
  end

  test "receipts bound to another scope, launch or runtime never count", ctx do
    {context, receipts, _verdict} = observe(ctx, "normal")

    rebound = fn key, value ->
      receipts
      |> Enum.map(&if(&1["mode"] == "scope-off", do: Map.put(&1, key, value), else: &1))
      |> then(&Compatibility.account_plugin_verdict(context, ctx.cwd, &1))
      |> native()
    end

    assert rebound.("launch_binding", "other")["reason"] == "launch_binding_mismatch"
    assert rebound.("args_sha256", "other")["reason"] == "not_production_arguments"
    assert rebound.("executable_sha256", "other")["reason"] == "executable_sha256_mismatch"
    assert rebound.("selected_codex_home", "/elsewhere")["reason"] == "codex_home_mismatch"

    stale = DateTime.utc_now() |> DateTime.add(-30 * 24 * 3600) |> DateTime.to_iso8601()
    assert rebound.("recorded_at", stale)["reason"] == "stale_observation"

    # A model-authored or synthetic empty list is not an observation.
    synthetic = [%{"visible_plugins" => [], "path" => "x", "sha256" => "y"}]

    assert %{"status" => "unproven", "reason" => "no_disabled_observation"} =
             context |> Compatibility.account_plugin_verdict(ctx.cwd, synthetic) |> native()
  end
end
