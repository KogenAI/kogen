defmodule Kogen.Acceptance.VerifyWordErrorsTest do
  use Kogen.Testkit.Case

  @moduletag :acceptance

  @source """
  ---
  title: Verify words
  domains: [intent]
  size: small
  ---
  Probe one Verify entry.

  ## Acceptance
  - A1: The probe behaves.

  ## Verify
  - A1: VERIFY
  """

  @verify_line 12

  @tag intent: "verify-word-errors/A1"
  test "an unknown Verify kind is a lint issue on its line" do
    issues = lint("bogus")

    assert Enum.any?(issues, fn issue ->
             issue.rule == :invalid_verify and issue.line == @verify_line and
               issue.message =~ "bogus"
           end)
  end

  @tag intent: "verify-word-errors/A2"
  test "an unknown Verify modifier is a lint issue on its line" do
    issues = lint("test domian=intent")

    assert Enum.any?(issues, fn issue ->
             issue.rule == :invalid_verify and issue.line == @verify_line and
               issue.message =~ "domian=intent"
           end)
  end

  @tag intent: "verify-word-errors/A3"
  test "a valid keep entry with a domain lints cleanly" do
    assert lint("test keep domain=intent") == []
  end

  defp lint(verify) do
    source = String.replace(@source, "VERIFY", verify)
    assert {:ok, intent} = Kogen.Intent.parse_binary(source, "verify-word-errors/intent.md")
    Kogen.Intent.lint(intent)
  end
end
