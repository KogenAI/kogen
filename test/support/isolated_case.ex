defmodule Kogen.IsolatedCase do
  @moduledoc false
  alias Kogen.IsolatedCase.Pool

  # Tests which change the VM's cwd or environment cannot safely share the
  # outer ExUnit VM.  The parent test below is deliberately only a dispatcher:
  # the original test source is loaded again in a fresh VM, where this module
  # becomes a normal ExUnit.Case.
  @child_marker "KOGEN_ISOLATED_CASE_CHILD"
  @ready_message "KOGEN_ISOLATED_READY\n"
  @target_evidence_prefix "KOGEN_TARGET_EVIDENCE_MANIFEST\t"
  @completion_prefix "KOGEN_ISOLATED_COMPLETION\t"
  @completion_version 1
  @default_timeout 120_000
  @cached_parameter_marker {:kogen_isolated_dynamic, :template}

  def cached_parameter_marker, do: @cached_parameter_marker

  defmacro __using__(options) do
    options = Keyword.put(options, :async, true)
    target_evidence = Keyword.get(options, :target_evidence)
    exunit_options = Keyword.delete(options, :target_evidence)

    if System.get_env(@child_marker) == "1" do
      quote do
        use ExUnit.Case, Kogen.IsolatedCase.child_case_options(unquote(exunit_options))
      end
    else
      quote do
        @kogen_isolated_target_evidence unquote(target_evidence)
        use ExUnit.Case, unquote(exunit_options)
        import ExUnit.Case, except: [test: 2, test: 3]
        import Kogen.IsolatedCase, only: [test: 2, test: 3]

        setup_all isolated_context do
          Kogen.IsolatedCase.pool_context(__MODULE__, isolated_context, unquote(target_evidence))
        end
      end
    end
  end

  defmacro test(message, contents) do
    dispatch_test(message, quote(do: _), contents, __CALLER__)
  end

  defmacro test(message, context, contents) do
    dispatch_test(message, context, contents, __CALLER__)
  end

  defp dispatch_test(message, context, contents, caller) do
    source = Path.expand(caller.file)
    body = Keyword.fetch!(contents, :do)
    target_evidence = Module.get_attribute(caller.module, :kogen_isolated_target_evidence)

    quote do
      ExUnit.Case.test unquote(message), isolated_context do
        case isolated_context do
          unquote(context) ->
            # Keep the source body in the parent module's lexical analysis so
            # normal compiler warnings remain meaningful, without ever running
            # cwd/env-mutating code in the parent VM.
            if false do
              unquote(body)
            else
              Kogen.IsolatedCase.run_or_await!(
                unquote(source),
                isolated_context.test,
                Kogen.IsolatedCase.dispatch_options(
                  isolated_context,
                  unquote(@default_timeout),
                  unquote(target_evidence),
                  unquote(caller.module)
                ),
                Map.get(isolated_context, :kogen_isolated_pool)
              )
            end
        end
      end
    end
  end

  @doc """
  Runs one trusted test from `source` in a new Elixir VM.

  `selector` is either the test source line (the form used by the macro) or an
  ExUnit test name. It intentionally accepts a source file rather than a
  closure: a closure cannot cross VM boundaries safely.
  """
  @spec run(Path.t(), pos_integer() | String.t() | atom(), keyword() | map()) ::
          {:ok, binary()} | {:error, term(), binary()}
  def run(source, selector, options \\ []) do
    options = normalize_options(options)
    source = Path.expand(source)
    root = Path.expand(System.fetch_env!("KOGEN_TEST_ROOT"))
    options = put_cached_module_option(source, options)
    working_dir = Path.expand(Keyword.get(options, :cd, root))
    timeout = Keyword.get(options, :timeout, @default_timeout)
    readiness = readiness_config(options, timeout)
    tmpdir = private_tmpdir(options)
    notify_pool_root(options, tmpdir)
    invocation = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    binding = %{
      invocation: invocation,
      source: source,
      selector: to_string(selector),
      module: Keyword.get(options, :isolated_module)
    }

    readiness = if readiness, do: Map.put(readiness, :path, Path.join(tmpdir, "readiness"))

    if File.dir?(working_dir) do
      supervision = %{
        tmpdir: tmpdir,
        working_dir: working_dir,
        timeout: timeout,
        readiness: readiness,
        binding: binding
      }

      port = start_supervisor(root, source, selector, options, supervision)

      collection_timeout = Keyword.get(options, :collection_timeout, timeout + 2_000)

      {status, output} = collect_with_readiness(port, readiness, collection_timeout)

      # Only after confirmed exit may we reclaim a root whose supervisor never started.
      if File.dir?(tmpdir) and not File.exists?(Path.join(tmpdir, "supervisor-started")) do
        cleanup_unowned_tmpdir(tmpdir)
      end

      # The supervisor alone removes its temporary root, after reaping children.
      # In particular, cancellation must never race parent-side fixture removal.
      isolated_result(status, output, binding)
    else
      cleanup_unowned_tmpdir(tmpdir)
      {:error, {:exit_status, 1}, "working directory does not exist: #{working_dir}"}
    end
  end

  defp start_supervisor(root, source, selector, options, supervision) do
    # Until Port.open/2 succeeds, no supervisor can clean this root. Keep the
    # setup in a separate ownership phase so failed argument or environment
    # preparation does not retain a private fixture.
    args = child_args(root, source, selector)
    env = child_env(options, supervision.tmpdir, supervision.readiness, supervision.binding)

    open_supervisor(
      args,
      supervision.working_dir,
      env,
      supervision.timeout,
      supervision.readiness
    )
  rescue
    exception ->
      cleanup_unowned_tmpdir(supervision.tmpdir)
      reraise exception, __STACKTRACE__
  catch
    kind, reason ->
      cleanup_unowned_tmpdir(supervision.tmpdir)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp isolated_result(0, output, binding) do
    case completion_receipt(output, binding) do
      :ok -> {:ok, output}
      {:error, reason} -> {:error, {:completion_receipt, reason}, output}
    end
  end

  defp isolated_result(124, output, _binding), do: {:error, :timeout, output}
  defp isolated_result(126, output, _binding), do: {:error, :readiness_timeout, output}
  defp isolated_result(:timeout, output, _binding), do: {:error, :timeout, output}
  defp isolated_result(:cancelled, output, _binding), do: {:error, :cancelled, output}

  defp isolated_result({:readiness_exit, status}, output, _binding),
    do: {:error, {:readiness_exit, status}, output}

  defp isolated_result(status, output, _binding), do: {:error, {:exit_status, status}, output}

  defp completion_receipt(output, binding) do
    receipts =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, @completion_prefix))

    with [line] <- receipts,
         [version, invocation, source, selector, status, completed, cleanup] <-
           line |> String.replace_prefix(@completion_prefix, "") |> String.split("\t"),
         {version, ""} <- Integer.parse(version),
         true <- version == @completion_version,
         true <- invocation == binding.invocation,
         {:ok, source} <- Base.decode64(source),
         true <- source == binding.source,
         {:ok, selector} <- Base.decode64(selector),
         true <- selector == binding.selector,
         true <- status == "0",
         true <- completed == "true",
         true <- cleanup == "passed" do
      :ok
    else
      [] -> {:error, :missing}
      [_ | _] -> {:error, :duplicate_or_malformed}
      _ -> {:error, :binding_mismatch}
    end
  end

  @doc false
  def child_case_options(options) do
    case requested_parameters(options) do
      nil ->
        options

      encoded ->
        # This value is generated by the parent dispatcher immediately before
        # spawning this trusted child; `:safe` would reject the test module atom
        # because the source has not been compiled in the fresh VM yet.
        expected = encoded |> Base.decode64!() |> :erlang.binary_to_term()

        parameters =
          Enum.filter(Keyword.fetch!(options, :parameterize), &matches_parameters?(&1, expected))

        Keyword.put(options, :parameterize, parameters)
    end
  end

  defp requested_parameters(options) do
    if Keyword.has_key?(options, :parameterize) and
         System.get_env("KOGEN_ISOLATED_COMPILER") != "1" do
      System.get_env("KOGEN_ISOLATED_PARAMETERS")
    end
  end

  @doc false
  def dispatch_options(context, default_timeout) do
    dispatch_options(context, default_timeout, nil, nil)
  end

  @doc false
  def dispatch_options(context, default_timeout, target_evidence) do
    dispatch_options(context, default_timeout, target_evidence, nil)
  end

  @doc false
  def dispatch_options(context, default_timeout, target_evidence, isolated_module) do
    [:timeout, :collection_timeout, :readiness, :startup_timeout, :target_evidence]
    |> Enum.reduce([parameters: context], fn key, options ->
      case Map.fetch(context, key) do
        {:ok, value} -> Keyword.put(options, key, value)
        :error -> options
      end
    end)
    |> Keyword.put_new(:timeout, default_timeout)
    |> maybe_put_isolated_module(isolated_module)
    |> maybe_put_target_evidence(target_evidence)
  end

  defp maybe_put_isolated_module(options, nil), do: options

  defp maybe_put_isolated_module(options, module),
    do: Keyword.put_new(options, :isolated_module, Atom.to_string(module))

  defp put_cached_module_option(source, options) do
    module =
      Keyword.get(options, :isolated_module) ||
        case System.get_env("KOGEN_ISOLATED_BEAM_MANIFEST") do
          nil ->
            nil

          path ->
            with {:ok, manifest} <- File.read(path),
                 {:ok, decoded} <- Jason.decode(manifest),
                 module when is_binary(module) <- get_in(decoded, ["modules_by_source", source]) do
              module
            else
              _ -> nil
            end
        end

    cache = System.get_env("KOGEN_ISOLATED_BEAM_CACHE")

    if is_binary(module) and is_binary(cache) and
         File.regular?(Path.join(cache, module <> ".beam")) do
      Keyword.put(options, :isolated_module, module)
    else
      Keyword.delete(options, :isolated_module)
    end
  end

  defp maybe_put_target_evidence(options, nil), do: options

  defp maybe_put_target_evidence(options, value),
    do: Keyword.put_new(options, :target_evidence, value)

  defp matches_parameters?(parameter, expected) do
    Enum.all?(parameter, fn
      {:template, @cached_parameter_marker} -> Map.has_key?(expected, :template)
      {key, value} -> Map.get(expected, key) == value
    end)
  end

  @doc false
  def pool_context(module, context, target_evidence) do
    pool = start_pool(module, context, target_evidence)
    if pool, do: ExUnit.Callbacks.on_exit(fn -> stop_pool(pool) end)
    %{kogen_isolated_pool: pool}
  end

  @doc false
  def start_pool(module, context, target_evidence) do
    if System.get_env("KOGEN_WARM_POOL") == "1" and
         System.get_env(@child_marker) != "1" do
      jobs =
        module
        |> selected_pool_tests(context)
        |> Enum.map(fn test ->
          test_context = context |> Map.merge(test.tags) |> Map.put(:test, test.name)

          {test.name, test.tags.file,
           dispatch_options(test_context, @default_timeout, target_evidence, module)}
        end)

      if jobs == [], do: nil, else: Pool.register(jobs)
    end
  end

  defp selected_pool_tests(module, context) do
    config = ExUnit.configuration() |> Map.new()
    tests = module.__ex_unit__().tests

    Enum.filter(tests, fn test ->
      tags =
        Map.merge(test.tags, %{
          test: test.name,
          module: module,
          async: Map.get(context, :async, true),
          test_group: Map.get(context, :test_group)
        })

      (is_nil(config[:only_test_ids]) or
         MapSet.member?(config[:only_test_ids], {module, test.name})) and
        ExUnit.Filters.eval(config[:include] || [], config[:exclude] || [], tags, tests) == :ok
    end)
  end

  @doc false
  def stop_pool(pool) do
    :ok = Pool.cancel(pool)
  end

  @doc false
  def run_or_await!(source, selector, options, nil), do: run!(source, selector, options)

  def run_or_await!(source, selector, options, pool) do
    required? = Keyword.get(options, :target_evidence) == :required

    result =
      Pool.await(
        pool,
        selector,
        Keyword.get(options, :timeout, @default_timeout)
      )

    assert_result!(source, selector, result, required?)
  end

  @doc false
  def run!(source, selector, options \\ []) do
    options = normalize_options(options)
    required? = Keyword.get(options, :target_evidence) == :required
    assert_result!(source, selector, run(source, selector, options), required?)
  end

  defp assert_result!(source, selector, result, required?) do
    case result do
      {:ok, output} ->
        if System.get_env("KOGEN_PROFILE_ISOLATED") == "1" do
          output
          |> String.split("\n")
          |> Enum.filter(
            &(String.starts_with?(&1, "KOGEN_ISOLATED_TIMING\t") or
                String.starts_with?(&1, "KOGEN_ISOLATED_PHASE\t"))
          )
          |> Enum.each(&IO.puts/1)
        end

        frames = target_evidence_frames(output)
        forward_target_evidence(frames)

        if required? and frames == [] do
          raise ExUnit.AssertionError,
            message: "isolated test #{source}:#{selector} produced no target evidence manifest"
        end

        :ok

      {:error, reason, output} ->
        # Forwarding is best-effort and happens before raising only so a
        # successful child can expose its structured evidence. It must never
        # replace the child's status or cleanup error.
        output |> target_evidence_frames() |> forward_target_evidence()

        # The frame was forwarded once above; echoing it again in the failure
        # message would make the target's one manifest frame a duplicate.
        raise ExUnit.AssertionError,
          message:
            "isolated test #{source}:#{selector} failed (#{inspect(reason)})\n#{without_target_evidence_frames(output)}"
    end
  end

  defp target_evidence_frames(output) do
    lines = :binary.split(output, "\n", [:global])
    complete_lines = if String.ends_with?(output, "\n"), do: lines, else: Enum.drop(lines, -1)

    complete_lines
    |> Enum.flat_map(fn line ->
      case :binary.match(line, @target_evidence_prefix) do
        {offset, _length} ->
          [binary_part(line, offset, byte_size(line) - offset) <> "\n"]

        :nomatch ->
          []
      end
    end)
  end

  defp without_target_evidence_frames(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&String.contains?(&1, @target_evidence_prefix))
    |> Enum.join("\n")
  end

  defp forward_target_evidence(frames) do
    Enum.each(frames, fn frame ->
      try do
        IO.write(frame)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  end

  @doc false
  def child_run!(helper, source, selector) do
    phase_started = System.monotonic_time(:millisecond)
    Code.require_file(helper)
    helper_loaded = System.monotonic_time(:millisecond)
    # `include` alone adds a matching test but leaves untagged tests eligible.
    # Every ExUnit test has the special `:test` tag, so exclude that universe
    # first and let the exact selector opt one test back in.
    ExUnit.configure(exclude: [:test], include: selector_filter(selector))

    case System.get_env("KOGEN_ISOLATED_MODULE") do
      module_name when is_binary(module_name) and module_name != "" ->
        module = String.to_atom(module_name)

        case Code.ensure_loaded(module) do
          {:module, ^module} ->
            config = filter_cached_parameters(module.__ex_unit__(:config))
            ExUnit.Server.add_module(module, config)

          _ ->
            raise "cached isolated test module could not be loaded: #{module_name}"
        end

      _ ->
        Code.require_file(source)
    end

    source_loaded = System.monotonic_time(:millisecond)

    status =
      case ExUnit.run() do
        %{failures: 0, total: total, excluded: excluded, skipped: 0}
        when total - excluded == 1 ->
          0

        result ->
          IO.puts(:stderr, "expected exactly one passing isolated test: #{inspect(result)}")
          1
      end

    if System.get_env("KOGEN_PROFILE_ISOLATED") == "1" do
      IO.puts(
        "KOGEN_ISOLATED_PHASE\t" <>
          Jason.encode!(%{
            source: source,
            selector: to_string(selector),
            helper_ms: helper_loaded - phase_started,
            source_ms: source_loaded - helper_loaded,
            test_ms: System.monotonic_time(:millisecond) - source_loaded
          })
      )
    end

    # Keep the VM alive until the owner has found and reaped any OS children.
    result_path = System.fetch_env!("KOGEN_ISOLATED_RESULT")

    receipt =
      [
        @completion_version,
        System.fetch_env!("KOGEN_ISOLATED_INVOCATION"),
        Base.encode64(System.fetch_env!("KOGEN_ISOLATED_SOURCE")),
        Base.encode64(System.fetch_env!("KOGEN_ISOLATED_SELECTOR")),
        status,
        "true"
      ]
      |> Enum.join("\n")

    File.write!(result_path <> ".tmp", receipt <> "\n", [:exclusive])
    File.rename!(result_path <> ".tmp", result_path)
    await_cleanup(result_path <> ".ack", status)
  end

  defp filter_cached_parameters(%{parameterize: parameters} = config) when is_list(parameters) do
    case System.get_env("KOGEN_ISOLATED_PARAMETERS") do
      nil ->
        config

      encoded ->
        expected = encoded |> Base.decode64!() |> :erlang.binary_to_term()

        selected =
          parameters
          |> Enum.filter(&matches_parameters?(&1, expected))
          |> Enum.map(&restore_cached_parameter(&1, expected))

        %{config | parameterize: selected}
    end
  end

  defp filter_cached_parameters(config), do: config

  defp restore_cached_parameter(parameter, expected) do
    if Map.get(parameter, :template) == @cached_parameter_marker do
      Map.put(parameter, :template, Map.fetch!(expected, :template))
    else
      parameter
    end
  end

  defp await_cleanup(path, status) do
    if File.exists?(path) do
      System.halt(status)
    else
      Process.sleep(5)
      await_cleanup(path, status)
    end
  end

  defp selector_filter(selector) when is_integer(selector), do: [line: selector]
  defp selector_filter(selector) when is_atom(selector), do: [test: selector]
  defp selector_filter(selector), do: [test: String.to_atom(selector)]

  defp child_args(root, source, selector) do
    helper = Path.join(root, "test/test_helper.exs")

    code =
      "Kogen.IsolatedCase.child_run!(#{inspect(helper)}, #{inspect(source)}, #{inspect(selector)})"

    ["+S", "1:1", "+SDcpu", "1", "+SDio", "1", "-noshell"] ++
      cache_code_path() ++
      Enum.flat_map(code_paths(), fn path -> ["-pa", path] end) ++
      ["-s", "elixir", "start_cli", "-extra", "-e", code]
  end

  defp cache_code_path do
    case System.get_env("KOGEN_ISOLATED_BEAM_CACHE") do
      path when is_binary(path) and path != "" -> ["-pa", path]
      _ -> []
    end
  end

  defp code_paths do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&(Path.type(&1) == :absolute))
    |> Enum.uniq()
  end

  @doc """
  Offline Jev defaults for every isolated child: a Keychain lookup and a Jev
  transport that replays or synthesizes answers without any network access.
  A test's own `:env` entries, or its own `System.put_env/2`, still override.
  """
  def offline_jev_env do
    root = System.fetch_env!("KOGEN_TEST_ROOT")

    [
      {"KOGEN_JEV_TRANSPORT", Path.join(root, "test/support/fake_jev")},
      {"KOGEN_JEV_SECURITY", Path.join(root, "test/support/fake_security")}
    ]
  end

  defp child_env(options, tmpdir, readiness, binding) do
    configured =
      options
      |> Keyword.get(:env, [])
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)

    configured =
      case readiness do
        nil ->
          configured

        %{env: readiness_env} ->
          Enum.reject(configured, fn {key, _value} -> key == readiness_env end)
      end

    parameter_env =
      case Keyword.get(options, :parameters) do
        parameters when is_map(parameters) ->
          [
            {"KOGEN_ISOLATED_PARAMETERS",
             parameters |> :erlang.term_to_binary() |> Base.encode64()}
          ]

        _ ->
          []
      end

    readiness_env =
      case readiness do
        nil -> []
        %{env: key, path: path} -> [{key, path}]
      end

    # Isolated children still use the repository's explicitly provisioned
    # toolchain. Without PATH they fall back to the host /usr/bin/python3,
    # which can be older than Kogen's declared Python 3.11 baseline.
    ([
       {@child_marker, "1"},
       {"ROOTDIR", List.to_string(:code.root_dir())},
       {"BINDIR", erts_bin()},
       {"EMU", "beam"},
       {"PROGNAME", "erl"},
       {"PATH", System.fetch_env!("PATH")},
       {"KOGEN_TEST_PYTHON_BIN", System.fetch_env!("KOGEN_TEST_PYTHON_BIN")},
       {"DYLD_INSERT_LIBRARIES", System.fetch_env!("KOGEN_TEST_PROCESS_GUARD")},
       {"TMPDIR", tmpdir},
       {"TMP", tmpdir},
       {"TEMP", tmpdir},
       {"MIX_BUILD_PATH", Path.join(tmpdir, "_build")},
       {"ERL_CRASH_DUMP", Path.join(tmpdir, "erl_crash.dump")},
       {"KOGEN_ISOLATED_RESULT", Path.join(tmpdir, "result")},
       {"KOGEN_ISOLATED_INVOCATION", binding.invocation},
       {"KOGEN_ISOLATED_SOURCE", binding.source},
       {"KOGEN_ISOLATED_SELECTOR", binding.selector},
       {"KOGEN_ISOLATED_BEAM_CACHE", System.get_env("KOGEN_ISOLATED_BEAM_CACHE", "")},
       {"KOGEN_ISOLATED_BEAM_MANIFEST",
        Path.join(System.get_env("KOGEN_ISOLATED_BEAM_CACHE", ""), "modules.json")}
     ] ++
       if(binding.module, do: [{"KOGEN_ISOLATED_MODULE", binding.module}], else: []) ++
       offline_jev_env() ++ parameter_env ++ configured ++ readiness_env)
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp open_supervisor(args, cd, env, timeout, readiness) do
    executable = System.find_executable("python3") || raise "python3 executable was not found"
    elixir = Path.join(erts_bin(), "erlexec")

    supervisor =
      Path.join(System.fetch_env!("KOGEN_TEST_ROOT"), "test/support/isolated_process.py")

    {startup_timeout, ready_path} =
      case readiness do
        nil -> {0, "-"}
        %{timeout: startup_timeout, path: path} -> {startup_timeout, path}
      end

    args =
      [
        supervisor,
        to_string(timeout / 1_000),
        to_string(startup_timeout / 1_000),
        ready_path,
        elixir
        | args
      ]

    Port.open({:spawn_executable, String.to_charlist(executable)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map(args, &String.to_charlist/1),
      cd: String.to_charlist(cd),
      env: env
    ])
  end

  defp collect_with_readiness(port, nil, collection_timeout) do
    collect_port(port, [], System.monotonic_time(:millisecond) + collection_timeout)
  end

  defp collect_with_readiness(port, readiness, collection_timeout) do
    startup_deadline = System.monotonic_time(:millisecond) + readiness.timeout + 2_000

    case collect_readiness(port, [], startup_deadline) do
      {:ready, output} ->
        collect_port(
          port,
          [output],
          System.monotonic_time(:millisecond) + collection_timeout
        )

      {:exit, 126, output} ->
        {126, output}

      {:exit, status, output} ->
        {{:readiness_exit, status}, output}

      {:timeout, output} ->
        Port.command(port, "cancel")

        {_status, final_output} =
          await_termination(port, [output], System.monotonic_time(:millisecond) + 5_000)

        {126, final_output}
    end
  end

  defp collect_readiness(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:kogen_pool_cancel, _key} ->
        Port.command(port, "cancel")

        {_status, final_output} =
          await_termination(port, output, System.monotonic_time(:millisecond) + 5_000)

        {:exit, :cancelled, final_output}

      {^port, {:data, data}} ->
        accumulated = [data | output] |> Enum.reverse() |> IO.iodata_to_binary()

        if String.contains?(accumulated, @ready_message) do
          {:ready, String.replace(accumulated, @ready_message, "", global: false)}
        else
          collect_readiness(port, [accumulated], deadline)
        end

      {^port, {:exit_status, status}} ->
        {:exit, status, output |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      remaining -> {:timeout, output |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp erts_bin do
    Path.join([
      List.to_string(:code.root_dir()),
      "erts-#{:erlang.system_info(:version)}",
      "bin"
    ])
  end

  defp collect_port(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:kogen_pool_cancel, _key} ->
        Port.command(port, "cancel")

        {_status, final_output} =
          await_termination(port, output, System.monotonic_time(:millisecond) + 5_000)

        {:cancelled, final_output}

      {^port, {:data, data}} ->
        collect_port(port, [data | output], deadline)

      {^port, {:exit_status, status}} ->
        {status, output |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      remaining ->
        # Keep the port open so its exit_status confirms supervisor cleanup.
        Port.command(port, "cancel")
        await_termination(port, output, System.monotonic_time(:millisecond) + 5_000)
    end
  end

  defp await_termination(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        await_termination(port, [data | output], deadline)

      {^port, {:exit_status, 124}} ->
        {:timeout, output |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {status, output |> Enum.reverse() |> IO.iodata_to_binary()}
    after
      remaining ->
        raise "isolated supervisor did not confirm cleanup; its private fixture is retained"
    end
  end

  defp private_tmpdir(options) do
    root = Path.expand(Keyword.get(options, :tmpdir_root, System.tmp_dir!()))

    path =
      Path.join(
        root,
        "kogen-isolated-#{System.pid()}-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    path
  end

  defp notify_pool_root(options, tmpdir) do
    case {Keyword.get(options, :pool_owner), Keyword.get(options, :pool_key)} do
      {owner, key} when is_pid(owner) -> send(owner, {:pool_root, key, tmpdir})
      _ -> :ok
    end
  end

  defp readiness_config(options, timeout) do
    case Keyword.get(options, :readiness) do
      nil ->
        nil

      env when is_binary(env) ->
        startup_timeout = Keyword.get(options, :startup_timeout, timeout)

        unless is_number(startup_timeout) and startup_timeout > 0 do
          raise ArgumentError, "startup_timeout must be a positive number"
        end

        %{env: env, timeout: startup_timeout}
    end
  end

  # Cleanup is best-effort here because setup is already failing. In particular,
  # a cleanup exception must never hide the error that prevented the supervisor
  # from taking ownership.
  defp cleanup_unowned_tmpdir(tmpdir) do
    File.rm_rf(tmpdir)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp normalize_options(options) when is_map(options), do: Map.to_list(options)
  defp normalize_options(options) when is_list(options), do: options
end

defmodule Kogen.IsolatedCase.Pool do
  @moduledoc false
  use GenServer

  # One scheduler owns every warm isolated child in this ExUnit VM. A module
  # registers its exact selected tests once. ExUnit's current dispatcher test
  # is promoted ahead of speculative work, so it cannot starve behind another
  # module's queue. No worker starts a child before the global permit exists.
  def register(jobs, server \\ nil) do
    names = Enum.map(jobs, &elem(&1, 0))

    if length(names) != length(Enum.uniq(names)),
      do: raise("duplicate isolated test identity in pool registration")

    server = server || ensure_started()
    ref = make_ref()
    :ok = GenServer.call(server, {:register, ref, jobs})
    %{server: server, ref: ref}
  end

  def await(%{server: server, ref: ref}, selector, timeout) do
    GenServer.call(server, {:await, {ref, selector}}, timeout + 10_000)
  catch
    :exit, reason ->
      {:error, {:pool_unavailable, reason}, ""}
  end

  def cancel(%{server: server, ref: ref}) do
    GenServer.call(server, {:cancel, ref}, 15_000)
  end

  # Nearly all of a case's wall time is a child VM waiting on a subprocess,
  # a socket or a fixture Build, not computing, so the number of live children
  # follows one and a half times the scheduler count (measured: three times
  # saturated the machine with process-spawn system time and made timed
  # cases flaky). `KOGEN_ISOLATED_POOL` overrides it; test_helper.exs sizes ExUnit's `max_cases` from this same function so
  # the two limits cannot drift apart.
  @doc false
  def limit do
    case Integer.parse(System.get_env("KOGEN_ISOLATED_POOL", "")) do
      {count, ""} when count > 0 -> count
      _ -> div(System.schedulers_online() * 3, 2)
    end
  end

  @doc false
  def start_test_server(limit) when is_integer(limit) and limit > 0 do
    GenServer.start(__MODULE__, limit)
  end

  def init(limit) do
    {:ok,
     %{
       limit: if(limit == :ok, do: limit(), else: limit),
       jobs: %{},
       queue: [],
       running: %{},
       failed: nil,
       cancellations: %{}
     }}
  end

  def handle_call({:register, _ref, _entries}, _from, %{failed: failed} = state)
      when not is_nil(failed), do: {:reply, {:error, failed}, state}

  def handle_call({:register, ref, entries}, _from, state) do
    now = System.monotonic_time(:millisecond)

    jobs =
      Enum.reduce(entries, state.jobs, fn {name, source, options}, jobs ->
        Map.put(jobs, {ref, name}, %{
          source: source,
          name: name,
          options: options,
          queued_at: now,
          queue_ms: nil,
          status: :queued,
          result: nil,
          waiters: []
        })
      end)

    queue = state.queue ++ Enum.map(entries, fn {name, _, _} -> {ref, name} end)
    {:reply, :ok, start_ready(%{state | jobs: jobs, queue: queue})}
  end

  def handle_call({:await, key}, from, state) do
    case Map.get(state.jobs, key) do
      nil ->
        {:reply, {:error, {:pool_missing_test, key}, ""}, state}

      %{status: :done, result: result} ->
        {:reply, result, state}

      job ->
        job = %{job | waiters: [from | job.waiters]}
        state = %{state | jobs: Map.put(state.jobs, key, job)}

        queue =
          if job.status == :queued, do: [key | List.delete(state.queue, key)], else: state.queue

        {:noreply, start_ready(%{state | queue: queue})}
    end
  end

  def handle_call({:cancel, ref}, from, state) do
    queue = Enum.reject(state.queue, fn {owner, _name} -> owner == ref end)
    running_keys = Enum.filter(Map.keys(state.running), fn {owner, _name} -> owner == ref end)

    Enum.each(running_keys, fn key ->
      %{pid: pid} = Map.fetch!(state.running, key)
      send(pid, {:kogen_pool_cancel, key})
    end)

    state = %{state | queue: queue, cancellations: Map.put(state.cancellations, ref, from)}
    {:noreply, finish_cancel(state, ref)}
  end

  def handle_info({:pool_result, key, result, run_ms}, state) do
    case Map.pop(state.running, key) do
      {nil, _running} ->
        {:noreply, state}

      {%{monitor: monitor}, running} ->
        Process.demonitor(monitor, [:flush])
        job = Map.fetch!(state.jobs, key)
        record_timing(key, job, run_ms, result)
        Enum.each(job.waiters, &GenServer.reply(&1, result))

        jobs =
          Map.put(
            state.jobs,
            key,
            job
            |> Map.put(:run_ms, run_ms)
            |> Map.merge(%{status: :done, result: result, waiters: []})
          )

        state = start_ready(%{state | jobs: jobs, running: running})
        {:noreply, finish_cancel(state, elem(key, 0))}
    end
  end

  def handle_info({:pool_root, key, root}, state) do
    running =
      Map.update(state.running, key, nil, fn worker ->
        Map.put(worker, :root, root)
      end)

    {:noreply, %{state | running: running}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.running, fn {_key, worker} -> worker.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {key, worker} ->
        worker = Map.put(worker, :exit_reason, reason)
        state = %{state | running: Map.put(state.running, key, worker)}
        send(self(), {:pool_cleanup_check, key, System.monotonic_time(:millisecond) + 5_000})
        {:noreply, state}
    end
  end

  def handle_info({:pool_cleanup_check, key, deadline}, state) do
    case Map.get(state.running, key) do
      nil ->
        {:noreply, state}

      worker ->
        cond do
          is_nil(worker.root) or not File.exists?(worker.root) ->
            result = {:error, {:pool_worker_exit, worker.exit_reason}, ""}
            {:noreply, finish_abnormal(state, key, result)}

          System.monotonic_time(:millisecond) >= deadline ->
            result = {:error, {:pool_cleanup_failed, worker.root}, ""}
            {:noreply, fail_pool(state, key, result)}

          true ->
            Process.send_after(self(), {:pool_cleanup_check, key, deadline}, 10)
            {:noreply, state}
        end
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, server} -> server
          {:error, {:already_started, server}} -> server
        end

      server ->
        server
    end
  end

  defp start_ready(%{failed: failed} = state) when not is_nil(failed), do: state
  defp start_ready(state) when map_size(state.running) >= state.limit, do: state
  defp start_ready(%{queue: []} = state), do: state

  defp start_ready(%{queue: [key | rest]} = state) do
    job = Map.fetch!(state.jobs, key)
    server = self()
    started_at = System.monotonic_time(:millisecond)

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            options =
              job.options |> Keyword.put(:pool_owner, server) |> Keyword.put(:pool_key, key)

            Kogen.IsolatedCase.run(job.source, job.name, options)
          rescue
            error -> {:error, {:pool_exception, Exception.message(error)}, ""}
          catch
            kind, reason -> {:error, {:pool_exception, {kind, reason}}, ""}
          end

        run_ms = System.monotonic_time(:millisecond) - started_at
        send(server, {:pool_result, key, result, run_ms})
      end)

    job = %{job | status: :running, queue_ms: started_at - job.queued_at}

    state = %{
      state
      | queue: rest,
        jobs: Map.put(state.jobs, key, job),
        running: Map.put(state.running, key, %{pid: pid, monitor: monitor, root: nil})
    }

    start_ready(state)
  end

  defp finish_abnormal(state, key, result) do
    job = Map.fetch!(state.jobs, key)
    Enum.each(job.waiters, &GenServer.reply(&1, result))
    jobs = Map.put(state.jobs, key, %{job | status: :done, result: result, waiters: []})
    state = start_ready(%{state | jobs: jobs, running: Map.delete(state.running, key)})
    finish_cancel(state, elem(key, 0))
  end

  defp fail_pool(state, key, result) do
    state = %{state | failed: result, queue: []}

    state =
      Enum.reduce(Map.keys(state.jobs), state, fn pending_key, state ->
        if pending_key == key or Map.fetch!(state.jobs, pending_key).status == :queued do
          job = Map.fetch!(state.jobs, pending_key)
          Enum.each(job.waiters, &GenServer.reply(&1, result))

          jobs =
            Map.put(state.jobs, pending_key, %{job | status: :done, result: result, waiters: []})

          %{state | jobs: jobs}
        else
          state
        end
      end)

    state = %{state | running: Map.delete(state.running, key)}
    finish_cancel(state, elem(key, 0))
  end

  defp finish_cancel(state, ref) do
    if Map.has_key?(state.cancellations, ref) and
         not Enum.any?(state.running, fn {{owner, _name}, _worker} -> owner == ref end) do
      reply = if state.failed, do: {:error, state.failed}, else: :ok
      GenServer.reply(Map.fetch!(state.cancellations, ref), reply)
      report_module_timings(state.jobs, ref)
      jobs = Map.reject(state.jobs, fn {{owner, _name}, _job} -> owner == ref end)
      %{state | jobs: jobs, cancellations: Map.delete(state.cancellations, ref)}
    else
      state
    end
  end

  defp report_module_timings(jobs, ref) do
    if System.get_env("KOGEN_POOL_TIMING_SUMMARY") == "1" do
      selected = for {{owner, _name}, job} <- jobs, owner == ref, do: job
      completed = Enum.filter(selected, &(&1.status == :done))
      queue_ms = Enum.sum(Enum.map(completed, &(&1.queue_ms || 0)))
      run_ms = Enum.sum(Enum.map(completed, &Map.get(&1, :run_ms, 0)))
      longest_queue_ms = completed |> Enum.map(&(&1.queue_ms || 0)) |> Enum.max(fn -> 0 end)
      longest_run_ms = completed |> Enum.map(&Map.get(&1, :run_ms, 0)) |> Enum.max(fn -> 0 end)

      IO.puts(
        "KOGEN_POOL_TIMING\t" <>
          Jason.encode!(%{
            module:
              selected
              |> List.first()
              |> then(&if(&1, do: Keyword.get(&1.options, :isolated_module))),
            selected: length(selected),
            completed: length(completed),
            queue_ms: queue_ms,
            run_ms: run_ms,
            longest_queue_ms: longest_queue_ms,
            longest_run_ms: longest_run_ms
          })
      )
    end
  end

  defp record_timing(_key, job, run_ms, result) do
    case System.get_env("KOGEN_POOL_TIMING_LOG") do
      path when is_binary(path) and path != "" ->
        line =
          Jason.encode!(%{
            module: Keyword.get(job.options, :isolated_module),
            test: to_string(job.name),
            queue_ms: job.queue_ms,
            run_ms: run_ms,
            status: if(match?({:ok, _}, result), do: "passed", else: "failed")
          })

        File.write!(path, line <> "\n", [:append])

      _ ->
        :ok
    end
  end
end
