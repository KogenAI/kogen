defmodule Kogen.Codex.StatePluginsTest do
  use ExUnit.Case, async: true

  alias Kogen.Codex.State
  alias Kogen.Harness.ProviderMarker

  setup do
    scope = Path.join(System.tmp_dir!(), "kogen-plugins-#{System.unique_integer([:positive])}")
    State.ensure_scope!(scope)
    on_exit(fn -> File.rm_rf(scope) end)
    %{scope: scope, plugins: Path.join(scope, "plugins")}
  end

  test "an absent or empty directory tree Codex created is not discovery content", %{
    scope: scope,
    plugins: plugins
  } do
    assert :ok = State.validate_scope!(scope)

    File.mkdir_p!(Path.join(plugins, "cache/marketplace"))
    File.mkdir_p!(Path.join(plugins, ".remote-plugin-install-staging"))
    assert :ok = State.validate_scope!(scope)
  end

  test "real plugin content, a symlink or a plain file still refuses", %{
    scope: scope,
    plugins: plugins
  } do
    manifest = Path.join(plugins, "cache/m/p/1/.codex-plugin/plugin.json")
    File.mkdir_p!(Path.dirname(manifest))
    File.write!(manifest, "{}")

    error =
      assert_raise RuntimeError, ~r/unexpected discovery settings.*plugins/, fn ->
        State.validate_scope!(scope)
      end

    # The refusal is an environment fault to the Build's failure classifier.
    assert ProviderMarker.scope_refusal?(Exception.message(error))

    foreign = Path.join(scope, "foreign")
    File.mkdir_p!(foreign)
    other = assert_raise RuntimeError, fn -> State.validate_scope!(foreign) end
    assert ProviderMarker.scope_refusal?(Exception.message(other))

    assert File.read!(manifest) == "{}"
    File.rm_rf!(plugins)

    target = Path.join(scope, "elsewhere")
    File.mkdir_p!(target)
    File.ln_s!(target, plugins)

    assert_raise RuntimeError, ~r/unexpected discovery settings/, fn ->
      State.validate_scope!(scope)
    end

    File.rm!(plugins)

    File.write!(plugins, "not a directory")

    assert_raise RuntimeError, ~r/unexpected discovery settings/, fn ->
      State.validate_scope!(scope)
    end

    File.rm!(plugins)
    File.mkdir_p!(Path.join(plugins, "cache/empty"))
    File.ln_s!(target, Path.join(plugins, "cache/link"))

    assert_raise RuntimeError, ~r/unexpected discovery settings/, fn ->
      State.validate_scope!(scope)
    end
  end

  test "real plugin content refuses immediately", %{
    scope: scope,
    plugins: plugins
  } do
    File.mkdir_p!(plugins)
    File.write!(Path.join(plugins, "plugin.json"), "{}")

    {micros, _} =
      :timer.tc(fn ->
        assert_raise RuntimeError, ~r/unexpected discovery settings/, fn ->
          State.validate_scope!(scope)
        end
      end)

    assert micros < 5_000_000
  end
end
