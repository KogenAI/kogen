Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.BuildBoundariesTest do
  use ExUnit.Case, async: true

  alias Kogen.Integration.{FakeProvider, Helpers}

  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  for {stage, reason} <- [{"setup", "setup_failed"}, {"checks", "check_failing"}] do
    test "GIT-8 restores the saved index when startup #{stage} fails", %{suite: suite} do
      context = fixture!(suite, [])
      configure_startup!(context, unquote(stage), "exit 12")
      before = state(context)
      arm!(context)

      {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

      assert status == 3, output
      assert output =~ "environment/" <> unquote(reason)
      refute output =~ "building fixture"
      refute output =~ "failed fixture:"
      refute output =~ "  run log:"
      assert state(context) == before
      assert File.read!(Path.join(context.repo, "app.txt")) == "startup edit\n"
      assert length(FakeProvider.provider_requests(context.server)) == 1
      assert result(context)["outcome"] == unquote(reason)
    end
  end

  test "GIT-8/CLI-7 restores the saved index and reports an interrupted startup", %{suite: suite} do
    context = fixture!(suite, [])
    configure_startup!(context, "setup", "touch .kogen/local/startup-waiting; sleep 600")
    before = state(context)
    arm!(context)
    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/startup-waiting"))
    Helpers.signal!(context, port, "INT")
    {output, status} = Helpers.await_exit(port, "", 15_000)

    assert status == 130, output
    assert output =~ "stopped fixture: interrupted"
    assert state(context) == before
    assert File.read!(Path.join(context.repo, "app.txt")) == "startup edit\n"
    assert length(FakeProvider.provider_requests(context.server)) == 1
    assert result(context)["outcome"] == "interrupted"
  end

  test "CLI-7 undoes a commit interrupted during postcommit validation", %{suite: suite} do
    context = fixture!(suite, build_script())
    before = state(context)
    bin = Path.join(context.root, "bin")
    File.mkdir_p!(bin)
    git = System.find_executable("git")

    # Widen the real postcommit query window without changing Git's output or behavior.
    wrapper = Path.join(bin, "git")

    File.write!(wrapper, """
    #!/bin/sh
    if [ "$1" = cat-file ] && [ "$2" = commit ]; then
      touch .kogen/local/postcommit-waiting
      while [ ! -f .kogen/local/release-query ]; do sleep 0.02; done
    fi
    exec #{Kogen.Init.shell_quote(git)} "$@"
    """)

    File.chmod!(wrapper, 0o755)

    port =
      Helpers.start_kogen(context, ["intent", "build", "fixture"],
        env: [{"PATH", bin <> ":" <> context.env["PATH"]}]
      )

    Helpers.wait_for_file!(Path.join(context.repo, ".kogen/local/postcommit-waiting"))
    Helpers.signal!(context, port, "INT")
    Process.sleep(200)
    File.write!(Path.join(context.repo, ".kogen/local/release-query"), "")
    {output, status} = Helpers.await_exit(port, "", 15_000)

    assert status == 130, output
    assert output =~ "stopped fixture: interrupted"
    refute output =~ "landed fixture"
    assert state(context) == before
    assert File.exists?(Path.join(context.repo, ".kogen/local/approvals/fixture.json"))
    assert File.read!(Path.join(context.repo, "app.txt")) == "verified edit\n"
    assert result(context)["outcome"] == "interrupted"
  end

  test "VER-10/GIT-4 excludes new siblings in another uncommitted Intent folder", %{suite: suite} do
    extra =
      {:function, "write_file",
       %{"path" => ".kogen/intents/staged/new.md", "content" => "new unrelated draft\n"}}

    context = fixture!(suite, List.insert_at(build_script(), 2, extra))
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 0, output
    assert output =~ "landed fixture"
    committed = git_value!(context, ["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"])
    assert "app.txt" in String.split(committed, "\n")
    refute committed =~ ".kogen/intents/staged/"

    assert File.read!(Path.join(context.repo, ".kogen/intents/staged/draft.md")) ==
             "caller staged this Intent\n"

    assert File.read!(Path.join(context.repo, ".kogen/intents/staged/new.md")) ==
             "new unrelated draft\n"
  end

  test "AUT-2 stops a preflight hook that changes the approved baseline", %{suite: suite} do
    context = fixture!(suite, build_script())
    before = state(context)
    steps = Path.join(context.repo, "features/steps/integration_steps.js")
    approved = File.read!(steps)

    commit_msg_hook!(
      context,
      "printf '\\n// changed by preflight\\n' >> features/steps/integration_steps.js\ngit add features/steps/integration_steps.js\n"
    )

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 1, output
    assert output =~ "baseline_changed"
    assert state(context) == before
    assert File.read!(steps) != approved
    assert length(FakeProvider.provider_requests(context.server)) == 1
  end

  test "GIT-8 restores the original index when a staging preflight hook rejects", %{suite: suite} do
    context = fixture!(suite, [])
    before = state(context)
    commit_msg_hook!(context, "printf 'hook edit\\n' > app.txt\ngit add app.txt\nexit 12\n")

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 3, output
    assert output =~ "environment/commit_rejected"
    assert state(context) == before
    assert File.read!(Path.join(context.repo, "app.txt")) == "hook edit\n"
    assert length(FakeProvider.provider_requests(context.server)) == 1
  end

  test "GIT-1 rejects a staged rename from outside the allowed Intent paths", %{suite: suite} do
    context = fixture!(suite, build_script())
    Helpers.git!(context, ["mv", "README.md", ".kogen/intents/staged/original-readme.md"])
    before = state(context)

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 5, output
    assert output =~ "environment/dirty_tree"
    assert state(context) == before
    assert length(FakeProvider.provider_requests(context.server)) == 1
  end

  test "CLI-9 records a successful large Unicode startup check and continues", %{suite: suite} do
    context = fixture!(suite, build_script())

    configure_startup!(
      context,
      "checks",
      "node -e \"process.stdout.write('€'.repeat(400000))\"",
      false
    )

    arm!(context)

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 0, output
    assert output =~ "landed fixture"

    events =
      Helpers.run_log(context)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    event = Enum.find(events, &(&1["event"] == "command_result" and &1["name"] == "startup"))
    assert event["status"] == 0
    assert String.valid?(event["output"])
    assert byte_size(event["output"]) <= 1_048_576
    assert event["output"] =~ "cut in the run log"
  end

  defp commit_msg_hook!(context, command) do
    path = Helpers.write_hook!(context, "exit 0\n") |> Path.dirname() |> Path.join("commit-msg")
    File.write!(path, "#!/bin/sh\n" <> command)
    File.chmod!(path, 0o755)
  end

  defp fixture!(suite, script) do
    context = Helpers.project!(suite, script)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    context
  end

  defp configure_startup!(context, stage, ending, edit \\ true) do
    command =
      "if test -f .kogen/local/arm; then printf 'startup edit\\n' > app.txt; git add app.txt; #{ending}; fi"

    command = if edit, do: command, else: ending
    quoted = "'" <> String.replace(command, "'", "''") <> "'"
    value = if stage == "setup", do: quoted, else: "{name: startup, run: #{quoted}}"
    config = Path.join(context.repo, ".kogen/project.yaml")

    File.write!(
      config,
      String.replace(File.read!(config), "  #{stage}: []", "  #{stage}: [#{value}]")
    )

    Helpers.git!(context, [
      "commit",
      "-q",
      "--only",
      "-m",
      "configure startup probe",
      "--",
      ".kogen/project.yaml"
    ])

    {card, 5} = Helpers.run_kogen(context, ["intent", "approve", "fixture"])
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)

    {output, status} =
      Helpers.run_kogen(context, ["intent", "approve", "fixture", String.slice(hash, 0, 8)])

    assert status == 0, output
  end

  defp arm!(context), do: File.write!(Path.join(context.repo, ".kogen/local/arm"), "")

  defp state(context) do
    {git_value!(context, ["rev-parse", "HEAD"]), Helpers.index_tree!(context),
     git_value!(context, ["diff", "--cached", "--binary"])}
  end

  defp result(context) do
    [path] = Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/result.json"))
    path |> File.read!() |> JSON.decode!()
  end

  defp build_script do
    [
      {:text, "Plan the fixture edit."},
      {:function, "write_file", %{"path" => "app.txt", "content" => "verified edit\n"}},
      {:function, "finish", %{"summary" => "The fixture edit is ready."}},
      {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
    ]
  end

  defp git_value!(context, args) do
    {output, 0} = Helpers.git!(context, args)
    String.trim_trailing(output, "\n")
  end
end
