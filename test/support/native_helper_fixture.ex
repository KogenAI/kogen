defmodule Kogen.NativeHelperFixture do
  @moduledoc false

  # A deliberately small read-only fixture for the provider-backed routing
  # probe. It is test support, rather than a product dispatcher: the live
  # driver asks Codex to make these two bounded calls and this module checks
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
    }
  ]

  @files %{
    "scout.json" =>
      "{\"current\":{\"release\":\"r17\",\"channel\":\"stable\",\"enabled\":true},\"historical\":{\"release\":\"r16\",\"channel\":\"preview\",\"enabled\":false}}\n",
    "worker.json" =>
      "{\"records\":[{\"id\":\"B\",\"value\":2},{\"id\":\"a\",\"value\":1},{\"id\":\"b\",\"value\":2}],\"rules\":[\"lowercase ids\",\"deduplicate equal normalized records\",\"reject conflicting duplicates\"]}\n"
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

  # Reads only the Candidate's prompt and frozen route settings. The fixture
  # values make the normal role template safe to run as a read-only native
  # probe; the paid owner passes this result to prompt/3.
  def candidate_prompt(config, project_root) when is_map(config) and is_binary(project_root) do
    developer_path = Path.join(project_root, "priv/kogen/prompts/developer.md")
    developer_template = File.read!(developer_path)

    execution_policy =
      Kogen.ExecutionPolicy.render(config, "developer", project_root)

    replacements = %{
      "{{intent_title}}" => "Fix Build convergence and live selection",
      "{{intent_id}}" => "01a0e6df-71cf-78d7-9921-2c41bdd58979",
      "{{approved_path}}" => ".kogen/intents/approved/build-system-fixes",
      "{{may_change_guarded_paths}}" => "fixture/scout.json, fixture/worker.json",
      "{{verification_ownership}}" =>
        "This read-only routing probe has no developer-run verification target. Do not run any gate, Make target, or Stop script.",
      "{{readiness_scope}}" =>
        "fixture Candidate; changed paths: fixture/scout.json, fixture/worker.json",
      "{{readiness_commands}}" => "",
      "{{execution_policy}}" => execution_policy
    }

    rendered =
      Enum.reduce(replacements, developer_template, fn {placeholder, value}, text ->
        String.replace(text, placeholder, value)
      end)

    if Regex.match?(~r/\{\{[^}]+\}\}/, rendered),
      do:
        raise(ArgumentError, "Candidate Developer prompt has an unresolved template placeholder")

    rendered
  end

  # Offline tests can use the production execution-policy renderer. The live
  # proof must pass Build's fully rendered Candidate Developer prompt to /3.
  def prompt(config, role) when role in ["shaping", "developer", "reviewer"] do
    prompt(config, role, Kogen.ExecutionPolicy.render(config, role))
  end

  def prompt(config, role, candidate_prompt)
      when role in ["shaping", "developer", "reviewer"] and is_binary(candidate_prompt) do
    if String.trim(candidate_prompt) == "",
      do: raise(ArgumentError, "native helper fixture requires a rendered Candidate prompt")

    assignments =
      tasks(config)
      |> Enum.map_join("\n\n", fn task ->
        """
        Native child `#{task.name}`: call `spawn_agent` with agent_type `#{task.kind}`, model `#{task.model}`, reasoning_effort `#{task.effort}`, and no forked turns (`fork_turns` `none`, or `fork_context` false where the tool exposes only that parameter). Pass exactly this `message`, character for character, and add nothing to it:
        Task #{task.name}: Read-only boundary: inspect only `fixture/#{task.file}` (a relative path; your working directory already contains `fixture/`, so pass no `workdir` and never type an absolute path). #{task.instruction} This is a separate fixed slice; the other child owns a different fixture file. Do not spawn children, modify files, run any gate/Make target/Stop script, or retry. Return exactly one JSON object matching #{task.schema}; derive its values from the fixture and include no prose. If the file cannot be read, return {"error": "<what failed>"} and never guess values.
        """
      end)

    candidate_prompt <>
      "\n\n## Bounded native-helper routing probe\n\n" <>
      "This is a read-only routing probe using the rendered Candidate prompt and frozen Candidate settings. Start both independent child tasks concurrently before waiting for either result. Do not modify any file, run a gate, Make target, or Stop script.\n\n" <>
      assignments <>
      "\n\nWait for both children. Do not make another native call. If a child fails or returns invalid data, report the failure to the root and do not claim completion. Otherwise, your final answer may only state that both requested child returns were collected."
  end

  def prompt(_config, _role, _candidate_prompt),
    do: raise(ArgumentError, "native helper fixture requires a rendered Candidate prompt")

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
    owned = owned_children!(sessions, parent_id, protocol["children"], calls)

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
    outputs = spawn_outputs(parent_rows)

    first_wait =
      Enum.find_index(parent_rows, fn
        %{"type" => "response_item", "payload" => %{"type" => "function_call", "name" => name}} ->
          name in ["wait_agent", "write_stdin"]

        _ ->
          false
      end)

    spawn_positions =
      parent_rows
      |> Enum.with_index()
      |> Enum.filter(fn
        {%{
           "type" => "response_item",
           "payload" => %{"type" => "function_call", "name" => "spawn_agent"}
         }, _} ->
          true

        _ ->
          false
      end)
      |> Enum.map(&elem(&1, 1))

    if first_wait && Enum.any?(spawn_positions, &(&1 > first_wait)),
      do: raise(ArgumentError, "native child slices were not dispatched before waiting")

    calls =
      parent_rows
      |> Enum.flat_map(fn
        %{
          "type" => "response_item",
          "payload" =>
            %{"type" => "function_call", "name" => "spawn_agent", "arguments" => json} = payload
        } ->
          [normalize_call!(json, payload["call_id"], outputs, tasks)]

        _ ->
          []
      end)

    if MapSet.new(Enum.map(calls, &elem(&1, 0))) != expected or length(calls) != length(tasks),
      do: raise(ArgumentError, "missing or repeated requested native child call")

    Map.new(calls)
  end

  # Codex 0.158.0 spawn calls carry `task_name` and `fork_turns`, and the child
  # session records `agent_path`. Codex 0.159.0 (multi_agent_v1) has neither: the
  # call carries `fork_context` and a `message` that begins `Task <name>:`, its
  # output carries the child's `agent_id`, and the child's `agent_path` is null.
  # Both shapes are reduced to one name, one fork setting and (when the runner
  # recorded it) the spawned child id; anything else is a malformed call.
  defp normalize_call!(json, call_id, outputs, tasks) do
    with {:ok, %{} = call} <- Jason.decode(json),
         {:ok, name} <- call_name(call, tasks),
         {:ok, fork} <- call_fork(call),
         true <- Enum.all?(~w(agent_type model reasoning_effort), &is_binary(call[&1])) do
      agent_id = outputs |> Map.get(call_id, %{}) |> Map.get("agent_id")
      {name, call |> Map.put("fork_turns", fork) |> Map.put("agent_id", agent_id)}
    else
      _ -> raise ArgumentError, "malformed native child call"
    end
  end

  defp call_name(%{"task_name" => name}, _tasks) when is_binary(name) and name != "",
    do: {:ok, name}

  # Without `task_name` the call must name exactly one requested task and must
  # point at that task's own fixture file only.
  defp call_name(%{"message" => message}, tasks) when is_binary(message) do
    with [_, name] <- Regex.run(~r/\ATask ([A-Za-z0-9_]+):/, message),
         %{} = task <- Enum.find(tasks, &(&1["name"] == name)),
         true <- message =~ "fixture/" <> task["file"],
         true <-
           Enum.all?(tasks, &(&1 == task or not (message =~ "fixture/" <> &1["file"]))) do
      {:ok, name}
    else
      _ -> :error
    end
  end

  defp call_name(_call, _tasks), do: :error

  defp call_fork(%{"fork_turns" => fork}) when is_binary(fork) and fork != "", do: {:ok, fork}
  defp call_fork(%{"fork_context" => false}), do: {:ok, "none"}
  defp call_fork(%{"fork_context" => true}), do: {:ok, "context"}
  defp call_fork(_call), do: :error

  defp spawn_outputs(parent_rows) do
    parent_rows
    |> Enum.flat_map(fn
      %{
        "type" => "response_item",
        "payload" => %{"type" => "function_call_output", "call_id" => id, "output" => output}
      }
      when is_binary(id) and is_binary(output) ->
        case Jason.decode(output) do
          {:ok, %{"agent_id" => agent_id} = decoded} when is_binary(agent_id) -> [{id, decoded}]
          _ -> []
        end

      _ ->
        []
    end)
    |> Map.new()
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

  defp owned_children!(sessions, parent_id, tasks, calls) do
    expected = MapSet.new(Enum.map(tasks, & &1["name"]))

    owned =
      Enum.filter(sessions, fn {_id, {_path, meta}} -> meta["parent_thread_id"] == parent_id end)

    by_agent_id =
      for {name, %{"agent_id" => id}} <- calls, is_binary(id), into: %{}, do: {id, name}

    child_name = fn id, meta ->
      case meta["agent_path"] do
        path when is_binary(path) and path != "" -> Path.basename(path)
        _ -> Map.get(by_agent_id, id, "")
      end
    end

    names = Enum.map(owned, fn {id, {_path, meta}} -> child_name.(id, meta) end)

    if MapSet.new(names) != expected or length(names) != length(tasks),
      do: raise(ArgumentError, "missing, duplicate, or unexpected native child session")

    child_ids = MapSet.new(Enum.map(owned, &elem(&1, 0)))

    if Enum.any?(sessions, fn {_id, {_path, meta}} ->
         MapSet.member?(child_ids, meta["parent_thread_id"])
       end),
       do: raise(ArgumentError, "native helper spawned an unexpected descendant")

    Map.new(owned, fn {id, {_path, meta} = value} -> {child_name.(id, meta), {id, value}} end)
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
