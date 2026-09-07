defmodule Kogen.CommitProvenanceTest do
  @moduledoc "Automated first and subsequent Builds must never claim manual bootstrap provenance."
  use ExUnit.Case, async: false

  @makefile """
  .PHONY: check
  check:
  \t@true
  """

  @config_yaml """
  harness: codex
  shaping:   {model: fake, effort: low}
  developer: {model: fake, effort: low}
  reviewer:  {model: fake, effort: low}
  outer_resumptions: 2
  """

  test "first and subsequent Builds record truthful automated provenance" do
    project_root = File.cwd!()
    dest = Path.join(System.tmp_dir!(), "kogen-provenance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    setup_fixture(project_root, dest)

    fake_harness = Path.join(project_root, "test/support/fake_codex_simple_accept")
    prior_harness = System.get_env("KOGEN_HARNESS")
    System.put_env("KOGEN_HARNESS", fake_harness)

    on_exit(fn ->
      if prior_harness,
        do: System.put_env("KOGEN_HARNESS", prior_harness),
        else: System.delete_env("KOGEN_HARNESS")
    end)

    write_intent(dest, "intent-one", "Intent one")
    assert :ok = File.cd!(dest, fn -> Kogen.Build.run("intent-one") end)

    first_body = git!(dest, ["log", "-1", "--format=%B"])
    refute first_body =~ "Bootstrap provenance"
    refute first_body =~ "manual Developer invocation"
    assert first_body =~ "Built by Kogen"

    assert File.read!(Path.join(dest, ".kogen/intents/complete/intent-one/evidence.md")) ==
             "original evidence\n"

    assert first_body =~ "build-evidence-1.md"

    assert File.read!(Path.join(dest, ".kogen/intents/complete/intent-one/build-evidence-1.md")) =~
             "Complete evidence"

    write_intent(dest, "intent-two", "Intent two")
    assert :ok = File.cd!(dest, fn -> Kogen.Build.run("intent-two") end)

    second_body = git!(dest, ["log", "-1", "--format=%B"])
    refute second_body =~ "Bootstrap provenance"
    refute second_body =~ "manual Developer invocation"
    assert second_body =~ "Candidate"
    assert second_body =~ "build-evidence-1.md"

    complete_evidence = Path.join(dest, ".kogen/intents/complete/intent-one/evidence.md")
    write_intent(dest, "intent-one", "Duplicate intent")

    assert {:error, "Complete Intent already exists: intent-one"} =
             File.cd!(dest, fn -> Kogen.Build.run("intent-one") end)

    assert File.read!(complete_evidence) == "original evidence\n"
  end

  defp setup_fixture(project_root, dest) do
    File.mkdir_p!(Path.join(dest, ".codex/hooks"))

    File.cp!(
      Path.join(project_root, ".codex/hooks/check.sh"),
      Path.join(dest, ".codex/hooks/check.sh")
    )

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)

    File.mkdir_p!(Path.join(dest, "priv/kogen/prompts"))

    for prompt <- ["developer.md", "reviewer.md"] do
      File.cp!(
        Path.join(project_root, "priv/kogen/prompts/#{prompt}"),
        Path.join(dest, "priv/kogen/prompts/#{prompt}")
      )
    end

    File.write!(Path.join(dest, "Makefile"), @makefile)

    File.write!(
      Path.join(dest, ".gitignore"),
      ".kogen/build.lock\n.kogen/runtime/\n.kogen/intents/drafts/\n.kogen/intents/approved/\n"
    )

    config_path = Path.join(dest, ".kogen/config.yaml")
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, @config_yaml)

    env = git_env()
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: dest)
    {_out, 0} = System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: dest, env: env)
  end

  defp write_intent(dest, slug, title) do
    intent_yaml = """
    id: 01960000-0000-7000-8000-0000000#{String.pad_leading(Integer.to_string(:erlang.phash2(slug, 9999)), 5, "0")}
    slug: #{slug}
    title: #{title}
    may_change_guarded_paths:
      - dummy.txt
    """

    scenarios_yaml = """
    - id: fixture-scenario
      given: a fixture Candidate
      when: the fake Developer settles immediately
      then: a fresh Reviewer accepts immediately
      wrong_result: n/a, fixture only
      verified_by: [check]
      evidence: fixture only
    """

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{slug}")
    File.mkdir_p!(intent_dir)
    File.write!(Path.join(intent_dir, "intent.yaml"), intent_yaml)
    File.write!(Path.join(intent_dir, "scenarios.yaml"), scenarios_yaml)
    File.write!(Path.join(intent_dir, "evidence.md"), "original evidence\n")
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir)
    String.trim(out)
  end
end
