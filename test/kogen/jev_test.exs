Code.require_file("../support/fake_jev.ex", __DIR__)
Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.JevTest do
  @moduledoc """
  The TypeSafe Jev client through injected fake transports and an offline
  Keychain lookup: exact request bytes, key handling, the retry and timeout
  policy, retained evidence, answer validation, advisory labels, the
  calibrated objection threshold, and the offline network guard.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.FakeJev
  alias Kogen.Jev

  @root Path.expand("../..", __DIR__)

  @items [
    %{"kind" => "scenario", "id" => "s1"},
    %{"kind" => "risk", "id" => "r1"},
    %{"kind" => "finding", "id" => "F1"}
  ]

  # The calibrated v2 wording, copied from the Approved Intent's
  # evidence/jev-probe/prose_v2.py.
  @status_criteria %{
    "unfinished" =>
      "The Developer states that implementation work it owns for this item is still missing, partial, stubbed or not yet done in this Candidate.",
    "done" => "The Developer presents its own work for this item as complete.",
    "pending_external" =>
      "The Developer's own work is complete; what remains is verification, review, a live/paid run, or approval owned by Kogen, a Reviewer, the owner or another party.",
    "resolved_or_historical" =>
      "The notes mention incompleteness only as past history, an earlier attempt, retained evidence, or something since fixed.",
    "objection_only" =>
      "The Developer says this item cannot be met as approved (contract defect), rather than simply unfinished.",
    "unclear" => "The notes do not say, or are contradictory."
  }

  @objection_criteria %{
    "objection" =>
      "The Developer says the approved contract for this item cannot be met as written: a required change is outside the allowed or guarded paths, requirements contradict, the proof cannot observe it, an assumption of the approved Intent is false, or it needs a Shaping decision.",
    "no_objection" =>
      "The notes raise no contract objection for this item. Unfinished work, pending verification or ordinary difficulties are not objections.",
    "unclear" => "The notes are ambiguous about whether the contract itself is at fault."
  }

  test "the request is one pinned systemone POST with verbatim notes, item IDs and calibrated v2 wording" do
    notes = "Scenario s1 is done.\n\"Quoted\" text, unicode ✓, and ``` fences."

    outcome =
      Jev.read_notes(notes, @items,
        transport: FakeJev.transport([{200, FakeJev.answer_body(@items)}]),
        security: FakeJev.security_path()
      )

    assert_received {:jev_request, request}
    refute_received {:jev_request, _second}
    assert request.url == "https://api.typesafe.ai/v1/systemone"
    assert request.timeout == 60_000
    assert Jev.timeout_ms() == 60_000

    body = Jason.decode!(request.body, objects: :ordered_objects)
    assert body.values |> Enum.map(&elem(&1, 0)) == ["model", "state", "questions"]
    decoded = Jason.decode!(request.body)
    assert decoded["model"] == "jev-1.13.0"
    assert Jev.model() == "jev-1.13.0"
    assert decoded["state"] == %{"developer_notes" => notes, "items" => @items}

    assert Map.keys(decoded["questions"]) |> Enum.sort() ==
             Enum.sort([
               "status:s1",
               "objection:scenario:s1",
               "objection:risk:r1",
               "objection:finding:F1"
             ])

    status = decoded["questions"]["status:s1"]
    assert status["type"] == "choice"
    assert status["criteria"] == @status_criteria

    assert status["instructions"] == %{
             "task" =>
               "According to developer_notes, what is the state of the Developer's own work on scenario `s1`?",
             "rules" => [
               "Judge only what the notes literally state about this item; do not judge code.",
               "Pending verification, review or live runs owned by someone else is pending_external, not unfinished.",
               "Past or fixed incompleteness is resolved_or_historical."
             ]
           }

    for {kind, id} <- [{"scenario", "s1"}, {"risk", "r1"}, {"finding", "F1"}] do
      question = decoded["questions"]["objection:#{kind}:#{id}"]
      assert question["criteria"] == @objection_criteria

      assert question["instructions"] == %{
               "task" =>
                 "According to developer_notes, does the Developer object that the approved contract for #{kind} `#{id}` cannot be met as written?",
               "rules" => [
                 "Judge only what the notes state about this item.",
                 "Unfinished work alone is not an objection."
               ]
             }
    end

    # No diff, code or controller report is ever sent.
    refute request.body =~ "diff --git"
    assert request.body == Jev.request_body(notes, @items)

    assert outcome["outcome"] == "answered"
    assert outcome["request"]["body"] == request.body
    assert outcome["request"]["sha256"] == sha256(request.body)
    assert outcome["request"]["byte_count"] == byte_size(request.body)

    assert [%{"status" => 200, "response_body" => _body, "latency_ms" => _ms}] =
             outcome["exchanges"]

    assert outcome["usage"] == %{"input_tokens" => 100, "output_tokens" => 0}
  end

  test "the key is read from the Keychain at call time and used only in the Bearer header" do
    log = Path.join(System.tmp_dir!(), "kogen-security-log-#{System.unique_integer([:positive])}")
    System.put_env("FAKE_SECURITY_LOG", log)
    on_exit(fn -> File.rm(log) end)

    outcome =
      Jev.read_notes("notes", @items,
        transport: FakeJev.transport([{200, FakeJev.answer_body(@items)}]),
        security: FakeJev.security_path()
      )

    assert_received {:jev_request, request}

    assert request.headers == [
             {"authorization", "Bearer " <> FakeJev.sentinel_key()},
             {"content-type", "application/json"}
           ]

    refute request.body =~ FakeJev.sentinel_key()
    assert File.read!(log) == "find-generic-password -s ai.typesafe.api -w\n"
    refute inspect(outcome) =~ FakeJev.sentinel_key()
    refute Jason.encode!(outcome) =~ FakeJev.sentinel_key()
  end

  test "the Build precondition only tests that the Keychain item exists, never reading it" do
    log = Path.join(System.tmp_dir!(), "kogen-security-log-#{System.unique_integer([:positive])}")
    System.put_env("FAKE_SECURITY_LOG", log)
    on_exit(fn -> File.rm(log) end)

    assert :ok = Jev.key_present(security: FakeJev.security_path())
    assert File.read!(log) == "find-generic-password -s ai.typesafe.api\n"
    refute File.read!(log) =~ "-w"

    System.put_env("FAKE_SECURITY_ITEM", "missing")
    assert {:error, reason} = Jev.key_present(security: FakeJev.security_path())
    assert reason =~ "`ai.typesafe.api`"
    assert reason =~ "security add-generic-password -s ai.typesafe.api -a <account> -w"
    assert reason =~ "stops before launch"

    assert {:error, _reason} = Jev.key_present(security: "/nonexistent/security")
  end

  test "only a timeout, HTTP 429 or HTTP 529 is retried, and only once" do
    for {results, sent} <- [
          {[{:timeout}, {:timeout}, {:timeout}], 2},
          {[{429, "slow"}, {429, "slow"}, {429, "slow"}], 2},
          {[{529, "busy"}, {529, "busy"}, {529, "busy"}], 2},
          {[{:timeout}, {200, FakeJev.answer_body(@items)}], 2},
          {[{400, FakeJev.max_tokens_body()}], 1},
          {[{401, "no"}], 1},
          {[{422, "bad"}], 1},
          {[{500, "boom"}], 1},
          {[{:error, "refused"}], 1}
        ] do
      outcome = read(results)
      assert length(outcome["exchanges"]) == sent, inspect(results)
      assert request_count() == sent
    end

    assert read([{:timeout}, {200, FakeJev.answer_body(@items)}])["outcome"] == "answered"
  end

  test "every failure is an explicit unavailable outcome with a precise reason" do
    partial =
      FakeJev.answer_body(@items)
      |> Jason.decode!()
      |> update_in(["answers"], &Map.delete(&1, "objection:finding:F1"))
      |> Jason.encode!()

    extra =
      FakeJev.answer_body(@items)
      |> Jason.decode!()
      |> put_in(["answers", "status:other"], %{"choice" => "done", "confidence" => 0.9})
      |> Jason.encode!()

    duplicated =
      String.replace(
        FakeJev.answer_body(@items),
        ~s("answers":{),
        ~s("answers":{"objection:risk:r1":{"choice":"objection","confidence":0.99},),
        global: false
      )

    for {results, reason} <- [
          {[{:timeout}, {:timeout}], "timeout after 60000 ms"},
          {[{400, FakeJev.max_tokens_body()}],
           ~s(HTTP 400: {"detail":{"error_type":"max_tokens_exceeded"}})},
          {[{401, "invalid key"}], "HTTP 401: invalid key"},
          {[{422, "unprocessable"}], "HTTP 422"},
          {[{429, "x"}, {429, "x"}], "HTTP 429"},
          {[{529, "x"}, {529, "x"}], "HTTP 529"},
          {[{503, "x"}], "HTTP 503"},
          {[{:error, "econnrefused"}], "transport failure"},
          {[{200, "not json"}], "not a JSON object"},
          {[{200, "[1]"}], "not a JSON object"},
          {[{200, FakeJev.answer_body(@items, %{}, "jev-latest")}], "jev-latest"},
          {[{200, partial}], "answer for objection:finding:F1 is missing"},
          {[{200, extra}], "unasked questions: status:other"},
          {[{200, duplicated}], "response answers repeat objection:risk:r1"},
          {[{200, FakeJev.answer_body(@items, %{"status:s1" => {"maybe", 0.9}})}],
           "was not sent"},
          {[{200, FakeJev.answer_body(@items, %{"objection:risk:r1" => {"done", 0.9}})}],
           "was not sent"},
          {[{200, FakeJev.answer_body(@items, %{"status:s1" => {"done", 1.5}})}],
           "confidence out of range"}
        ] do
      outcome = read(results)
      assert outcome["outcome"] == "unavailable", inspect(results)
      assert outcome["reason"] =~ reason
      assert outcome["answers"] == nil
      # A partially valid response is never cherry-picked.
      assert Jev.objections(outcome) == []
    end

    # The retained max_tokens_exceeded body is exact.
    [exchange] = read([{400, FakeJev.max_tokens_body()}])["exchanges"]
    assert exchange["response_body"] == FakeJev.max_tokens_body()
    assert exchange["status"] == 400
  end

  test "an unreadable Keychain item, invalid notes or an invalid item list never reach the transport" do
    System.put_env("FAKE_SECURITY_ITEM", "unreadable")
    outcome = read([{200, FakeJev.answer_body(@items)}])
    assert outcome["outcome"] == "unavailable"
    assert outcome["reason"] == "Keychain item `ai.typesafe.api` could not be read at call time"
    System.delete_env("FAKE_SECURITY_ITEM")
    refute_received {:jev_request, _}

    outcome =
      Jev.read_notes(<<0xFF>>, @items,
        transport: FakeJev.transport([{200, "{}"}]),
        security: FakeJev.security_path()
      )

    assert outcome["reason"] =~ "not valid UTF-8"
    refute_received {:jev_request, _}

    outcome =
      Jev.read_notes("notes", [%{"kind" => "other", "id" => "x"}],
        transport: FakeJev.transport([{200, "{}"}]),
        security: FakeJev.security_path()
      )

    assert outcome["outcome"] == "unavailable"
    refute_received {:jev_request, _}
  end

  test "the key never appears in a reason, even when a transport echoes it" do
    key = FakeJev.sentinel_key()
    outcome = read([{:error, "failed with Bearer #{key}"}])
    assert outcome["reason"] =~ "[redacted]"
    refute Jason.encode!(outcome) =~ key

    raising = fn _request -> raise "boom #{key}" end

    outcome = Jev.read_notes("n", @items, transport: raising, security: FakeJev.security_path())
    assert outcome["outcome"] == "unavailable"
    refute Jason.encode!(outcome) =~ key
  end

  test "only an objection at or above the calibrated 0.85 is a cannot-comply reading" do
    assert Jev.objection_threshold() == 0.85

    for {confidence, flagged?} <- [{0.95, true}, {0.85, true}, {0.849, false}, {0.84, false}] do
      outcome =
        read([
          {200,
           FakeJev.answer_body(@items, %{"objection:finding:F1" => {"objection", confidence}})}
        ])

      expected =
        if flagged?,
          do: [%{"kind" => "finding", "id" => "F1", "confidence" => confidence}],
          else: []

      assert Jev.objections(outcome) == expected
    end

    # objection_only status and unclear answers never stop a Build.
    outcome =
      read([
        {200,
         FakeJev.answer_body(@items, %{
           "status:s1" => {"objection_only", 0.99},
           "objection:risk:r1" => {"unclear", 0.99}
         })}
      ])

    assert Jev.objections(outcome) == []
  end

  test "advisory labels report only what the Developer says, per item and per outcome" do
    labels = %{
      "unfinished" => "the Developer says s1 is unfinished (confidence 0.91)",
      "done" => "the Developer says its work on s1 is done (confidence 0.91)",
      "pending_external" =>
        "the Developer says its work on s1 is done and only external verification is pending (confidence 0.91)",
      "resolved_or_historical" => "resolved or historical (confidence 0.91)",
      "objection_only" => "possible objection (confidence 0.91)",
      "unclear" => "unclear (confidence 0.91)"
    }

    for {choice, label} <- labels do
      outcome = read([{200, FakeJev.answer_body(@items, %{"status:s1" => {choice, 0.91}})}])

      assert [%{"kind" => "scenario", "id" => "s1", "notes" => [^label, _objection]} | _] =
               Jev.advisory(outcome)
    end

    for {choice, label} <- [
          {"objection", "possible objection (confidence 0.62)"},
          {"no_objection", "no objection stated (confidence 0.62)"},
          {"unclear", "objection unclear (confidence 0.62)"}
        ] do
      outcome =
        read([{200, FakeJev.answer_body(@items, %{"objection:risk:r1" => {choice, 0.62}})}])

      assert %{"notes" => [^label]} = Enum.at(Jev.advisory(outcome), 1)
    end

    unavailable = read([{401, "no"}])

    for item <- Jev.advisory(unavailable) do
      assert item["notes"] == [
               "Jev unavailable: HTTP 401: no; no Developer-notes reading was available"
             ]
    end

    assert Enum.map(Jev.advisory(unavailable), & &1["id"]) == ["s1", "r1", "F1"]
  end

  test "offline tests reach Jev only through fakes and never open a network connection" do
    # Every isolated child and compiled fixture defaults to the offline fakes.
    assert System.get_env("KOGEN_JEV_TRANSPORT") == FakeJev.transport_path()
    assert System.get_env("KOGEN_JEV_SECURITY") == FakeJev.security_path()
    assert Jev.transport_kind() == {:executable, FakeJev.transport_path()}

    assert Kogen.CompiledFixture.offline_jev_env() == [
             {"KOGEN_JEV_TRANSPORT", FakeJev.transport_path()},
             {"KOGEN_JEV_SECURITY", FakeJev.security_path()}
           ]

    assert Kogen.CompiledFixture.offline_jev_env([{"KOGEN_JEV_TRANSPORT", "x"}]) == [
             {"KOGEN_JEV_SECURITY", FakeJev.security_path()}
           ]

    # The default (environment-selected) transport is the offline executable.
    log = Path.join(System.tmp_dir!(), "kogen-fake-jev-#{System.unique_integer([:positive])}")
    System.put_env("FAKE_JEV_LOG_DIR", log)
    on_exit(fn -> File.rm_rf(log) end)
    outcome = Jev.read_notes("notes", @items)
    assert outcome["outcome"] == "answered"
    assert [%{"authorization_matches_keychain" => true}] = FakeJev.requests(log)

    # The fake executable has no network code at all.
    fake = File.read!(FakeJev.transport_path())
    refute fake =~ ~r/\b(socket|urllib|http\.client|requests|ssl)\b/

    # Only paid live drivers clear the offline transport, and only for their
    # real `mix kogen.build` runs.
    clearing =
      (Path.wildcard(Path.join(@root, "test/**/*.{ex,exs}")) ++
         Path.wildcard(Path.join(@root, "test/support/*")))
      |> Enum.uniq()
      |> Enum.filter(&clears_offline_transport?/1)
      |> Enum.map(&Path.relative_to(&1, @root))
      |> Enum.reject(&(&1 == "test/kogen/jev_test.exs"))

    assert Enum.all?(clearing, &String.contains?(Path.basename(&1), "live")),
           "only live drivers may clear the offline Jev transport: #{inspect(clearing)}"
  end

  defp clears_offline_transport?(path) do
    File.regular?(path) and
      (File.read!(path) =~ ~s({"KOGEN_JEV_TRANSPORT", nil}) or
         File.read!(path) =~ ~S|delete_env("KOGEN_JEV_TRANSPORT")|)
  end

  defp read(results) do
    flush()

    Jev.read_notes("notes", @items,
      transport: FakeJev.transport(results),
      security: FakeJev.security_path()
    )
  end

  defp request_count(count \\ 0) do
    receive do
      {:jev_request, _request} -> request_count(count + 1)
    after
      0 -> count
    end
  end

  defp flush do
    receive do
      {:jev_request, _request} -> flush()
    after
      0 -> :ok
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
