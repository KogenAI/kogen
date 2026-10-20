Code.require_file(Path.expand("../support/integration_helpers.ex", __DIR__))

defmodule Kogen.Integration.BuildContextFilesTest do
  use ExUnit.Case, async: true
  alias Kogen.Integration.{FakeProvider, Helpers}
  @moduletag :integration

  setup_all do
    suite = Helpers.setup_suite!()
    on_exit(fn -> Helpers.cleanup_suite(suite) end)
    {:ok, suite: suite}
  end

  test "nonregular FIFO and unreadable file fail before provider or custody effects", %{
    suite: suite
  } do
    c = Helpers.project!(suite, [], staged_intent: false)
    on_exit(fn -> Helpers.cleanup_case(c) end)
    fifo = Path.join(c.root, "fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    file = Path.join(c.root, "unreadable")
    File.write!(file, "valid false control")
    File.chmod!(file, 0o000)
    on_exit(fn -> File.chmod(file, 0o600) end)
    before = custody(c)
    requests = FakeProvider.provider_requests(c.server)

    {output, code} = Helpers.run_kogen(c, ["intent", "build", "fixture", "--context", fifo])
    assert code == 2, output
    assert output =~ "intent/context_unavailable"

    case File.read(file) do
      {:error, :eacces} ->
        {output, code} = Helpers.run_kogen(c, ["intent", "build", "fixture", "--context", file])
        assert code == 2, output
        assert output =~ "intent/context_unavailable"

      {:ok, "valid false control"} ->
        # Privileged callers can read mode-000 files. Exercise the same installed
        # CLI bytes under an unprivileged uid, rather than failing or skipping the
        # unreadable case on root-run Linux CI. No core or provider is needed for
        # an early file-validation error.
        unreadable_as_unprivileged!(c)
    end

    assert custody(c) == before
    assert FakeProvider.provider_requests(c.server) == requests

    File.chmod!(file, 0o600)
    {output, _} = Helpers.run_kogen(c, ["intent", "build", "fixture", "--context", file])
    refute output =~ "intent/context_unavailable"
    assert length(FakeProvider.provider_requests(c.server)) == length(requests) + 1
  end

  for diagnostic? <- [false, true] do
    test "cancelled initial request freezes conversation across source replacement and deletion (context=#{diagnostic?})",
         %{suite: suite} do
      c =
        Helpers.project!(suite, [{:pause, self(), {:text, "late response"}}],
          staged_intent: false
        )

      on_exit(fn -> Helpers.cleanup_case(c) end)
      file = Path.join(c.root, "diagnostic.txt")
      text = "  captured Δ🙂\r\noriginal observation\n "
      File.write!(file, text)
      args = ["intent", "build", "fixture"]
      args = if unquote(diagnostic?), do: args ++ ["--context", file], else: args
      before = custody(c)
      port = Helpers.start_kogen(c, args)
      assert_receive {:provider_paused, provider}, 15_000

      try do
        Helpers.signal!(c, port, "INT")
        {output, code} = Helpers.await_exit(port, "", 15_000)
        assert code == 130, output
        assert output =~ "interrupted"
      after
        send(provider, :continue)
      end

      assert custody_without_runs(c) == Tuple.delete_at(before, 4)
      original_dir = Path.dirname(Helpers.run_log(c))
      id = Path.basename(original_dir)

      original =
        Map.new(~w(checkpoint.json result.json), &{&1, File.read!(Path.join(original_dir, &1))})

      [_, initial] = FakeProvider.provider_requests(c.server)
      input = initial.json["input"]
      assert length(input) == if(unquote(diagnostic?), do: 2, else: 1)
      checkpoint = JSON.decode!(original["checkpoint.json"])
      assert checkpoint["version"] == 2
      assert {:ok, _, state} = Kogen.Run.decode_checkpoint(original["checkpoint.json"])
      assert state.continuation.stage == :builder
      assert state.continuation.input == input

      if unquote(diagnostic?) do
        assert List.last(input)["content"] =~ text
      else
        refute File.exists?(Path.join(original_dir, "diagnostic-context.json"))
      end

      poison = "POISON replacement must never enter the resumed request"
      File.write!(file, poison)
      assert File.read!(file) == poison

      final_id =
        Enum.reduce([:replace, :delete], id, fn operation, parent ->
          if operation == :delete, do: File.rm!(file)
          prior = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*"))
          {output, code} = Helpers.run_kogen(c, ["intent", "resume", parent])
          assert code == 4, output
          assert output =~ "resuming Build #{parent}"
          resumed = List.last(FakeProvider.provider_requests(c.server)).json
          assert resumed["input"] == input
          assert resumed["instructions"] == initial.json["instructions"]
          assert resumed["tools"] == initial.json["tools"]
          refute JSON.encode!(resumed["input"]) =~ poison
          assert custody_without_runs(c) == Tuple.delete_at(before, 4)
          [child] = Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*")) -- prior
          result = JSON.decode!(File.read!(Path.join(child, "result.json")))
          assert result["resumed_from"] == parent
          assert result["root_build"] == id
          assert JSON.decode!(File.read!(Path.join(child, "checkpoint.json")))["version"] == 2
          Path.basename(child)
        end)

      assert final_id != id

      for {name, bytes} <- original,
          do: assert(File.read!(Path.join(original_dir, name)) == bytes)

      assert length(FakeProvider.provider_requests(c.server)) == 4
    end
  end

  defp custody_without_runs(c), do: c |> custody() |> Tuple.delete_at(4)

  defp unreadable_as_unprivileged!(c) do
    # Use a traversable directory outside the suite's private HOME/prefix. Only
    # copy the installed CLI, not a replacement implementation or a fake reader.
    dir =
      Path.join(
        "/tmp",
        "kogen-context-eacces-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o755)

    try do
      cli = Path.join(dir, "bin/kogen")
      File.mkdir!(Path.dirname(cli))
      File.chmod!(Path.dirname(cli), 0o755)
      File.cp!(c.suite.release, cli)
      File.chmod!(cli, 0o755)
      file = Path.join(dir, "context")
      File.write!(file, "valid false control")
      File.chmod!(file, 0o000)

      script = """
      import errno, os, sys
      cli, file = sys.argv[1:]
      os.setgroups([])
      os.setgid(65534)
      os.setuid(65534)
      try:
          open(file, 'rb').read()
      except OSError as e:
          assert e.errno == errno.EACCES, e
      else:
          raise AssertionError('file was readable under the denied control')
      os.execv(cli, [cli, 'intent', 'build', 'fixture', '--context', file])
      """

      {output, code} =
        System.cmd("python3", ["-c", script, cli, file], cd: dir, stderr_to_stdout: true)

      assert code == 2, output
      assert output =~ "intent/context_unavailable"

      # A readable file must get past validation through the identical installed
      # binary and reduced uid. It reaches the deliberately absent core instead.
      File.chmod!(file, 0o644)

      script = """
      import os, sys
      cli, file = sys.argv[1:]
      os.setgroups([])
      os.setgid(65534)
      os.setuid(65534)
      assert open(file, 'rb').read() == b'valid false control'
      os.execv(cli, [cli, 'intent', 'build', 'fixture', '--context', file])
      """

      {output, code} =
        System.cmd("python3", ["-c", script, cli, file], cd: dir, stderr_to_stdout: true)

      assert code == 3, output
      assert output =~ "environment/core_unavailable"
      refute output =~ "intent/context_unavailable"
    after
      File.rm_rf!(dir)
    end
  end

  defp custody(c) do
    {head, 0} = Helpers.git!(c, ["rev-parse", "HEAD"])

    {head, File.read!(Path.join(c.repo, ".git/index")),
     File.read!(Kogen.Intent.approval_path(c.repo, "fixture")),
     File.read!(Path.join(c.repo, "app.txt")),
     Path.wildcard(Path.join(c.repo, ".kogen/local/runs/*"))}
  end
end
