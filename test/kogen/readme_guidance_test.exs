Code.require_file("../support/document_references.ex", __DIR__)

defmodule Kogen.ReadmeGuidanceTest do
  use ExUnit.Case, async: true

  alias Kogen.Test.DocumentReferences, as: DR

  @root Path.expand("../..", __DIR__)
  @readme File.read!(Path.join(@root, "README.md"))
  @shaping_prompt File.read!(Path.join(@root, "priv/kogen/prompts/shaping.md"))

  # These checks are behavior, not sentences: every repository path README
  # names in backticks must exist, every Module.function/arity it names must
  # be exported, and its pinned Jev version must match the code's. Rewording
  # a paragraph around these must still pass; a stale path, a stale function
  # reference or a stale version must not.
  test "every repository path README names in backticks exists" do
    assert DR.missing_paths(@root, @readme) == []
  end

  test "every Module.function/arity README names is exported" do
    assert DR.unresolved_functions(@readme) == []
  end

  test "README's pinned Jev version matches the code's" do
    assert @readme =~ Kogen.Jev.model()
  end

  test "README still documents self-hosting (expand and contract) as a short anchor" do
    compact = Regex.replace(~r/\s+/, @readme, " ")

    # Short anchors, not sentences: the concept name, and that self-hosting
    # changes land in two Intents (expand, then contract).
    assert compact =~ "expand and contract"
    assert compact =~ "Kogen builds itself"
  end

  test "shared Shaping prompt does not carry the Kogen-specific self-hosting section" do
    refute @shaping_prompt =~ "expand and contract"
  end

  # Every `{{placeholder}}` the controller's renderer substitutes
  # (`Kogen.Build.render_developer_prompt/5`, `render_reviewer_prompt/4`)
  # must still be present, literally, in the templates it reads.
  test "every placeholder the renderer substitutes is present in developer.md and reviewer.md" do
    developer = File.read!(Path.join(@root, "priv/kogen/prompts/developer.md"))
    reviewer = File.read!(Path.join(@root, "priv/kogen/prompts/reviewer.md"))

    assert DR.placeholders_present?(developer, [
             "intent_title",
             "intent_id",
             "approved_path",
             "may_change_guarded_paths",
             "verification_ownership",
             "readiness_commands",
             "execution_policy"
           ])

    assert DR.placeholders_present?(reviewer, [
             "intent_title",
             "intent_id",
             "approved_path",
             "candidate_id",
             "execution_policy"
           ])
  end

  # The `provider-required:`/`offline-sufficient:` proof-reason formats
  # `Kogen.Build.VerificationPlan`'s reason validator accepts must appear,
  # in that form, in both README and the Shaping prompt that instructs
  # writing them.
  test "the provider-required/offline-sufficient proof-reason formats appear in README and the Shaping prompt" do
    assert @readme =~ "offline-sufficient:"

    for text <- ["offline-sufficient:", "provider-required:"] do
      assert @shaping_prompt =~ text
    end

    assert @shaping_prompt =~
             "provider-required: <exact-target>; observation: <provider-only observable>; offline-limit:"

    assert @shaping_prompt =~ "offline-sufficient: <consumer/control>"
  end

  # Negative controls on fixture copies of the real README: a missing path
  # fails naming it, a version mismatch fails, and rewording passes.
  describe "negative controls on a fixture copy" do
    test "a README citing a missing path fails naming it" do
      broken = @readme <> "\nSee `lib/kogen/does_not_exist_anywhere.ex` for details.\n"
      assert "lib/kogen/does_not_exist_anywhere.ex" in DR.missing_paths(@root, broken)
    end

    test "a README with a stale Jev version fails" do
      stale = String.replace(@readme, Kogen.Jev.model(), "jev-0.0.0")
      refute stale =~ Kogen.Jev.model()
    end

    test "rewording a paragraph around a real path still passes" do
      reworded =
        String.replace(
          @readme,
          "Kogen manages the complete native runtime",
          "Kogen fully manages the native runtime"
        )

      assert DR.missing_paths(@root, reworded) == []
    end

    test "a removed placeholder fails" do
      developer = File.read!(Path.join(@root, "priv/kogen/prompts/developer.md"))
      stripped = String.replace(developer, "{{execution_policy}}", "")

      refute DR.placeholders_present?(stripped, ["execution_policy"])
    end

    test "a README naming a nonexistent function fails resolution" do
      broken = @readme <> "\nSee `Kogen.Build.Verification.nope/9` for details.\n"

      assert {"Kogen.Build.Verification", :nope, 9} in DR.unresolved_functions(broken)
    end
  end
end
