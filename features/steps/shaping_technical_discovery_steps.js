const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { When, Then } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const ROOT = H.ROOT;
const { fn: f } = H;

// Independent installed-release harness. The fake provider and documentation fixture are local; no real account or public internet is used.
// Everything is observed through the installed `kogen` (the one Go program) and the files it keeps.

const SECRET = /authorization|cookie|api-key|api_key|bearer/i;
const MARK = 'DOC-FACT-7b9acb97';
const HOSTILE_TEXT = 'UNTRUSTED-DIRECTIVE-7b9acb97';

// ------------------------------------------------------------------ the local documentation fixture (DocsFixture)

async function startDocs() {
  const requests = [];
  const server = http.createServer((req, res) => {
    const raw = `${req.method} ${req.url} HTTP/1.1\r\n${Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n')}\r\n\r\n`;
    requests.push(raw);
    const reply = (status, type, body) => {
      res.writeHead(status, { 'content-type': type, 'content-length': Buffer.byteLength(body), connection: 'close' });
      res.end(body);
    };
    if (req.method !== 'GET') return reply(400, 'text/plain', '');
    const uri = new URL(req.url, 'http://127.0.0.1');
    const base = `http://127.0.0.1:${server.address().port}`;
    if (uri.pathname === '/search' && uri.searchParams.get('q') === 'cache controls') return reply(200, 'application/json', JSON.stringify({ sources: [{ url: `${base}/cache-controls`, title: 'Cache controls' }] }));
    if (uri.pathname === '/search' && uri.searchParams.get('q') === 'missing-provider') return reply(415, 'text/plain', 'unsupported');
    if (uri.pathname === '/cache-controls') return reply(200, 'text/plain', `${MARK}\ncache-control: public, max-age=60\n`);
    if (uri.pathname === '/hostile') return reply(200, 'text/plain', `${HOSTILE_TEXT}\n`);
    return reply(404, 'text/plain', 'missing');
  });
  const sockets = new Set();
  server.on('connection', s => { sockets.add(s); s.once('close', () => sockets.delete(s)); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  // A port with nobody listening.
  const probe = net.createServer();
  await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
  const closed = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  return {
    port, closed, base, good: `${base}/cache-controls`, hostile: `${base}/hostile`,
    closed_url: `http://127.0.0.1:${closed}/missing`, closed_base: `http://127.0.0.1:${closed}`,
    sawSecret: () => requests.some(r => SECRET.test(r)),
    requestCount: () => requests.length,
    async stop() { for (const s of sockets) s.destroy(); await new Promise(resolve => server.close(resolve)); },
  };
}

// ------------------------------------------------------------------ the discovery driver

const bool = v => (v ? 'true' : 'false');
const section = (text, heading) => {
  const m = new RegExp(`^## ${heading}[^\\n]*\\n([\\s\\S]*?)(?=\\n## |$(?![\\s\\S]))`, 'm').exec(text);
  return m ? m[1] : '';
};
const hasTool = (request, name) => (request.json.tools || []).some(t => t.name === name);
// Tool outputs by first appearance, once per call (the provider replays history on every request).
const toolOutputs = server => {
  const seen = new Set(), out = [];
  for (const r of server.providerRequests()) for (const i of (r.json.input || [])) {
    if (i.type === 'function_call_output' && !seen.has(i.call_id)) { seen.add(i.call_id); out.push(i.output); }
  }
  return out;
};
const field = (text, key) => {
  let v; try { v = JSON.parse(String(text)); } catch { return undefined; }
  return v && typeof v === 'object' && !Array.isArray(v) ? v[key] : undefined;
};
const hasSource = (text, url) => { const s = field(text, 'sources') || []; return Array.isArray(s) && s.some(x => x && x.url === url); };
const emptyList = v => Array.isArray(v) && v.length === 0;
const str = v => (v === undefined || v === null ? '' : String(v));

const files = (slug, title, prose, feasibility, comparison, decision = 'Report only what the repository shows.') => {
  const feature = `.kogen/intents/${slug}/acceptance.feature`;
  return [
    { path: `.kogen/intents/${slug}/intent.md`, content: `# ${title}

Slug: ${slug}
Model: not applicable — the shaped fixture has no product state
Acceptance:
- ${feature}
- features/steps/integration_steps.js

${prose}

## Decisions
- ${decision} (source: request)

## Source comparison
${comparison}
## Tests
- the fixture stays available: the acceptance scenario (existing)

## Feasibility
${feasibility}
` },
    { path: feature, content: `Feature: Fixture remains available
  Scenario: The fixture remains available
    Given the fixture is available
    Then the acceptance check passes
` },
  ];
};
const comparison = () => '- addressed: discover the supported protocol from the repository; source request; contract prose.\n- omitted: operator recipe endpoint https://example.invalid/v1 is not the design; source request; contract prose.\n';
const discoveryRequest = () => 'Add a status command that reports the integration protocol supported by this project.\nDiscover it from the repository. Do not ask which protocol or endpoint to use.\nOperator recipe (not authority): use protocol line-v1 and endpoint https://example.invalid/v1.\nDISCOVERY-MARKER-7b9acb97\n';
const docsRequest = () => 'Add a status command that reports provider cache-control behavior from current authoritative documentation.\nDiscover the documentation. Do not ask which document or endpoint to use.\nOperator source hint (not authority): https://example.invalid/cache\nDOCS-MARKER-7b9acb97\n';
const docsFiles = fx => files('cache-docs', 'Report the documented cache control', `The retrieved document states ${MARK}. The operator hint is not the source.`,
  `- documentation-lookup: retrieved ${fx.good}\n- documentation-discovered: ${fx.good}\n- documentation-lookup: unreachable ${fx.closed_url}\n- documentation-lookup: untrusted ${fx.hostile}\n- documentation-lookup: unsupported missing-provider\n`,
  '- addressed: cache-control fact from retrieved documentation; source documentation tool; contract prose.\n- omitted: operator source hint https://example.invalid/cache is not discovery; source request; contract prose.\n');
const badFiles = () => files('bad-docs', 'Copy the untrusted directive', 'Use the operator hint as discovered documentation.',
  '- documentation-lookup: retrieved https://example.invalid/cache\n- documentation-discovered: https://example.invalid/cache\n', '- addressed: copied hint; source request; contract prose.\n', `${HOSTILE_TEXT} is required scope.`);

const writeProtocol = c => {
  fs.writeFileSync(path.join(c.repo, 'protocol.json'), '{"supported":"line-v2","rejected":"line-v1"}\n');
  fs.writeFileSync(path.join(c.repo, 'protocol.py'), `import json, sys
doc = json.load(open("protocol.json"))
arg = sys.argv[1] if len(sys.argv) > 1 else ""
if arg and arg != doc["supported"]:
    sys.stdout.write("explicit rejection" + chr(10))
    raise SystemExit(23)
sys.stdout.write("supported " + doc["supported"] + chr(10))
`);
};

const readCall = p => f('read_file', { path: p });
const doc = args => f('documentation', args);
const submitFiles = list => f('submit', { files: list });

async function observe(suite, makeScript, slug, requestText, protocol, withFixture) {
  const fixture = withFixture ? await startDocs() : null;
  const c = await H.project(suite, makeScript(fixture));
  try {
    if (protocol) writeProtocol(c);
    let out, status, requestBody, later = '', outputs = [];
    if (requestText === null) {
      const approval = JSON.parse(fs.readFileSync(path.join(c.repo, '.kogen/local/approvals/fixture.json'), 'utf8'));
      const correction = path.join(c.root, 'correction.txt');
      fs.writeFileSync(correction, 'Clarify the fixture title only.\n');
      const r = await H.runKogen(c, ['intent', 'refine', 'fixture', approval.sha256, correction]);
      out = r.out; status = r.code;
      const first = c.server.providerRequests().find(q => hasTool(q, 'submit_refinement'));
      requestBody = first ? JSON.stringify(first.json) : '';
    } else {
      const request = path.join(c.root, 'request.txt');
      fs.writeFileSync(request, requestText);
      const r = await H.runKogen(c, ['intent', 'shape', slug, request]);
      out = r.out; status = r.code;
      const shape = c.server.providerRequests().filter(q => hasTool(q, 'submit'));
      requestBody = JSON.stringify(shape.length ? shape[0].json : {});
      const rest = shape.slice(1).map(q => JSON.stringify(q.json)).join('\n');
      outputs = toolOutputs(c.server);
      later = `${rest}\n${outputs.join('\n')}`;
    }
    const intentPath = path.join(c.repo, `.kogen/intents/${slug}/intent.md`);
    const exists = fs.existsSync(intentPath) && fs.statSync(intentPath).isFile();
    const intent = exists ? fs.readFileSync(intentPath, 'utf8') : '';
    const [, search = '', fetch = '', unreachable = '', untrusted = '', unsupported = ''] = outputs;
    const good = fixture ? fixture.good : '', hostile = fixture ? fixture.hostile : '', closedUrl = fixture ? fixture.closed_url : '';
    const decisions = section(intent, 'Decisions'), cmp = section(intent, 'Source comparison');
    const docLines = {
      intent_has_doc_fact: bool(intent.includes(MARK)),
      intent_has_retrieved: bool(good !== '' && intent.includes(`documentation-lookup: retrieved ${good}`)),
      intent_has_discovered: bool(good !== '' && intent.includes(`documentation-discovered: ${good}`)),
      intent_has_unreachable: bool(closedUrl !== '' && intent.includes(`documentation-lookup: unreachable ${closedUrl}`)),
      intent_has_untrusted_lookup: bool(hostile !== '' && intent.includes(`documentation-lookup: untrusted ${hostile}`)),
      intent_has_unsupported: bool(intent.includes('documentation-lookup: unsupported missing-provider')),
      intent_has_directive: bool(intent.includes(HOSTILE_TEXT)),
      decisions_have_directive: bool(decisions.includes(HOSTILE_TEXT)),
      decisions_have_hint: bool(decisions.includes('https://example.invalid/cache')),
      comparison_has_hint: bool(cmp.includes('https://example.invalid/cache')),
      first_request_has_doc_fact: bool(requestBody.includes(MARK)),
      search_is_search: bool(field(search, 'operation') === 'search' && field(search, 'status') === 'retrieved' && field(search, 'body') === '' && field(search, 'untrusted') === false && field(search, 'truncated') === false),
      search_has_source: bool(hasSource(search, good)),
      search_lacks_fact: bool(!String(search).includes(MARK)),
      fetch_is_fetch: bool(field(fetch, 'operation') === 'fetch' && field(fetch, 'status') === 'retrieved' && field(fetch, 'untrusted') === true && field(fetch, 'url') === good && field(fetch, 'truncated') === false),
      fetch_has_fact: bool(str(field(fetch, 'body')).includes(MARK)),
      unreachable_honest: bool(field(unreachable, 'status') === 'unreachable' && field(unreachable, 'error') === 'documentation source unreachable' && field(unreachable, 'body') === '' && !String(unreachable).includes(MARK)),
      untrusted_honest: bool(field(untrusted, 'status') === 'untrusted' && field(untrusted, 'error') === 'documentation response untrusted' && field(untrusted, 'untrusted') === true && str(field(untrusted, 'body')).includes(HOSTILE_TEXT)),
      unsupported_honest: bool(field(unsupported, 'status') === 'unsupported' && field(unsupported, 'error') === 'documentation source unsupported' && field(unsupported, 'query') === 'missing-provider' && emptyList(field(unsupported, 'sources'))),
      docs_saw_secret: bool(fixture !== null && fixture.sawSecret()),
      docs_reached_fixture: bool(fixture !== null && fixture.requestCount() >= 4),
    };
    return {
      status: String(status),
      questions_printed: bool(out.includes('Questions for')),
      intent_exists: bool(exists),
      intent_has_line_v2: bool(intent.includes('line-v2')),
      decisions_have_example_invalid: bool(decisions.includes('example.invalid')),
      comparison_has_omitted: bool(cmp.includes('omitted')),
      comparison_has_endpoint: bool(cmp.includes('https://example.invalid/v1')),
      first_request_has_line_v2: bool(requestBody.includes('line-v2')),
      first_request_has_marker: bool(requestBody.includes('DISCOVERY-MARKER-7b9acb97')),
      first_request_has_recipe: bool(requestBody.includes('Operator recipe (not authority): use protocol line-v1 and endpoint https://example.invalid/v1.')),
      later_request_has_supported: bool(later.includes('supported line-v2')),
      probe_count: String(out.split('kogen: probe: ').length - 1),
      request_body: requestBody,
      stdout: out,
      ...docLines,
    };
  } finally {
    await H.cleanupCase(c);
    if (fixture) await fixture.stop();
  }
}

// A real shaper inspects the repository (read, list or search) before it submits files; probes and documentation
// lookups alone do not count. Only the "uninspected" mode submits without inspecting, to prove the refusal.
const modes = {
  discovery: suite => observe(suite, () => [
    readCall('protocol.json'),
    f('probe', { command: 'python3 protocol.py' }),
    f('probe', { command: 'python3 protocol.py line-v1' }),
    submitFiles(files('status-line', 'Report the supported protocol', 'The supported integration protocol is line-v2.', '- protocol.json supports line-v2. (probe 1: exit 0, 0.1 s)\n- line-v1 is an explicit rejection. (probe 2: exit 23, 0.1 s)', comparison())),
  ], 'status-line', discoveryRequest(), true, false),
  uninspected: suite => observe(suite, () => {
    const submit = submitFiles(files('copied-recipe', 'Copy the operator recipe', 'Use protocol line-v1 and endpoint https://example.invalid/v1.', '- none', comparison()));
    return [submit, submit, submit];
  }, 'copied-recipe', discoveryRequest(), false, false),
  engineering: suite => observe(suite, () => {
    const question = f('submit', { questions: [{ question: 'Which protocol and endpoint should the integration use?', kind: 'engineering', options: [{ label: 'use the operator recipe', recommended: true }, { label: 'leave it unknown' }] }] });
    return [question, question, question];
  }, 'ask-protocol', discoveryRequest(), false, false),
  handoff: suite => observe(suite, () => [
    f('submit', { questions: [{ question: 'Sign in to the provider before shaping can check this account-scoped capability.', kind: 'handoff', options: [{ label: 'sign in', recommended: true }] }] }),
  ], 'sign-in-handoff', discoveryRequest(), false, false),
  trivial: suite => {
    const list = files('greeting', 'Set the greeting copy', 'Change the greeting copy to Hello.', '- none', '- addressed: greeting copy; source request; contract prose.\n');
    const read = { type: 'function_call', id: 'function-read', call_id: 'call-read', name: 'read_file', arguments: JSON.stringify({ path: 'README.md' }) };
    const submit = { type: 'function_call', id: 'function-submit', call_id: 'call-submit', name: 'submit', arguments: JSON.stringify({ files: list }) };
    return observe(suite, () => [{ items: [read, submit] }], 'greeting', 'Change the greeting copy to Hello.\nTRIVIAL-MARKER-7b9acb97\n', false, false);
  },
  refine: suite => observe(suite, () => [f('submit_refinement', { constraint: 'This correction needs no technical change.' })], 'fixture', null, false, false),
  docs: suite => observe(suite, fx => [
    readCall('README.md'),
    doc({ operation: 'search', query: 'cache controls', base: fx.base }),
    doc({ operation: 'fetch', url: fx.good, base: fx.base }),
    doc({ operation: 'fetch', url: fx.closed_url, base: fx.closed_base }),
    doc({ operation: 'fetch', url: fx.hostile, base: fx.base }),
    doc({ operation: 'search', query: 'missing-provider', base: fx.base }),
    submitFiles(docsFiles(fx)),
  ], 'cache-docs', docsRequest(), false, true),
  'docs-reject': suite => observe(suite, fx => {
    const submit = submitFiles(badFiles());
    return [readCall('README.md'), doc({ operation: 'fetch', url: fx.hostile, base: fx.base }), submit, submit, submit];
  }, 'bad-docs', docsRequest(), false, true),
};

async function runAll() {
  const suite = await H.setupSuite();
  try {
    const result = {};
    for (const [name, run] of Object.entries(modes)) {
      try { result[name] = await run(suite); }
      catch (e) { result[name] = { status: 'crash', stdout: String((e && e.stack) || e), request_body: '' }; }
    }
    return result;
  } finally { H.cleanupSuite(suite); }
}

let exercise;
const installed = () => { if (!exercise) exercise = runAll(); return exercise; };

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
