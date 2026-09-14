Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.CodexLoginHelpTest do
  use Kogen.IsolatedCase, async: true

  @source Path.expand("../..", __DIR__)

  test "offline Mix help documents native login forwarding without starting login" do
    fixture = Kogen.CompiledFixture.create!(@source, "codex-login-help")
    on_exit(fn -> File.rm_rf(fixture) end)
    managed_root = Path.join(fixture, "no-managed-runtime")
    trace = Path.join(fixture, "native.jsonl")

    {output, 0} =
      Kogen.CompiledFixture.mix_task!(
        fixture,
        ["help", "kogen.codex.login"],
        [{"KOGEN_CODEX_ROOT", managed_root}, {"KOGEN_TEST_NATIVE_TRACE", trace}]
      )

    assert output =~ "default browser login"
    assert output =~ "mix kogen.codex.login"
    assert output =~ "mix kogen.codex.login -- --device-auth"
    assert output =~ "mix kogen.codex.login --project -- --device-auth"
    assert output =~ "printenv OPENAI_API_KEY | mix kogen.codex.login -- --with-api-key"
    assert output =~ "printenv OPENAI_API_KEY | mix kogen.codex.login --project -- --with-api-key"
    assert output =~ "mix kogen.codex.login -- --help"
    assert output =~ "mix kogen.codex.login --project -- --help"
    assert output =~ ~r/needs a human to\s+authorize it/
    assert output =~ "unattended"
    refute File.exists?(managed_root)
    refute File.exists?(trace)
  end
end
