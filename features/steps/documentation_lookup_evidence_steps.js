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

const SENTENCE = 'Kogen records each documentation tool lookup as its own progress line, shaping event and retained record; a probe transcript and an optional Intent provenance line are not that record.';
const SECRET = /authorization|cookie|api-key|api_key|bearer/i;
const RECORD_KEYS = ['error', 'operation', 'query', 'sources', 'status', 'truncated', 'untrusted', 'url'];
const EVENT_KEYS = ['error', 'event', 'operation', 'query', 'sources', 'status', 'truncated', 'untrusted', 'url'];
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

// ------------------------------------------------------------------ the evidence driver

const bool = v => (v ? 'true' : 'false');
const readNdjson = file => {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) return [];
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => {
    try { const row = JSON.parse(line); return row && typeof row === 'object' && !Array.isArray(row) ? row : { parse: 'bad' }; } catch { return { parse: 'bad' }; }
  });
};
const sortedKeys = o => Object.keys(o).sort();
const sameList = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const sourceKeys = sources => Array.isArray(sources) && sources.every(s => s && typeof s === 'object' && sameList(sortedKeys(s), ['title', 'url']) && typeof s.url === 'string' && typeof s.title === 'string');
const exact = (row, keys) => sameList(sortedKeys(row), keys) && sourceKeys(row.sources);
const same = (record, event) => RECORD_KEYS.every(k => JSON.stringify(record[k]) === JSON.stringify(event[k])) && event.event === 'documentation_lookup';
const field = (row, key) => {
  if (!row) return 'absent';
  const v = row[key];
  if (v === true) return 'true';
  if (v === false) return 'false';
  if (typeof v === 'string') return v;
  if (v === undefined || v === null) return 'absent';
  return JSON.stringify(v);
};
const blank = v => (v === '' ? 'empty' : v);
const sourceUrl = row => (row && Array.isArray(row.sources) && row.sources[0] && row.sources[0].url) || '';
const sourceTitle = row => (row && Array.isArray(row.sources) && row.sources[0] && row.sources[0].title) || 'absent';
const sourcesCount = row => (row ? String((row.sources || []).length) : 'absent');
const mode = p => { try { return (fs.statSync(p).mode & 0o777).toString(8); } catch { return 'missing'; } };
const section = (text, heading) => {
  const m = new RegExp(`^## ${heading}[^\\n]*\\n([\\s\\S]*?)(?=\\n## |$(?![\\s\\S]))`, 'm').exec(text);
  return m ? m[1] : '';
};
const count = (text, needle) => text.split(needle).length - 1;
const hasTool = (request, name) => (request.json.tools || []).some(t => t.name === name);

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
const recordedFiles = () => files('lookup-record', 'Report the documented cache control', `The retrieved document states ${MARK}. The operator hint is not the source.`, '- none\n', '- addressed: cache-control fact from retrieved documentation; source documentation tool; contract prose.\n- omitted: operator source hint https://example.invalid/cache is not discovery; source request; contract prose.\n');
const greetingFiles = () => files('lookup-trivial', 'Set the greeting copy', 'Change the greeting copy to Hello.', '- none\n', '- addressed: greeting copy; source request; contract prose.\n');
const badFiles = () => files('lookup-reject', 'Copy the untrusted directive', 'Use the operator hint as discovered documentation.', '- documentation-lookup: retrieved https://example.invalid/cache\n- documentation-discovered: https://example.invalid/cache\n', '- addressed: copied hint; source request; contract prose.\n', `${HOSTILE_TEXT} is required scope.`);
const docsRequest = () => 'Add a status command that reports provider cache-control behavior from current authoritative documentation.\nDiscover the documentation. Do not ask which document or endpoint to use.\nOperator source hint (not authority): https://example.invalid/cache\nDOCS-MARKER-7b9acb97\n';

async function observe(suite, makeScript, slug, requestText, withFixture, refinement) {
  const fixture = withFixture ? await startDocs() : null;
  const c = await H.project(suite, makeScript(fixture));
  try {
    if (!refinement) fs.writeFileSync(path.join(c.repo, 'echo_fact.py'), 'import sys\nprint("DOC-FACT-7b9acb97")\n');
    let out, status, requestBody;
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
    }
    const outputs = c.server.toolOutputs();
    const intentPath = path.join(c.repo, `.kogen/intents/${slug}/intent.md`);
    const intent = fs.existsSync(intentPath) && fs.statSync(intentPath).isFile() ? fs.readFileSync(intentPath, 'utf8') : '';
    let dir;
    if (refinement) { const m = /kogen: refinement evidence: (\S+)/.exec(out); dir = m ? m[1] : ''; }
    else dir = path.join(c.repo, `.kogen/local/shaping/${slug}`);
    const records = readNdjson(path.join(dir, 'documentation.ndjson'));
    const allEvents = readNdjson(path.join(dir, 'events.ndjson'));
    const events = allEvents.filter(e => e.event === 'documentation_lookup');
    const probes = allEvents.filter(e => e.event === 'probe_result');
    const shapingRecord = path.join(c.repo, `.kogen/local/shaping/${slug}/documentation.ndjson`);
    const row = base({ out, status, requestBody, intent, dir, records, events, probes, fixture });
    return {
      ...row,
      evidence_is_refinement: bool(refinement && dir.includes('/.kogen/local/refinements/')),
      shaping_record_absent: bool(!(fs.existsSync(shapingRecord) && fs.statSync(shapingRecord).isFile())),
      tool_fetch_has_fact: bool(outputs.some(o => String(o).includes(MARK))),
    };
  } finally {
    await H.cleanupCase(c);
    if (fixture) await fixture.stop();
  }
}

function base({ out, status, requestBody, intent, dir, records, events, probes, fixture }) {
  const good = fixture ? fixture.good : '', hostile = fixture ? fixture.hostile : '', closedUrl = fixture ? fixture.closed_url : '';
  const search = records.find(r => r.operation === 'search' && r.query === 'cache controls');
  const fetch = records.find(r => r.operation === 'fetch' && r.status === 'retrieved');
  const untrusted = records.find(r => r.status === 'untrusted');
  const unreachable = records.find(r => r.status === 'unreachable');
  const unsupported = records.find(r => r.status === 'unsupported');
  const recordText = records.map(r => JSON.stringify(r)).join('\n');
  const eventText = events.map(e => JSON.stringify(e)).join('\n');
  const docProgress = out.split('\n').filter(l => l.includes('kogen: documentation')).join('\n');
  const decisions = section(intent, 'Decisions'), comparison = section(intent, 'Source comparison');
  return {
    status: String(status),
    output: out,
    request_body: requestBody,
    questions_printed: bool(out.includes('Questions for')),
    intent_exists: bool(intent !== ''),
    intent_has_doc_fact: bool(intent.includes(MARK)),
    intent_has_lookup_line: bool(intent.includes('documentation-lookup:')),
    intent_has_directive: bool(intent.includes(HOSTILE_TEXT)),
    decisions_have_directive: bool(decisions.includes(HOSTILE_TEXT)),
    decisions_have_hint: bool(decisions.includes('https://example.invalid/cache')),
    comparison_has_hint: bool(comparison.includes('https://example.invalid/cache')),
    comparison_has_omitted: bool(comparison.includes('omitted')),
    first_request_has_doc_fact: bool(requestBody.includes(MARK)),
    first_request_has_marker: bool(requestBody.includes('DOCS-MARKER-7b9acb97')),
    first_request_has_hint: bool(requestBody.includes('Operator source hint (not authority): https://example.invalid/cache')),
    first_request_has_evidence_sentence: bool(requestBody.includes(SENTENCE)),
    first_request_has_trivial: bool(requestBody.includes('TRIVIAL-MARKER-7b9acb97') && requestBody.includes('Change the greeting copy to Hello.')),
    probe_count: String(count(out, 'kogen: probe: ')),
    documentation_progress_count: String(count(out, 'kogen: documentation: ')),
    documentation_result_count: String(count(out, 'kogen: documentation result: ')),
    record_count: String(records.length),
    event_count: String(events.length),
    probe_event_count: String(probes.length),
    record_file_exists: bool(dir !== '' && fs.existsSync(path.join(dir, 'documentation.ndjson')) && fs.statSync(path.join(dir, 'documentation.ndjson')).isFile()),
    record_file_mode: mode(path.join(dir, 'documentation.ndjson')),
    record_dir_mode: mode(dir),
    exact_keys: bool(records.length > 0 && events.length > 0 && records.every(r => exact(r, RECORD_KEYS)) && events.every(e => exact(e, EVENT_KEYS)) && records.length === events.length),
    records_match_events: bool(records.length > 0 && records.length === events.length && records.every((r, i) => same(r, events[i]))),
    records_have_fact: bool(recordText.includes(MARK)),
    records_have_directive: bool(recordText.includes(HOSTILE_TEXT)),
    documentation_events_have_fact: bool(eventText.includes(MARK)),
    documentation_events_have_directive: bool(eventText.includes(HOSTILE_TEXT)),
    probe_event_has_fact: bool(probes.some(p => JSON.stringify(p).includes(MARK))),
    secret_in_documentation_evidence: bool(SECRET.test(recordText + eventText + docProgress)),
    docs_saw_secret: bool(fixture !== null && fixture.sawSecret()),
    docs_reached_fixture: bool(fixture !== null && fixture.requestCount() >= 1),
    search_status: field(search, 'status'),
    search_query: field(search, 'query'),
    search_url: blank(field(search, 'url')),
    search_untrusted: field(search, 'untrusted'),
    search_source_matches: bool(sourceUrl(search) === good && good !== ''),
    search_title: sourceTitle(search),
    fetch_status: field(fetch, 'status'),
    fetch_untrusted: field(fetch, 'untrusted'),
    fetch_truncated: field(fetch, 'truncated'),
    fetch_error: blank(field(fetch, 'error')),
    fetch_url_matches: bool(field(fetch, 'url') === good && good !== ''),
    untrusted_status: field(untrusted, 'status'),
    untrusted_error: field(untrusted, 'error'),
    untrusted_flag: field(untrusted, 'untrusted'),
    untrusted_url_matches: bool(field(untrusted, 'url') === hostile && hostile !== ''),
    unreachable_status: field(unreachable, 'status'),
    unreachable_error: field(unreachable, 'error'),
    unreachable_sources: sourcesCount(unreachable),
    unreachable_url_matches: bool(field(unreachable, 'url') === closedUrl && closedUrl !== ''),
    unsupported_status: field(unsupported, 'status'),
    unsupported_error: field(unsupported, 'error'),
    unsupported_query: field(unsupported, 'query'),
    unsupported_sources: sourcesCount(unsupported),
    progress_has_good_url: bool(good !== '' && out.includes(`kogen: documentation: fetch ${good}`)),
    progress_has_hostile: bool(hostile !== '' && out.includes(`kogen: documentation: fetch ${hostile}`)),
    progress_has_closed: bool(closedUrl !== '' && out.includes(`kogen: documentation: fetch ${closedUrl}`)),
    progress_has_directive: bool(docProgress.includes(HOSTILE_TEXT)),
    progress_has_fact: bool(docProgress.includes(MARK)),
  };
}

const readCall = path => f('read_file', { path });
const doc = (args) => f('documentation', args);
const submitFiles = list => f('submit', { files: list });

async function recorded(suite) {
  return observe(suite, fx => [
    readCall('README.md'),
    doc({ operation: 'search', query: 'cache controls', base: fx.base }),
    doc({ operation: 'fetch', url: fx.good, base: fx.base }),
    f('probe', { command: 'python3 echo_fact.py' }),
    submitFiles(recordedFiles()),
  ], 'lookup-record', docsRequest(), true, false);
}
async function rejected(suite) {
  return observe(suite, fx => {
    const submit = submitFiles(badFiles());
    return [
      readCall('README.md'),
      doc({ operation: 'fetch', url: fx.hostile, base: fx.base }),
      doc({ operation: 'fetch', url: fx.closed_url, base: fx.closed_base }),
      doc({ operation: 'search', query: 'missing-provider', base: fx.base }),
      submit, submit, submit,
    ];
  }, 'lookup-reject', docsRequest(), true, false);
}
async function trivial(suite) {
  const read = { type: 'function_call', id: 'function-read', call_id: 'call-read', name: 'read_file', arguments: JSON.stringify({ path: 'README.md' }) };
  const submit = { type: 'function_call', id: 'function-submit', call_id: 'call-submit', name: 'submit', arguments: JSON.stringify({ files: greetingFiles() }) };
  return observe(suite, () => [{ items: [read, submit] }], 'lookup-trivial', 'Change the greeting copy to Hello.\nTRIVIAL-MARKER-7b9acb97\n', false, false);
}
async function refine(suite) {
  return observe(suite, fx => [
    doc({ operation: 'fetch', url: fx.good, base: fx.base }),
    f('submit_refinement', { constraint: 'This correction needs no technical change.' }),
  ], 'fixture', null, true, true);
}

async function safe(fn) {
  try { return await fn(); } catch (e) { return { status: 'crash', output: String((e && e.stack) || e), request_body: '' }; }
}
async function runAll() {
  const suite = await H.setupSuite();
  try {
    return {
      recorded: await safe(() => recorded(suite)),
      rejected: await safe(() => rejected(suite)),
      trivial: await safe(() => trivial(suite)),
      refine: await safe(() => refine(suite)),
    };
  } finally { H.cleanupSuite(suite); }
}

let exercise;
const installed = () => { if (!exercise) exercise = runAll(); return exercise; };

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
