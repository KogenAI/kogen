Code.require_file("review_packet_audit.ex", __DIR__)

defmodule Kogen.LiveReviewerReworkFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Kogen.Build.{Contract, VerificationPlan}
  alias Kogen.{Intent, LiveReworkAudit, ReviewPacketAudit, RootProfileAudit}

  @slug "live-reviewer-rework-probe"
  @intent_id "01960000-0000-7000-8000-00000000beef"

  @check_rule """
  check:
  \t@test -f dummy.txt || (echo "dummy.txt is missing. Required exact content: reviewer-rework-k4q9z" && exit 1)
  \t@printf 'reviewer-rework-k4q9z\\n' | cmp -s - dummy.txt || (echo "dummy.txt must contain reviewer-rework-k4q9z followed by exactly one LF newline" && exit 1)
  """

  @intent """
  id: #{@intent_id}
  slug: #{@slug}
  title: Live reviewer rework probe
  may_change_guarded_paths:
    - dummy.txt
    - reviewer-notes.md
  """

  @scenarios """
  - id: reviewer-directed-rework
    given: an isolated provider-backed fixture with no dummy.txt or reviewer-notes.md
    when: the first Developer turn implements this test protocol
    then: it creates dummy.txt at the repository root containing exactly reviewer-rework-k4q9z followed by one LF newline, deliberately leaves reviewer-notes.md absent for the first independent Reviewer to identify, and creates reviewer-notes.md containing exactly reviewer-confirmed-k4q9z followed by one LF newline only after that Reviewer returns actionable rework in the exact same Developer conversation. For the first controlled phase, its final free-prose notes plainly disclose that reviewer-notes.md is intentionally absent pending the mandated independent Review -- not a contract objection -- and reference only files that actually exist; it does not fabricate the missing file or gate receipts. The fresh second Reviewer assesses only the final Candidate's exact bytes and current passing Check before accepting it. The outer live-test driver exclusively audits the historical omission, first Review, and resume sequence from retained streams, receipts, and Check archives; a nested Reviewer must not request inaccessible prior records or transcripts, and cannot certify its own future acceptance
    wrong_result: the first Reviewer accepts without inspecting the intentionally deferred companion file, a replacement Developer session performs rework, or the final Candidate lacks the companion file
    verified_by: [check]
    evidence: provider-backed Build-only fixture preserves both structured reviewer receipts, Developer raw streams, Stop records, and the resulting Commit
    proof:
      offline: [test/kogen/live_rework_audit_test.exs, test/kogen/verification_ownership_lifecycle_test.exs]
      paid_target: none
      paid_reason: "offline-sufficient: the fixture check deterministically rejects missing or malformed candidate bytes"
      affected_paths: [dummy.txt, reviewer-notes.md]
  """

  @risks """
  - id: seeded-fixture-is-not-user-ownership
    scenario_ids: [reviewer-directed-rework]
    description: Fixture seed state is not acceptance evidence.
  """

  def run do
    project_root = File.cwd!()
    {:ok, config} = Intent.read_config()
    log_dir = owned_log_dir(project_root)

    raw_fixture =
      Path.join(
        System.tmp_dir!(),
        "kogen-reviewer-rework-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(raw_fixture)
    on_exit(fn -> File.rm_rf!(raw_fixture) end)

    # The fixture project root is created under System.tmp_dir!() and then
    # resolved to its canonical, symlink-free path (fixture-outside-checkout):
    # macOS aliases /tmp and /var/folders through symlinks, and both the
    # Codex environment and Claude Code's path-keyed login scopes need the
    # canonical form. Nothing is created under the checkout's
    # .kogen/runtime/live-reviewer-rework.
    fixture = ReviewPacketAudit.assert_outside_checkout!(raw_fixture, project_root)

    # Fail closed, before any provider dispatch, if the fixture does not
    # resolve to a logged-in Kogen Claude Code login scope.
    ReviewPacketAudit.assert_logged_in!(fixture)

    File.write!(Path.join(log_dir, "fixture-path.txt"), fixture <> "\n")
    setup_fixture(project_root, fixture)
    precompile!(fixture, log_dir)
    write_package!(fixture)

    # Fail closed locally before a provider-backed Build can be dispatched.
    approved = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    assert {:ok, contract} = Contract.load(approved)
    assert contract.scenarios != []
    assert {:ok, catalog} = VerificationPlan.load(fixture)

    assert {:ok, _plan} =
             VerificationPlan.build(
               contract.scenarios,
               ["dummy.txt", "reviewer-notes.md"],
               catalog,
               fixture
             )

    raw_stream_dir = Path.join(log_dir, "build-raw-streams")

    {output, status} =
      System.cmd("mix", ["kogen.build", @slug],
        cd: fixture,
        env: [
          {"KOGEN_RAW_LOG_DIR", raw_stream_dir},
          {"MIX_BUILD_PATH", Path.join(fixture, "_build")},
          {"KOGEN_JEV_TRANSPORT", nil},
          {"KOGEN_JEV_SECURITY", nil}
        ],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "build-console.log"), output)
    complete = Path.join(fixture, ".kogen/intents/complete/#{@slug}")
    preserve(fixture, complete, log_dir)
    # Records, sidecars, packets and the complete package survive fixture
    # removal, including when the nested Build fails.
    retained = ReviewPacketAudit.retain_evidence!(fixture, log_dir, @slug)

    assert status == 0,
           "reviewer-rework Build failed (#{status}):\n#{output}\nretained: #{log_dir}"

    assert File.dir?(complete)

    audit =
      LiveReworkAudit.audit!(fixture, raw_stream_dir, slug: @slug, intent_id: @intent_id)

    # The Build ran in the fixture with the fixture's config and login scope.
    RootProfileAudit.audit!(
      Path.join(log_dir, "build-root-profile-audit"),
      %{
        audit.developer_session_id => Map.put(config.developer, :role, "developer"),
        audit.rework_reviewer_session_id => Map.put(config.reviewer, :role, "reviewer"),
        audit.accepting_reviewer_session_id => Map.put(config.reviewer, :role, "reviewer")
      },
      RootProfileAudit.sessions_root(fixture)
    )

    File.write!(
      Path.join(log_dir, "native-receipt-summary.json"),
      Jason.encode!(audit.native_summary) <> "\n"
    )

    assert [build_id] = retained.build_ids, "expected exactly one nested Build tracking id"

    ReviewPacketAudit.audit!(log_dir, build_id, {:git, fixture, audit.candidate})

    File.rm_rf!(fixture)
    assert :ok = LiveReworkAudit.audit_retained!(log_dir)
  end

  def write_package!(fixture) do
    dir = Path.join(fixture, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "intent.yaml"), @intent)
    File.write!(Path.join(dir, "scenarios.yaml"), @scenarios)
    File.write!(Path.join(dir, "risks.yaml"), @risks)
  end

  defp owned_log_dir(root) do
    base = System.get_env("KOGEN_LIVE_LOG_DIR") || Path.join(root, ".kogen/runtime/live-evidence")
    dir = Path.join(base, "reviewer-rework-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp setup_fixture(root, fixture) do
    {_out, 0} =
      System.cmd("rsync", [
        "-a",
        "--exclude=_build",
        "--exclude=deps",
        "--exclude=.git",
        "--exclude=.kogen/runtime",
        "--exclude=.kogen/build.lock",
        "--exclude=.kogen/intents",
        root <> "/",
        fixture <> "/"
      ])

    Kogen.DependencyFixture.copy!(Path.join(root, "deps"), Path.join(fixture, "deps"))
    {:ok, catalog} = VerificationPlan.load(root)

    other_targets =
      catalog.entries
      |> Enum.reject(&(&1["name"] == "check"))
      |> VerificationPlan.render_target_declarations()

    File.write!(Path.join(fixture, "Makefile"), @check_rule <> other_targets)

    env = [
      {"GIT_AUTHOR_NAME", "Kogen Fixture"},
      {"GIT_AUTHOR_EMAIL", "kogen-fixture@example.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Fixture"},
      {"GIT_COMMITTER_EMAIL", "kogen-fixture@example.invalid"}
    ]

    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture)
    {_out, 0} = System.cmd("git", ["add", "-A"], cd: fixture)

    {_out, 0} =
      System.cmd("git", ["commit", "-q", "-m", "fixture baseline"], cd: fixture, env: env)
  end

  defp precompile!(fixture, log_dir) do
    {out, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: fixture,
        env: [{"MIX_BUILD_PATH", Path.join(fixture, "_build")}],
        stderr_to_stdout: true
      )

    File.write!(Path.join(log_dir, "fixture-precompile.log"), out)
    assert status == 0, "fixture precompile failed (#{status}):\n#{out}"
  end

  defp preserve(fixture, complete, log_dir) do
    for {source, name} <- [
          {Path.join(fixture, ".kogen/runtime/verification-history.jsonl"),
           "verification-history.jsonl"},
          {Path.join(complete, "evidence.md"), "evidence.md"}
        ],
        File.exists?(source),
        do: File.cp!(source, Path.join(log_dir, name))

    retained =
      for path <-
            Path.wildcard(Path.join(fixture, ".kogen/runtime/scenario-tracking/*/record.json")) do
        destination =
          Path.join([
            log_dir,
            "scenario-tracking",
            Path.basename(Path.dirname(path)),
            "record.json"
          ])

        File.mkdir_p!(Path.dirname(destination))
        File.cp!(path, destination)
        {Path.relative_to(path, fixture), destination}
      end

    retained = Map.new(retained)

    for path <- Path.wildcard(Path.join(complete, "build-summary*.json")) do
      summary = path |> File.read!() |> Jason.decode!()
      source = get_in(summary, ["full_record", "path"])
      destination = Map.fetch!(retained, source)
      updated = put_in(summary, ["full_record", "path"], destination)
      File.write!(Path.join(log_dir, Path.basename(path)), Jason.encode!(updated) <> "\n")
    end
  end
end
