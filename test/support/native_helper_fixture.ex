defmodule Kogen.NativeHelperFixture do
  @moduledoc false

  # A deliberately small read-only fixture for the provider-backed routing
  # probe. It is test support, rather than a product dispatcher: the live
  # driver asks Codex to make these three bounded calls and this module checks
  # the runner-owned receipt it retains afterwards.
  @tasks [
    %{
      name: "fresh_scout_route",
      helper: :scout,
      kind: "explorer",
      file: "scout.json",
      expected: %{"release" => "r17", "channel" => "stable", "enabled" => true},
      schema: "{\"release\": string, \"channel\": string, \"enabled\": boolean}",
      instruction:
        "Read scout.json only. Report the current release, channel, and enabled value; do not edit files."
    },
    %{
      name: "fresh_worker_route",
      helper: :worker,
      kind: "worker",
      file: "worker.json",
      expected: %{"records" => [%{"id" => "a", "value" => 1}, %{"id" => "b", "value" => 2}]},
      schema: "{\"records\":[{\"id\": string, \"value\": integer}]}",
      instruction:
        "Read worker.json only. Report the sorted normalized non-conflicting records exactly; do not edit files."
    },
    %{
      name: "fresh_expert_route",
      helper: :expert,
      kind: "default",
      file: "review_boundary.py",
      expected: %{"provider_failure_result" => "provider_error"},
      schema: "{\"provider_failure_result\": string}",
      instruction:
        "Read review_boundary.py only. Report the result required for provider failure; do not edit files."
    }
  ]

  @files %{
    "scout.json" =>
      "{\"current\":{\"release\":\"r17\",\"channel\":\"stable\",\"enabled\":true},\"historical\":{\"release\":\"r16\",\"channel\":\"preview\",\"enabled\":false}}\n",
    "worker.json" =>
      "{\"records\":[{\"id\":\"B\",\"value\":2},{\"id\":\"a\",\"value\":1},{\"id\":\"b\",\"value\":2}],\"rules\":[\"lowercase ids\",\"deduplicate equal normalized records\",\"reject conflicting duplicates\"]}\n",
    "review_boundary.py" =>
      "def outcome(provider_failed, verdict_valid):\n    if provider_failed:\n        return 'provider_error'\n    return 'accept' if verdict_valid else 'malformed_verdict'\n"
  }

  def files, do: @files

  def tasks(config) do
    Enum.map(@tasks, fn task ->
      profile = get_in(config, [:helpers, task.helper])

      Map.take(task, [:name, :kind, :file, :expected, :schema, :instruction])
      |> Map.merge(%{model: profile.model, effort: profile.effort})
    end)
  end

  def protocol(config, role) when role in ["shaping", "developer", "reviewer"] do
    root = Map.fetch!(config, String.to_existing_atom(role))

    %{
      "parent_profile" => %{"model" => root.model, "effort" => root.effort},
      "fixture_sha256" => file_digests(),
      "children" =>
        Enum.map(tasks(config), &Map.new(&1, fn {key, value} -> {Atom.to_string(key), value} end))
    }
  end

  # The policy renderer is intentionally the production renderer. The appended
  # packet gives a live parent a compact, deterministic read-only task only.
  def prompt(config, role) when role in ["shaping", "developer", "reviewer"] do
    rendered = Kogen.ExecutionPolicy.render(config, role)

    assignments =
      tasks(config)
      |> Enum.map_join("\n\n", fn task ->
        """
        Native child `#{task.name}`: call `spawn_agent` with agent_type `#{task.kind}`, model `#{task.model}`, reasoning_effort `#{task.effort}`, and fork_turns `none`.
        Read-only boundary: inspect only `fixture/#{task.file}`. #{task.instruction}
        Do not spawn children, modify files, run any gate/Make target/Stop script, or retry. Return exactly one JSON object matching #{task.schema}; derive its values from the fixture and include no prose.
        """
      end)

    rendered <>
      "\n\n## Bounded native-helper routing probe\n\n" <>
      "This is a read-only routing probe. Do not modify any file, run a gate, Make target, or Stop script.\n\n" <>
      assignments <>
      "\n\nWait for all three children. Do not make another native call. Your final answer may only state that all requested child returns were collected."
  end

  def write_fixture!(root) do
    fixture = Path.join(root, "fixture")
    File.mkdir_p!(fixture)
    Enum.each(@files, fn {name, bytes} -> File.write!(Path.join(fixture, name), bytes) end)
    fixture
  end

  # Session records are the native runner's evidence. The live test supplies
  # the Harness-returned parent id, so an unrelated session with a convenient
  # common parent can never satisfy this collector.
  def collect_receipt!(sessions_root, raw_root, parent_id, fixture, protocol) do
    sessions = session_index!(sessions_root, parent_id)
    {parent_path, parent_meta} = Map.fetch!(sessions, parent_id)
    parent_bytes = File.read!(parent_path)
    parent_rows = rows_from_bytes!(parent_bytes)
    calls = child_calls!(parent_rows, protocol["children"])
    File.mkdir_p!(raw_root)
    File.write!(Path.join(raw_root, "parent.jsonl"), parent_bytes)
    owned = owned_children!(sessions, parent_id, protocol["children"])

    children =
      protocol["children"]
      |> Enum.map(fn task -> collect_child!(owned, raw_root, task, calls) end)

    receipt = %{
      "parent_id" => parent_id,
      "parent_profile" => single_profile!(parent_rows),
      "parent_source_sha256" => digest(parent_bytes),
      "fixture_sha256" => fixture_digests!(fixture),
      "fixture_unchanged" => fixture_unchanged?(fixture, protocol["fixture_sha256"]),
      "children" => children
    }

    if parent_meta["id"] != parent_id,
      do: raise(ArgumentError, "native parent metadata disagrees")

    receipt
  end

  def validate_receipt(receipt, protocol) when is_map(receipt) and is_map(protocol) do
    with :ok <- fixture_unchanged(receipt, protocol),
         :ok <- parent_profile(receipt, protocol),
         true <- nonblank?(receipt["parent_source_sha256"]),
         :ok <- children(receipt, protocol) do
      :ok
    else
      _ -> {:error, "native receipt has missing or contradictory parent evidence"}
    end
  end

  def validate_receipt(_, _), do: {:error, "native receipt must be an object"}

  defp fixture_unchanged(receipt, protocol) do
    if receipt["fixture_unchanged"] == true and
         receipt["fixture_sha256"] == protocol["fixture_sha256"],
       do: :ok,
       else: {:error, "native fixture changed or lacks its matching digest"}
  end

  defp parent_profile(receipt, protocol) do
    if nonblank?(receipt["parent_id"]) and receipt["parent_profile"] == protocol["parent_profile"],
      do: :ok,
      else: {:error, "native parent identity or profile is missing or wrong"}
  end

  defp children(receipt, protocol) do
    expected = Map.new(protocol["children"], &{&1["name"], &1})
    actual = receipt["children"]

    with true <- is_list(actual) and length(actual) == map_size(expected),
         true <- Enum.all?(actual, &is_map/1),
         true <- MapSet.new(Enum.map(actual, & &1["name"])) == MapSet.new(Map.keys(expected)),
         true <- Enum.uniq(Enum.map(actual, & &1["child_id"])) |> length() == length(actual),
         true <- Enum.all?(actual, &valid_child?(&1, expected, receipt["parent_id"])) do
      :ok
    else
      _ -> {:error, "native child metadata is missing, unrelated, incomplete, or contradictory"}
    end
  end

  defp valid_child?(child, expected, parent_id) when is_map(child) do
    task = expected[child["name"]]

    task != nil and nonblank?(child["child_id"]) and child["parent_id"] == parent_id and
      requested_profile?(child, task) and
      child["observed_profiles"] == [[task["model"], task["effort"]]] and
      child["complete"] == true and nonblank?(child["source_sha256"]) and
      child["observed_task"] == task["expected"]
  end

  defp valid_child?(_, _, _), do: false

  defp requested_profile?(child, task) do
    expected = %{
      "requested_kind" => task["kind"],
      "requested_model" => task["model"],
      "requested_effort" => task["effort"],
      "requested_fork_turns" => "none"
    }

    Map.take(child, Map.keys(expected)) == expected
  end

  defp session_index!(root, parent_id) do
    headers =
      root
      |> Path.join("**/*.jsonl")
      |> Path.wildcard()
      |> Enum.flat_map(&session_header/1)

    child_ids =
      headers
      |> Enum.filter(fn {_path, meta} -> meta["parent_thread_id"] == parent_id end)
      |> MapSet.new(fn {_path, meta} -> meta["id"] end)

    headers
    |> Enum.filter(fn {_path, meta} ->
      meta["id"] == parent_id or meta["parent_thread_id"] == parent_id or
        MapSet.member?(child_ids, meta["parent_thread_id"])
    end)
    |> Enum.reduce(%{}, &index_session/2)
  end

  defp session_header(path) do
    case session_meta(path) do
      {:ok, %{"id" => id} = meta} when is_binary(id) and id != "" -> [{path, meta}]
      _ -> []
    end
  end

  defp index_session({path, meta}, index) do
    id = meta["id"]
    if Map.has_key?(index, id), do: raise(ArgumentError, "duplicate native session id: #{id}")
    Map.put(index, id, {path, meta})
  end

  defp child_calls!(parent_rows, tasks) do
    expected = MapSet.new(Enum.map(tasks, & &1["name"]))

    calls =
      parent_rows
      |> Enum.flat_map(fn
        %{
          "type" => "response_item",
          "payload" => %{"type" => "function_call", "name" => "spawn_agent", "arguments" => json}
        } ->
          case Jason.decode(json) do
            {:ok, %{"task_name" => name} = call} -> [{name, call}]
            _ -> raise ArgumentError, "malformed native child call"
          end

        _ ->
          []
      end)

    if MapSet.new(Enum.map(calls, &elem(&1, 0))) != expected or length(calls) != length(tasks),
      do: raise(ArgumentError, "missing or repeated requested native child call")

    Map.new(calls)
  end

  defp collect_child!(owned, raw_root, task, calls) do
    {child_id, {path, meta}} = Map.fetch!(owned, task["name"])
    bytes = File.read!(path)
    rows = rows_from_bytes!(bytes)
    File.write!(Path.join(raw_root, task["name"] <> ".jsonl"), bytes)
    call = Map.fetch!(calls, task["name"])
    answer = final_answer(rows)

    %{
      "name" => task["name"],
      "parent_id" => meta["parent_thread_id"],
      "child_id" => child_id,
      "requested_kind" => call["agent_type"],
      "requested_model" => call["model"],
      "requested_effort" => call["reasoning_effort"],
      "requested_fork_turns" => call["fork_turns"],
      "observed_profiles" => observed_profiles(rows),
      "complete" => complete?(rows),
      "source_sha256" => digest(bytes),
      "answer" => answer,
      "observed_task" => decode_answer!(answer)
    }
  end

  defp rows_from_bytes!(bytes) do
    bytes
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp session_meta(path) do
    case File.open(path, [:read], fn file -> IO.read(file, :line) end) do
      {:ok, line} when is_binary(line) ->
        case Jason.decode(line) do
          {:ok, %{"type" => "session_meta", "payload" => meta}} when is_map(meta) -> {:ok, meta}
          _ -> :ignore
        end

      _ ->
        :ignore
    end
  end

  defp owned_children!(sessions, parent_id, tasks) do
    expected = MapSet.new(Enum.map(tasks, & &1["name"]))

    owned =
      Enum.filter(sessions, fn {_id, {_path, meta}} -> meta["parent_thread_id"] == parent_id end)

    names =
      Enum.map(owned, fn {_id, {_path, meta}} -> Path.basename(meta["agent_path"] || "") end)

    if MapSet.new(names) != expected or length(names) != length(tasks),
      do: raise(ArgumentError, "missing, duplicate, or unexpected native child session")

    child_ids = MapSet.new(Enum.map(owned, &elem(&1, 0)))

    if Enum.any?(sessions, fn {_id, {_path, meta}} ->
         MapSet.member?(child_ids, meta["parent_thread_id"])
       end),
       do: raise(ArgumentError, "native helper spawned an unexpected descendant")

    Map.new(owned, fn {id, value} ->
      {Path.basename(elem(value, 1)["agent_path"]), {id, value}}
    end)
  end

  defp observed_profiles(rows) do
    rows
    |> Enum.flat_map(fn
      %{"type" => "turn_context", "payload" => payload} when is_map(payload) ->
        [[payload["model"], payload["effort"]]]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp single_profile!(rows) do
    case observed_profiles(rows) do
      [[model, effort]] -> %{"model" => model, "effort" => effort}
      _ -> raise ArgumentError, "native parent has missing or contradictory turn_context profile"
    end
  end

  defp complete?(rows) do
    Enum.any?(rows, fn
      %{"type" => "event_msg", "payload" => %{"type" => "task_complete"}} -> true
      _ -> false
    end)
  end

  defp final_answer(rows) do
    rows
    |> Enum.flat_map(fn
      %{
        "type" => "event_msg",
        "payload" => %{"type" => "task_complete", "last_agent_message" => answer}
      }
      when is_binary(answer) ->
        [answer]

      %{
        "type" => "response_item",
        "payload" => %{
          "type" => "message",
          "role" => "assistant",
          "channel" => "final",
          "content" => content
        }
      } ->
        Enum.flat_map(content, fn
          %{"type" => "output_text", "text" => answer} -> [answer]
          _ -> []
        end)

      _ ->
        []
    end)
    |> List.last()
    |> case do
      answer when is_binary(answer) -> answer
      _ -> raise ArgumentError, "native child has no final answer"
    end
  end

  defp decode_answer!(answer) do
    answer = String.trim(answer)
    answer = Regex.replace(~r/^```(?:json)?\s*|\s*```$/u, answer, "") |> String.trim()

    case Jason.decode(answer) do
      {:ok, value} when is_map(value) -> value
      _ -> raise ArgumentError, "native child did not return the requested JSON object"
    end
  end

  defp fixture_digests!(fixture) do
    Map.new(@files, fn {name, _bytes} ->
      {name, Path.join(fixture, name) |> File.read!() |> digest()}
    end)
  end

  defp fixture_unchanged?(fixture, expected) do
    actual_names =
      fixture
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&Path.relative_to(&1, fixture))
      |> MapSet.new()

    actual_names == MapSet.new(Map.keys(expected)) and
      Enum.all?(Map.keys(expected), fn name ->
        case File.lstat(Path.join(fixture, name)) do
          {:ok, %{type: :regular}} -> true
          _ -> false
        end
      end) and fixture_digests!(fixture) == expected
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp file_digests do
    Map.new(@files, fn {name, bytes} ->
      {name, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
    end)
  end

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_), do: false
end
