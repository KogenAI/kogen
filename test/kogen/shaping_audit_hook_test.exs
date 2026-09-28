Code.require_file("../support/shaping_audit/fixture.ex", __DIR__)

defmodule Kogen.ShapingAuditHookTest do
  @moduledoc """
  The Shaping Stop hook (`shaping-stop-hook`): `mix kogen.audit --stop-hook`
  through `Kogen.ShapingAudit.main/2` on the landed layers and audit-only
  fakes, and `priv/kogen/shaping_audit/stop_hook.sh` with the fake `mix`.
  """
  use Kogen.IsolatedCase, async: true

  alias Kogen.ShapingAudit.{Finding, Fixture, StopHook}

  @t 1_790_000_000_000

  @proof_ids [
    "unguarded-affected-path lib/unguarded.ex",
    "proof-selector-missing test/gone_test.exs",
    "proof-selector-missing test/stray_test.exs",
    "unsupported-selector test/a_test.exs:3",
    "unsupported-selector test/**",
    "unsupported-selector /abs/x_test.exs",
    "unsupported-selector ../x_test.exs",
    "paid-reason-malformed not a valid reason",
    "unknown-target live-extra"
  ]

  @ready_summary_tail "\nelapsed: launch 2.0 min, chain 0.0 min, audit 0.0 min (total 0.0 min), " <>
                        "budget 15.0 min\nAssumed:\n- The button keeps its current size. Reason: the " <>
                        "Shaper asked only about colour. Undo: resize it in a follow-up Intent.\n" <>
                        "Left undecided:\n- Whether to support dark mode. Recommendation: defer, " <>
                        "revisit after v1.\nNot audited by the auditor: none"

  @usage "usage: mix kogen.audit [--route <name>] [--auditor] <slug> | " <>
           "mix kogen.audit --status [--route <name>] <slug> | mix kogen.audit --stop-hook"

  # -- Elixir entry helpers ---------------------------------------------------

  defp uuid7(ms) do
    hex = ms |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "#{String.slice(hex, 0, 8)}-#{String.slice(hex, 8, 4)}-7000-8000-000000000001"
  end

  # A clock cycling through `times` (DateTimes from millisecond stamps), and a
  # function returning how often it was read.
  defp clock(times) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    read = fn ->
      n = Agent.get_and_update(agent, &{&1, &1 + 1})
      DateTime.from_unix!(Enum.at(times, rem(n, length(times))), :millisecond)
    end

    {read, fn -> Agent.get(agent, & &1) end}
  end

  defp checkout!(draft, opts \\ []) do
    root = Fixture.repo!()
    on_exit(fn -> File.rm_rf(root) end)
    {root, Fixture.add_draft!(root, draft, opts)}
  end

  # Private copy of test/kogen/shaping_audit_flow_test.exs flow_checkout!/0.
  defp flow_checkout! do
    root = Fixture.repo!(second_commit: false, working_tree: false, prior_failures: false)
    File.mkdir_p!(Path.join(root, "test/kogen"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def ok, do: true\nend\n")
    File.write!(Path.join(root, "test/kogen/demo_test.exs"), "assert true\n")
    {_, 0} = System.cmd("git", ["add", "lib/demo.ex", "test/kogen/demo_test.exs"], cd: root)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "flow: demo"], cd: root)
    root
  end

  defp flow!(state) do
    root = flow_checkout!()
    on_exit(fn -> File.rm_rf(root) end)
    {root, Fixture.add_draft!(root, state, source: "packages/flow")}
  end

  defp intent_id(root, package_rel) do
    {:ok, intent} =
      [root, package_rel, "intent.yaml"]
      |> Path.join()
      |> File.read!()
      |> YamlElixir.read_from_string()

    intent["id"]
  end

  defp hook_env(root, package_rel, extra \\ %{}) do
    root
    |> Fixture.audit_env!()
    |> Map.merge(%{
      "KOGEN_ROLE" => "shaper",
      "KOGEN_SHAPING_INTENT_ID" => intent_id(root, package_rel),
      "KOGEN_SHAPING_ROUTE" => "codex",
      "KOGEN_SHAPING_LAUNCH_ID" => uuid7(@t - 120_000),
      "KOGEN_SHAPING_SKIP_KEY" => "k1",
      "KOGEN_SHAPING_HOOK_OUTPUT" => Path.join(root, "hook-output.json")
    })
    |> Map.merge(extra)
  end

  defp silent_io, do: %{puts: fn _ -> :ok end, err: fn _ -> :ok end}

  # One stop: main/2 returns 0 and the output file holds exactly one JSON value.
  defp stop!(root, env, opts \\ []) do
    output = env["KOGEN_SHAPING_HOOK_OUTPUT"]
    File.rm(output)
    {default_clock, _reads} = clock([@t, @t + 1_500])
    opts = Keyword.merge([stdin: "", clock: default_clock, io: silent_io()], opts)
    assert Kogen.ShapingAudit.main(["--stop-hook"], [root: root, env: env] ++ opts) == 0
    output |> File.read!() |> Jason.decode!()
  end

  defp runtime(root, slug), do: Path.join(root, ".kogen/runtime/shaping-audits/#{slug}")

  defp hook_lines(root, slug) do
    root
    |> runtime(slug)
    |> Path.join("hook.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp hook_state(root, slug),
    do: root |> runtime(slug) |> Path.join("hook-state.json") |> read_json()

  defp prime_state!(root, slug, fields) do
    state =
      Map.merge(
        %{
          "chain_start" => nil,
          "chain_blocks" => 0,
          "last_revision" => nil,
          "last_was_block" => false,
          "audit_total_ms" => 0,
          "auditor_bound_reached" => false,
          "bound_head" => nil,
          "skip_key" => nil,
          "decision" => nil
        },
        fields
      )

    File.mkdir_p!(runtime(root, slug))
    File.write!(Path.join(runtime(root, slug), "hook-state.json"), Jason.encode!(state))
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp report_path(root, slug, revision),
    do: Path.join([runtime(root, slug), revision, "report.json"])

  defp open_ids(report),
    do: report["findings"] |> Enum.filter(&Finding.open_blocking?/1) |> Enum.map(& &1["id"])

  # The block reason INTENT.md states, computed from report.json independently.
  defp expected_reason(path) do
    report = read_json(path)

    lines =
      report["findings"]
      |> Enum.filter(&Finding.open_blocking?/1)
      |> Enum.map(&"- #{&1["id"]} (route: #{&1["route"] || "none"}): #{&1["message"]}")

    advisory = Enum.count(report["findings"], &(&1["severity"] == "advisory"))

    Enum.join(
      ["blocking findings:" | lines] ++ ["advisory: #{advisory}", "report: #{path}"],
      "\n"
    )
  end

  defp append_intent!(root, package_rel, text),
    do: File.write!(Path.join([root, package_rel, "INTENT.md"]), text, [:append])

  # -- stop_hook.sh helpers -----------------------------------------------------

  defp script, do: Path.join(File.cwd!(), "priv/kogen/shaping_audit/stop_hook.sh")

  defp toolchain!(root) do
    toolchain = Path.join(root, "toolchain")
    File.mkdir_p!(toolchain)
    mix = Path.join(toolchain, "mix")
    File.cp!(Path.join(File.cwd!(), "test/support/shaping_audit/fake_mix"), mix)
    File.chmod!(mix, 0o755)
    python = System.find_executable("python3")

    assert {"True\n", 0} =
             System.cmd(python, ["-c", "import sys; print(sys.version_info >= (3, 11))"])

    File.ln_s!(python, Path.join(toolchain, "python3"))
    toolchain
  end

  defp shell_env(root, extra) do
    [
      {"PATH", "/usr/bin:/bin"},
      {"KOGEN_ROLE", "shaper"},
      {"KOGEN_HARNESS_HOME", nil},
      {"KOGEN_ENV_RESTORE_PENDING", nil},
      {"KOGEN_SHAPING_HOOK_OUTPUT", nil},
      {"KOGEN_SHAPING_SKIP_KEY", nil},
      {"KOGEN_FAKE_MIX_DECISION", nil},
      {"KOGEN_SHAPING_TOOLCHAIN_PATH", Path.join(root, "toolchain")},
      {"KOGEN_FAKE_MIX_LOG", Path.join(root, "fake-mix.log")}
    ]
    |> Enum.reject(fn {key, _} -> List.keymember?(extra, key, 0) end)
    |> Kernel.++(extra)
  end

  defp shell_checkout! do
    {root, package_rel} = checkout!("complete")
    toolchain!(root)
    {root, package_rel, [{"KOGEN_SHAPING_INTENT_ID", intent_id(root, package_rel)}]}
  end

  defp sh!(root, extra, cd \\ nil),
    do: System.cmd("sh", [script()], cd: cd || root, env: shell_env(root, extra))

  defp mix_log(root) do
    path = Path.join(root, "fake-mix.log")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.chunk_every(4)
      |> Enum.map(fn [
                       "argv:" <> argv,
                       "PWD:" <> pwd,
                       "PATH:" <> path,
                       "KOGEN_SHAPING_SKIP_KEY:" <> key
                     ] ->
        %{argv: argv, pwd: pwd, path: path, key: key}
      end)
    else
      []
    end
  end

  defp cache!(root, key, decision) do
    File.mkdir_p!(runtime(root, "complete"))

    File.write!(
      Path.join(runtime(root, "complete"), "hook-state.json"),
      Jason.encode!(%{"skip_key" => key, "decision" => decision})
    )
  end

  defp realpath(dir) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: dir)
    String.trim_trailing(out, "\n")
  end

  # The skip key's byte half, computed independently of stop_hook.sh.
  defp bytes_digest(root, package_rel) do
    package = Path.join(root, package_rel)

    package
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn file ->
      hash = :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
      "#{hash}  #{Path.relative_to(file, package)}\n"
    end)
    |> Enum.sort()
    |> Enum.join()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @fake ~s({"continue":true,"systemMessage":"fake"})

  # ---------------------------------------------------------------------------

  test "H1 no package: {\"continue\":true}, no audit" do
    {root, package_rel} = checkout!("complete")

    env =
      hook_env(root, package_rel, %{
        "KOGEN_SHAPING_INTENT_ID" => "01965000-0000-7000-8000-00000000ffff"
      })

    assert stop!(root, env) == %{"continue" => true}
    refute File.exists?(Path.join(root, ".kogen/runtime/shaping-audits"))
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
  end

  test "H2 blocking findings block, naming the finding, its route, the advisory count and the report path" do
    {root, package_rel} = checkout!("proof-defects")
    env = hook_env(root, package_rel)
    decision = stop!(root, env)

    assert Enum.sort(Map.keys(decision)) == ["decision", "reason"]
    assert decision["decision"] == "block"

    [line] = hook_lines(root, "proof-defects")
    path = report_path(root, "proof-defects", line["revision"])
    report = read_json(path)
    assert open_ids(report) == @proof_ids

    assert report["findings"] |> Enum.filter(&Finding.open_blocking?/1) |> Enum.map(& &1["route"]) ==
             List.duplicate(nil, 9)

    assert decision["reason"] == expected_reason(path)

    assert String.ends_with?(
             decision["reason"],
             "\nreport: #{root}/.kogen/runtime/shaping-audits/proof-defects/#{report["revision"]}/report.json"
           )

    assert {line["kind"], line["decision"], line["chain_blocks"], line["blocking"]} ==
             {"blocked", "block", 1, @proof_ids}

    assert {line["report"], line["revision"], line["slug"]} ==
             {path, report["revision"], "proof-defects"}

    state = hook_state(root, "proof-defects")

    assert {state["last_was_block"], state["decision"], state["skip_key"], state["chain_blocks"]} ==
             {true, nil, nil, 1}

    assert report["layers"]["auditor"]["status"] == "skipped"
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
  end

  test "H3 a block reason with many findings stays within 16 KiB" do
    findings =
      for n <- 1..60 do
        %{
          "id" => "f-" <> String.pad_leading(Integer.to_string(n), 2, "0"),
          "route" => nil,
          "message" => String.duplicate("x", 400)
        }
      end

    line = fn n ->
      "- f-#{String.pad_leading(Integer.to_string(n), 2, "0")} (route: none): " <>
        String.duplicate("x", 400)
    end

    reason = StopHook.block_reason(findings, 2, "/r/report.json")
    assert byte_size(reason) == 16_173

    assert String.split(reason, "\n") ==
             ["blocking findings:"] ++
               Enum.map(1..38, line) ++
               [
                 "- … 22 more blocking findings in the report",
                 "advisory: 2",
                 "report: /r/report.json"
               ]

    assert StopHook.block_reason(Enum.take(findings, 3), 2, "/r/report.json") ==
             "blocking findings:\n#{line.(1)}\n#{line.(2)}\n#{line.(3)}\nadvisory: 2\nreport: /r/report.json"
  end

  test "H4 the same revision stopped again is allowed and recorded as stalled" do
    {root, package_rel} = checkout!("proof-defects")
    env = hook_env(root, package_rel)

    assert %{"decision" => "block"} = stop!(root, env)
    assert stop!(root, env) == %{"continue" => true}

    lines = hook_lines(root, "proof-defects")
    assert Enum.map(lines, & &1["kind"]) == ["blocked", "stalled"]
    assert Enum.map(lines, & &1["chain_blocks"]) == [1, 1]
    assert Enum.map(lines, & &1["decision"]) == ["block", "allow"]
    state = hook_state(root, "proof-defects")
    assert {state["chain_start"], state["chain_blocks"]} == {nil, 1}

    append_intent!(root, package_rel, "edited\n")
    third = stop!(root, env)
    line = List.last(hook_lines(root, "proof-defects"))
    path = report_path(root, "proof-defects", line["revision"])
    assert third == %{"decision" => "block", "reason" => expected_reason(path)}
    assert {line["kind"], line["chain_blocks"]} == {"blocked", 2}
    assert hook_state(root, "proof-defects")["chain_blocks"] == 2
  end

  test "H5 nine successive revisions block one to eight and allow the ninth" do
    {root, package_rel} = checkout!("proof-defects")
    env = hook_env(root, package_rel)

    decisions =
      for i <- 1..9 do
        if i > 1, do: File.write!(Path.join([root, package_rel, "INTENT.md"]), "revision #{i}\n")
        stop!(root, env)
      end

    lines = hook_lines(root, "proof-defects")
    assert Enum.map(lines, & &1["kind"]) == List.duplicate("blocked", 8) ++ ["block-limit"]
    assert Enum.map(lines, & &1["chain_blocks"]) == Enum.to_list(1..8) ++ [0]
    assert lines |> Enum.map(& &1["revision"]) |> Enum.uniq() |> length() == 9

    for {decision, line} <- Enum.zip(Enum.take(decisions, 8), lines) do
      path = report_path(root, "proof-defects", line["revision"])
      assert decision == %{"decision" => "block", "reason" => expected_reason(path)}
    end

    ninth = List.last(lines)

    assert List.last(decisions) == %{
             "continue" => true,
             "systemMessage" =>
               "not ready after 8 blocks in this chain; allowing the stop to avoid a trap.\n" <>
                 expected_reason(report_path(root, "proof-defects", ninth["revision"]))
           }

    assert ninth["decision"] == "allow"
    state = hook_state(root, "proof-defects")
    assert {state["chain_blocks"], state["chain_start"]} == {0, nil}
  end

  test "H6 only an environment finding is allowed, naming the fix" do
    {root, package_rel} = checkout!("complete")
    env = hook_env(root, package_rel, %{"KOGEN_SHAPING_ROUTE" => "other"})

    assert stop!(root, env) == %{
             "continue" => true,
             "systemMessage" => "not ready: environment — route other has no auditor setting"
           }

    [line] = hook_lines(root, "complete")
    assert {line["kind"], line["decision"], line["route"]} == {"environment", "allow", "other"}
    report = read_json(line["report"])
    assert report["layers"]["auditor"]["status"] == "unavailable"
    assert report["readiness"] == "not_ready"
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
  end

  defp ready_stop! do
    {root, package_rel} = flow!("ready")
    env = hook_env(root, package_rel)
    {read, reads} = clock([@t, @t + 1_500])
    decision = stop!(root, env, clock: read)
    assert reads.() == 2
    [line] = hook_lines(root, "flow-demo")
    {root, package_rel, env, decision, line}
  end

  test "H7 a ready package is allowed with the presented summary (report path, elapsed, Assumed, Left undecided, not audited)" do
    {root, _package_rel, _env, decision, line} = ready_stop!()
    path = report_path(root, "flow-demo", line["revision"])
    report = read_json(path)
    assert report["readiness"] == "ready"
    assert report["not_audited_by_auditor"] == []

    expected = %{"continue" => true, "systemMessage" => "ready: #{path}" <> @ready_summary_tail}
    assert decision == expected
    assert {line["kind"], line["decision"], line["report"]} == {"ready", "allow", path}

    state = hook_state(root, "flow-demo")

    assert {state["decision"], state["skip_key"], state["last_revision"]} ==
             {expected, "k1", report["revision"]}

    assert :erlang.float_to_binary(121_500 / 60_000, decimals: 1) == "2.0"
  end

  test "H8 an approved package is audited the same way" do
    {root, package_rel} = checkout!("complete", dir: "approved")
    env = hook_env(root, package_rel)
    assert %{"continue" => true, "systemMessage" => "ready: " <> _} = stop!(root, env)
    [line] = hook_lines(root, "complete")
    assert line["kind"] == "ready"
    assert read_json(line["report"])["package"] == ".kogen/intents/approved/complete"
  end

  test "H9 the lock present is allowed with no audit" do
    {root, package_rel} = checkout!("complete")
    File.write!(Path.join(root, ".kogen/build.lock"), "lock\n")
    env = hook_env(root, package_rel)
    assert stop!(root, env) == %{"continue" => true}
    refute File.exists?(Path.join(root, ".kogen/runtime/shaping-audits"))
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
  end

  test "H10 KOGEN_ROLE=developer is allowed with no audit" do
    {root, package_rel} = checkout!("complete")
    env = hook_env(root, package_rel, %{"KOGEN_ROLE" => "developer"})
    assert stop!(root, env) == %{"continue" => true}
    refute File.exists?(Path.join(root, ".kogen/runtime/shaping-audits"))
    refute File.exists?(env["FAKE_AUDITOR_LOG_DIR"])
  end

  defp payload(rollout) do
    Jason.encode!(%{
      "session_id" => "s",
      "transcript_path" => Path.join(File.cwd!(), "test/support/shaping_audit/hook/#{rollout}"),
      "stop_hook_active" => false
    })
  end

  test "H11 a Codex helper thread's Stop event is allowed with no audit" do
    {root, package_rel} = checkout!("proof-defects")
    env = hook_env(root, package_rel)
    assert stop!(root, env, stdin: payload("helper-rollout.jsonl")) == %{"continue" => true}
    refute File.exists?(Path.join(root, ".kogen/runtime/shaping-audits"))
  end

  test "H12 a Codex root's Stop event is audited normally" do
    {root, package_rel} = checkout!("complete")
    env = hook_env(root, package_rel)

    assert %{"continue" => true, "systemMessage" => "ready: " <> _} =
             stop!(root, env, stdin: payload("root-rollout.jsonl"))

    assert [%{"kind" => "ready"}] = hook_lines(root, "complete")
  end

  test "H13 an exception inside the audit is allowed, naming the error and mix kogen.audit <slug>" do
    {root, package_rel} = checkout!("complete")
    env = hook_env(root, package_rel)

    assert stop!(root, env, read: fn _ -> raise "boom" end) == %{
             "continue" => true,
             "systemMessage" => "shaping audit error: boom; run mix kogen.audit complete"
           }

    assert [%{"kind" => "error", "decision" => "allow"}] = hook_lines(root, "complete")

    {root2, package_rel2} = checkout!("complete")
    File.ln_s!("intent.yaml", Path.join([root2, package_rel2, "evil-link"]))

    assert stop!(root2, hook_env(root2, package_rel2)) == %{
             "continue" => true,
             "systemMessage" =>
               "shaping audit error: refusing non-regular package entry: evil-link; " <>
                 "run mix kogen.audit complete"
           }

    assert Kogen.ShapingAudit.error_text({:ambiguous, "m"}) == "m"
    assert Kogen.ShapingAudit.error_text({:not_found, "m"}) == "m"

    assert Kogen.ShapingAudit.error_text({:non_regular, "p"}) ==
             "refusing non-regular package entry: p"

    assert Kogen.ShapingAudit.error_text(:boom) == "mix kogen.audit failed: :boom"

    # An error is never cached.
    {root3, package_rel3} = checkout!("complete")
    env3 = hook_env(root3, package_rel3)
    assert %{"continue" => true, "systemMessage" => "ready: " <> _} = stop!(root3, env3)
    before = hook_state(root3, "complete")
    assert before["skip_key"] == "k1"
    assert is_map(before["decision"])

    assert %{"systemMessage" => "shaping audit error: boom; run mix kogen.audit complete"} =
             stop!(root3, env3, read: fn _ -> raise "boom" end)

    after_error = hook_state(root3, "complete")
    assert {after_error["skip_key"], after_error["decision"]} == {nil, nil}

    assert {after_error["chain_start"], after_error["chain_blocks"]} ==
             {before["chain_start"], before["chain_blocks"]}

    assert Enum.map(hook_lines(root3, "complete"), & &1["kind"]) == ["ready", "error"]

    # stop_hook.sh starts mix again on an unchanged package whose decision is null.
    {root4, _package_rel4, extra} = shell_checkout!()
    assert {@fake, 0} = sh!(root4, [{"KOGEN_FAKE_MIX_DECISION", @fake} | extra])
    [%{key: key}] = mix_log(root4)
    cache!(root4, key, nil)
    assert {@fake, 0} = sh!(root4, [{"KOGEN_FAKE_MIX_DECISION", @fake} | extra])
    assert [%{key: ^key}, %{key: ^key}] = mix_log(root4)
  end

  test "H14 an auditor bound reached with open blocking findings is allowed with the exact message, kind auditor-bound, never blocked again on later stops" do
    {root, package_rel} = checkout!("complete")
    env = hook_env(root, package_rel) |> Map.put("FAKE_AUDITOR_MESSAGE", "three-findings")
    System.put_env("FAKE_AUDITOR_MESSAGE", "three-findings")

    first = stop!(root, env)
    [line1] = hook_lines(root, "complete")
    report1 = read_json(line1["report"])
    ids = open_ids(report1)
    assert length(ids) == 3

    assert Enum.map(Enum.filter(report1["findings"], &(&1["id"] in ids)), & &1["route"]) ==
             ["shaper", "shaper", "shaper"]

    assert first == %{"decision" => "block", "reason" => expected_reason(line1["report"])}
    assert {line1["kind"], line1["blocking"]} == {"blocked", ids}

    bound = %{
      "continue" => true,
      "systemMessage" =>
        "not ready: auditor bound reached; 3 blocking findings remain (#{Enum.join(ids, ", ")})"
    }

    append_intent!(root, package_rel, "second\n")
    assert stop!(root, env) == bound
    line2 = List.last(hook_lines(root, "complete"))
    report2 = read_json(line2["report"])
    assert line2["kind"] == "auditor-bound"
    assert report2["layers"]["auditor"]["bound_reached"] == true
    assert open_ids(report2) == ids

    append_intent!(root, package_rel, "third\n")
    assert stop!(root, env) == bound
    line3 = List.last(hook_lines(root, "complete"))
    assert line3["kind"] == "auditor-bound"
    assert length(Enum.uniq([line1["revision"], line2["revision"], line3["revision"]])) == 3
    assert length(Path.wildcard(Path.join(runtime(root, "complete"), "auditor/*.json"))) == 2
  end

  test "H15 a chain whose first block is stamped 40 minutes ago decides by content only and records chain_ms and complex" do
    primed = %{
      "chain_start" => @t - 2_400_000,
      "chain_blocks" => 1,
      "last_revision" => String.duplicate("0", 64),
      "last_was_block" => true
    }

    {root, package_rel} = checkout!("proof-defects")
    env = hook_env(root, package_rel)
    {constant, _} = clock([@t])
    prime_state!(root, "proof-defects", primed)
    decision = stop!(root, env, clock: constant)
    [line] = hook_lines(root, "proof-defects")
    path = report_path(root, "proof-defects", line["revision"])
    assert decision == %{"decision" => "block", "reason" => expected_reason(path)}
    assert line["blocking"] == @proof_ids

    assert {line["elapsed"]["chain_ms"], line["elapsed"]["complex"], line["elapsed"]["budget_ms"],
            line["chain_blocks"]} == {2_400_000, false, 900_000, 2}

    # The same content on a fresh chain decides identically.
    File.rm_rf!(Path.join(root, ".kogen/runtime/shaping-audits"))
    assert stop!(root, env, clock: constant) == decision

    {root2, package_rel2} = checkout!("proof-defects")

    for n <- 1..11 do
      name = "e" <> String.pad_leading(Integer.to_string(n), 2, "0") <> ".md"
      path = Path.join([root2, package_rel2, "evidence", name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "evidence #{n}\n")
    end

    prime_state!(root2, "proof-defects", primed)
    decision2 = stop!(root2, hook_env(root2, package_rel2), clock: constant)
    [line2] = hook_lines(root2, "proof-defects")
    path2 = report_path(root2, "proof-defects", line2["revision"])
    assert decision2 == %{"decision" => "block", "reason" => expected_reason(path2)}
    assert line2["blocking"] == @proof_ids

    assert {line2["elapsed"]["chain_ms"], line2["elapsed"]["complex"],
            line2["elapsed"]["budget_ms"], line2["chain_blocks"]} ==
             {2_400_000, true, 1_800_000, 2}
  end

  test "H16 a presented stop followed by a new block resets the chain clock" do
    {root, package_rel} = flow!("ready")
    env = hook_env(root, package_rel)
    {constant, _} = clock([@t])
    prime_state!(root, "flow-demo", %{"chain_start" => @t - 2_400_000, "chain_blocks" => 3})

    first = stop!(root, env, clock: constant)
    [line1] = hook_lines(root, "flow-demo")
    path1 = report_path(root, "flow-demo", line1["revision"])

    assert first == %{
             "continue" => true,
             "systemMessage" =>
               "ready: #{path1}" <>
                 String.replace(
                   @ready_summary_tail,
                   "chain 0.0 min, audit 0.0 min (total 0.0 min)",
                   "chain 40.0 min, audit 0.0 min (total 0.0 min)"
                 )
           }

    assert {line1["kind"], line1["elapsed"]["chain_ms"], line1["chain_blocks"]} ==
             {"ready", 2_400_000, 0}

    state1 = hook_state(root, "flow-demo")
    assert {state1["chain_start"], state1["chain_blocks"]} == {nil, 0}

    File.cp!(
      Path.join(
        File.cwd!(),
        "test/support/shaping_audit/packages/flow/assumed-without-reason/questions.md"
      ),
      Path.join([root, package_rel, "questions.md"])
    )

    second = stop!(root, env, clock: constant)
    line2 = List.last(hook_lines(root, "flow-demo"))
    path2 = report_path(root, "flow-demo", line2["revision"])
    assert second == %{"decision" => "block", "reason" => expected_reason(path2)}

    assert {line2["kind"], line2["blocking"], line2["elapsed"]["chain_ms"], line2["chain_blocks"]} ==
             {"blocked", ["assumption-without-reason 1"], 0, 1}

    state2 = hook_state(root, "flow-demo")
    assert {state2["chain_start"], state2["chain_blocks"]} == {@t, 1}
  end

  test "H17 elapsed fields are recorded in report.json and hook.jsonl and never decide" do
    {root, _package_rel, env, _decision, line} = ready_stop!()

    elapsed = %{
      "launch_ms" => 121_500,
      "chain_ms" => 0,
      "audit_ms" => 1_500,
      "audit_total_ms" => 1_500,
      "budget_ms" => 900_000,
      "complex" => false
    }

    assert read_json(line["report"])["elapsed"] == elapsed
    assert line["elapsed"] == elapsed

    for launch_id <- ["not-a-uuid", "0190a6b2-8c3e-4f00-8000-000000000000"] do
      {read, reads} = clock([@t, @t + 1_500])

      assert %{"continue" => true, "systemMessage" => "ready: " <> _} =
               stop!(root, %{env | "KOGEN_SHAPING_LAUNCH_ID" => launch_id}, clock: read)

      assert reads.() == 2
      last = List.last(hook_lines(root, "flow-demo"))
      assert last["kind"] == "ready"
      assert last["elapsed"]["launch_ms"] == nil
      assert read_json(last["report"])["elapsed"]["launch_ms"] == nil
    end

    {root2, package_rel2} = checkout!("proof-defects")
    env2 = hook_env(root2, package_rel2)
    first = stop!(root2, env2)
    File.rm_rf!(Path.join(root2, ".kogen/runtime/shaping-audits/proof-defects"))
    {later, _} = clock([@t + 36_000_000, @t + 36_001_500])
    assert stop!(root2, env2, clock: later) == first

    assert [%{"kind" => "blocked", "elapsed" => %{"launch_ms" => 36_121_500}}] =
             hook_lines(root2, "proof-defects")
  end

  test "H18 stop_hook.sh allows non-shaper roles without starting mix" do
    {root, _package_rel, extra} = shell_checkout!()
    assert sh!(root, [{"KOGEN_ROLE", "developer"} | extra]) == {"{\"continue\":true}\n", 0}
    refute File.exists?(Path.join(root, "fake-mix.log"))
  end

  test "H19 stop_hook.sh puts KOGEN_SHAPING_TOOLCHAIN_PATH first on PATH and runs the fake mix" do
    {root, package_rel, extra} = shell_checkout!()
    toolchain = Path.join(root, "toolchain")

    assert sh!(root, [{"KOGEN_FAKE_MIX_DECISION", @fake} | extra], Path.join(root, "lib")) ==
             {@fake, 0}

    assert [entry] = mix_log(root)
    assert entry.argv == "kogen.audit --stop-hook"
    assert entry.pwd == realpath(root)
    assert String.starts_with?(entry.path, toolchain <> ":")
    assert entry.path == toolchain <> ":/usr/bin:/bin"
    assert entry.key =~ ~r/\A#{Fixture.head(root)}:[0-9a-f]{64}\z/
    assert entry.key == "#{Fixture.head(root)}:#{bytes_digest(root, package_rel)}"
  end

  test "H20 stop_hook.sh serves an unchanged package from hook-state.json without starting mix again" do
    {root, _package_rel, extra} = shell_checkout!()
    extra = [{"KOGEN_FAKE_MIX_DECISION", @fake} | extra]
    assert {@fake, 0} = sh!(root, extra)
    [%{key: key}] = mix_log(root)
    cache!(root, key, %{"continue" => true, "systemMessage" => "cached"})

    assert sh!(root, extra) == {"{\"continue\": true, \"systemMessage\": \"cached\"}\n", 0}
    assert length(mix_log(root)) == 1
  end

  test "H21 a same-size byte edit and a new commit each re-run the audit" do
    {root, package_rel, extra} = shell_checkout!()
    extra = [{"KOGEN_FAKE_MIX_DECISION", @fake} | extra]
    cached = %{"continue" => true, "systemMessage" => "cached"}
    assert {@fake, 0} = sh!(root, extra)
    [%{key: key1}] = mix_log(root)
    cache!(root, key1, cached)

    intent = Path.join([root, package_rel, "intent.yaml"])
    before = File.read!(intent)

    edited =
      String.replace(before, "title: Add a fixture feature", "title: Add a fixture featurE")

    assert byte_size(edited) == byte_size(before) and edited != before
    File.write!(intent, edited)

    assert {@fake, 0} = sh!(root, extra)
    [_, %{key: key2}] = mix_log(root)
    refute key2 == key1
    cache!(root, key2, cached)

    commit_env = [
      {"GIT_AUTHOR_NAME", "Hook Test"},
      {"GIT_AUTHOR_EMAIL", "hook@example.com"},
      {"GIT_COMMITTER_NAME", "Hook Test"},
      {"GIT_COMMITTER_EMAIL", "hook@example.com"}
    ]

    {_, 0} =
      System.cmd("git", ["commit", "-q", "--allow-empty", "-m", "empty"],
        cd: root,
        env: commit_env
      )

    assert {@fake, 0} = sh!(root, extra)
    [_, _, %{key: key3}] = mix_log(root)
    assert String.starts_with?(key3, Fixture.head(root) <> ":")
    refute key3 == key2
    assert List.last(String.split(key3, ":")) == List.last(String.split(key2, ":"))
  end

  test "H22 a symlink in the package skips the cache and is refused" do
    {root, package_rel, extra} = shell_checkout!()
    extra = [{"KOGEN_FAKE_MIX_DECISION", @fake} | extra]
    assert {@fake, 0} = sh!(root, extra)
    [%{key: key}] = mix_log(root)
    cache!(root, key, %{"continue" => true, "systemMessage" => "cached"})

    File.ln_s!("intent.yaml", Path.join([root, package_rel, "evil-link"]))
    assert {@fake, 0} = sh!(root, extra)
    assert [%{key: ^key}, %{argv: "kogen.audit --stop-hook", key: ""}] = mix_log(root)
  end

  test "H23 stop_hook.sh re-execs through environment.py when KOGEN_ENV_RESTORE_PENDING=1" do
    {root, _package_rel} = checkout!("complete")
    tmp = Path.join(root, "reexec")
    copied = Path.join(tmp, "priv/kogen/shaping_audit/stop_hook.sh")
    File.mkdir_p!(Path.dirname(copied))
    File.cp!(script(), copied)
    environment = Path.join(tmp, ".codex/hooks/environment.py")
    File.mkdir_p!(Path.dirname(environment))

    File.write!(environment, """
    import os
    import sys

    with open(os.environ["RESTORE_LOG"], "a") as handle:
        handle.write("restored\\n")
    env = dict(os.environ)
    env.pop("KOGEN_ENV_RESTORE_PENDING", None)
    os.execvpe(sys.argv[1], sys.argv[1:], env)
    """)

    restore_log = Path.join(root, "restore.log")

    assert System.cmd("sh", [copied],
             cd: tmp,
             env: [
               {"PATH", "/usr/bin:/bin"},
               {"KOGEN_ROLE", "developer"},
               {"KOGEN_HARNESS_HOME", nil},
               {"KOGEN_ENV_RESTORE_PENDING", "1"},
               {"RESTORE_LOG", restore_log}
             ]
           ) == {"{\"continue\":true}\n", 0}

    assert File.read!(restore_log) == "restored\n"
  end

  test "H24 .codex/hooks/check.sh under KOGEN_ROLE=shaper prints {\"continue\":true}" do
    assert System.cmd("sh", [".codex/hooks/check.sh"],
             env: [
               {"KOGEN_ROLE", "shaper"},
               {"KOGEN_HARNESS_HOME", nil},
               {"KOGEN_ENV_RESTORE_PENDING", nil}
             ]
           ) == {"{\"continue\":true}\n", 0}
  end

  test "H27 the README documents the Stop hook and the inside-Shaping status" do
    readme = Regex.replace(~r/\s+/, File.read!("README.md"), " ")
    assert readme =~ "mix kogen.audit --stop-hook"
    assert readme =~ "Inside a Shaping session the Stop hook audits the Draft at every stop"
    refute readme =~ "it does not run as a Shaper Stop hook"
    refute readme =~ "The auditor is launched only when"
  end

  test "H28 --stop-hook takes no slug and no other flag" do
    {root, package_rel} = checkout!("complete")
    env = hook_env(root, package_rel)
    parent = self()
    io = %{puts: &send(parent, {:out, &1}), err: &send(parent, {:err, &1})}

    for args <- [["--stop-hook", "complete"], ["--stop-hook", "--auditor"]] do
      assert Kogen.ShapingAudit.main(args, root: root, env: env, io: io, stdin: "") == 2
      assert_received {:err, @usage}
      refute_received {:out, _}
      refute_received {:err, _}
    end

    refute File.exists?(env["KOGEN_SHAPING_HOOK_OUTPUT"])
    refute File.exists?(Path.join(root, ".kogen/runtime/shaping-audits"))
  end

  test "P5 settings.json and .codex are byte-identical to HEAD" do
    paths =
      ["priv/kogen/claude_code/settings.json"] ++
        case System.cmd("git", ["ls-tree", "-r", "--name-only", "HEAD", ".codex"]) do
          {output, 0} -> String.split(output, "\n", trim: true)
          {output, status} -> raise "git ls-tree failed (#{status}): #{output}"
        end

    for path <- paths do
      {expected, 0} = System.cmd("git", ["show", "HEAD:#{path}"])
      assert File.read!(path) == expected, path
    end
  end
end
