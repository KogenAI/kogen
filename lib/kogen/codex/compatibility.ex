defmodule Kogen.Codex.Compatibility do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [Kogen.Codex, Kogen.Harness, Kogen.Intent, Kogen.VerificationPolicy]

  # This is deliberately a small, direct boundary used by update and the live
  # acceptance slice.  It receives a runtime and login scope that have already
  # been selected by the caller: resolving a default, installing, updating, or
  # authenticating here would make candidate verification able to change the
  # state it is meant to assess.

  alias Kogen.Codex.Environment

  @type runtime :: %{
          required(String.t()) => String.t()
        }

  @type scope :: %{path: Path.t(), name: :shared | :project}

  @spec run(runtime(), scope(), Kogen.Intent.config()) :: {:ok, Path.t()} | {:error, term()}
  def run(runtime, scope, config) do
    Kogen.Codex.with_active(runtime, File.cwd!(), fn -> run_fixture(runtime, scope, config) end)
  end

  defp run_fixture(runtime, scope, config) do
    with :ok <- validate_runtime(runtime),
         :ok <- validate_scope(scope),
         :ok <- validate_config(config),
         {:ok, project_root} <- kogen_project_root(),
         {:ok, fixture, evidence, discovery} <- prepare_fixture(project_root, config) do
      result =
        with {:ok, context} <- launch_context(runtime, scope, config, fixture, discovery),
             {:ok, receipts} <-
               exercise_in_fixture(context, config, fixture, discovery),
             do: settle_evidence(receipts)

      retain_result(result, evidence, fixture)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, {:compatibility_exception, Exception.message(error)}}
  end

  defp exercise_in_fixture(context, config, fixture, discovery),
    do: File.cd!(fixture, fn -> exercise(context, config, fixture, discovery) end)

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

  @doc false
  @spec verify_evidence(map()) :: :ok | {:error, term()}
  def verify_evidence(%{
        "shaping" => %{"status" => 0, "marker" => true, "cleanup" => true},
        "developer" => %{"session_id" => developer_id},
        "resume" => %{"session_id" => developer_id},
        "initial_reviewer" => %{
          "session_id" => initial_reviewer_id,
          "verdict" => "rework",
          "scenarios" => initial_scenarios,
          "findings" => initial_findings
        },
        "final_reviewer" => %{
          "session_id" => final_reviewer_id,
          "verdict" => "accept",
          "scenarios" => final_scenarios
        },
        "checks" => checks,
        "checks_before_resume" => prior_count,
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
          "resume_rework" => true,
          "hook_receipt" => true
        }
      })
      when is_list(checks) and is_integer(prior_count) and prior_count >= 0 do
    with :ok <- validate_sessions([developer_id, initial_reviewer_id, final_reviewer_id]),
         :ok <- check_state(checks, developer_id),
         true <- fresh_resume_check?(checks, prior_count, developer_id),
         true <- reviewer_requested_rework?(initial_scenarios, initial_findings),
         true <-
           Enum.any?(
             final_scenarios,
             &(&1["id"] == "compatibility-runner" and &1["status"] == "satisfied")
           ) do
      :ok
    else
      false -> {:error, :reviewer_did_not_complete_rework_sequence}
      {:error, _} = error -> error
    end
  end

  def verify_evidence(receipts) do
    failures = evidence_failures(receipts)

    if failures == [],
      do: {:error, :incomplete_compatibility_evidence},
      else: {:error, {:compatibility_requirements_failed, failures}}
  end

  defp evidence_failures(receipts) when is_map(receipts) do
    environment = Map.get(receipts, "hostile_discovery", %{})

    failed =
      for key <- ~w(root_receipt helper_environment hook_receipt shell_modes),
          Map.get(environment, key) == false,
          do: {key, :caller_environment_mismatch}

    case receipts["final_reviewer"] do
      %{"verdict" => "rework"} = review ->
        failed ++ [{"final_reviewer", Map.take(review, ~w(findings scenarios))}]

      _ ->
        failed
    end
  end

  defp evidence_failures(_), do: []

  defp validate_sessions(ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) and
         length(Enum.uniq(ids)) == length(ids),
       do: :ok,
       else: {:error, :incomplete_compatibility_evidence}
  end

  defp fresh_resume_check?(checks, prior_count, developer_id) do
    case checks |> Enum.drop(prior_count) |> List.last() do
      %{"session_id" => ^developer_id, "status" => "passed"} -> true
      _ -> false
    end
  end

  defp check_state(checks, developer_id) do
    statuses =
      checks
      |> Enum.filter(&(&1["session_id"] == developer_id))
      |> Enum.map(& &1["status"])

    if "failed" in statuses and Enum.count(statuses, &(&1 == "passed")) >= 2 do
      if Enum.find_index(statuses, &(&1 == "failed")) <
           Enum.find_index(statuses, &(&1 == "passed")) and List.last(statuses) == "passed",
         do: :ok,
         else: {:error, :check_correction_order}
    else
      {:error, :missing_failed_check_correction_or_resume}
    end
  end

  defp reviewer_requested_rework?(scenarios, findings)
       when is_list(scenarios) and is_list(findings) do
    findings != [] and
      Enum.any?(
        scenarios,
        &(&1["id"] == "compatibility-runner" and &1["status"] == "needs_rework")
      )
  end

  defp reviewer_requested_rework?(_, _), do: false

  defp exercise(context, config, fixture, discovery) do
    with {:ok, discovery_receipt} <- probe_discovery(context, fixture, discovery),
         {:ok, shaping} <- interactive_shaping(context, config, fixture),
         {:ok, developer} <- developer_turn(bounded(context), config, fixture),
         {:ok, before_resume} <- check_history(fixture),
         {:ok, initial_reviewer} <- initial_reviewer_turn(bounded(context), config, fixture),
         {:ok, resumed} <-
           resume_turn(
             bounded(context),
             config,
             fixture,
             developer.session_id,
             initial_reviewer.response["findings"]
           ),
         {:ok, final_reviewer} <- final_reviewer_turn(bounded(context), config, fixture),
         {:ok, checks} <- check_history(fixture) do
      for {name, turn} <- [
            {"developer", developer},
            {"initial-reviewer", initial_reviewer},
            {"resume", resumed},
            {"final-reviewer", final_reviewer}
          ] do
        File.write!(
          Path.join(fixture, ".kogen/runtime/compatibility-#{name}.json"),
          Jason.encode!(turn)
        )
      end

      {:ok,
       %{
         "shaping" => shaping,
         "developer" => %{"session_id" => developer.session_id},
         "resume" => %{"session_id" => resumed.session_id},
         "initial_reviewer" => %{
           "session_id" => initial_reviewer.session_id,
           "verdict" => initial_reviewer.verdict,
           "scenarios" => initial_reviewer.response["scenarios"],
           "findings" => initial_reviewer.response["findings"]
         },
         "final_reviewer" => %{
           "session_id" => final_reviewer.session_id,
           "verdict" => final_reviewer.verdict,
           "scenarios" => final_reviewer.response["scenarios"],
           "findings" => final_reviewer.response["findings"]
         },
         "checks" => checks,
         "checks_before_resume" => length(before_resume),
         "discovery_controls" => discovery_receipt,
         "blocked_gate" => blocked_gate?(developer),
         "hostile_discovery" => hostile_discovery(fixture, context, discovery)
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

    if status == 0 and result["marker"] and result["cleanup"],
      do: {:ok, result},
      else: {:error, {:interactive_shaping_failed, result}}
  end

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
    Report unsupported shell controls as failure, without fabricating receipts. Create
    `state.txt` containing `broken` and finish. When the tracked Stop hook blocks on its owned
    failed check, read its receipt, correct state.txt to exactly `corrected`, and finish in this
    same Developer session. Do not ask a helper to write files or run a gate.
    """

    invoke_harness(:launch_developer, [
      prompt,
      config.developer.model,
      config.developer.effort,
      Kogen.VerificationPolicy.environment(["check", "live"], fixture),
      context
    ])
  end

  defp resume_turn(context, config, fixture, session_id, findings) do
    prompt = """
    This is the exact compatibility rework resume after the initial independent Reviewer returned
    these findings:
    #{Jason.encode!(findings)}

    Preserve `state.txt` as exactly `corrected`, add `.kogen/runtime/resume-rework.txt` containing
    exactly `EXACT_RESUME_REWORK`, and repair the concrete missing resume/helper evidence named by
    the Reviewer. Do not run any gate yourself; the Stop hook owns this fresh Check settlement.
    Before finishing, ask one configured native scout helper using model
    #{config.helpers.scout.model} at effort #{config.helpers.scout.effort}, read-only, to identify
    the project skill from its automatically supplied catalog, state whether any personal skill
    or instruction was supplied, and run the focused `python3 environment-receipt.py` command.
    That script only prints JSON. The root saves the helper's returned exact JSON in
    `.kogen/runtime/helper-environment.json`, its project skill name in
    `.kogen/runtime/helper-receipt.txt`, and its report of personal context in
    `.kogen/runtime/helper-context.txt`. The helper-context receipt must contain exactly
    `PERSONAL_CONTEXT_ABSENT` only when the helper found no supplied personal skill or instruction;
    otherwise preserve the helper's actual report and stop rather than claiming the fixture passed.
    Do not substitute a model or inherit your own profile; report unavailable configured profiles
    as a failure. The helper must not write files or run a gate. Wait for its completed reply before
    you finish.
    """

    invoke_harness(:resume_developer, [
      session_id,
      prompt,
      config.developer.model,
      config.developer.effort,
      Kogen.VerificationPolicy.environment(["check", "live"], fixture),
      context
    ])
  end

  defp initial_reviewer_turn(context, config, _fixture) do
    prompt = """
    You are the initial independent Reviewer for this disposable compatibility fixture. Do not
    modify files or run a gate. The Developer has corrected its Stop Check, but no rework resume
    has occurred yet. Inspect `state.txt`, `.kogen/runtime/verification-history.jsonl`, and the
    runtime receipts. In particular, determine whether the required exact-resume marker and helper
    evidence (`resume-rework.txt`, helper environment, project-skill receipt, and personal-context
    receipt) are actually absent or inadequate. Those missing artifacts are concrete blocking
    evidence for this candidate, so return `rework` with actionable findings citing existing
    requirement/fixture files and a `compatibility-runner` assessment of `needs_rework` when they
    are missing. Do not invent a pass merely because the first Developer Check settled. Return the
    schema-valid verdict for candidate `compatibility-candidate` and attempt
    `compatibility-initial-review` based on the inspected candidate.
    """

    invoke_harness(:launch_reviewer, [
      prompt,
      config.reviewer.model,
      config.reviewer.effort,
      context
    ])
  end

  defp final_reviewer_turn(context, config, _fixture) do
    prompt = """
    You are the final independent Reviewer for this disposable compatibility fixture after a
    Developer rework resume. Do not modify files or run a gate. Inspect the revised candidate and
    assess the whole contract: `state.txt` is `corrected`; verification history has a failed then
    passed Check in one Developer session plus a later passing Check from that exact resumed session;
    `resume-rework.txt` contains its exact marker; root, hook, and helper environment receipts have
    the restored caller HOME/XDG and selected CODEX_HOME; the helper receipt names the project skill;
    and helper context actually records `PERSONAL_CONTEXT_ABSENT`. Also inspect project guidance
    content and the discovery receipt rather than treating marker-file existence as proof. Return a
    schema-valid verdict for candidate `compatibility-candidate` and attempt
    `compatibility-final-review` based only on what you find. Acceptance is not pre-decided. Include
    one scenario assessment with id `compatibility-runner`.
    """

    invoke_harness(:launch_reviewer, [
      prompt,
      config.reviewer.model,
      config.reviewer.effort,
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

    result = apply(Kogen.Harness, function, arguments)

    path =
      Path.join(".kogen/runtime", "turn-#{function}-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{"operation" => function, "result" => inspect(result, limit: :infinity)})
    )

    case result do
      {:ok, result} ->
        {:ok,
         Map.merge(result, %{
           bounded_receipt: read_bounded_receipt(receipt),
           bounded_invocation: invocation
         })}

      {:error, reason} ->
        {:error, {:compatibility_turn, function, reason}}

      other ->
        {:error, {:compatibility_turn, function, other}}
    end
  rescue
    UndefinedFunctionError -> {:error, {:compatibility_harness_context_unavailable, function}}
  end

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

    {:ok, Environment.prepare(runtime, scope, config, fixture, fixture, caller)}
  rescue
    error -> {:error, {:compatibility_environment, Exception.message(error)}}
  end

  @doc false
  def prepare_fixture(project_root, config) do
    with {:ok, fixture, evidence} <- create_fixture(project_root) do
      case seed_discovery(fixture, config) do
        {:ok, discovery} -> {:ok, fixture, evidence, discovery}
        {:error, reason} -> failed_evidence(evidence, fixture, reason)
      end
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

  defp write_fixture_files(fixture, root) do
    File.write!(Path.join(fixture, ".gitignore"), ".kogen/runtime/\ngenerations/\nstate/\n")

    File.write!(
      Path.join(fixture, "README.md"),
      "# Kogen compatibility fixture\n\nDisposable native lifecycle proof. environment-receipt.py is a read-only focused probe. The tracked Stop hook exclusively owns the bounded check.\n"
    )

    File.write!(Path.join(fixture, "PROJECT_GUIDANCE.md"), "PROJECT_GUIDANCE_VISIBLE\n")

    File.write!(
      Path.join(fixture, "Makefile"),
      "check:\n\t@python3 environment-receipt.py > .kogen/runtime/hook-environment.json\n\t@test \"$$(cat state.txt 2>/dev/null)\" = corrected || { echo 'Required state.txt content: corrected'; exit 1; }\n"
    )

    File.write!(
      Path.join(fixture, "environment-receipt.py"),
      "import json, os\n" <>
        "keys = ['HOME', 'CODEX_HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME']\n" <>
        "data = {'home': os.getenv('HOME'), 'codex_home': os.getenv('CODEX_HOME'), 'xdg': {key: os.getenv(key) for key in keys if key.startswith('XDG_')}}\n" <>
        "print(json.dumps(data))\n"
    )

    File.write!(
      Path.join(fixture, ".codex/hooks.json"),
      File.read!(Path.join(root, ".codex/hooks.json"))
    )

    File.cp!(
      Path.join(root, ".codex/hooks/check.sh"),
      Path.join(fixture, ".codex/hooks/check.sh")
    )

    File.cp!(
      Path.join(root, ".codex/hooks/stop_runner.py"),
      Path.join(fixture, ".codex/hooks/stop_runner.py")
    )

    File.cp!(
      Path.join(root, ".codex/hooks/verification_policy.py"),
      Path.join(fixture, ".codex/hooks/verification_policy.py")
    )

    File.cp!(
      Path.join(root, ".codex/hooks/environment.py"),
      Path.join(fixture, ".codex/hooks/environment.py")
    )

    File.chmod!(Path.join(fixture, ".codex/hooks/check.sh"), 0o755)
    :ok
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

  defp check_history(fixture) do
    path = Path.join(fixture, ".kogen/runtime/verification-history.jsonl")

    case File.read(path) do
      {:ok, body} -> {:ok, body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)}
      {:error, reason} -> {:error, {:missing_check_history, reason}}
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

  defp hostile_discovery(fixture, context, discovery) do
    root_receipt = Path.join(fixture, ".kogen/runtime/root-environment.json")
    helper_receipt = Path.join(fixture, ".kogen/runtime/helper-receipt.txt")
    helper_context = Path.join(fixture, ".kogen/runtime/helper-context.txt")

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
      "hook_receipt" =>
        valid_root_receipt?(
          Path.join(fixture, ".kogen/runtime/hook-environment.json"),
          context.env
        ),
      "helper_environment" =>
        valid_root_receipt?(
          Path.join(fixture, ".kogen/runtime/helper-environment.json"),
          context.env
        ),
      "helper_receipt" => file_contains?(helper_receipt, discovery["project_sentinel"]),
      "helper_context" => file_equals?(helper_context, "PERSONAL_CONTEXT_ABSENT"),
      "resume_rework" =>
        file_equals?(
          Path.join(fixture, ".kogen/runtime/resume-rework.txt"),
          "EXACT_RESUME_REWORK"
        )
    }
  end

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

  defp bounded(context) do
    python =
      System.find_executable("python3") ||
        raise "Kogen compatibility requires Python 3.11 or newer"

    %{
      context
      | executable: python,
        args: [
          Path.join([priv_dir(), "compatibility", "bounded_exec.py"]),
          context.executable | context.args
        ]
    }
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
