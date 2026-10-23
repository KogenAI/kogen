Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ContractRegressionsTest do
  use ExUnit.Case, async: true, group: :installed_release

  alias Kogen.{Config, Integration.FakeProvider, Integration.Helpers}

  @moduletag :integration
  @moduletag timeout: 300_000

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "SHP-10 probe progress reports status without echoing tool output", %{suite: suite} do
    context =
      fixture!(suite, [
        {:function, "probe", %{"command" => "cat probe-output.txt; exit 7"}},
        {:function, "submit", %{"questions" => [%{"question" => "Continue?"}]}}
      ])

    File.write!(Path.join(context.repo, "probe-output.txt"), "private fixture probe output")
    request = Path.join(context.root, "request.txt")
    File.write!(request, "Check feasibility before asking about display.")
    {output, status} = Helpers.run_kogen(context, ["intent", "shape", "probe-progress", request])
    assert status == 5, output
    assert output =~ "kogen: probe result: exit status: 7; timed_out: false; wall:"
    refute output =~ "private fixture probe output"

    assert FakeProvider.tool_outputs(context.server)
           |> Enum.any?(&String.contains?(&1, "private fixture probe output"))
  end

  test "SHP-2 quoted executable paths and assignment values pass tool lookup without execution",
       %{suite: suite} do
    question = %{"question" => "Which display?"}

    context =
      fixture!(suite, List.duplicate({:function, "submit", %{"questions" => [question]}}, 4))

    config_path = Path.join(context.repo, Config.path())
    config = Config.load!(context.repo)
    tool = Path.join(context.repo, "check tool")
    File.write!(tool, "#!/bin/sh\nprintf executed > check-was-run\n")
    File.chmod!(tool, 0o755)
    request = Path.join(context.root, "request.txt")
    File.write!(request, "Add a display choice.")

    commands = [
      ~s("/usr/bin/true"),
      ~s("./check tool"),
      ~s(LABEL="two words" /usr/bin/true),
      ~s(./check\\ tool)
    ]

    for {command, index} <- Enum.with_index(commands) do
      File.write!(
        config_path,
        Config.render(%{
          setup: [],
          fix: [],
          checks: [%{name: "quoted", run: command}],
          protect: [],
          acceptance: %{run: config.acceptance_run, steps_dir: config.steps_dir}
        })
      )

      {output, status} =
        Helpers.run_kogen(context, ["intent", "shape", "quoted-#{index}", request])

      assert status == 5, output
      assert output =~ "Which display?"
      refute File.exists?(Path.join(context.repo, "check-was-run"))
    end

    assert length(FakeProvider.provider_requests(context.server)) == 5
  end

  test "SET-4 init rejects ignored legacy configuration before login or writes", %{suite: suite} do
    context = fixture!(suite, [])
    Helpers.git!(context, ["rm", "--cached", Config.path()])
    Helpers.git!(context, ["commit", "-qm", "Remove configuration"])
    File.write!(Path.join(context.repo, ".gitignore"), ".kogen/\n")
    Helpers.git!(context, ["add", ".gitignore"])
    Helpers.git!(context, ["commit", "-qm", "Ignore local configuration"])
    legacy = "# Keep this legacy configuration\ncommands: {}\n"
    path = Path.join(context.repo, Config.path())
    File.write!(path, legacy)
    {head, 0} = Helpers.git!(context, ["rev-parse", "HEAD"])
    index = Helpers.index_tree!(context)

    for logged_in <- [false, true] do
      if logged_in,
        do: Helpers.seed_credentials!(context),
        else: File.rm!(Path.join(context.home, ".kogen/credentials/chatgpt.json"))

      {output, status} = Helpers.run_kogen(context, ["init"])
      assert status == 3, output
      assert output =~ "environment/old_kogen_config"
      assert File.read!(path) == legacy
      assert Helpers.git!(context, ["rev-parse", "HEAD"]) == {head, 0}
      assert Helpers.index_tree!(context) == index
    end

    assert length(FakeProvider.provider_requests(context.server)) == 1
  end

  test "SHP-4 invalid question options receive correction feedback and are never persisted", %{
    suite: suite
  } do
    malformed = [
      "malformed array",
      %{},
      nil,
      ["option"],
      [%{}],
      [%{"label" => 1}],
      [%{"label" => "One", "recommended" => "yes"}]
    ]

    valid = [
      %{"question" => "Any preference?"},
      %{"question" => "Which display?", "options" => []},
      %{
        "question" => "Which order?",
        "options" => [
          %{"label" => "Newest", "recommended" => true},
          %{"label" => "Oldest", "recommended" => false},
          %{"label" => "Other"}
        ]
      }
    ]

    script =
      Enum.flat_map(malformed, fn options ->
        List.duplicate(
          {:function, "submit",
           %{"questions" => [%{"question" => "Which display?", "options" => options}]}},
          3
        )
      end) ++ [{:function, "submit", %{"questions" => valid}}]

    context = fixture!(suite, script)
    request = Path.join(context.root, "request.txt")
    File.write!(request, "Add a display choice.")
    state = Path.join(context.repo, ".kogen/local/shaping/options/state.json")

    for _ <- malformed do
      {output, status} = Helpers.run_kogen(context, ["intent", "shape", "options", request])
      assert status == 1, output
      assert output =~ "shape/invalid_output"
      refute File.exists?(state)
    end

    {output, status} = Helpers.run_kogen(context, ["intent", "shape", "options", request])
    assert status == 5, output
    assert output =~ "Newest (recommended)"

    assert JSON.decode!(File.read!(state))["rounds"] == [
             %{"questions" => valid, "answers" => %{}}
           ]

    requests = FakeProvider.provider_requests(context.server)
    assert length(requests) == 23
    assert Enum.any?(FakeProvider.tool_outputs(context.server), &String.contains?(&1, "options"))
    # The request text again is no answer (SHP-6): refused without a model request.
    {again, 2} = Helpers.run_kogen(context, ["intent", "shape", "options", request])
    assert again =~ "intent/answers_invalid"
    assert FakeProvider.provider_requests(context.server) == requests
  end

  test "SHP-4 blocked submissions require an actual protected path and a reason", %{suite: suite} do
    invalid = [
      %{"blocked" => %{"paths" => [], "reason" => "required edit"}},
      %{"blocked" => %{"paths" => ["README.md"], "reason" => "  "}},
      %{"blocked" => %{"paths" => ["app.txt"], "reason" => "required edit"}}
    ]

    script =
      Enum.flat_map(invalid, fn submission ->
        [
          {:function, "submit", submission},
          {:function, "submit", %{"questions" => [%{"question" => "Continue?"}]}}
        ]
      end)

    context = fixture!(suite, script)
    request = Path.join(context.root, "request.txt")
    File.write!(request, "Make a protected change.")

    for {slug, expected} <-
          Enum.zip(~w(bad-paths bad-reason unprotected), [
            "blocked.paths must be a non-empty list",
            "blocked.reason must be non-empty text",
            "blocked path app.txt is not protected by the current contract"
          ]) do
      {output, status} = Helpers.run_kogen(context, ["intent", "shape", slug, request])
      assert status == 5, output
      assert output =~ "Continue?"

      assert FakeProvider.tool_outputs(context.server)
             |> Enum.any?(&String.contains?(&1, expected))

      refute File.exists?(Path.join(context.repo, ".kogen/intents/#{slug}/intent.md"))
      refute File.exists?(Path.join(context.repo, ".kogen/local/approvals/#{slug}.json"))
    end
  end

  test "SHP-4 blocked reports recognize protected paths matched by a glob", %{suite: suite} do
    submission = %{
      "blocked" => %{
        "paths" => ["settings/check.cfg"],
        "reason" => "the requested verification definition cannot be changed in Build"
      }
    }

    context = fixture!(suite, [{:function, "submit", submission}])
    settings = Path.join(context.repo, "settings/check.cfg")
    File.mkdir_p!(Path.dirname(settings))
    File.write!(settings, "strict=true\n")
    config = Config.load!(context.repo)

    File.write!(
      Path.join(context.repo, Config.path()),
      Config.render(%{
        setup: config.setup,
        fix: config.fix,
        checks: config.checks,
        protect: ["settings/*.cfg"],
        acceptance: %{run: config.acceptance_run, steps_dir: config.steps_dir}
      })
    )

    Helpers.git!(context, ["add", "settings/check.cfg", Config.path()])
    Helpers.git!(context, ["commit", "-qm", "Configure protected glob"])
    request = Path.join(context.root, "request.txt")
    File.write!(request, "Change the protected check definition.")

    {output, status} = Helpers.run_kogen(context, ["intent", "shape", "glob-conflict", request])
    assert status == 1, output

    assert output =~
             "shape/protected_conflict: required edits touch protected files: settings/check.cfg"

    assert output =~ "the requested verification definition cannot be changed in Build"

    assert output =~
             "Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override."

    assert length(FakeProvider.provider_requests(context.server)) == 2
    refute File.exists?(Path.join(context.repo, ".kogen/intents/glob-conflict/intent.md"))
    refute File.exists?(Path.join(context.repo, ".kogen/local/approvals/glob-conflict.json"))
    refute File.dir?(Path.join(context.repo, ".kogen/local/runs"))
  end

  test "REL-3 self-build gate runs the maintained suite and propagates its failure", %{
    suite: suite
  } do
    context = fixture!(suite, [])

    destination = Path.join(context.repo, "test/suite.sh")
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(Path.join(Helpers.project_root(), "test/suite.sh"), destination)

    # The real suite must reject this candidate before reaching the installed scenarios: the
    # archive the gate hands it does not exist.
    source = File.read!(Path.join(Helpers.project_root(), "test/live/self-build-check.sh"))
    [_, gate] = String.split(source, ~s(say "packaged $archive"), parts: 2)
    [gate, _] = String.split(gate, ~s(mkdir -p "$work/extract"), parts: 2)
    script = Path.join(context.root, "suite-gate.sh")

    File.write!(
      script,
      "set -eu\nwork=\"$1\"\narchive=missing-archive.tar.gz\nsay() { printf '%s\\n' \"$*\"; }\n" <>
        gate
    )

    {output, status} =
      System.cmd("/bin/sh", [script, context.root],
        cd: context.repo,
        env: Helpers.env_for(context),
        stderr_to_stdout: true
      )

    assert status == 1, output
    assert output =~ "suite: archive not found: missing-archive.tar.gz"
    assert output =~ "FAIL: the self-built deterministic suite"
    refute output =~ "ok: the self-built deterministic suite passes"
  end

  test "REL-3 observation rejects an installed release whose core is unavailable", %{suite: suite} do
    context = fixture!(suite, [])
    source = File.read!(Path.join(Helpers.project_root(), "test/live/self-build-check.sh"))
    [_, observation] = String.split(source, "\nset +e\n", parts: 2)
    script = Path.join(context.root, "observe.sh")
    File.ln_s!(suite.prefix, Path.join(context.root, "prefix"))

    File.write!(
      script,
      "set -eu\nwork=\"$1\"\nsay() { printf '%s\\n' \"$*\"; }\nset +e\n" <> observation
    )

    core = Path.join(suite.prefix, "lib/kogen/lib/release/bin/kogen")
    File.rename!(core, core <> ".parked")

    try do
      {output, status} =
        System.cmd("/bin/sh", [script, context.root],
          env: Helpers.env_for(context),
          stderr_to_stdout: true
        )

      assert status == 1, output
      assert output =~ "environment/core_unavailable"
      refute output =~ "ok: the change is observed"
    after
      File.rename!(core <> ".parked", core)
    end
  end

  test "REL-3 disposable self repositories leave source HEAD, index and edits untouched", %{
    suite: suite
  } do
    context = fixture!(suite, [])
    source_script = Path.join(context.repo, "test/live/self-repo.sh")
    File.mkdir_p!(Path.dirname(source_script))
    File.cp!(Path.join(Helpers.project_root(), "test/live/self-repo.sh"), source_script)
    Helpers.git!(context, ["add", "test/live/self-repo.sh"])
    Helpers.git!(context, ["commit", "-qm", "Add self repository setup"])
    worktree = Path.join(context.root, "worktree")
    Helpers.git!(context, ["worktree", "add", "-qb", "candidate", worktree])

    for {source, index} <- Enum.with_index([context.repo, worktree]) do
      git = fn args ->
        {output, 0} =
          System.cmd("git", ["-C", source | args],
            env: Helpers.env_for(context),
            stderr_to_stdout: true
          )

        output
      end

      File.write!(Path.join(source, "app.txt"), "staged candidate\n")
      git.(["add", "app.txt"])
      File.write!(Path.join(source, "README.md"), "Uncommitted candidate\n")
      before_head = git.(["rev-parse", "HEAD"])
      before_index = git.(["write-tree"])
      before_status = git.(["status", "--porcelain"])
      destination = Path.join(context.root, "disposable-#{index}")

      {output, status} =
        System.cmd("/bin/sh", [Path.join(source, "test/live/self-repo.sh"), destination],
          cd: source,
          env:
            Helpers.env_for(context, %{
              "GIT_AUTHOR_NAME" => "Fixture",
              "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
              "GIT_COMMITTER_NAME" => "Fixture",
              "GIT_COMMITTER_EMAIL" => "fixture@example.invalid"
            }),
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert File.dir?(Path.join(destination, ".git"))
      assert git.(["rev-parse", "HEAD"]) == before_head
      assert git.(["write-tree"]) == before_index
      assert git.(["status", "--porcelain"]) == before_status
      assert File.read!(Path.join(destination, "README.md")) == "Uncommitted candidate\n"
      assert File.read!(Path.join(destination, "app.txt")) == "staged candidate\n"

      assert {"", 0} =
               System.cmd("git", ["-C", destination, "status", "--porcelain"],
                 env: Helpers.env_for(context)
               )

      {committed, 0} =
        System.cmd("git", ["-C", destination, "show", "HEAD:README.md"],
          env: Helpers.env_for(context)
        )

      assert committed == "Uncommitted candidate\n"
    end
  end

  defp fixture!(suite, script) do
    context = Helpers.project!(suite, script, staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    context
  end
end
