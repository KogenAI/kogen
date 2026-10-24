'use strict';
// Native Shape and Refine working-window summaries, observed on the installed Go candidate (the one `kogen` program).
//
// A scripted local provider (FakeProvider from go_driver_support) drives a real `kogen intent shape` or `kogen intent
// refine` conversation through repeated working-window resets; documentation lookups are real `documentation` tool calls
// answered by a local HTTP server. What is observed is what a person or the provider sees: the requests the provider
// receives (the reduced input after every reset, with its handoff message), the private archive chain and the
// documentation snapshots on disk, the working_context_reset events, and the refusal after damaged custody. The one
// internal observation (what the production read_file tool delivers for a numbered line of a snapshot) goes through the
// Go driver at test/migration/drivers/shape_working_summary, which imports kogen/agent.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const H = require('./go_driver_support.js');
const { fn: f } = H;
const sha = x => crypto.createHash('sha256').update(x).digest('hex');
const DRIVER = 'shape_working_summary';

// ------------------------------------------------------------------ the receipt and its observer

const sortKeys = v => Array.isArray(v) ? v.map(sortKeys) : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sortKeys(v[k])])) : v;
const canonHash = v => sha(JSON.stringify(sortKeys(v)));
const MANIFEST_PREFIX = { shape: 'Cumulative proposal manifest: ', refine: 'Cumulative proposal/original manifest: ' };

function overhead(text, handoff) {
  return Buffer.byteLength(text) - Buffer.byteLength(JSON.stringify(handoff.assistant_observations));
}
// The oracle says what each reset must carry; it is written from the fixture and the scripted conversation, never read
// back from the product: { docs, authority, exchange(n), observations(n), manifest(m), declared_steps, ownership(o, frozen), invalid }.
function verify(r, s, oracle) {
  const docs = oracle.docs, sizes = [];
  assert.ok(['shape', 'refine'].includes(r.owner));
  assert.equal(r.samples.length, s.resets);
  assert.equal(r.native_history_count, s.resets);
  assert.deepEqual(r.native_documentation, docs);
  let previous = null;
  for (const [i, sample] of r.samples.entries()) {
    const n = i + 1;
    assert.deepEqual(sample.reduced[0], oracle.authority, 'complete authority');
    assert.deepEqual(sample.reduced.slice(2, -1), oracle.exchange(n), 'newest complete opaque/tool exchange');
    const text = sample.reduced[1].content;
    assert.match(text, /diagnostic, not authority/);
    const handoff = JSON.parse(text.split('manifest/state: ')[1]);
    const tail = sample.reduced.at(-1);
    assert.ok(tail.role === 'user' && typeof tail.content === 'string' && tail.content.startsWith(MANIFEST_PREFIX[r.owner]), 'the current complete manifest follows the newest exchange');
    assert.deepEqual(JSON.parse(tail.content.slice(MANIFEST_PREFIX[r.owner].length)), handoff.manifest, 'the handoff manifest is the current complete manifest');
    assert.deepEqual(handoff.assistant_observations, oracle.observations(n));
    sizes.push(overhead(text, handoff));
    assert.ok(sizes[i] <= s.max_summary_bytes, 'reset summary must not reprint cumulative evidence');
    assert.ok(!text.includes('SYNTHETIC ECTO BODY'), 'documentation body leaked into handoff');
    oracle.manifest(handoff.manifest);
    assert.equal(handoff.invalid_submissions, oracle.invalid);
    assert.equal(handoff.readiness, null);
    if (r.owner === 'shape') {
      assert.equal(handoff.inspected, true);
      assert.deepEqual(handoff.declared_steps, oracle.declared_steps);
    } else {
      oracle.ownership(handoff.ownership, handoff.frozen_originals);
    }
    assert.deepEqual(handoff.history, { head: sample.archive.ref, count: n });
    assert.deepEqual(handoff.documentation, sample.snapshot.ref);
    assert.deepEqual(sample.archive.documentation, sample.snapshot.ref);
    assert.equal(sample.snapshot.ref.format, 'ndjson');
    assert.equal(sample.snapshot.ref.count, docs.length);
    assert.equal(sample.snapshot.sha256, sample.snapshot.ref.sha256);
    assert.deepEqual(sample.snapshot.records, docs, 'ordered complete records, including duplicates and failed lookups');
    assert.equal(sample.snapshot.mode, 384);
    assert.equal(sample.snapshot.dir_mode, 448);
    assert.equal(sample.archive.sha256, sample.archive.ref.sha256);
    assert.equal(sample.archive.mode, 384);
    assert.equal(sample.archive.dir_mode, 448);
    assert.equal(sample.archive.version, 1);
    assert.equal(sample.archive.owner, r.owner);
    assert.deepEqual(sample.archive.previous, previous, 'complete linked history');
    assert.equal(sample.archive.input_hash, sample.expected_input_hash, 'exact archived active replay');
    assert.ok(sample.before_bytes > s.ceiling);
    assert.ok(sample.after_bytes <= s.ceiling && sample.after_bytes < sample.before_bytes);
    assert.equal(sample.wire_bytes, sample.after_bytes, 'the request the provider received is the measured reduced request');
    assert.equal(sample.reserve, s.reserve);
    previous = sample.archive.ref;
  }
  assert.ok(Math.max(...sizes) - Math.min(...sizes) <= s.max_growth_bytes, 'repeated resets must not grow linearly');
  assert.equal(r.retrieved.length, docs.length);
  r.retrieved.forEach((text, i) => {
    assert.ok(Buffer.byteLength(text) <= s.tool_result_limit);
    assert.ok(text.startsWith(`${i + 1}\t`));
    assert.deepEqual(JSON.parse(text.slice(text.indexOf('\t') + 1)), docs[i], 'selected line retrieval');
  });
  assert.deepEqual(r.damage.map(x => x.kind), ['changed', 'missing', 'symlink', 'mode']);
  for (const d of r.damage) {
    assert.equal(d.code, 'candidate/context_custody_invalid');
    assert.equal(d.no_new_archive, true);
  }
}

// ------------------------------------------------------------------ the local fixture records

// The documentation lookups of the fixture, in order: twelve identical fetches of one 10035-byte page, three of its HTML
// form, three long ones, then search lookups that end retrieved, unreachable or unsupported in turn. Each plan item is
// the tool call the model sends and the record that call must leave. `base` is the local documentation origin and `closed`
// an origin nothing listens on. The queries of the fetches carry the filler that makes the records total documentation_bytes.
function documentPlan(s, base, closed) {
  if (s.documentation_count === 0) return [];
  const md = 'SYNTHETIC ECTO BODY\n'.padEnd(s.md_body_bytes, 'd');
  const html = 'h'.repeat(s.html_body_bytes);
  const long = 'l'.repeat(s.long_body_bytes);
  const mdUrl = base + new URL(s.md_url).pathname, htmlUrl = base + new URL(s.html_url).pathname;
  const fetch = (url, body) => ({ args: { operation: 'fetch', url, query: '' }, record: { operation: 'fetch', status: 'retrieved', query: '', url, sources: [], body, untrusted: true, truncated: false, error: '' } });
  const plan = [];
  for (let i = 0; i < 12; i++) plan.push(fetch(mdUrl, md));
  for (let i = 0; i < 3; i++) plan.push(fetch(htmlUrl, html));
  for (let i = 0; i < 3; i++) plan.push(fetch(`${mdUrl}?fixture=${i}`, long));
  const statuses = ['retrieved', 'unreachable', 'unsupported'];
  while (plan.length < s.documentation_count) {
    const i = plan.length, status = statuses[i % 3];
    const query = status === 'unsupported' ? `missing-${i}` : `lookup-${i}`;
    const error = status === 'retrieved' ? '' : `documentation source ${status}`;
    plan.push({ args: { operation: 'search', query, base: status === 'unreachable' ? closed : base }, record: { operation: 'search', status, query, url: '', sources: [], body: '', untrusted: false, truncated: false, error } });
  }
  const missing = s.documentation_bytes - Buffer.byteLength(JSON.stringify(plan.map(p => p.record)));
  assert.ok(missing >= 0, 'documentation target must fit the reproducer records');
  const fetches = plan.filter(p => p.record.operation === 'fetch');
  fetches.forEach((p, i) => {
    const filler = 'q'.repeat(Math.floor(missing / fetches.length) + (i < missing % fetches.length ? 1 : 0));
    p.args.query = filler; p.record.query = filler;
    assert.ok(Buffer.byteLength(JSON.stringify(p.record)) < 16000, 'a lookup must stay whole under the display bound');
  });
  assert.equal(Buffer.byteLength(JSON.stringify(plan.map(p => p.record))), s.documentation_bytes);
  return plan;
}
// The local documentation origin: the three pages, a search answer and a refusal.
async function documentationOrigin(s) {
  const md = 'SYNTHETIC ECTO BODY\n'.padEnd(s.md_body_bytes, 'd'), html = 'h'.repeat(s.html_body_bytes), long = 'l'.repeat(s.long_body_bytes);
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const reply = (status, type, body) => { res.writeHead(status, { 'content-type': type, 'content-length': Buffer.byteLength(body), connection: 'close' }); res.end(body); };
    if (url.pathname === new URL(s.md_url).pathname) return reply(200, 'text/markdown', url.searchParams.has('fixture') ? long : md);
    if (url.pathname === new URL(s.html_url).pathname) return reply(200, 'text/html', html);
    if (url.pathname === '/search') return (url.searchParams.get('q') || '').startsWith('missing') ? reply(404, 'text/plain', 'missing') : reply(200, 'application/json', '{"sources":[]}');
    reply(404, 'text/plain', 'missing');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const probe = net.createServer();
  await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
  const closedPort = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  return { base: `http://127.0.0.1:${server.address().port}`, closed: `http://127.0.0.1:${closedPort}`, stop: () => new Promise(resolve => { server.closeAllConnections?.(); server.close(resolve); }) };
}

// ------------------------------------------------------------------ the conversation

const driver = () => H.driverProgram(DRIVER);
async function replayAll(items) {
  const run = await driver();
  const r = await run(['replay'], { input: JSON.stringify(items) });
  assert.equal(r.code, 0, r.out);
  return JSON.parse(r.out);
}
// What the model receives from one production tool call in root.
async function delivered(root, name, args) {
  const run = await driver();
  const r = await run(['tool', root, name, JSON.stringify(args)]);
  assert.equal(r.code, 0, r.out);
  return r.out;
}
const request = (packet, s) => {
  const prefix = packet + '\nLocal synthetic authority padding:\n';
  assert.ok(Buffer.byteLength(prefix) <= s.request_bytes);
  return prefix + 'R'.repeat(s.request_bytes - Buffer.byteLength(prefix));
};
const texts = message => { const out = []; const walk = v => { if (typeof v === 'string') out.push(v); else if (Array.isArray(v)) v.forEach(walk); else if (v && typeof v === 'object') Object.values(v).forEach(walk); }; walk(message.content); return out; };
const put = (c, p, bytes) => { const full = path.join(c.repo, p); fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, bytes); };
const lines = p => { try { return fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)); } catch { return []; } };
const mode = p => fs.lstatSync(p).mode & 0o777;
function script(c, actions) { const fake = c.server; fake.next = Math.min(fake.next, fake.script.length); fake.setScript(actions); }
function either(k, fake, ms = 60000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('the fixture timed out before the paused provider')), ms);
    fake.waitPaused(ms).then(p => { clearTimeout(timer); resolve({ paused: p }); }, () => {});
    k.awaitExit(ms).then(r => { clearTimeout(timer); resolve({ done: r }); }, () => {});
  });
}
const BIG_READS = 14;

// One scripted conversation of an owner. Responses: two invalid submissions (so the invalid count is carried), the setup
// response (inspection, every documentation lookup and large reads that bring it to about 270 KB of results: fits), then one response per reset (an unfinished
// exchange: opaque reasoning, a commentary message, the exact-literal read and large reads whose results fill the window),
// and last the call that ends the conversation.
async function plan(c, owner, s, resets, docs) {
  const call = (n, j, name, args) => ({ type: 'function_call', id: `fc-${n}-${j}`, call_id: `call-${n}-${j}`, name, arguments: JSON.stringify(args) });
  const turn = (n, specs) => [
    { type: 'reasoning', id: `reason-${n}`, encrypted_content: s.opaque, summary: [] },
    { type: 'message', id: `message-${n}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: s.observation }] },
    ...specs.map(([name, args], j) => call(n, j + 1, name, args)),
  ];
  const big = n => Array.from({ length: n }, () => ['read_file', { path: 'pad.txt' }]);
  const setup = turn(1, [['read_file', { path: 'README.md' }], ['read_file', { path: 'literal.txt' }], ...docs.map(d => ['documentation', d.args]), ...big(docs.length ? 4 : 16)]);
  const exchanges = Array.from({ length: resets }, (_, i) => turn(i + 2, [['read_file', { path: 'literal.txt' }], ...big(BIG_READS)]));
  const root = c.repo;
  const literal = await delivered(root, 'read_file', { path: 'literal.txt' }), pad = await delivered(root, 'read_file', { path: 'pad.txt' });
  const replayed = await replayAll(exchanges.flat());
  let at = 0;
  const expected = exchanges.map(items => {
    const mine = replayed.slice(at, at += items.length);
    const outs = items.filter(i => i.type === 'function_call').map(i => H.outputItem(i, JSON.parse(i.arguments).path === 'literal.txt' ? literal : pad));
    return [...mine, ...outs];
  });
  const invalid = owner === 'shape' ? f('submit', {}) : f('submit_refinement', { files: [] });
  const last = owner === 'shape'
    ? f('submit', { questions: [{ question: 'Preserve the local fixture?', options: [{ label: 'Preserve', recommended: true }] }] })
    : f('submit_refinement', { constraint: 'The local fixture ends the conversation after its working windows.' });
  return { setup: { items: setup }, exchanges: exchanges.map(items => ({ items })), expected, invalid, last, invalids: Math.min(s.invalid_submissions, 2) };
}

// A project with an approved Intent and the fixture files, the origin of the lookups, and the way to start the owner.
async function fixture(suite, owner, s, packet) {
  const c = await H.project(suite, [], { stagedIntent: false });
  const origin = await documentationOrigin(s);
  c.origin = origin;
  put(c, 'pad.txt', 'p'.repeat(22000));
  put(c, 'literal.txt', s.literal);
  await H.git(c, ['add', 'pad.txt', 'literal.txt']); await H.git(c, ['commit', '-qm', 'Seed the summary fixture']);
  const file = path.join(c.root, 'request.md'), text = request(packet, s);
  fs.writeFileSync(file, text);
  c.request = text;
  if (owner === 'shape') c.args = ['intent', 'shape', 'summary-fixture', file];
  else c.args = ['intent', 'refine', 'fixture', await H.baselineHash(c, 'fixture', []), file];
  return c;
}
async function release(c) { if (c) { await c.origin.stop().catch(() => {}); await H.cleanupCase(c); } }

const archiveDir = (c, owner) => owner === 'shape'
  ? H.wildcard(path.join(c.repo, '.kogen/local/shaping/summary-fixture/working-context/*'))[0]
  : H.wildcard(path.join(c.repo, '.kogen/local/refinements/*/working-context'))[0];
const eventsOf = (c, owner) => (owner === 'shape' ? [path.join(c.repo, '.kogen/local/shaping/summary-fixture/events.ndjson')] : H.wildcard(path.join(c.repo, '.kogen/local/refinements/*/events.ndjson'))).flatMap(lines);

async function exercise(suite, owner, s, packet) {
  const c = await fixture(suite, owner, s, packet);
  try {
    const docs = documentPlan(s, c.origin.base, c.origin.closed);
    const p = await plan(c, owner, s, s.resets, docs);
    script(c, [...Array.from({ length: p.invalids }, () => p.invalid), p.setup, ...p.exchanges, p.last]);
    const n0 = c.server.providerRequests().length;
    const run = await H.runKogen(c, c.args, { timeout: 30 * H.MIN });
    const reqs = c.server.providerRequests().slice(n0);
    assert.ok(reqs.length > 0, run.out);
    const dir = archiveDir(c, owner);
    assert.ok(dir, `no working-context custody was kept: ${run.out}`);
    const first = reqs[0].json.input[0];
    assert.ok(texts(first).some(t => t.includes(c.request)), 'the complete original request is in the first message');
    const resetIndexes = reqs.flatMap((r, i) => typeof r.json.input[1]?.content === 'string' && r.json.input[1].content.startsWith('Local working-window reset.') ? [i] : []);
    const events = eventsOf(c, owner).filter(e => e.event === 'working_context_reset');
    assert.equal(events.length, resetIndexes.length, `reset events: ${run.out}`);
    const samples = resetIndexes.map((at, i) => {
      const n = i + 1, event = events[i], reduced = reqs[at].json.input;
      assert.equal(event.generation, n); assert.equal(event.owner, owner);
      const ref = event.archive, bytes = fs.readFileSync(ref.path), archive = JSON.parse(bytes);
      const snapshotRef = archive.documentation, snapshotBytes = fs.readFileSync(snapshotRef.path);
      return {
        reduced,
        before_bytes: event.before_bytes, after_bytes: event.after_bytes, reserve: event.output_reserve_tokens, wire_bytes: Buffer.byteLength(reqs[at].body),
        expected_input_hash: canonHash([...reqs[at - 1].json.input, ...reduced.slice(2)]),
        archive: { ref, sha256: sha(bytes), mode: mode(ref.path), dir_mode: mode(path.dirname(ref.path)), version: archive.version, owner: archive.owner, previous: archive.previous, documentation: archive.documentation, input_hash: canonHash(archive.input) },
        snapshot: { ref: snapshotRef, sha256: sha(snapshotBytes), mode: mode(snapshotRef.path), dir_mode: mode(path.dirname(snapshotRef.path)), records: snapshotBytes.toString('utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) },
      };
    });
    const history = fs.readdirSync(dir).filter(x => /^\d+\.json$/.test(x));
    const lastSnapshot = samples.at(-1).snapshot;
    const retrieved = [];
    for (let i = 1; i <= docs.length; i++) retrieved.push(await delivered(c.repo, 'read_file', { path: lastSnapshot.ref.path, start_line: i, end_line: i }));
    const receipt = { owner, samples, native_history_count: history.length, native_documentation: lastSnapshot.records, retrieved, damage: [] };
    // What the oracle expects of the conversation, from the fixture and the script.
    const message = k => ({ id: `message-${k}`, phase: 'commentary', content: [{ type: 'output_text', text: s.observation }] });
    const originals = owner === 'refine' ? await refineOriginals(c) : null;
    const oracle = {
      // Shape keeps every lookup result whole; Refine keeps its retained rows, which never carry the document body.
      docs: docs.map(d => { if (owner === 'shape') return d.record; const { body, ...row } = d.record; return row; }), authority: first, exchange: n => p.expected[n - 1],
      observations: n => Array.from({ length: n + 1 }, (_, k) => message(k + 1)),
      manifest: m => owner === 'shape' ? assert.deepEqual(m, { proposed: [], originals: [] }) : originals.manifest(m),
      declared_steps: [], ownership: (o, frozen) => originals.ownership(o, frozen), invalid: p.invalids,
    };
    receipt.exit = run.code; receipt.out = run.out;
    return { receipt, oracle, run };
  } finally { await release(c); }
}

// What a Refine of the fixture Intent freezes: its owned artifacts at the approved baseline.
async function refineOriginals(c) {
  const paths = [H.intentMd('fixture'), H.featurePath('fixture')];
  const head = await H.git(c, ['rev-parse', 'HEAD']);
  const kept = new Map(H.wildcard(path.join(c.repo, '.kogen/local/refinements/*/original')).flatMap(d => H.listFiles(d).map(p => [p, fs.readFileSync(p)])));
  const bytes = Object.fromEntries(paths.map(p => [p, fs.readFileSync(path.join(c.repo, p))]));
  const frozen = list => {
    assert.ok(Array.isArray(list) && list.length > 0);
    for (const e of list) assert.deepEqual(Object.keys(e).sort(), ['path', 'sha256']);
    const got = Object.fromEntries(list.map(e => [e.path, e.sha256]));
    for (const p of paths) assert.equal(got[p], sha(bytes[p]), `${p} is frozen at its approved bytes`);
    return list;
  };
  return {
    manifest: m => {
      assert.ok(Array.isArray(m) && m.length > 0);
      for (const e of m) { assert.equal(e.proposed, null); assert.equal(e.revision.head, head); }
      for (const p of paths) { const e = m.find(x => x.path === p); assert.ok(e, `${p} is in the manifest`); assert.equal(e.sha256, sha(bytes[p])); assert.ok(kept.has(e.source) && kept.get(e.source).equals(bytes[p]), 'the frozen original is kept'); }
    },
    ownership: (owned, list) => { frozen(list); assert.ok(Array.isArray(owned) && paths.every(p => owned.includes(p)), 'the owned artifacts are carried'); },
  };
}

// The four damages of a snapshot of an earlier reset, each against a fresh conversation paused after its first reset
// with a fitting continuation: the next step must refuse with custody_invalid and make neither a request nor an archive.
async function damaged(suite, owner, s, packet, kind) {
  const c = await fixture(suite, owner, s, packet);
  try {
    const docs = documentPlan(s, c.origin.base, c.origin.closed);
    const p = await plan(c, owner, s, 1, docs);
    script(c, [p.setup, ...p.exchanges, { pause: { text: 'No call; the continuation fits.' } }]);
    const k = H.startKogen(c, c.args);
    const waited = await either(k, c.server);
    assert.ok(waited.paused, `the conversation ended before the paused provider: ${waited.done?.out}`);
    const dir = archiveDir(c, owner), snapshot = path.join(dir, '1-documentation.ndjson');
    const original = fs.readFileSync(snapshot);
    if (kind === 'changed') fs.appendFileSync(snapshot, ' ');
    else if (kind === 'missing') fs.rmSync(snapshot);
    else if (kind === 'symlink') { const q = path.join(c.root, 'replacement.ndjson'); fs.writeFileSync(q, original); fs.rmSync(snapshot); fs.symlinkSync(q, snapshot); }
    else fs.chmodSync(snapshot, 0o644);
    const before = fs.readdirSync(dir).sort(), requests = c.server.providerRequests().length;
    waited.paused.continue();
    const r = await k.awaitExit(60000);
    const refusal = /\b(\w+\/context_custody_invalid)\b/.exec(r.out);
    const after = fs.readdirSync(dir).sort();
    assert.notEqual(r.code, 0, r.out);
    return { kind, code: refusal ? refusal[1] : 'accepted', no_new_archive: JSON.stringify(before) === JSON.stringify(after) && c.server.providerRequests().length === requests };
  } finally { await release(c); }
}

// ------------------------------------------------------------------ the observer controls (no product execution)

function synthetic(s) {
  const record = (operation, url, body, status = 'retrieved') => ({ operation, url, body, status, query: '', sources: [], error: '', truncated: operation === 'fetch', untrusted: true });
  if (s.documentation_count === 0) return [];
  const md = record('fetch', s.md_url, 'SYNTHETIC ECTO BODY\n'.padEnd(s.md_body_bytes, 'd'));
  const rows = Array.from({ length: 12 }, () => structuredClone(md));
  for (let i = 0; i < 3; i++) rows.push(record('fetch', s.html_url, 'h'.repeat(s.html_body_bytes)));
  for (let i = 0; i < 3; i++) rows.push(record('fetch', `${s.md_url}?fixture=${i}`, 'l'.repeat(s.long_body_bytes)));
  while (rows.length < s.documentation_count) rows.push(record('search', '', '', ['retrieved', 'unreachable', 'unsupported'][rows.length % 3]));
  const remaining = s.documentation_bytes - Buffer.byteLength(JSON.stringify(rows));
  assert.ok(remaining >= 0, 'documentation target must fit the reproducer records');
  rows[rows.length - 1].body = 's'.repeat(remaining);
  assert.equal(Buffer.byteLength(JSON.stringify(rows)), s.documentation_bytes);
  return rows;
}
function controlAuthority(packet, s) {
  const prefix = packet + '\nLocal synthetic authority padding:\n';
  assert.ok(Buffer.byteLength(prefix) <= s.request_bytes);
  return { role: 'user', content: prefix + 'R'.repeat(s.request_bytes - Buffer.byteLength(prefix)) };
}
function controlExchange(n, s) {
  return [
    { type: 'reasoning', id: `reason-${n}`, encrypted_content: s.opaque, summary: [] },
    { type: 'message', id: `message-${n}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: s.observation }] },
    { type: 'function_call', id: `fc-${n}`, call_id: `call-${n}`, name: 'read_file', arguments: JSON.stringify({ path: s.literal }) },
    { type: 'function_call_output', call_id: `call-${n}`, output: s.literal },
  ];
}
function controlObservations(n, s) {
  return Array.from({ length: n }, (_, i) => { const m = controlExchange(i + 1, s)[1]; return { id: m.id, phase: m.phase, content: m.content }; });
}
function controlOracle(s, packet) {
  return { docs: synthetic(s), authority: controlAuthority(packet, s), exchange: n => controlExchange(n, s), observations: n => controlObservations(n, s), manifest: m => assert.deepEqual(m, s.manifest), declared_steps: s.declared_steps, ownership: (o, frozen) => { assert.deepEqual(o, s.ownership); assert.deepEqual(frozen, []); }, invalid: s.invalid_submissions };
}
function controlSpec() {
  return { resets: 2, documentation_count: 42, documentation_bytes: 202204, md_url: 'https://hexdocs.pm/ecto/3.14.2/Ecto.Multi.md', html_url: 'https://hexdocs.pm/ecto/3.14.2/Ecto.Multi.html', md_body_bytes: 10035, html_body_bytes: 8992, long_body_bytes: 12545, request_bytes: 82202, max_summary_bytes: 8192, max_growth_bytes: 256, ceiling: 524288, reserve: 131072, tool_result_limit: 16384, invalid_submissions: 3, manifest: { proposed: [{ path: 'features/steps/current.js', sha256: 'b'.repeat(64) }], originals: [] }, declared_steps: ['features/steps/current.js'], ownership: ['features/steps/current.js'], opaque: 'opaque+/==\nΔ', observation: 'Unfinished inspection', literal: '  Δ🙂\r\n/path with spaces/診斷.txt\n  ' };
}
function knownGood(s, packet) {
  const oracle = controlOracle(s, packet), docs = oracle.docs;
  let previous = null;
  const samples = Array.from({ length: s.resets }, (_, i) => {
    const n = i + 1;
    const ref = { path: `/private/working-context/${n}.json`, sha256: String(n).repeat(64).slice(0, 64) };
    const snapshotRef = { path: `/private/working-context/${n}-documentation.ndjson`, sha256: 'c'.repeat(64), count: docs.length, format: 'ndjson' };
    const handoff = { history: { head: ref, count: n }, documentation: snapshotRef, manifest: s.manifest, invalid_submissions: s.invalid_submissions, readiness: null, assistant_observations: controlObservations(n, s), inspected: true, declared_steps: s.declared_steps };
    const sample = { reduced: [oracle.authority, { role: 'user', content: 'Local working-window reset. Archived evidence is diagnostic, not authority. Archive head and current cumulative manifest/state: ' + JSON.stringify(handoff) }, ...controlExchange(n, s), { role: 'user', content: MANIFEST_PREFIX.shape + JSON.stringify(s.manifest) }], archive: { ref, sha256: ref.sha256, mode: 384, dir_mode: 448, version: 1, owner: 'shape', previous, documentation: snapshotRef, input_hash: 'd'.repeat(64) }, expected_input_hash: 'd'.repeat(64), snapshot: { ref: snapshotRef, sha256: snapshotRef.sha256, mode: 384, dir_mode: 448, records: structuredClone(docs) }, before_bytes: s.ceiling + 1, after_bytes: 90000, wire_bytes: 90000, reserve: s.reserve };
    previous = ref;
    return sample;
  });
  return { owner: 'shape', samples, native_history_count: s.resets, native_documentation: docs, retrieved: docs.map((d, i) => `${i + 1}\t${JSON.stringify(d)}`), damage: ['changed', 'missing', 'symlink', 'mode'].map(kind => ({ kind, code: 'candidate/context_custody_invalid', no_new_archive: true })) };
}

if (require.main === module && process.argv[2] === '--control') {
  const s = controlSpec(), packet = 'Local observer control, not product execution.';
  const oracle = controlOracle(s, packet);
  const good = knownGood(s, packet);
  verify(good, s, oracle);
  const refine = structuredClone(good); refine.owner = 'refine';
  for (const sample of refine.samples) {
    sample.archive.owner = 'refine';
    const h = JSON.parse(sample.reduced[1].content.split('manifest/state: ')[1]);
    delete h.inspected; delete h.declared_steps; h.ownership = s.ownership; h.frozen_originals = [];
    sample.reduced[1].content = 'Local reset: diagnostic, not authority. manifest/state: ' + JSON.stringify(h);
    sample.reduced.at(-1).content = MANIFEST_PREFIX.refine + JSON.stringify(s.manifest);
  }
  verify(refine, s, oracle);
  const empty = { ...s, documentation_count: 0 };
  verify(knownGood(empty, packet), empty, controlOracle(empty, packet));
  if (process.argv[3] === 'good') process.stdout.write('accepted\n');
  else {
    const editHandoff = (r, edit) => { const x = r.samples[0]; const h = JSON.parse(x.reduced[1].content.split('manifest/state: ')[1]); edit(h); x.reduced[1].content = 'diagnostic, not authority. manifest/state: ' + JSON.stringify(h); };
    const mutations = [
      r => r.samples.pop(), r => r.native_documentation.pop(), r => r.samples[0].reduced[0].content += 'changed',
      r => r.samples[0].reduced[2].encrypted_content += 'changed', r => r.samples[0].reduced[3].phase = 'final', r => r.samples[0].reduced.pop(),
      r => r.samples[0].reduced.splice(-2, 1), r => { r.samples[0].reduced.at(-1).content = MANIFEST_PREFIX.shape + JSON.stringify({ proposed: [], originals: [] }); },
      r => editHandoff(r, h => h.manifest.proposed = []), r => editHandoff(r, h => h.invalid_submissions = 0),
      r => editHandoff(r, h => h.assistant_observations = []), r => editHandoff(r, h => h.history.count = 0),
      r => editHandoff(r, h => h.documentation.count = 0), r => editHandoff(r, h => h.documentation = r.native_documentation),
      r => r.samples[1].archive.previous = null, r => r.samples[0].archive.input_hash = 'changed',
      r => r.samples[0].archive.sha256 = 'changed', r => r.samples[0].archive.mode = 420,
      r => r.samples[0].snapshot.sha256 = 'changed', r => r.samples[0].snapshot.dir_mode = 493,
      r => r.samples[0].snapshot.records.reverse(), r => r.samples[0].snapshot.records[0].body = 'clipped',
      r => r.samples[0].after_bytes = s.ceiling + 1, r => r.samples[0].wire_bytes += 1, r => r.samples[0].reserve = 1,
      r => r.retrieved[0] = '1\t{}', r => r.damage[0].code = 'accepted', r => r.damage[0].no_new_archive = false,
      r => editHandoff(r, h => h.ownership = [])
    ];
    mutations.forEach((mutate, i) => {
      const bad = structuredClone(i === mutations.length - 1 ? refine : good); mutate(bad);
      assert.throws(() => verify(bad, s, oracle), undefined, `control mutation ${i} escaped`);
    });
    process.stdout.write('rejected\n'); process.exitCode = 1;
  }
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  Given('the working-summary original request:', function (packet) { this.summaryPacket = packet; });
  Given('the working-summary local fixture:', function (json) { this.summarySpec = JSON.parse(json); });
  When('I exercise current {string} working summaries for {int} resets with {int} documentation records', { timeout: 1800000 }, async function (owner, resets, count) {
    const s = { ...this.summarySpec, resets, documentation_count: count };
    const suite = await H.setupSuite();
    try {
      const main = await exercise(suite, owner, s, this.summaryPacket);
      for (const kind of ['changed', 'missing', 'symlink', 'mode']) main.receipt.damage.push(await damaged(suite, owner, s, this.summaryPacket, kind));
      this.summaryReceipt = main.receipt; this.summaryOracle = main.oracle; this.summaryCase = s;
    } finally { H.cleanupSuite(suite); }
  });
  Then('the working-summary custody and bounded growth satisfy the local fixture', function () {
    verify(this.summaryReceipt, this.summaryCase, this.summaryOracle);
  });
}
