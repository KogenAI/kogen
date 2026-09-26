Code.require_file("../support/compiled_fixture.exs", __DIR__)

defmodule Kogen.HarnessRoleTest do
  use Kogen.IsolatedCase, async: true

  alias Kogen.Build.{Workspace, WriteBoundary}
  alias Kogen.Codex.State
  alias Kogen.Harness.Claude
  alias Mix.Tasks.Kogen.Expert

  @moduletag timeout: 120_000

  @hybrid_config """
  default_route: hybrid
  routes:
    hybrid:
      shaping:   {harness: claude, model: claude-opus-5-5, effort: medium}
      developer: {harness: claude, model: claude-opus-5-5, effort: medium}
      reviewer:  {harness: codex, model: gpt-6-sol, effort: high}
      expert:    {harness: codex, model: gpt-6-sol, effort: high}
      helpers:
        claude:
          scout:  {model: claude-sonnet-5, effort: low}
          worker: {model: claude-sonnet-5, effort: medium}
        codex:
          scout:  {model: gpt-6-luna, effort: low}
          worker: {model: gpt-6-luna, effort: high}
  outer_resumptions: 2
  verification_retries: 2
  """

  # Claude Code speaks `-p` stream-json and Codex speaks `exec` JSONL; one
  # offline executable answers either protocol and logs argv and role env.
  @dual_protocol """
  #!/bin/sh
  printf 'argv:' >> "$DISPATCH_LOG"; for a in "$@"; do printf ' %s' "$a" >> "$DISPATCH_LOG"; done
  printf '\\nenv: KOGEN_ROLE=%s KOGEN_EXPERT=%s KOGEN_VERIFICATION_CONTEXT=%s\\n' "${KOGEN_ROLE:-}" "${KOGEN_EXPERT:-unset}" "${KOGEN_VERIFICATION_CONTEXT:-unset}" >> "$DISPATCH_LOG"
  if [ "${1:-}" = auth ]; then
    printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'
    exit 0
  fi
  cat > /dev/null
  protocol=
  for a in "$@"; do
    case "$a" in -p|exec) protocol="$a"; break ;; esac
  done
  if [ "$protocol" = exec ]; then
    printf '%s\\n' '{"type":"thread.started","thread_id":"codex-expert"}' '{"type":"item.completed","item":{"type":"agent_message","text":"codex expert answer"}}' '{"type":"turn.completed"}'
    exit 0
  fi
  sid=; model=; prev=
  for a in "$@"; do
    [ "$prev" = --session-id ] && sid="$a"
    [ "$prev" = --model ] && model="$a"
    prev="$a"
  done
  printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$sid"
  printf '{"type":"assistant","session_id":"%s","message":{"model":"%s","content":[]}}\\n' "$sid" "${FAKE_ROOT_MODEL:-$model}"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"claude expert answer","session_id":"%s"}\\n' "$sid"
  """

  # `@dual_protocol` plus one line: when launched as the Expert, dump the full
  # environment the process actually received to `$ENV_LOG`, so a test can
  # assert `CLAUDE_CONFIG_DIR`/`CLAUDE_SECURESTORAGE_CONFIG_DIR`/`HOME`/`cwd`
  # from the fake harness's own receipt rather than from launch arguments.
  @expert_receipt_protocol """
  #!/bin/sh
  printf 'argv:' >> "$DISPATCH_LOG"; for a in "$@"; do printf ' %s' "$a" >> "$DISPATCH_LOG"; done
  printf '\\n' >> "$DISPATCH_LOG"
  if [ "${KOGEN_ROLE:-}" = expert ] && [ -n "${ENV_LOG:-}" ]; then
    { echo "PWD=$(pwd -P)"; env; } > "$ENV_LOG"
  fi
  if [ "${1:-}" = auth ]; then
    printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'
    exit 0
  fi
  cat > /dev/null
  protocol=
  for a in "$@"; do
    case "$a" in -p|exec) protocol="$a"; break ;; esac
  done
  if [ "$protocol" = exec ]; then
    printf '%s\\n' '{"type":"thread.started","thread_id":"codex-expert"}' '{"type":"item.completed","item":{"type":"agent_message","text":"codex expert answer"}}' '{"type":"turn.completed"}'
    exit 0
  fi
  sid=; model=; prev=
  for a in "$@"; do
    [ "$prev" = --session-id ] && sid="$a"
    [ "$prev" = --model ] && model="$a"
    prev="$a"
  done
  printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$sid"
  printf '{"type":"assistant","session_id":"%s","message":{"model":"%s","content":[]}}\\n' "$sid" "${FAKE_ROOT_MODEL:-$model}"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"claude expert answer","session_id":"%s"}\\n' "$sid"
  """

  # Scenario `per-build-harness-home`: inside a Build the frozen Expert
  # assignment `Kogen.Harness.expert_environment/3` hands the caller role also
  # carries the control root, the Candidate, the harness home, the Build's own
  # binding for the Expert's harness (never re-resolved) and the write
  # boundary, so `mix kogen.expert` launches bound and confined exactly as the
  # rest of that Build. Outside a Build (`launch: nil`) none of those fields
  # is present.
  test "inside a Build the Expert assignment also carries control root, Candidate, harness home, binding and write boundary" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-expert-assignment-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    config_path = Path.join(dir, "config.yaml")
    File.write!(config_path, @hybrid_config)
    {:ok, config} = Kogen.Intent.read_config(config_path)

    codex_binding = %{
      harness: "codex",
      runtime: %{"executable" => "/managed/codex", "version" => "0.156.1"},
      scope: %{name: :shared, path: "/scope/codex"}
    }

    launch = %{
      control: "/control/root",
      root: "/candidate/path",
      harness_home: "/harness/home",
      bindings: %{"codex" => codex_binding},
      boundary: %{"sha256" => "abc123", "candidate" => "/candidate/path"}
    }

    [{"KOGEN_EXPERT", json}] = Kogen.Harness.expert_environment(config, :developer, launch)
    assignment = Jason.decode!(json)

    assert assignment["control_root"] == "/control/root"
    assert assignment["candidate"] == "/candidate/path"
    assert assignment["harness_home"] == "/harness/home"
    assert assignment["binding"] == Kogen.Harness.binding_record(codex_binding)

    assert assignment["write_boundary"] == %{
             "sha256" => "abc123",
             "candidate" => "/candidate/path"
           }

    [{"KOGEN_EXPERT", plain_json}] = Kogen.Harness.expert_environment(config, :developer)
    plain = Jason.decode!(plain_json)
    refute Map.has_key?(plain, "control_root")
    refute Map.has_key?(plain, "candidate")
    refute Map.has_key?(plain, "harness_home")
    refute Map.has_key?(plain, "binding")
    refute Map.has_key?(plain, "write_boundary")
  end

  # Scenario `per-build-harness-home` and `role-write-boundary`: `mix
  # kogen.expert`, run by the Developer from the Candidate, refuses any other
  # cwd, and otherwise launches the Expert with cwd the Candidate, the frozen
  # binding (never re-resolved from the Candidate path) and its config dir
  # under the harness home -- observed from the fake harness's own receipt of
  # the process it actually ran in, not from launch arguments. Applying the
  # write boundary here runs a real `sandbox-exec` self-test.
  @tag :unconfined
  test "mix kogen.expert launches on the Build's bound scope and harness home, and refuses a wrong cwd" do
    candidate =
      File.cwd!()
      |> Kogen.CompiledFixture.create!("expert-candidate")
      |> Workspace.canonical()

    File.mkdir_p!(Path.join(candidate, "priv/kogen/prompts"))

    File.cp!(
      Path.join(File.cwd!(), "priv/kogen/prompts/expert.md"),
      Path.join(candidate, "priv/kogen/prompts/expert.md")
    )

    dir =
      Path.join(System.tmp_dir!(), "kogen-expert-build-#{System.unique_integer([:positive])}")

    harness_home = Path.join(dir, "harness-home")
    scope = Path.join(dir, "claude-scope")
    control = Path.join(dir, "control")
    tmp_dir = Path.join(dir, "tmp")

    for d <- [harness_home, scope, control, tmp_dir], do: File.mkdir_p!(d)

    on_exit(fn ->
      File.rm_rf!(candidate)
      File.rm_rf!(dir)
    end)

    executable = Path.join(dir, "provider")
    File.write!(executable, @expert_receipt_protocol)
    File.chmod!(executable, 0o755)

    dispatch_log = Path.join(harness_home, "dispatch.log")
    env_log = Path.join(harness_home, "expert-env.log")

    binding = %{
      "harness" => "claude",
      "scope_name" => "shared",
      "scope_path" => scope,
      "runtime_version" => "test",
      "runtime_executable" => executable
    }

    assignment = %{
      "route" => "hybrid",
      "caller" => "developer",
      "harness" => "claude",
      "model" => "claude-opus-5-5",
      "effort" => "high",
      "helpers" => %{
        "scout" => %{"model" => "claude-sonnet-5", "effort" => "low"},
        "worker" => %{"model" => "claude-sonnet-5", "effort" => "medium"}
      },
      "control_root" => control,
      "candidate" => candidate,
      "harness_home" => harness_home,
      "binding" => binding,
      "write_boundary" => %{
        "sha256" => "placeholder",
        "candidate" => candidate,
        "harness_home" => harness_home,
        "tmp_dir" => tmp_dir,
        "control" => control
      }
    }

    base_env = [
      {"KOGEN_EXPERT", Jason.encode!(assignment)},
      {"DISPATCH_LOG", dispatch_log},
      {"ENV_LOG", env_log}
    ]

    {output, status} =
      run_expert_task!(candidate, "Which lock order is safe?", base_env)

    assert status == 0, output
    assert File.exists?(env_log), "the Expert never ran: #{output}"
    receipt = File.read!(env_log)

    assert receipt =~ "PWD=#{candidate}"
    assert receipt =~ "CLAUDE_CONFIG_DIR=#{Path.join(harness_home, "claude")}"
    assert receipt =~ "CLAUDE_SECURESTORAGE_CONFIG_DIR=#{scope}"
    assert receipt =~ "HOME=#{System.get_env("HOME")}"
    assert receipt =~ "KOGEN_HARNESS_HOME=#{harness_home}"

    # A wrong cwd is refused before any launch: the candidate the assignment
    # names does not match this process's own cwd.
    wrong_assignment = %{assignment | "candidate" => Path.join(dir, "elsewhere")}
    File.rm!(env_log)

    {wrong_output, wrong_status} =
      run_expert_task!(candidate, "Which lock order is safe?", [
        {"KOGEN_EXPERT", Jason.encode!(wrong_assignment)},
        {"DISPATCH_LOG", dispatch_log}
      ])

    assert wrong_status != 0
    assert wrong_output =~ "run it from the Build's Candidate"
    refute File.exists?(env_log)
  end

  # `Kogen.CompiledFixture.mix_task!/3` plus one `-e`: a documented core
  # defect (see this packet's report) makes a *completely fresh* `mix
  # kogen.expert` process -- exactly how the real task always starts, since
  # native Claude Code/Codex invoke it as a brand-new OS process -- crash in
  # `Kogen.Harness.binding_from_record/1` (`String.to_existing_atom/1` on a
  # scope name no code path has interned yet). Pre-loading the two modules
  # that define `:shared`/`:project` works around it here so the rest of this
  # test's real assertions (bound scope, harness home, cwd refusal) can run;
  # it does not touch the behavior under test.
  defp run_expert_task!(fixture, question, env, prefix \\ []) do
    env = Kogen.CompiledFixture.offline_jev_env(env) ++ env

    ebins =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.filter(
        &(Path.type(&1) == :absolute and Path.basename(&1) == "ebin" and File.dir?(&1))
      )
      |> Enum.sort()

    preload = "Code.ensure_loaded!(Kogen.ClaudeCode); Code.ensure_loaded!(Kogen.Codex.State)"

    [cmd | args] =
      prefix ++
        ["elixir", "--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++
        Enum.flat_map(ebins, &["-pa", &1]) ++
        ["-e", preload, "-S", "mix", "kogen.expert", question]

    System.cmd(
      cmd,
      args,
      cd: fixture,
      env: [{"MIX_BUILD_PATH", Path.join(fixture, "_build")} | env],
      stderr_to_stdout: true
    )
  end

  # Scenario `codex-roles-inside-boundary`: the Codex Expert `mix kogen.expert`
  # starts from the Developer's tree runs inside the Developer's own profile
  # (`inherited`), never re-applies one, takes no Codex lease (the Build
  # controller already holds it) and writes nothing under Kogen's Codex state
  # root -- no `active/` lease and no `operations/` dir there -- since its
  # operation root lives under the harness home. This exercises the managed
  # open path (`KOGEN_HARNESS` skips leases entirely) inside a real, already
  # -applied outer `sandbox-exec` profile standing in for the enclosing Build.
  #
  # KNOWN CORE DEFECT (reported, not fixed here -- see this packet's report):
  # `Kogen.Codex.close/1` (lib/kogen/codex.ex:157) unconditionally matches
  # `%{lease: lease}` and calls `File.rm(lease)`; when a launch sets
  # `lease: false` (every cross-harness Codex Expert consultation,
  # lib/mix/tasks/kogen.expert.ex:150), `lease` is `nil` and `File.rm(nil)`
  # raises `FunctionClauseError` in `IO.chardata_to_string/1` from inside
  # `Mix.Tasks.Kogen.Expert.launch/4`'s `after` clause
  # (lib/mix/tasks/kogen.expert.ex:246), right after a successful answer --
  # so this test currently fails at `assert status == 0`. Fix proposal: add
  # `def close(%{lease: nil}), do: :ok` before the existing clause.
  @tag :unconfined
  test "the Codex Expert's managed launch runs inherited inside the enclosing profile and touches no Codex state root" do
    source = File.cwd!()

    candidate =
      source
      |> Kogen.CompiledFixture.create!("expert-codex-candidate")
      |> Workspace.canonical()

    File.mkdir_p!(Path.join(candidate, "priv/kogen/prompts"))

    File.cp!(
      Path.join(source, "priv/kogen/prompts/expert.md"),
      Path.join(candidate, "priv/kogen/prompts/expert.md")
    )

    dir =
      Path.join(
        System.tmp_dir!(),
        "kogen-expert-codex-build-#{System.unique_integer([:positive])}"
      )

    codex_root = Path.join(dir, "codex-root")
    harness_home = Path.join(dir, "harness-home")
    control = Path.join(dir, "control")
    tmp_dir = Path.join(dir, "tmp")
    for d <- [codex_root, harness_home, control, tmp_dir], do: File.mkdir_p!(d)

    on_exit(fn ->
      File.rm_rf!(candidate)
      File.rm_rf!(dir)
    end)

    {install_output, install_status} =
      System.cmd(
        "python3",
        [
          Path.join(source, "test/support/managed_codex_fixture.py"),
          codex_root,
          Path.join(source, "priv/kogen/codex/install.py")
        ],
        stderr_to_stdout: true
      )

    assert install_status == 0, install_output
    trace_path = Path.join(harness_home, "codex-trace.jsonl")

    scope = Path.join([codex_root, "accounts", "shared"])
    State.ensure_scope!(scope)
    File.write!(Path.join(scope, "auth.json"), "shared-account")

    # Scenario `codex-roles-inside-boundary`: the scope is pre-seeded (here,
    # by one unconfined readiness probe, exactly like the real Build
    # controller's own binding/readiness call before any role launches)
    # with its deterministic bookkeeping files (`environments.toml`,
    # `agents/kogen_boundary.toml`) *before* the boundary is applied, because
    # those exact names are in the boundary's denied set: a role running
    # inside the boundary must never create or change them.
    with_env([{"KOGEN_CODEX_ROOT", codex_root}, {"KOGEN_TEST_NATIVE_TRACE", trace_path}], fn ->
      System.delete_env("KOGEN_HARNESS")
      assert {:ok, priming} = Kogen.Codex.open(%{harness: "codex"}, candidate)
      Kogen.Codex.close(priming)
    end)

    assert File.regular?(Path.join(scope, "environments.toml"))

    active_before = Path.wildcard(Path.join([codex_root, "active", "*"]))
    operations_before = Path.wildcard(Path.join([codex_root, "operations", "*"]))

    # The enclosing Build's own boundary: rendered and applied for real, then
    # wrapped around the whole `mix kogen.expert` subprocess, standing in for
    # the Developer's already-confined process tree. Scenario
    # `codex-roles-inside-boundary`: the Build-wide profile also grants the
    # Codex scope, so the Expert's own login/environment bookkeeping there
    # (never its operation root, which lives under the harness home) succeeds.
    assert {:ok, enclosing} =
             WriteBoundary.prepare(%{
               candidate: candidate,
               harness_home: harness_home,
               tmp_dir: tmp_dir,
               control: control,
               codex_scope: scope
             })

    codex_binding =
      with_env([{"KOGEN_CODEX_ROOT", codex_root}, {"KOGEN_TEST_NATIVE_TRACE", trace_path}], fn ->
        System.delete_env("KOGEN_HARNESS")
        Kogen.Codex.bind(candidate)
      end)

    assert {:ok, binding} = codex_binding
    binding_record = Kogen.Harness.binding_record(binding)

    assignment = %{
      "route" => "hybrid",
      "caller" => "developer",
      "harness" => "codex",
      "model" => "gpt-6-sol",
      "effort" => "high",
      "helpers" => %{
        "scout" => %{"model" => "gpt-6-luna", "effort" => "low"},
        "worker" => %{"model" => "gpt-6-luna", "effort" => "high"}
      },
      "control_root" => control,
      "candidate" => candidate,
      "harness_home" => harness_home,
      "binding" => binding_record,
      "write_boundary" => %{
        "sha256" => "placeholder",
        "candidate" => candidate,
        "harness_home" => harness_home,
        "tmp_dir" => tmp_dir,
        "control" => control
      }
    }

    env = [
      {"KOGEN_EXPERT", Jason.encode!(assignment)},
      {"KOGEN_CODEX_ROOT", codex_root},
      {"KOGEN_TEST_NATIVE_TRACE", trace_path},
      {WriteBoundary.marker(), enclosing.sha256}
    ]

    prefix = WriteBoundary.prefix(enclosing)

    {output, status} =
      run_expert_task!(candidate, "Which lock order is safe?", env, prefix)

    assert status == 0, output

    launches =
      harness_home
      |> Path.join("raw-log/expert-launches.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert [%{"role" => "expert", "harness" => "codex", "boundary" => "inherited"}] = launches

    assert Path.wildcard(Path.join([codex_root, "active", "*"])) == active_before
    assert Path.wildcard(Path.join([codex_root, "operations", "*"])) == operations_before
  end

  defp with_env(env, fun) do
    previous = Enum.map(env, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(env, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "every Codex launch overrides a hostile inherited role" do
    dir = Path.join(System.tmp_dir!(), "kogen roles-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    executable = Path.join(dir, "provider")
    log = Path.join(dir, "roles")
    raw_log_dir = Path.join(dir, "raw-streams")

    original =
      Map.new(["KOGEN_ROLE", "KOGEN_HARNESS", "ROLE_LOG", "KOGEN_RAW_LOG_DIR"], fn key ->
        {key, System.get_env(key)}
      end)

    on_exit(fn ->
      Enum.each(original, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    File.write!(executable, """
    #!/bin/sh
    printf '%s\\n' "$KOGEN_ROLE" >> "$ROLE_LOG"
    out=; prev=
    for a in "$@"; do [ "$prev" = --output-last-message ] && out="$a"; prev="$a"; done
    case "$KOGEN_ROLE" in
      developer) cat >/dev/null || true; printf '%s\\n' '{"type":"thread.started","thread_id":"dev"}' '{"type":"turn.completed","thread_id":"dev"}' ;;
      reviewer) cat >/dev/null || true; printf '%s\\n' '{"candidate_id":"fixture-candidate","attempt_token":"fixture-attempt","verdict":"accept","scenarios":[],"dispositions":[],"findings":[]}' > "$out"; printf '%s\\n' '{"type":"thread.started","thread_id":"review"}' '{"type":"turn.completed","thread_id":"review"}' ;;
      shaper)
        [ "$KOGEN_REQUIRE_TTY" != 1 ] || test -t 0 || exit 31
        case "${KOGEN_SHAPER_BEHAVIOR:-success}" in
          early) exit 23 ;;
          missing) sleep 60 ;;
        esac
        sleep "${KOGEN_START_DELAY:-0}"
        : > "$KOGEN_READY_MARKER"
        case "${KOGEN_SHAPER_BEHAVIOR:-success}" in
          eof) cat >/dev/null ;;
          background-success)
            python3 -c 'import os, subprocess; p = subprocess.Popen(["sleep", "60"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True); open(os.environ["KOGEN_DESCENDANT_PID"], "w").write(str(p.pid))'
            sleep 0.5
            ;;
          background-failure)
            python3 -c 'import os, subprocess; p = subprocess.Popen(["sleep", "60"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True); open(os.environ["KOGEN_DESCENDANT_PID"], "w").write(str(p.pid))'
            sleep 0.5
            exit 29
            ;;
        esac
        ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("ROLE_LOG", log)
    System.put_env("KOGEN_RAW_LOG_DIR", raw_log_dir)
    System.put_env("KOGEN_ROLE", "reviewer")
    context = %{harness: "codex", executable: executable, args: [], env: []}
    assert {:ok, _} = Kogen.Harness.launch_developer("test", "fake", "low", [], context)
    assert {:ok, _} = Kogen.Harness.resume_developer("dev", "test", "fake", "low", [], context)
    System.put_env("KOGEN_ROLE", "developer")
    assert {:ok, _} = Kogen.Harness.launch_reviewer("test", "fake", "low", context)
    assert [verdict_path] = Path.wildcard(Path.join(raw_log_dir, "reviewer-verdict-*.json"))

    assert File.read!(verdict_path) ==
             "{\"candidate_id\":\"fixture-candidate\",\"attempt_token\":\"fixture-attempt\",\"verdict\":\"accept\",\"scenarios\":[],\"dispositions\":[],\"findings\":[]}\n"

    assert File.read!(Path.join(raw_log_dir, "reviewer-verdicts.jsonl")) ==
             "{\"attempt_token\":\"fixture-attempt\",\"candidate_id\":\"fixture-candidate\",\"dispositions\":[],\"findings\":[],\"scenarios\":[],\"session_id\":\"review\",\"verdict\":\"accept\"}\n"

    prompt = Path.join(dir, "prompt")
    File.write!(prompt, "shape")
    probe = Path.expand("../support/terminal_probe.py", __DIR__)
    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    shaper_context = %{harness: "codex", executable: executable, args: [], env: []}

    expression =
      "System.halt(Kogen.Harness.exec_shaper(\"fake\", \"low\", #{inspect(prompt)}, #{inspect(shaper_context)}))"

    command = [elixir, "--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++ code_paths ++ ["-e", expression]

    for mode <- ["pipe", "pty"], behavior <- terminal_behaviors() do
      {output, status, pid_path} =
        run_shaper_probe(probe, command, executable, log, dir, mode, behavior)

      assert_terminal_outcome(behavior, "#{mode} #{behavior}: #{output}", status)

      if pid_path do
        pid = pid_path |> File.read!() |> String.trim()
        assert {_, kill_status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
        assert kill_status != 0, "#{mode} #{behavior} descendant #{pid} survived cleanup"
      end
    end

    roles = log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.take(roles, 3) == ["developer", "developer", "reviewer"]
    assert Enum.count(roles, &(&1 == "shaper")) == 12
  end

  test "a hybrid route launches each role only through its assigned harness and profile" do
    dir = Path.join(System.tmp_dir!(), "kogen-hybrid-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    executable = Path.join(dir, "provider")
    log = Path.join(dir, "dispatch")
    File.write!(executable, @dual_protocol)
    File.chmod!(executable, 0o755)
    config_path = Path.join(dir, "config.yaml")
    File.write!(config_path, @hybrid_config)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("DISPATCH_LOG", log)
    private_claude_scope!(dir)
    System.delete_env("KOGEN_RAW_LOG_DIR")
    # An inherited Developer verification context must never reach an Expert.
    System.put_env("KOGEN_VERIFICATION_CONTEXT", "/inherited/context")

    {:ok, config} = Kogen.Intent.read_config(config_path)

    assert {:ok, runtime} =
             Kogen.Harness.open_roles(config, [:developer, :reviewer, :expert], dir)

    assert runtime.selections |> Map.keys() |> Enum.sort() == ["claude", "codex"]

    developer = Kogen.Harness.role_context(runtime, :developer)
    reviewer = Kogen.Harness.role_context(runtime, :reviewer)
    assert developer.harness == "claude"
    assert reviewer.harness == "codex"

    # The dominant Developer carries the frozen Codex Expert assignment; its
    # native Claude Code helpers exclude any substituted expert.
    {"KOGEN_EXPERT", json} = List.keyfind(developer.env, "KOGEN_EXPERT", 0)

    assert Jason.decode!(json) == %{
             "route" => "hybrid",
             "caller" => "developer",
             "harness" => "codex",
             "model" => "gpt-6-sol",
             "effort" => "high",
             "helpers" => %{
               "scout" => %{"model" => "gpt-6-luna", "effort" => "low"},
               "worker" => %{"model" => "gpt-6-luna", "effort" => "high"}
             }
           }

    assert List.keyfind(reviewer.env, "KOGEN_EXPERT", 0) == {"KOGEN_EXPERT", nil}

    developer_args =
      Claude.developer_args("claude-opus-5-5", "medium", developer, {:fresh, "s"})

    agents = developer_args |> after_flag("--agents") |> Jason.decode!()
    assert agents |> Map.keys() |> Enum.sort() == ["kogen-scout", "kogen-worker"]
    assert agents["kogen-scout"]["model"] == "claude-sonnet-5"
    assert "--dangerously-skip-permissions" in developer_args
    assert after_flag(developer_args, "--model") == "claude-opus-5-5"
    assert after_flag(developer_args, "--effort") == "medium"

    # The Expert role itself launches on Codex with Codex's unattended flags.
    assignment = Expert.assignment(json)
    assert {:ok, %{harness: "codex", expert: %{model: "gpt-6-sol", effort: "high"}}} = assignment
    {:ok, expert_config} = assignment

    assert {:ok, %{session_id: "codex-expert", message: "codex expert answer"}} =
             Expert.launch(expert_config, "Which lock order is safe?", dir)

    assert_raise ArgumentError, ~r/role shaping was not opened/, fn ->
      Kogen.Harness.role_context(runtime, :shaping)
    end

    Kogen.Harness.close(runtime)

    # The codex-dominant route's Expert runs on Claude Code, read-only, with
    # only Claude Code native helpers and no nested expert.
    claude_expert = %{
      route: "hybrid",
      caller: "developer",
      harness: "claude",
      expert: %{model: "claude-opus-5-5", effort: "high"},
      helpers: %{
        scout: %{model: "claude-sonnet-5", effort: "low"},
        worker: %{model: "claude-sonnet-5", effort: "medium"}
      },
      roles: %{expert: "claude"},
      native_helpers: %{
        "claude" => %{
          scout: %{model: "claude-sonnet-5", effort: "low"},
          worker: %{model: "claude-sonnet-5", effort: "medium"}
        }
      }
    }

    {:ok, claude_selection} = Kogen.Harness.open(claude_expert, dir)
    claude_context = Kogen.Harness.launch_context(claude_selection)

    assert {:ok, %{message: "claude expert answer"}} =
             Kogen.Harness.launch_expert("question", "claude-opus-5-5", "high", claude_context)

    # A provider answering from another model is a failure, never a fallback.
    System.put_env("FAKE_ROOT_MODEL", "claude-sonnet-5")

    assert {:error,
            {:root_model_mismatch, %{expected: "claude-opus-5-5", actual: "claude-sonnet-5"}}} =
             Kogen.Harness.launch_expert("question", "claude-opus-5-5", "high", claude_context)

    entries = log |> File.read!() |> String.split("argv:", trim: true)
    [codex_expert] = Enum.filter(entries, &String.starts_with?(&1, " exec "))
    claude_launch = Enum.find(entries, &String.starts_with?(&1, " -p "))

    assert codex_expert =~
             ~s(exec --model gpt-6-sol -c model_reasoning_effort="high" --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --json -)

    assert codex_expert =~ "KOGEN_ROLE=expert KOGEN_EXPERT=unset KOGEN_VERIFICATION_CONTEXT=unset"

    assert claude_launch =~ "--model claude-opus-5-5 --effort high --dangerously-skip-permissions"
    assert claude_launch =~ "Agent(general-purpose)"
    assert claude_launch =~ " Edit Write NotebookEdit "
    assert claude_launch =~ "kogen-scout"
    refute claude_launch =~ "kogen-expert"

    assert claude_launch =~
             "KOGEN_ROLE=expert KOGEN_EXPERT=unset KOGEN_VERIFICATION_CONTEXT=unset"
  end

  # Expert launches reuse the prepared launch context: its arguments (which
  # carry the central tool_output_token_limit, see codex_environment_test)
  # and environment precede the role's own flags.
  test "Codex Expert launches run from the prepared launch context" do
    dir = Path.join(System.tmp_dir!(), "kogen-prepared-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    executable = Path.join(dir, "provider")
    log = Path.join(dir, "dispatch")
    File.write!(executable, @dual_protocol)
    File.chmod!(executable, 0o755)
    System.put_env("DISPATCH_LOG", log)
    System.put_env("KOGEN_EXPERT", ~s({"inherited":true}))
    System.put_env("KOGEN_VERIFICATION_CONTEXT", "/inherited/context")

    prepared = ["--disable", "apps", "-c", "tool_output_token_limit=4000"]

    context = %{
      harness: "codex",
      executable: executable,
      args: prepared,
      env: [{"DISPATCH_LOG", log}]
    }

    assert {:ok, %{session_id: "codex-expert"}} =
             Kogen.Harness.launch_expert("q", "gpt-6-sol", "high", context)

    [expert] = log |> File.read!() |> String.split("argv:", trim: true)

    assert expert =~
             ~s( --disable apps -c tool_output_token_limit=4000 exec --model gpt-6-sol -c model_reasoning_effort="high" --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --json -)

    assert expert =~
             "KOGEN_ROLE=expert KOGEN_EXPERT=unset KOGEN_VERIFICATION_CONTEXT=unset"
  end

  test "a harness that is not ready names its roles and releases held selections" do
    dir = Path.join(System.tmp_dir!(), "kogen-unready-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    executable = Path.join(dir, "provider")
    File.write!(executable, @dual_protocol)
    File.chmod!(executable, 0o755)
    System.put_env("KOGEN_HARNESS", executable)
    System.put_env("DISPATCH_LOG", Path.join(dir, "dispatch"))
    private_claude_scope!(dir)

    {:ok, config} =
      Kogen.Intent.read_config(".kogen/config.yaml", "claude-dominant-adversarial-codex")

    broken = put_in(config, [:roles, :reviewer], "pi")

    assert {:error,
            "reviewer harness pi is not ready: unsupported harness: \"pi\"; expected codex or claude"} =
             Kogen.Harness.open_roles(broken, [:developer, :reviewer, :expert])

    assert {:error, reason} = Expert.assignment(nil)
    assert reason =~ "missing KOGEN_EXPERT assignment"
    assert {:error, reason} = Expert.assignment(~s({"harness":"pi"}))
    assert reason =~ "invalid KOGEN_EXPERT assignment"
  end

  test "no harness exposes an auditor launch" do
    Code.ensure_loaded(Kogen.Harness)
    Code.ensure_loaded(Kogen.Harness.Claude)
    Code.ensure_loaded(Kogen.Harness.Codex)

    refute function_exported?(Kogen.Harness, :launch_auditor, 4)
    refute function_exported?(Kogen.Harness.Claude, :launch_auditor, 4)
    refute function_exported?(Kogen.Harness.Codex, :launch_auditor, 4)

    assert Kogen.Intent.roles() == [:shaping, :developer, :reviewer, :expert]
    config = %{harness: "claude"}

    assert_raise ArgumentError, ~r/unknown role :auditor/, fn ->
      Kogen.Harness.open_roles(config, [:auditor])
    end

    assert_raise ArgumentError, ~r/unknown role :auditor/, fn ->
      Kogen.Intent.role_config(config, :auditor)
    end
  end

  defp private_claude_scope!(dir) do
    root = Path.join(dir, "claude-root")
    File.mkdir_p!(Path.join(root, "accounts/shared"))
    System.put_env("KOGEN_CLAUDE_ROOT", root)
  end

  defp after_flag(args, flag) do
    index = Enum.find_index(args, &(&1 == flag))
    Enum.at(args, index + 1)
  end

  defp terminal_behaviors do
    [:success, :eof, :early, :missing, :background_success, :background_failure]
  end

  defp run_shaper_probe(probe, command, executable, log, dir, mode, behavior) do
    marker = Path.join(dir, "ready-#{mode}-#{behavior}")

    pid_path =
      if behavior in [:background_success, :background_failure],
        do: Path.join(dir, "descendant-#{mode}-#{behavior}.pid")

    startup_timeout = if behavior == :missing, do: "5", else: "15"
    completion_timeout = if behavior == :eof, do: "0.3", else: "5"

    ownership_args = if pid_path, do: ["--owned-pid-file", pid_path], else: []

    {output, status} =
      System.cmd(
        "python3",
        [
          probe,
          "--mode",
          mode,
          "--startup-timeout",
          startup_timeout,
          "--timeout",
          completion_timeout,
          "--ready-marker",
          marker
        ] ++ ownership_args ++ ["--" | command],
        env: [
          {"KOGEN_HARNESS", executable},
          {"ROLE_LOG", log},
          {"KOGEN_START_DELAY", "0.1"},
          {"KOGEN_SHAPER_BEHAVIOR", behavior |> Atom.to_string() |> String.replace("_", "-")},
          {"KOGEN_DESCENDANT_PID", pid_path},
          {"KOGEN_REQUIRE_TTY", if(mode == "pty", do: "1", else: "0")}
        ],
        stderr_to_stdout: true
      )

    {output, status, pid_path}
  end

  defp assert_terminal_outcome(:success, output, status) do
    assert status == 0, output
  end

  defp assert_terminal_outcome(:eof, output, status) do
    assert status == 1
    assert output =~ "did not complete after readiness deadline"
  end

  defp assert_terminal_outcome(:early, output, status) do
    assert status == 1
    assert output =~ "exited before readiness (status 23)"
  end

  defp assert_terminal_outcome(:missing, output, status) do
    assert status == 1
    assert output =~ "did not become ready before startup deadline"
  end

  defp assert_terminal_outcome(:background_success, output, status) do
    assert status == 0, output
  end

  defp assert_terminal_outcome(:background_failure, output, status) do
    assert status == 1
    assert output =~ "command exited with status 29"
  end
end
