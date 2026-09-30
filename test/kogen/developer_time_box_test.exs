defmodule Kogen.DeveloperTimeBoxTest do
  @moduledoc """
  The Developer turn time-box: a soft timeout (TERM, grace, KILL) that only the
  Developer launch sends, so verification timeout semantics stay an immediate
  KILL, and a timed-out turn returns the observed session id so the same
  session can be resumed. Scripted fake CLIs; no provider is contacted.
  """
  use ExUnit.Case, async: true

  alias Kogen.ClaudeCode
  alias Kogen.Harness
  alias Kogen.ProcessCustody

  setup do
    dir = Path.join(System.tmp_dir!(), "kogen-time-box-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A fake `claude`: the first (non-resume) turn announces its session then
  # hangs; the marker file proves TERM reached it. A resumed turn completes.
  defp fake_claude(dir, hang, trap \\ "") do
    executable = Path.join(dir, "claude")

    File.write!(executable, """
    #!/bin/sh
    d="#{dir}"
    #{trap}
    cat > "$d/stdin-$$"
    session=; resume=0; previous=
    for a in "$@"; do
      [ "$previous" = --session-id ] && session="$a"
      [ "$previous" = --resume ] && session="$a" && resume=1
      previous="$a"
    done
    printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$session"
    if [ "$resume" -eq 0 ]; then
      #{hang}
    fi
    printf '{"type":"assistant","session_id":"%s","parent_tool_use_id":null,"message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"wrapped up"}]}}\\n' "$session"
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","terminal_reason":"completed","result":"wrapped up"}\\n' "$session"
    """)

    File.chmod!(executable, 0o755)

    %{
      harness: "claude",
      executable: executable,
      args: [],
      env: ClaudeCode.environment(%{path: Path.join(dir, "scope")}),
      config: %{
        harness: "claude",
        helpers: %{
          scout: %{model: "claude-sonnet-5", effort: "low"},
          worker: %{model: "claude-sonnet-5", effort: "medium"},
          expert: %{model: "claude-opus-5-5", effort: "high"}
        }
      },
      project: dir,
      cwd: dir
    }
  end

  # The trap is installed as the script's first statement so a loaded machine
  # cannot deliver TERM before the handler exists.
  @term_trap ~s|trap 'echo term > "$d/term-marker"; exit 143' TERM|
  @traps_term "sleep 30 \& wait"
  @ignore_trap ~s|trap '' TERM|
  @ignores_term "while :; do sleep 1; done"

  # The time box starts at launch, so TERM must not fire before the fake CLI's
  # shell has started and installed its trap. Process start-up cost varies by
  # an order of magnitude under the suite's load; the box is the small base
  # plus a generous multiple of the start-up cost of this very executable,
  # measured just now (a resumed turn exits at once).
  defp time_box_ms(context, base) do
    startup =
      Enum.max(
        for _ <- 1..3 do
          started = System.monotonic_time(:millisecond)

          {_, 0} =
            System.cmd("/bin/sh", [
              "-c",
              ~s|exec "$0" --resume probe < /dev/null|,
              context.executable
            ])

          System.monotonic_time(:millisecond) - started
        end
      )

    base + 10 * startup
  end

  defp with_time_box(context, base, grace),
    do: Map.merge(context, %{turn_timeout_ms: time_box_ms(context, base), turn_grace_ms: grace})

  test "a Claude turn past its time box is interrupted by TERM, keeps its session, and resumes",
       %{dir: dir} do
    context =
      dir
      |> fake_claude(@traps_term, @term_trap)
      |> with_time_box(700, 5_000)

    assert {:error, {:developer_turn_timeout, evidence}} =
             Harness.launch_build_developer("PROMPT", "claude-opus-5-5", "medium", [], context)

    assert evidence.outcome == :turn_timeout
    assert is_binary(evidence.session_id)
    assert File.read!(Path.join(dir, "term-marker")) == "term\n"

    resumed = Map.delete(context, :turn_timeout_ms)

    assert {:ok, turn} =
             Harness.resume_build_developer(
               evidence.session_id,
               "wrap up",
               "claude-opus-5-5",
               "medium",
               [],
               resumed
             )

    assert turn.session_id == evidence.session_id
    assert turn.message == "wrapped up"
  end

  test "a CLI ignoring TERM is killed after the grace and still reports the timeout", %{dir: dir} do
    context =
      dir
      |> fake_claude(@ignores_term, @ignore_trap)
      |> with_time_box(500, 1_000)

    started = System.monotonic_time(:millisecond)

    assert {:error, {:developer_turn_timeout, %{session_id: session}}} =
             Harness.launch_build_developer("PROMPT", "claude-opus-5-5", "medium", [], context)

    elapsed = System.monotonic_time(:millisecond) - started
    assert is_binary(session)

    assert elapsed >= context.turn_timeout_ms + 900,
           "KILL must wait for the grace (#{elapsed} ms)"

    assert elapsed < 15_000
  end

  test "no time box is applied without :turn_timeout_ms or outside the Developer role", %{
    dir: dir
  } do
    context = fake_claude(dir, "sleep 1")

    assert {:ok, %{message: "wrapped up"}} =
             Harness.launch_build_developer("PROMPT", "claude-opus-5-5", "medium", [], context)

    # A Reviewer launch never receives the Developer time-box, even when the
    # context carries one: the hung CLI is not interrupted.
    hanging = dir |> fake_claude("sleep 2") |> Map.put(:turn_timeout_ms, 300)

    assert {:error, {:malformed_verdict, _, _}} =
             Harness.launch_reviewer("PROMPT", "claude-opus-5-5", "medium", hanging)

    refute File.exists?(Path.join(dir, "term-marker"))
  end

  describe "process supervisor" do
    test "soft_timeout sends TERM first; the default timeout is still an immediate KILL", %{
      dir: dir
    } do
      script = "trap 'echo term > #{dir}/custody-marker; exit 143' TERM; sleep 30 & wait"

      assert {:ok, soft} =
               ProcessCustody.run(["/bin/sh", "-c", script], dir,
                 timeout_ms: 500,
                 soft_timeout: true,
                 grace_ms: 5_000
               )

      assert soft["timed_out"] == true
      assert File.read!(Path.join(dir, "custody-marker")) == "term\n"
      File.rm!(Path.join(dir, "custody-marker"))

      assert {:ok, hard} =
               ProcessCustody.run(["/bin/sh", "-c", script], dir, timeout_ms: 500)

      assert hard["timed_out"] == true
      refute File.exists?(Path.join(dir, "custody-marker"))
    end

    test "soft_timeout leaves a helper child to finish and never fires before the session is observed",
         %{dir: dir} do
      # The helper writes its marker after the TERM; it must not be reaped.
      script =
        "trap 'exit 143' TERM; (sleep 1; echo done > #{dir}/helper-marker) & " <>
          "sleep 1.5; echo '{\"type\":\"thread.started\"}'; sleep 30 & wait"

      started = System.monotonic_time(:millisecond)

      assert {:ok, soft} =
               ProcessCustody.run(["/bin/sh", "-c", script], dir,
                 timeout_ms: 300,
                 soft_timeout: true,
                 soft_ready_pattern: ~S("thread\.started"),
                 grace_ms: 5_000
               )

      assert soft["timed_out"] == true
      # Held until the session marker (>= 1.5s), not at the 300 ms deadline.
      assert System.monotonic_time(:millisecond) - started >= 1_400
      assert File.read!(Path.join(dir, "helper-marker")) == "done\n"
    end
  end

  test "a nudged turn resumed under the same time box times out again and resumes again",
       %{dir: dir} do
    # The first two resumes hang again, the third completes: the nudge repeats,
    # each time on the same session.
    executable = Path.join(dir, "claude")
    base = fake_claude(dir, "sleep 30 \\& wait", @term_trap)

    File.write!(executable, """
    #!/bin/sh
    d="#{dir}"
    #{@term_trap}
    cat > "$d/stdin-$$"
    session=; resume=0; previous=
    for a in "$@"; do
      [ "$previous" = --session-id ] && session="$a"
      [ "$previous" = --resume ] && session="$a" && resume=1
      previous="$a"
    done
    printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$session"
    if [ "$resume" -eq 0 ]; then sleep 30 & wait; fi
    n=$(cat "$d/resumes" 2>/dev/null)
    n=${n:-0}
    [ "$session" = probe ] && n=2
    [ "$session" = probe ] || echo $((n + 1)) > "$d/resumes"
    if [ "$n" -lt 2 ]; then sleep 30 & wait; fi
    printf '{"type":"assistant","session_id":"%s","parent_tool_use_id":null,"message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"wrapped up"}]}}\\n' "$session"
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"%s","terminal_reason":"completed","result":"wrapped up"}\\n' "$session"
    """)

    File.chmod!(executable, 0o755)
    context = with_time_box(base, 700, 5_000)

    assert {:error, {:developer_turn_timeout, %{session_id: session}}} =
             Harness.launch_build_developer("PROMPT", "claude-opus-5-5", "medium", [], context)

    resume = fn ->
      Harness.resume_build_developer(session, "nudge", "claude-opus-5-5", "medium", [], context)
    end

    assert {:error, {:developer_turn_timeout, %{session_id: ^session}}} = resume.()
    assert {:error, {:developer_turn_timeout, %{session_id: ^session}}} = resume.()
    assert {:ok, %{session_id: ^session, message: "wrapped up"}} = resume.()
  end

  describe "Kogen.Build.developer_turn_timeout_ms/1" do
    test "defaults to 30 minutes and honours the config; no wrap-up bound or budget clamp" do
      assert Kogen.Build.developer_turn_timeout_ms(%{}) == 30 * 60_000
      assert Kogen.Build.developer_turn_timeout_ms(%{developer_turn_minutes: 45}) == 45 * 60_000
      assert Kogen.Build.developer_turn_timeout_ms(%{developer_turn_minutes: 4}) == 4 * 60_000
      refute function_exported?(Kogen.Build, :developer_turn_timeout_ms, 2)
    end

    test "the turn nudge prompt reports the minutes, is not a stop and is not a resumption" do
      prompt = Kogen.Build.turn_nudge_prompt(60, 2)
      assert prompt =~ "60 minutes"
      assert prompt =~ "Report your progress"
      assert prompt =~ "narrow the scope"
      assert prompt =~ "hand off the concrete remaining work"
      assert prompt =~ "not a stop"
      refute prompt =~ "second timeout"
    end
  end
end
