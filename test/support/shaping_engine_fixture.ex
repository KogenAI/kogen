Code.require_file("shaping_audit/fixture.ex", __DIR__)

defmodule Kogen.ShapingEngineFixture do
  @moduledoc """
  A committed fixture checkout for headless Shaping tests: the Shaping audit's
  fixture repository (real `Deterministic` layer; fake auditor and Jev
  layers), this test build's compiled Kogen (so `mix kogen.shape` and the
  detached `mix kogen.shape.runner` run the Candidate's own code), and the
  scripted `test/support/fake_shaping_controller` as the provider.

  `shape/3` runs `mix kogen.shape` as an external driver: it removes
  `KOGEN_ROLE` and every `KOGEN_SHAPING_*` variable from the child
  environment (a test that itself runs inside a managed Developer launch
  would otherwise be refused `managed_role`), and returns stdout and stderr
  separately.
  """

  alias Kogen.ShapingAudit.Fixture

  @project_root Path.expand("../..", __DIR__)

  @doc "A fresh fixture checkout. `opts[:turns]` is the fake's step script."
  def repo!(opts \\ []) do
    root =
      Fixture.repo!(
        compiled: true,
        second_commit: false,
        working_tree: false,
        prior_failures: false
      )

    # The files the ready flow template's scenarios cite.
    File.mkdir_p!(Path.join(root, "test/kogen"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def ok, do: true\nend\n")
    File.write!(Path.join(root, "test/kogen/demo_test.exs"), "assert true\n")
    File.write!(Path.join(root, ".gitignore"), ".kogen/runtime/\n_build/\ndeps/\n")

    {_, 0} =
      System.cmd("git", ["add", ".gitignore", "lib/demo.ex", "test/kogen/demo_test.exs"],
        cd: root
      )

    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "flow: demo"], cd: root)
    File.mkdir_p!(Path.join(root, ".kogen/runtime"))
    script!(root, Keyword.get(opts, :turns, [[]]), Keyword.get(opts, :script, %{}))
    ExUnit.Callbacks.on_exit(fn -> cleanup(root) end)
    root
  end

  # Stops any runner still holding a session, then removes the checkout. A
  # lock outlives its runner, so only a pid whose start time still matches
  # the lock is killed: a reused pid belongs to an unrelated suite process.
  defp cleanup(root) do
    for lock <- Path.wildcard(Path.join(root, ".kogen/runtime/shaping/*/.kogen/build.lock")),
        {:ok, pid} <- [Kogen.Shaping.live_runner(lock |> Path.dirname() |> Path.dirname())] do
      System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
    end

    File.rm_rf(root)
  end

  @doc "Writes the fake's script."
  def script!(root, turns, extra \\ %{}) do
    File.write!(script_path(root), Jason.encode!(Map.put(extra, "turns", turns)))
  end

  defp script_path(root), do: Path.join(root, ".kogen/fake-script.json")

  @doc "The packaged template of an audit-ready Draft."
  def ready_template,
    do: Path.join(@project_root, "test/support/shaping_audit/packages/flow/ready")

  @doc "Directory receiving the fake's invocation logs."
  def log_dir(root), do: Path.join(root, ".kogen/fake-log")

  @doc "Directory receiving notifier captures."
  def notes_path(root), do: Path.join(root, ".kogen/notifications.jsonl")

  @doc """
  The environment of every fixture child: the fake provider and audit
  fakes, the notifier capture, fast poll timings and this build's code.
  """
  def env(root, extra \\ []) do
    audit = [
      {"KOGEN_JEV_TRANSPORT",
       Path.join(@project_root, "test/support/shaping_audit/fake_jev_audit")},
      {"KOGEN_JEV_SECURITY",
       Path.join(@project_root, "test/support/shaping_audit/fake_security_audit")},
      {"FAKE_AUDITOR_LOG_DIR", Path.join(root, ".kogen/runtime/fake-auditor")},
      {"FAKE_JEV_LOG_DIR", Path.join(root, ".kogen/runtime/fake-jev-audit")},
      {"FAKE_SECURITY_LOG", Path.join(root, ".kogen/runtime/fake-security.log")},
      {"FAKE_AUDITOR_MESSAGE", "empty"},
      {"KOGEN_HARNESS_HOME", nil},
      {"FAKE_JEV_ANSWERS", nil}
    ]

    notifier = Path.join(root, ".kogen/notifier")

    File.write!(notifier, "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"#{notes_path(root)}\"\n")
    File.chmod!(notifier, 0o755)

    base =
      audit ++
        [
          {"KOGEN_HARNESS", Path.join(root, "test/support/fake_shaping_controller")},
          {"FAKE_SHAPING_SCRIPT", script_path(root)},
          {"FAKE_SHAPING_LOG_DIR", log_dir(root)},
          {"KOGEN_SHAPING_NOTIFIER", notifier},
          {"KOGEN_SHAPING_POLL_MS", "200"},
          {"KOGEN_SHAPING_QUIET_MS", "1500"},
          {"ERL_LIBS", erl_libs()},
          {"MIX_BUILD_PATH", Path.join(root, "_build")},
          {"KOGEN_TEST_ROOT", @project_root}
        ]

    Map.to_list(Map.merge(Map.new(base), Map.new(extra)))
  end

  @doc """
  The external-driver form of a child environment: `KOGEN_ROLE` and every
  `KOGEN_SHAPING_*` variable of this process removed, then `env` applied.
  """
  def driver_env(env) do
    inherited =
      for {key, _value} <- System.get_env(),
          key == "KOGEN_ROLE" or String.starts_with?(key, "KOGEN_SHAPING_"),
          do: {key, nil}

    Map.to_list(Map.merge(Map.new(inherited), Map.new(env)))
  end

  defp erl_libs do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&(Path.basename(&1) == "ebin" and String.contains?(&1, "_build")))
    |> Enum.map(&(&1 |> Path.dirname() |> Path.dirname()))
    |> Enum.uniq()
    |> Enum.join(":")
  end

  @doc """
  Runs `mix kogen.shape args` in `root` as an external driver. Returns
  `%{stdout, stderr, exit, json, lines}`. `opts[:env]` adds or overrides
  variables; `opts[:raw_env]` skips the driver stripping (the control).
  """
  def shape(root, args, opts \\ []) do
    env = env(root, Keyword.get(opts, :env, []))
    env = if Keyword.get(opts, :raw_env, false), do: env, else: driver_env(env)
    mix(root, ["kogen.shape" | args], env)
  end

  @doc "Runs a mix task in the fixture with stdout and stderr kept apart."
  def mix(root, args, env) do
    stderr =
      Path.join(System.tmp_dir!(), "kogen-shape-stderr-#{System.unique_integer([:positive])}")

    {stdout, exit} =
      System.cmd("sh", ["-c", "exec \"$@\" 2>\"$KOGEN_TEST_STDERR\"", "sh", "mix" | args],
        cd: root,
        env: [{"KOGEN_TEST_STDERR", stderr} | env]
      )

    err = File.read!(stderr)
    File.rm(stderr)
    lines = String.split(stdout, "\n", trim: true)

    json =
      case lines do
        [line] -> Jason.decode!(line)
        _other -> nil
      end

    %{stdout: stdout, stderr: err, exit: exit, json: json, lines: lines}
  end

  @doc "Writes `text` to a temporary input file and returns its path."
  def input!(root, name, text) do
    path = Path.join([root, ".kogen/inputs-under-test", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  @doc "The session directory."
  def session_dir(root, id), do: Path.join([root, ".kogen/runtime/shaping", id])

  @doc "The decoded session.json."
  def session(root, id),
    do: root |> session_dir(id) |> Path.join("session.json") |> File.read!() |> Jason.decode!()

  @doc "Polls `status` until `fun.(json)` holds (default 90 s)."
  def await(root, id, fun, timeout_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_loop(root, id, fun, deadline)
  end

  defp await_loop(root, id, fun, deadline) do
    status = shape(root, [id]).json

    cond do
      fun.(status) ->
        status

      System.monotonic_time(:millisecond) > deadline ->
        raise "timed out waiting; last status: #{inspect(status)}\nrunner.log:\n#{runner_log(root, id)}" <>
                "\nreport findings: #{report_findings(status)}\nhooks:\n#{hooks_log(root)}"

      true ->
        Process.sleep(250)
        await_loop(root, id, fun, deadline)
    end
  end

  defp report_findings(%{"report" => path}) when is_binary(path) do
    case File.read(path) do
      {:ok, text} ->
        report = Jason.decode!(text)

        inspect(%{
          readiness: report["readiness"],
          layers:
            Map.new(report["layers"] || %{}, fn {k, v} -> {k, {v["status"], v["reason"]}} end),
          findings: Enum.map(report["findings"] || [], &{&1["id"], &1["severity"], &1["message"]})
        })

      _ ->
        "unreadable"
    end
  end

  defp report_findings(_status), do: "none"

  defp hooks_log(root) do
    case File.read(Path.join(log_dir(root), "hooks.jsonl")) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  @doc "Waits until no runner holds the session."
  def await_idle(root, id, timeout_ms \\ 90_000) do
    await(root, id, &(&1["runner"] == false and &1["state"] != "running"), timeout_ms)
  end

  @doc "The runner log."
  def runner_log(root, id) do
    case File.read(Path.join(session_dir(root, id), "runner.log")) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  @doc "Captured notifications."
  def notifications(root) do
    case File.read(notes_path(root)) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      _ -> []
    end
  end

  @doc "The fake's recorded provider launches, in order."
  def launches(root) do
    root
    |> log_dir()
    |> Path.join("invocation-*.json")
    |> Path.wildcard()
    |> Enum.sort_by(
      &(&1
        |> Path.basename(".json")
        |> String.split("-")
        |> List.last()
        |> String.to_integer())
    )
    |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))
  end

  @doc "Events of the session."
  def events(root, id) do
    case File.read(Path.join(session_dir(root, id), "events.jsonl")) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      _ -> []
    end
  end

  @doc "The Draft directory of `slug`."
  def draft(root, slug), do: Path.join([root, ".kogen/intents/drafts", slug])

  @doc "Whether this VM is a `Kogen.IsolatedCase` child (not the dispatching parent)."
  def isolated_child?, do: System.get_env("KOGEN_ISOLATED_CASE_CHILD") == "1"

  @doc "Whether an OS process is alive."
  def alive?(pid) do
    {_out, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  end
end
