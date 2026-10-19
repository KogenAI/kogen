defmodule Kogen.Checks do
  @moduledoc """
  Executed checks (chapter 05): the Intent's acceptance scenarios through the configured
  runner and its Cucumber Messages report (VER-3, VER-4), its Quint model with Kogen's own Node
  and Quint (VER-5), and the project's checks. Every command runs through `kogen` with stdin
  closed and the caller's environment.
  """
  alias Kogen.{Bridge, Error, Gherkin, Intent, Run}

  @doc """
  Runs the acceptance command on the Intent's feature. Returns
  `%{status, output, scenarios: [%{name, line, status, detail}], problems: [line], binding_problems: [line], passed, failed}`;
  `problems` is empty only when every expected scenario passed exactly once and the command exited 0.
  """
  def acceptance(root, %Intent{} = intent, command, report, opts \\ []) do
    Kogen.ShapeEvidence.count("acceptance")
    {:ok, text} = File.read(Path.join(root, Intent.feature(intent.slug)))
    {:ok, expected} = Gherkin.parse(text)
    File.rm(report)
    File.mkdir_p!(Path.dirname(report))
    Run.log(opts[:run], %{"event" => "command", "name" => "acceptance", "command" => command})

    result =
      Bridge.exec(command, root,
        env: [
          {"KOGEN_ACCEPTANCE_FEATURES", Intent.feature(intent.slug)},
          {"KOGEN_ACCEPTANCE_REPORT", report}
        ]
      )

    Run.log(opts[:run], %{
      "event" => "command_result",
      "name" => "acceptance",
      "status" => result.status,
      "output" => Run.cap(result.output)
    })

    account(root, Intent.feature(intent.slug), expected, report, result)
  end

  @doc """
  The VER-4 accounting of one acceptance run: `expected` scenarios (from `Kogen.Gherkin.parse/1`) of
  `feature` against the Cucumber Messages report at `report` and the command's `%{status, output}`.
  `problems` is empty only when every expected scenario passed exactly once in a finished test case.
  `binding_problems` preserves undefined and ambiguous steps independently of scenario status.
  """
  def account(root, feature, expected, report, result) do
    base = %{
      status: result.status,
      output: result.output,
      scenarios: [],
      binding_problems: [],
      passed: 0,
      failed: 0
    }

    case read_report(root, report) do
      {:error, problem} ->
        Map.merge(base, %{
          problems: [
            "#{problem}: the acceptance command exited #{result.status}; its output:\n" <>
              excerpt(result.output)
          ],
          scenarios: Enum.map(expected, &Map.merge(&1, %{status: problem, detail: nil}))
        })

      {:ok, cases} ->
        mine = Enum.filter(cases, &(&1.uri == feature))

        scenarios =
          Enum.map(expected, fn s ->
            case Enum.filter(mine, &(&1.line == s.line)) do
              [] -> Map.merge(s, %{status: "missing", detail: nil})
              [c] -> Map.merge(s, %{status: c.status, detail: c.detail})
              [_ | _] -> Map.merge(s, %{status: "duplicate", detail: nil})
            end
          end)

        unexpected =
          for c <- cases,
              not (c.uri == feature and Enum.any?(expected, &(&1.line == c.line))),
              do: "unexpected: #{c.uri} line #{c.line} (#{c.name})"

        scen_problems =
          for s <- scenarios,
              s.status != "passed",
              do: "#{s.status}: #{s.name} (line #{s.line})" <> detail(s.detail)

        all_passed = scen_problems == [] and unexpected == []

        problems =
          cond do
            not all_passed -> scen_problems ++ unexpected
            result.status != 0 -> ["exit #{result.status} with all scenarios passed"]
            true -> []
          end

        Map.merge(base, %{
          problems: problems,
          binding_problems: Enum.flat_map(cases, & &1.binding_problems) |> Enum.uniq(),
          scenarios: scenarios,
          passed: Enum.count(scenarios, &(&1.status == "passed")),
          failed: Enum.count(scenarios, &(&1.status == "failed"))
        })
    end
  end

  defp detail(nil), do: ""
  defp detail(d), do: "\n" <> d

  # Each test case's feature path, scenario line (the Examples row for outlines), name and
  # final status, from a Cucumber Messages NDJSON report.
  defp read_report(root, report) do
    with {:ok, text} <- File.read(report) |> either("report_missing"),
         {:ok, msgs} <- decode_lines(text) do
      lines =
        for(%{"gherkinDocument" => d} <- msgs, do: ast_lines(d))
        |> Enum.reduce(%{}, &Map.merge(&2, &1))

      pickles = for %{"pickle" => p} <- msgs, into: %{}, do: {p["id"], p}
      cases = for %{"testCase" => c} <- msgs, into: %{}, do: {c["id"], c}
      hooks = for %{"hook" => h} <- msgs, into: %{}, do: {h["id"], h}
      started = for %{"testCaseStarted" => s} <- msgs, into: %{}, do: {s["id"], s["testCaseId"]}

      retried =
        for %{"testCaseFinished" => f} <- msgs,
            f["willBeRetried"],
            into: MapSet.new(),
            do: f["testCaseStartedId"]

      finished =
        for %{"testCaseFinished" => f} <- msgs,
            not f["willBeRetried"],
            into: MapSet.new(),
            do: f["testCaseStartedId"]

      steps =
        for %{"testStepFinished" => f} <- msgs,
            not MapSet.member?(retried, f["testCaseStartedId"]) do
          {f["testCaseStartedId"], f["testStepId"], f["testStepResult"]}
        end

      results =
        Enum.flat_map(started, fn {sid, case_id} ->
          if MapSet.member?(retried, sid) do
            []
          else
            tc = cases[case_id]
            pickle = pickles[tc["pickleId"]]
            mine = for {^sid, step_id, r} <- steps, do: {step_id, r}

            complete =
              MapSet.member?(finished, sid) and
                Enum.all?(tc["testSteps"], &List.keymember?(mine, &1["id"], 0))

            # A case counts only when it finished and every one of its steps reported a result.
            {status, detail} =
              if complete,
                do: case_status(tc, pickle, mine, lines, hooks),
                else: {"report_invalid", "the report does not finish this scenario"}

            uri = pickle["uri"] |> Path.expand(root) |> Path.relative_to(root)

            [
              %{
                uri: uri,
                line: lines[List.last(pickle["astNodeIds"])][:line],
                name: pickle["name"],
                status: status,
                detail: detail,
                binding_problems: binding_problems(tc, pickle, mine, lines)
              }
            ]
          end
        end)

      {:ok, results}
    else
      {:error, p} -> {:error, p}
    end
  rescue
    _ -> {:error, "report_invalid"}
  end

  defp either({:ok, v}, _), do: {:ok, v}
  defp either(_, problem), do: {:error, problem}

  defp decode_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case JSON.decode(line) do
        {:ok, m} when is_map(m) -> {:cont, {:ok, [m | acc]}}
        _ -> {:halt, {:error, "report_invalid"}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "report_invalid"}
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  # AST node id → %{line, keyword} for scenarios, Examples rows and steps.
  defp ast_lines(doc) do
    walk = fn walk, children ->
      Enum.flat_map(children || [], fn ch ->
        node = ch["scenario"] || ch["background"]

        cond do
          r = ch["rule"] ->
            walk.(walk, r["children"])

          node ->
            rows =
              for ex <- node["examples"] || [],
                  row <- ex["tableBody"] || [],
                  do: {row["id"], %{line: row["location"]["line"]}}

            steps =
              for st <- node["steps"] || [],
                  do: {st["id"], %{line: st["location"]["line"], keyword: st["keyword"]}}

            [{node["id"], %{line: node["location"]["line"]}} | rows ++ steps]

          true ->
            []
        end
      end)
    end

    doc |> get_in(["feature", "children"]) |> then(&walk.(walk, &1)) |> Map.new()
  end

  @order ~w(UNKNOWN PASSED SKIPPED PENDING UNDEFINED AMBIGUOUS FAILED)

  defp case_status(tc, pickle, results, lines, hooks) do
    worst =
      results
      |> Enum.map(fn {_, r} -> r["status"] end)
      |> Enum.max_by(&Enum.find_index(@order, fn s -> s == &1 end), fn -> "UNKNOWN" end)

    bad = Enum.find(results, fn {_, r} -> r["status"] == worst end)

    detail =
      case {worst, bad} do
        {"PASSED", _} -> nil
        {_, nil} -> nil
        {_, {step_id, r}} -> step_detail(tc, pickle, step_id, r, lines, hooks)
      end

    {String.downcase(worst), detail}
  end

  defp step_detail(tc, pickle, step_id, result, lines, hooks \\ %{}) do
    step = Enum.find(tc["testSteps"], &(&1["id"] == step_id)) || %{}
    pickle_step_id = step["pickleStepId"]

    pstep = Enum.find(pickle["steps"] || [], &(&1["id"] == pickle_step_id))

    where =
      case pstep && lines[hd(pstep["astNodeIds"])] do
        %{line: line, keyword: kw} ->
          "acceptance.feature line #{line}: #{String.trim(kw)} #{pstep["text"]}"

        _ ->
          case hooks[step["hookId"]] do
            %{"sourceReference" => %{"uri" => uri, "location" => %{"line" => line}}} ->
              "a hook at #{uri} line #{line}"

            _ ->
              "a hook (location not reported)"
          end
      end

    msg = result["message"] || get_in(result, ["exception", "message"]) || ""
    msg_lines = String.split(msg, "\n")
    msg = Enum.take(msg_lines, 20) |> Enum.join("\n")

    msg =
      if length(msg_lines) > 20,
        do: msg <> "\n[... #{length(msg_lines) - 20} lines omitted ...]",
        else: msg

    String.trim_trailing(where <> "\n" <> msg) |> Kogen.Tools.cut()
  end

  # Binding evidence must survive a failed assertion in the same scenario. Ordinary skipped
  # steps after that assertion are allowed at readiness; missing or ambiguous bindings are not.
  defp binding_problems(tc, pickle, results, lines) do
    for {step_id, r} <- results, r["status"] in ["UNDEFINED", "AMBIGUOUS"], uniq: true do
      [where | _] = String.split(step_detail(tc, pickle, step_id, r, lines), "\n")

      String.replace(
        where,
        ~r/^(acceptance\.feature line \d+): /,
        "\\1: #{String.downcase(r["status"])} step: "
      )
    end
  end

  # ---- Quint (VER-5) ----

  @doc "Kogen's own Node and Quint, as recorded at install (INS-4, LOOP-12)."
  def quint_paths do
    root = Kogen.caller().install_root

    node =
      root
      |> Path.join("node-path")
      |> File.read()
      |> case do
        {:ok, p} -> String.trim(p)
        _ -> Path.join(root, "node-path")
      end

    {node, Path.join(root, "lib/quint/node_modules/@informalsystems/quint/dist/src/cli.js")}
  end

  def require_quint! do
    {node, quint} = quint_paths()

    if not File.regular?(node),
      do:
        Error.raise!(
          "environment",
          "tool_missing",
          "node is not available at #{node}; reinstall Kogen",
          3
        )

    if not File.regular?(quint),
      do:
        Error.raise!(
          "environment",
          "tool_missing",
          "quint is not available at #{quint}; reinstall Kogen",
          3
        )
  end

  @doc "typecheck, test (when tests exist) and one run per invariant. Returns `{:ok, []} | {:failed, problems}`."
  def model(root, model, opts \\ []) do
    {node, quint} = quint_paths()
    q = fn args -> Enum.map_join([node, quint | args], " ", &Kogen.Init.shell_quote/1) end
    has_tests = Regex.match?(~r/\brun\s+\w*Test\b/, File.read!(Path.join(root, model.path)))

    steps =
      [{["typecheck", model.path], "typecheck"}] ++
        if(has_tests,
          do: [{["test", model.path, "--backend", "typescript", "--match", "Test"], "test"}],
          else: []
        ) ++
        for inv <- model.invariants do
          {[
             "run",
             model.path,
             "--backend",
             "typescript",
             "--invariant",
             inv,
             "--seed",
             model.seed,
             "--max-samples",
             model.samples,
             "--max-steps",
             model.steps
           ], {:invariant, inv}}
        end

    problems =
      Enum.flat_map(steps, fn {args, what} ->
        Run.log(opts[:run], %{
          "event" => "command",
          "name" => "model",
          "command" => Enum.join(["quint" | args], " "),
          "node" => node
        })

        Kogen.ShapeEvidence.count("quint")
        r = Bridge.exec(q.(args), root)

        Run.log(opts[:run], %{
          "event" => "command_result",
          "name" => "model",
          "status" => r.status,
          "output" => Run.cap(r.output)
        })

        cond do
          r.status == 0 ->
            []

          match?({:invariant, _}, what) and r.output =~ "[violation]" ->
            [
              "model.qnt: invariant #{elem(what, 1)} violated (seed #{model.seed})\n" <>
                excerpt(r.output)
            ]

          true ->
            [
              "model.qnt: quint #{if is_tuple(what), do: "run", else: what} failed (status #{r.status})\n" <>
                excerpt(r.output)
            ]
        end
      end)

    if problems == [], do: {:ok, []}, else: {:failed, problems}
  end

  @doc """
  Command output for feedback that keeps both ends: Quint names its error at the start and its
  location and summary at the end. Up to 60 lines whole, else the first 30 and the last 20.
  """
  def excerpt(output) do
    lines = output |> String.trim_trailing() |> String.split("\n")

    if length(lines) <= 60,
      do: Enum.join(lines, "\n"),
      else:
        Enum.join(
          Enum.take(lines, 30) ++
            ["[... #{length(lines) - 50} lines omitted ...]"] ++ Enum.take(lines, -20),
          "\n"
        )
  end

  @doc "The last `n` lines of command output."
  def tail(output, n),
    do: output |> String.trim_trailing() |> String.split("\n") |> Enum.take(-n) |> Enum.join("\n")
end
