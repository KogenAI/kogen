defmodule Kogen.Codex.Compatibility do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      Kogen.Codex,
      Kogen.Codex.AccountPlugins,
      Kogen.Codex.AccountObservation,
      Kogen.Harness,
      Kogen.Intent,
      Kogen.VerificationPolicy
    ]

  # This is deliberately a small, direct boundary used by update and the live
  # acceptance slice.  It receives a runtime and login scope that have already
  # been selected by the caller: resolving a default, installing, updating, or
  # authenticating here would make candidate verification able to change the
  # state it is meant to assess.

  alias Kogen.Codex.{AccountObservation, AccountPlugins, Environment, ProviderOutcome}

  @type runtime :: %{
          required(String.t()) => String.t()
        }

  @type scope :: %{path: Path.t(), name: :shared | :project}

  # The resume is driven by this fixed rework request. The real Reviewer is
  # proved by the real Build in live-reviewer-rework, never by a scripted
  # stand-in Reviewer here.
  @rework_findings [
    %{
      "description" =>
        "The exact-resume marker and scout helper evidence (resume-rework.txt, helper-environment.json, helper-receipt.txt, helper-context.json, resume-context.json) are missing.",
      "scenario_ids" => ["compatibility-runner"]
    }
  ]

  # Timing policy is owned here, never by Kogen core or configuration. Measured
  # GPT-6 Sol turns without stand-in Reviewers: Developer 72-135 s, resume
  # 56-90 s, whole run 229 s (Shaping probe 2026-09-25). A native turn gets
  # main's unchanged 240 s per-turn limit, passed explicitly here and never
  # raised in Kogen core, config or bounded_exec.py. The whole live test must
  # finish within 15 minutes, so the runner keeps a reserve for test startup,
  # bounded cleanup and evidence emission, and starts its one timed_out rerun
  # only when a typical run still fits.
  @turn_timeout_seconds 240
  @deadline_ms 900_000
  @reserve_ms 60_000
  @typical_attempt_ms 300_000
  @minimum_turn_seconds 30

  @spec run(runtime(), scope(), Kogen.Intent.config()) :: {:ok, Path.t()} | {:error, term()}
  def run(runtime, scope, config),
    do: run(runtime, scope, config, System.monotonic_time(:millisecond) + @deadline_ms)

  defp run(runtime, scope, config, deadline) do
    Kogen.Codex.with_active(runtime, File.cwd!(), fn ->
      run_fixture(runtime, scope, config, deadline)
    end)
  end

  @doc """
  Runs the compatibility fixture under the owner's 15-minute deadline. Only a
  `timed_out` attempt is rerun, once, in a fresh fixture, and only when a
  typical run still fits. Both attempts are kept in a repository-relative
  summary bound by the returned target evidence locator.
  """
  @spec run_bounded(runtime(), scope(), Kogen.Intent.config()) ::
          {:ok | :error, %{summary: Path.t(), locator: map()}}
  def run_bounded(runtime, scope, config) do
    root = File.cwd!()

    attempt = fn _number, deadline ->
      File.cd!(root, fn -> run(runtime, scope, config, deadline) end)
    end

    run_attempts(attempt, root: root)
  end

  @doc false
  def run_attempts(attempt, options) do
    clock = Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end)
    deadline_ms = Keyword.get(options, :deadline_ms, @deadline_ms)
    typical = Keyword.get(options, :typical_attempt_ms, @typical_attempt_ms)
    started = clock.()
    deadline = started + deadline_ms - @reserve_ms
    first = run_attempt(attempt, 1, deadline, clock)

    {attempts, retry} =
      case retry_decision(first, deadline - clock.(), typical) do
        :rerun -> {[first, run_attempt(attempt, 2, deadline, clock)], %{"started" => true}}
        reason -> {[first], %{"started" => false, "reason" => reason}}
      end

    status = if List.last(attempts)["class"] == "passed", do: :ok, else: :error

    summary = %{
      "schema_version" => 1,
      "result" => Atom.to_string(status),
      "elapsed_ms" => clock.() - started,
      "deadline_ms" => deadline_ms,
      "reserve_ms" => @reserve_ms,
      "turn_timeout_seconds" => @turn_timeout_seconds,
      "typical_attempt_ms" => typical,
      "retry" => retry,
      "attempts" => attempts
    }

    {status, write_summary(Keyword.fetch!(options, :root), summary, attempts)}
  end

  defp run_attempt(attempt, number, deadline, clock) do
    started = clock.()
    result = attempt.(number, deadline)
    elapsed = clock.() - started
    evidence = attempt_evidence(result)
    fixture = if evidence, do: Path.join(Path.dirname(evidence), "fixture")

    Map.merge(
      %{
        "number" => number,
        "class" => attempt_class(result),
        "reason" => attempt_reason(result),
        "elapsed_ms" => elapsed,
        "evidence" => evidence,
        "fixture" => fixture
      },
      fixture_receipts(fixture)
    )
  end

  defp retry_decision(%{"class" => "timed_out"}, remaining, typical) when remaining >= typical,
    do: :rerun

  defp retry_decision(%{"class" => "timed_out"}, _remaining, _typical), do: "no_retry_fitted"
  defp retry_decision(%{"class" => "passed"}, _remaining, _typical), do: "passed"
  defp retry_decision(_attempt, _remaining, _typical), do: "not_timed_out"

  defp attempt_class({:ok, _evidence}), do: "passed"

  defp attempt_class({:error, {:compatibility_failed, reason, _evidence}}),
    do: failure_class(reason)

  defp attempt_class({:error, reason}), do: failure_class(reason)

  defp failure_class({:compatibility_turn_timed_out, _function, _reason}), do: "timed_out"

  defp failure_class({:interactive_shaping_failed, _result, %{status: :timed_out}}),
    do: "timed_out"

  defp failure_class(_reason), do: "failed"

  defp attempt_reason({:ok, _evidence}), do: nil
  defp attempt_reason({:error, reason}), do: inspect(reason, limit: 50, printable_limit: 2000)

  defp attempt_evidence({:ok, evidence}) when is_binary(evidence), do: evidence

  defp attempt_evidence({:error, {:compatibility_failed, _reason, evidence}})
       when is_binary(evidence),
       do: evidence

  defp attempt_evidence(_result), do: nil

  # Provider session ids and cleanup come from the bounded wrapper's own
  # receipts and the PTY receipt, never from model output.
  defp fixture_receipts(nil), do: %{"sessions" => [], "cleanup" => %{"ok" => false}}

  defp fixture_receipts(fixture) do
    runtime = Path.join(fixture, ".kogen/runtime")

    sessions =
      runtime
      |> Path.join("process-*.json")
      |> Path.wildcard()
      |> Enum.sort_by(&process_sequence/1)
      |> Enum.map(&session_receipt/1)

    shaping = read_bounded_receipt(Path.join(runtime, "compatibility-shaping.json"))
    shaping_cleanup = if shaping == %{}, do: nil, else: get_in(shaping, ["cleanup", "ok"]) == true
    native_cleanup = Enum.all?(sessions, & &1["cleanup"])

    %{
      "sessions" => sessions,
      "cleanup" => %{
        "ok" => shaping_cleanup != false and native_cleanup,
        "shaping" => shaping_cleanup,
        "native_turns" => native_cleanup
      }
    }
  end

  defp session_receipt(path) do
    receipt = read_bounded_receipt(path)

    %{
      "operation" => path |> Path.basename(".json") |> String.replace(~r/^process-|-\d+$/, ""),
      "session_id" => receipt["native_session_id"],
      "native_exit" => receipt["native_exit"],
      "timed_out" => receipt["timed_out"] == true,
      "cleanup" => get_in(receipt, ["cleanup", "ok"]) == true
    }
  end

  defp process_sequence(path) do
    case Regex.run(~r/-(\d+)\.json$/, path) do
      [_, sequence] -> String.to_integer(sequence)
      _ -> 0
    end
  end

  defp write_summary(root, summary, attempts) do
    directory =
      Path.join(
        ".kogen/runtime/codex-compatibility",
        "run-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, directory))

    copies =
      for %{"number" => number, "evidence" => evidence} <- attempts,
          is_binary(evidence) and File.regular?(evidence) do
        path = Path.join(directory, "attempt-#{number}-evidence.json")
        File.cp!(evidence, Path.join(root, path))
        path
      end

    summary_path = Path.join(directory, "summary.json")
    File.write!(Path.join(root, summary_path), Jason.encode!(summary, pretty: true) <> "\n")

    manifest = %{
      "schema_version" => 1,
      "required_evidence" =>
        Enum.map([summary_path | copies], &%{"path" => &1, "sha256" => file_digest(root, &1)})
    }

    manifest_path = Path.join(directory, "manifest.json")
    File.write!(Path.join(root, manifest_path), Jason.encode!(manifest) <> "\n")

    %{
      summary: summary_path,
      locator: %{"manifest_path" => manifest_path, "sha256" => file_digest(root, manifest_path)}
    }
  end

  defp file_digest(root, path),
    do: Base.encode16(:crypto.hash(:sha256, File.read!(Path.join(root, path))), case: :lower)

  defp run_fixture(runtime, scope, config, deadline) do
    with :ok <- validate_runtime(runtime),
         :ok <- validate_scope(scope),
         :ok <- validate_config(config),
         {:ok, project_root} <- kogen_project_root(),
         {:ok, fixture, evidence, discovery} <- prepare_fixture(project_root, config) do
      result =
        with {:ok, context} <- launch_context(runtime, scope, config, fixture, discovery),
             context = Map.put(context, :runtime_identity, runtime),
             {:ok, receipts} <-
               exercise_in_fixture(context, config, fixture, discovery, deadline),
             do: settle_evidence(receipts)

      retain_result(result, evidence, fixture)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:compatibility_exception, Exception.message(error)}}
  end

  defp exercise_in_fixture(context, config, fixture, discovery, deadline),
    do: File.cd!(fixture, fn -> exercise(context, config, fixture, discovery, deadline) end)

  defp retain_result({:ok, receipts}, evidence, fixture) do
    File.write!(evidence, Jason.encode!(Map.put(receipts, "fixture", fixture)) <> "\n")
    {:ok, evidence}
  end

  defp retain_result({:error, reason}, evidence, fixture),
    do: failed_evidence(evidence, fixture, reason)

  defp retain_result({:error, reason, receipts}, evidence, fixture) do
    File.write!(
      evidence,
      Jason.encode!(
        Map.merge(receipts, %{
          "fixture" => fixture,
          "status" => "failed",
          "reason" => inspect(reason)
        })
      ) <> "\n"
    )

    {:error, {:compatibility_failed, reason, evidence}}
  end

  defp settle_evidence(receipts) do
    case verify_evidence(receipts) do
      :ok -> {:ok, receipts}
      {:error, reason} -> {:error, reason, receipts}
    end
  end

  defp failed_evidence(evidence, fixture, reason) do
    File.write!(
      evidence,
      Jason.encode!(%{"fixture" => fixture, "status" => "failed", "reason" => inspect(reason)}) <>
        "\n"
    )

    {:error, {:compatibility_failed, reason, evidence}}
  end

  # Kogen core settles a Check; this fixture's evidence never asserts one. It
  # asserts only the requirements this Intent keeps: the PreToolUse
  # blocked-gate, hostile discovery, interactive Shaping, the Developer and
  # its exact-session resume, and the scout helper.
  @doc false
  @spec verify_evidence(map()) :: :ok | {:error, term()}
  def verify_evidence(
        %{
          "shaping" => %{"status" => 0, "marker" => true, "cleanup" => true},
          "developer" => %{"session_id" => developer_id},
          "resume" => %{"session_id" => developer_id},
          "discovery_controls" => %{"ok" => true},
          "blocked_gate" => true,
          "hostile_discovery" => %{
            "personal_marker" => false,
            "project_marker" => true,
            "root_receipt" => true,
            "shell_modes" => true,
            "helper_receipt" => true,
            "helper_environment" => true,
            "helper_context" => true,
            "resume_rework" => true
          }
        } = receipts
      ) do
    with :ok <- validate_sessions([developer_id]),
         do: account_plugin_acceptance(receipts["account_plugins"])
  end

  def verify_evidence(receipts) do
    failures = evidence_failures(receipts)

    if failures == [],
      do: {:error, :incomplete_compatibility_evidence},
      else: {:error, {:compatibility_requirements_failed, failures}}
  end

  defp evidence_failures(receipts) when is_map(receipts) do
    environment = Map.get(receipts, "hostile_discovery", %{})

    environment_failures =
      for key <- ~w(root_receipt helper_environment shell_modes),
          Map.get(environment, key) == false,
          do: {key, :caller_environment_mismatch}

    account =
      case Map.fetch(receipts, "account_plugins") do
        {:ok, verdict} ->
          case account_plugin_acceptance(verdict) do
            :ok -> []
            {:error, reason} -> [{"account_plugins", reason}]
          end

        :error ->
          []
      end

    environment_failures ++ account
  end

  defp evidence_failures(_), do: []

  defp validate_sessions(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
         length(Enum.uniq(ids)) == length(ids),
       do: :ok,
       else: {:error, :incomplete_compatibility_evidence}
  end

  defp exercise(context, config, fixture, discovery, deadline) do
    with {:ok, discovery_receipt} <- probe_discovery(context, fixture, discovery),
         {:ok, shaping} <- interactive_shaping(context, config, fixture),
         {:ok, developer_context} <- bounded(context, deadline),
         {:ok, developer} <- developer_turn(developer_context, config, fixture),
         {:ok, resume_context} <- bounded(context, deadline),
         {:ok, resumed} <-
           resume_turn(resume_context, config, fixture, developer.session_id, @rework_findings) do
      for {name, turn} <- [{"developer", developer}, {"resume", resumed}] do
        File.write!(
          Path.join(fixture, ".kogen/runtime/compatibility-#{name}.json"),
          Jason.encode!(turn)
        )
      end

      oracle = run_isolation_oracle(context, fixture, discovery)

      {:ok,
       %{
         "shaping" => shaping,
         "developer" => %{"session_id" => developer.session_id},
         "resume" => %{"session_id" => resumed.session_id},
         "discovery_controls" => discovery_receipt,
         "blocked_gate" => blocked_gate?(developer),
         "hostile_discovery" => hostile_discovery(fixture, context, discovery, oracle),
         "isolation_oracle" => oracle,
         "account_plugins" => account_plugins(context, fixture)
       }}
    end
  end

  defp interactive_shaping(context, config, fixture) do
    prompt =
      "You are a Shaping compatibility probe. Reply with the concatenation of COMPATIBILITY_ and SHAPING_OK (no space), and do not use tools."

    args =
      context.args ++
        [
          "--model",
          config.shaping.model,
          "-c",
          "model_reasoning_effort=#{Jason.encode!(config.shaping.effort)}",
          "--enable",
          "hooks",
          "--dangerously-bypass-hook-trust",
          "--dangerously-bypass-approvals-and-sandbox",
          "--",
          prompt
        ]

    driver = Path.join([priv_dir(), "compatibility", "pty_driver.py"])
    output = Path.join(fixture, ".kogen/runtime/compatibility-shaping.json")

    {_, status} =
      System.cmd(
        "python3",
        [driver, context.executable, output, "COMPATIBILITY_SHAPING_OK" | args],
        cd: fixture,
        env:
          merge_env(context.env, [
            {"KOGEN_ROLE", "shaper"},
            {"KOGEN_COMPATIBILITY_TRUST_FIXTURE", fixture}
          ])
      )

    receipt =
      case File.read(output) do
        {:ok, text} -> Jason.decode!(text)
        _ -> %{}
      end

    result = %{
      "status" => status,
      "receipt" => relative(fixture, output),
      "marker" => receipt["marker"] == true,
      "cleanup" => get_in(receipt, ["cleanup", "ok"]) == true
    }

    outcome = shaping_outcome(status, result)

    if outcome.success,
      do: {:ok, Map.put(result, "outcome", outcome.status)},
      else: {:error, {:interactive_shaping_failed, result, outcome}}
  end

  defp shaping_outcome(0, %{"marker" => true, "cleanup" => true}),
    do: ProviderOutcome.settle(:succeeded, %{final: true})

  defp shaping_outcome(status, %{"marker" => marker, "cleanup" => false}) do
    kind = if status == 124, do: :timed_out, else: :provider_failed
    ProviderOutcome.settle(kind, %{status: status, marker: marker}, {:error, :pty_cleanup_failed})
  end

  defp shaping_outcome(124, result),
    do: ProviderOutcome.settle(:timed_out, %{status: 124, marker: result["marker"]})

  defp shaping_outcome(status, result) when status != 0,
    do: ProviderOutcome.settle(:provider_failed, %{status: status, marker: result["marker"]})

  defp shaping_outcome(status, _result),
    do: ProviderOutcome.settle(:malformed_evidence, %{status: status, marker: false})

  defp developer_turn(context, config, fixture) do
    prompt = """
    Work only in this disposable compatibility fixture. Use a focused shell command to write
    `.kogen/runtime/root-environment.json` with JSON keys `home`, `codex_home`, and `xdg` (an
    object containing every XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_CACHE_HOME, XDG_STATE_HOME value
    or null when absent). First attempt exactly one `make check` only to prove Kogen's PreToolUse
    hook blocks it; after the denial do not run it or any gate again. Execute the focused
    `python3 environment-receipt.py` and save its exact JSON output as the root receipt. Create
    additional exact receipts from the same command with tool-level login=false in
    `.kogen/runtime/root-nonlogin-environment.json` and with tool-level shell=/bin/zsh in
    `.kogen/runtime/root-explicit-shell-environment.json`. The first root receipt must use
    login=true. Do not emulate explicit shell selection by running sh inside a different shell.
    Your working directory is already the fixture: never pass a `workdir` to a tool and never
    type an absolute path (a mistyped path silently fails); use only the relative paths above.
    Report unsupported shell controls as failure, without fabricating receipts. Do not ask a
    helper to write files or run a gate, and finish this turn once every receipt above is
    written.
    """

    invoke_harness(:launch_developer, [
      prompt,
      config.developer.model,
      config.developer.effort,
      Kogen.VerificationPolicy.environment(["check", "live-native"], fixture),
      context
    ])
  end

  # Kogen's role policy maps the scout to the native `explorer` kind (see
  # Kogen.ExecutionPolicy). `codex exec` registers no custom `scout` kind, so a
  # prompt that only says "scout" lets the model guess an unknown agent_type and
  # spawn nothing. The prompt therefore names the native kind explicitly.
  @doc false
  @spec resume_prompt(Kogen.Intent.config(), [map()]) :: String.t()
  def resume_prompt(config, findings) do
    """
    This is the exact compatibility rework resume. Rework was requested with these findings:
    #{Jason.encode!(findings)}

    Add `.kogen/runtime/resume-rework.txt` containing exactly `EXACT_RESUME_REWORK`, and repair
    the concrete missing resume/helper evidence named by the rework request. Do not run `make
    check` or any other gate yourself.
    Before finishing, ask one configured native scout helper (spawn it with the native kind
    `explorer`; a native `codex exec` session has no `scout` kind) using model
    #{config.helpers.scout.model} at effort #{config.helpers.scout.effort}, read-only, to identify
    the project skill from its automatically supplied catalog, list the exact names in its
    supplied skill catalog and any supplied plugin or MCP server names, and run this one focused
    command, verbatim, with no argument added or removed (the next sentence is not part of it):
    `python3 environment-receipt.py --write .kogen/runtime/helper-environment.json`
    The script itself writes the helper's exact environment JSON to that
    file, so nobody retypes long paths. The helper's cwd is already the fixture; it must not pass
    a `workdir` and must not type any absolute path. The root saves the helper's project skill
    name in `.kogen/runtime/helper-receipt.txt`, and the helper's structured catalog as JSON
    `{"skills": [<every catalog skill name>], "skill_origins": {<skill name>: <that skill's
    catalog root path exactly as the catalog's skill roots list shows it>}, "plugins": [<names or
    empty>], "mcp_servers": [<names or empty>]}` in `.kogen/runtime/helper-context.json`. The root also saves its own
    catalog in the same JSON shape in `.kogen/runtime/resume-context.json`. Report only names
    you actually see; do not summarize them as an absence claim.
    Do not substitute a model or inherit your own profile; report unavailable configured profiles
    as a failure. The helper must not write any file other than through that one script option,
    and must not run a gate. Wait for its completed reply before
    you finish.
    """
  end

  defp resume_turn(context, config, fixture, session_id, findings) do
    prompt = resume_prompt(config, findings)

    invoke_harness(:resume_developer, [
      session_id,
      prompt,
      config.developer.model,
      config.developer.effort,
      Kogen.VerificationPolicy.environment(["check", "live-native"], fixture),
      context
    ])
  end

  # The Harness owns JSON/event parsing.  This runner merely supplies the
  # selected native context; accepting the legacy arity would silently re-resolve
  # the executable and is therefore refused.
  defp invoke_harness(function, arguments) do
    receipt =
      Path.expand(".kogen/runtime/process-#{function}-#{System.unique_integer([:positive])}.json")

    invocation = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    if File.exists?(receipt) do
      {:error, {:compatibility_receipt_exists, receipt}}
    else
      invoke_harness(function, arguments, receipt, invocation)
    end
  end

  defp invoke_harness(function, arguments, receipt, invocation) do
    arguments =
      List.update_at(arguments, -1, fn context ->
        %{
          context
          | env:
              merge_env(context.env, [
                {"KOGEN_BOUNDED_EXEC_RECEIPT", receipt},
                {"KOGEN_BOUNDED_EXEC_INVOCATION", invocation}
              ])
        }
      end)

    started = System.monotonic_time(:millisecond)
    result = apply(Kogen.Harness, function, arguments)
    elapsed_ms = System.monotonic_time(:millisecond) - started

    path =
      Path.join(".kogen/runtime", "turn-#{function}-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "operation" => function,
        "elapsed_ms" => elapsed_ms,
        "result" => inspect(result, limit: :infinity)
      })
    )

    case result do
      {:ok, result} ->
        {:ok,
         Map.merge(result, %{
           bounded_receipt: read_bounded_receipt(receipt),
           bounded_invocation: invocation
         })}

      {:error, reason} ->
        {:error, turn_failure(function, reason, read_bounded_receipt(receipt))}

      other ->
        {:error, {:compatibility_turn, function, other}}
    end
  rescue
    UndefinedFunctionError -> {:error, {:compatibility_harness_context_unavailable, function}}
  end

  # Only the bounded wrapper's own receipt classifies a turn as timed out; a
  # native exit status alone is never trusted as that class.
  @doc false
  def turn_failure(function, reason, %{"timed_out" => true}),
    do: {:compatibility_turn_timed_out, function, reason}

  def turn_failure(function, reason, _receipt), do: {:compatibility_turn, function, reason}

  defp read_bounded_receipt(path) do
    with {:ok, body} <- File.read(path),
         {:ok, receipt} <- Jason.decode(body),
         do: receipt,
         else: (_ -> %{})
  end

  defp launch_context(runtime, scope, config, fixture, discovery) do
    caller =
      Map.merge(System.get_env(), %{
        "HOME" => discovery["home"],
        "XDG_CONFIG_HOME" => Path.join(discovery["home"], "xdg-config"),
        "XDG_DATA_HOME" => "",
        "XDG_CACHE_HOME" => nil,
        "XDG_STATE_HOME" => nil,
        "OPENAI_API_KEY" => "synthetic-inherited-account-override",
        "CODEX_THREAD_ID" => "synthetic-unrelated-session",
        # This disposable repository owns its bounded Stop history. An outer
        # Build context is candidate-bound to the real checkout and must never
        # leak into the nested compatibility fixture.
        "KOGEN_VERIFICATION_CONTEXT" => nil,
        "KOGEN_TRACKING_CONTEXT" => nil
      })

    context = Environment.prepare(runtime, scope, config, fixture, fixture, caller)
    {:ok, Map.put(context, :harness, "codex")}
  rescue
    error -> {:error, {:compatibility_environment, Exception.message(error)}}
  end

  @doc false
  def prepare_fixture(project_root, config) do
    rehearsal_trace("Kogen.Codex.Compatibility.prepare_fixture")

    with {:ok, fixture, evidence} <- create_fixture(project_root) do
      case seed_discovery(fixture, config) do
        {:ok, discovery} -> {:ok, fixture, evidence, discovery}
        {:error, reason} -> failed_evidence(evidence, fixture, reason)
      end
    end
  end

  defp rehearsal_trace(identity) do
    case System.get_env("KOGEN_REHEARSAL_TRACE") do
      nil -> :ok
      path -> File.write!(path, identity <> "\n", [:append])
    end
  end

  defp create_fixture(project_root) do
    run =
      "compatibility-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"

    fixture = Path.join([Kogen.Codex.root(), "compatibility", run, "fixture"])
    evidence = Path.join([Kogen.Codex.root(), "compatibility", run, "evidence.json"])

    with :ok <- File.mkdir_p(Path.join(fixture, ".kogen/runtime")),
         :ok <- File.mkdir_p(Path.join(fixture, ".codex/hooks")),
         :ok <- write_fixture_files(fixture, project_root),
         :ok <- initialize_git(fixture) do
      {:ok, fixture, evidence}
    end
  end

  # This fixture never registers or copies the Stop scripts (`check.sh`,
  # `stop_runner.py`). It exercises only the PreToolUse blocked-gate path, so
  # its own hooks.json is authored here rather than copied from the project
  # root, and it stays free of the deleted no-context Stop mode.
  defp write_fixture_files(fixture, root) do
    File.write!(Path.join(fixture, ".gitignore"), ".kogen/runtime/\ngenerations/\nstate/\n")

    File.write!(
      Path.join(fixture, "README.md"),
      "# Kogen compatibility fixture\n\nDisposable native lifecycle proof. environment-receipt.py is a read-only focused probe. Kogen machinery owns verification gates through the PreToolUse hook; this fixture has no Stop hook.\n"
    )

    File.write!(Path.join(fixture, "PROJECT_GUIDANCE.md"), "PROJECT_GUIDANCE_VISIBLE\n")

    File.write!(
      Path.join(fixture, "Makefile"),
      "check:\n\t@echo 'Kogen machinery owns verification gates.'\n\t@exit 1\n"
    )

    File.write!(
      Path.join(fixture, "environment-receipt.py"),
      "import json, os, sys\n" <>
        "keys = ['HOME', 'CODEX_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME']\n" <>
        "data = {'home': os.getenv('HOME'), 'codex_home': os.getenv('CODEX_HOME'), 'xdg': {key: os.getenv(key) for key in keys if key.startswith('XDG_')}}\n" <>
        "print(json.dumps(data))\n" <>
        "if '--write' in sys.argv[1:-1]:\n" <>
        "    with open(sys.argv[sys.argv.index('--write') + 1], 'w') as out:\n" <>
        "        out.write(json.dumps(data) + '\\n')\n"
    )

    File.write!(
      Path.join(fixture, ".codex/hooks.json"),
      Jason.encode!(fixture_hooks(), pretty: true)
    )

    File.cp!(
      Path.join(root, ".codex/hooks/verification_policy.py"),
      Path.join(fixture, ".codex/hooks/verification_policy.py")
    )

    File.cp!(
      Path.join(root, ".codex/hooks/environment.py"),
      Path.join(fixture, ".codex/hooks/environment.py")
    )

    :ok
  end

  defp fixture_hooks do
    %{
      "description" => "Kogen owns Developer verification gates through the PreToolUse hook.",
      "hooks" => %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{
                "type" => "command",
                "command" =>
                  "python3 \"$(git rev-parse --show-toplevel)/.codex/hooks/verification_policy.py\""
              }
            ]
          }
        ]
      }
    }
  end

  defp initialize_git(fixture) do
    with {_, 0} <- System.cmd("git", ["init", "-q", "-b", "main"], cd: fixture),
         {_, 0} <- System.cmd("git", ["add", "."], cd: fixture),
         {_, 0} <-
           System.cmd(
             "git",
             [
               "-c",
               "user.name=Kogen Compatibility",
               "-c",
               "user.email=compatibility@example.invalid",
               "commit",
               "-q",
               "-m",
               "fixture"
             ],
             cd: fixture
           ) do
      :ok
    else
      {output, status} -> {:error, {:compatibility_fixture_git, status, output}}
    end
  end

  @doc false
  def native_denial_receipt?(receipt, invocation, session_id)
      when is_map(receipt) and is_binary(invocation) and is_binary(session_id) do
    with %{
           "invocation_id" => ^invocation,
           "native_session_id" => ^session_id,
           "native_exit" => 0,
           "timed_out" => false,
           "cancelled" => false,
           "native_stderr_complete" => true,
           "native_stderr" => stderr,
           "cleanup" => %{"ok" => true}
         } <- receipt,
         true <- is_binary(stderr) do
      Enum.any?(String.split(stderr, ~r/\R/, trim: true), fn line ->
        String.contains?(line, "Command blocked by PreToolUse hook:") and
          String.contains?(line, "Kogen machinery owns verification gates") and
          Regex.match?(~r/Command: make check\s*$/, line)
      end)
    else
      _ -> false
    end
  end

  def native_denial_receipt?(_, _, _), do: false

  defp blocked_gate?(%{session_id: id, bounded_receipt: receipt, bounded_invocation: invocation}),
    do: native_denial_receipt?(receipt, invocation, id)

  defp blocked_gate?(_), do: false

  defp hostile_discovery(fixture, context, discovery, oracle) do
    root_receipt = Path.join(fixture, ".kogen/runtime/root-environment.json")
    helper_receipt = Path.join(fixture, ".kogen/runtime/helper-receipt.txt")

    %{
      "personal_marker" =>
        Enum.any?([discovery["marker"], discovery["hook_marker"]], &File.exists?/1),
      "project_marker" =>
        file_contains?(Path.join(fixture, "PROJECT_GUIDANCE.md"), "PROJECT_GUIDANCE_VISIBLE"),
      "root_receipt" => valid_root_receipt?(root_receipt, context.env),
      "shell_modes" =>
        Enum.all?(
          ~w(root-nonlogin-environment.json root-explicit-shell-environment.json),
          fn name ->
            valid_root_receipt?(Path.join(fixture, ".kogen/runtime/" <> name), context.env)
          end
        ),
      "helper_environment" =>
        valid_root_receipt?(
          Path.join(fixture, ".kogen/runtime/helper-environment.json"),
          context.env
        ),
      "helper_receipt" => file_contains?(helper_receipt, discovery["project_sentinel"]),
      # Decided only from structured observed names; a free-text absence claim
      # is never read. See isolation_oracle/2.
      "helper_context" => oracle["status"] == "pass",
      "resume_rework" =>
        file_equals?(
          Path.join(fixture, ".kogen/runtime/resume-rework.txt"),
          "EXACT_RESUME_REWORK"
        )
    }
  end

  # ---------------------------------------------------------------------------
  # Deterministic isolation oracle.
  #
  # Decisions come only from structured observed names (native `debug
  # prompt-input` skill catalogs run by Kogen, or structured JSON a native
  # agent saved).  A free-text absence claim is never read.  Every observed
  # name is classified as bundled (in an inventory bound to the running
  # runtime), project (the project sentinel), forbidden (planted personal or
  # hostile content) or unclassified.  Unclassified names are neither
  # allowlisted nor called leakage: the result is `unproven`.
  # ---------------------------------------------------------------------------

  @oracle_surfaces ~w(root helper resume interactive)
  @observation_kinds ~w(skills plugins mcp_servers)

  @doc false
  def bundled_inventory_path, do: Path.join(priv_dir(), "bundled_inventory.json")

  @doc false
  def load_bundled_inventory do
    with {:ok, body} <- File.read(bundled_inventory_path()),
         {:ok, %{"runtimes" => runtimes} = inventory} when is_list(runtimes) <-
           Jason.decode(body) do
      {:ok, inventory}
    else
      _ -> {:error, :inventory_unreadable}
    end
  end

  @doc """
  Digest of a materialized `.system` skill tree: sha256 over sorted
  `relative path TAB file sha256 NEWLINE` lines, excluding the Codex marker.
  """
  @spec system_tree_digest(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def system_tree_digest(directory) do
    if File.dir?(directory) do
      lines =
        directory
        |> Path.join("**")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, directory))
        |> Enum.reject(&(&1 == ".codex-system-skills.marker"))
        |> Enum.map(fn relative ->
          digest = :crypto.hash(:sha256, File.read!(Path.join(directory, relative)))
          relative <> "\t" <> Base.encode16(digest, case: :lower) <> "\n"
        end)
        |> Enum.sort()

      {:ok, Base.encode16(:crypto.hash(:sha256, lines), case: :lower)}
    else
      {:error, :system_tree_missing}
    end
  end

  @doc """
  Binds the inventory to the running runtime.  Returns `{:ok, names}` or
  `{:error, reason}`; any mismatch or missing evidence makes it unusable.
  `binding` carries the observed `version`, `platform`, `executable_sha256`,
  `system_tree_digest` and `system_marker`.
  """
  @spec bind_inventory(map() | term(), map() | term()) ::
          {:ok, [String.t()]} | {:error, atom()}
  def bind_inventory(%{"runtimes" => runtimes}, binding)
      when is_list(runtimes) and is_map(binding) do
    case Enum.find(runtimes, &(&1["version"] == binding["version"])) do
      nil ->
        {:error, :inventory_version_mismatch}

      entry ->
        bind_inventory_entry(entry, binding)
    end
  end

  def bind_inventory(_, _), do: {:error, :inventory_unusable}

  defp bind_inventory_entry(
         %{"system_skills" => %{"names" => names} = skills} = entry,
         binding
       )
       when is_list(names) do
    cond do
      entry["platform"] != binding["platform"] ->
        {:error, :inventory_platform_mismatch}

      not present?(binding["executable_sha256"]) ->
        {:error, :runtime_digest_unobserved}

      entry["executable_sha256"] != binding["executable_sha256"] ->
        {:error, :inventory_runtime_digest_mismatch}

      not present?(binding["system_tree_digest"]) ->
        {:error, :system_tree_unobserved}

      skills["tree_digest"] != binding["system_tree_digest"] ->
        {:error, :inventory_tree_digest_mismatch}

      skills["marker"] != binding["system_marker"] ->
        {:error, :inventory_marker_mismatch}

      true ->
        {:ok, names}
    end
  end

  defp bind_inventory_entry(_, _), do: {:error, :inventory_malformed}

  defp present?(value), do: is_binary(value) and value != ""

  @doc """
  Evaluates structured observations.

  `observations` maps each of root, helper, resume and interactive to
  `%{"skills" => [...], "plugins" => [...], "mcp_servers" => [...]}` (plus
  optional `"forbidden_hits"` from a raw-output scan).  A surface without a
  structured `skills` list is unproven.  `options` supplies `:inventory`,
  `:binding`, `:project_sentinel`, `:project_root` (the only root the
  project sentinel may originate from) and `:forbidden` (planted sentinel names).
  """
  @spec isolation_oracle(map(), keyword() | map()) :: map()
  def isolation_oracle(observations, options) do
    options = Map.new(options)
    project = options[:project_sentinel]
    forbidden = Enum.map(options[:forbidden] || [], &String.downcase/1)

    system_root = canonical_root(get_in(options, [:binding, "system_root"]))
    project_root = canonical_root(options[:project_root])

    {inventory_state, bundled} =
      case bind_inventory(options[:inventory], options[:binding]) do
        {:ok, names} ->
          {%{"usable" => true}, MapSet.new(names)}

        {:error, reason} ->
          {%{"usable" => false, "reason" => Atom.to_string(reason)}, MapSet.new()}
      end

    observations = if is_map(observations), do: observations, else: %{}

    surfaces =
      Map.new(@oracle_surfaces, fn surface ->
        {surface,
         classify_surface(
           observations[surface],
           project,
           forbidden,
           bundled,
           inventory_state["usable"],
           {system_root, project_root}
         )}
      end)

    {status, reason} = oracle_verdict(surfaces, inventory_state, project)

    unclassified =
      surfaces
      |> Map.values()
      |> Enum.flat_map(& &1["unclassified"])
      |> Enum.uniq()
      |> Enum.sort()

    leaked =
      surfaces |> Map.values() |> Enum.flat_map(& &1["forbidden"]) |> Enum.uniq() |> Enum.sort()

    %{
      "status" => status,
      "reason" => reason,
      "inventory" => inventory_state,
      "unclassified" => unclassified,
      "forbidden" => leaked,
      "foreign" =>
        surfaces |> Map.values() |> Enum.flat_map(& &1["foreign"]) |> Enum.uniq() |> Enum.sort(),
      "surfaces" => surfaces
    }
  end

  defp classify_surface(
         %{"skills" => skills} = observation,
         project,
         forbidden,
         bundled,
         usable,
         roots
       )
       when is_list(skills) do
    origins = if is_map(observation["skill_origins"]), do: observation["skill_origins"], else: %{}

    entries =
      for kind <- @observation_kinds,
          list = observation[kind],
          is_list(list),
          name <- list,
          do: {kind, to_string(name)}

    hits = for hit <- List.wrap(observation["forbidden_hits"]), do: {"raw", to_string(hit)}

    classified =
      Enum.map(entries ++ hits, fn {kind, name} ->
        origin = if kind == "skills", do: canonical_origins(origins[name])

        {classify_name(kind, name, project, forbidden, bundled, usable, origin, roots), name}
      end)

    names = fn class ->
      classified
      |> Enum.filter(&(elem(&1, 0) == class))
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Enum.sort()
    end

    %{
      "observed" => true,
      "source" => observation["source"],
      "bundled" => names.(:bundled),
      "project" => names.(:project),
      "forbidden" => names.(:forbidden),
      "foreign" => names.(:foreign),
      "unclassified" => names.(:unclassified),
      "origins" => Map.new(origins, fn {name, root} -> {to_string(name), root} end)
    }
  end

  defp classify_surface(_, _, _, _, _, _),
    do: %{
      "observed" => false,
      "bundled" => [],
      "project" => [],
      "forbidden" => [],
      "foreign" => [],
      "unclassified" => [],
      "origins" => %{}
    }

  # A name is bundled only when the skill was observed under the pinned
  # `.system` tree (its inventory digest is checked by the binding). The same
  # name from another catalog root is foreign; a name with no recorded origin
  # cannot be proven bundled.
  defp classify_name(kind, name, project, forbidden, bundled, usable, origin, roots) do
    {system_root, project_root} = roots
    lowered = String.downcase(name)

    cond do
      Enum.any?(forbidden, &(lowered == &1 or String.contains?(lowered, &1))) ->
        :forbidden

      kind == "skills" and name == project ->
        origin_class(origin, project_root, :project)

      kind == "skills" and usable and MapSet.member?(bundled, name) ->
        origin_class(origin, system_root, :bundled)

      true ->
        :unclassified
    end
  end

  # Every catalog entry of a name is checked; one foreign-origin entry makes the
  # name foreign even when another entry of the same name is in the right root.
  defp origin_class([], _root, _class), do: :unclassified
  defp origin_class(_origins, nil, _class), do: :unclassified

  defp origin_class(origins, root, class) when is_list(origins),
    do: if(Enum.all?(origins, &(&1 == root)), do: class, else: :foreign)

  defp canonical_origins(value) do
    value
    |> List.wrap()
    |> Enum.map(&canonical_root/1)
    |> case do
      [] -> []
      roots -> if Enum.any?(roots, &is_nil/1), do: [:unknown], else: roots
    end
  end

  defp canonical_root(root) when is_binary(root) and root != "" do
    expanded = Path.expand(root)

    if String.starts_with?(expanded, "/private/"),
      do: binary_part(expanded, 8, byte_size(expanded) - 8),
      else: expanded
  end

  defp canonical_root(_), do: nil

  defp project_absent?(surface, project),
    do: surface["project"] == [] and project not in surface["unclassified"]

  defp oracle_verdict(surfaces, inventory, project) do
    values = Map.values(surfaces)

    cond do
      Enum.any?(values, &(&1["forbidden"] != [])) ->
        {"leak", "forbidden_sentinel_present"}

      Enum.any?(values, &(not &1["observed"])) ->
        {"unproven", "no_structured_observation"}

      Enum.any?(values, &(&1["foreign"] != [])) ->
        {"fail", "bundled_name_from_foreign_root"}

      Enum.any?(values, &project_absent?(&1, project)) ->
        {"fail", "project_sentinel_missing"}

      Enum.any?(values, &(&1["unclassified"] != [])) and inventory["usable"] ->
        {"unproven", "unclassified_names"}

      not inventory["usable"] ->
        {"unproven", inventory["reason"]}

      true ->
        {"pass", "all_names_classified"}
    end
  end

  # Account/remote plugin exclusion is evaluated per surface by
  # Kogen.Codex.AccountPlugins from native and model-visible observation
  # receipts.  Missing or unrecognized receipts are `unproven`; it is never
  # inferred from the local isolation oracle or from the bundled inventory.
  defp account_plugins(context, fixture) do
    dir = Path.join(fixture, ".kogen/runtime/account-plugin-observations")
    runtime = Map.get(context, :runtime_identity, %{})
    receipts = AccountObservation.observe(context, fixture, runtime, dir)
    account_plugin_verdict(context, fixture, receipts)
  end

  @doc """
  Judges this run's own fresh native observations (never an external or
  earlier directory) bound to the effective launch: the pinned runtime and
  executable, the selected scope home the server reported, the exact
  production arguments for the disabled session and one launch binding
  shared with the enabled positive control. The written receipt files are
  named with their digests so acceptance can refuse a tampered one.
  """
  @spec account_plugin_verdict(map(), Path.t(), [map()], keyword()) :: map()
  def account_plugin_verdict(context, cwd, receipts, opts \\ []) do
    runtime = Map.get(context, :runtime_identity, %{})
    home = AccountObservation.codex_home(context)

    observations =
      Enum.flat_map(receipts, fn receipt ->
        case AccountPlugins.parse(receipt) do
          {:ok, parsed} -> parsed
          _ -> []
        end
      end)

    observations
    |> AccountPlugins.evaluate(
      runtime: runtime["version"],
      executable_sha256: file_sha256(runtime["executable"]),
      codex_home: home,
      launch_binding: AccountObservation.launch_binding(context.args, home, cwd),
      production_args_sha256: AccountObservation.args_sha256(context.args),
      now: opts[:now]
    )
    |> Map.put("receipts", Enum.map(receipts, &Map.take(&1, ~w(mode path sha256))))
  end

  # Live compatibility accepts only native discovery demonstrated excluded
  # from this run's untampered receipts. The model-visible surfaces stay
  # reported as they are (normally unproven) and are not claimed here.
  defp account_plugin_acceptance(
         %{"surfaces" => %{"native_discovery" => %{"status" => "excluded"}}} = verdict
       ) do
    case verdict["receipts"] do
      [_ | _] = receipts ->
        case Enum.reject(receipts, &receipt_intact?/1) do
          [] ->
            :ok

          tampered ->
            {:error, {:account_plugin_receipts_changed, Enum.map(tampered, & &1["path"])}}
        end

      _ ->
        {:error, {:account_plugins_not_excluded, "no native observation receipts"}}
    end
  end

  defp account_plugin_acceptance(%{"surfaces" => %{"native_discovery" => native}}),
    do: {:error, {:account_plugins_not_excluded, native}}

  defp account_plugin_acceptance(_),
    do: {:error, {:account_plugins_not_excluded, "no account plugin evidence"}}

  defp receipt_intact?(%{"path" => path, "sha256" => sha}) when is_binary(path),
    do: file_sha256(path) == sha

  defp receipt_intact?(_), do: false

  defp run_isolation_oracle(context, fixture, discovery) do
    runtime = Map.get(context, :runtime_identity, %{})
    observations = isolation_observations(context, fixture, discovery)
    binding = isolation_binding(runtime, isolation_system_tree(observations, context))

    binding = Map.put(binding, "system_root", isolation_system_tree(observations, context))

    isolation_oracle(observations,
      inventory: bundled_inventory(),
      binding: binding,
      project_sentinel: discovery["project_sentinel"],
      project_root: Path.join(fixture, ".agents/skills"),
      forbidden: [discovery["personal_sentinel"], "personal-fixture"]
    )
    |> Map.put("binding", binding)
  end

  defp isolation_observations(context, fixture, discovery) do
    %{
      "root" => prompt_input_observation(context, fixture, discovery, []),
      "interactive" =>
        prompt_input_observation(context, fixture, discovery, ["--enable", "hooks"]),
      "helper" =>
        structured_observation(Path.join(fixture, ".kogen/runtime/helper-context.json")),
      "resume" => structured_observation(Path.join(fixture, ".kogen/runtime/resume-context.json"))
    }
  end

  # The pinned tree is the isolated CODEX_HOME's `.system`; the observed root
  # is only a fallback and every skill's own origin is checked against it.
  defp isolation_system_tree(observations, context) do
    case env_value(context.env, "CODEX_HOME") do
      home when is_binary(home) and home != "" ->
        Path.join(home, "skills/.system")

      _ ->
        case get_in(observations, ["root", "system_root"]) do
          root when is_binary(root) -> root
          _ -> ""
        end
    end
  end

  defp isolation_binding(runtime, tree) do
    digest = tree_digest(tree)
    marker = tree_marker(tree)

    %{
      "version" => runtime["version"],
      "platform" => runtime["platform"],
      "executable_sha256" => file_sha256(runtime["executable"]),
      "system_tree_digest" => digest,
      "system_marker" => marker
    }
  end

  defp tree_digest(tree) do
    case system_tree_digest(tree) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp tree_marker(tree) do
    case File.read(Path.join(tree, ".codex-system-skills.marker")) do
      {:ok, value} -> String.trim(value)
      _ -> nil
    end
  end

  defp bundled_inventory do
    case load_bundled_inventory() do
      {:ok, inventory} -> inventory
      _ -> nil
    end
  end

  defp file_sha256(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} -> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
      _ -> nil
    end
  end

  defp file_sha256(_), do: nil

  defp structured_observation(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"skills" => skills} = decoded} when is_list(skills) <- Jason.decode(body) do
      Map.put(decoded, "source", "native-agent-json")
    else
      _ -> nil
    end
  end

  # Kogen-run native `debug prompt-input` for the selected launch arguments.
  defp prompt_input_observation(context, fixture, discovery, extra_args) do
    task =
      Task.async(fn ->
        System.cmd(context.executable, context.args ++ extra_args ++ ["debug", "prompt-input"],
          cd: fixture,
          env: context.env,
          stderr_to_stdout: false
        )
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> parse_prompt_input(output, [discovery["personal_sentinel"]])
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Parses `debug prompt-input` JSON into a structured observation: the skill
  catalog names, the catalog's `.system` root, and any planted sentinel found
  anywhere in the raw output.
  """
  @spec parse_prompt_input(binary(), [String.t()]) :: map() | nil
  def parse_prompt_input(output, sentinels) do
    with {:ok, decoded} <- Jason.decode(output),
         [_ | _] = catalogs <- skill_catalogs(decoded) do
      text = Enum.join(catalogs, "\n")

      names =
        Regex.scan(~r/^- ([^\s:]+): .*\(file: r\d+\//m, text)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.uniq()

      system_root =
        case Regex.run(~r/`r\d+` = `([^`]*\/skills\/\.system)`/, text) do
          [_, root] -> root
          _ -> nil
        end

      origins = catalog_skill_origins(text)

      %{
        "skills" => names,
        "skill_origins" => origins,
        "system_root" => system_root,
        "source" => "prompt-input",
        "forbidden_hits" =>
          Enum.filter(sentinels, &(is_binary(&1) and &1 != "" and String.contains?(output, &1)))
      }
    else
      _ -> nil
    end
  end

  # Maps each catalog skill name to the root its `file:` alias names.  A name
  # listed more than once keeps every distinct origin (a list) so a foreign
  # entry cannot be hidden behind a bundled one.
  defp catalog_skill_origins(text) do
    aliases =
      Map.new(Regex.scan(~r/`(r\d+)` = `([^`]*)`/, text), fn [_, alias_, root] ->
        {alias_, root}
      end)

    for [_, name, alias_] <- Regex.scan(~r/^- ([^\s:]+): .*\(file: (r\d+)\//m, text),
        is_binary(aliases[alias_]),
        reduce: %{} do
      acc -> Map.update(acc, name, [aliases[alias_]], &Enum.uniq(&1 ++ [aliases[alias_]]))
    end
    |> Map.new(fn
      {name, [only]} -> {name, only}
      other -> other
    end)
  end

  defp skill_catalogs(value) when is_binary(value),
    do: if(String.contains?(value, "<skills_instructions>"), do: [value], else: [])

  defp skill_catalogs(value) when is_list(value), do: Enum.flat_map(value, &skill_catalogs/1)
  defp skill_catalogs(value) when is_map(value), do: value |> Map.values() |> skill_catalogs()
  defp skill_catalogs(_), do: []

  defp file_equals?(path, expected) do
    case File.read(path) do
      {:ok, content} -> String.trim(content) == expected
      _ -> false
    end
  end

  defp file_contains?(path, expected) do
    case File.read(path) do
      {:ok, content} -> String.contains?(content, expected)
      _ -> false
    end
  end

  defp valid_root_receipt?(path, environment) do
    with {:ok, body} <- File.read(path),
         {:ok, receipt} <- Jason.decode(body),
         true <- receipt["home"] == env_value(environment, "KOGEN_CALLER_HOME"),
         true <- receipt["codex_home"] == env_value(environment, "CODEX_HOME"),
         true <- valid_xdg_receipt?(receipt["xdg"], environment) do
      true
    else
      _ -> false
    end
  end

  defp valid_xdg_receipt?(xdg, environment) when is_map(xdg) do
    Enum.all?(~w(XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME), fn variable ->
      expected =
        cond do
          env_value(environment, "KOGEN_CALLER_#{variable}_ABSENT") == "1" -> nil
          env_value(environment, "KOGEN_CALLER_#{variable}_EMPTY") == "1" -> ""
          true -> env_value(environment, "KOGEN_CALLER_#{variable}")
        end

      xdg[variable] == expected
    end)
  end

  defp valid_xdg_receipt?(_, _), do: false
  defp env_value(environment, name), do: environment |> Map.new() |> Map.get(name)

  defp validate_runtime(runtime) when is_map(runtime) do
    required = ~w(version executable path platform)

    if Enum.all?(required, &(is_binary(runtime[&1]) and runtime[&1] != "")),
      do: :ok,
      else: {:error, :invalid_runtime}
  end

  defp validate_runtime(_), do: {:error, :invalid_runtime}

  defp seed_discovery(fixture, config) do
    script = Path.join(priv_dir(), "discovery.py")

    case System.cmd("python3", [script, "seed", fixture, Jason.encode!(config)],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Jason.decode(output)
      {output, status} -> {:error, {:discovery_seed, status, output}}
    end
  end

  defp probe_discovery(context, fixture, specification) do
    script = Path.join(priv_dir(), "discovery.py")

    case System.cmd(
           "python3",
           [
             script,
             "probe",
             context.executable,
             fixture,
             Jason.encode!(specification),
             Jason.encode!(context.args)
           ],
           env: context.env,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        with {:ok, receipt} <- Jason.decode(output) do
          File.write!(Path.join(fixture, ".kogen/runtime/discovery.json"), Jason.encode!(receipt))
          {:ok, Map.put(receipt, "ok", true)}
        end

      {output, status} ->
        receipt = Path.join(fixture, ".kogen/runtime/discovery.json")
        File.write!(receipt, output)
        {:error, {:effective_discovery_failed, status, receipt}}
    end
  end

  # Each native turn gets the owner's per-turn limit, shortened only so that no
  # turn can outlive the whole-test deadline. This overrides any inherited value.
  # Exposed (not private) so offline tests can assert the exact
  # KOGEN_BOUNDED_EXEC_TIMEOUT value the owner actually passes, not merely the
  # module attribute.
  @doc false
  def bounded(context, deadline) do
    python =
      System.find_executable("python3") ||
        raise "Kogen compatibility requires Python 3.11 or newer"

    seconds =
      min(@turn_timeout_seconds, div(deadline - System.monotonic_time(:millisecond), 1000))

    if seconds < @minimum_turn_seconds do
      {:error, {:compatibility_deadline_exhausted, seconds}}
    else
      {:ok,
       %{
         context
         | executable: python,
           args: [
             Path.join([priv_dir(), "compatibility", "bounded_exec.py"]),
             context.executable | context.args
           ],
           env:
             merge_env(context.env, [{"KOGEN_BOUNDED_EXEC_TIMEOUT", Integer.to_string(seconds)}])
       }}
    end
  end

  defp merge_env(environment, overrides),
    do: Map.merge(Map.new(environment), Map.new(overrides)) |> Map.to_list()

  defp validate_scope(%{path: path, name: name})
       when is_binary(path) and name in [:shared, :project] do
    expanded = Path.expand(path)

    if Path.type(expanded) == :absolute and expanded == path,
      do: :ok,
      else: {:error, :invalid_scope_path}
  end

  defp validate_scope(_), do: {:error, :invalid_scope}

  defp validate_config(%{
         harness: "codex",
         shaping: %{model: model, effort: effort},
         developer: %{model: dev_model, effort: dev_effort},
         reviewer: %{model: review_model, effort: review_effort}
       })
       when is_binary(model) and is_binary(effort) and is_binary(dev_model) and
              is_binary(dev_effort) and is_binary(review_model) and is_binary(review_effort),
       do: :ok

  defp validate_config(_), do: {:error, :invalid_config}

  defp kogen_project_root do
    root = File.cwd!() |> Path.expand()

    if File.regular?(Path.join(root, "README.md")),
      do: {:ok, root},
      else: {:error, :not_kogen_root}
  end

  defp priv_dir, do: Application.app_dir(:kogen, "priv/kogen/codex")
  defp relative(root, path), do: Path.relative_to(path, root)
end
