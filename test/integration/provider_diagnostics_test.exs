Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.ProviderDiagnosticsTest do
  use ExUnit.Case, async: true
  alias Kogen.{Config, Intent, Integration.FakeProvider, Integration.Helpers}
  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "GPT-8 unknown structured stream failure retains safe fields in refinement evidence", %{
    suite: suite
  } do
    error = %{
      "code" => "unknown_overload",
      "type" => "provider_capacity",
      "message" => "structured overload",
      "access_token" => "SECRET-TOKEN-MARKER",
      "request" => "PRIVATE-PAYLOAD-MARKER"
    }

    context = fixture!(suite, [failed(error)])
    before = authority(context)
    request = Path.join(context.root, "correction.txt")
    File.write!(request, "Clarify the existing title.")

    hash =
      Intent.hash(
        context.repo,
        Intent.baseline(context.repo, "fixture", Config.load!(context.repo))
      )

    {output, 4} = Helpers.run_kogen(context, ["intent", "refine", "fixture", hash, request])
    assert output =~ "provider/refused"
    assert output =~ "unknown_overload"
    assert output =~ "provider_capacity"
    assert output =~ "response.failed"
    assert authority(context) == before
    [path] = Path.wildcard(Path.join(context.repo, ".kogen/local/refinements/*/result.json"))
    result = JSON.decode!(File.read!(path))

    assert result["provider_failure"] == %{
             "code" => "unknown_overload",
             "type" => "provider_capacity",
             "event_kind" => "response.failed"
           }

    refute output <> File.read!(path) =~ "SECRET-TOKEN-MARKER"
    refute output <> File.read!(path) =~ "PRIVATE-PAYLOAD-MARKER"
    assert length(FakeProvider.provider_requests(context.server)) == 2
  end

  test "GPT-8 HTTP failure metadata reaches Build result and log without request payload", %{
    suite: suite
  } do
    context =
      fixture!(suite, [
        {:function, "write_file", %{"path" => "app.txt", "content" => "preserved candidate\n"}},
        {:http, 400,
         %{
           "error" => %{
             "code" => "unknown_http_code",
             "type" => "invalid_request",
             "message" => "structured HTTP failure",
             "authorization" => "SECRET-AUTH-MARKER"
           }
         }}
      ])

    before = authority(context)
    {output, 4} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "provider/refused: ChatGPT refused the request: 400"
    expected = %{"code" => "unknown_http_code", "type" => "invalid_request", "http_status" => 400}
    assert result(context)["provider_failure"] == expected
    assert File.read!(Path.join(context.repo, "app.txt")) == "preserved candidate\n"
    assert authority(context) == before
    log = File.read!(Helpers.run_log(context))
    assert log =~ "unknown_http_code"

    outcome =
      log
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.find(&(&1["event"] == "outcome"))

    assert outcome["event"] == "outcome"
    assert outcome["provider_failure"] == expected
    refute log <> output =~ "SECRET-AUTH-MARKER"
    assert result(context)["passes"] == 0
  end

  test "GPT-8 known structured transients keep three attempts and final diagnostics", %{
    suite: suite
  } do
    failure =
      failed(%{"code" => "server_error", "type" => "capacity", "message" => "known transient"})

    context = fixture!(suite, List.duplicate(failure, 3))
    {output, 4} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "provider/unavailable: ChatGPT did not answer after 3 attempts"

    assert result(context)["provider_failure"] == %{
             "code" => "server_error",
             "type" => "capacity",
             "event_kind" => "response.failed"
           }

    assert length(FakeProvider.provider_requests(context.server)) == 4
    assert result(context)["passes"] == 0
  end

  test "GPT-8 no-code and malformed stream error fields remain safe diagnostic fallbacks", %{
    suite: suite
  } do
    for error <- [
          %{"message" => "no-code failure"},
          "malformed error",
          %{
            "code" => %{"bad" => "PRIVATE-MARKER"},
            "type" => ["PRIVATE-MARKER"],
            "message" => %{}
          }
        ] do
      context = fixture!(suite, [{:events, [%{"type" => "error", "error" => error}]}])
      {output, 4} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
      assert output =~ "provider/refused"
      assert result(context)["provider_failure"] == %{"event_kind" => "error"}
      refute output =~ "PRIVATE-MARKER"
      assert length(FakeProvider.provider_requests(context.server)) == 2
    end
  end

  test "GPT-8 context and login wrappers preserve known response metadata without changing exits",
       %{suite: suite} do
    context =
      fixture!(suite, [
        failed(%{
          "code" => "context_length_exceeded",
          "type" => "request_error",
          "message" => "context limit"
        })
      ])

    {output, 1} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "candidate/context_exhausted"

    assert result(context)["provider_failure"] == %{
             "code" => "context_length_exceeded",
             "type" => "request_error",
             "event_kind" => "response.failed"
           }

    assert length(FakeProvider.provider_requests(context.server)) == 2

    unauthorized =
      {:http, 401,
       %{
         "error" => %{
           "code" => "unauthorized",
           "type" => "authentication_error",
           "message" => "rejected"
         }
       }}

    context = fixture!(suite, [unauthorized, unauthorized])
    {output, 4} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "provider/login: the ChatGPT sign-in was rejected"

    assert result(context)["provider_failure"] == %{
             "code" => "unauthorized",
             "type" => "authentication_error",
             "http_status" => 401
           }

    assert length(FakeProvider.auth_requests(context.server)) == 1
    assert length(FakeProvider.provider_requests(context.server)) == 3
  end

  test "GPT-8 a flat error event retains code and event kind without inventing an error subtype",
       %{suite: suite} do
    context =
      fixture!(suite, [
        {:events,
         [
           %{
             "type" => "error",
             "code" => "unknown_flat_code",
             "message" => "flat failure",
             "request" => "PRIVATE-FLAT-MARKER"
           }
         ]}
      ])

    {output, 4} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "provider/refused"

    assert result(context)["provider_failure"] == %{
             "code" => "unknown_flat_code",
             "event_kind" => "error"
           }

    refute output <> File.read!(Helpers.run_log(context)) =~ "PRIVATE-FLAT-MARKER"
    assert length(FakeProvider.provider_requests(context.server)) == 2
  end

  test "GPT-8 incomplete stream diagnostics do not present an internal marker as provider code",
       %{
         suite: suite
       } do
    context =
      fixture!(suite, [
        {:events,
         [
           %{
             "type" => "response.incomplete",
             "response" => %{"incomplete_details" => %{"reason" => "max_output_tokens"}}
           }
         ]}
      ])

    {output, 4} = Helpers.run_kogen(context, ["intent", "build", "fixture"])
    assert output =~ "provider/refused"
    assert result(context)["provider_failure"] == %{"event_kind" => "response.incomplete"}
    assert length(FakeProvider.provider_requests(context.server)) == 2
  end

  defp failed(error),
    do: {:events, [%{"type" => "response.failed", "response" => %{"error" => error}}]}

  defp fixture!(suite, script) do
    context = Helpers.project!(suite, script)
    on_exit(fn -> Helpers.cleanup_case(context) end)
    context
  end

  defp authority(context),
    do:
      {Kogen.Git.head(context.repo), File.read!(Path.join(context.repo, ".git/index")),
       File.read!(Intent.approval_path(context.repo, "fixture"))}

  defp result(context) do
    [path] = Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/result.json"))
    path |> File.read!() |> JSON.decode!()
  end
end
