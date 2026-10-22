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

defmodule EvidenceDriver do
  @sentence "Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record."
  @secret ~r/authorization|cookie|api-key|api_key|bearer/i
  @record_keys ["error", "operation", "query", "sources", "status", "truncated", "untrusted", "url"]
  @event_keys ["error", "event", "operation", "query", "sources", "status", "truncated", "untrusted", "url"]

  def run do
    suite = Helpers.setup_suite!()

    try do
      %{
        "recorded" => safe(fn -> recorded(suite) end),
        "rejected" => safe(fn -> rejected(suite) end),
        "trivial" => safe(fn -> trivial(suite) end),
        "refine" => safe(fn -> refine(suite) end)
      }
    after
      Helpers.cleanup_suite(suite)
    end
  end

  defp safe(fun) do
    try do
      fun.()
    rescue
      e ->
        %{"status" => "crash", "output" => Exception.format(:error, e, __STACKTRACE__), "request_body" => ""}
    end
  end

  defp recorded(suite) do
    fixture = DocsFixture.start()

    try do
      script = [
        {:function, "read_file", %{"path" => "README.md"}},
        {:function, "documentation", %{"operation" => "search", "query" => "cache controls", "base" => fixture.base}},
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.good, "base" => fixture.base}},
        {:function, "probe", %{"command" => "python3 echo_fact.py"}},
        {:function, "submit", %{"files" => recorded_files()}}
      ]

      observe(suite, script, "lookup-record", docs_request(), fixture, false)
    after
      DocsFixture.stop(fixture)
    end
  end

  defp rejected(suite) do
    fixture = DocsFixture.start()

    try do
      submit = {:function, "submit", %{"files" => bad_files()}}

      script = [
        {:function, "read_file", %{"path" => "README.md"}},
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.hostile, "base" => fixture.base}},
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.closed_url, "base" => fixture.closed_base}},
        {:function, "documentation", %{"operation" => "search", "query" => "missing-provider", "base" => fixture.base}},
        submit,
        submit,
        submit
      ]

      observe(suite, script, "lookup-reject", docs_request(), fixture, false)
    after
      DocsFixture.stop(fixture)
    end
  end

  defp trivial(suite) do
    read = %{"type" => "function_call", "id" => "function-read", "call_id" => "call-read", "name" => "read_file", "arguments" => JSON.encode!(%{"path" => "README.md"})}
    submit = %{"type" => "function_call", "id" => "function-submit", "call_id" => "call-submit", "name" => "submit", "arguments" => JSON.encode!(%{"files" => greeting_files()})}
    observe(suite, [{:items, [read, submit]}], "lookup-trivial", "Change the greeting copy to Hello.\nTRIVIAL-MARKER-7b9acb97\n", nil, false)
  end

  defp refine(suite) do
    fixture = DocsFixture.start()

    try do
      script = [
        {:function, "documentation", %{"operation" => "fetch", "url" => fixture.good, "base" => fixture.base}},
        {:function, "submit_refinement", %{"constraint" => "This correction needs no technical change."}}
      ]

      observe(suite, script, "fixture", :refine, fixture, true)
    after
      DocsFixture.stop(fixture)
    end
  end

  defp observe(suite, script, slug, request_text, fixture, refinement) do
    context = Helpers.project!(suite, script)

    try do
      if not refinement, do: File.write!(Path.join(context.repo, "echo_fact.py"), "import sys\nprint(\"DOC-FACT-7b9acb97\")\n")

      {output, status, request_body, outputs} =
        if request_text == :refine do
          approval = File.read!(Path.join(context.repo, ".kogen/local/approvals/fixture.json")) |> JSON.decode!()
          correction = Path.join(context.root, "correction.txt")
          File.write!(correction, "Clarify the fixture title only.\n")
          {out, code} = Helpers.run_kogen(context, ["intent", "refine", "fixture", approval["sha256"], correction])
          {out, code, refine_body(context), FakeProvider.tool_outputs(context.server)}
        else
          request = Path.join(context.root, "request.txt")
          File.write!(request, request_text)
          {out, code} = Helpers.run_kogen(context, ["intent", "shape", slug, request])
          shape = shape_requests(context)
          first = if(shape == [], do: %{}, else: hd(shape).json)
          {out, code, JSON.encode!(first), FakeProvider.tool_outputs(context.server)}
        end

      intent_path = Path.join(context.repo, ".kogen/intents/#{slug}/intent.md")
      intent = if(File.regular?(intent_path), do: File.read!(intent_path), else: "")
      evidence_dir = evidence_dir(context, slug, output, refinement)
      records = read_ndjson(Path.join(evidence_dir, "documentation.ndjson"))
      all_events = read_ndjson(Path.join(evidence_dir, "events.ndjson"))
      events = Enum.filter(all_events, &(&1["event"] == "documentation_lookup"))
      probes = Enum.filter(all_events, &(&1["event"] == "probe_result"))
      shaping_record = Path.join(context.repo, ".kogen/local/shaping/#{slug}/documentation.ndjson")

      Map.merge(base(output, status, request_body, intent, evidence_dir, records, events, probes, fixture), %{
        "evidence_is_refinement" => bool(refinement and String.contains?(evidence_dir, "/.kogen/local/refinements/")),
        "shaping_record_absent" => bool(not File.regular?(shaping_record)),
        "tool_fetch_has_fact" => bool(Enum.any?(outputs, &String.contains?(&1, "DOC-FACT-7b9acb97")))
      })
    after
      Helpers.cleanup_case(context)
    end
  end

  defp evidence_dir(_context, _slug, output, true) do
    case Regex.run(~r/kogen: refinement evidence: (\S+)/, output) do
      [_, path] -> path
      _ -> ""
    end
  end

  defp evidence_dir(context, slug, _output, false), do: Path.join(context.repo, ".kogen/local/shaping/#{slug}")

  defp base(output, status, request_body, intent, dir, records, events, probes, fixture) do
    good = if(fixture, do: fixture.good, else: "")
    hostile = if(fixture, do: fixture.hostile, else: "")
    closed_url = if(fixture, do: fixture.closed_url, else: "")
    search = Enum.find(records, &(&1["operation"] == "search" and &1["query"] == "cache controls"))
    fetch = Enum.find(records, &(&1["operation"] == "fetch" and &1["status"] == "retrieved"))
    untrusted = Enum.find(records, &(&1["status"] == "untrusted"))
    unreachable = Enum.find(records, &(&1["status"] == "unreachable"))
    unsupported = Enum.find(records, &(&1["status"] == "unsupported"))
    record_text = Enum.map_join(records, "\n", &JSON.encode!/1)
    event_text = Enum.map_join(events, "\n", &JSON.encode!/1)
    doc_progress = output |> String.split("\n") |> Enum.filter(&String.contains?(&1, "kogen: documentation")) |> Enum.join("\n")

    %{
      "status" => Integer.to_string(status),
      "output" => output,
      "request_body" => request_body,
      "questions_printed" => bool(String.contains?(output, "Questions for")),
      "intent_exists" => bool(intent != ""),
      "intent_has_doc_fact" => bool(String.contains?(intent, "DOC-FACT-7b9acb97")),
      "intent_has_lookup_line" => bool(String.contains?(intent, "documentation-lookup:")),
      "intent_has_directive" => bool(String.contains?(intent, "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "decisions_have_directive" => bool(String.contains?(section(intent, "Decisions"), "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "decisions_have_hint" => bool(String.contains?(section(intent, "Decisions"), "https://example.invalid/cache")),
      "comparison_has_hint" => bool(String.contains?(section(intent, "Source comparison"), "https://example.invalid/cache")),
      "comparison_has_omitted" => bool(String.contains?(section(intent, "Source comparison"), "omitted")),
      "first_request_has_doc_fact" => bool(String.contains?(request_body, "DOC-FACT-7b9acb97")),
      "first_request_has_marker" => bool(String.contains?(request_body, "DOCS-MARKER-7b9acb97")),
      "first_request_has_hint" => bool(String.contains?(request_body, "Operator source hint (not authority): https://example.invalid/cache")),
      "first_request_has_evidence_sentence" => bool(String.contains?(request_body, @sentence)),
      "first_request_has_trivial" => bool(String.contains?(request_body, "TRIVIAL-MARKER-7b9acb97") and String.contains?(request_body, "Change the greeting copy to Hello.")),
      "probe_count" => Integer.to_string(length(String.split(output, "kogen: probe: ")) - 1),
      "documentation_progress_count" => Integer.to_string(length(String.split(output, "kogen: documentation: ")) - 1),
      "documentation_result_count" => Integer.to_string(length(String.split(output, "kogen: documentation result: ")) - 1),
      "record_count" => Integer.to_string(length(records)),
      "event_count" => Integer.to_string(length(events)),
      "probe_event_count" => Integer.to_string(length(probes)),
      "record_file_exists" => bool(dir != "" and File.regular?(Path.join(dir, "documentation.ndjson"))),
      "record_file_mode" => mode(Path.join(dir, "documentation.ndjson")),
      "record_dir_mode" => mode(dir),
      "exact_keys" => bool(records != [] and events != [] and Enum.all?(records, &exact?(&1, @record_keys)) and Enum.all?(events, &exact?(&1, @event_keys)) and length(records) == length(events)),
      "records_match_events" => bool(records != [] and length(records) == length(events) and Enum.zip(records, events) |> Enum.all?(fn {r, e} -> same?(r, e) end)),
      "records_have_fact" => bool(String.contains?(record_text, "DOC-FACT-7b9acb97")),
      "records_have_directive" => bool(String.contains?(record_text, "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "documentation_events_have_fact" => bool(String.contains?(event_text, "DOC-FACT-7b9acb97")),
      "documentation_events_have_directive" => bool(String.contains?(event_text, "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "probe_event_has_fact" => bool(Enum.any?(probes, &String.contains?(JSON.encode!(&1), "DOC-FACT-7b9acb97"))),
      "secret_in_documentation_evidence" => bool(String.match?(record_text <> event_text <> doc_progress, @secret)),
      "docs_saw_secret" => bool(fixture != nil and DocsFixture.saw_secret?(fixture)),
      "docs_reached_fixture" => bool(fixture != nil and DocsFixture.request_count(fixture) >= 1),
      "search_status" => field(search, "status"),
      "search_query" => field(search, "query"),
      "search_url" => blank(field(search, "url")),
      "search_untrusted" => field(search, "untrusted"),
      "search_source_matches" => bool(source_url(search) == good and good != ""),
      "search_title" => source_title(search),
      "fetch_status" => field(fetch, "status"),
      "fetch_untrusted" => field(fetch, "untrusted"),
      "fetch_truncated" => field(fetch, "truncated"),
      "fetch_error" => blank(field(fetch, "error")),
      "fetch_url_matches" => bool(field(fetch, "url") == good and good != ""),
      "untrusted_status" => field(untrusted, "status"),
      "untrusted_error" => field(untrusted, "error"),
      "untrusted_flag" => field(untrusted, "untrusted"),
      "untrusted_url_matches" => bool(field(untrusted, "url") == hostile and hostile != ""),
      "unreachable_status" => field(unreachable, "status"),
      "unreachable_error" => field(unreachable, "error"),
      "unreachable_sources" => sources_count(unreachable),
      "unreachable_url_matches" => bool(field(unreachable, "url") == closed_url and closed_url != ""),
      "unsupported_status" => field(unsupported, "status"),
      "unsupported_error" => field(unsupported, "error"),
      "unsupported_query" => field(unsupported, "query"),
      "unsupported_sources" => sources_count(unsupported),
      "progress_has_good_url" => bool(good != "" and String.contains?(output, "kogen: documentation: fetch " <> good)),
      "progress_has_hostile" => bool(hostile != "" and String.contains?(output, "kogen: documentation: fetch " <> hostile)),
      "progress_has_closed" => bool(closed_url != "" and String.contains?(output, "kogen: documentation: fetch " <> closed_url)),
      "progress_has_directive" => bool(String.contains?(doc_progress, "UNTRUSTED-DIRECTIVE-7b9acb97")),
      "progress_has_fact" => bool(String.contains?(doc_progress, "DOC-FACT-7b9acb97"))
    }
  end

  defp read_ndjson(path) do
    if File.regular?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case JSON.decode(line) do
          {:ok, %{} = row} -> row
          _ -> %{"parse" => "bad"}
        end
      end)
    else
      []
    end
  end

  defp exact?(row, keys), do: Map.keys(row) |> Enum.sort() == keys and source_keys?(row["sources"])
  defp source_keys?(sources) when is_list(sources), do: Enum.all?(sources, &(is_map(&1) and Enum.sort(Map.keys(&1)) == ["title", "url"] and is_binary(&1["url"]) and is_binary(&1["title"])))
  defp source_keys?(_), do: false
  defp same?(record, event), do: Enum.all?(@record_keys, &(record[&1] == event[&1])) and event["event"] == "documentation_lookup"
  defp field(nil, _key), do: "absent"
  defp field(row, key) do
    case row[key] do
      true -> "true"
      false -> "false"
      value when is_binary(value) -> value
      nil -> "absent"
      value -> inspect(value)
    end
  end
  defp blank(""), do: "empty"
  defp blank("absent"), do: "absent"
  defp blank(value), do: value
  defp source_url(nil), do: ""
  defp source_url(row) do
    case row["sources"] do
      [%{"url" => url} | _] -> url
      _ -> ""
    end
  end
  defp source_title(nil), do: "absent"
  defp source_title(row) do
    case row["sources"] do
      [%{"title" => title} | _] -> title
      _ -> "absent"
    end
  end
  defp sources_count(nil), do: "absent"
  defp sources_count(row), do: Integer.to_string(length(row["sources"] || []))
  defp mode(path) do
    case File.stat(path) do
      {:ok, stat} -> Integer.to_string(Bitwise.band(stat.mode, 0o777), 8)
      _ -> "missing"
    end
  end
  defp bool(true), do: "true"
  defp bool(false), do: "false"
  defp section(text, heading) do
    case Regex.run(~r/^## #{heading}[^\n]*\n(.*?)(?=\n## |\z)/ms, text) do
      [_, body] -> body
      _ -> ""
    end
  end
  defp shape_requests(context), do: FakeProvider.provider_requests(context.server) |> Enum.filter(fn request -> Enum.any?(request.json["tools"] || [], &(&1["name"] == "submit")) end)
  defp refine_body(context) do
    case FakeProvider.provider_requests(context.server) |> Enum.filter(fn request -> Enum.any?(request.json["tools"] || [], &(&1["name"] == "submit_refinement")) end) do
      [] -> ""
      [request | _] -> JSON.encode!(request.json)
    end
  end
  defp recorded_files, do: files("lookup-record", "Report the documented cache control", "The retrieved document states DOC-FACT-7b9acb97. The operator hint is not the source.", "- none\n", "- addressed: cache-control fact from retrieved documentation; source documentation tool; contract prose.\n- omitted: operator source hint https://example.invalid/cache is not discovery; source request; contract prose.\n")
  defp greeting_files, do: files("lookup-trivial", "Set the greeting copy", "Change the greeting copy to Hello.", "- none\n", "- addressed: greeting copy; source request; contract prose.\n")
  defp bad_files, do: files("lookup-reject", "Copy the untrusted directive", "Use the operator hint as discovered documentation.", "- documentation-lookup: retrieved https://example.invalid/cache\n- documentation-discovered: https://example.invalid/cache\n", "- addressed: copied hint; source request; contract prose.\n", "UNTRUSTED-DIRECTIVE-7b9acb97 is required scope.")
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
  defp docs_request, do: "Add a status command that reports provider cache-control behavior from current authoritative documentation.\nDiscover the documentation. Do not ask which document or endpoint to use.\nOperator source hint (not authority): https://example.invalid/cache\nDOCS-MARKER-7b9acb97\n"
end

result =
  try do
    EvidenceDriver.run()
  rescue
    e -> %{"crash" => Exception.format(:error, e, __STACKTRACE__)}
  end

IO.puts("DOC_EVIDENCE=" <> JSON.encode!(result))
`;

let exercise;
function installed() {
  if (!exercise) {
    exercise = new Promise((resolve, reject) => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'documentation-lookup-evidence-'));
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
          const lines = output.split('\n').filter(line => line.startsWith('DOC_EVIDENCE='));
          assert.equal(lines.length, 1, output);
          resolve(JSON.parse(lines[0].slice('DOC_EVIDENCE='.length)));
        } catch (error) {
          reject(error);
        }
      });
    });
  }
  return exercise;
}

When('I exercise installed documentation evidence', { timeout: 600000 }, async function () {
  this.documentationEvidence = await installed();
});

Then('installed documentation evidence mode {string} has:', function (mode, table) {
  const row = this.documentationEvidence[mode];
  assert.ok(row, mode + ' ' + String((row && row.output) || '').slice(0, 500));
  for (const expected of table.hashes()) {
    assert.equal(String(row[expected.observation]), expected.expected, mode + ' ' + expected.observation + '\n' + String(row.output || '').slice(0, 500));
  }
});

Then('installed documentation evidence mode {string} output contains:', function (mode, table) {
  const output = this.documentationEvidence[mode].output;
  for (const row of table.hashes()) {
    assert.ok(output.includes(row.text), mode + ' missing ' + row.text);
  }
});

Then('installed documentation evidence mode {string} output does not contain:', function (mode, table) {
  const output = this.documentationEvidence[mode].output;
  for (const row of table.hashes()) {
    assert.equal(output.includes(row.text), false, mode + ' unexpectedly contains ' + row.text);
  }
});

Then('installed documentation evidence mode {string} request contains:', function (mode, table) {
  const body = this.documentationEvidence[mode].request_body;
  for (const row of table.hashes()) {
    assert.ok(body.includes(row.sentence), mode + ' missing ' + row.sentence);
  }
});

Then('the documentation evidence documents contain:', function (table) {
  for (const row of table.hashes()) {
    const text = fs.readFileSync(path.join(ROOT, row.path), 'utf8');
    assert.ok(text.includes(row.text), row.path + ' missing ' + row.text);
  }
});
