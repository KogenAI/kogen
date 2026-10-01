Code.require_file("../support/generic_project_fixture.ex", __DIR__)

defmodule Kogen.DeveloperGuardRebindTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{ReviewPacket, Tracking}
  alias Kogen.CandidateFixture
  alias Kogen.GenericProjectFixture, as: Fixture

  @source "dummy.txt"
  @frozen ".kogen/runtime/frozen-proof.txt"
  @approved ".kogen/intents/approved/generic-project/intent.yaml"
  @root Path.expand("../..", __DIR__)

  @tag timeout: 120_000
  test "timeout after Review-cited repair records one same-session nudge" do
    dir = fixture!("timeout")
    assert :ok = Fixture.run(dir, reviews: "rework,accept")
    attempt = attempt!(dir)
    before = observation!(dir, 2)

    assert_review_binding!(before)

    assert [%{"nudge" => 1, "session_id" => "developer-session", "turn_minutes" => 1}] =
             attempt["turn_nudges"]

    assert state!(dir, "developer-call-3.json")["session"] == "developer-session"
    assert state!(dir, "developer-call-3.json")["prompt"] == Kogen.Build.turn_nudge_prompt(1, 1)

    assert state!(dir, "developer-call-3.json")["args"] =~
             ~r/^exec resume .*developer-session -$/

    assert observation!(dir, 3)["developer_invocation"]["outcome"] == "turn_timeout"
    assert_uncharged!(before, observation!(dir, 3))
    assert_history!(dir, before, attempt)
    assert_reverification!(attempt)
    assert attempt["verdict"]["verdict"] == "accept"
    assert List.wrap(attempt["provider_retries"]) == []
  end

  test "transport retry after Review-cited repair preserves policy" do
    dir = fixture!("transport")
    assert :ok = Fixture.run(dir, reviews: "rework,accept")
    before = observation!(dir, 2)
    attempt = attempt!(dir)

    assert_review_binding!(before)

    assert [%{"session_id" => "developer-session", "backoff_minutes" => 1} = retry] =
             attempt["provider_retries"]

    assert retry["role"] == "developer"
    assert retry["marker"]["retry"] == true
    assert retry["marker"]["kind"] == "overload"

    assert state!(dir, "developer-call-2.json")["prompt"] ==
             state!(dir, "developer-call-3.json")["prompt"]

    assert state!(dir, "developer-call-3.json")["session"] == "developer-session"

    assert state!(dir, "developer-call-3.json")["args"] =~
             ~r/^exec resume .*developer-session -$/

    assert_uncharged!(before, observation!(dir, 3))
    assert List.wrap(attempt["turn_nudges"]) == []
    assert_history!(dir, before, attempt)
    assert_reverification!(attempt)
  end

  test "generic harness error after cited repair keeps harness failure" do
    # Native adapters wrap provider exits as transport failures. This test-local
    # adapter scripts the generic error result at that boundary; all Build,
    # Review, citation, guard and stop code runs unchanged.
    install_generic_adapter!()
    dir = fixture!("generic")
    assert {:error, reason} = Fixture.run(dir, reviews: "rework,accept")
    assert reason =~ "harness failure during Developer turn: :guard_rebind_generic_failure"
    refute reason =~ "bound evidence reference mutated"
    attempt = attempt!(dir)
    before = observation!(dir, 2)
    assert_review_binding!(before)
    assert_history!(dir, before, attempt)
    assert_no_retry!(dir, attempt)
    assert reason =~ "category: provider-failure"
    assert length(verification_state!(dir, attempt)["cycles"]) == 1
  end

  test "fresh same-tree citations survive repeated guard rebinding" do
    install_guard_probe!()
    Process.put(:guard_rebind_observations, [])

    Process.put(:guard_rebind_callback, fn
      {:ok, ctx} = result ->
        if fresh_source_binding?(ctx) do
          second = run_guard(ctx)
          third = repeat_guard(second)
          observations = Process.get(:guard_rebind_observations)
          Process.put(:guard_rebind_observations, observations ++ [{result, second, third}])
          third
        else
          result
        end

      result ->
        result
    end)

    dir = fixture!("fresh")
    assert {:error, reason} = Fixture.run(dir, reviews: "rework,rework,accept")
    assert reason =~ "Candidate unchanged since failed cycle"
    refute reason =~ "integrity"
    observations = Process.get(:guard_rebind_observations)
    assert length(observations) == 3

    for {{:ok, first}, {:ok, second}, {:ok, third}} <- observations do
      assert first.references == second.references
      assert first.references == third.references
      assert last_attempt(first) == last_attempt(second)
      assert last_attempt(first) == last_attempt(third)
      assert first.review_packet == second.review_packet
      assert first.review_packet == third.review_packet
      assert first.references[@source]["sha256"] == sha256("baseline\nrepair\n")
      assert last_attempt(first)["provisional_review"]["verdict"] == "rework"

      assert last_attempt(first)["reviewer_reference_snapshots"][@source] ==
               first.references[@source]

      assert first.review_packet["candidate_id"] == last_attempt(first)["candidate_id"]
      assert :ok = Tracking.verify_artifacts(third.tracking)
      assert :ok = ReviewPacket.verify(third.review_packet, dir)
    end

    attempt = attempt!(dir)
    assert_history!(dir, observation!(dir, 2), attempt)

    assert_reverification!(Map.put(attempt, "verification", verification_state!(dir, attempt)), [
      "failed",
      "failed"
    ])

    assert length(attempt["provider_retries"]) == 2
  end

  test "fresh current packet binding remains enforceable after repeated rebinding" do
    install_guard_probe!()

    Process.put(:guard_rebind_callback, fn
      {:ok, ctx} = result ->
        if fresh_source_binding?(ctx) do
          assert {:ok, repeated} = run_guard(ctx)
          assert repeated.references == ctx.references
          path = Path.expand(ctx.review_packet["path"], ctx.control)
          File.write!(path, File.read!(path) <> "mutated")
          run_guard(repeated)
        else
          result
        end

      result ->
        result
    end)

    dir = fixture!("fresh")
    assert {:error, reason} = Fixture.run(dir, reviews: "rework,rework,accept")
    assert reason =~ "review packet"
    assert reason =~ "category: integrity"
    attempt = attempt!(dir)
    assert attempt["reference_snapshots"][@source]["sha256"] == sha256("baseline\nrepair\n")
    assert List.wrap(attempt["provider_retries"]) == []
    assert_history!(dir, observation!(dir, 2), attempt)
  end

  test "source repair does not forgive frozen Approved mutation" do
    dir = fixture!("approved")
    assert {:error, reason} = Fixture.run(dir, reviews: "rework,accept")
    assert reason =~ "Approved Intent changed during Build"
    assert reason =~ "category: integrity"
    before = observation!(dir, 2)
    attempt = attempt!(dir)
    assert_review_binding!(before, @approved)
    assert attempt["reference_snapshots"][@approved] == before["reference_snapshots"][@approved]
    assert_history!(dir, before, attempt)
    assert_retained!(dir, before["reference_snapshots"][@approved])
    assert_no_retry!(dir, attempt)
  end

  test "source repair preserves frozen non-source citation live guard" do
    dir = fixture!("frozen")
    assert {:error, reason} = Fixture.run(dir, reviews: "rework,accept")
    candidate = CandidateFixture.worktree(dir)
    assert reason =~ "bound evidence reference mutated: #{Path.join(candidate, @frozen)}"
    assert reason =~ "category: integrity"
    before = observation!(dir, 2)
    attempt = attempt!(dir)
    assert_review_binding!(before, @frozen)
    assert attempt["reference_snapshots"][@frozen] == before["reference_snapshots"][@frozen]
    assert_retained!(dir, attempt["reference_snapshots"][@frozen], "frozen evidence\n")
    assert File.read!(Path.join(candidate, @frozen)) == "mutated evidence\n"
    assert_history!(dir, before, attempt)
    assert_no_retry!(dir, attempt)
  end

  test "unchanged source still enforces frozen non-source citation" do
    dir = fixture!("unchanged-frozen")
    assert {:error, reason} = Fixture.run(dir, reviews: "rework,accept")
    assert reason =~ "bound evidence reference mutated:"
    assert reason =~ @frozen
    before = observation!(dir, 2)
    attempt = attempt!(dir)
    assert_review_binding!(before, @frozen)
    assert attempt["candidate_id"] == before["candidate_id"]

    assert List.wrap(attempt["reference_snapshot_history"]) ==
             List.wrap(before["reference_snapshot_history"])

    assert attempt["reference_snapshots"][@frozen] == before["reference_snapshots"][@frozen]
    assert_retained!(dir, attempt["reference_snapshots"][@frozen], "frozen evidence\n")
    assert_no_retry!(dir, attempt)
  end

  defp fixture!(mode) do
    dir = Fixture.fixture!(test_fails: 0)
    File.write!(Path.join(dir, "provider.py"), provider())
    config = Path.join(dir, ".kogen/config.yaml")
    File.write!(config, File.read!(config) <> "developer_turn_minutes: 1\n")

    if mode == "fresh" do
      makefile = Path.join(dir, "Makefile")
      File.write!(makefile, String.replace(File.read!(makefile), "-lt 1", "-lt 2"))
    end

    git!(dir, ["add", "provider.py", ".kogen/config.yaml", "Makefile"])
    git!(dir, ["commit", "-q", "-m", "guard fixture"])
    System.put_env("GUARD_REBIND_MODE", mode)
    on_exit(fn -> System.delete_env("GUARD_REBIND_MODE") end)
    dir
  end

  defp attempt!(dir), do: List.last(Fixture.record!(dir)["attempts"])
  defp last_attempt(ctx), do: List.last(ctx.tracking.record["attempts"])

  defp state!(dir, name),
    do: dir |> CandidateFixture.fake_state(name) |> File.read!() |> Jason.decode!()

  defp observation!(dir, call), do: state!(dir, "developer-call-#{call}.json")["attempt"]

  defp assert_review_binding!(attempt, frozen \\ nil) do
    review = attempt["provisional_review"]
    assert review["verdict"] == "rework"

    assert attempt["reviewer_reference_snapshots"][@source] ==
             attempt["reference_snapshots"][@source]

    assert attempt["reference_snapshots"][@source]["sha256"] == sha256("baseline\n")
    assert attempt["review_packet"]["candidate_id"] == attempt["candidate_id"]

    if frozen do
      assert attempt["reviewer_reference_snapshots"][frozen] ==
               attempt["reference_snapshots"][frozen]

      assert is_map(attempt["reference_snapshots"][frozen])
    end
  end

  defp assert_uncharged!(before, after_attempt) do
    for field <- ~w(number guard_resumptions_spent) do
      assert before[field] == after_attempt[field]
    end

    assert is_integer(before["progress"]["developer_resumptions"])

    assert before["progress"]["developer_resumptions"] ==
             after_attempt["progress"]["developer_resumptions"]

    assert before["progress"]["limits"] == after_attempt["progress"]["limits"]

    assert before["verification_context"] == after_attempt["verification_context"]
  end

  defp assert_history!(dir, before, attempt) do
    history = List.wrap(attempt["reference_snapshot_history"])
    assert length(Enum.uniq(history)) == length(history)

    entry =
      Enum.find(history, &(&1["snapshots"][@source] == before["reference_snapshots"][@source]))

    assert entry
    assert entry["candidate_id"] == before["candidate_id"]
    refute entry["candidate_id"] == attempt["candidate_id"]
    assert entry["snapshots"][@source] == before["reference_snapshots"][@source]
    assert_retained!(dir, entry["snapshots"][@source], "baseline\n")

    for historical <- history,
        historical["snapshots"][@source] == before["reference_snapshots"][@source] do
      assert historical["candidate_id"] == before["candidate_id"]
    end

    assert before["review_packet"] in attempt["superseded_review_packets"]
    assert :ok = ReviewPacket.verify(before["review_packet"], dir)
  end

  defp assert_retained!(dir, snapshot, expected \\ nil) do
    bytes = File.read!(Path.expand(snapshot["sidecar"], dir))
    assert byte_size(bytes) == snapshot["byte_count"]
    assert sha256(bytes) == snapshot["sha256"]
    if expected, do: assert(bytes == expected)
  end

  defp assert_reverification!(attempt, statuses \\ ["failed", "passed"]) do
    cycles = attempt["verification"]["cycles"]
    assert Enum.map(cycles, & &1["status"]) == statuses
    [old, repaired] = cycles
    refute old["candidate_id"] == repaired["candidate_id"]
    assert repaired["candidate_id"] == attempt["candidate_id"]
    assert Enum.map(repaired["receipts"], & &1["target"]) == ["test", "e2e"]
    assert Enum.all?(repaired["receipts"], &(&1["candidate_id"] == repaired["candidate_id"]))
    assert Enum.all?(repaired["receipts"], &is_nil(&1["reused_from"]))
  end

  defp assert_no_retry!(dir, attempt) do
    assert state!(dir, "developer-call-2.json")["session"] == "developer-session"
    refute File.exists?(CandidateFixture.fake_state(dir, "developer-call-3.json"))
    assert List.wrap(attempt["turn_nudges"]) == []
    assert List.wrap(attempt["provider_retries"]) == []
    assert attempt["number"] == 0
    assert (attempt["guard_resumptions_spent"] || 0) == 0
  end

  defp fresh_source_binding?(ctx) do
    snapshot = ctx.references[@source]
    is_map(snapshot) and snapshot["sha256"] == sha256("baseline\nrepair\n")
  end

  defp verification_state!(dir, attempt) do
    dir |> Path.join(attempt["budget_state"]["state"]) |> File.read!() |> Jason.decode!()
  end

  defp run_guard(ctx), do: :erlang.make_fun(Kogen.Build, :guard_rebind_probe, 1).(ctx)
  defp repeat_guard({:ok, ctx}), do: run_guard(ctx)
  defp repeat_guard(result), do: result

  # Expose the existing guard only in this isolated test VM, and wrap its
  # caller to repeat it while the actual controller context is still current.
  # No guard return is mocked and no production API/test timing switch is added.
  defp install_guard_probe! do
    source = @root |> Path.join("lib/kogen/build.ex") |> File.read!() |> Code.string_to_quoted!()

    source =
      Macro.postwalk(source, fn
        # Boundary is checked by normal project compilation. This runtime
        # test copy needs no compiler annotation, and its isolated VM has no
        # Mix project stack. All runtime guard and ownership code is retained.
        {:use, _meta, [{:__aliases__, _alias_meta, [:Boundary]} | _options]} ->
          nil

        {:defp, meta, [{:post_developer_inputs_unchanged, call_meta, args}, body]} ->
          {:def, meta, [{:guard_rebind_probe, call_meta, args}, body]}

        ast ->
          ast
      end)

    wrapper =
      quote do
        defp post_developer_inputs_unchanged(ctx) do
          result = guard_rebind_probe(ctx)

          case Process.get(:guard_rebind_callback) do
            nil -> result
            callback -> callback.(result)
          end
        end
      end

    compile_with_wrapper!(source, wrapper)
  end

  defp install_generic_adapter! do
    source =
      @root |> Path.join("lib/kogen/harness/codex.ex") |> File.read!() |> Code.string_to_quoted!()

    source =
      Macro.postwalk(source, fn
        {:defp, meta, [{:notes_turn, call_meta, args}, body]} ->
          {:defp, meta, [{:scripted_notes_turn, call_meta, args}, body]}

        ast ->
          ast
      end)

    wrapper =
      quote do
        defp notes_turn(args, text, environment, session, context) do
          case scripted_notes_turn(args, text, environment, session, context) do
            {:error, {:developer_transport_failure, _reason, %{output_tail: tail}}} = result ->
              if tail =~ "guard-rebind-generic-error",
                do: {:error, :guard_rebind_generic_failure},
                else: result

            result ->
              result
          end
        end
      end

    compile_with_wrapper!(source, wrapper)
  end

  defp compile_with_wrapper!({:defmodule, meta, [name, [do: body]]}, wrapper) do
    ast = {:defmodule, meta, [name, [do: {:__block__, [], [body, wrapper]}]]}
    options = Code.compiler_options(ignore_module_conflict: true)

    try do
      Code.compile_quoted(ast)
    after
      Code.compiler_options(options)
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp git!(dir, args) do
    assert {_output, 0} =
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

  defp provider do
    ~S'''
    #!/usr/bin/env python3
    import importlib.util, json, os, pathlib, subprocess, sys, time
    sys.dont_write_bytecode = True
    state = pathlib.Path(os.environ["KOGEN_HARNESS_HOME"]) / "fake-state"
    state.mkdir(parents=True, exist_ok=True)
    args = sys.argv[1:]
    prompt = sys.stdin.read()
    mode = os.environ["GUARD_REBIND_MODE"]
    spec = importlib.util.spec_from_file_location("responses", os.environ["HANDOFF_RESPONSE_HELPER"])
    responses = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(responses)
    def count(name):
        path = state / name
        n = int(path.read_text()) + 1 if path.exists() else 1
        path.write_text(str(n))
        return n
    if os.environ.get("KOGEN_ROLE") == "reviewer":
        context = responses.snapshot(prompt)
        addendum = prompt.startswith("KOGEN_EVIDENCE_ADDENDUM")
        n = count("addenda" if addendum else "reviews")
        verdicts = os.environ["HANDOFF_REVIEWS"].split(",")
        verdict = "accept" if addendum else verdicts[min(n, len(verdicts)) - 1]
        os.environ["KOGEN_SCENARIO_EVIDENCE_PATH"] = "dummy.txt"
        response = responses.reviewer(context, verdict)
        frozen = (".kogen/intents/approved/generic-project/intent.yaml" if mode == "approved"
                  else ".kogen/runtime/frozen-proof.txt" if mode in ("frozen", "unchanged-frozen") else None)
        if frozen:
            for entry in response["scenarios"] + response["findings"]:
                entry["evidence"].append({"path": frozen, "locator": "frozen bytes", "receipt": None})
        pathlib.Path(args[args.index("--output-last-message") + 1]).write_text(json.dumps(response))
        sid = args[args.index("resume") + 1] if addendum else f"review-{n}"
        print(json.dumps({"type": "thread.started", "thread_id": sid}))
        print(json.dumps({"type": "turn.completed", "thread_id": sid}))
        raise SystemExit(0)
    n = count("developer-calls")
    if n == 1:
        context = responses.snapshot(prompt)
        (state / "tracking-path").write_text(context["tracking_path"])
    tracking = pathlib.Path((state / "tracking-path").read_text())
    attempt = json.loads(tracking.read_text())["attempts"][-1]
    sid = "developer-session"
    (state / f"developer-call-{n}.json").write_text(json.dumps({
        "session": sid, "args": " ".join(args), "prompt": prompt, "attempt": attempt}))
    if n == 1:
        evidence = pathlib.Path(".kogen/runtime/frozen-proof.txt")
        evidence.parent.mkdir(parents=True, exist_ok=True)
        evidence.write_text("frozen evidence\n")
    if n == 2:
        if mode != "unchanged-frozen":
            with open("dummy.txt", "a") as source: source.write("repair\n")
        if mode == "approved":
            with open(".kogen/intents/approved/generic-project/intent.yaml", "a") as frozen:
                frozen.write("mutated\n")
        if mode in ("frozen", "unchanged-frozen"):
            pathlib.Path(".kogen/runtime/frozen-proof.txt").write_text("mutated evidence\n")
    print(json.dumps({"type": "thread.started", "thread_id": sid}), flush=True)
    if n == 2 and mode == "timeout":
        time.sleep(90)
    if (n == 2 and mode in ("transport", "approved", "frozen", "unchanged-frozen")) or (mode == "fresh" and n in (3, 4)):
        print(json.dumps({"type": "error", "message": "Server is overloaded; try again later"}), flush=True)
        raise SystemExit(1)
    if n == 2 and mode == "generic":
        print("guard-rebind-generic-error", flush=True)
        raise SystemExit(1)
    print(json.dumps({"type": "item.completed", "item": {"type": "agent_message", "text": "All scenarios are done; nothing is unfinished."}}))
    print(json.dumps({"type": "turn.completed", "thread_id": sid}))
    '''
  end
end
