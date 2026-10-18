defmodule Kogen.Readiness do
  @moduledoc """
  Whether an Intent is ready to build (SHP-8), run after shaping and at approval unless a card
  already passed for the same baseline hash and HEAD: the SHP-5 rules, the model checks (VER-5)
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
      r = Bridge.exec(cmd, root)

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

  @doc "Whether `.kogen/local` records a successful readiness pass for this Intent hash and HEAD."
  def cached?(root, slug, sha, head) do
    case File.read(readiness_path(root, slug)) do
      {:ok, text} ->
        case JSON.decode(text) do
          {:ok, record} when is_map(record) ->
            record["sha256"] == sha and record["head"] == head

          _ ->
            false
        end

      {:error, _} ->
        false
    end
  end

  @doc "Records a successful readiness pass keyed by both the baseline hash and HEAD."
  def record_pass!(root, slug, sha, head) do
    path = readiness_path(root, slug)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(%{"sha256" => sha, "head" => head}) <> "\n")
  end

  defp readiness_path(root, slug),
    do: Path.join(root, ".kogen/local/readiness/#{slug}.json")

  @doc """
  Checks the Intent on disk. Returns `%{intent, model, scenarios}` with each scenario's dry-run
  status, or raises `intent/parse`, `intent/lint` or `intent/not_ready`.
  """
  def check!(root, slug, %Config{} = config) do
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
          for p <- result.problems, String.starts_with?(p, ["report_", "unexpected"]), do: p
      end

    case model_problems ++ dry_problems do
      [] ->
        %{intent: intent, model: model, scenarios: result.scenarios}

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
