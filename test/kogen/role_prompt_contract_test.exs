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

  @project_root Path.expand("../..", __DIR__)

  alias Kogen.Harness.Verdict

  @developer_path Path.join(@project_root, "priv/kogen/prompts/developer.md")
  @reviewer_path Path.join(@project_root, "priv/kogen/prompts/reviewer.md")

  test "the Developer prompt carries an explicit Done-when list" do
    developer = File.read!(@developer_path)

    assert developer =~ ~r/done when/i

    for phrase <- [
          ~r/every scenario.{0,40}`then`.{0,40}(genuinely true|not just plausible)/is,
          ~r/declared proof selector.{0,80}(present|passing).{0,80}focused/is,
          ~r/every additional path.{0,80}approved outcome.{0,80}disclosed/is,
          ~r/no frozen package.{0,100}verification record.{0,100}protected control/is,
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

  test "the Developer may delegate only supplied focused non-gate checks for assigned paths" do
    developer = File.read!(@developer_path)

    assert developer =~ ~r/editing helper may run an\s+exact supplied focused non-gate command/is
    assert developer =~ ~r/directly checks or exercises\s+the helper's assigned paths/is
    assert developer =~ ~r/exact command, expected result and\s+finite stopping condition/is

    assert developer =~
             ~r/each command run, its exit\s+status and retained output locator, plus any blocker/is

    assert developer =~ ~r/completion of delegated work.{0,80}combined behavior/is

    assert developer =~
             ~r/Neither you nor any helper may run or delegate a declared verification gate/is

    assert developer =~ "{{verification_ownership}}"

    refute developer =~ ~r/do not.{0,35}delegate (them|focused commands)/is
  end

  test "the prompts no longer describe the bootstrap Stop path as active verification ownership" do
    developer = File.read!(@developer_path)
    compact_developer = Regex.replace(~r/\s+/, developer, " ")
    reviewer = File.read!(@reviewer_path)

    refute developer =~ ~r/older Kogen controller.{0,100}v1 verification context/is
    refute developer =~ ~r/let Stop run again/is
    refute reviewer =~ "Stop script settles instead"

    assert developer =~ ~r/Kogen's Build controller verifies each of your turns/is
    assert reviewer =~ ~r/Kogen's Build controller owns verification/is

    assert compact_developer =~
             "applicable failure-class retry policy from the shared execution policy"

    refute compact_developer =~ "`verification_retries` remains"
    refute compact_developer =~ "normal retry budget"
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
