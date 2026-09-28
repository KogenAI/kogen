defmodule Kogen.ShapingAudit do
  @moduledoc """
  The Shaping audit: deterministic checks, Jev and a blind auditor over one
  Draft revision, bound to `HEAD` and the route. Reports live under
  `.kogen/runtime/shaping-audits/<slug>/` and are never approval.

  `main/2` is the entry function for `mix kogen.audit`; `audit/2` runs one
  audit end to end and writes its report. Neither ever touches anything
  under `.kogen/intents/`.
  """
  use Boundary,
    deps: [
      Kogen.Intent,
      Kogen.Harness,
      Kogen.Jev,
      Kogen.Build,
      Kogen.VerificationPolicy,
      Kogen.Git
    ]

  alias Kogen.ShapingAudit.{
    Auditor,
    Deterministic,
    Finding,
    JevLayer,
    Materialization,
    Package,
    Questions,
    Report,
    StopHook
  }

  @refused_roles ~w(developer reviewer expert auditor)
  @lock_path ".kogen/build.lock"
  @config_path ".kogen/config.yaml"

  @doc """
  The entry function for `mix kogen.audit`. Returns the process exit code:
  `0` ready, `1` not ready (including `asking`), `2` on a usage error, a
  refused role, a present `.kogen/build.lock`, or an ambiguous/missing slug.

  `opts` (all optional): `:root` (default `File.cwd!()`), `:env` (default
  `System.get_env()`), `:read` (recording read function, default
  `&File.read/1`), `:clock` (default `fn -> DateTime.utc_now() end`),
  `:io` (`%{puts: fun, err: fun}`, default `IO.puts/1`), `:stdin` (the
  `--stop-hook` Stop payload, default standard input).
  """
  @spec main([String.t()], keyword()) :: 0 | 1 | 2
  def main(args, opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    env = normalize_env(Keyword.get(opts, :env, System.get_env()))
    io = Keyword.get(opts, :io, default_io())

    case parse_args(args) do
      {:stop_hook} ->
        StopHook.run(root, env, opts)
        0

      {:ok, mode, route, auditor?, slug} ->
        run_command(root, env, io, opts, mode, route, auditor?, slug)

      :usage ->
        io.err.(usage())
        2
    end
  end

  defp usage do
    "usage: mix kogen.audit [--route <name>] [--auditor] <slug> | " <>
      "mix kogen.audit --status [--route <name>] <slug> | mix kogen.audit --stop-hook"
  end

  defp default_io, do: %{puts: &IO.puts/1, err: fn msg -> IO.puts(:stderr, msg) end}

  defp normalize_env(env) when is_map(env), do: env
  defp normalize_env(env) when is_list(env), do: Map.new(env)
  defp normalize_env(_env), do: %{}

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [route: :string, auditor: :boolean, status: :boolean, stop_hook: :boolean]
         ) do
      {[stop_hook: true], [], []} -> {:stop_hook}
      {opts, [slug], []} when slug != "" -> parse_with_slug(opts, slug)
      _usage -> :usage
    end
  end

  defp parse_with_slug(opts, slug) do
    route = Keyword.get(opts, :route)
    auditor? = Keyword.get(opts, :auditor, false)
    status? = Keyword.get(opts, :status, false)

    cond do
      Keyword.get(opts, :stop_hook, false) -> :usage
      status? and auditor? -> :usage
      status? -> {:ok, :status, route, false, slug}
      true -> {:ok, :audit, route, auditor?, slug}
    end
  end

  defp run_command(root, env, io, opts, mode, route, auditor?, slug) do
    role = Map.get(env, "KOGEN_ROLE")

    cond do
      role in @refused_roles ->
        io.err.("mix kogen.audit refuses role #{inspect(role)}")
        2

      File.exists?(Path.join(root, @lock_path)) ->
        io.err.("mix kogen.audit refuses to run while #{@lock_path} is present")
        2

      role == "shaper" and blank?(Map.get(env, "KOGEN_SHAPING_HOOK_OUTPUT")) ->
        shaping_session_status(root, io, slug)

      mode == :status ->
        run_status(root, env, io, opts, route, slug)

      true ->
        run_audit(root, env, io, opts, route, auditor?, slug)
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp shaping_session_status(root, io, slug) do
    io.puts.(
      "Inside a Shaping session the Stop hook audits the Draft at every stop: end your turn to re-audit"
    )

    with {:ok, revision} <- Report.latest_revision(root, slug),
         {:ok, report} <- Report.read(root, slug, revision) do
      io.puts.("last hook report: #{report["readiness"]} (revision #{revision})")
      if report["readiness"] == "ready", do: 0, else: 1
    else
      {:error, :missing} ->
        io.puts.("last hook report: missing")
        1
    end
  end

  defp run_status(root, _env, io, opts, route, slug) do
    with {:ok, package_rel} <- Package.locate(root, slug),
         read = Keyword.get(opts, :read, &File.read/1),
         {:ok, %{files: _files, revision: revision}} <- Package.load(root, package_rel, read),
         {:ok, head} <- Kogen.Git.head_sha(root),
         {:ok, config} <- Kogen.Intent.read_config(Path.join(root, @config_path), route) do
      status = Report.status(root, slug, revision, head, config.route)
      print_status(io, status)
      exit_code_for_status(root, slug, revision, status)
    else
      {:error, reason} -> report_error(io, reason)
    end
  end

  defp print_status(io, :current), do: io.puts.("current")
  defp print_status(io, {:stale, changed}), do: io.puts.("stale: #{Enum.join(changed, ", ")}")
  defp print_status(io, :missing), do: io.puts.("missing")

  defp exit_code_for_status(_root, _slug, _revision, :missing), do: 1
  defp exit_code_for_status(_root, _slug, _revision, {:stale, _changed}), do: 1

  defp exit_code_for_status(root, slug, revision, :current) do
    case Report.read(root, slug, revision) do
      {:ok, %{"readiness" => "ready"}} -> 0
      _other -> 1
    end
  end

  defp run_audit(root, env, io, opts, route, auditor?, slug) do
    case audit(root, %{slug: slug, route: route, auditor: auditor?, env: env, opts: opts}) do
      {:ok, report, _path} ->
        io.puts.("#{report["readiness"]}: #{report["revision"]}")
        if report["readiness"] == "ready", do: 0, else: 1

      {:error, reason} ->
        report_error(io, reason)
    end
  end

  defp report_error(io, {:ambiguous, message}) do
    io.err.(error_text({:ambiguous, message}))
    2
  end

  defp report_error(io, {:not_found, message}) do
    io.err.(error_text({:not_found, message}))
    2
  end

  defp report_error(io, {:non_regular, path}) do
    io.err.(error_text({:non_regular, path}))
    2
  end

  defp report_error(io, reason) do
    io.err.(error_text(reason))
    2
  end

  @doc false
  def error_text({:ambiguous, message}), do: message
  def error_text({:not_found, message}), do: message
  def error_text({:non_regular, path}), do: "refusing non-regular package entry: #{path}"
  def error_text(reason), do: "mix kogen.audit failed: #{inspect(reason)}"

  @doc """
  Runs one audit end to end: locates the package, walks it under `lstat`,
  materializes `HEAD` plus the package, runs the deterministic, auditor and
  Jev layers, applies `questions.md` dispositions, computes readiness, and
  writes `report.json`/`report.md`. The materialization is always removed.

  `params`: `:slug`, `:route` (name or `nil` for the default route),
  `:auditor` (bool, `--auditor`/hook `launch?`), `:env`, `:opts` (`:read`,
  `:jev_deadline_ms`).
  """
  @spec audit(Path.t(), map()) :: {:ok, map(), Path.t()} | {:error, term()}
  def audit(root, params) do
    slug = Map.fetch!(params, :slug)
    route = Map.get(params, :route)
    auditor? = Map.get(params, :auditor, false)
    env = normalize_env(Map.get(params, :env, System.get_env()))
    opts = Map.get(params, :opts, [])
    read = Keyword.get(opts, :read, &File.read/1)

    with {:ok, package_rel} <- Package.locate(root, slug),
         {:ok, %{files: files, revision: revision}} <- Package.load(root, package_rel, read),
         {:ok, head} <- Kogen.Git.head_sha(root),
         {:ok, config} <- Kogen.Intent.read_config(Path.join(root, @config_path), route) do
      base = %{
        root: root,
        slug: slug,
        package_rel: package_rel,
        files: files,
        revision: revision,
        head: head,
        config: config,
        env: env,
        opts: opts
      }

      run_with_materialization(base, auditor?)
    end
  end

  defp run_with_materialization(base, auditor?) do
    case Materialization.create(base.root, base.package_rel, base.files) do
      {:ok, materialization} ->
        try do
          ctx = build_ctx(base, materialization)
          {report, path} = run_layers_and_write(ctx, auditor?, base.opts)
          {:ok, report, path}
        after
          Materialization.remove(materialization)
        end

      {:error, reason} ->
        {:error, {:materialization, reason}}
    end
  end

  defp build_ctx(base, materialization) do
    files = base.files
    questions = Questions.parse(Map.get(files, "questions.md"))
    state = Questions.state(questions)

    %{
      root: base.root,
      slug: base.slug,
      package_rel: base.package_rel,
      materialization: materialization.dir,
      files: files,
      intent: parse_yaml(Map.get(files, "intent.yaml")),
      scenarios: parse_yaml(Map.get(files, "scenarios.yaml")),
      questions: questions,
      state: state,
      head: base.head,
      revision: base.revision,
      route: base.config.route,
      config: base.config,
      env: base.env,
      opts: base.opts
    }
  end

  defp parse_yaml(nil), do: nil

  defp parse_yaml(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, data} -> data
      {:error, _reason} -> nil
    end
  end

  defp run_layers_and_write(ctx, auditor?, opts) do
    {deterministic, det_findings} =
      if ctx.state == :asking do
        findings = Questions.findings(ctx.questions, ctx.files)

        {%{
           "status" => "skipped",
           "reason" => "asking the Shaper: only the question checks run",
           "findings" => findings
         }, findings}
      else
        layer = Deterministic.run(ctx)

        findings =
          ((layer["findings"] || []) ++
             Questions.findings(ctx.questions, ctx.files))
          |> Finding.apply_dispositions(ctx.questions.dispositions)

        {Map.put(layer, "findings", findings), findings}
      end

    read = Keyword.get(opts, :read, &File.read/1)
    prior_failures = Deterministic.prior_failures(ctx.root, intent_id(ctx), read)

    auditor =
      Auditor.run(ctx, det_findings,
        launch?: auditor?,
        prior_failures: prior_failures
      )

    auditor_findings =
      (auditor["findings"] || [])
      |> Finding.apply_dispositions(ctx.questions.dispositions)

    jev = JevLayer.run(ctx, det_findings ++ auditor_findings)
    routed_auditor = Map.get(jev, "routed_findings", auditor_findings)
    jev_findings = jev["findings"] || []

    all_findings = det_findings ++ routed_auditor ++ jev_findings

    jev = normalize_jev_layer(jev)

    layer_reports = %{
      "deterministic" => Map.delete(deterministic, "findings"),
      "jev" => jev,
      "auditor" => auditor
    }

    readiness = readiness(ctx.state, all_findings, layer_reports, auditor?)

    report =
      %{
        "slug" => ctx.slug,
        "package" => ctx.package_rel,
        "revision" => ctx.revision,
        "head" => ctx.head,
        "route" => ctx.route,
        "state" => to_string(ctx.state),
        "readiness" => readiness,
        "layers" => layer_reports,
        "findings" => all_findings,
        "not_audited_by_auditor" => Map.get(auditor, "not_audited", []),
        "questions" => questions_summary(ctx.questions)
      }
      |> maybe_put_elapsed(opts)

    {:ok, path} = Report.write(ctx.root, ctx.slug, report)
    {report, path}
  end

  defp normalize_jev_layer(layer) do
    requests = layer["requests"] || []
    answers = layer["answers"] || []
    request_list = Enum.sort(Enum.uniq(List.flatten(requests)))

    answer_map =
      if is_map(answers) do
        answers
      else
        request_list
        |> Enum.zip(List.flatten(answers))
        |> Map.new(fn {digest, answer} -> {digest, answer} end)
      end

    layer |> Map.put("requests", request_list) |> Map.put("answers", answer_map)
  end

  # The entries the presented summary shows: every assumption and every
  # item left undecided, with its recommendation.
  defp questions_summary(questions) do
    sections =
      Map.new(["Assumed", "Left undecided"], fn name ->
        entries =
          for entry <- Questions.entries(questions, name) do
            %{
              "number" => entry.number,
              "title" => entry.title,
              "text" => entry.text,
              "recommendation" => entry.fields["Recommendation"]
            }
          end

        {name, entries}
      end)

    %{"sections" => sections}
  end

  defp maybe_put_elapsed(report, opts) do
    case Keyword.get(opts, :elapsed) do
      nil -> report
      elapsed -> Map.put(report, "elapsed", elapsed)
    end
  end

  defp intent_id(%{intent: %{"id" => id}}), do: id
  defp intent_id(_ctx), do: nil

  defp readiness(:asking, _findings, _layers, _auditor?), do: "asking"

  defp readiness(:autonomous, findings, layer_reports, _auditor?) do
    open_blocking? = Enum.any?(findings, &Finding.open_blocking?/1)

    all_ok? =
      layer_reports
      |> Enum.all?(fn {_name, layer} -> layer["status"] == "ok" end)

    if not open_blocking? and all_ok?, do: "ready", else: "not_ready"
  end
end
