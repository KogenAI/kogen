defmodule Kogen.ProcessCustodyInputTest do
  use ExUnit.Case, async: true

  alias Kogen.ProcessCustody

  test "anonymous input is exact, closes at EOF and stays out of process metadata" do
    bytes = :crypto.strong_rand_bytes(24) |> Base.encode64()

    script = """
    import hashlib, json, os, subprocess, sys
    data = sys.stdin.buffer.read()
    metadata = subprocess.check_output(['/bin/ps', 'eww', '-p', str(os.getpid()), '-p', str(os.getppid())])
    print(json.dumps({'sha256': hashlib.sha256(data).hexdigest(), 'size': len(data), 'exposed': data in metadata}))
    """

    assert {:ok, facts} =
             ProcessCustody.run(
               [System.find_executable("python3"), "-c", script],
               System.tmp_dir!(),
               stdin_bytes: bytes,
               timeout_ms: 5_000
             )

    assert facts["exit_code"] == 0
    assert facts["stdin_error"] == nil
    assert facts["cleanup"] == "clean"
    result = Jason.decode!(facts["output"])
    assert result["sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert result["size"] == byte_size(bytes)
    refute result["exposed"]
    refute String.contains?(Jason.encode!(facts), bytes)
  end

  test "invalid or conflicting input refuses before process creation" do
    argv = [System.find_executable("python3"), "-c", "raise Exception('must not launch')"]

    assert {:error, "stdin_bytes must be a binary"} =
             ProcessCustody.run(argv, System.tmp_dir!(), stdin_bytes: 1)

    assert {:error, "stdin_bytes exceeds 16 KiB"} =
             ProcessCustody.run(argv, System.tmp_dir!(), stdin_bytes: :binary.copy("x", 16_385))

    assert {:error, "stdin_bytes and stdin_path conflict"} =
             ProcessCustody.run(argv, System.tmp_dir!(), stdin_bytes: "x", stdin_path: "/missing")
  end

  test "anonymous input retains timeout and process group cleanup" do
    script = "import sys, time; assert sys.stdin.buffer.read() == b'frame'; time.sleep(60)"

    assert {:ok, facts} =
             ProcessCustody.run(
               [System.find_executable("python3"), "-c", script],
               System.tmp_dir!(),
               stdin_bytes: "frame",
               timeout_ms: 200,
               grace_ms: 200
             )

    assert facts["timed_out"]
    refute facts["cleanup"] == "failed"
    assert ProcessCustody.process_start(facts["pid"]) == ""
  end

  test "a rejected start gate reaps the input recipient without a control root" do
    owner = self()

    script =
      "import sys; assert sys.stdin.buffer.read() == b'frame'; raise Exception('must not run')"

    assert {:error, reason} =
             ProcessCustody.run(
               [System.find_executable("python3"), "-c", script],
               System.tmp_dir!(),
               stdin_bytes: "frame",
               on_start: fn group ->
                 send(owner, {:started, group})
                 {:error, :refused}
               end
             )

    assert reason =~ "process supervision setup failed"
    assert_received {:started, group}
    assert ProcessCustody.process_start(group["pid"]) == ""
  end
end
