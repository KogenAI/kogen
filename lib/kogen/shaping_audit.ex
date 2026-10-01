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
    exports: [Package, Report, Questions, Deterministic, Finding, HeadlessInput, Lock],
    deps: [
      Kogen.ProcessCustody,
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
    Lock,
    Materialization,
    Package,
    Questions,
    Report,
    StopHook
  }

  @refused_roles ~w(developer reviewer expert auditor)
  @managed_roles ["shaping" | @refused_roles]
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

      {:ok, mode, route, auditor?, confirm?, slug} ->
        run_command(root, env, io, opts, {mode, route, auditor?, confirm?, slug})

      :usage ->
        io.err.(usage())
        2
    end
  end

  defp usage do
    "usage: mix kogen.audit [--route <name>] [--auditor | --confirm] <slug> | " <>
      "mix kogen.audit --status [--route <name>] <slug> | mix kogen.audit --stop-hook"
  end

  defp default_io, do: %{puts: &IO.puts/1, err: fn msg -> IO.puts(:stderr, msg) end}

  defp normalize_env(env) when is_map(env), do: env
  defp normalize_env(env) when is_list(env), do: Map.new(env)
  defp normalize_env(_env), do: %{}

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [
             route: :string,
             auditor: :boolean,
             confirm: :boolean,
             status: :boolean,
             stop_hook: :boolean
           ]
         ) do
      {[stop_hook: true], [], []} -> {:stop_hook}
      {opts, [slug], []} when slug != "" -> parse_with_slug(opts, slug)
      _usage -> :usage
    end
  end

  defp parse_with_slug(opts, slug) do
    route = Keyword.get(opts, :route)
    auditor? = Keyword.get(opts, :auditor, false)
    confirm? = Keyword.get(opts, :confirm, false)
    status? = Keyword.get(opts, :status, false)

    cond do
      Keyword.get(opts, :stop_hook, false) -> :usage
      confirm? and (auditor? or status?) -> :usage
      status? and auditor? -> :usage
      status? -> {:ok, :status, route, false, false, slug}
      true -> {:ok, :audit, route, auditor?, confirm?, slug}
    end
  end

  defp run_command(root, env, io, opts, {mode, route, auditor?, confirm?, slug}) do
    role = Map.get(env, "KOGEN_ROLE")

    cond do
      confirm? and role in @managed_roles ->
        io.err.("mix kogen.audit --confirm refuses managed role #{inspect(role)}")
        2

      role in @refused_roles ->
        io.err.("mix kogen.audit refuses role #{inspect(role)}")
        2

      File.exists?(Path.join(root, @lock_path)) ->
        io.err.("mix kogen.audit refuses to run while #{@lock_path} is present")
        2

      role == "shaping" and blank?(Map.get(env, "KOGEN_SHAPING_HOOK_OUTPUT")) ->
        shaping_session_status(root, io, slug)

      mode == :status ->
        run_status(root, env, io, opts, route, slug)

      true ->
        run_audit(root, env, io, opts, route, auditor?, confirm?, slug)
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

  defp run_audit(root, env, io, opts, route, auditor?, confirm?, slug) do
    case audit(root, %{
           slug: slug,
           route: route,
           auditor: auditor? or confirm?,
           confirm?: confirm?,
           env: env,
           opts: opts
         }) do
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

  def error_text(:confirmation_before_bound),
    do: "mix kogen.audit --confirm requires the exhausted normal auditor budget"

  def error_text(reason), do: "mix kogen.audit failed: #{inspect(reason)}"

  @doc """
  Runs one audit end to end: locates the package, walks it under `lstat`,
  materializes `HEAD` plus the package, runs the deterministic, auditor and
  Jev layers, applies `questions.md` dispositions, computes readiness, and
  writes `report.json`/`report.md`. The materialization is always removed.

  `params`: `:slug`, `:route` (name or `nil` for the default route),
  `:auditor` (bool, `--auditor`/hook `launch?`), `:confirm?` (bool, external
  `--confirm` request), `:env`, `:opts` (`:read`,
  `:jev_deadline_ms`), and

  - `:reuse` (default `false`): when the current revision already has a
    `"scope" => "full"` report for the same `HEAD` and route, return it
    without running any layer;
  - `:scope` (`:full`, the default, or `:checkpoint`): a checkpoint runs only
    the Deterministic layer and the question checks, the auditor in
    reuse-only mode, and no Jev. It is never `ready`, never launches a paid
    auditor and is stored as `checkpoint.json` (see `Report.read_checkpoint/3`),
    never over a full `report.json`.

  Audits of one slug are serialized by
  `.kogen/runtime/shaping-audits/<slug>/audit.lock` (held for the whole run),
  so concurrent audits of one revision run the layers once and the later ones
  reuse.
  """
  @spec audit(Path.t(), map()) :: {:ok, map(), Path.t()} | {:error, term()}
  def audit(root, params) do
    slug = Map.fetch!(params, :slug)

    with {:ok, package_rel} <- Package.locate(root, slug) do
      with_slug_lock(root, slug, fn -> audit_locked(root, slug, package_rel, params) end)
    end
  end

  defp audit_locked(root, slug, package_rel, params) do
    route = Map.get(params, :route)
    auditor? = Map.get(params, :auditor, false)
    scope = Map.get(params, :scope, :full)
    env = normalize_env(Map.get(params, :env, System.get_env()))
    opts = Map.get(params, :opts, [])
    read = Keyword.get(opts, :read, &File.read/1)

    with {:ok, %{files: files, revision: revision}} <- Package.load(root, package_rel, read),
         {:ok, head} <- Kogen.Git.head_sha(root),
         {:ok, config} <- audit_config(root, route, params),
         :ok <-
           confirmation_admission(params, %{
             root: root,
             slug: slug,
             revision: revision,
             head: head,
             route: config.route
           }) do
      case reusable(params, root, slug, revision, head, config.route) do
        {:ok, report, path} ->
          {:ok, report, path}

        :none ->
          base = %{
            root: root,
            slug: slug,
            package_rel: package_rel,
            files: files,
            revision: revision,
            head: head,
            config: config,
            env: env,
            opts: opts,
            scope: scope,
            confirm?: Map.get(params, :confirm?, false) and scope == :full
          }

          run_with_materialization(base, auditor? and scope == :full)
      end
    end
  end

  defp audit_config(_root, route, %{config: %{route: route} = config}), do: {:ok, config}

  defp audit_config(_root, _route, %{config: _}),
    do: {:error, "audit configuration route mismatch"}

  defp audit_config(root, route, _params),
    do: Kogen.Intent.read_config(Path.join(root, @config_path), route)

  defp confirmation_admission(%{confirm?: true} = params, ctx) do
    if Map.get(params, :scope, :full) == :full,
      do: Auditor.confirmation_admission(ctx),
      else: :ok
  end

  defp confirmation_admission(_params, _ctx), do: :ok

  defp reusable(params, root, slug, revision, head, route) do
    with true <- Map.get(params, :reuse, false),
         :current <-
           Report.status(root, slug, revision, head, route, supplied_fingerprint(params)),
         {:ok, %{"scope" => "full"} = report} <- Report.read(root, slug, revision),
         true <- reusable_confirmation?(params, report) do
      {:ok, report, Path.join(Report.dir(root, slug, revision), "report.json")}
    else
      _ -> :none
    end
  end

  defp supplied_fingerprint(%{config: config}), do: Kogen.Intent.config_fingerprint(config)
  defp supplied_fingerprint(_params), do: nil

  defp reusable_confirmation?(%{confirm?: true}, report) do
    report["readiness"] == "ready" and
      get_in(report, ["layers", "auditor", "budget_state", "confirmation_grant"]) == "used"
  end

  defp reusable_confirmation?(_params, _report), do: true

  @lock_poll_ms 200
  @lock_partial_grace_s 2

  defp with_slug_lock(root, slug, fun) do
    directory = Report.runtime_dir(root, slug)
    File.mkdir_p!(directory)
    path = Path.join(directory, "audit.lock")

    case Lock.with_lock(path, 1_800_000, fn ->
           acquire_lock(path)

           try do
             fun.()
           after
             File.rm(path)
           end
         end) do
      {:ok, result} -> result
      {:error, :busy} -> {:error, :audit_busy}
    end
  end

  defp acquire_lock(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        pid = System.pid()

        record = %{
          "pid" => pid,
          "started_at" => Kogen.ProcessCustody.process_start(pid)
        }

        IO.write(io, Jason.encode!(record))
        File.close(io)

      {:error, :eexist} ->
        unless reclaim_stale_lock(path), do: Process.sleep(@lock_poll_ms)
        acquire_lock(path)

      {:error, reason} ->
        raise "cannot take #{path}: #{inspect(reason)}"
    end
  end

  # true when a dead holder's lock was removed.
  defp reclaim_stale_lock(path) do
    with {:ok, bytes} <- File.read(path),
         true <- stale_holder?(path, bytes),
         {:ok, ^bytes} <- File.read(path) do
      File.rm(path) == :ok
    else
      _ -> false
    end
  end

  defp stale_holder?(path, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"pid" => pid, "started_at" => started}} when is_binary(pid) ->
        started == "" or Kogen.ProcessCustody.process_start(pid) != started

      _partial ->
        case File.stat(path, time: :posix) do
          {:ok, %File.Stat{mtime: mtime}} ->
            System.os_time(:second) - mtime > @lock_partial_grace_s

          _ ->
            false
        end
    end
  end

  defp run_with_materialization(base, auditor?) do
    case Materialization.create(base.root, base.package_rel, base.files) do
      {:ok, materialization} ->
        try do
          ctx = build_ctx(base, materialization)
          {report, path} = run_layers_and_write(ctx, auditor?, base.opts, base.confirm?)
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
      opts: base.opts,
      scope: base.scope
    }
  end

  defp parse_yaml(nil), do: nil

  defp parse_yaml(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, data} -> data
      {:error, _reason} -> nil
    end
  end

  defp run_layers_and_write(ctx, auditor?, opts, confirm?) do
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
        launch?: auditor? or confirm?,
        confirm?: confirm?,
        prior_failures: prior_failures
      )

    auditor = apply_previous_dispositions(auditor, ctx.questions)

    auditor_findings =
      (auditor["findings"] || [])
      |> Finding.apply_dispositions(ctx.questions.dispositions)

    {jev, routed_auditor, jev_findings} =
      if ctx.scope == :checkpoint do
        {%{"status" => "skipped", "reason" => "checkpoint scope"}, auditor_findings, []}
      else
        jev = JevLayer.run(ctx, det_findings ++ auditor_findings)

        {normalize_jev_layer(jev), Map.get(jev, "routed_findings", auditor_findings),
         jev["findings"] || []}
      end

    all_findings = det_findings ++ routed_auditor ++ jev_findings

    layer_reports = %{
      "deterministic" => Map.delete(deterministic, "findings"),
      "jev" => jev,
      "auditor" => auditor
    }

    readiness =
      if ctx.scope == :checkpoint,
        do: checkpoint_readiness(ctx.state),
        else: readiness(ctx.state, all_findings, layer_reports, auditor?)

    report =
      %{
        "slug" => ctx.slug,
        "package" => ctx.package_rel,
        "revision" => ctx.revision,
        "head" => ctx.head,
        "route" => ctx.route,
        "config_fingerprint" => Kogen.Intent.config_fingerprint(ctx.config),
        "scope" => to_string(ctx.scope),
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

  defp apply_previous_dispositions(
         %{"previous_audit" => %{"findings" => findings} = previous} = auditor,
         questions
       )
       when is_list(findings) do
    previous =
      Map.put(previous, "findings", Finding.apply_dispositions(findings, questions.dispositions))

    Map.put(auditor, "previous_audit", previous)
  end

  defp apply_previous_dispositions(auditor, _questions), do: auditor

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

  defp checkpoint_readiness(:asking), do: "asking"
  defp checkpoint_readiness(_state), do: "not_ready"

  defp readiness(:asking, _findings, _layers, _auditor?), do: "asking"

  defp readiness(:autonomous, findings, layer_reports, _auditor?) do
    open_blocking? = Enum.any?(findings, &Finding.open_blocking?/1)

    all_ok? =
      layer_reports
      |> Enum.all?(fn {_name, layer} -> layer["status"] == "ok" end)

    if not open_blocking? and all_ok?, do: "ready", else: "not_ready"
  end
end
