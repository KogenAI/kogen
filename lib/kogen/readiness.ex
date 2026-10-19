defmodule Kogen.Readiness do
  @moduledoc """
  Whether an Intent is ready to build (SHP-8), run after shaping and reused at approval when complete successful evidence
  already exists for the same baseline hash and HEAD: the SHP-5 rules, the model checks (VER-5)
  and a dry run of `commands.setup` and the acceptance command that must account for every
  scenario exactly once as passed or failed.
  Also the start checks shared with Builds: tools on PATH (LOOP-12) and setup (AUT-5).
  """
  alias Kogen.{Bridge, Checks, Config, Error, Git, Intent, Run}

  @doc """
  Refuses when git or /bin/sh is missing, or with `configured: true` (a Build, after setup)
  the program of a configured command (LOOP-12): leading `NAME=value` words are skipped and the
  next word is looked up with `command -v` in the repository root. The generated runner's
  `"$KOGEN_NODE"` resolves to the Node recorded by the installed command.
  """
  def tools!(root, %Config{} = config, configured \\ false) do
    if not File.exists?("/bin/sh"),
      do: Error.raise!("environment", "tool_missing", "/bin/sh is not available", 3)

    commands = if configured, do: Config.named_commands(config), else: []

    words =
      Enum.flat_map(commands, fn {_name, cmd} ->
        cmd
        |> OptionParser.split()
        |> Enum.drop_while(&Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))
        # A subshell, a group or a negation is the shell's own syntax; the program follows it.
        |> Enum.map(&String.replace(&1, ~r/^[({!]+/, ""))
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(1)
      end)

    for word <- Enum.uniq(["git" | words]) do
      program =
        if word == "$KOGEN_NODE", do: Kogen.caller().env["KOGEN_NODE"] || "", else: word

      {_, status} =
        System.cmd("/bin/sh", ["-c", ~s(command -v "$1" >/dev/null), "sh", program],
          cd: root,
          env: [{"PATH", Kogen.caller().env["PATH"] || ""}]
        )

      if status != 0,
        do: Error.raise!("environment", "tool_missing", "#{word} is not available", 3)
    end

    :ok
  end

  @doc """
  Runs `commands.setup` in order; refuses on the first failure (AUT-5). With `reuse: true`
  (shaping, readiness, the approval card) it is skipped when it last passed for the same checkout
  state (SET-7); a Build always runs it.
  """
  def setup!(root, %Config{setup: setup} = config, run \\ nil, opts \\ []) do
    key = setup_key(root, config)
    stamp = Path.join(root, ".kogen/local/setup.json")

    if opts[:reuse] && File.read(stamp) == {:ok, key} do
      Bridge.progress("kogen: setup already ran for this checkout state")
    else
      run_setup!(root, setup, run)
      File.mkdir_p!(Path.dirname(stamp))
      File.write!(stamp, key)
    end

    :ok
  end

  # The checkout state setup depends on: its commands, HEAD and every change outside the Intent
  # files shaping writes (.kogen/ and the steps folder).
  defp setup_key(root, config) do
    outside =
      ["--", ".", ":(exclude).kogen"] ++
        if(config.steps_dir, do: [":(exclude)#{config.steps_dir}"], else: [])

    {diff, _} = Git.run(root, ["diff", "--binary", "HEAD" | outside])
    {untracked, _} = Git.run(root, ["ls-files", "--others", "--exclude-standard" | outside])

    JSON.encode!(%{
      "setup" => config.setup,
      "head" => Git.head(root),
      "changes" => Base.encode16(:crypto.hash(:sha256, [diff, untracked]), case: :lower)
    })
  end

  defp run_setup!(root, setup, run) do
    for {cmd, i} <- Enum.with_index(setup, 1) do
      Bridge.progress("kogen: running setup-#{i}: #{cmd}")
      Run.log(run, %{"event" => "command", "name" => "setup-#{i}", "command" => cmd})
      Kogen.ShapeEvidence.count("setup")
      r = Kogen.ShapeEvidence.timed("setup", fn -> Bridge.exec(cmd, root) end)

      Run.log(run, %{
        "event" => "command_result",
        "name" => "setup-#{i}",
        "status" => r.status,
        "output" => Run.cap(r.output)
      })

      if r.status != 0 do
        Error.raise!(
          "environment",
          "setup_failed",
          "Setup setup-#{i} failed (status=#{r.status}).",
          3,
          String.split(Checks.tail(r.output, 20), "\n")
        )
      end
    end

    :ok
  end

  @doc "Loads complete successful evidence for the current full baseline and HEAD, or returns nil."
  def cached(root, slug, config) do
    {baseline, sha, head} = inputs(root, slug, config)

    with {:ok, text} <- File.read(readiness_path(root, slug)),
         {:ok, record} when is_map(record) <- JSON.decode(text),
         true <- record["version"] == 2 and record["outcome"] == "ready",
         true <- is_integer(record["acceptance_exit"]),
         true <- record["sha256"] == sha and record["head"] == head,
         true <- record["baseline"] == baseline,
         {:ok, intent, _} <- Intent.check(root, slug),
         {:ok, feature} <- File.read(Path.join(root, Intent.feature(slug))),
         {:ok, expected} <- Kogen.Gherkin.parse(feature),
         true <- record["title"] == intent.title,
         true <- record["model"] == json(Intent.model(intent)),
         true <-
           record["model_outcome"] ==
             if(Intent.model(intent) == :none, do: "not_applicable", else: "passed"),
         scenarios when is_list(scenarios) <- record["scenarios"],
         true <- length(scenarios) == length(expected),
         true <-
           Enum.zip(expected, scenarios)
           |> Enum.all?(fn {e, s} ->
             is_map(s) and s["status"] in ["passed", "failed"] and
               Map.drop(s, ["status", "detail"]) == json(e) and Map.has_key?(s, "detail") and
               (is_nil(s["detail"]) or is_binary(s["detail"]))
           end),
         true <-
           Enum.any?(scenarios, &(&1["status"] == "failed")) or record["acceptance_exit"] == 0 do
      checked =
        Enum.zip_with(expected, scenarios, fn e, s ->
          Map.merge(e, %{status: s["status"], detail: s["detail"]})
        end)

      %{
        intent: intent,
        model: Intent.model(intent),
        scenarios: checked,
        acceptance_exit: record["acceptance_exit"],
        baseline: baseline,
        sha256: sha,
        head: head
      }
    else
      _ -> nil
    end
  end

  defp json(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp inputs(root, slug, config) do
    baseline = Intent.baseline(root, slug, config)
    {baseline, Intent.hash(root, baseline), Git.head(root)}
  end

  @doc "Whether the complete checked baseline and HEAD still identify this readiness result."
  def current?(root, slug, config, ready) when is_map(ready),
    do: inputs(root, slug, config) == {ready.baseline, ready.sha256, ready.head}

  def current?(_root, _slug, _config, _ready), do: false

  def failures?(ready), do: Enum.any?(ready.scenarios, &(&1.status == "failed"))

  @doc "The same bounded, actual failed-baseline observations for the model and approval card."
  def observations(slug, ready, reference \\ nil) do
    if failures?(ready) do
      reference = reference || ".kogen/local/readiness/#{slug}.json"

      details =
        ready.scenarios
        |> Enum.filter(&(&1.status == "failed"))
        |> Enum.map_join("\n\n", fn s ->
          "Scenario: #{s.name} (acceptance.feature line #{s.line})\n" <>
            (s.detail || "The runner supplied no failure detail.")
        end)

      ("Readiness observations\n" <>
         "Checked baseline: #{ready.sha256}\nHEAD: #{ready.head}\n" <>
         "Acceptance exit: #{ready.acceptance_exit}\nEvidence: #{reference}\n" <>
         details)
      |> Kogen.Tools.cut()
    else
      ""
    end
  end

  def acknowledgment(slug, ready, reference \\ nil) do
    ("Inspect whether fixtures, inputs and commands reached the intended behavior, using the existing read/probe tools when needed. Repair demonstrated contract defects. Ordinary missing-feature red is valid: resubmit the unchanged complete candidate to acknowledge these observations without rerunning unchanged readiness. A failure can mask later cases; this is not proof that every fixture is correct.\n\n" <>
       observations(slug, ready, reference))
    |> Kogen.Tools.cut()
  end

  @doc "Publishes the original successful evidence only when the complete checked inputs still match."
  def record_pass!(root, slug, config, ready) do
    unless inputs(root, slug, config) == {ready.baseline, ready.sha256, ready.head},
      do:
        Error.raise!("intent", "not_ready", "the Intent is not ready to build", 1, [
          "readiness inputs changed during checking or publication"
        ])

    path = readiness_path(root, slug)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 2,
        "outcome" => "ready",
        "sha256" => ready.sha256,
        "head" => ready.head,
        "baseline" => ready.baseline,
        "title" => ready.intent.title,
        "model" => ready.model,
        "model_outcome" => if(ready.model == :none, do: "not_applicable", else: "passed"),
        "acceptance_exit" => ready.acceptance_exit,
        "scenarios" => ready.scenarios
      }) <> "\n"
    )
  end

  defp readiness_path(root, slug),
    do: Path.join(root, ".kogen/local/readiness/#{slug}.json")

  @doc """
  Checks the Intent on disk. Returns `%{intent, model, scenarios}` with each scenario's dry-run
  status, or raises `intent/parse`, `intent/lint` or `intent/not_ready`.
  """
  def check!(root, slug, %Config{} = config) do
    File.rm(readiness_path(root, slug))
    {baseline, sha, head} = inputs(root, slug, config)

    intent =
      case Intent.check(root, slug) do
        {:ok, intent, _} ->
          intent

        {:parse, problems} ->
          Error.raise!("intent", "parse", "the Intent cannot be read", 1, problems)

        {:lint, problems} ->
          Error.raise!("intent", "lint", "the Intent needs changes", 1, problems)
      end

    model = Intent.model(intent)

    model_problems =
      case model do
        :none ->
          []

        m ->
          Checks.require_quint!()
          {_, problems} = Checks.model(root, m)
          problems
      end

    setup!(root, config, nil, reuse: true)

    report =
      Kogen.tmp_path("kogen-dry-run") <> ".ndjson"

    result = Checks.acceptance(root, intent, config.acceptance_run, report)
    File.rm(report)

    report_problems = for p <- result.problems, String.starts_with?(p, "report_"), do: p

    dry_problems =
      result.binding_problems ++
        for s <- result.scenarios,
            s.status not in ["passed", "failed", "undefined"],
            do: "#{s.status}: #{s.name} (line #{s.line})"

    dry_problems =
      cond do
        report_problems != [] ->
          report_problems

        dry_problems != [] ->
          dry_problems

        Enum.any?(result.scenarios, &(&1.status == "undefined")) ->
          ["undefined steps in acceptance.feature"]

        true ->
          for p <- result.problems,
              String.starts_with?(p, ["report_", "unexpected", "exit "]) do
            if String.starts_with?(p, "exit "),
              do: p <> "; its output:\n" <> Checks.excerpt(result.output),
              else: p
          end
      end

    case model_problems ++ dry_problems do
      [] ->
        ready = %{
          intent: intent,
          model: model,
          scenarios: result.scenarios,
          acceptance_exit: result.status,
          baseline: baseline,
          sha256: sha,
          head: head
        }

        record_pass!(root, slug, config, ready)
        ready

      problems ->
        Error.raise!(
          "intent",
          "not_ready",
          "the Intent is not ready to build",
          1,
          Enum.flat_map(problems, &String.split(&1, "\n"))
        )
    end
  end

  @doc """
  Runs `command` (an acceptance command) in `dir` on a feature with no scenarios: `:ok` when it
  exits 0 and writes its report, else `{:failed, reason}` (SET-13, SHP-2).
  """
  def runner_check(dir, command) do
    Bridge.progress("kogen: checking the acceptance runner")
    tmp = Kogen.tmp_path("kogen-runner-check")
    File.mkdir_p!(tmp)
    feature = Path.join(tmp, "check.feature")
    report = Path.join(tmp, "report.ndjson")
    File.write!(feature, "Feature: Kogen acceptance runner check\n")

    try do
      r =
        Bridge.exec(command, dir,
          env: [{"KOGEN_ACCEPTANCE_FEATURES", feature}, {"KOGEN_ACCEPTANCE_REPORT", report}]
        )

      cond do
        r.status != 0 -> {:failed, "the runner check failed with status #{r.status}", r.output}
        not File.regular?(report) -> {:failed, "the runner check wrote no report", r.output}
        true -> :ok
      end
    after
      File.rm_rf(tmp)
    end
  end

  @doc "Before the first shaping request: the configured commands exist and the runner starts (SHP-2)."
  def runner!(root, %Config{} = config) do
    tools!(root, config, true)

    case runner_check(root, config.acceptance_run) do
      :ok ->
        :ok

      {:failed, why, output} ->
        Error.raise!(
          "environment",
          "acceptance_unavailable",
          "#{why}; fix commands.acceptance.run in .kogen/project.yaml",
          3,
          output |> Checks.excerpt() |> String.split("\n")
        )
    end
  end
end
