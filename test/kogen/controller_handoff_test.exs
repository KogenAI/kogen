Code.require_file("../support/fake_jev.ex", __DIR__)

defmodule Kogen.ControllerHandoffTest do
  @moduledoc """
  Controller-built Developer handoff reports, free-prose Developer notes read
  once by an offline fake Jev, the calibrated cannot-comply stop, Jev
  unavailability, and missing declared proof selectors, all driven through the
  real `Kogen.Build.run/1` consumer with a scripted Codex-protocol provider.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.Report
  alias Kogen.FakeJev

  @slug "controller-handoff"
  @root Path.expand("../..", __DIR__)
  @selector "test/kogen/handoff_selector_test.exs"
  @late_selector "test/kogen/late_selector_test.exs"
  @prefix "Developer cannot comply as approved; return to Shaping:"

  @old_shape_notes ~s({"attempt_token":"stale","scenarios":[{"id":"s-change","status":"ready","claim":"done","implementation":[{"path":"lib","locator":"x"}],"evidence":[]}],"risks":[{"id":"r-shared","scenario_ids":["s-preserve"],"response":"moved","evidence":[]}],"findings":[]})

  @variants [
    {"prose", "Both scenarios are done. Nothing is unfinished and I have no objection."},
    {"prose then JSON", ~s(Summary follows.\n{"attempt_token":"x","scenarios":[]})},
    {"malformed JSON", ~s({"attempt_token": "x", "scenarios": [}, oops})},
    {"truncated JSON", ~s({"attempt_token":"x","scenarios":[{"id":"s-cha)},
    {"old handoff shape", @old_shape_notes},
    {"empty", ""}
  ]

  test "every Developer message variant yields the same controller report and reaches Review" do
    reports =
      for {label, notes} <- @variants do
        dir = fixture!()
        result = run(dir, notes: [notes], edits: %{1 => "printf 'changed\\n' > dummy.txt"})
        assert result == :ok, "#{label}: #{inspect(result)}"

        [attempt] = record!(dir)["attempts"]
        assert Base.decode64!(attempt["developer_notes"]["content_base64"]) == notes, label
        assert attempt["developer_notes"]["text"] == notes
        assert attempt["developer_notes"]["label"] =~ "unverified"
        assert attempt["developer_invocation"]["message"] == notes
        refute Map.has_key?(attempt["developer_invocation"], "schema")
        assert attempt["outcome"] == "settled"
        assert attempt["jev"]["outcome"] == "answered"
        assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "1"
        assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))

        report = attempt["handoff"]
        assert report["attempt_token"] == attempt["attempt_token"]
        assert report["candidate_id"] == attempt["candidate_id"]
        check = Enum.find(report["receipts"], &(&1["target"] == "check"))
        assert check["status"] == "passed"
        assert check["attempt_token"] == attempt["attempt_token"]
        assert check["candidate_id"] == attempt["candidate_id"]

        assert Map.keys(attempt["developer_reference_snapshots"]) |> Enum.sort() ==
                 ["dummy.txt", @selector]

        normalize(report)
      end

    [first | rest] = reports
    assert Enum.all?(rest, &(&1 == first))

    assert Enum.map(first["scenarios"], & &1["id"]) == ["s-change", "s-preserve"]
    [change, preserve] = first["scenarios"]

    assert change["changed_affected_paths"] == [
             %{
               "path" => "dummy.txt",
               "change" => "modified",
               "locator" => "changed in Candidate relative to HEAD (modified)"
             }
           ]

    assert change["affected_paths_note"] == nil
    assert change["paid_target"] == "none"

    assert change["offline_selectors"] == [
             %{
               "selector" => @selector,
               "path" => @selector,
               "locator" => "declared offline selector"
             }
           ]

    assert preserve["changed_affected_paths"] == []
    assert preserve["affected_paths_note"] =~ "not a failure"

    assert first["risks"] == [
             %{"id" => "r-shared", "scenario_ids" => ["s-change", "s-preserve"]},
             %{"id" => "r-preserve", "scenario_ids" => ["s-preserve"]}
           ]

    assert first["findings"] == []
    assert first["built_by"] == "controller"
  end

  test "changing the Candidate's affected paths changes the report, and a deleted path is never cited" do
    dir = fixture!()

    assert :ok =
             run(dir,
               edits: %{
                 1 =>
                   "printf 'changed\\n' > dummy.txt; printf 'kept\\n' > keep.txt; rm retired.txt"
               }
             )

    [attempt] = record!(dir)["attempts"]
    [_change, preserve] = attempt["handoff"]["scenarios"]

    assert preserve["changed_affected_paths"] == [
             %{
               "path" => "keep.txt",
               "change" => "modified",
               "locator" => "changed in Candidate relative to HEAD (modified)"
             },
             %{"path" => "retired.txt", "change" => "deleted"}
           ]

    assert preserve["affected_paths_note"] == nil
    snapshots = attempt["developer_reference_snapshots"]
    assert Map.has_key?(snapshots, "keep.txt")
    refute Map.has_key?(snapshots, "retired.txt")
    # Unrelated changes are never listed under a scenario's affected paths.
    refute Enum.any?(preserve["changed_affected_paths"], &(&1["path"] == "dummy.txt"))
  end

  test "the report builder is total and identical for any message bytes and any Jev outcome" do
    :rand.seed(:exsss, {7, 11, 13})
    contract = %{scenarios: scenarios_data(), risks: risks_data()}

    inputs = %{
      contract: contract,
      attempt_token: "token",
      candidate_id: "candidate",
      open_findings: [%{"id" => "F1", "scenario_ids" => ["s-change"], "origin" => %{}}],
      changes: [{"dummy.txt", "modified"}, {"retired.txt", "deleted"}, {"other.txt", "added"}],
      receipts: [
        %{"target" => "check", "status" => "passed", "output" => "ok"}
      ],
      existing?: &(&1 in ["dummy.txt", @selector])
    }

    items = [%{"kind" => "scenario", "id" => "s-change"}]

    messages =
      [
        "",
        <<0xFF, 0xFE, 0x00>>,
        String.duplicate("x", 2_000_000),
        @old_shape_notes,
        "Developer cannot comply as approved"
      ] ++ for(_ <- 1..40, do: :crypto.strong_rand_bytes(:rand.uniform(512)))

    outcomes = [
      nil,
      %{"outcome" => "unavailable", "reason" => "timeout", "items" => items},
      %{
        "outcome" => "answered",
        "items" => items,
        "answers" => %{
          "status:s-change" => %{"choice" => "unfinished", "confidence" => 0.99},
          "objection:scenario:s-change" => %{"choice" => "objection", "confidence" => 0.99}
        }
      }
    ]

    expected = Report.build(inputs)

    for message <- messages, jev <- outcomes do
      assert Report.build(Map.merge(inputs, %{notes: message, jev: jev})) == expected
    end

    [finding] = expected["findings"]
    assert finding["id"] == "F1"
  end

  test "Build has no remaining code path that produces a Developer handoff invalid failure" do
    source = File.read!(Path.join(@root, "lib/kogen/build.ex"))
    refute source =~ "Developer handoff structure invalid"
    refute source =~ "Developer handoff semantic invalid"
    refute source =~ ~r/Developer handoff [^"]*invalid/
    refute source =~ "Contract.handoff("
    refute source =~ "DeveloperHandoff"
    refute source =~ "structured_output_"
    refute source =~ "handoff_valid?"
  end

  test "Build sends one pinned Jev request per settled attempt with the notes, IDs and calibrated wording" do
    dir = fixture!()
    notes = ["First attempt notes: s-change is done.", "Rework done for F1."]
    console = Path.join(dir, ".kogen/runtime/console.txt")

    assert :ok =
             run(dir,
               notes: notes,
               reviews: "rework,accept",
               edits: %{1 => "printf 'changed\\n' > dummy.txt"}
             )

    record = record!(dir)
    [first, second] = record["attempts"]
    requests = FakeJev.requests(jev_log(dir))
    assert length(requests) == 2

    for {attempt, request, text, items} <- [
          {first, Enum.at(requests, 0), Enum.at(notes, 0), base_items()},
          {second, Enum.at(requests, 1), Enum.at(notes, 1),
           base_items() ++ [%{"kind" => "finding", "id" => "F1"}]}
        ] do
      assert request["url"] == "https://api.typesafe.ai/v1/systemone"
      assert request["timeout_ms"] == 60_000
      assert request["header_names"] == ["authorization", "content-type"]
      assert request["authorization_matches_keychain"]
      assert request["body"] == Kogen.Jev.request_body(text, items)

      body = Jason.decode!(request["body"])
      assert body["model"] == "jev-1.13.0"
      assert body["state"] == %{"developer_notes" => text, "items" => items}

      assert body["questions"]["status:s-change"]["criteria"] |> Map.keys() |> Enum.sort() ==
               Enum.sort(
                 ~w(unfinished done pending_external resolved_or_historical objection_only unclear)
               )

      assert body["questions"]["objection:risk:r-shared"]["criteria"] |> Map.keys() |> Enum.sort() ==
               ~w(no_objection objection unclear)

      assert body["questions"]["objection:scenario:s-change"]["instructions"]["rules"] == [
               "Judge only what the notes state about this item.",
               "Unfinished work alone is not an objection."
             ]

      jev = attempt["jev"]
      assert jev["request"]["body"] == request["body"]
      assert jev["request"]["sha256"] == sha256(request["body"])
      assert [%{"status" => 200, "latency_ms" => latency}] = jev["exchanges"]
      assert is_integer(latency)
      assert jev["usage"]["input_tokens"] > 0
      assert jev["attempt_token"] == attempt["attempt_token"]
      assert jev["candidate_id"] == attempt["candidate_id"]
    end

    # Nothing Jev-related reaches the Developer's context.
    for call <- [1, 2] do
      prompt = File.read!(Kogen.CandidateFixture.fake_state(dir, "developer-prompt-#{call}"))
      refute prompt =~ "systemone"
      refute prompt =~ "objection:scenario"
      refute prompt =~ first["jev"]["request"]["sha256"]
    end

    File.write!(console, "")
    assert_no_key!(dir)
  end

  test "the fresh Reviewer is told the report is controller-built and sees labelled advisory Jev notes" do
    dir = fixture!()

    assert :ok =
             run(dir,
               notes: ["s-change still lacks its edge case; the rest is done."],
               jev_answers: %{"status:s-change" => ["unfinished", 0.93]}
             )

    prompt = File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-prompt-1"))
    assert prompt =~ "is controller-built and contains no Developer self-assessment"

    assert prompt =~
             "you are responsible for finding unfinished or plausible-looking-only scenarios"

    assert prompt =~ "including prose responses to open findings, are unverified claims"
    assert prompt =~ "Jev only read the Developer's words and never judged the code"

    assert prompt =~
             "`changed_affected_paths` lists files that changed relative to HEAD, not where each behaviour lives"

    assert prompt =~
             "- scenario `s-change`: the Developer says s-change is unfinished (confidence 0.93)"

    assert prompt =~
             "- scenario `s-preserve`: the Developer says its work on s-preserve is done (confidence 0.97)"

    assert prompt =~ "- risk `r-shared`: no objection stated (confidence 0.98)"

    context = task_context!(prompt)
    assert context["handoff_report"] =~ "controller-built"
    assert context["developer_notes"] =~ "unverified claims"

    # The bounded review packet is the evidence source; the record stays an
    # audit locator under its existing key.
    [attempt] = record!(dir)["attempts"]
    assert context["evidence_source"] == "review_packet"

    # The Reviewer's context names an absolute control path (it must open
    # from the Candidate cwd); the record keeps the control-relative locator.
    binding = Map.take(attempt["review_packet"], ["sha256", "byte_count"])
    assert Map.take(context["review_packet"], ["sha256", "byte_count"]) == binding

    assert context["review_packet"]["path"] ==
             realpath!(Path.join(dir, attempt["review_packet"]["path"]))

    assert context["tracking_path"] == realpath!(List.first(records(dir)))
    assert context["tracking_record"]["use"] =~ "audit locator only"
    packet_bytes = File.read!(context["review_packet"]["path"])
    assert sha256(packet_bytes) == context["review_packet"]["sha256"]
    packet = Jason.decode!(packet_bytes)
    assert packet["handoff"] == attempt["handoff"]
    assert packet["developer_notes"] == "s-change still lacks its edge case; the rest is done."
    assert prompt =~ "Review packet: `#{context["review_packet"]["path"]}`"
    assert context["jev_reading"]["advisory"] =~ "never findings or verification"

    assert %{"kind" => "scenario", "id" => "s-change", "notes" => notes} =
             hd(context["jev_reading"]["items"])

    assert hd(notes) == "the Developer says s-change is unfinished (confidence 0.93)"

    # A confident "unfinished" reading never routes rework by itself.
    record = record!(dir)
    assert [%{"verdict" => %{"verdict" => "accept"}}] = record["attempts"]
    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "developer-prompt-2"))
  end

  for {label, kind, id, confidence} <- [
        {"a scenario objection at 0.95", "scenario", "s-change", 0.95},
        {"a risk objection at 0.95", "risk", "r-preserve", 0.95},
        {"an objection exactly at 0.85", "scenario", "s-preserve", 0.85}
      ] do
    test "#{label} stops the Build without Review, resumption or publication" do
      dir = fixture!()
      notes = "The contract for this item cannot be met: it needs a change outside guarded paths."

      assert {:error, reason} =
               run(dir,
                 notes: [notes],
                 jev_answers: %{
                   "objection:#{unquote(kind)}:#{unquote(id)}" => [
                     "objection",
                     unquote(confidence)
                   ]
                 },
                 edits: %{1 => "printf 'changed\\n' > dummy.txt"}
               )

      assert String.starts_with?(reason, @prefix)
      confidence = unquote(confidence)

      assert reason =~
               "#{unquote(kind)} `#{unquote(id)}` (Jev confidence #{Kogen.Jev.format(confidence)})"

      assert reason =~ "Developer's notes: \"#{notes}\""
      refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
      assert File.read!(Kogen.CandidateFixture.fake_state(dir, "developer-calls")) == "1"
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
      # The Candidate (never control) is kept for inspection like any
      # stopped Build.
      assert File.read!(Path.join(dir, "dummy.txt")) == "baseline\n"

      assert File.read!(Path.join(Kogen.CandidateFixture.worktree(dir), "dummy.txt")) ==
               "changed\n"

      [attempt] = record!(dir)["attempts"]
      assert attempt["status"] == "failed"
      assert attempt["outcome"] == "cannot_comply"
      assert attempt["failure"] =~ @prefix

      assert [%{"kind" => unquote(kind), "id" => unquote(id)}] =
               attempt["cannot_comply"]["items"]

      assert attempt["cannot_comply"]["notes_quote"] == notes
      assert attempt["cannot_comply"]["threshold"] == 0.85
    end
  end

  test "an objection below 0.85 never stops the Build and reaches Review as a possible objection" do
    dir = fixture!()

    assert :ok =
             run(dir, jev_answers: %{"objection:scenario:s-change" => ["objection", 0.84]})

    prompt = File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-prompt-1"))
    assert prompt =~ "possible objection (confidence 0.84)"
    [attempt] = record!(dir)["attempts"]
    assert attempt["outcome"] == "settled"
  end

  test "an open finding the Developer says it cannot address stops the Build as cannot-comply" do
    dir = fixture!()

    assert {:error, reason} =
             run(dir,
               notes: ["All done.", "F1 cannot be addressed as approved; it needs Shaping."],
               reviews: "rework",
               jev_answers: %{"objection:finding:F1" => ["objection", 0.95]}
             )

    assert String.starts_with?(reason, @prefix)
    assert reason =~ "finding `F1` (Jev confidence 0.95)"
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "1"
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "developer-calls")) == "2"
    [_reworked, stopped] = record!(dir)["attempts"]
    assert stopped["outcome"] == "cannot_comply"
  end

  test "long notes are visibly truncated in the stop and name the record holding them" do
    dir = fixture!()
    notes = "I object: the contract is contradictory. " <> String.duplicate("detail ", 1_000)

    assert {:error, reason} =
             run(dir,
               notes: [notes],
               jev_answers: %{"objection:scenario:s-change" => ["objection", 0.99]}
             )

    [record_path] = records(dir)

    assert reason =~
             "[notes truncated at 2000 of #{String.length(notes)} characters; full notes in #{realpath!(record_path)} attempt 0 developer_notes]"

    refute reason =~ notes
    [attempt] = record!(dir)["attempts"]
    assert attempt["cannot_comply"]["notes_truncated"]
    assert attempt["developer_notes"]["text"] == notes
  end

  # Scenario `notes-and-selectors-before-verification`: Jev reads the turn's
  # notes before any verification cycle runs. An objection on the first turn
  # (no cycle has failed yet in this attempt) stops the Build as
  # `cannot_comply` at once, spending no verification cycle.
  test "an objection on the first turn stops as cannot-comply before any verification cycle runs" do
    dir = fixture!()

    assert {:error, reason} =
             run(dir,
               notes: ["I cannot meet s-change as approved."],
               edits: %{1 => "mkdir -p .kogen/runtime && touch .kogen/runtime/fail-check"},
               jev_answers: %{"objection:scenario:s-change" => ["objection", 0.95]}
             )

    assert String.starts_with?(reason, @prefix)
    assert length(FakeJev.requests(jev_log(dir))) == 1
    [attempt] = record!(dir)["attempts"]
    assert Map.has_key?(attempt, "jev")
    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
  end

  # When no cycle of the attempt failed yet, Jev is read before verification
  # runs. Since this attempt carries no objection, verification proceeds and
  # (with `fail-check` never cleared) exhausts `offline_retries`; Jev keeps
  # being read on every subsequent turn.
  test "exhausted verification without an objection still asks Jev and keeps the exhaustion reason" do
    dir = fixture!()

    assert {:error, reason} =
             run(dir, edits: %{1 => "mkdir -p .kogen/runtime && touch .kogen/runtime/fail-check"})

    assert reason =~ ~r/^offline retries exhausted/
    [attempt] = record!(dir)["attempts"]
    assert Map.has_key?(attempt, "jev")
    assert FakeJev.requests(jev_log(dir)) != []
    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
  end

  @unavailable [
    {"two timeouts", [{:timeout}, {:timeout}], 2, "timeout after 60000 ms"},
    {"HTTP 400 max_tokens_exceeded", [{400, FakeJev.max_tokens_body()}], 1,
     "HTTP 400: " <> FakeJev.max_tokens_body()},
    {"HTTP 401", [{401, ~s({"detail":"invalid key"})}], 1, "HTTP 401"},
    {"HTTP 422", [{422, ~s({"detail":"bad request"})}], 1, "HTTP 422"},
    {"HTTP 429 after the retry", [{429, "slow down"}, {429, "slow down"}], 2, "HTTP 429"},
    {"HTTP 529 after the retry", [{529, "overloaded"}, {529, "overloaded"}], 2, "HTTP 529"},
    {"HTTP 500", [{500, "boom"}], 1, "HTTP 500"},
    {"a transport failure", [{:error, "connection refused"}], 1, "transport failure"},
    {"a body that is not JSON", [{200, "<html>oops</html>"}], 1, "not a JSON object"},
    {"a response for another model", [{200, :other_model}], 1, "jev-latest"},
    {"a partially valid response", [{200, :partial}], 1, "is missing"},
    {"a duplicated answer", [{200, :duplicated}], 1, "repeat status:s-change"},
    {"an answer with an unsent option", [{200, :invalid_option}], 1, "was not sent"}
  ]

  for {label, results, exchanges, reason} <- @unavailable do
    test "Jev unavailable (#{label}) reaches Review with the reason and never stops the Build" do
      dir = fixture!()
      responses = Path.join(dir, ".kogen/runtime/jev-responses")
      FakeJev.record_responses!(responses, materialize(unquote(Macro.escape(results))))

      assert :ok = run(dir, jev_responses: responses)
      assert_unavailable!(dir, unquote(exchanges), unquote(reason))
    end
  end

  test "a retried 529 that then answers is a normal reading" do
    dir = fixture!()
    responses = Path.join(dir, ".kogen/runtime/jev-responses")

    FakeJev.record_responses!(responses, [
      {529, "overloaded"},
      {200, FakeJev.answer_body(base_items())}
    ])

    assert :ok = run(dir, jev_responses: responses)
    [attempt] = record!(dir)["attempts"]
    assert attempt["jev"]["outcome"] == "answered"
    assert Enum.map(attempt["jev"]["exchanges"], & &1["status"]) == [529, 200]
  end

  test "a Keychain item that disappears after preconditions makes Jev unavailable, not a stop" do
    dir = fixture!()
    assert :ok = run(dir, security_item: "unreadable")
    assert_unavailable!(dir, 0, "Keychain item `dev.kogen.jev` could not be read at call time")
    assert FakeJev.requests(jev_log(dir)) == []
  end

  test "a missing declared proof selector is unfinished work that spends one outer resumption" do
    dir = fixture!(late_selector: true)

    assert :ok =
             run(dir,
               edits: %{
                 1 => "printf 'changed\\n' > dummy.txt",
                 2 => "printf '# late\\n' > #{@late_selector}"
               }
             )

    [unfinished, finished] = record!(dir)["attempts"]
    assert unfinished["outcome"] == "unfinished_work"
    assert unfinished["status"] == "failed"

    assert unfinished["failure"] ==
             "Unfinished work: missing declared proof selector #{@late_selector}"

    refute Map.has_key?(unfinished, "verdict")
    refute Map.has_key?(unfinished, "handoff")
    assert finished["verdict"]["verdict"] == "accept"
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "1"
    # The next attempt settled a fresh Stop verification of its own.
    assert finished["verification"]["cycles"] != []
    assert finished["attempt_token"] != unfinished["attempt_token"]

    resume = File.read!(Kogen.CandidateFixture.fake_state(dir, "developer-prompt-2"))
    assert resume =~ "category: unfinished_work"

    [summary] =
      Path.wildcard(Path.join(dir, ".kogen/intents/complete/#{@slug}/build-summary*.json"))

    kinds =
      summary
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("attempts")
      |> Enum.map(& &1["failure_kind"])

    assert kinds == ["unfinished_work", nil]
  end

  test "a declared proof selector missing on every attempt stops after the outer resumptions" do
    dir = fixture!(late_selector: true)

    assert {:error, reason} = run(dir)

    assert reason =~
             "stopped after 2 outer resumptions without an accepting Review: Unfinished work: missing declared proof selector #{@late_selector}"

    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "developer-calls")) == "3"
    refute File.exists?(Kogen.CandidateFixture.fake_state(dir, "reviews"))
  end

  test "a declared proof selector that exists is not unfinished work" do
    dir = fixture!(late_selector: true)
    assert :ok = run(dir, edits: %{1 => "printf '# late\\n' > #{@late_selector}"})
    assert [%{"outcome" => "settled"}] = record!(dir)["attempts"]
  end

  # Scenario `candidate-routing`: "the Candidate-only selector counts as
  # present and the control-only edit never appears" (Candidate id, changed
  # paths, proof-selector existence, report entries and review packet
  # contents are all computed from the Candidate root, never control's).
  test "candidate-routing: a Candidate-only proof selector file counts as present, and a control-only ignored edit never appears in changed paths, report or packet" do
    dir = fixture!(late_selector: true)

    # An edit to control's own ignored state (never copied into the
    # Candidate at admission): must never surface anywhere Build-visible.
    File.mkdir_p!(Path.join(dir, ".kogen/runtime"))
    File.write!(Path.join(dir, ".kogen/runtime/control-only-sentinel.txt"), "control only\n")

    assert :ok =
             run(dir,
               edits: %{
                 1 => "printf 'changed\\n' > dummy.txt; printf '# late\\n' > #{@late_selector}"
               }
             )

    [attempt] = record!(dir)["attempts"]
    assert attempt["outcome"] == "settled"
    report = attempt["handoff"]
    late = Enum.find(report["scenarios"], &(&1["id"] == "s-late"))

    # The late selector, written only inside the Candidate by the edit,
    # counts as present: no "missing declared proof selector" unfinished
    # work and the selector is listed.
    assert Enum.any?(late["offline_selectors"], &(&1["selector"] == @late_selector))

    all_paths =
      report["scenarios"]
      |> Enum.flat_map(& &1["changed_affected_paths"])
      |> Enum.map(& &1["path"])

    refute Enum.any?(all_paths, &(&1 =~ "control-only-sentinel"))
    refute Jason.encode!(report) =~ "control-only-sentinel"

    binding = attempt["review_packet"]
    packet_bytes = File.read!(Path.join(dir, binding["path"]))
    refute packet_bytes =~ "control-only-sentinel"

    # The control-side sentinel was never copied into the Candidate at all.
    refute File.exists?(Path.join(Kogen.CandidateFixture.worktree(dir), ".kogen/runtime"))
  end

  test "a cannot-comply reading takes precedence over a missing declared proof selector" do
    dir = fixture!(late_selector: true)

    assert {:error, reason} =
             run(dir, jev_answers: %{"objection:scenario:s-late" => ["objection", 0.9]})

    assert String.starts_with?(reason, @prefix)
    refute reason =~ "Unfinished work"
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "developer-calls")) == "1"
  end

  # Scenario `candidate-routing`: every role launch's cwd is the Candidate,
  # `control_root` names control, and every control locator a role is handed
  # (`tracking_path`, the review packet path, the verification-failure
  # prompt's retained receipt and log, and one packet `log_path` joined to
  # `control_root`) opens from that Candidate cwd. Asserted on the shared
  # fakes' own per-launch receipts (`test/support/launch_receipt.py`), on OS
  # process state, never on launch arguments.
  test "candidate-routing: launch receipts show the Candidate cwd, control_root, and every handed control locator opening from it" do
    dir = shared_fake_fixture!()
    commit_all!(dir)

    claude_root = Path.join(dir <> "-claude-root", "claude")
    File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)
    System.put_env("KOGEN_CLAUDE_ROOT", claude_root)
    System.put_env("KOGEN_HARNESS", Path.join(@root, "test/support/fake_codex"))
    System.delete_env("KOGEN_ROLE")

    assert :ok = File.cd!(dir, fn -> Kogen.Build.run(@slug, nil, dir) end)

    control = realpath!(dir)
    receipts = Kogen.CandidateFixture.receipts(dir)
    assert receipts != []

    candidate = realpath!(Kogen.CandidateFixture.worktree(dir))

    for receipt <- receipts, receipt["role"] in ["developer", "reviewer"] do
      assert receipt["pwd"] == candidate

      # The verification-failure resume prompt deliberately carries no
      # `KOGEN_TASK_CONTEXT` block (the controller's context/state/history
      # paths are never given out), so that one receipt alone has no
      # `working_directory`/`control_root`; every other developer/reviewer
      # receipt does, and always names the Candidate and control.
      if receipt["working_directory"] do
        assert receipt["working_directory"] == candidate
        assert receipt["control_root"] == control
      end

      for {_label, opened?} <- receipt["opens"] do
        assert opened?, "receipt #{inspect(receipt["locators"])} failed to open a control locator"
      end
    end

    # At least one Developer receipt saw the verification-failure prompt's
    # retained receipt and log (this fixture's Developer always breaks
    # `check` once), and at least one Reviewer receipt resolved a packet
    # `log_path` joined to `control_root`.
    developer_locators = for r <- receipts, r["role"] == "developer", do: r["locators"]
    assert Enum.any?(developer_locators, &Map.has_key?(&1, "failure_receipt"))
    assert Enum.any?(developer_locators, &Map.has_key?(&1, "failure_log"))

    reviewer_locators = for r <- receipts, r["role"] == "reviewer", do: r["locators"]
    assert Enum.any?(reviewer_locators, &Map.has_key?(&1, "packet_log_path"))
    assert Enum.any?(reviewer_locators, &Map.has_key?(&1, "tracking_path"))
    assert Enum.any?(reviewer_locators, &Map.has_key?(&1, "review_packet"))
  end

  defp shared_fake_fixture! do
    dest =
      Path.join(
        System.tmp_dir!(),
        "kogen-controller-handoff-shared-fake-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dest)
    on_exit(fn -> File.rm_rf(dest) end)

    for relative <- [
          ".codex/hooks.json",
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md",
          "priv/kogen/prompts/execution-policy.md"
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dest, relative)))
      File.cp!(Path.join(@root, relative), Path.join(dest, relative))
    end

    File.chmod!(Path.join(dest, ".codex/hooks/check.sh"), 0o755)
    File.write!(Path.join(dest, "proof.txt"), "focused fixture selector\n")
    File.write!(Path.join(dest, "dummy.txt"), "baseline\n")

    File.write!(
      Path.join(dest, "Makefile"),
      ".PHONY: check\ncheck:\n\t@test ! -f .kogen/runtime/kogen_fake_break || { echo bounded fixture check: kogen_fake_break remains >&2; exit 1; }\n"
    )

    File.mkdir_p!(Path.join(dest, "priv/kogen"))

    File.write!(Path.join(dest, "priv/kogen/verification_targets.yaml"), """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture
    """)

    File.write!(Path.join(dest, ".gitignore"), ".kogen/build.lock\n.kogen/runtime/\n")
    File.mkdir_p!(Path.join(dest, ".kogen"))

    File.write!(Path.join(dest, ".kogen/config.yaml"), """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping:   {model: gpt-5.6-sol, effort: low}
        developer: {model: gpt-5.6-sol, effort: low}
        reviewer:  {model: gpt-5.6-terra, effort: medium}
        helpers:
          scout:  {model: gpt-5.6-luna, effort: low}
          worker: {model: gpt-5.6-luna, effort: medium}
          expert: {model: gpt-5.6-sol, effort: medium}
    outer_resumptions: 2
    verification_retries: 2
    offline_retries: 4
    """)

    intent_dir = Path.join(dest, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent_dir)

    File.write!(Path.join(intent_dir, "intent.yaml"), """
    id: 01960000-0000-7000-8000-0000000c0de3
    slug: #{@slug}
    title: Controller handoff shared-fake fixture
    may_change_guarded_paths: [dummy.txt, reviewer-rework-marker.txt]
    """)

    File.write!(Path.join(intent_dir, "scenarios.yaml"), """
    - id: shared-fake-scenario
      given: a fixture Candidate built through the shared fake Codex
      when: Build settles Check and Review
      then: dummy.txt is reviewed and the Build commits
      wrong_result: a role writes or reads outside the Candidate's write boundary
      verified_by: [check]
      evidence: shared fake harness lifecycle
      proof:
        offline: [proof.txt]
        paid_target: none
        paid_reason: "offline-sufficient: shared fake harness drives the real Build consumer"
        affected_paths: [dummy.txt]
    """)

    File.write!(
      Path.join(intent_dir, "requirement.json"),
      ~s({"path":"dummy.txt","expected":"reviewed fixture value"})
    )

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dest, "deps"))
    {_out, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: dest)
    dest
  end

  defp assert_unavailable!(dir, exchanges, reason) do
    [attempt] = record!(dir)["attempts"]
    jev = attempt["jev"]
    assert jev["outcome"] == "unavailable"
    assert jev["reason"] =~ reason
    assert jev["answers"] == nil
    assert length(jev["exchanges"]) == exchanges
    assert attempt["outcome"] == "settled"
    assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "1"
    assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))

    prompt = File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-prompt-1"))

    for item <- base_items() do
      assert prompt =~
               "- #{item["kind"]} `#{item["id"]}`: Jev unavailable: #{jev["reason"]}; no Developer-notes reading was available"
    end

    assert_no_key!(dir)
  end

  defp materialize(results) do
    Enum.map(results, fn
      {200, :other_model} ->
        {200, FakeJev.answer_body(base_items(), %{}, "jev-latest")}

      {200, :partial} ->
        body = FakeJev.answer_body(base_items()) |> Jason.decode!()
        {200, Jason.encode!(update_in(body["answers"], &Map.delete(&1, "status:s-preserve")))}

      {200, :duplicated} ->
        answer = ~s({"type":"choice","choice":"done","confidence":0.9})
        body = FakeJev.answer_body(base_items())
        [head, tail] = String.split(body, ~s("answers":{), parts: 2)
        {200, head <> ~s("answers":{"status:s-change":) <> answer <> "," <> tail}

      {200, :invalid_option} ->
        {200, FakeJev.answer_body(base_items(), %{"status:s-change" => {"maybe", 0.9}})}

      other ->
        other
    end)
  end

  defp assert_no_key!(dir) do
    key = FakeJev.sentinel_key()

    for path <- Path.wildcard(Path.join(dir, ".kogen/**/*"), match_dot: true),
        File.regular?(path),
        not String.contains?(path, "/fake-jev/") do
      refute File.read!(path) =~ key, "Jev key leaked into #{path}"
    end
  end

  defp base_items do
    [
      %{"kind" => "scenario", "id" => "s-change"},
      %{"kind" => "scenario", "id" => "s-preserve"},
      %{"kind" => "risk", "id" => "r-shared"},
      %{"kind" => "risk", "id" => "r-preserve"}
    ]
  end

  # Fields that legitimately differ between otherwise identical Builds.
  defp normalize(report) do
    report
    |> Map.drop(["attempt_token", "candidate_id", "receipts", "reused_receipts"])
    |> Map.update!("scenarios", fn scenarios ->
      Enum.map(scenarios, &Map.delete(&1, "receipts"))
    end)
  end

  defp run(dir, opts \\ []) do
    notes_dir = Path.join(dir, ".kogen/runtime/handoff-notes")
    File.mkdir_p!(notes_dir)

    opts
    |> Keyword.get(:notes, [])
    |> Enum.with_index(1)
    |> Enum.each(fn {notes, call} ->
      File.write!(Path.join(notes_dir, "notes-#{call}"), notes)
    end)

    env =
      [
        {"KOGEN_HARNESS", Path.join(dir, "provider.py")},
        {"HANDOFF_NOTES_DIR", notes_dir},
        {"HANDOFF_REVIEWS", Keyword.get(opts, :reviews, "accept")},
        {"HANDOFF_REASK", Enum.join(Keyword.get(opts, :reask, []), ",")},
        {"HANDOFF_RESPONSE_HELPER", Path.join(@root, "test/support/scenario_response.py")},
        {"FAKE_JEV_LOG_DIR", jev_log(dir)},
        {"FAKE_JEV_ANSWERS", Jason.encode!(Keyword.get(opts, :jev_answers, %{}))},
        {"FAKE_JEV_RESPONSES", Keyword.get(opts, :jev_responses)},
        {"FAKE_SECURITY_ITEM", Keyword.get(opts, :security_item, "present")},
        {"KOGEN_JEV_TRANSPORT", FakeJev.transport_path()},
        {"KOGEN_JEV_SECURITY", FakeJev.security_path()},
        {"HANDOFF_FREEZE_RESUME_EDIT", Enum.join(Keyword.get(opts, :freeze_resume_edit, []), ",")}
      ] ++
        Enum.map(Keyword.get(opts, :edits, %{}), fn {call, command} ->
          {"HANDOFF_EDIT_#{call}", command}
        end)

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    System.delete_env("KOGEN_RAW_LOG_DIR")

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      File.cd!(dir, fn -> Kogen.Build.run(@slug, nil, dir) end)
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp jev_log(dir), do: Path.join(dir, ".kogen/runtime/fake-jev")

  defp fixture!(opts \\ []) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-controller-handoff-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for path <- [
          ".codex/hooks/check.sh",
          ".codex/hooks/stop_runner.py",
          ".codex/hooks/environment.py",
          ".codex/hooks/verification_policy.py",
          ".codex/hooks.json",
          "priv/kogen/prompts/execution-policy.md",
          "priv/kogen/prompts/developer.md",
          "priv/kogen/prompts/reviewer.md"
        ] do
      target = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.join(@root, path), target)
    end

    File.chmod!(Path.join(dir, ".codex/hooks/check.sh"), 0o755)
    File.write!(Path.join(dir, "provider.py"), provider())
    File.chmod!(Path.join(dir, "provider.py"), 0o755)

    File.write!(
      Path.join(dir, "Makefile"),
      ".PHONY: check\n\ncheck:\n\t@test ! -f .kogen/runtime/fail-check\n"
    )

    File.mkdir_p!(Path.join(dir, "priv/kogen"))

    File.write!(Path.join(dir, "priv/kogen/verification_targets.yaml"), """
    targets:
      - name: check
        cost_class: offline-complete
        rank: 0
        dependencies: []
        provider_backed: false
        owner: fixture
    """)

    File.write!(
      Path.join(dir, ".gitignore"),
      ".kogen/build.lock\n.kogen/runtime/\n.kogen/intents/approved/\n"
    )

    File.mkdir_p!(Path.join(dir, ".kogen"))
    File.write!(Path.join(dir, ".kogen/config.yaml"), config())

    for {path, content} <- [
          {"dummy.txt", "baseline\n"},
          {"keep.txt", "preserved\n"},
          {"retired.txt", "retired\n"},
          {@selector, "# focused selector\n"}
        ] do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    intent = Path.join(dir, ".kogen/intents/approved/#{@slug}")
    File.mkdir_p!(intent)

    File.write!(Path.join(intent, "intent.yaml"), """
    id: 01960000-0000-7000-8000-0000000c0de1
    slug: #{@slug}
    title: Controller handoff fixture
    may_change_guarded_paths: [dummy.txt, keep.txt, retired.txt, #{@late_selector}]
    """)

    scenarios =
      if Keyword.get(opts, :late_selector),
        do: scenarios_data() ++ [late_scenario()],
        else: scenarios_data()

    File.write!(Path.join(intent, "scenarios.yaml"), Jason.encode!(scenarios))
    File.write!(Path.join(intent, "risks.yaml"), Jason.encode!(risks_data()))

    # Build admission copies control deps/ into each Candidate.

    File.mkdir_p!(Path.join(dir, "deps"))

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "baseline"])
    dir
  end

  defp scenarios_data do
    [
      scenario("s-change", [@selector], ["dummy.txt"]),
      scenario("s-preserve", [@selector], ["keep.txt", "retired.txt"])
    ]
  end

  defp late_scenario, do: scenario("s-late", [@late_selector], [@late_selector])

  defp scenario(id, offline, affected) do
    %{
      "id" => id,
      "given" => "a fixture Candidate",
      "when" => "Build settles the Developer turn",
      "then" => "controller code builds the handoff report",
      "wrong_result" => "the Developer's message decides the report",
      "verified_by" => ["check"],
      "evidence" => "scripted provider",
      "proof" => %{
        "offline" => offline,
        "paid_target" => "none",
        "paid_reason" => "offline-sufficient: scripted provider drives the real Build consumer",
        "affected_paths" => affected
      }
    }
  end

  defp risks_data do
    [
      %{
        "id" => "r-shared",
        "scenario_ids" => ["s-change", "s-preserve"],
        "description" => "fixture"
      },
      %{"id" => "r-preserve", "scenario_ids" => ["s-preserve"], "description" => "fixture"}
    ]
  end

  defp config do
    """
    default_route: codex
    routes:
      codex:
        harness: codex
        shaping:   {model: fake, effort: low}
        developer: {model: fake, effort: low}
        reviewer:  {model: fake, effort: low}
        helpers:
          scout:  {model: fake, effort: low}
          worker: {model: fake, effort: medium}
          expert: {model: fake, effort: medium}
    outer_resumptions: 2
    verification_retries: 2
    offline_retries: 4
    """
  end

  # A Codex-protocol provider: Developer turns apply HANDOFF_EDIT_<call>,
  # settle the real Stop hook and end with notes-<call> (or default prose);
  # Reviewers answer HANDOFF_REVIEWS in order through scenario_response.py.
  defp provider do
    ~S'''
    #!/usr/bin/env python3
    import json, os, pathlib, subprocess, sys
    # Scratch state a test reads back after the Build lives in the Build's
    # harness home (publication removes the Candidate); outside a Build it
    # falls back to the cwd's ignored .kogen/runtime.
    home = os.environ.get("KOGEN_HARNESS_HOME")
    runtime = pathlib.Path(home) / "fake-state" if home else pathlib.Path(".kogen/runtime")
    runtime.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]; prompt = sys.stdin.read()
    def count(name):
        path = runtime / name
        value = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(value)); return value
    def listed(name, value):
        return str(value) in [item for item in os.environ.get(name, "").split(",") if item]
    if os.environ.get("KOGEN_ROLE") == "reviewer":
        n = count("reviews")
        # `reviewer-reask-once`: a resume reuses the exact requested thread
        # id, never a freshly minted one.
        is_resume = "resume" in args
        resume_id = args[args.index("resume") + 1] if is_resume else None
        sid = resume_id or f"review-{n}"
        (runtime / f"reviewer-prompt-{n}").write_text(prompt)
        verdicts = os.environ.get("HANDOFF_REVIEWS", "accept").split(",")
        verdict = verdicts[min(n, len(verdicts)) - 1]
        out = args[args.index("--output-last-message") + 1]
        # A real Reviewer resume continues the same conversation, so it still
        # has the original task context. This fake harness's re-ask prompt
        # (the schema-error text) carries none, so it reuses the most recent
        # fresh launch's stored prompt (never a resume's own, and never an
        # older attempt's) to rebuild the same scenario/candidate context on
        # resume.
        fresh_prompt_path = runtime / "reviewer-prompt-latest-fresh"
        if not is_resume:
            fresh_prompt_path.write_text(prompt)
        context_prompt = fresh_prompt_path.read_text() if is_resume else prompt
        response = subprocess.run([sys.executable, os.environ["HANDOFF_RESPONSE_HELPER"], "reviewer", verdict],
                                  input=context_prompt, capture_output=True, text=True, check=True).stdout
        # A comma list, one entry per Review call (fresh launch, then its one
        # resume): `valid`, `invalid` (strips the first evidence item's
        # `receipt`, so it fails the per-launch schema) or `changed` (stays
        # schema-valid but flips `verdict`, a control for "the repair must
        # keep its verdict value").
        reask_modes = [item for item in os.environ.get("HANDOFF_REASK", "").split(",") if item]
        if len(reask_modes) >= n:
            mode = reask_modes[n - 1]
            value = json.loads(response)
            if mode == "invalid":
                del value["scenarios"][0]["evidence"][0]["receipt"]
            elif mode == "missing_path":
                # Schema-valid, but the Contract rejects a path that does not exist.
                value["scenarios"][0]["evidence"][0]["path"] = "reask-probe-missing.md"
            elif mode == "changed":
                value["verdict"] = "rework" if value["verdict"] == "accept" else "accept"
            response = json.dumps(value)
        pathlib.Path(out).write_text(response)
        print(json.dumps({"type": "thread.started", "thread_id": sid}))
        print(json.dumps({"type": "turn.completed", "thread_id": sid}))
        raise SystemExit(0)
    if "--output-last-message" in args or "--output-schema" in args:
        raise SystemExit("Developer turn carried a handoff output schema")
    session = "developer-session"
    if prompt.startswith("Controller verification failed after your turn"):
        # The controller resumed this same Developer call after a failed
        # cycle. A real Developer fixing a failure changes the Candidate;
        # this fake one does too (unless the test freezes this resume
        # number), so the controller's unchanged-Candidate stop is never hit
        # by accident.
        call = int((runtime / "developer-calls").read_text())
        n = count("verification-resumes")
        (runtime / f"verification-resume-{n}").write_text(prompt)
        if not listed("HANDOFF_FREEZE_RESUME_EDIT", n):
            with open("dummy.txt", "a") as f:
                f.write(f"resume-{n}\n")
    else:
        call = count("developer-calls")
        (runtime / f"developer-prompt-{call}").write_text(prompt)
        edit = os.environ.get(f"HANDOFF_EDIT_{call}")
        if edit: subprocess.run(["sh", "-c", edit], check=True)
    for _ in range(8):
        hook = subprocess.run(["sh", ".codex/hooks/check.sh"], input=json.dumps({"session_id": session, "thread_id": session}).encode(),
                              capture_output=True, check=True)
        answer = json.loads(hook.stdout)
        if "continue" in answer: break
    notes_file = pathlib.Path(os.environ["HANDOFF_NOTES_DIR"]) / f"notes-{call}"
    notes = notes_file.read_text() if notes_file.exists() else "All scenarios are done; nothing is unfinished."
    print(json.dumps({"type": "thread.started", "thread_id": session}))
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": notes}}))
    print(json.dumps({"type": "turn.completed", "thread_id": session}))
    '''
  end

  defp task_context!(prompt) do
    lines = String.split(prompt, "\n")
    index = Enum.find_index(lines, &(&1 == "KOGEN_TASK_CONTEXT"))
    lines |> Enum.at(index + 1) |> Jason.decode!()
  end

  defp record!(dir), do: records(dir) |> List.last() |> File.read!() |> Jason.decode!()

  defp records(dir),
    do: Path.wildcard(Path.join(dir, ".kogen/runtime/scenario-tracking/*/record.json"))

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp realpath!(path) do
    {out, 0} = System.cmd("/bin/pwd", ["-P"], cd: Path.dirname(path))
    Path.join(String.trim(out), Path.basename(path))
  end

  defp commit_all!(dir) do
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "fixture baseline"])
  end

  defp git!(dir, args) do
    {_output, 0} =
      System.cmd("git", args,
        cd: dir,
        env: [
          {"GIT_AUTHOR_NAME", "Fixture"},
          {"GIT_AUTHOR_EMAIL", "fixture@example.invalid"},
          {"GIT_COMMITTER_NAME", "Fixture"},
          {"GIT_COMMITTER_EMAIL", "fixture@example.invalid"}
        ]
      )
  end

  # `reviewer-reask-once`: an invalid verdict with a known session id gets
  # exactly one resume (`Kogen.Harness.resume_reviewer`), asking only for a
  # corrected verdict in the same shape, never a new judgement. `provider()`'s
  # `HANDOFF_REASK` scripts a fresh fake Reviewer's verdict per Review call
  # (the fresh launch, then its one resume), each `invalid` (strips the first
  # evidence item's `receipt`, so it fails the per-launch schema), `valid` or
  # `changed` (schema-valid, but flips `verdict`).
  describe "reviewer re-ask" do
    test "an invalid verdict repaired on the one re-ask settles, in the same session id" do
      dir = fixture!()

      assert :ok = run(dir, reask: ["invalid", "valid"])

      # One fresh Review, plus its one re-ask resume; both kept the same
      # thread id (`provider()` echoes the requested resume id).
      assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "2"
      [attempt] = record!(dir)["attempts"]
      assert attempt["verdict"]["verdict"] == "accept"
      refute Map.has_key?(attempt, "invalid_verdict")
      refute Map.has_key?(attempt, "invalid_verdict_reask")
      assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    end

    test "a second invalid verdict stops the Build, keeping both invalid payloads" do
      dir = fixture!()

      assert {:error, reason} = run(dir, reask: ["invalid", "invalid"])

      assert reason =~ "Reviewer failure:"
      assert reason =~ "unrepaired on re-ask"
      assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "2"
      [attempt] = record!(dir)["attempts"]
      assert attempt["invalid_verdict"]["reviewer_session_id"] == "review-1"
      assert attempt["invalid_verdict_reask"]["reviewer_session_id"] == "review-1"
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    end

    test "a schema-valid verdict the Contract rejects (a missing evidence path) gets the same one re-ask, naming the Contract's error" do
      dir = fixture!()

      assert :ok = run(dir, reask: ["missing_path", "valid"])

      assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "2"
      reask = File.read!(Kogen.CandidateFixture.fake_state(dir, "reviewer-prompt-2"))
      assert reask =~ "Do not form a new judgement"
      assert reask =~ "reask-probe-missing.md"
      [attempt] = record!(dir)["attempts"]
      assert attempt["verdict"]["verdict"] == "accept"
      assert File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    end

    test "a second Contract rejection after the re-ask stops the Build, keeping both payloads" do
      dir = fixture!()

      assert {:error, reason} = run(dir, reask: ["missing_path", "missing_path"])

      assert reason =~ "unrepaired on re-ask"
      assert reason =~ "reask-probe-missing.md"
      assert File.read!(Kogen.CandidateFixture.fake_state(dir, "reviews")) == "2"
      [attempt] = record!(dir)["attempts"]
      assert get_in(attempt, ["invalid_verdict", "verdict"]) == "accept"
      assert get_in(attempt, ["invalid_verdict_reask", "verdict"]) == "accept"
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    end

    test "a repair that changes the verdict value stops the Build instead of settling it" do
      dir = fixture!()

      assert {:error, reason} = run(dir, reask: ["invalid", "changed"])

      assert reason =~ "Reviewer failure:"
      assert reason =~ "unrepaired on re-ask"
      [attempt] = record!(dir)["attempts"]
      assert attempt["invalid_verdict_reask"]["reason"] =~ "changed its verdict value"
      refute File.dir?(Path.join(dir, ".kogen/intents/complete/#{@slug}"))
    end
  end

  # handoff-lists-all-evidence: the resumed Developer's prompt is rendered
  # from committed, verbatim excerpts of real mined receipts
  # (test/support/mined_failures, each with its provenance header).
  describe "verification failure handoff from real mined receipts" do
    alias Kogen.Build.FailureHandoff

    @mined Path.expand("../support/mined_failures", __DIR__)
    @control "/control/root"
    @candidate "/candidate/root"
    @private ~w(context.json state.json state-history.jsonl verification-history)

    test "every failed receipt, prepare receipt and manifest entry is listed with its class, locators, digests and primary lines" do
      check = mined!("a2spfuvf_c2_check")
      quality = mined!("r9oe4fcp_c2_live_shaping_quality")
      suite = mined!("r9oe4fcp_suite_failure")
      case_log = mined!("r9oe4fcp_stateful_flawed_case_log")

      evidence = %{
        "manifest" => %{"path" => "evidence/manifest.json", "sha256" => sha("manifest")},
        "required_evidence" => [
          entry("evidence/suite-failure.json", suite["output"]),
          entry("evidence/stateful-flawed-output.log", case_log["output"])
        ]
      }

      cycle = %{
        "sequence" => 2,
        "candidate_id" => String.duplicate("c", 40),
        "class" => "paid",
        "receipts" => [
          receipt("check", "passed", "all good", false),
          Map.put(
            receipt("live-shaping-quality", "failed", quality["output"], true),
            "target_evidence",
            evidence
          )
        ],
        "prepare" => [
          Map.merge(receipt("live-reviewer-rework", "failed", check["output"], false), %{
            "kind" => "prepare",
            "class" => "offline"
          }),
          Map.merge(receipt("live-shaping-smoke", "passed", "", false), %{"kind" => "prepare"})
        ],
        "failure" => %{
          "kind" => "target",
          "target" => "live-shaping-quality",
          "class" => "paid",
          "log_path" => log("live-shaping-quality"),
          "log_sha256" => sha("live-shaping-quality"),
          "output" => quality["output"]
        }
      }

      prompt = render(cycle, %{"failures_since_pass" => 1, "offline_failures" => 3})

      # Every failed receipt of the cycle, and only those, with its class.
      assert prompt =~ "### `prepare-live-reviewer-rework`"
      assert prompt =~ "### `live-shaping-quality`"
      refute prompt =~ "### `check`"
      refute prompt =~ "### `prepare-live-shaping-smoke`"
      assert prompt =~ "- Class: `offline`"
      assert prompt =~ "- Class: `paid`"

      # Retained receipt and log locators with their digests.
      for name <- ["prepare-live-reviewer-rework", "live-shaping-quality"] do
        assert prompt =~ "/receipts/cycle-2-#{name}.json"
      end

      for target <- ["live-reviewer-rework", "live-shaping-quality"] do
        assert prompt =~ "`#{Path.join(@control, log(target))}` (sha256 #{sha(target)})"
      end

      # The manifest and each entry, alike, with its digest and an excerpt
      # of its own content.
      assert prompt =~
               "`#{Path.join(@candidate, "evidence/manifest.json")}` (sha256 #{sha("manifest")})"

      assert prompt =~
               "`#{Path.join(@candidate, "evidence/suite-failure.json")}` (sha256 #{sha_of(suite["output"])})"

      assert prompt =~
               "`#{Path.join(@candidate, "evidence/stateful-flawed-output.log")}` (sha256 #{sha_of(case_log["output"])})"

      assert prompt =~ "stateful-flawed: child exited 1"
      assert prompt =~ "no .kogen/runtime/shaping-audits/eval-stateful-flawed was produced"

      # Primary failure lines: the real assertion sits 232 of 262 non-blank
      # lines from the end of a2sPFUvF's cycle-2 receipt, so a tail misses it.
      assert prompt =~ "test/kogen/intent_test.exs:102"
      assert prompt =~ ~s(assert config.route == "claude")
      assert prompt =~ "five-session shaping evaluation failed"

      # The remaining retries of both classes.
      assert prompt =~ "Offline (`offline_retries`) retries left: 1 of 4"
      assert prompt =~ "Paid (`verification_retries`) retries left: 1 of 2"

      refute_private!(prompt)
    end

    test "a frame-carrying receipt gives the frame's lines, and the whole prompt stays within its bound" do
      frame =
        ~s(KOGEN_FAILURE_SIGNATURE\t{"stage":"mix test","test_id":"Kogen.IntentTest:102","assertion":"assert config.route == \\"claude\\""})

      noise = String.duplicate("noise line that is not a failure\n", 4_000)

      long = mined!("a2spfuvf_c2_check")["output"]

      receipts =
        [receipt("target-1", "failed", noise <> frame <> "\n" <> noise, false)] ++
          for n <- 2..30, do: receipt("target-#{n}", "failed", long, false)

      cycle = %{
        "sequence" => 5,
        "candidate_id" => String.duplicate("d", 40),
        "class" => "offline",
        "receipts" => receipts,
        "failure" => %{
          "kind" => "target",
          "target" => "target-1",
          "class" => "offline",
          "log_path" => log("target-1"),
          "log_sha256" => sha("target-1"),
          "output" => noise
        }
      }

      prompt = render(cycle, %{"failures_since_pass" => 0, "offline_failures" => 1})

      assert byte_size(prompt) <= 24_000
      assert prompt =~ "test: Kogen.IntentTest:102"
      assert prompt =~ ~s(assertion: assert config.route == "claude")
      assert prompt =~ "### `target-1`"
      assert prompt =~ ~r/further failed receipt\(s\) omitted|section truncated/
      refute_private!(prompt)
    end

    test "the mined excerpts carry their provenance headers" do
      for name <-
            ~w(a2spfuvf_c2_check r9oe4fcp_c2_live_shaping_quality r9oe4fcp_suite_failure r9oe4fcp_stateful_flawed_case_log) do
        provenance = mined!(name)["provenance"]

        for key <- ~w(build_id cycle source_record_path sha256),
            do: assert(provenance[key], "#{name} lacks provenance #{key}")
      end
    end

    defp render(cycle, state) do
      FailureHandoff.render(%{
        cycle: cycle,
        state: state,
        context: %{
          "verification_retries" => 2,
          "offline_retries" => 4,
          "control_root" => @control,
          "project_root" => @control
        },
        control: @control,
        candidate_root: @candidate,
        receipt_path: fn sequence, name ->
          Path.join([@control, ".kogen/runtime/receipts", "cycle-#{sequence}-#{name}.json"])
        end
      })
    end

    defp refute_private!(prompt) do
      for private <- @private, do: refute(prompt =~ private)
    end

    defp mined!(name), do: Path.join(@mined, name <> ".json") |> File.read!() |> Jason.decode!()

    defp receipt(target, status, output, provider_backed?) do
      %{
        "target" => target,
        "status" => status,
        "exit_code" => if(status == "passed", do: 0, else: 2),
        "timed_out" => false,
        "provider_backed" => provider_backed?,
        "log_path" => log(target),
        "log_sha256" => sha(target),
        "output" => output
      }
    end

    defp entry(path, content),
      do: %{
        "path" => path,
        "sha256" => sha_of(content),
        "content_base64" => Base.encode64(content)
      }

    defp log(target), do: ".kogen/runtime/logs/cycle-2-#{target}.log"
    defp sha(label), do: sha_of("log " <> label)
    defp sha_of(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end
end
