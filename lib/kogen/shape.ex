defmodule Kogen.Shape do
  @moduledoc """
  `kogen intent shape <slug> <file|->` (chapter 02): the shaper model turns a request into an
  Intent, or asks numbered UI/UX questions whose answers continue shaping. Nothing is written
  before a valid submission; shaping never approves or builds.
  """
  alias Kogen.{Bridge, ChatGPT, Config, Error, Git, Intent, Readiness, Tools, Usage}

  def run(project, slug, input, input_path \\ nil) do
    root = Git.root!(project)
    config = Config.load!(root)

    if config.acceptance_run == nil or config.steps_dir == nil,
      do:
        Error.raise!(
          "environment",
          "acceptance_unconfigured",
          "set commands.acceptance in .kogen/project.yaml",
          3
        )

    Readiness.tools!(root, config)
    ChatGPT.require_login!()
    state_dir = Path.join(root, ".kogen/local/shaping/#{slug}")
    state = read_state(state_dir)

    if path = untracked_request_path(root, input_path),
      do: Bridge.puts("note: #{path} is untracked; commit or move it before kogen intent build")

    if state == nil and File.exists?(Path.join(root, Intent.dir(slug))) do
      Error.raise!(
        "intent",
        "exists",
        "#{slug} is already shaped; edit its files, or delete .kogen/intents/#{slug}/ and shape again",
        5
      )
    end

    state =
      case state do
        nil -> %{"request" => input, "rounds" => []}
        pending -> answer(pending, input)
      end

    case unanswered(state) do
      [] ->
        if config.checks == [],
          do: Bridge.progress("warning: commands.checks is empty; Builds will not run your tests")

        Readiness.setup!(root, config, nil, reuse: true)
        Readiness.runner!(root, config)
        shape(root, slug, config, state, state_dir, input_path)

      missing ->
        save_state(state_dir, state)
        print_questions(slug, missing)
    end
  end

  # ---- Questions and answers (SHP-6) ----

  defp read_state(dir) do
    case File.read(Path.join(dir, "state.json")) do
      {:ok, text} -> JSON.decode!(text)
      {:error, :enoent} -> nil
    end
  end

  defp save_state(dir, state) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "state.json"), JSON.encode!(state))
  end

  # Merges `<n>: <answer>` lines into the pending round.
  defp answer(state, input) do
    {round, earlier} = List.pop_at(state["rounds"], -1)
    count = length(round["questions"])

    given =
      if String.trim(input) == "all: recommended" do
        recommended_answers!(round)
      else
        parse_answers!(input)
      end

    Enum.each(given, fn {n, answer} ->
      i = String.to_integer(n)

      if i in 1..count and Regex.match?(~r/^[a-z]$/, answer) do
        options = Enum.at(round["questions"], i - 1)["options"] || []

        if :binary.first(answer) - ?a >= length(options),
          do:
            Error.raise!(
              "intent",
              "answer_option_invalid",
              "question #{i} has no option #{answer}",
              2
            )
      end
    end)

    given = Map.filter(given, fn {n, _} -> String.to_integer(n) in 1..count end)
    %{state | "rounds" => earlier ++ [Map.update(round, "answers", given, &Map.merge(&1, given))]}
  end

  defp parse_answers!(input) do
    given =
      for line <- String.split(input, "\n"),
          [_, n, a] <- [Regex.run(~r/^\s*(\d+)\s*:\s*(.*\S)\s*$/, line)],
          into: %{},
          do: {n, String.trim(a)}

    if map_size(given) == 0,
      do:
        Error.raise!(
          "intent",
          "answers_invalid",
          "expected one or more lines as <n>: <letter or your words> (or all: recommended)",
          2
        )

    given
  end

  defp recommended_answers!(round) do
    Enum.with_index(round["questions"], 1)
    |> Enum.reduce(%{}, fn {question, i}, answers ->
      options = question["options"] || []

      case Enum.find_index(options, & &1["recommended"]) do
        nil ->
          Error.raise!("intent", "answers_invalid", "question #{i} has no recommended option", 2)

        option ->
          Map.put(answers, "#{i}", <<?a + option>>)
      end
    end)
  end

  defp unanswered(%{"rounds" => []}), do: []

  defp unanswered(%{"rounds" => rounds}) do
    round = List.last(rounds)
    answers = round["answers"] || %{}

    for {q, i} <- Enum.with_index(round["questions"], 1),
        not Map.has_key?(answers, "#{i}"),
        do: {i, q}
  end

  defp print_questions(slug, numbered) do
    Bridge.puts("Questions for #{slug}:")

    for {i, q} <- numbered do
      Bridge.puts("#{i}. #{q["question"]}")

      for {opt, k} <- Enum.with_index(q["options"] || []) do
        Bridge.puts(
          "   #{<<?a + k>>}) #{opt["label"]}" <>
            if(opt["recommended"], do: " (recommended)", else: "")
        )
      end
    end

    sample =
      Enum.map_join(numbered, "\\n", fn {i, q} ->
        options = q["options"] || []
        option = Enum.find_index(options, & &1["recommended"]) || 0
        answer = if options == [], do: "your words", else: <<?a + option>>
        "#{i}: #{answer}"
      end)

    Bridge.puts(
      "Answer one per line as <n>: <letter or your words>, e.g. printf '#{sample}\\n' | kogen intent shape #{slug} -"
    )

    Bridge.puts("Or enter all: recommended to use every question's recommended option.")
    5
  end

  defp untracked_request_path(_root, nil), do: nil

  defp untracked_request_path(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    relative = Path.relative_to(path, root)

    outside? =
      relative == ".." or String.starts_with?(relative, "../") or Path.type(relative) == :absolute

    if outside? or not File.regular?(path) do
      nil
    else
      case Git.run(root, [
             "status",
             "--porcelain=v1",
             "-z",
             "--untracked-files=all",
             "--",
             ":(literal)#{relative}"
           ]) do
        {status, 0} ->
          if status == "?? #{relative}" <> <<0>>, do: relative

        _ ->
          nil
      end
    end
  end

  defp elapsed_seconds(sh),
    do: div(System.monotonic_time(:millisecond) - sh.started_at, 1_000)

  defp progress(sh, line),
    do: Bridge.progress("#{line} (#{elapsed_seconds(sh)} s)")

  # ---- The shaper conversation ----

  defp shape(root, slug, config, state, state_dir, input_path) do
    role = config.models["shape"]
    t0 = System.monotonic_time(:millisecond)
    tools = Tools.defs(~w(read_file list_files search_text probe)) ++ [submit_def()]
    protected_paths = Intent.protected(root, config)

    input = [
      %{"role" => "user", "content" => context(root, slug, config, state, protected_paths)}
    ]

    sh = %{
      root: root,
      slug: slug,
      config: config,
      role: role,
      tools: tools,
      started_at: t0,
      originals: %{},
      ready: nil
    }

    {result, sh, usage} =
      try do
        converse(sh, input, 0, Usage.zero())
      rescue
        e in Error ->
          if e.class == "provider",
            do: provider_failed(e, slug, input_path),
            else: reraise(e, __STACKTRACE__)
      end

    usage_line =
      "shape #{role.model}/#{role.effort} " <>
        Usage.line(usage) <> " wall_ms=#{System.monotonic_time(:millisecond) - t0}"

    case result do
      {:invalid, problems} when sh.originals != %{} ->
        Error.raise!("intent", "not_ready", "the Intent is not ready to build", 1, problems)

      {:invalid, problems} ->
        Error.raise!(
          "shape",
          "invalid_output",
          "the shaper's output was not a valid Intent after 3 attempts",
          1,
          problems
        )

      {:questions, questions} ->
        save_state(state_dir, %{
          state
          | "rounds" => state["rounds"] ++ [%{"questions" => questions, "answers" => %{}}]
        })

        print_questions(slug, Enum.with_index(questions, 1) |> Enum.map(fn {q, i} -> {i, q} end))

      {:blocked, paths, reason} ->
        print_blocked(paths, reason)

      :ready ->
        Readiness.record_pass!(root, slug, config, sh.ready)
        File.rm_rf!(state_dir)
        new_paths = for {p, :absent} <- sh.originals, do: p
        print_ready(root, slug, sh.ready, new_paths, usage_line)
    end
  end

  defp provider_failed(e, slug, input_path) do
    Bridge.out(Error.render(e))

    retry =
      case input_path do
        nil ->
          "kogen intent shape #{slug} - with the original request on stdin (or the same answers if questions are pending)"

        path ->
          "kogen intent shape #{slug} #{shell_quote(path)} with that request file (or the same answers file if questions are pending)"
      end

    sentence =
      if e.reason in ["login", "usage_limit"],
        do:
          "shaping stopped on a provider error that retrying cannot fix; the failed request wrote no files. Fix the account, then rerun #{retry}.",
        else:
          "shaping stopped on a provider error after its retries; the failed request wrote no files. Rerun #{retry}, or write the Intent yourself."

    raise Error, class: "shape", reason: "provider_failed", detail: sentence, exit: 4
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # The conversation until a valid submission, or 3 invalid ones in a row (SHP-4, SHP-8).
  defp converse(sh, input, invalid, usage) do
    sh = Map.update(sh, :requests, 1, &(&1 + 1))
    Bridge.progress("kogen: shaping (request #{sh.requests}, #{elapsed_seconds(sh)} s)")
    t0 = System.monotonic_time(:millisecond)
    resp = ChatGPT.respond(sh.role, instructions(), input, sh.tools)
    wall = System.monotonic_time(:millisecond) - t0
    progress(sh, "kogen: shape response #{Usage.line(resp.usage)} wall_ms=#{wall}")
    usage = Usage.add(usage, resp.usage)
    calls = for %{"type" => "function_call"} = c <- resp.items, do: c
    input = input ++ (Enum.map(resp.items, &replay_item/1) |> Enum.reject(&is_nil/1))
    ctx = %{root: sh.root, protected: [], tools: ~w(read_file list_files search_text probe)}

    {outputs, result, sh} =
      Enum.reduce(calls, {[], nil, sh}, fn call, {outs, result, sh} ->
        cond do
          result != nil ->
            {outs ++ [output(call, "ignored: only one submit counts per response")], result, sh}

          call["name"] == "submit" ->
            {text, result, sh} = submit(decode(call), sh)
            {outs ++ [output(call, text)], result, sh}

          true ->
            if call["name"] == "probe",
              do: progress(sh, "kogen: probe: #{decode(call)["command"]}")

            tool_result = Tools.run(call["name"], decode(call), ctx)

            if call["name"] == "probe" do
              summary =
                case Regex.run(
                       ~r/\Aexit status: -?\d+\ntimed_out: (?:true|false)\nwall: [\d.]+ s(?:\n|\z)/,
                       tool_result
                     ) do
                  [metadata] -> metadata |> String.trim() |> String.replace("\n", "; ")
                  _ -> "tool error"
                end

              progress(sh, "kogen: probe result: #{summary}")
            end

            {outs ++ [output(call, Tools.cut(tool_result))], nil, sh}
        end
      end)

    input = input ++ outputs

    case result do
      {:invalid, problems} when invalid + 1 >= 3 ->
        {{:invalid, problems}, sh, usage}

      {:invalid, _} ->
        converse(sh, input, invalid + 1, usage)

      :observations ->
        converse(sh, input, invalid, usage)

      {:blocked, paths, reason} ->
        {{:blocked, paths, reason}, sh, usage}

      nil when calls == [] ->
        if invalid + 1 >= 3,
          do: {{:invalid, ["the shaper ended without calling submit"]}, sh, usage},
          else:
            converse(
              sh,
              input ++
                [
                  %{
                    "role" => "user",
                    "content" => "End by calling submit with either questions or files."
                  }
                ],
              invalid + 1,
              usage
            )

      nil ->
        converse(sh, input, invalid, usage)

      done ->
        {done, sh, usage}
    end
  end

  # A submission: questions, files that pass readiness, or a truthful protected-conflict report.
  # Blocked is a report only; it never authorizes an edit or writes submission files.
  defp submit(args, sh) do
    case validate(args, sh.root, sh.slug, sh.config) do
      {:error, problems} ->
        {"invalid submission:\n" <> Enum.join(problems, "\n"), {:invalid, problems}, sh}

      {:ok, {:questions, _} = q} ->
        {"accepted", q, sh}

      {:ok, {:blocked, _paths, _reason} = blocked} ->
        {"blocked: required protected edits reported", blocked, sh}

      {:ok, {:files, files}} ->
        sh = write_attempt(sh, files)
        fix_attempt(sh, Enum.map(files, &elem(&1, 0)))
        progress(sh, "kogen: checking readiness")

        try do
          if Readiness.current?(sh.root, sh.slug, sh.config, sh.ready) do
            {"accepted: unchanged checked observations acknowledged", :ready, sh}
          else
            ready = Readiness.check!(sh.root, sh.slug, sh.config)
            sh = %{sh | ready: ready}

            if Readiness.failures?(ready),
              do: {Readiness.acknowledgment(sh.slug, ready), :observations, sh},
              else: {"accepted: the Intent is ready", :ready, sh}
          end
        rescue
          e in Error ->
            if e.reason in ["not_ready", "parse", "lint"] do
              # Not-ready problems as they are; a lint or parse error with its own first line.
              problems =
                if e.reason == "not_ready", do: e.lines, else: [Error.message(e) | e.lines]

              {"not ready:\n" <> Enum.join(problems, "\n"), {:invalid, problems}, sh}
            else
              reraise e, __STACKTRACE__
            end
        end
    end
  end

  defp write_attempt(sh, files) do
    originals =
      Enum.reduce(files, sh.originals, fn {p, _}, acc ->
        Map.put_new_lazy(acc, p, fn ->
          case File.read(Path.join(sh.root, p)) do
            {:ok, old} -> old
            {:error, _} -> :absent
          end
        end)
      end)

    # Files of an earlier attempt that this one leaves out go back to how they were.
    for {p, orig} <- originals, not List.keymember?(files, p, 0) do
      if orig == :absent,
        do: File.rm(Path.join(sh.root, p)),
        else: File.write!(Path.join(sh.root, p), orig)
    end

    for {p, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(sh.root, p)))
      File.write!(Path.join(sh.root, p), content)
    end

    %{sh | originals: originals}
  end

  # SHP-4: the project's fixers format the attempt's files, so the card, the approval hash and the
  # Build's unchanged-tree checks see them formatted. What the fixers change anywhere else is undone.
  defp fix_attempt(%{config: %{fix: []}}, _paths), do: :ok

  defp fix_attempt(sh, paths) do
    before = Map.new(Git.changed_paths(sh.root), &{&1, File.read(Path.join(sh.root, &1))})

    for {cmd, i} <- Enum.with_index(sh.config.fix, 1) do
      progress(sh, "kogen: running fix-#{i}: #{cmd}")
      Bridge.exec(cmd, sh.root)
    end

    for path <- Git.changed_paths(sh.root), path not in paths do
      file = Path.join(sh.root, path)

      case Map.fetch(before, path) do
        {:ok, {:ok, text}} ->
          if File.read(file) != {:ok, text}, do: File.write!(file, text)

        {:ok, {:error, _}} ->
          File.rm_rf(file)

        :error ->
          if Git.show(sh.root, "HEAD", path),
            do: Git.ok!(sh.root, ["checkout", "HEAD", "--", path]),
            else: File.rm_rf(file)
      end
    end

    :ok
  end

  @doc "An output item sent back on the next request; reasoning items are not kept (store is false)."
  def replay_item(%{"type" => "function_call"} = c),
    do: Map.take(c, ["type", "call_id", "name", "arguments"])

  def replay_item(%{"type" => "message", "content" => content}) do
    text = Enum.map_join(content || [], "", &(&1["text"] || ""))
    if text == "", do: nil, else: %{"role" => "assistant", "content" => text}
  end

  def replay_item(_), do: nil

  def output(call, text),
    do: %{"type" => "function_call_output", "call_id" => call["call_id"], "output" => text}

  def decode(call) do
    case JSON.decode(call["arguments"] || "") do
      {:ok, args} when is_map(args) -> args
      _ -> %{"__invalid__" => true}
    end
  end

  defp submit_def do
    %{
      "type" => "function",
      "name" => "submit",
      "strict" => false,
      "description" =>
        "End shaping with exactly one of questions, ready Intent files, or blocked. A blocked report names required edits to currently protected paths and is never authorization; it cannot be paired with another result.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "questions" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "question" => %{"type" => "string"},
                "options" => %{
                  "type" => "array",
                  "items" => %{
                    "type" => "object",
                    "properties" => %{
                      "label" => %{"type" => "string"},
                      "recommended" => %{"type" => "boolean"}
                    },
                    "required" => ["label"]
                  }
                }
              },
              "required" => ["question"]
            }
          },
          "files" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "path" => %{"type" => "string"},
                "content" => %{"type" => "string"}
              },
              "required" => ["path", "content"]
            }
          },
          "blocked" => %{
            "type" => "object",
            "properties" => %{
              "paths" => %{"type" => "array", "items" => %{"type" => "string"}},
              "reason" => %{"type" => "string"}
            },
            "required" => ["paths", "reason"]
          }
        }
      }
    }
  end

  # SHP-4: questions, or files that make a valid Intent.
  defp validate(%{"blocked" => blocked} = args, root, slug, config)
       when not is_map_key(args, "questions") and not is_map_key(args, "files") do
    paths = if is_map(blocked), do: blocked["paths"], else: nil
    reason = if is_map(blocked), do: blocked["reason"], else: nil

    problems =
      cond do
        not is_list(paths) or paths == [] ->
          ["blocked.paths must be a non-empty list"]

        not Enum.all?(paths, &(is_binary(&1) and String.trim(&1) != "")) ->
          ["blocked.paths must contain non-empty paths"]

        true ->
          []
      end ++
        if(is_binary(reason) and String.trim(reason) != "",
          do: [],
          else: ["blocked.reason must be non-empty text"]
        )

    protected = Intent.baseline(root, slug, config)

    problems =
      problems ++
        for path <- if(is_list(paths), do: paths, else: []),
            is_binary(path) and String.trim(path) != "",
            path not in protected,
            do: "blocked path #{path} is not protected by the current contract"

    if problems == [], do: {:ok, {:blocked, paths, reason}}, else: {:error, problems}
  end

  defp validate(%{"questions" => [_ | _] = qs} = args, _root, _slug, _config)
       when not is_map_key(args, "files") and not is_map_key(args, "blocked") do
    if Enum.all?(
         qs,
         &(is_map(&1) and is_binary(&1["question"]) and String.trim(&1["question"]) != "" and
             valid_options?(&1))
       ),
       do: {:ok, {:questions, Enum.map(qs, &Map.take(&1, ["question", "options"]))}},
       else:
         {:error,
          [
            "every question needs question text and optional options with string labels and boolean recommended values"
          ]}
  end

  defp validate(%{"files" => [_ | _] = files} = args, root, slug, config)
       when not is_map_key(args, "questions") and not is_map_key(args, "blocked") do
    own = for f <- ~w(intent.md acceptance.feature model.qnt), do: Intent.dir(slug) <> "/" <> f
    steps = config.steps_dir

    path_problems =
      Enum.flat_map(files, fn
        %{"path" => p, "content" => c} when is_binary(p) and is_binary(c) ->
          norm = Path.relative_to(Path.expand(p, "/r"), "/r")

          cond do
            norm != p or String.starts_with?(p, "/") ->
              ["#{p}: paths must be relative and normal"]

            p in own ->
              []

            steps != nil and String.starts_with?(p, steps <> "/") ->
              []

            true ->
              [
                "#{p}: shaping may write only #{Intent.dir(slug)}/{intent.md,acceptance.feature,model.qnt} and step files under #{steps || "commands.acceptance.steps_dir (unset)"}/"
              ]
          end

        _ ->
          ["every file needs a path and a content string"]
      end)

    overlay = for %{"path" => p, "content" => c} <- files, into: %{}, do: {p, c}

    cond do
      path_problems != [] ->
        {:error, path_problems}

      not Map.has_key?(overlay, Intent.intent_md(slug)) or
          not Map.has_key?(overlay, Intent.feature(slug)) ->
        {:error, ["the files must include #{Intent.intent_md(slug)} and #{Intent.feature(slug)}"]}

      true ->
        case Intent.check(root, slug, overlay) do
          {:ok, _, _} -> {:ok, {:files, Enum.sort(Map.to_list(overlay))}}
          {_, problems} -> {:error, problems}
        end
    end
  end

  defp validate(_, _, _, _),
    do:
      {:error,
       [
         "submit takes exactly one of a non-empty questions list, a non-empty files list, or a blocked report"
       ]}

  defp valid_options?(%{"options" => options}) when is_list(options) do
    Enum.all?(options, fn
      %{"label" => label} = option when is_binary(label) ->
        not Map.has_key?(option, "recommended") or is_boolean(option["recommended"])

      _ ->
        false
    end)
  end

  defp valid_options?(question), do: not Map.has_key?(question, "options")

  # ---- Output (SHP-8) ----

  defp print_blocked(paths, reason) do
    Bridge.puts(
      "shape/protected_conflict: required edits touch protected files: #{Enum.join(paths, ", ")}"
    )

    Bridge.puts(reason)

    Bridge.puts(
      "Next: revise the request, or review and commit .kogen/project.yaml outside Build, then shape again; preserve checks and actual check configuration. There is no protected-edit override."
    )

    1
  end

  defp print_ready(root, slug, ready, new_paths, usage_line) do
    steps =
      Intent.step_files(ready.intent)
      |> Enum.map_join(", ", fn p ->
        state =
          cond do
            p in new_paths -> "new"
            Git.changed_paths(root, [p]) != [] -> "edited"
            true -> "unchanged"
          end

        "#{p} (#{state})"
      end)

    failing = Enum.count(ready.scenarios, &(&1.status == "failed"))
    passing = Enum.count(ready.scenarios, &(&1.status == "passed"))
    Bridge.puts("Intent: #{Path.join(root, Intent.intent_md(slug))}")
    Bridge.puts("Acceptance test: #{Path.join(root, Intent.feature(slug))}")
    Bridge.puts("Step files: " <> if(steps == "", do: "none", else: steps))
    Bridge.puts("Model: #{ready.intent.model}")

    Bridge.puts(
      "Scenarios: #{length(ready.scenarios)} (#{failing} fail now, #{passing} pass now)"
    )

    Bridge.puts(usage_line)
    Bridge.puts("Next: kogen intent approve #{slug}")
    0
  end

  # ---- Prompt (SHP-3) ----

  defp context(root, slug, config, state, protected_paths) do
    files = Git.ok!(root, ["ls-files"])
    steps_dir = config.steps_dir
    baseline = Intent.baseline(root, slug, config)

    acceptance_paths =
      if Intent.exists?(root, slug), do: Intent.read(root, slug).acceptance || [], else: []

    automatic_baseline =
      Enum.filter(baseline, fn path ->
        path == Config.path() or path in acceptance_paths or
          String.starts_with?(path, Intent.dir(slug) <> "/")
      end)

    step_files =
      if steps_dir do
        Git.ok!(root, ["ls-files", "--cached", "--others", "--exclude-standard", "--", steps_dir])
        |> String.split("\n", trim: true)
        |> Enum.map_join("\n", fn p ->
          "--- #{p}\n" <> (File.read(Path.join(root, p)) |> elem(1))
        end)
      else
        ""
      end

    rounds =
      Enum.with_index(state["rounds"], 1)
      |> Enum.map_join("\n", fn {r, n} ->
        qa =
          Enum.with_index(r["questions"], 1)
          |> Enum.map_join("\n", fn {q, i} ->
            opts =
              (q["options"] || [])
              |> Enum.with_index()
              |> Enum.map_join("", fn {o, k} -> "\n   #{<<?a + k>>}) #{o["label"]}" end)

            "#{i}. #{q["question"]}#{opts}\n   answer: #{i}: #{r["answers"]["#{i}"]}"
          end)

        "Round #{n}:\n" <> qa
      end)

    """
    # Request

    #{state["request"]}

    #{if rounds != "", do: "# Your earlier questions and the caller's answers (cite them as `(source: answer <n>)` using the numbers of the latest round)\n\n" <> rounds <> "\n", else: ""}
    # The Intent to write

    Slug: #{slug}
    Write `#{Intent.intent_md(slug)}`, `#{Intent.feature(slug)}`, optionally `#{Intent.model_path(slug)}`, and step files under `#{steps_dir || "(commands.acceptance.steps_dir is unset: you cannot add step files)"}/`.

    # Project instructions (README.md)

    #{readme(root)}

    # Testing rules (docs/testing-rules.md)

    #{Kogen.testing_rules()}

    # Configured commands (.kogen/project.yaml)

    setup: #{inspect(config.setup)}
    fix: #{inspect(config.fix)}
    checks: #{Enum.map_join(config.checks, ", ", fn {n, r} -> "#{n}: #{r}" end)}
    acceptance: #{config.acceptance_run}
      (it runs with KOGEN_ACCEPTANCE_FEATURES set to the Intent's feature path and KOGEN_ACCEPTANCE_REPORT to the report path)

    # Protection contract

    configured protect patterns: #{inspect(config.protect)}
    paths currently matched by those patterns: #{inspect(protected_paths)}
    automatic baseline: every file in `#{Intent.dir(slug)}/`, every path listed under the Intent's `Acceptance:` (including step files), and `.kogen/project.yaml`.
    automatic paths currently present or listed: #{inspect(automatic_baseline)}
    Approval freezes this baseline. It is not an exception or authorization to change a protected path. Inspect the implementation edits required to deliver the requested outcome; do not infer a conflict by scanning request prose. If a required protected edit cannot be avoided without changing the requested outcome, submit the exclusive `blocked` report with actual protected paths and a reason. Never submit a ready package conditional on a protected-edit approval mechanism: no such override exists.

    # Existing step files under #{steps_dir}

    #{if step_files == "", do: "(none)", else: step_files}

    # Tracked files

    #{files}
    """
  end

  def readme(root) do
    case File.read(Path.join(root, "README.md")) do
      {:ok, text} -> text
      _ -> "(no README.md)"
    end
  end

  defp instructions do
    """
    You are Kogen's shaper. You turn a feature request for this Git repository into an Intent that another model will implement and that Kogen will verify by running it. You never implement the feature yourself and you cannot edit project files; you submit the Intent's files with the `submit` tool.

    How to shape:
    - Make the requested behavior precise. Existing code and tests are evidence of current behavior, not proof of intended behavior: separate "the code does this now" from "the product should do this". Add only what the request needs: no extra features, settings, abstractions or defensive behavior. If the request replaces existing behavior, say what is changed or removed.
    - The builder receives your Intent, not the original request. Preserve settled non-secret literal inputs (paths, commands, names and values) needed by the requested behavior or required examples. Do not substitute guessed values or refer to facts that exist only in the original request.
    - Ask the caller (submit `questions`) only about material UI/UX choices the request leaves open, each with options (plain text; Kogen letters them) and one marked recommended. Decide technical details yourself. Never ask about things the request or the answers already settle.
    - Read the project with read_file, list_files and search_text before writing. Follow its README and conventions.
    - Use `probe` only to prove a genuinely uncertain assumption the Intent depends on (a library call's behavior, a tool's availability, a command in this project). Most Intents need no probe. A failed probe is a finding: reshape around it, or ask if it is a UI/UX matter.
    - Probes run in a copy of the project outside the repository, so tools that trust folders (mise) may need `mise trust` first.
    - Kogen's own Quint runs in a probe as `"$KOGEN_NODE" "$KOGEN_QUINT" typecheck <file>` (also `test` and `run`): pass the model in the probe's files and check it before you submit.

    The Intent's files:
    1. `intent.md`, exactly in this shape:

    ```markdown
    # <Title: an imperative verb first, at most 50 characters, no final period; it becomes the commit subject>

    Slug: <slug>
    Model: not applicable — <why the change has no meaningful state>
    Acceptance:
    - .kogen/intents/<slug>/acceptance.feature
    - <each step file the feature uses that this Intent adds or edits>

    <Short prose: the outcome and its boundaries, including what existing behavior is replaced or removed.>

    ## Decisions
    - <each UI/UX decision> (source: request)
    - <decided from an answer> (source: answer <n>)

    ## Tests
    - <each behavioral rule the request adds, changes or removes>: <the test to add or update> (<layer>)

    ## Feasibility
    - none
    ```

    In `## Tests`, follow the testing rules below exactly: one line per rule, the layer one of `unit`, `integration`, `scenario`, `regression` or `existing`; or `- none: <reason>` for a change with no executable behavior (copy, documentation).

    When the change has meaningful state, write a Quint model `model.qnt` and use instead:
    `Model: .kogen/intents/<slug>/model.qnt invariants=<Name>[,<Name>...] seed=<n> samples=<n> steps=<n>`
    (Quint 0.33, TypeScript backend; each invariant a `val` in the model; keep it small). In `## Feasibility`, list each probe you ran with what it showed and its result, e.g. `- <finding>. (probe 1: exit 0, 0.1 s)`, or `- none`.
    For direct probes use a Boolean expression, e.g. `quint run model.qnt --backend=typescript --invariant='A and B'`; commas belong only to Intent metadata `invariants=A,B`.
    When the request changes the acceptance runner or a step library, the scenarios exercise it through an independent harness that you list in `Acceptance:`; the files that implement the requested change stay out of `Acceptance:` so the Build can change them.

    2. `acceptance.feature`: Gherkin scenarios that fail now and pass once the feature is implemented. Every scenario needs a Then step; no @skip, @wip, @pending, @manual or @ignore tags. Expected values live in the feature file. Use only step sentences that the existing step files define or that step files you submit define.

    3. Step files under the configured steps folder: step definitions that exercise the real behavior (run the program, call the code or inspect its output). You may add new step files or edit existing ones; the caller reviews them before approving. List every step file the feature relies on in `Acceptance:`, right after the feature.

    Kogen then checks the Intent: the rules above, the model, and a dry run of the acceptance command that must report every scenario exactly once as passed or failed (an undefined, pending or skipped step means not ready). Problems come back to you; fix them and submit again.

    Inspect the required implementation edits, not arbitrary request wording. If a required edit cannot be avoided and touches a path protected by the current contract, end with `submit` containing only `blocked: {paths: ["relative/path"], reason: "why the requested change requires this edit"}`. A blocked report is not authorization, writes no new Intent or approval, and starts no Build. Do not offer conditional readiness or suggest a protected-edit approval. Otherwise submit either `questions` or `files`, not both. If Kogen reports problems with a submission, fix them and submit again. Accounted baseline failures remain valid, but Kogen returns their actual observations before completion: inspect whether fixtures, inputs and commands reached intended behavior, using existing read/probe tools for uncertain assumptions. Repair demonstrated contract defects; otherwise resubmit unchanged to acknowledge legitimate missing-feature red without a second unchanged readiness run. Failures can mask later cases; do not promise all fixtures are correct.
    """
  end
end
