defmodule Kogen.RolePromptContractTest do
  @moduledoc """
  `role-prompt-tune-up`: offline prompt-content contracts for the Developer
  and Reviewer prompts, checked for meaning (the pattern in
  `harness_contract_test.exs:80-108`), not pinned sentences. Both prompts are
  one harness-neutral file each (`build.ex`'s `render_developer_prompt/5` and
  `render_reviewer_prompt/4`), so "for both harnesses" is satisfied by
  asserting on that one shared source file, exactly as
  `harness_contract_test.exs` already treats it as harness-neutral by
  construction.
  """
  use ExUnit.Case, async: true

  alias Kogen.Harness.Verdict

  @developer_path Path.join(File.cwd!(), "priv/kogen/prompts/developer.md")
  @reviewer_path Path.join(File.cwd!(), "priv/kogen/prompts/reviewer.md")

  test "the Developer prompt carries an explicit Done-when list" do
    developer = File.read!(@developer_path)

    assert developer =~ ~r/done when/i

    for phrase <- [
          ~r/every scenario.{0,40}`then`.{0,40}(genuinely true|not just plausible)/is,
          ~r/declared proof selector.{0,80}(present|passing).{0,80}focused/is,
          ~r/no path outside.{0,40}guard/is,
          ~r/notes.{0,40}written.{0,60}objection.{0,40}objection/is
        ] do
      assert developer =~ phrase,
             "developer.md is missing a Done-when item matching #{inspect(phrase)}"
    end
  end

  test "the Developer prompt requires a pre-stop self-review naming then and wrong_result" do
    developer = File.read!(@developer_path)

    assert developer =~ ~r/git diff/i
    assert developer =~ "`then`"
    assert developer =~ "`wrong_result`"

    assert developer =~ ~r/before (ending|end).{0,40}turn/is,
           "developer.md's self-review must run before the turn ends"

    # The self-review is reused through the existing per-scenario notes
    # channel (Jev reads it), not a new structured section.
    assert developer =~ ~r/self-review.{0,400}notes/is or
             developer =~ ~r/notes.{0,400}self-review/is
  end

  test "the Developer prompt requires the final notes to say what the self-review checked, per scenario" do
    developer = File.read!(@developer_path)

    assert developer =~ ~r/what.{0,40}self-review checked/is
  end

  test "the Developer prompt requires a verification-failure resume to list every failed receipt, log and manifest entry with digests" do
    developer = File.read!(@developer_path)

    assert developer =~ ~r/every failed.{0,40}(receipt|log|manifest)/is
    assert developer =~ ~r/digest/i
  end

  test "the Reviewer prompt's findings say what was checked and what wasn't, citing evidence locators" do
    reviewer = File.read!(@reviewer_path)

    assert reviewer =~ ~r/what you (actually )?checked/i
    assert reviewer =~ ~r/what you did not (reach|check)/i
    assert reviewer =~ ~r/locator/i
  end

  test "the Reviewer prompt describes receipt as conditional on the launch's verdict schema" do
    reviewer = File.read!(@reviewer_path)

    assert reviewer =~ "receipt"
    assert reviewer =~ ~r/when your verdict schema (provides|includes)/i
  end

  test "the prompts stay harness-neutral: one text, no harness-specific branch" do
    for path <- [@developer_path, @reviewer_path] do
      text = File.read!(path)
      refute text =~ ~r/\bclaude(?! Code)\b/i and text =~ ~r/\bcodex\b/i and text =~ "if harness"
      refute text =~ "{% if"
      refute text =~ "{{harness}}"
    end
  end

  test "the prompts never claim this tune-up improves outcomes" do
    for path <- [@developer_path, @reviewer_path] do
      text = File.read!(path)
      refute text =~ ~r/improves? (build )?outcomes?/i
      refute text =~ ~r/reduces? rework/i
    end
  end

  test "the verdict schema's required key set is unchanged by the prompt tune-up" do
    decoded = Jason.decode!(Verdict.schema())

    assert Enum.sort(decoded["required"]) ==
             Enum.sort(~w(candidate_id attempt_token verdict scenarios dispositions findings))

    assert decoded["additionalProperties"] == false
  end

  test "negative control: a Reviewer prompt without its read-only rule reads incomplete" do
    reviewer = File.read!(@reviewer_path)

    stripped =
      reviewer
      |> String.split("\n")
      |> Enum.reject(&(&1 =~ ~r/must not modify the candidate|must not edit, create, delete/i))
      |> Enum.join("\n")

    refute stripped =~ ~r/must not edit, create, delete/i
    assert reviewer =~ ~r/must not edit, create, delete/i
  end
end
