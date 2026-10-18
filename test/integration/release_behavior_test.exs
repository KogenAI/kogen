Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ReleaseBehaviorTest do
  use ExUnit.Case, async: true

  alias Kogen.Integration.{FakeProvider, Helpers}

  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  @tag :runner_paths
  test "SET-10/VER-3 both generated runners preserve feature and report paths with spaces", %{
    suite: suite
  } do
    context = fixture!(suite, [], repo_name: "repo with space")
    runtime = Path.join(suite.prefix, "lib/kogen")
    node = runtime |> Path.join("node-path") |> File.read!() |> String.trim()
    modules = Path.join(runtime, "lib/cucumber/node_modules")
    File.ln_s!(modules, Path.join(context.repo, "node_modules"))
    feature = Path.join(context.repo, ".kogen/intents/fixture/acceptance.feature")

    for runner <- [:project, :kogen] do
      report = Path.join(context.repo, ".kogen/local/report #{runner}.ndjson")

      {output, status} =
        System.cmd("/bin/sh", ["-c", Kogen.Detect.acceptance_command("features/steps", runner)],
          cd: context.repo,
          env:
            Helpers.env_for(context, %{
              "KOGEN_NODE" => node,
              "KOGEN_CUCUMBER" => modules,
              "KOGEN_ACCEPTANCE_FEATURES" => feature,
              "KOGEN_ACCEPTANCE_REPORT" => report
            }),
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert File.regular?(report)
      assert File.read!(report) =~ "testCaseFinished"
    end
  end

  test "REV-4/REV-5 retries one invalid review verdict and lands after approval", %{suite: suite} do
    context =
      fixture!(suite, [
        {:function, "write_file", %{"path" => "app.txt", "content" => "verified edit\n"}},
        {:function, "finish", %{"summary" => "The fixture change is ready."}},
        {:function, "submit_review",
         %{
           "verdict" => "approve",
           "findings" => [
             %{
               "path" => "app.txt",
               "line" => 1,
               "severity" => "blocking",
               "message" => "An approve verdict cannot contain a blocking finding."
             }
           ]
         }},
        {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
      ])

    start = git_value!(context, ["rev-parse", "HEAD"])
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 0, output
    assert output =~ "landed fixture"
    assert length(FakeProvider.review_requests(context.server)) == 2
    assert git_value!(context, ["rev-parse", "HEAD"]) != start

    [_, retry] = FakeProvider.review_requests(context.server)

    assert Enum.any?(retry.json["input"], fn item ->
             item["type"] == "function_call_output" and
               String.contains?(item["output"], "invalid verdict")
           end)
  end

  test "GIT-5/GIT-8 a rejecting commit hook leaves edits and restores the staged Intent index", %{
    suite: suite
  } do
    context = fixture!(suite, editable_build_script())
    original_head = git_value!(context, ["rev-parse", "HEAD"])
    original_index = Helpers.index_tree!(context)
    original_cached_diff = git_value!(context, ["diff", "--cached", "--binary"])

    Helpers.write_hook!(context, "echo scripted rejection >&2\nexit 1\n")
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 3, output
    assert output =~ "environment/commit_failed: git commit failed"
    assert output =~ "scripted rejection"
    assert git_value!(context, ["rev-parse", "HEAD"]) == original_head
    assert Helpers.index_tree!(context) == original_index
    assert git_value!(context, ["diff", "--cached", "--binary"]) == original_cached_diff
    {staged_intent, 0} = Helpers.git!(context, ["show", ":.kogen/intents/staged/draft.md"])
    assert staged_intent == "caller staged this Intent\n"
    assert File.read!(Path.join(context.repo, "app.txt")) == "verified edit\n"
  end

  test "GIT-6/GIT-8 an editing hook is undone and the original staged Intent index is restored",
       %{suite: suite} do
    context = fixture!(suite, editable_build_script())
    original_head = git_value!(context, ["rev-parse", "HEAD"])
    original_index = Helpers.index_tree!(context)
    original_cached_diff = git_value!(context, ["diff", "--cached", "--binary"])

    Helpers.write_hook!(context, "printf 'hook edit\\n' >> app.txt\ngit add app.txt\n")
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 1, output
    assert output =~ "candidate/hook_changed_commit: a commit hook changed app.txt"
    assert git_value!(context, ["rev-parse", "HEAD"]) == original_head
    assert Helpers.index_tree!(context) == original_index
    assert git_value!(context, ["diff", "--cached", "--binary"]) == original_cached_diff
    assert File.read!(Path.join(context.repo, "app.txt")) == "verified edit\nhook edit\n"
  end

  test "GIT-8 a provider failure leaves edits and restores the staged Intent index", %{
    suite: suite
  } do
    context =
      fixture!(suite, [
        {:function, "write_file", %{"path" => "app.txt", "content" => "verified edit\n"}},
        refused_response()
      ])

    original_head = git_value!(context, ["rev-parse", "HEAD"])
    original_index = Helpers.index_tree!(context)
    original_cached_diff = git_value!(context, ["diff", "--cached", "--binary"])
    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 4
    assert output =~ "provider/refused: ChatGPT refused the request: 400"
    assert git_value!(context, ["rev-parse", "HEAD"]) == original_head
    assert Helpers.index_tree!(context) == original_index
    assert git_value!(context, ["diff", "--cached", "--binary"]) == original_cached_diff
    assert File.read!(Path.join(context.repo, "app.txt")) == "verified edit\n"
  end

  test "GIT-8/CLI-7 an interrupt leaves edits and restores the staged Intent index", %{
    suite: suite
  } do
    context =
      fixture!(suite, [
        {:function, "write_file", %{"path" => "app.txt", "content" => "verified edit\n"}},
        {:function, "shell",
         %{
           "command" =>
             "mkdir -p .kogen/local && printf started > .kogen/local/interrupt-started && sleep 600"
         }}
      ])

    marker = Path.join(context.repo, ".kogen/local/interrupt-started")

    original_head = git_value!(context, ["rev-parse", "HEAD"])
    original_index = Helpers.index_tree!(context)
    original_cached_diff = git_value!(context, ["diff", "--cached", "--binary"])
    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])
    Helpers.wait_for_file!(marker)
    Helpers.signal!(context, port, "INT")
    {output, status} = Helpers.await_exit(port, "", 15_000)

    assert status == 130
    assert output =~ "stopped fixture: interrupted"
    assert git_value!(context, ["rev-parse", "HEAD"]) == original_head
    assert Helpers.index_tree!(context) == original_index
    assert git_value!(context, ["diff", "--cached", "--binary"]) == original_cached_diff
    assert File.read!(Path.join(context.repo, "app.txt")) == "verified edit\n"
  end

  test "GPT-3/GPT-6 a stale credentials lock is removed before refresh", %{suite: suite} do
    context = fixture!(suite, [refused_response()])
    Helpers.seed_credentials!(context, :expired)
    lock = Path.join(context.home, ".kogen/credentials/chatgpt.lock")
    File.write!(lock, "2147483647\n")

    {_output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])

    assert status == 4
    assert length(FakeProvider.auth_requests(context.server)) == 1
    assert not File.exists?(lock)
    assert saved_credentials(context)["refresh_token"] == "fake-rotated-refresh-token"

    assert hd(FakeProvider.auth_requests(context.server)).json["refresh_token"] ==
             "fake-integration-refresh-token"
  end

  test "GPT-3/GPT-6 a live credentials lock makes refresh wait until it is released", %{
    suite: suite
  } do
    context = fixture!(suite, [refused_response()])
    Helpers.seed_credentials!(context, :expired)
    lock = Path.join(context.home, ".kogen/credentials/chatgpt.lock")
    File.write!(lock, System.pid() <> "\n")
    port = Helpers.start_kogen(context, ["intent", "build", "fixture"])

    _output = Helpers.await_output(port, "kogen: building (round 1)")
    Process.sleep(250)
    assert File.exists?(lock)
    assert FakeProvider.auth_requests(context.server) == []

    File.rm!(lock)
    {output, status} = Helpers.await_exit(port, "", 20_000)

    assert status == 4, output
    assert length(FakeProvider.auth_requests(context.server)) == 1
    assert saved_credentials(context)["refresh_token"] == "fake-rotated-refresh-token"
  end

  test "CLI-9 UTF-8 output survives the bridge and an invalid byte becomes U+FFFD, UTF-8 locale",
       %{suite: suite} do
    {actual, expected} = protocol_bytes_case!(suite, "en_US.UTF-8")
    assert actual == expected
  end

  test "CLI-9 UTF-8 output survives the bridge and an invalid byte becomes U+FFFD, no LANG", %{
    suite: suite
  } do
    {actual, expected} = protocol_bytes_case!(suite, nil)
    assert actual == expected
  end

  test "CLI-4 the core starts from a folder holding one-letter file names", %{suite: suite} do
    context = fixture!(suite, [])
    folder = Path.join(context.root, "letters")
    File.mkdir_p!(folder)
    Enum.each(?a..?z, &File.write!(Path.join(folder, <<&1>>), ""))

    {output, status} = Helpers.run_kogen(context, ["provider", "list"], cd: folder)

    assert status == 0, output
    assert output =~ ~r/\Achatgpt: signed in\b/
  end

  defp protocol_bytes_case!(suite, lang) do
    command = ~S(printf 'münchen 東京 \377\n')

    context =
      fixture!(
        suite,
        [
          {:function, "shell", %{"command" => command}},
          {:function, "finish", %{"summary" => "The command probe is complete."}},
          approve_review()
        ],
        lang: lang
      )

    {output, status} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert status == 0, output

    # JSON carries text: valid UTF-8 arrives byte for byte, an invalid byte as U+FFFD (CLI-9).
    expected = "exit status: 0\n" <> "münchen 東京 \uFFFD\n"

    tool_result =
      Enum.find(
        FakeProvider.tool_outputs(context.server),
        &String.starts_with?(&1, "exit status: 0\n")
      )

    [log_line] =
      context
      |> Helpers.run_log()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&(&1["event"] == "tool_call" and &1["name"] == "shell"))

    actual_log = log_line["result"]

    {{tool_result, actual_log}, {expected, expected}}
  end

  defp fixture!(suite, script, opts \\ []) do
    context = Helpers.project!(suite, script, opts)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    context
  end

  defp editable_build_script do
    [
      {:function, "write_file", %{"path" => "app.txt", "content" => "verified edit\n"}},
      {:function, "finish", %{"summary" => "The fixture edit is ready."}},
      approve_review()
    ]
  end

  defp approve_review do
    {:function, "submit_review", %{"verdict" => "approve", "findings" => []}}
  end

  defp refused_response do
    {:http, 400,
     %{"error" => %{"message" => "scripted provider refusal", "code" => "invalid_request_error"}}}
  end

  defp git_value!(context, args) do
    {output, 0} = Helpers.git!(context, args)
    String.trim_trailing(output, "\n")
  end

  defp saved_credentials(context) do
    context.home
    |> Path.join(".kogen/credentials/chatgpt.json")
    |> File.read!()
    |> JSON.decode!()
  end
end
