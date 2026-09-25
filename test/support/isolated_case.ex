defmodule Kogen.IsolatedCase do
  @moduledoc false

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
              Kogen.IsolatedCase.run!(
                unquote(source),
                isolated_context.test,
                Kogen.IsolatedCase.dispatch_options(
                  isolated_context,
                  unquote(@default_timeout),
                  unquote(target_evidence)
                )
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
    working_dir = Path.expand(Keyword.get(options, :cd, root))
    timeout = Keyword.get(options, :timeout, @default_timeout)
    readiness = readiness_config(options, timeout)
    tmpdir = private_tmpdir(options)
    invocation = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    binding = %{invocation: invocation, source: source, selector: to_string(selector)}
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
    case if(Keyword.has_key?(options, :parameterize),
           do: System.get_env("KOGEN_ISOLATED_PARAMETERS")
         ) do
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

  @doc false
  def dispatch_options(context, default_timeout) do
    dispatch_options(context, default_timeout, nil)
  end

  @doc false
  def dispatch_options(context, default_timeout, target_evidence) do
    [:timeout, :collection_timeout, :readiness, :startup_timeout, :target_evidence]
    |> Enum.reduce([parameters: context], fn key, options ->
      case Map.fetch(context, key) do
        {:ok, value} -> Keyword.put(options, key, value)
        :error -> options
      end
    end)
    |> Keyword.put_new(:timeout, default_timeout)
    |> maybe_put_target_evidence(target_evidence)
  end

  defp maybe_put_target_evidence(options, nil), do: options

  defp maybe_put_target_evidence(options, value),
    do: Keyword.put_new(options, :target_evidence, value)

  defp matches_parameters?(parameter, expected) do
    Enum.all?(parameter, fn {key, value} -> Map.get(expected, key) == value end)
  end

  @doc false
  def run!(source, selector, options \\ []) do
    options = normalize_options(options)
    required? = Keyword.get(options, :target_evidence) == :required

    case run(source, selector, options) do
      {:ok, output} ->
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
    Code.require_file(helper)
    # `include` alone adds a matching test but leaves untagged tests eligible.
    # Every ExUnit test has the special `:test` tag, so exclude that universe
    # first and let the exact selector opt one test back in.
    ExUnit.configure(exclude: [:test], include: selector_filter(selector))
    Code.require_file(source)

    status =
      case ExUnit.run() do
        %{failures: 0, total: total, excluded: excluded, skipped: 0}
        when total - excluded == 1 ->
          0

        result ->
          IO.puts(:stderr, "expected exactly one passing isolated test: #{inspect(result)}")
          1
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

    ["+S", "2:2", "+SDcpu", "1", "+SDio", "1", "-noshell"] ++
      Enum.flat_map(code_paths(), fn path -> ["-pa", path] end) ++
      ["-s", "elixir", "start_cli", "-extra", "-e", code]
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

    [
      {@child_marker, "1"},
      {"ROOTDIR", List.to_string(:code.root_dir())},
      {"BINDIR", erts_bin()},
      {"EMU", "beam"},
      {"PROGNAME", "erl"},
      # Isolated children still use the repository's explicitly provisioned
      # toolchain. Without PATH they fall back to the host /usr/bin/python3,
      # which can be older than Kogen's declared Python 3.11 baseline.
      {"PATH", System.fetch_env!("PATH")},
      {"DYLD_INSERT_LIBRARIES", System.fetch_env!("KOGEN_TEST_PROCESS_GUARD")},
      {"TMPDIR", tmpdir},
      {"TMP", tmpdir},
      {"TEMP", tmpdir},
      {"MIX_BUILD_PATH", Path.join(tmpdir, "_build")},
      {"ERL_CRASH_DUMP", Path.join(tmpdir, "erl_crash.dump")},
      {"KOGEN_ISOLATED_RESULT", Path.join(tmpdir, "result")},
      {"KOGEN_ISOLATED_INVOCATION", binding.invocation},
      {"KOGEN_ISOLATED_SOURCE", binding.source},
      {"KOGEN_ISOLATED_SELECTOR", binding.selector}
      | offline_jev_env() ++ parameter_env ++ configured ++ readiness_env
    ]
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
