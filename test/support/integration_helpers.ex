defmodule Kogen.Integration.FakeProvider do
  @moduledoc false

  @provider_path "/v1/responses"
  @token_path "/api/accounts/oauth/token"

  def start(script) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)
    {:ok, state} = Agent.start(fn -> %{script: script, provider: [], auth: [], next: 0} end)
    server = spawn(fn -> accept(listener, state) end)
    %{listener: listener, port: port, pid: server, state: state}
  end

  def stop(%{listener: listener, state: state}) do
    :gen_tcp.close(listener)
    Agent.stop(state)
  catch
    :exit, _ -> :ok
  end

  def provider_requests(%{state: state}), do: Agent.get(state, &Enum.reverse(&1.provider))
  def auth_requests(%{state: state}), do: Agent.get(state, &Enum.reverse(&1.auth))

  def tool_outputs(server) do
    server
    |> provider_requests()
    |> Enum.flat_map(fn request ->
      (request.json["input"] || [])
      |> Enum.filter(&(&1["type"] == "function_call_output"))
      |> Enum.map(& &1["output"])
    end)
  end

  def review_requests(server) do
    Enum.filter(provider_requests(server), fn request ->
      String.contains?(request.json["instructions"] || "", "You review code")
    end)
  end

  defp accept(listener, state) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          with {:ok, request} <- read_request(socket) do
            action = next_action(state, request)
            send_response(socket, action)
          end
        after
          :gen_tcp.close(socket)
        end

        accept(listener, state)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept(listener, state)
    end
  end

  defp read_request(socket, data \\ <<>>) do
    case :binary.match(data, "\r\n\r\n") do
      {head_size, 4} ->
        head = binary_part(data, 0, head_size)
        available = binary_part(data, head_size + 4, byte_size(data) - head_size - 4)
        content_length = content_length(head)

        if byte_size(available) >= content_length do
          body = binary_part(available, 0, content_length)
          {:ok, parse_request(head, body)}
        else
          case :gen_tcp.recv(socket, 0, 10_000) do
            {:ok, more} -> read_request(socket, data <> more)
            error -> error
          end
        end

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, more} -> read_request(socket, data <> more)
          error -> error
        end
    end
  end

  defp content_length(head) do
    head
    |> :binary.split("\r\n", [:global])
    |> Enum.find_value(0, fn line ->
      case String.split(to_string(line), ":", parts: 2) do
        [name, value] when is_binary(name) ->
          if String.downcase(name) == "content-length", do: String.to_integer(String.trim(value))

        _ ->
          nil
      end
    end)
  end

  defp parse_request(head, body) do
    [line | _] = :binary.split(head, "\r\n", [:global])
    [method, path | _] = String.split(to_string(line), " ")

    decoded =
      cond do
        path == @provider_path ->
          JSON.decode!(body)

        path == @token_path ->
          URI.decode_query(to_string(body))

        true ->
          body
      end

    %{method: method, path: path, json: decoded, body: body}
  end

  defp next_action(state, %{path: @token_path} = request) do
    Agent.update(state, &%{&1 | auth: [request | &1.auth]})

    {:json, 200,
     %{
       "access_token" => "fake-rotated-access-token",
       "refresh_token" => "fake-rotated-refresh-token",
       "expires_in" => 3600
     }}
  end

  defp next_action(state, %{path: @provider_path} = request) do
    Agent.get_and_update(state, fn s ->
      action = Enum.at(s.script, s.next, {:http, 400, refused_body()})
      {{:provider, action, s.next + 1}, %{s | provider: [request | s.provider], next: s.next + 1}}
    end)
    |> then(fn {:provider, action, index} -> provider_action(action, index) end)
  end

  defp next_action(_state, _request), do: {:json, 404, %{"error" => "not found"}}

  defp provider_action({:http, status, body}, _index), do: {:json, status, body}
  defp provider_action({:json, status, body}, _index), do: {:json, status, body}

  defp provider_action({:pause, owner, action}, index) do
    send(owner, {:provider_paused, self()})

    receive do
      :continue -> provider_action(action, index)
    end
  end

  defp provider_action({:text, text}, index) do
    item = %{
      "type" => "message",
      "id" => "message-#{index}",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }

    {:sse, [item]}
  end

  defp provider_action({:function, name, arguments}, index) do
    item = %{
      "type" => "function_call",
      "id" => "function-#{index}",
      "call_id" => "call-#{index}",
      "name" => name,
      "arguments" => JSON.encode!(arguments)
    }

    {:sse, [item]}
  end

  defp provider_action({:items, items}, _index), do: {:sse, items}
  defp provider_action({:events, events}, _index), do: {:events, events}
  defp provider_action({:open_events, owner, events}, _index), do: {:open_events, owner, events}

  defp refused_body do
    %{"error" => %{"message" => "scripted provider refusal", "code" => "invalid_request_error"}}
  end

  defp send_response(socket, {:json, status, body}) do
    send_http(socket, status, "application/json", JSON.encode!(body))
  end

  defp send_response(socket, {:open_events, owner, events}) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
      )

    for event <- events do
      frame = "data: " <> JSON.encode!(event) <> "\n\n"

      :ok =
        :gen_tcp.send(socket, [Integer.to_string(byte_size(frame), 16), "\r\n", frame, "\r\n"])
    end

    send(owner, {:provider_open, self()})
    result = wait_for_close(socket, System.monotonic_time(:millisecond) + 3000)
    send(owner, {:provider_closed, result})
  end

  defp send_response(socket, {:events, events}) do
    body = Enum.map_join(events, "", &("data: " <> JSON.encode!(&1) <> "\n\n"))
    send_http(socket, 200, "text/event-stream", body)
  end

  defp send_response(socket, {:sse, items}) do
    events =
      items
      |> Enum.with_index()
      |> Enum.map_join("", fn {item, index} ->
        "data: " <>
          JSON.encode!(%{
            "type" => "response.output_item.done",
            "output_index" => index,
            "item" => item
          }) <> "\n\n"
      end)

    done =
      JSON.encode!(%{
        "type" => "response.completed",
        "response" => %{
          "usage" => %{
            "input_tokens" => 1,
            "input_tokens_details" => %{"cached_tokens" => 0},
            "output_tokens" => 1,
            "output_tokens_details" => %{"reasoning_tokens" => 0}
          }
        }
      })

    send_http(socket, 200, "text/event-stream", events <> "data: " <> done <> "\n\n")
  end

  # Keep a real open stream active even if TCP coalesces its initial headers and frames.
  defp wait_for_close(socket, deadline) do
    case :gen_tcp.recv(socket, 0, 20) do
      {:error, :timeout} = timeout ->
        if System.monotonic_time(:millisecond) < deadline do
          :gen_tcp.send(socket, "3\r\n:\n\n\r\n")
          wait_for_close(socket, deadline)
        else
          timeout
        end

      result ->
        result
    end
  end

  defp send_http(socket, status, content_type, body) do
    reason =
      if status == 200, do: "OK", else: if(status == 400, do: "Bad Request", else: "Not Found")

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: #{content_type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ])
  end
end

defmodule Kogen.Integration.Helpers do
  @moduledoc false

  alias Kogen.Integration.FakeProvider

  @toolchain_path System.get_env("PATH") || "/usr/bin:/bin"
  @erl_flags System.get_env("ERL_FLAGS") || "+S 2:2 +SDcpu 1 +SDio 1"

  def project_root, do: Path.expand("../..", __DIR__)

  def setup_suite! do
    archive = shared_archive!()
    suite_root = temp_dir!("kogen-integration-suite")
    build_home = Path.join(suite_root, "build-home")
    install_home = Path.join(suite_root, "install-home")
    prefix = Path.join(suite_root, "prefix")
    tmp = Path.join(suite_root, "tmp")
    Enum.each([build_home, install_home, tmp], &File.mkdir_p!/1)
    global_config = Path.join(build_home, ".gitconfig")
    File.write!(global_config, "")

    extraction = Path.join(suite_root, "extract")
    File.mkdir_p!(extraction)

    command!(["/usr/bin/tar", "-xzf", archive, "-C", extraction],
      cd: project_root(),
      env: suite_env(build_home, global_config, tmp)
    )

    [release_dir] = File.ls!(extraction) |> Enum.map(&Path.join(extraction, &1))

    command!("/bin/sh", [Path.join(release_dir, "install.sh"), "--prefix", prefix],
      cd: release_dir,
      env: suite_env(install_home, Path.join(install_home, ".gitconfig"), tmp)
    )

    %{
      root: suite_root,
      release: Path.join([prefix, "bin", "kogen"]),
      prefix: prefix,
      cucumber: cucumber_paths(project_root()),
      path: @toolchain_path
    }
  end

  def cleanup_suite(%{root: root}), do: File.rm_rf(root)

  # Build once even when `mix test` runs the integration modules concurrently. Each
  # module still installs its own prefix: one regression deliberately removes its core.
  defp shared_archive! do
    key = {__MODULE__, :archive}

    :global.trans({key, self()}, fn ->
      case :persistent_term.get(key, nil) do
        nil ->
          root = temp_dir!("kogen-integration-build")
          home = Path.join(root, "home")
          tmp = Path.join(root, "tmp")
          Enum.each([home, tmp], &File.mkdir_p!/1)

          try do
            ensure_cucumber!(project_root(), home, tmp)

            archive =
              case System.get_env("KOGEN_ARCHIVE") do
                nil -> package_release!(project_root(), home, tmp, root)
                path -> Path.expand(path)
              end

            if not File.regular?(archive), do: raise("release archive not found: #{archive}")
            :persistent_term.put(key, archive)

            ExUnit.after_suite(fn _ ->
              :persistent_term.erase(key)
              File.rm_rf(root)
            end)

            archive
          rescue
            error ->
              File.rm_rf(root)
              reraise error, __STACKTRACE__
          end

        archive ->
          archive
      end
    end)
  end

  def project!(suite, provider_script, opts \\ []) do
    root = temp_dir!("kogen-integration-case")
    repo = Path.join(root, opts[:repo_name] || "repo")
    home = Path.join(root, "home")
    tmp = Path.join(root, "tmp")
    Enum.each([repo, home, tmp], &File.mkdir_p!/1)
    global_config = Path.join(home, ".gitconfig")
    File.write!(global_config, "")

    server =
      FakeProvider.start([
        {:function, "submit_configuration",
         %{"setup" => [], "fix" => [], "checks" => [], "protect" => []}}
        | provider_script
      ])

    env = %{
      "HOME" => home,
      "PATH" => suite.path,
      "ERL_FLAGS" => @erl_flags,
      "GIT_CONFIG_GLOBAL" => global_config,
      "GIT_CONFIG_NOSYSTEM" => "1",
      "KOGEN_PROVIDER_URL" => "http://127.0.0.1:#{server.port}",
      "KOGEN_AUTH_URL" => "http://127.0.0.1:#{server.port}",
      "TMPDIR" => tmp
    }

    isolated = if opts[:lang], do: Map.put(env, "LANG", opts[:lang]), else: env

    build_project!(suite, opts, root, repo, home, tmp, global_config, server, isolated)
  end

  defp build_project!(
         suite,
         opts,
         root,
         repo,
         home,
         tmp,
         global_config,
         server,
         isolated
       ) do
    ports = start_port_registry!()

    try do
      File.write!(Path.join(repo, "README.md"), "# Fixture project\n")
      File.write!(Path.join(repo, "app.txt"), "baseline\n")
      git!(%{repo: repo, env: isolated}, ["init", "-q", "--initial-branch=main"])
      git!(%{repo: repo, env: isolated}, ["config", "user.name", "Kogen Integration"])

      git!(%{repo: repo, env: isolated}, [
        "config",
        "user.email",
        "kogen-integration@example.invalid"
      ])

      git!(%{repo: repo, env: isolated}, ["add", "README.md", "app.txt"])
      git!(%{repo: repo, env: isolated}, ["commit", "-q", "-m", "fixture baseline"])

      context = %{
        suite: suite,
        root: root,
        repo: repo,
        home: home,
        tmp: tmp,
        env: isolated,
        global_config: global_config,
        server: server,
        ports: ports
      }

      seed_credentials!(context, :valid)
      {init_out, init_status} = run_kogen(context, ["init"])
      if init_status != 0, do: raise("kogen init failed: #{init_out}")

      write_intent!(context)
      if opts[:staged_intent] != false, do: stage_other_intent!(context)
      approve!(context)
      context
    rescue
      error ->
        FakeProvider.stop(server)
        Agent.stop(ports)
        File.rm_rf(root)
        reraise error, __STACKTRACE__
    end
  end

  def cleanup_case(context) do
    ports =
      try do
        Agent.get(context.ports, & &1)
      catch
        :exit, _ -> []
      end

    Enum.each(ports, fn port ->
      try do
        case Port.info(port, :os_pid) do
          {:os_pid, pid} ->
            System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)],
              env: env_for(context),
              stderr_to_stdout: true
            )

            await_exit(port, "", 3_000)

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end)

    FakeProvider.stop(context.server)
    Agent.stop(context.ports)
    File.rm_rf(context.root)
  catch
    :exit, _ -> File.rm_rf(context.root)
  end

  def env_for(context), do: env_for(context, %{})

  def env_for(context, change) do
    context.env
    |> Map.merge(change)
    |> Map.to_list()
    |> isolated_env()
  end

  def run_kogen(context, args, opts \\ []) do
    System.cmd(context.suite.release, args,
      cd: opts[:cd] || context.repo,
      env: env_for(context, Map.new(opts[:env] || [])),
      stderr_to_stdout: true
    )
  end

  def start_kogen(context, args, opts \\ []) do
    env = env_for(context, Map.new(opts[:env] || []))

    port =
      Port.open({:spawn_executable, String.to_charlist(context.suite.release)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, Enum.map(args, &String.to_charlist/1)},
        {:cd, String.to_charlist(opts[:cd] || context.repo)},
        {:env,
         Enum.map(env, fn {name, value} ->
           {String.to_charlist(name),
            if(value == nil, do: false, else: String.to_charlist(value))}
         end)}
      ])

    Agent.update(context.ports, &[port | &1])
    port
  end

  def git!(context, args) do
    command!("git", ["-C", context.repo | args], env: env_for(context), stderr_to_stdout: true)
  end

  def signal!(context, port, signal) do
    {:os_pid, pid} = Port.info(port, :os_pid)

    command!("/bin/kill", ["-#{signal}", Integer.to_string(pid)],
      env: env_for(context),
      stderr_to_stdout: true
    )
  end

  def index_tree!(context), do: context |> git!(["write-tree"]) |> elem(0) |> String.trim()

  def write_hook!(context, contents) do
    hooks = Path.join(context.root, "git-hooks")
    File.mkdir_p!(hooks)
    path = Path.join(hooks, "pre-commit")
    File.write!(path, "#!/bin/sh\n" <> contents)
    File.chmod!(path, 0o755)
    git!(context, ["config", "core.hooksPath", hooks])
    path
  end

  def seed_credentials!(context, freshness \\ :valid) do
    expires_at =
      case freshness do
        :expired -> System.system_time(:second) - 120
        :valid -> System.system_time(:second) + 86_400
      end

    directory = Path.join(context.home, ".kogen/credentials")
    File.mkdir_p!(directory)
    File.chmod!(Path.dirname(directory), 0o700)
    File.chmod!(directory, 0o700)

    File.write!(
      Path.join(directory, "chatgpt.json"),
      JSON.encode!(%{
        "client_id" => "oaiapp_fake-integration-client",
        "access_token" => "fake-integration-access-token",
        "refresh_token" => "fake-integration-refresh-token",
        "expires_at" => expires_at,
        "scope" =>
          "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
        "email" => "integration@example.invalid"
      })
    )

    File.chmod!(Path.join(directory, "chatgpt.json"), 0o600)
  end

  def await_output(port, needle, timeout \\ 10_000), do: await_output(port, needle, timeout, "")

  defp await_output(port, needle, timeout, output) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if String.contains?(output, needle),
          do: output,
          else: await_output(port, needle, timeout, output)

      {^port, {:exit_status, status}} ->
        raise("kogen exited with #{status} before output #{inspect(needle)}: #{output}")
    after
      timeout -> raise("timed out waiting for kogen output #{inspect(needle)}: #{output}")
    end
  end

  def await_exit(port, output \\ "", timeout \\ 20_000),
    do: await_exit(port, output, timeout, System.monotonic_time(:millisecond))

  defp await_exit(port, output, timeout, started) do
    receive do
      {^port, {:data, data}} -> await_exit(port, output <> data, timeout, started)
      {^port, {:exit_status, status}} -> {output, status}
    after
      max(timeout - (System.monotonic_time(:millisecond) - started), 0) ->
        raise("kogen did not exit within #{timeout} ms: #{output}")
    end
  end

  def wait_for_file!(path, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_file(path, deadline)
  end

  defp wait_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise("timed out waiting for #{path}")

      true ->
        Process.sleep(20)
        wait_file(path, deadline)
    end
  end

  def run_log(context) do
    [path] = Path.wildcard(Path.join(context.repo, ".kogen/local/runs/*/log.jsonl"))
    path
  end

  defp write_intent!(context) do
    intent_dir = Path.join(context.repo, ".kogen/intents/fixture")
    steps_dir = Path.join(context.repo, "features/steps")
    File.mkdir_p!(intent_dir)
    File.mkdir_p!(steps_dir)

    File.write!(Path.join(intent_dir, "intent.md"), """
    # Preserve the fixture

    Slug: fixture
    Model: not applicable — no model for this fixture

    Acceptance:
    - .kogen/intents/fixture/acceptance.feature
    - features/steps/integration_steps.js

    ## Tests
    - the fixture stays as it is: the acceptance scenario (existing)

    ## Feasibility
    - none
    """)

    File.write!(Path.join(intent_dir, "acceptance.feature"), """
    Feature: Integration fixture
      Scenario: The actual Cucumber runner passes
        Given the fixture is available
        Then the acceptance check passes
    """)

    File.write!(Path.join(steps_dir, "integration_steps.js"), """
    const { Given, Then } = require('@cucumber/cucumber');

    Given('the fixture is available', function () {
      this.fixtureAvailable = true;
    });

    Then('the acceptance check passes', function () {
      if (!this.fixtureAvailable) throw new Error('fixture was not available');
    });
    """)
  end

  defp stage_other_intent!(context) do
    path = Path.join(context.repo, ".kogen/intents/staged/draft.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "caller staged this Intent\n")
    git!(context, ["add", ".kogen/intents/staged/draft.md"])
  end

  defp approve!(context) do
    {card, status} = run_kogen(context, ["intent", "approve", "fixture"])
    if status != 5, do: raise("kogen approval card failed: #{card}")
    [_, hash] = Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card)

    {output, status} =
      run_kogen(context, ["intent", "approve", "fixture", String.slice(hash, 0, 8)])

    if status != 0, do: raise("kogen approval failed: #{output}")
  end

  defp ensure_cucumber!(repo, home, tmp) do
    node_modules = Path.join([repo, "test/acceptance/node_modules"])

    if not File.regular?(Path.join(node_modules, "@cucumber/cucumber/bin/cucumber.js")) do
      global = Path.join(home, ".gitconfig")
      File.write!(global, "")

      command!("npm", ["ci", "--no-audit", "--no-fund"],
        cd: Path.join(repo, "test/acceptance"),
        env: suite_env(home, global, tmp),
        stderr_to_stdout: true
      )
    end
  end

  defp package_release!(repo, home, tmp, suite_root) do
    global = Path.join(home, ".gitconfig")
    File.write!(global, "")

    # Package a copy of the source: `mix test` holds this project's Mix locks.
    source = Path.join(suite_root, "source")
    File.mkdir_p!(source)

    for entry <- ~w(mix.exs mix.lock LICENSE NOTICE config lib rel cli packaging docs),
        File.exists?(Path.join(repo, entry)) do
      File.cp_r!(Path.join(repo, entry), Path.join(source, entry))
    end

    {output, 0} =
      command!("/bin/sh", ["packaging/package.sh"],
        cd: source,
        # The isolated HOME has no Hex: keep this user's Mix and Hex homes so Mix never prompts.
        env:
          suite_env(home, global, tmp) ++
            [
              {"MIX_ENV", "prod"},
              {"MIX_HOME", System.get_env("MIX_HOME") || Path.expand("~/.mix")},
              {"HEX_HOME", System.get_env("HEX_HOME") || Path.expand("~/.hex")}
            ],
        stderr_to_stdout: true
      )

    archive =
      output
      |> String.split("\n", trim: true)
      |> Enum.find(&String.ends_with?(&1, ".tar.gz"))

    if archive == nil, do: raise("packaging did not print an archive path: #{output}")
    archive
  end

  defp cucumber_paths(repo) do
    node_modules = Path.join([repo, "test/acceptance/node_modules"])

    %{
      node: System.find_executable("node"),
      node_modules: node_modules,
      cucumber: Path.join([node_modules, "@cucumber/cucumber/bin/cucumber.js"])
    }
  end

  defp suite_env(home, global_config, tmp) do
    isolated_env([
      {"HOME", home},
      {"PATH", @toolchain_path},
      {"ERL_FLAGS", @erl_flags},
      {"GIT_CONFIG_GLOBAL", global_config},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"TMPDIR", tmp}
    ])
  end

  defp command!(executable, args, opts) when is_binary(executable) do
    System.cmd(executable, args,
      cd: opts[:cd] || project_root(),
      env: opts[:env] || [],
      stderr_to_stdout: opts[:stderr_to_stdout] || false
    )
    |> case do
      {output, 0} ->
        {output, 0}

      {output, status} ->
        raise("command #{executable} #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp command!(args, opts), do: command!(hd(args), tl(args), opts)

  defp isolated_env(values) do
    unset = Map.new(System.get_env(), fn {name, _value} -> {name, nil} end)
    Map.merge(unset, Map.new(values)) |> Map.to_list()
  end

  defp start_port_registry! do
    {:ok, registry} = Agent.start_link(fn -> [] end)
    registry
  end

  defp temp_dir!(prefix) do
    # The OS pid keeps the name unique across runs (a crashed run leaves its folder behind).
    name = "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
    # Match the OS working directory used by the installed CLI (macOS /var is a symlink).
    {tmp, 0} = System.cmd("/bin/pwd", ["-P"], cd: System.tmp_dir!())
    path = Path.join(String.trim(tmp), name)
    File.mkdir!(path)
    path
  end
end
