const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

// Independent installed-release harness. The fake provider and documentation fixture are local; no real account or public internet is used.
const driver = String.raw`
ExUnit.start(autorun: false)
Code.require_file("test/support/integration_helpers.ex")
alias Kogen.Integration.{Helpers, FakeProvider}

defmodule DocsFixture do
  def start do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    {:ok, closed_listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])
    {:ok, closed} = :inet.port(closed_listen)
    :gen_tcp.close(closed_listen)
    {:ok, agent} = Agent.start_link(fn -> [] end)
    pid = spawn(fn -> accept(listen, agent, port) end)
    base = "http://127.0.0.1:#{port}"

    %{
      listen: listen,
      pid: pid,
      agent: agent,
      port: port,
      closed: closed,
      base: base,
      good: base <> "/cache-controls",
      hostile: base <> "/hostile",
      closed_url: "http://127.0.0.1:#{closed}/missing",
      closed_base: "http://127.0.0.1:#{closed}"
    }
  end

  def stop(fixture) do
    try do
      :gen_tcp.close(fixture.listen)
      Process.exit(fixture.pid, :kill)
      if Process.alive?(fixture.agent), do: Agent.stop(fixture.agent)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def saw_secret?(fixture) do
    Agent.get(fixture.agent, fn reqs ->
      Enum.any?(reqs, &String.match?(&1, ~r/authorization|cookie|api-key|api_key|bearer/i))
    end)
  end

  def request_count(fixture), do: Agent.get(fixture.agent, &length/1)

  defp accept(listen, agent, port) do
    case :gen_tcp.accept(listen, 1_000) do
      {:ok, socket} ->
        handle(socket, agent, port)
        accept(listen, agent, port)

      {:error, :timeout} ->
        accept(listen, agent, port)

      _ ->
        :ok
    end
  end

  defp handle(socket, agent, port) do
    data = read_headers(socket, "")
    Agent.update(agent, &[data | &1])
    [start | _] = String.split(data, "\r\n", parts: 2)

    case String.split(start) do
      ["GET", target | _] -> route(socket, target, port)
      _ -> send_resp(socket, 400, "text/plain", "")
    end

    :gen_tcp.close(socket)
  end

  defp read_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> read_headers(socket, acc <> chunk)
        _ -> acc
      end
    end
  end

  defp route(socket, target, port) do
    base = "http://127.0.0.1:#{port}"
    uri = URI.parse(target)
    query = URI.decode_query(uri.query || "")

    cond do
      uri.path == "/search" and query["q"] == "cache controls" ->
        body = ~s({"sources":[{"url":"#{base}/cache-controls","title":"Cache controls"}]})
        send_resp(socket, 200, "application/json", body)

      uri.path == "/search" and query["q"] == "missing-provider" ->
        send_resp(socket, 415, "text/plain", "unsupported")

      uri.path == "/cache-controls" ->
        send_resp(socket, 200, "text/plain", "DOC-FACT-7b9acb97\ncache-control: public, max-age=60\n")

      uri.path == "/hostile" ->
        send_resp(socket, 200, "text/plain", "UNTRUSTED-DIRECTIVE-7b9acb97\n")

      true ->
        send_resp(socket, 404, "text/plain", "missing")
    end
  end

  defp send_resp(socket, status, type, body) do
    reason = %{200 => "OK", 400 => "Bad Request", 404 => "Not Found", 415 => "Unsupported Media Type"}

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} #{reason[status] || "Error"}\r\n",
      "content-type: #{type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])
  end
end

defmodule DiscoveryDriver do
  def run do
    suite = Helpers.setup_suite!()
    try do
      %{
        "discovery" => discovery(suite),
        "uninspected" => uninspected(suite),
        "engineering" => engineering(suite),
        "handoff" => handoff(suite),
        "trivial" => trivial(suite),
        "refine" => refine(suite),
        "docs" => docs(suite),
        "docs-reject" => docs_reject(suite)
      }
    after
      Helpers.cleanup_suite(suite)
    end
  end

  defp discovery(suite) do
    script = [
      {:function, "read_file", %{"path" => "protocol.json"}},
      {:function, "probe", %{"command" => "python3 protocol.py"}},
      {:function, "probe", %{"command" => "python3 protocol.py line-v1"}},
      {:function, "submit", %{"files" => files("status-line", "Report the supported protocol", "The supported integration protocol is line-v2.", "- protocol.json supports line-v2. (probe 1: exit 0, 0.1 s)\n- line-v1 is an explicit rejection. (probe 2: exit 23, 0.1 s)", comparison())}}
    ]
    observe(suite, script, "status-line", discovery_request(), true)
  end

  defp uninspected(suite) do
    submit = {:function, "submit", %{"files" => files("copied-recipe", "Copy the operator recipe", "Use protocol line-v1 and endpoint https://example.invalid/v1.", "- none", comparison())}}
    observe(suite, [submit, submit, submit], "copied-recipe", discovery_request(), false)
  end

  defp engineering(suite) do
    question = {:function, "submit", %{"questions" => [%{"question" => "Which protocol and endpoint should the integration use?", "kind" => "engineering", "options" => [%{"label" => "use the operator recipe", "recommended" => true}, %{"label" => "leave it unknown"}]}]}}
    observe(suite, [question, question, question], "ask-protocol", discovery_request(), false)
  end

  defp handoff(suite) do
    question = {:function, "submit", %{"questions" => [%{"question" => "Sign in to the provider before shaping can check this account-scoped capability.", "kind" => "handoff", "options" => [%{"label" => "sign in", "recommended" => true}]}]}}
    observe(suite, [question], "sign-in-handoff", discovery_request(), false)
  end

  defp trivial(suite) do
    files = files("greeting", "Set the greeting copy", "Change the greeting copy to Hello.", "- none", "- addressed: greeting copy; source request; contract prose.\n")
    read = %{"type" => "function_call", "id" => "function-read", "call_id" => "call-read", "name" => "read_file", "arguments" => JSON.encode!(%{"path" => "README.md"})}
    submit = %{"type" => "function_call", "id" => "function-submit", "call_id" => "call-submit", "name" => "submit", "arguments" => JSON.encode!(%{"files" => files})}
    observe(suite, [{:items, [read, submit]}], "greeting", "Change the greeting copy to Hello.\nTRIVIAL-MARKER-7b9acb97\n", false)
  end

  defp refine(suite) do
    observe(suite, [{:function, "submit_refinement", %{"constraint" => "This correction needs no technical change."}}], "fixture", :refine, false)
  end

  defp docs(suite) do
    fixture = DocsFixture.start()
    try do
      script = [
        {:function, "read_file", %{"path" => "README.md"}},
        {:function, "documentation", %{"operation" => "search", "query" => "cache controls", "base" => fixture.base}},
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.good, "base" => fixture.base}},
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.closed_url, "base" => fixture.closed_base}},
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.hostile, "base" => fixture.base}},
        {:function, "documentation", %{"operation" => "search", "query" => "missing-provider", "base" => fixture.base}},
        {:function, "submit", %{"files" => docs_files(fixture)}}
      ]
      observe(suite, script, "cache-docs", docs_request(), false, fixture)
    after
      DocsFixture.stop(fixture)
    end
  end

  defp docs_reject(suite) do
    fixture = DocsFixture.start()
    try do
      submit = {:function, "submit", %{"files" => bad_files()}}
      script = [
        {:function, "read_file", %{"path" => "README.md"}},
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.hostile, "base" => fixture.base}},
        submit,
        submit,
        submit
      ]
      observe(suite, script, "bad-docs", docs_request(), false, fixture)
    after
      DocsFixture.stop(fixture)
    end
  end

  defp observe(suite, script, slug, request_text, protocol, fixture \\ nil) do
    context = Helpers.project!(suite, script)
    try do
      if protocol, do: write_protocol!(context)
      {output, status, request_body, later, outputs} =
        if request_text == :refine do
          approval = File.read!(Path.join(context.repo, ".kogen/local/approvals/fixture.json")) |> JSON.decode!()
          correction = Path.join(context.root, "correction.txt")
          File.write!(correction, "Clarify the fixture title only.\n")
          {out, code} = Helpers.run_kogen(context, ["intent", "refine", "fixture", approval["sha256"], correction])
          {out, code, refine_body(context), "", []}
        else
          request = Path.join(context.root, "request.txt")
          File.write!(request, request_text)
          {out, code} = Helpers.run_kogen(context, ["intent", "shape", slug, request])
          shape = shape_requests(context)
          first = if(shape == [], do: %{}, else: hd(shape).json)
          rest = shape |> Enum.drop(1) |> Enum.map_join("\n", &JSON.encode!(&1.json))
          outputs = FakeProvider.tool_outputs(context.server)
          tools = Enum.join(outputs, "\n")
          {out, code, JSON.encode!(first), rest <> "\n" <> tools, outputs}
        end
      intent_path = Path.join(context.repo, ".kogen/intents/#{slug}/intent.md")
      intent = if(File.regular?(intent_path), do: File.read!(intent_path), else: "")
      search = Enum.at(outputs, 1, "")
      fetch = Enum.at(outputs, 2, "")
      unreachable = Enum.at(outputs, 3, "")
      untrusted = Enum.at(outputs, 4, "")
      unsupported = Enum.at(outputs, 5, "")
      good = if(fixture, do: fixture.good, else: "")
      hostile = if(fixture, do: fixture.hostile, else: "")
      closed_url = if(fixture, do: fixture.closed_url, else: "")
      Map.merge(
        %{
          "status" => Integer.to_string(status),
          "questions_printed" => bool(String.contains?(output, "Questions for")),
          "intent_exists" => bool(File.regular?(intent_path)),
          "intent_has_line_v2" => bool(String.contains?(intent, "line-v2")),
          "decisions_have_example_invalid" => bool(String.contains?(section(intent, "Decisions"), "example.invalid")),
          "comparison_has_omitted" => bool(String.contains?(section(intent, "Source comparison"), "omitted")),
          "comparison_has_endpoint" => bool(String.contains?(section(intent, "Source comparison"), "https://example.invalid/v1")),
          "first_request_has_line_v2" => bool(String.contains?(request_body, "line-v2")),
          "first_request_has_marker" => bool(String.contains?(request_body, "DISCOVERY-MARKER-7b9acb97")),
          "first_request_has_recipe" => bool(String.contains?(request_body, "Operator recipe (not authority): use protocol line-v1 and endpoint https://example.invalid/v1.")),
          "later_request_has_supported" => bool(String.contains?(later, "supported line-v2")),
          "probe_count" => Integer.to_string(length(String.split(output, "kogen: probe: ")) - 1),
          "request_body" => request_body,
          "stdout" => output
        },
        doc_fields(intent, request_body, fixture, search, fetch, unreachable, untrusted, unsupported, good, hostile, closed_url)
      )
    after
      Helpers.cleanup_case(context)
    end
  end

  defp doc_fields(intent, request_body, fixture, search, fetch, unreachable, untrusted, unsupported, good, hostile, closed_url) do
    %{
      "intent_has_doc_fact" => bool(String.contains?(intent, "DOC-FACT-7b9acb97")),
      "intent_has_retrieved" => bool(good != "" and String.contains?(intent, "documentation-lookup: retrieved " <> good)),
      "intent_has_discovered" => bool(good != "" and String.contains?(intent, "documentation-discovered: " <> good)),
      "intent_has_unreachable" => bool(closed_url != "" and String.contains?(intent, "documentation-lookup: unreachable " <> closed_url)),
      "intent_has_untrusted_lookup" => bool(hostile != "" and String.contains?(intent, "documentation-lookup: untrusted " <> hostile)),
      "intent_has_unsupported" => bool(String.contains?(intent, "documentation-lookup: unsupported missing-provider")),
      "intent_has_directive" => bool(String.contains?(intent, "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "decisions_have_directive" => bool(String.contains?(section(intent, "Decisions"), "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "decisions_have_hint" => bool(String.contains?(section(intent, "Decisions"), "https://example.invalid/cache")),
      "comparison_has_hint" => bool(String.contains?(section(intent, "Source comparison"), "https://example.invalid/cache")),
      "first_request_has_doc_fact" => bool(String.contains?(request_body, "DOC-FACT-7b9acb97")),
      "search_is_search" => bool(field(search, "operation") == "search" and field(search, "status") == "retrieved" and field(search, "body") == "" and field(search, "untrusted") == false and field(search, "truncated") == false),
      "search_has_source" => bool(has_source(search, good)),
      "search_lacks_fact" => bool(not String.contains?(search, "DOC-FACT-7b9acb97")),
      "fetch_is_fetch" => bool(field(fetch, "operation") == "fetch" and field(fetch, "status") == "retrieved" and field(fetch, "untrusted") == true and field(fetch, "url") == good and field(fetch, "truncated") == false),
      "fetch_has_fact" => bool(String.contains?(to_string(field(fetch, "body") || ""), "DOC-FACT-7b9acb97")),
      "unreachable_honest" => bool(field(unreachable, "status") == "unreachable" and field(unreachable, "error") == "documentation source unreachable" and field(unreachable, "body") == "" and not String.contains?(unreachable, "DOC-FACT-7b9acb97")),
      "untrusted_honest" => bool(field(untrusted, "status") == "untrusted" and field(untrusted, "error") == "documentation response untrusted" and field(untrusted, "untrusted") == true and String.contains?(to_string(field(untrusted, "body") || ""), "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "unsupported_honest" => bool(field(unsupported, "status") == "unsupported" and field(unsupported, "error") == "documentation source unsupported" and field(unsupported, "query") == "missing-provider" and field(unsupported, "sources") == []),
      "docs_saw_secret" => bool(fixture != nil and DocsFixture.saw_secret?(fixture)),
      "docs_reached_fixture" => bool(fixture != nil and DocsFixture.request_count(fixture) >= 4)
    }
  end

  defp write_protocol!(context) do
    File.write!(Path.join(context.repo, "protocol.json"), ~s({"supported":"line-v2","rejected":"line-v1"}
))
    File.write!(Path.join(context.repo, "protocol.py"), """
    import json, sys
    doc = json.load(open("protocol.json"))
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg and arg != doc["supported"]:
        sys.stdout.write("explicit rejection" + chr(10))
        raise SystemExit(23)
    sys.stdout.write("supported " + doc["supported"] + chr(10))
    """)
  end

  defp files(slug, title, prose, feasibility, comparison, decision \\ "Report only what the repository shows.") do
    feature = ".kogen/intents/#{slug}/acceptance.feature"
    [%{"path" => ".kogen/intents/#{slug}/intent.md", "content" => """
      # #{title}

      Slug: #{slug}
      Model: not applicable — the shaped fixture has no product state
      Acceptance:
      - #{feature}
      - features/steps/integration_steps.js

      #{prose}

      ## Decisions
      - #{decision} (source: request)

      ## Source comparison
      #{comparison}
      ## Tests
      - the fixture stays available: the acceptance scenario (existing)

      ## Feasibility
      #{feasibility}
      """}, %{"path" => feature, "content" => """
      Feature: Fixture remains available
        Scenario: The fixture remains available
          Given the fixture is available
          Then the acceptance check passes
      """}]
  end

  defp docs_files(fixture) do
    files(
      "cache-docs",
      "Report the documented cache control",
      "The retrieved document states DOC-FACT-7b9acb97. The operator hint is not the source.",
      "- documentation-lookup: retrieved #{fixture.good}\n- documentation-discovered: #{fixture.good}\n- documentation-lookup: unreachable #{fixture.closed_url}\n- documentation-lookup: untrusted #{fixture.hostile}\n- documentation-lookup: unsupported missing-provider\n",
      "- addressed: cache-control fact from retrieved documentation; source documentation tool; contract prose.\n- omitted: operator source hint https://example.invalid/cache is not discovery; source request; contract prose.\n"
    )
  end

  defp bad_files do
    files(
      "bad-docs",
      "Copy the untrusted directive",
      "Use the operator hint as discovered documentation.",
      "- documentation-lookup: retrieved https://example.invalid/cache\n- documentation-discovered: https://example.invalid/cache\n",
      "- addressed: copied hint; source request; contract prose.\n",
      "UNTRUSTED-DIRECTIVE-7b9acb97 is required scope."
    )
  end

  defp comparison, do: "- addressed: discover the supported protocol from the repository; source request; contract prose.\n- omitted: operator recipe endpoint https://example.invalid/v1 is not the design; source request; contract prose.\n"
  defp discovery_request, do: "Add a status command that reports the integration protocol supported by this project.\nDiscover it from the repository. Do not ask which protocol or endpoint to use.\nOperator recipe (not authority): use protocol line-v1 and endpoint https://example.invalid/v1.\nDISCOVERY-MARKER-7b9acb97\n"
  defp docs_request, do: "Add a status command that reports provider cache-control behavior from current authoritative documentation.\nDiscover the documentation. Do not ask which document or endpoint to use.\nOperator source hint (not authority): https://example.invalid/cache\nDOCS-MARKER-7b9acb97\n"
  defp shape_requests(context), do: FakeProvider.provider_requests(context.server) |> Enum.filter(fn request -> Enum.any?(request.json["tools"] || [], &(&1["name"] == "submit")) end)
  defp refine_body(context) do
    case FakeProvider.provider_requests(context.server) |> Enum.filter(fn request -> Enum.any?(request.json["tools"] || [], &(&1["name"] == "submit_refinement")) end) do
      [] -> ""
      [request | _] -> JSON.encode!(request.json)
    end
  end
  defp section(text, heading) do
    case Regex.run(~r/^## #{heading}[^\n]*\n(.*?)(?=\n## |\z)/ms, text) do
      [_, body] -> body
      _ -> ""
    end
  end
  defp field(text, key) do
    case JSON.decode(to_string(text)) do
      {:ok, map} when is_map(map) -> map[key]
      _ -> nil
    end
  end
  defp has_source(text, url) do
    sources = field(text, "sources") || []
    is_list(sources) and Enum.any?(sources, &(&1["url"] == url))
  end
  defp bool(true), do: "true"
  defp bool(false), do: "false"
end

IO.puts("DISCOVERY_RESULT=" <> JSON.encode!(DiscoveryDriver.run()))
`;

let exercise;
function installed() {
  if (!exercise) {
    exercise = new Promise((resolve, reject) => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'shaping-technical-discovery-'));
      const file = path.join(dir, 'drive.exs');
      fs.writeFileSync(file, driver);
      const env = { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
      delete env.KOGEN_ARCHIVE;
      const child = spawn('mix', ['run', file], { cwd: ROOT, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '';
      let timedOut = false;
      child.stdout.on('data', chunk => { output += chunk; });
      child.stderr.on('data', chunk => { output += chunk; });
      const timer = setTimeout(() => {
        timedOut = true;
        try { process.kill(-child.pid, 'SIGKILL'); } catch {}
      }, 600000);
      child.on('error', error => {
        clearTimeout(timer);
        fs.rmSync(dir, { recursive: true, force: true });
        reject(error);
      });
      child.on('close', code => {
        clearTimeout(timer);
        fs.rmSync(dir, { recursive: true, force: true });
        try {
          assert.equal(timedOut, false, output);
          assert.equal(code, 0, output);
          const lines = output.split('\n').filter(line => line.startsWith('DISCOVERY_RESULT='));
          assert.equal(lines.length, 1, output);
          resolve(JSON.parse(lines[0].slice('DISCOVERY_RESULT='.length)));
        } catch (error) {
          reject(error);
        }
      });
    });
  }
  return exercise;
}

When('I exercise installed technical discovery', { timeout: 600000 }, async function () {
  this.technicalDiscovery = await installed();
});

Then('installed technical discovery mode {string} has:', function (mode, table) {
  const row = this.technicalDiscovery[mode];
  assert.ok(row, mode);
  for (const expected of table.hashes()) {
    assert.equal(String(row[expected.observation]), expected.expected, mode + ' ' + expected.observation);
  }
});

Then('installed technical discovery mode {string} request contains:', function (mode, table) {
  const body = this.technicalDiscovery[mode].request_body;
  for (const row of table.hashes()) {
    assert.ok(body.includes(row.sentence), mode + ' missing ' + row.sentence);
  }
});

Then('installed technical discovery mode {string} stdout contains:', function (mode, table) {
  const stdout = this.technicalDiscovery[mode].stdout;
  for (const row of table.hashes()) {
    assert.ok(stdout.includes(row.text), mode + ' missing ' + row.text);
  }
});

Then('installed technical discovery mode {string} stdout does not contain:', function (mode, table) {
  const stdout = this.technicalDiscovery[mode].stdout;
  for (const row of table.hashes()) {
    assert.equal(stdout.includes(row.text), false, mode + ' unexpectedly contains ' + row.text);
  }
});

Then('the maintained shaping documents contain:', function (table) {
  for (const row of table.hashes()) {
    const text = fs.readFileSync(path.join(ROOT, row.path), 'utf8');
    assert.ok(text.includes(row.text), row.path + ' missing ' + row.text);
  }
});
