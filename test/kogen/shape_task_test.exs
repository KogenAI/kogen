Code.require_file("../support/shaping_engine_fixture.ex", __DIR__)
Code.require_file("../support/document_references.ex", __DIR__)

defmodule Kogen.ShapeTaskTest do
  @moduledoc """
  The public headless `mix kogen.shape` surface: one JSON line on stdout,
  exit codes 0 and 2, usage and input refusals that store nothing, durable
  request idempotency, the retired TUI-era Drafts, and the help surface.

  Fast refusals call `Kogen.Shaping.main/2` in process; every test that
  asserts the wire contract (stdout is exactly one JSON line) or needs a
  started session runs the real `mix kogen.shape` as an external driver.
  """
  use ExUnit.Case, async: true

  alias Kogen.Shaping
  alias Kogen.Shaping.Store
  alias Kogen.ShapingEngineFixture, as: F
  alias Kogen.Test.DocumentReferences, as: DR

  @project_root Path.expand("../..", __DIR__)
  @root @project_root
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @moduletag :lifecycle
  @moduletag timeout: 600_000

  # --- helpers ---------------------------------------------------------------

  defp session_ids(root) do
    case File.ls(Path.join(root, ".kogen/runtime/shaping")) do
      {:ok, names} -> names |> Enum.filter(&(&1 =~ @uuid)) |> Enum.sort()
      _ -> []
    end
  end

  defp stored?(root) do
    session_ids(root) != [] or
      Path.wildcard(Path.join(root, ".kogen/runtime/shaping/**/*.json")) != []
  end

  # Runs one invocation in process and returns {json, exit}.
  defp main(root, args, env \\ %{}), do: Kogen.Shaping.main(args, root: root, env: env)

  defp refused!(root, args, code, env \\ %{}) do
    assert {%{"error" => %{"code" => ^code}} = json, 2} = main(root, args, env)
    json
  end

  # The wire contract of a real invocation: one JSON object line, nothing else.
  defp assert_one_line!(result) do
    assert [line] = result.lines,
           "stdout was: #{inspect(result.stdout)}\nstderr: #{result.stderr}"

    assert result.stdout == line <> "\n"
    assert is_map(Jason.decode!(line))
    result
  end

  defp start!(root, brief \\ "Add a demo flag.\n", args \\ []) do
    result = F.shape(root, ["--brief", F.input!(root, "brief.md", brief) | args])
    assert result.exit == 0, result.stdout <> result.stderr
    assert_one_line!(result)
    result
  end

  defp settle!(root, id), do: F.await_idle(root, id)

  defp hash_tree(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, dir), :crypto.hash(:sha256, File.read!(path))}
  end

  defp request_path(root, id, rid),
    do: Store.request_path(root, F.session_dir(root, id), rid)

  defp read_json!(path) do
    {:ok, data} = Store.read_json(path)
    data
  end

  # --- usage refusals --------------------------------------------------------

  describe "usage refusals exit 2 with error.code usage" do
    setup do
      root = F.repo!()
      brief = F.input!(root, "brief.md", "A brief.\n")
      id = "01965000-0000-7000-8000-00000000abcd"
      {:ok, root: root, brief: brief, id: id}
    end

    test "every malformed invocation is refused in process and stores nothing", %{
      root: root,
      brief: brief,
      id: id
    } do
      cases = [
        ["--bogus"],
        ["--brief", brief, "--bogus"],
        ["--headless", "--brief", brief],
        ["--expected-revision", "1", id],
        [id, "other-positional"],
        [id, "second", "--brief", brief],
        [id, "--brief", brief, "--approve", "p-1-0123456789ab"],
        ["--brief", brief, "--approve", "p-1-0123456789ab"],
        [id, "--route", "codex", "--brief", brief],
        [id, "--route", "codex"],
        [id, "--route", "codex", "--cancel"],
        ["--brief", brief, "--request-id", "bad id!"],
        ["--brief", brief, "--request-id", ""],
        ["--brief", brief, "--request-id", "-leading-dash"],
        ["--brief", brief, "--interface", "no spaces"],
        [id, "--approve", "p-1"],
        [id, "--approve", "1-0123456789ab"],
        [id, "--approve", "p-1-0123456789AB"],
        [id, "--approve", "p-1-0123456789abc"],
        [id, "--interface", "web"],
        [id, "--request-id", "r1"],
        [id, "--cancel", "--interface", "web"],
        ["--route", "codex"],
        ["--cancel"],
        ["--approve", "p-1-0123456789ab"],
        ["--brief"],
        []
      ]

      for args <- cases do
        json = refused!(root, args, "usage")
        assert json["error"]["message"] =~ "usage: mix kogen.shape", inspect(args)
        refute stored?(root), inspect(args)
      end
    end

    test "status with any flag is a usage error and never touches the session", %{
      root: root,
      id: id
    } do
      for flag <- [["--interface", "web"], ["--request-id", "r1"], ["--route", "codex"]] do
        refused!(root, [id | flag], "usage")
      end

      refute stored?(root)
    end

    test "through the real task: one JSON line on stdout and exit 2", %{
      root: root,
      brief: brief,
      id: id
    } do
      for args <- [
            ["--bogus"],
            [id, "one-more"],
            ["--brief", brief, "--approve", "p-1-0123456789ab"],
            [id, "--route", "codex", "--brief", brief],
            ["--brief", brief, "--request-id", "bad id!"],
            [id, "--approve", "not-a-presentation"],
            [id, "--interface", "web"]
          ] do
        result = root |> F.shape(args) |> assert_one_line!()
        assert result.exit == 2, inspect(args)
        assert result.json["error"]["code"] == "usage", inspect(result.json)
        assert result.json["session"] == nil or result.json["session"] == id
        refute stored?(root)
      end
    end
  end

  # --- invalid input ---------------------------------------------------------

  describe "invalid input stores nothing" do
    test "empty, oversized, invalid UTF-8 and missing files are refused invalid_input" do
      root = F.repo!()
      empty = F.input!(root, "empty.md", "")
      big = F.input!(root, "big.md", String.duplicate("a", 1_048_577))
      bad = F.input!(root, "bad.md", <<0x66, 0x6F, 0xFF, 0xFE, 0x6F>>)
      missing = Path.join(root, ".kogen/inputs-under-test/none.md")

      for path <- [empty, big, bad, missing] do
        json = refused!(root, ["--brief", path], "invalid_input")
        assert json["session"] == nil
        refute stored?(root), path
      end

      # Exactly 1 MiB is still accepted by the size check (the boundary control).
      edge = F.input!(root, "edge.md", String.duplicate("a", 1_048_576))

      refute match?(
               {%{"error" => %{"code" => "invalid_input"}}, 2},
               main(root, ["--brief", edge, "--route", "nope"])
             )
    end

    test "through the real task: one JSON line, exit 2, no session directory" do
      root = F.repo!()
      empty = F.input!(root, "empty.md", "")
      bad = F.input!(root, "bad.md", <<0xC3, 0x28>>)

      for path <- [empty, bad, Path.join(root, "absent.md")] do
        result = root |> F.shape(["--brief", path]) |> assert_one_line!()
        assert result.exit == 2
        assert result.json["error"]["code"] == "invalid_input"
      end

      refute stored?(root)
      refute File.exists?(Path.join(root, ".kogen/runtime/shaping")) and session_ids(root) != []
    end

    test "an invalid continue message stores no new input and keeps the session" do
      root = F.repo!(turns: [[]])
      id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")
      settle!(root, id)
      dir = F.session_dir(root, id)
      before = hash_tree(Path.join(dir, "inputs"))

      for path <- [
            F.input!(root, "e.md", ""),
            F.input!(root, "b.md", <<0xFF>>),
            Path.join(root, "gone.md")
          ] do
        result = root |> F.shape([id, "--brief", path]) |> assert_one_line!()
        assert result.exit == 2
        assert result.json["error"]["code"] == "invalid_input"
      end

      assert hash_tree(Path.join(dir, "inputs")) == before
      assert session_ids(root) == [id]
    end
  end

  # --- exact bytes -----------------------------------------------------------

  test "multibyte brief bytes are stored exactly as inputs/0001.md" do
    root = F.repo!(turns: [[]])
    brief = "Zovi ga --demo — «ø» 名前 😀 č ć ž š đ\r\nline two without final newline"
    result = start!(root, brief)
    id = result.json["session"]
    assert id =~ @uuid
    assert File.read!(Path.join([F.session_dir(root, id), "inputs", "0001.md"])) == brief
    settle!(root, id)
    assert File.read!(Path.join([F.session_dir(root, id), "inputs", "0001.md"])) == brief

    [launch] = F.launches(root)
    compact_prompt = Regex.replace(~r/\s+/, launch["stdin"], " ")

    for instruction <- [
          "declared-target retries follow the controller's failure-class retry policy separately from that allowance and resume the same Developer session when the applicable class permits a retry",
          "Offline target, catalog and Candidate-caused `prepare` failures use `offline_retries` when present",
          "legacy attempt contexts without that field fall back to `verification_retries`",
          "Paid provider-backed target failures use `verification_retries`",
          "Terminal environment or provider failures spend neither retry budget",
          "For a Build, its controller alone runs exactly the approved `verified_by` targets and writes their receipts",
          "hook audits the Draft at every stop it sees",
          "If the hook blocks the stop, fix findings that are"
        ] do
      assert compact_prompt =~ instruction, instruction
    end

    refute compact_prompt =~ "Stop-owned verification retries"
    refute compact_prompt =~ "`verification_retries` budget separately governs"
  end

  # --- idempotency -----------------------------------------------------------

  describe "request IDs" do
    test "the same request ID and arguments replay the recorded outcome and exit without a second input" do
      root = F.repo!(turns: [[]])
      brief = F.input!(root, "brief.md", "Add a demo flag.\n")

      first =
        root
        |> F.shape(["--brief", brief, "--request-id", "r-start", "--interface", "web"])
        |> assert_one_line!()

      assert first.exit == 0, first.stdout <> first.stderr
      id = first.json["session"]

      again =
        root
        |> F.shape(["--brief", brief, "--request-id", "r-start", "--interface", "web"])
        |> assert_one_line!()

      assert again.exit == 0
      assert again.json == first.json
      assert session_ids(root) == [id]

      settle!(root, id)

      # A continue message is replayed too, with a byte-identical outcome and one input.
      msg = F.input!(root, "m.md", "Steer: keep it small.\n")
      sent = root |> F.shape([id, "--brief", msg, "--request-id", "r-msg"]) |> assert_one_line!()
      assert sent.exit == 0

      replay =
        root |> F.shape([id, "--brief", msg, "--request-id", "r-msg"]) |> assert_one_line!()

      assert replay.exit == 0
      assert replay.json == sent.json

      settle!(root, id)
      inputs = Path.wildcard(Path.join([F.session_dir(root, id), "inputs", "*.md"]))
      assert Enum.map(inputs, &Path.basename/1) == ["0001.md", "0002.md"]

      assert File.read!(Path.join([F.session_dir(root, id), "inputs", "0002.md"])) ==
               "Steer: keep it small.\n"
    end

    test "concurrent retries of one request ID store exactly one input and one outcome" do
      root = F.repo!(turns: [[]])
      id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")
      settle!(root, id)
      msg = F.input!(root, "m.md", "Steer: keep it small.\n")

      results =
        1..4
        |> Task.async_stream(
          fn _ -> root |> F.shape([id, "--brief", msg, "--request-id", "r-race"]) end,
          max_concurrency: 4,
          timeout: 300_000
        )
        |> Enum.map(fn {:ok, result} -> assert_one_line!(result) end)

      # Every caller gets the one recorded outcome, or a transient busy
      # refusal while the first attempt still holds the request.
      {accepted, busy} = Enum.split_with(results, &(&1.exit == 0))
      assert accepted != []
      assert accepted |> Enum.map(& &1.json["session"]) |> Enum.uniq() == [id]
      assert Enum.all?(busy, &(&1.exit == 2 and &1.json["error"]["code"] == "busy"))

      settle!(root, id)
      inputs = Path.join(F.session_dir(root, id), "inputs")

      assert inputs |> Path.join("*.md") |> Path.wildcard() |> Enum.map(&Path.basename/1) ==
               ["0001.md", "0002.md"]

      assert File.read!(Path.join(inputs, "0002.md")) == "Steer: keep it small.\n"

      replay =
        root |> F.shape([id, "--brief", msg, "--request-id", "r-race"]) |> assert_one_line!()

      assert replay.exit == 0
      assert replay.json == read_json!(request_path(root, id, "r-race"))["outcome"]
    end

    test "a request interrupted after claiming its input number completes that same input on retry" do
      root = F.repo!(turns: [[]])
      id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")
      settle!(root, id)
      bytes = "Steer: keep it small.\n"
      msg = F.input!(root, "m.md", bytes)
      dir = F.session_dir(root, id)

      # A crash after the number was claimed for r-crash and its bytes were
      # half written, before the request recorded the number or an outcome.
      args = %{"brief" => Store.sha256(bytes), "interface" => "cli"}

      File.write!(
        Path.join([dir, "inputs", "0002.claim"]),
        Jason.encode!(%{"request_id" => "r-crash"})
      )

      File.write!(Path.join([dir, "inputs", "0002.md"]), "Steer: ke")

      Store.write_request!(request_path(root, id, "r-crash"), %{
        "request_id" => "r-crash",
        "command" => "message",
        "digest" => Shaping.digest("message", id, args),
        "received_at" => Store.now(),
        "interface" => "cli",
        "input_sha256" => args["brief"],
        "outcome" => nil,
        "exit" => nil
      })

      retried =
        root |> F.shape([id, "--brief", msg, "--request-id", "r-crash"]) |> assert_one_line!()

      assert retried.exit == 0, retried.stdout <> retried.stderr
      settle!(root, id)

      inputs = Path.join(dir, "inputs")

      assert inputs |> Path.join("*.md") |> Path.wildcard() |> Enum.map(&Path.basename/1) ==
               ["0001.md", "0002.md"]

      assert File.read!(Path.join(inputs, "0002.md")) == bytes
      assert read_json!(Path.join(inputs, "0002.json"))["request_id"] == "r-crash"
      assert read_json!(request_path(root, id, "r-crash"))["input"] == 2
    end

    test "a refusal is recorded and replayed with exit 2" do
      root = F.repo!(turns: [[]])
      id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")
      settle!(root, id)
      args = [id, "--approve", "p-9-0123456789ab", "--request-id", "r-appr"]

      first = root |> F.shape(args) |> assert_one_line!()
      assert first.exit == 2
      again = root |> F.shape(args) |> assert_one_line!()
      assert again.exit == 2
      assert again.json == first.json
      assert first.json["error"]["code"] != "usage"

      changed =
        root
        |> F.shape([id, "--approve", "p-8-0123456789ab", "--request-id", "r-appr"])
        |> assert_one_line!()

      assert changed.exit == 2
      assert changed.json["error"]["code"] == "request_conflict"
    end

    test "reusing a start request ID with other bytes, another interface or another route is request_conflict" do
      root = F.repo!(turns: [[]])
      brief = F.input!(root, "brief.md", "Add a demo flag.\n")
      other = F.input!(root, "other.md", "Add a different flag.\n")

      first =
        root
        |> F.shape(["--brief", brief, "--request-id", "r1", "--interface", "cli"])
        |> assert_one_line!()

      assert first.exit == 0
      id = first.json["session"]
      settle!(root, id)
      record_path = Path.join([root, ".kogen/runtime/shaping/start-requests/r1.json"])
      recorded = File.read!(record_path)
      assert %{"outcome" => %{"session" => ^id}, "exit" => 0} = Jason.decode!(recorded)

      for args <- [
            ["--brief", other, "--request-id", "r1", "--interface", "cli"],
            ["--brief", brief, "--request-id", "r1", "--interface", "web"],
            ["--brief", brief, "--request-id", "r1", "--interface", "cli", "--route", "other"]
          ] do
        result = root |> F.shape(args) |> assert_one_line!()
        assert result.exit == 2, inspect(args)
        assert result.json["error"]["code"] == "request_conflict", inspect(result.json)
      end

      # The first record was not overwritten and no second session or input appeared.
      assert File.read!(record_path) == recorded
      assert session_ids(root) == [id]

      assert File.read!(Path.join([F.session_dir(root, id), "inputs", "0001.md"])) ==
               "Add a demo flag.\n"
    end

    test "reusing a continue request ID with other bytes or another interface is request_conflict" do
      root = F.repo!(turns: [[]])
      id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")
      settle!(root, id)
      one = F.input!(root, "one.md", "First answer.\n")
      two = F.input!(root, "two.md", "Second answer.\n")

      first =
        root
        |> F.shape([id, "--brief", one, "--request-id", "r2", "--interface", "cli"])
        |> assert_one_line!()

      assert first.exit == 0
      settle!(root, id)
      record_path = Path.join([F.session_dir(root, id), "requests", "r2.json"])
      recorded = File.read!(record_path)

      for args <- [
            [id, "--brief", two, "--request-id", "r2", "--interface", "cli"],
            [id, "--brief", one, "--request-id", "r2", "--interface", "web"]
          ] do
        result = root |> F.shape(args) |> assert_one_line!()
        assert result.exit == 2
        assert result.json["error"]["code"] == "request_conflict"
      end

      assert File.read!(record_path) == recorded
      inputs = Path.wildcard(Path.join([F.session_dir(root, id), "inputs", "*.md"]))
      assert Enum.map(inputs, &Path.basename/1) == ["0001.md", "0002.md"]

      assert File.read!(Path.join([F.session_dir(root, id), "inputs", "0002.md"])) ==
               "First answer.\n"
    end
  end

  # --- legacy and unknown sessions ----------------------------------------------

  describe "session addressing" do
    test "a TUI-era Draft named by slug is legacy_draft_unsupported and its bytes are untouched" do
      root = F.repo!()
      draft = F.draft(root, "old-tui-draft")
      File.mkdir_p!(Path.join(draft, "evidence"))

      File.write!(
        Path.join(draft, "intent.yaml"),
        "id: 01965000-0000-7000-8000-000000000042\nslug: old-tui-draft\n"
      )

      File.write!(Path.join(draft, "INTENT.md"), "# Old\nmultibyte «ø» 名前\n")
      File.write!(Path.join(draft, "evidence/note.md"), "kept\n")
      before = hash_tree(Path.join(root, ".kogen/intents"))
      brief = F.input!(root, "m.md", "continue please\n")

      for args <- [
            ["old-tui-draft"],
            ["old-tui-draft", "--brief", brief],
            ["old-tui-draft", "--approve", "p-1-0123456789ab"],
            ["old-tui-draft", "--cancel"]
          ] do
        json = refused!(root, args, "legacy_draft_unsupported")
        assert json["error"]["message"] =~ "old-tui-draft"
      end

      result = root |> F.shape(["old-tui-draft"]) |> assert_one_line!()
      assert result.exit == 2
      assert result.json["error"]["code"] == "legacy_draft_unsupported"

      assert hash_tree(Path.join(root, ".kogen/intents")) == before
      refute stored?(root)
    end

    test "a TUI-era Draft named by its UUID is legacy_draft_unsupported too" do
      root = F.repo!()
      id = "01965000-0000-7000-8000-000000000043"
      draft = F.draft(root, "uuid-draft")
      File.mkdir_p!(draft)
      File.write!(Path.join(draft, "intent.yaml"), "id: #{id}\nslug: uuid-draft\n")
      before = hash_tree(Path.join(root, ".kogen/intents"))

      refused!(root, [id], "legacy_draft_unsupported")
      assert hash_tree(Path.join(root, ".kogen/intents")) == before
    end

    test "a non-UUID argument that names nothing, and an unknown UUID, are session_not_found" do
      root = F.repo!()

      for arg <- ["no-such-draft", "01965000-0000-7000-8000-0000000000ff", "../etc", "Not A Slug"] do
        json = refused!(root, [arg], "session_not_found")
        assert json["state"] == nil
      end

      brief = F.input!(root, "m.md", "hello\n")
      refused!(root, ["no-such-draft", "--brief", brief], "session_not_found")
      refused!(root, ["01965000-0000-7000-8000-0000000000ff", "--cancel"], "session_not_found")

      for arg <- ["no-such-draft", "01965000-0000-7000-8000-0000000000ff"] do
        result = root |> F.shape([arg]) |> assert_one_line!()
        assert result.exit == 2
        assert result.json["error"]["code"] == "session_not_found"
      end

      refute stored?(root)
    end
  end

  # --- caller and environment gates -----------------------------------------------

  describe "gates that refuse before anything is stored" do
    test "build_running while .kogen/build.lock exists, for start and for continue" do
      root = F.repo!(turns: [[]])
      id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")
      settle!(root, id)
      lock = Path.join(root, ".kogen/build.lock")
      File.write!(lock, ~s({"pid": 1}))
      brief = F.input!(root, "m.md", "later\n")
      inputs = Path.join(F.session_dir(root, id), "inputs")
      before = hash_tree(inputs)

      start = root |> F.shape(["--brief", brief]) |> assert_one_line!()
      assert start.exit == 2
      assert start.json["error"]["code"] == "build_running"

      cont = root |> F.shape([id, "--brief", brief]) |> assert_one_line!()
      assert cont.exit == 2
      assert cont.json["error"]["code"] == "build_running"

      assert session_ids(root) == [id]
      assert hash_tree(inputs) == before

      # Control: status is read-only and still answers while a Build runs.
      status = root |> F.shape([id]) |> assert_one_line!()
      assert status.exit == 0
      assert status.json["session"] == id

      File.rm!(lock)
    end

    test "KOGEN_ROLE set refuses managed_role and stores nothing" do
      root = F.repo!()
      brief = F.input!(root, "brief.md", "A brief.\n")

      for role <- ["shaping", "developer", "reviewer"] do
        json = refused!(root, ["--brief", brief], "managed_role", %{"KOGEN_ROLE" => role})
        assert json["error"]["message"] =~ role
      end

      refused!(root, ["01965000-0000-7000-8000-000000000001"], "managed_role", %{
        "KOGEN_ROLE" => "shaping"
      })

      # An empty role is not a role (control).
      refute match?(
               {%{"error" => %{"code" => "managed_role"}}, _},
               main(root, ["--bogus"], %{"KOGEN_ROLE" => ""})
             )

      raw =
        root
        |> F.shape(["--brief", brief], raw_env: true, env: [{"KOGEN_ROLE", "shaping"}])
        |> assert_one_line!()

      assert raw.exit == 2
      assert raw.json["error"]["code"] == "managed_role"
      refute stored?(root)

      # Control: the external-driver environment strips the role and starts.
      driver =
        root |> F.shape(["--brief", brief], env: [{"KOGEN_ROLE", nil}]) |> assert_one_line!()

      assert driver.exit == 0
      assert driver.json["session"] =~ @uuid
    end

    test "a completed request replays its recorded outcome after login loss or a Build lock; a new one is refused" do
      root = F.repo!(turns: [[]])
      brief = F.input!(root, "brief.md", "Add a demo flag.\n")
      started = root |> F.shape(["--brief", brief, "--request-id", "r-s"]) |> assert_one_line!()
      assert started.exit == 0
      id = started.json["session"]
      settle!(root, id)
      msg = F.input!(root, "m.md", "Steer: keep it small.\n")
      sent = root |> F.shape([id, "--brief", msg, "--request-id", "r-m"]) |> assert_one_line!()
      assert sent.exit == 0
      settle!(root, id)
      inputs = Path.join(F.session_dir(root, id), "inputs")
      before = hash_tree(inputs)

      # Login lost: identical retries replay; a new request is refused.
      for {args, first} <- [
            {["--brief", brief, "--request-id", "r-s"], started},
            {[id, "--brief", msg, "--request-id", "r-m"], sent}
          ] do
        replay = root |> F.shape(args, env: not_ready_env(root)) |> assert_one_line!()
        assert {replay.exit, replay.json} == {0, first.json}
      end

      fresh =
        root
        |> F.shape([id, "--brief", msg, "--request-id", "r-new"], env: not_ready_env(root))
        |> assert_one_line!()

      assert {fresh.exit, fresh.json["error"]["code"]} == {2, "harness_not_ready"}

      fresh_start =
        root
        |> F.shape(["--brief", brief, "--request-id", "r-start-new"], env: not_ready_env(root))
        |> assert_one_line!()

      assert {fresh_start.exit, fresh_start.json["error"]["code"]} == {2, "harness_not_ready"}

      # A Build lock: the same.
      lock = Path.join(root, ".kogen/build.lock")
      File.write!(lock, ~s({"pid": 1}))

      start_replay =
        root |> F.shape(["--brief", brief, "--request-id", "r-s"]) |> assert_one_line!()

      assert {start_replay.exit, start_replay.json} == {0, started.json}
      replay = root |> F.shape([id, "--brief", msg, "--request-id", "r-m"]) |> assert_one_line!()
      assert {replay.exit, replay.json} == {0, sent.json}

      fresh =
        root |> F.shape([id, "--brief", msg, "--request-id", "r-new2"]) |> assert_one_line!()

      assert {fresh.exit, fresh.json["error"]["code"]} == {2, "build_running"}

      fresh_start =
        root |> F.shape(["--brief", brief, "--request-id", "r-start-new2"]) |> assert_one_line!()

      assert {fresh_start.exit, fresh_start.json["error"]["code"]} == {2, "build_running"}

      changed = F.input!(root, "changed.md", "Different bytes.\n")

      for args <- [
            ["--brief", changed, "--request-id", "r-s"],
            [id, "--brief", changed, "--request-id", "r-m"]
          ] do
        conflict = root |> F.shape(args, env: not_ready_env(root)) |> assert_one_line!()
        assert {conflict.exit, conflict.json["error"]["code"]} == {2, "request_conflict"}
      end

      File.rm!(lock)

      assert hash_tree(inputs) == before
      assert session_ids(root) == [id]
    end

    test "a route's harness that is not ready is harness_not_ready and nothing is stored" do
      root = F.repo!()
      brief = F.input!(root, "brief.md", "A brief.\n")

      result =
        root
        |> F.shape(["--brief", brief], env: not_ready_env(root))
        |> assert_one_line!()

      assert result.exit == 2
      assert result.json["error"]["code"] == "harness_not_ready", inspect(result.json)
      assert result.json["error"]["message"] =~ "is not ready"
      refute stored?(root)
      assert F.launches(root) == []
    end

    test "a not-ready harness also refuses a continue message and stores no input" do
      root = F.repo!(turns: [[]])
      id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")
      settle!(root, id)
      inputs = Path.join(F.session_dir(root, id), "inputs")
      before = hash_tree(inputs)
      msg = F.input!(root, "m.md", "again\n")

      result =
        root
        |> F.shape([id, "--brief", msg], env: not_ready_env(root))
        |> assert_one_line!()

      assert result.exit == 2
      assert result.json["error"]["code"] == "harness_not_ready"
      assert hash_tree(inputs) == before
    end

    test "a hybrid route's not-ready adversarial Expert harness is refused, naming the role and harness" do
      root = F.repo!()
      File.write!(Path.join(root, ".kogen/config.yaml"), hybrid_config())

      claude_root = Path.join(root <> "-claude-root", "claude")
      File.mkdir_p!(Path.join(claude_root, "accounts/shared"))
      on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)

      {_out, 0} =
        System.cmd(
          "python3",
          [
            Path.join(@project_root, "test/support/managed_claude_fixture.py"),
            claude_root,
            Path.join(@project_root, "priv/kogen/claude_code/install.py")
          ],
          env: [{"KOGEN_ROLE", nil}, {"KOGEN_HARNESS_HOME", nil}],
          cd: @root
        )

      File.write!(Path.join(claude_root, "accounts/shared/.fake-login"), "claude.ai\n")
      brief = F.input!(root, "brief.md", "A brief.\n")

      # No `KOGEN_HARNESS`: both harnesses use real managed readiness, so only
      # the adversarial Codex harness (a fresh, unmanaged root) is not ready.
      result =
        F.shape(root, ["--brief", brief],
          env: [
            {"KOGEN_HARNESS", nil},
            {"KOGEN_CLAUDE_ROOT", claude_root},
            {"KOGEN_TEST_NATIVE_TRACE", Path.join(root <> "-claude-root", "claude-trace.jsonl")},
            {"KOGEN_CODEX_ROOT", Path.join(root <> "-claude-root", "codex-not-installed")}
          ]
        )

      assert_one_line!(result)
      assert result.exit == 2
      assert result.json["error"]["code"] == "harness_not_ready"

      assert result.json["error"]["message"] =~
               "expert harness codex is not ready: Kogen Codex is not installed. Run mix kogen.codex.install"

      refute result.json["error"]["message"] =~ "reviewer"
      refute stored?(root)
      assert F.launches(root) == []
    end
  end

  # --- routes and configuration -----------------------------------------------------

  describe "route selection" do
    test "an unknown --route is refused before any provider launch" do
      root = F.repo!()
      brief = F.input!(root, "brief.md", "A brief.\n")

      for route <- ["missing", "Codex"] do
        json = refused!(root, ["--brief", brief, "--route", route], "usage")

        assert json["error"]["message"] =~
                 "unknown route: #{route}; available routes: codex, other"
      end

      result = root |> F.shape(["--brief", brief, "--route", "missing"]) |> assert_one_line!()
      assert result.exit == 2
      assert result.json["error"]["code"] == "usage"
      assert result.json["error"]["message"] =~ "unknown route: missing"
      refute stored?(root)
      assert F.launches(root) == []
    end

    test "--route without a value, and --route on a session command, are usage errors" do
      root = F.repo!()
      brief = F.input!(root, "brief.md", "A brief.\n")
      id = "01965000-0000-7000-8000-00000000abcd"

      refused!(root, ["--brief", brief, "--route"], "usage")
      refused!(root, ["--route", "--brief", brief], "usage")
      refused!(root, [id, "--brief", brief, "--route", "codex"], "usage")
      refute stored?(root)
    end

    test "the selected route is recorded on the session and the other route is untouched" do
      root = F.repo!(turns: [[]])
      result = start!(root, "Use the other route.\n", ["--route", "other"])
      id = result.json["session"]
      assert result.json["route"] == "other"
      assert F.session(root, id)["route"] == "other"
      settle!(root, id)

      default = start!(root, "Use the default route.\n", ["--request-id", "second"])
      assert default.json["route"] == "codex"
      settle!(root, default.json["session"])
    end

    test "the flat configuration shape is refused before any launch, for start and continue" do
      root = F.repo!()
      brief = F.input!(root, "brief.md", "A brief.\n")

      File.write!(Path.join(root, ".kogen/config.yaml"), """
      harness: codex
      shaping: {model: current-shaper, effort: shaping-effort}
      developer: {model: current-developer, effort: developer-effort}
      reviewer: {model: current-reviewer, effort: reviewer-effort}
      helpers:
        scout: {model: current-scout, effort: scout-effort}
        worker: {model: current-worker, effort: worker-effort}
        expert: {model: current-expert, effort: expert-effort}
      outer_resumptions: 2
      verification_retries: 2
      offline_retries: 4
      """)

      for args <- [["--brief", brief], ["--brief", brief, "--route", "current"]] do
        json = refused!(root, args, "usage")
        assert json["error"]["message"] =~ "flat configuration shape"
        assert json["error"]["message"] =~ "define default_route and routes"
      end

      result = root |> F.shape(["--brief", brief]) |> assert_one_line!()
      assert result.exit == 2
      assert result.json["error"]["code"] == "usage"
      assert result.json["error"]["message"] =~ "flat configuration shape"
      refute stored?(root)
      assert F.launches(root) == []
    end
  end

  test "only the selected route is checked for harness support, proven models and readiness" do
    root = F.repo!(turns: [[]])
    config_path = Path.join(root, ".kogen/config.yaml")
    claude_root = Path.join(root <> "-claude-root", "claude")
    File.mkdir_p!(claude_root)
    on_exit(fn -> File.rm_rf(Path.dirname(claude_root)) end)

    broken = """
      pi:
        harness: pi-chatgpt
        shaping: {model: pi-model, effort: low}
        developer: {model: pi-model, effort: low}
        reviewer: {model: pi-model, effort: low}
        helpers:
          scout: {model: pi-model, effort: low}
          worker: {model: pi-model, effort: low}
          expert: {model: pi-model, effort: low}
      unproven:
        harness: claude
        shaping: {model: claude-unproven-9, effort: medium}
        developer: {model: claude-opus-5-5, effort: medium}
        reviewer: {model: claude-opus-5-5, effort: medium}
        helpers:
          scout: {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
          expert: {model: claude-opus-5-5, effort: high}
      claude:
        harness: claude
        shaping: {model: claude-opus-5-5, effort: medium}
        developer: {model: claude-opus-5-5, effort: medium}
        reviewer: {model: claude-opus-5-5, effort: medium}
        helpers:
          scout: {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
          expert: {model: claude-opus-5-5, effort: high}
    """

    config = File.read!(config_path)

    File.write!(
      config_path,
      String.replace(config, "outer_resumptions:", broken <> "outer_resumptions:", global: false)
    )

    brief = F.input!(root, "brief.md", "A brief.\n")

    # The selected Codex route proceeds although the other routes name an
    # unsupported harness, an unproven model and an uninstalled Claude Code.
    started =
      root
      |> F.shape(["--brief", brief], env: [{"KOGEN_CLAUDE_ROOT", claude_root}])
      |> assert_one_line!()

    assert started.exit == 0, started.stdout <> started.stderr
    assert started.json["route"] == "codex"
    settle!(root, started.json["session"])

    for {route, expected} <- [
          {"pi", "unsupported harness: pi-chatgpt; expected codex or claude"},
          {"unproven", "unsupported Claude Code model for shaping: claude-unproven-9"},
          {"claude",
           "Kogen Claude Code #{Kogen.ManagedRuntimeReady.claude_code_version()} is not installed. Run mix kogen.claude.install"}
        ] do
      result =
        root
        |> F.shape(["--brief", brief, "--route", route, "--request-id", "route-#{route}"],
          env: [{"KOGEN_CLAUDE_ROOT", claude_root}, {"KOGEN_HARNESS", nil}]
        )
        |> assert_one_line!()

      assert result.exit == 2, inspect(result.json)
      assert result.json["error"]["message"] =~ expected, inspect(result.json)
    end

    assert session_ids(root) == [started.json["session"]]
  end

  # The Expert task never reads the config: without a frozen assignment it
  # fails naming the missing assignment, even when the config is unreadable.
  test "mix kogen.expert without KOGEN_EXPERT names the missing assignment and never reads the config" do
    root = F.repo!()
    config = Path.join(root, ".kogen/config.yaml")
    File.write!(config, "not: [valid")
    File.chmod!(config, 0o000)
    on_exit(fn -> File.chmod(config, 0o644) end)

    for assignment <- [nil, ~s({"harness":"codex"})] do
      env = F.driver_env(F.env(root, [{"KOGEN_EXPERT", assignment}]))
      result = F.mix(root, ["kogen.expert", "Which lock order is safe?"], env)

      assert result.exit != 0
      output = result.stdout <> result.stderr
      assert output =~ "KOGEN_EXPERT assignment"
      refute output =~ "config.yaml"
    end
  end

  # No fake provider: real managed readiness against a Codex root that is not
  # installed, so the route's harness is not ready.
  defp not_ready_env(root) do
    [
      {"KOGEN_HARNESS", nil},
      {"KOGEN_CODEX_ROOT", Path.join(root <> "-none", "codex-not-installed")}
    ]
  end

  # A hybrid (role-level) route: Shaping runs on Claude Code, Reviewer and
  # Expert on Codex.
  defp hybrid_config do
    """
    default_route: hybrid
    routes:
      hybrid:
        shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
        developer: {harness: claude, model: claude-opus-5-5, effort: medium}
        reviewer:  {harness: codex, model: gpt-6.1-sol, effort: high}
        expert:    {harness: codex, model: gpt-6.1-sol, effort: high}
        helpers:
          claude:
            scout:  {model: claude-sonnet-5, effort: low}
            worker: {model: claude-sonnet-5, effort: medium}
          codex:
            scout:  {model: gpt-6-luna, effort: low}
            worker: {model: gpt-6-luna, effort: high}
    outer_resumptions: 2
    verification_retries: 2
    offline_retries: 4
    """
  end

  # --- stdout purity -----------------------------------------------------------------

  test "status, cancel and continue after a killed runner keep stdout to one JSON line" do
    root = F.repo!(turns: [[%{"sleep" => 30}]])
    id = root |> start!() |> Map.fetch!(:json) |> Map.fetch!("session")

    # Wait for the runner to hold the session, then kill it hard.
    running = F.await(root, id, &(&1["runner"] == true and &1["turn_active"] == true))
    assert running["runner"] == true
    lock = Path.join(F.session_dir(root, id), ".kogen/build.lock")
    assert %{"pid" => pid} = lock |> File.read!() |> Jason.decode!()
    System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
    refute wait_dead(pid) == :alive

    status = root |> F.shape([id]) |> assert_one_line!()
    assert status.exit == 0
    assert status.json["runner"] == false
    assert status.json["state"] == "interrupted"
    assert status.json["stored_state"] == "running"
    assert status.json["state_source"] == "runner_custody"
    assert status.json["execution"]["status"] == "interrupted"
    assert status.json["execution"]["cause"] =~ "PID start time changed"

    cancel = root |> F.shape([id, "--cancel"]) |> assert_one_line!()
    assert cancel.exit == 0
    assert cancel.json["receipt"]["effect_status"] == "pending"
    assert cancel.json["session"] == id

    settled =
      F.await(root, id, fn saved ->
        saved["runner"] == false and get_in(saved, ["cancellation", "status"]) == "settled"
      end)

    assert settled["state"] == "cancelled"

    # Provider diagnostics and custody notices go to stderr, never stdout.
    refute cancel.stdout =~ "Reclaimed"
  end

  test "public cancel receipt is prompt and remains pending while an exact TERM-ignoring owner lives" do
    ask = [
      %{"create_draft" => %{"template" => F.ready_template()}},
      %{"ask" => %{"number" => 1, "question" => "Which name should the flag have?"}}
    ]

    root = F.repo!(turns: [ask, []])
    start = root |> start!() |> Map.fetch!(:json)
    id = start["session"]

    assert start["receipt"]["command"] == "start"
    assert start["receipt"]["effect_status"] == "received"
    assert start["received_input"]["number"] == 1
    assert start["received_input"]["status"] == "received"

    F.await(root, id, &(&1["runner"] == false))
    answer = F.input!(root, "before-cancel.md", "Keep this accepted answer.\n")
    received = F.shape(root, [id, "--brief", answer, "--request-id", "before-cancel"])
    assert received.exit == 0
    assert received.json["receipt"]["request_id"] == "before-cancel"
    assert received.json["received_input"]["id"] =~ ~r/^in-0002-/
    assert received.json["received_input"]["number"] == 2
    assert received.json["received_input"]["status"] == "received"
    F.await(root, id, &(&1["runner"] == false))

    owner_path = Path.join(root, ".kogen/test-term-ignoring-owner.pid")
    owner_signal_path = owner_path <> ".signals"
    {owner_task, owner_pid, owner_started} = term_ignoring_owner!(owner_path, owner_signal_path)
    session_dir = F.session_dir(root, id)
    lock_path = Kogen.ProcessCustody.lock_path(session_dir)
    File.mkdir_p!(Path.dirname(lock_path))

    File.write!(
      lock_path,
      Jason.encode!(%{
        "pid" => owner_pid,
        "started_at" => owner_started,
        "build_id" => "kogen-shaping-runner",
        "groups" => []
      })
    )

    args = [id, "--cancel", "--request-id", "public-cancel"]
    cancel_started = System.monotonic_time(:millisecond)
    cancel = root |> F.shape(args) |> assert_one_line!()
    external_elapsed = System.monotonic_time(:millisecond) - cancel_started

    assert cancel.exit == 0
    assert external_elapsed < 10_000

    assert cancel.json["receipt"] == %{
             "command" => "cancel",
             "effect_status" => "pending",
             "received_at" => cancel.json["receipt"]["received_at"],
             "request_id" => "public-cancel"
           }

    assert cancel.json["runner"] == true
    assert cancel.json["cancellation"]["status"] == "pending"

    assert cancel.json["cancellation"]["owner"] == %{
             "pid" => owner_pid,
             "started_at" => owner_started
           }

    coalesced = F.shape(root, [id, "--cancel", "--request-id", "public-cancel-second"])
    assert coalesced.exit == 0
    assert coalesced.json["receipt"]["effect_status"] == "pending"
    assert coalesced.json["cancellation"]["status"] == "pending"
    assert coalesced.json["cancellation"]["signal_status"] == "coalesced"

    assert "TERM\n" == File.read!(owner_signal_path)

    status = root |> F.shape([id]) |> assert_one_line!()
    assert status.json["cancellation"]["status"] == "pending"
    assert Enum.map(status.json["inputs"], & &1["number"]) == [1, 2]

    last_progress = status.json["inputs"] |> List.last() |> Map.fetch!("progress")
    assert last_progress in ["offered", "recorded", "received"]

    busy = F.shape(root, [id, "--brief", answer, "--request-id", "after-cancel"])
    assert busy.exit == 2
    assert busy.json["error"]["code"] == "busy"
    assert length(Store.messages(session_dir)) == 1

    replay = root |> F.shape(args) |> assert_one_line!()
    assert replay.json == cancel.json

    conflict = F.shape(root, [id, "--brief", answer, "--request-id", "public-cancel"])
    assert conflict.exit == 2
    assert conflict.json["error"]["code"] == "request_conflict"

    if Kogen.ProcessCustody.process_start(owner_pid) == owner_started do
      System.cmd("kill", ["-KILL", to_string(owner_pid)], stderr_to_stdout: true)
    end

    _ = Task.await(owner_task, 30_000)

    # A retry with another request ID finds the durable pending effect, does
    # not target a replacement process, and starts the existing recovery seam.
    recovery = F.shape(root, [id, "--cancel", "--request-id", "cancel-recovery"])
    assert recovery.exit == 0

    settled =
      F.await(root, id, fn saved ->
        saved["runner"] == false and get_in(saved, ["cancellation", "status"]) == "settled"
      end)

    assert settled["state"] == "cancelled"
    assert Enum.map(Store.messages(session_dir), & &1["number"]) == [2]
    assert length(Store.inputs(session_dir)) == 2
  end

  defp wait_dead(pid, tries \\ 100) do
    cond do
      not F.alive?(pid) -> :dead
      tries == 0 -> :alive
      true -> Process.sleep(50) && wait_dead(pid, tries - 1)
    end
  end

  defp term_ignoring_owner!(pid_path, signal_path) do
    script = """
    import os, pathlib, signal, sys, time
    def record_and_ignore(signum, frame):
        with open(sys.argv[2], "a") as signals:
            signals.write("TERM\\n")
    signal.signal(signal.SIGTERM, record_and_ignore)
    pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
    time.sleep(240)
    """

    task =
      Task.async(fn ->
        System.cmd("python3", ["-B", "-c", script, pid_path, signal_path], stderr_to_stdout: true)
      end)

    pid = pid_path |> wait_file_contents!() |> String.to_integer()
    started = Kogen.ProcessCustody.process_start(pid)
    assert started != ""

    ExUnit.Callbacks.on_exit(fn ->
      if Kogen.ProcessCustody.process_start(pid) == started do
        System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
      end
    end)

    {task, pid, started}
  end

  defp wait_file_contents!(path, tries \\ 1_000) do
    case File.read(path) do
      {:ok, contents} ->
        contents

      _ when tries > 0 ->
        Process.sleep(10)
        wait_file_contents!(path, tries - 1)

      _ ->
        flunk("timed out waiting for #{path}")
    end
  end

  # --- help surface -------------------------------------------------------------------

  describe "help surface" do
    test "the moduledoc names exactly the five invocations and no removed flag" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Mix.Tasks.Kogen.Shape)

      invocations =
        Regex.scan(~r/^\s+mix kogen\.shape\b.*$/m, doc)
        |> List.flatten()
        |> Enum.map(&String.trim/1)

      assert invocations == [
               "mix kogen.shape --brief FILE [--route ROUTE] [--interface NAME] [--request-id RID]",
               "mix kogen.shape ID",
               "mix kogen.shape ID --brief FILE [--interface NAME] [--request-id RID]",
               "mix kogen.shape ID --approve PRESENTATION [--interface NAME] [--request-id RID]",
               "mix kogen.shape ID --cancel [--request-id RID]"
             ]

      for removed <- [
            "--headless",
            "--expected-revision",
            "draft-slug",
            "--resume",
            "--interactive"
          ] do
        refute doc =~ removed, removed
      end
    end

    test "mix help kogen.shape prints that text, and the runner task is hidden" do
      root = F.repo!()
      help = F.mix(root, ["help", "kogen.shape"], F.driver_env(F.env(root)))
      assert help.exit == 0
      refute help.stdout =~ "--headless"
      refute help.stdout =~ "--expected-revision"
      assert help.stdout =~ "mix kogen.shape ID --approve PRESENTATION"
      assert help.stdout =~ "mix kogen.shape ID --cancel [--request-id RID]"

      listing = F.mix(root, ["help"], F.driver_env(F.env(root)))
      assert listing.exit == 0
      assert listing.stdout =~ ~r/^mix kogen\.shape\s/m
      refute listing.stdout =~ "kogen.shape.runner"

      {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(Mix.Tasks.Kogen.Shape.Runner)
      assert moduledoc == :hidden
    end

    test "the retired interactive surface is gone" do
      for module <- [Kogen.Intent, Kogen.Harness, Kogen.Shaping],
          do: Code.ensure_loaded!(module)

      refute function_exported?(Kogen.Intent, :read_draft, 1)
      refute function_exported?(Kogen.Harness, :exec_shaper, 4)
      refute File.exists?(Path.join(@project_root, "priv/kogen/prompts/shaping-continuation.md"))
      assert function_exported?(Kogen.Shaping, :main, 2)
    end
  end

  # --- prompts and README -------------------------------------------------------------

  test "fresh shaping guidance requires autonomous outcome-focused investigation" do
    prompt = File.read!(Path.join(@project_root, "priv/kogen/prompts/shaping.md"))
    compact = Regex.replace(~r/\s+/, prompt, " ")

    assert DR.missing_paths(@root, prompt) == []

    for text <- [
          "source-linked probe",
          "A plan to probe is not execution",
          "A different passing mock cannot repair missing credentials",
          "end the turn without asking for approval",
          "request for package review is not approval",
          "zero questions is not itself a quality target"
        ] do
      assert compact =~ text
    end

    required = [
      "Start useful native helpers early for independent codebase, supplied-source, web-documentation and probe work. Give helpers paths and constraints rather than copied file bodies. Continue reading and reviewing in the root session when useful; root ownership includes coverage, integration and challenging helper conclusions.",
      "Ask the human about a consequential unanswered product, UX, policy, scope, compatibility, data-loss or authority choice when it becomes clear, through a maintained `## Ask the Shaper` entry.",
      "Do not run `mix kogen.audit` during Shaping; end the turn instead.",
      "Ask a consequential human question as soon as its choice is understood, by writing it under `## Ask the Shaper` in the maintained package. Include the outcome at stake, a recommendation and evidence. Record the answer and its provenance; keep unresolved choices pending. Silence, session duration and work-budget expiry never resolve a question.",
      "Keep working on independent tasks while a choice is pending. Do not commit to work that depends on the answer, silently assume the choice, or mark the Draft ready while a consequential choice remains unresolved. Partial answers settle only their explicit or necessarily entailed part.",
      "Use engineering judgment for routine implementation, process and verification details. Ask about material human choices, not permission to do work already authorized.",
      "Keep it simple: no config switches, no plumbing without a caller, no unrequested splits.",
      "`title` and `commit_subject` are related but separate fields. Both follow [cbea.ms](https://cbea.ms/git-commit/): imperative mood, capitalised, no trailing period, no commit body. `title` stays the Intent's short name, at most 50 characters. `commit_subject` is required in `intent.yaml` on every Draft, aims at most 50 characters, and must never exceed 72. Prefer a subject derived from the slug in words",
      "a probe is executed, not planned.",
      "Use the smallest probe that settles the assumption: a mini-project in a temp git repo; one real CLI call through Kogen's own launch path",
      "Probe every harness a change reaches, with a disconfirming control.",
      "Check harness readiness first for every harness the probes or paid targets use",
      "one clone per parallel helper",
      "Evidence goes in `evidence/probe-<topic>/`: the script, the inputs, per-run summaries and a `RESULT.md`",
      "never the full test suite, a full live target, a full Build or a full Shape session as the probe itself.",
      "List every risk and assumption behind each scenario, proof and paid target, including whether the end result works at all.",
      "The Draft states the intended outcomes, observable acceptance, constraints, compatibility and preservation requirements, risks, evidence and proof obligations.",
      "Give the Developer freedom to choose implementation details inside that contract; do not prescribe exact files, functions or algorithms without a demonstrated need.",
      "Do not leave a consequential public behavior choice hidden as implementation freedom.",
      "Whether the end result is viable at all is itself a risk to probe, not an assumption left for Build.",
      "an offline test, then an offline replay of retained real provider evidence, then a minimal live smoke, and an existing expensive target only when its full observable is needed.",
      "Before probing a tool's behaviour, have a helper research its documentation on the web first.",
      "Report meaningful progress.",
      "Explicit user-provided session budgets limit work; they do not authorize assumptions or close pending questions.",
      "Record the material requirement or decision, its source/provenance and where it applies.",
      "do not duplicate every remark or complaint verbatim or copy bulk conversation history into Intent.",
      "A remark about how Shaping itself works is also a requirement for all future Shaping sessions.",
      "Environment facts the Shaper supplies (a key, a path, \"try again\") are used at once, not re-derived.",
      "A file or handoff the Shaper points to is read in full and folded into the Draft in the same turn.",
      "A slug rename changes the directory first and the slug second, in one step. The Shaper addresses the session by its Intent id, never by slug.",
      "Shaping workers may write only their disposable probe directories and the Draft files their packet assigns, on the relevant harnesses.",
      "A probe that launches a provider in a disposable directory is not a verification gate.",
      "You never approve the Intent, never move a Draft out of `.kogen/intents/drafts/`, and never write `approval.md` or approval metadata.",
      "Reshape against the actual project baseline and current `HEAD`; do not assume the target branch is `main`. Re-verify anchors, update `shaped_against`, and record baseline moves with evidence.",
      "### Routine engineering findings: the seven default fixes",
      "An edited live owner that is not selected: remove the edit when the outcome does not need it; otherwise select the target.",
      "Scope drift into another ROADMAP row's area",
      "A contradiction with another staged or approved package: align with the other package, whose contract wins.",
      "Ask only about consequential unanswered product, UX, policy, scope, compatibility, data-loss or authority choices, and state the concrete consequence.",
      "If so, surface that choice whenever discovered and keep it pending until answered.",
      "An unproven paid-path assumption: run the probe in a disposable clone; never ask.",
      "A paid target justified only by an edited owner: apply rule 1.",
      "A moved baseline: re-verify the anchors and update `shaped_against`",
      "Anything relabelling a timeout or failure as provider or environment: challenge it, because only explicit provider markers count."
    ]

    for text <- required, do: assert(compact =~ text)

    removed = [
      "If it changed, surface this and discuss reassessment with the Shaper",
      "Any eventual baseline update requires an explicit shaping decision",
      "ask where the Shaper wants to continue only when the human supplied no direction",
      "no separate approval command or Intent-quality validator",
      "The first stop is the only time you may ask",
      "There is no native mid-turn question tool",
      "never from timers",
      "or implement production code during Shaping",
      "paid or harness probes stay with the root"
    ]

    for name <- ["shaping.md", "shaping-fresh.md"],
        text <- removed do
      other = File.read!(Path.join(@project_root, "priv/kogen/prompts/#{name}"))
      refute Regex.replace(~r/\s+/, other, " ") =~ text, "#{name}: #{text}"
    end
  end

  # Short anchors for the verified_by/proof contract the format code
  # actually parses (`provider-required:`/`offline-sufficient:`), not the
  # surrounding prose.
  test "shaping prompt describes verified_by as the complete explicit target list and keeps the paid-reason format" do
    prompt = File.read!(Path.join(@project_root, "priv/kogen/prompts/shaping.md"))
    compact = Regex.replace(~r/\s+/, prompt, " ")

    assert DR.missing_paths(@root, prompt) == []

    for text <- [
          "no implicit `check`",
          "provider-required: <exact-target>; observation: <provider-only observable>; offline-limit:",
          "offline-sufficient: <consumer/control>",
          "`proof.base`",
          "catalog_changes.add",
          "verification_surface",
          "focused_runner",
          "base_cache"
        ] do
      assert compact =~ text
    end
  end

  test "README documents the Choosing verification targets policy" do
    readme = File.read!(Path.join(@project_root, "README.md"))
    compact = Regex.replace(~r/\s+/, readme, " ")

    assert readme =~ "## Choosing verification targets"

    for text <- [
          "orchestration",
          "offline-only",
          "unverified",
          "one paid target",
          "questions.md"
        ] do
      assert compact =~ text
    end
  end
end
