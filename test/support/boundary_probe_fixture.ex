defmodule Kogen.BoundaryProbeFixture do
  @moduledoc """
  The paid fixtures' fixture-only SessionStart probe of the role write
  boundary (never installed in this repository).

  `install_claude!/1` writes `.claude/settings.json` and the probe into a
  fixture before its baseline commit; `install_codex!/1` adds a SessionStart
  entry to the fixture's copy of `.codex/hooks.json`, keeping Kogen's
  PreToolUse Bash registration byte-identical in content. Both create the
  fixture control's ignored `.kogen/runtime/boundary-escape/`, so a refused
  write can only fail with EPERM, never ENOENT.

  The probe prints nothing (SessionStart output would enter the model's
  context) and does nothing unless `KOGEN_BOUNDARY_PROBE_OUTSIDE` is set,
  which only the nested `mix kogen.build` environment sets. It appends one
  JSON line per session to `$KOGEN_RAW_LOG_DIR/boundary-probe.jsonl`: inside
  a role that is `<harness home>/raw-log/`, which the controller copies into
  its own raw-log directory at Build exit. The line holds the role, session
  id (from the hook's stdin JSON), pid, cwd and the exit code and stderr of
  each attempt: a write into `$TMPDIR`, for Developer sessions a write into
  the Candidate's ignored `.kogen/runtime/`, a write into the escape dir and
  `git -C <fixture control> update-ref refs/heads/kogen-boundary-escape HEAD`.
  """

  import ExUnit.Assertions

  @escape ".kogen/runtime/boundary-escape"
  @ref "refs/heads/kogen-boundary-escape"

  @probe ~S"""
  import json
  import os
  import subprocess
  import sys

  outside = os.environ.get("KOGEN_BOUNDARY_PROBE_OUTSIDE")
  if not outside:
      sys.exit(0)
  try:
      data = json.load(sys.stdin)
  except Exception:
      data = {}


  def attempt(argv):
      done = subprocess.run(argv, capture_output=True, text=True)
      return {"exit": done.returncode, "stderr": done.stderr[-800:]}


  role = os.environ.get("KOGEN_ROLE", "")
  top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
  control = os.path.dirname(os.path.dirname(os.path.dirname(outside.rstrip("/"))))
  pid = os.getpid()
  attempts = {"tmpdir": attempt(["/bin/sh", "-c", 'echo in > "$TMPDIR/boundary-probe-%d"' % pid])}
  if role == "developer":
      attempts["candidate"] = attempt(
          ["/bin/sh", "-c", 'mkdir -p "%s/.kogen/runtime" && echo in > "%s/.kogen/runtime/boundary-probe-%d"' % (top, top, pid)]
      )
  attempts["outside"] = attempt(["/bin/sh", "-c", 'echo out > "%s/escape-%d"' % (outside, pid)])
  attempts["update_ref"] = attempt(["git", "-C", control, "update-ref", "refs/heads/kogen-boundary-escape", "HEAD"])
  line = {
      "role": role,
      "session_id": data.get("session_id") or data.get("thread_id"),
      "pid": pid,
      "cwd": os.path.realpath(top or os.getcwd()),
      "attempts": attempts,
  }
  directory = os.environ.get("KOGEN_RAW_LOG_DIR")
  if directory:
      os.makedirs(directory, exist_ok=True)
      with open(os.path.join(directory, "boundary-probe.jsonl"), "a") as handle:
          handle.write(json.dumps(line) + "\n")
  """

  @doc "The escape directory a fixture's nested Build names in `KOGEN_BOUNDARY_PROBE_OUTSIDE`."
  def outside(fixture), do: Path.join(fixture, @escape)

  @doc "Installs the Claude Code SessionStart probe into `fixture` (before its baseline commit)."
  def install_claude!(fixture) do
    File.mkdir_p!(Path.join(fixture, ".claude"))
    File.write!(Path.join(fixture, ".claude/boundary_probe.py"), @probe)

    File.write!(
      Path.join(fixture, ".claude/settings.json"),
      Jason.encode!(%{"hooks" => %{"SessionStart" => [session_start(".claude")]}}) <> "\n"
    )

    File.mkdir_p!(outside(fixture))
  end

  @doc "Adds the Codex SessionStart probe to `fixture`'s copy of `.codex/hooks.json`."
  def install_codex!(fixture) do
    path = Path.join(fixture, ".codex/hooks.json")
    hooks = path |> File.read!() |> Jason.decode!()
    pretooluse = get_in(hooks, ["hooks", "PreToolUse"])
    File.write!(Path.join(fixture, ".codex/boundary_probe.py"), @probe)
    updated = put_in(hooks, ["hooks", "SessionStart"], [session_start(".codex")])
    File.write!(path, Jason.encode!(updated, pretty: true) <> "\n")
    assert get_in(Jason.decode!(File.read!(path)), ["hooks", "PreToolUse"]) == pretooluse
    File.mkdir_p!(outside(fixture))
  end

  defp session_start(dir) do
    %{
      "hooks" => [
        %{
          "type" => "command",
          "command" =>
            "python3 \"$(git rev-parse --show-toplevel)/#{dir}/boundary_probe.py\" >/dev/null 2>&1 || true"
        }
      ]
    }
  end

  @doc "The probe lines the controller copied into `raw_log_dir`."
  def lines(raw_log_dir) do
    path = Path.join(raw_log_dir, "boundary-probe.jsonl")
    assert File.regular?(path), "no SessionStart boundary probe receipt at #{path}"
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Asserts a probe line's inside writes succeeded and both outside attempts
  (the escape dir and the ref) were refused with "Operation not permitted".
  """
  def assert_bounded!(line, candidate) do
    attempts = line["attempts"]
    assert line["cwd"] == candidate, "probe cwd #{line["cwd"]} is not the Candidate #{candidate}"
    assert attempts["tmpdir"]["exit"] == 0, inspect(attempts["tmpdir"])

    if line["role"] == "developer",
      do: assert(attempts["candidate"]["exit"] == 0, inspect(attempts["candidate"])),
      else: refute(Map.has_key?(attempts, "candidate"))

    for name <- ["outside", "update_ref"] do
      refute attempts[name]["exit"] == 0,
             "#{line["role"]} #{name} escaped: #{inspect(attempts[name])}"

      assert attempts[name]["stderr"] =~ ~r/[Oo]peration not permitted/,
             "#{line["role"]} #{name}: #{inspect(attempts[name])}"
    end
  end

  @doc "Asserts nothing escaped into the fixture control: no escape file and no escape ref."
  def assert_nothing_escaped!(fixture) do
    assert File.ls!(outside(fixture)) == []

    refute match?(
             {_, 0},
             System.cmd("git", ["show-ref", "--verify", @ref],
               cd: fixture,
               stderr_to_stdout: true
             )
           )
  end
end
