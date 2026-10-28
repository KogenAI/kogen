'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const NOTES = 'k9-secret-notes.txt';
const CONTENT = 'K9-CONTENT-SENTINEL-1\nK9-CONTENT-SENTINEL-2\nK9-CONTENT-SENTINEL-3\nK9-CONTENT-SENTINEL-4\n';
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
const cache = new Map();

function observe(kind) {
  if (cache.has(kind)) return cache.get(kind);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k9-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    const [pkg, driver, test, name] = kind === 'build'
      ? ['./build', 'k9_build_record_driver.go', 'k9_build_record_acceptance_test.go', 'TestK9RunRecordObservation']
      : ['./shape', 'k9_shape_record_driver.go', 'k9_shape_record_acceptance_test.go', 'TestK9ShapeRecordObservation'];
    fs.writeFileSync(overlay, JSON.stringify({ Replace: { [path.join(ROOT, 'cli', pkg, test)]: path.join(__dirname, driver) } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, pkg, '-run', `^${name}$`, '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 16 * 1024 * 1024,
      env: { ...process.env, KOGEN_K9_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    const data = JSON.parse(fs.readFileSync(output, 'utf8'));
    cache.set(kind, data);
    return data;
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const isInt = n => Number.isInteger(n);
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
function sizesMatch(events, sizes) {
  assert.equal(events.length, sizes.length, 'one request event per provider request');
  events.forEach((ev, i) => {
    assert.ok(isInt(ev.request_bytes) && ev.request_bytes > 0, `request_bytes of request ${i}`);
    assert.ok(Math.abs(ev.request_bytes - sizes[i]) <= Math.max(64, sizes[i] * 0.05), `request_bytes ${ev.request_bytes} is not the sent body size ${sizes[i]} (request ${i})`);
  });
}
function source(ev, p, start, end, whole, content) {
  assert.deepEqual(ev.source, { kind: 'file', path_sha256: sha(p), start_line: start, end_line: end, whole }, `source of ${p}`);
  assert.equal(ev.content_sha256, sha(content), `content_sha256 of ${p}`);
}

function checkBuild(d) {
  assert.equal(d.exit, 0, d.error_text);
  const ev = d.events;
  const reqs = ev.filter(e => e.event === 'request');
  sizesMatch(reqs, d.provider_sizes);
  const builds = reqs.filter(r => r.role === 'build'), reviews = reqs.filter(r => r.role === 'review');
  assert.equal(builds.length, 43);
  assert.equal(reviews.length, 2);
  for (const r of builds) {
    assert.equal(r.build_round, 1);
    assert.ok(!has(r, 'review_round') && !has(r, 'shape_attempt'), 'only the applicable round field');
  }
  for (const r of reviews) {
    assert.equal(r.review_round, 1);
    assert.ok(!has(r, 'build_round') && !has(r, 'shape_attempt'), 'only the applicable round field');
  }
  reqs.forEach((r, i) => {
    assert.ok(has(r.usage, 'cache_write'), `usage.cache_write of request ${i}`);
    assert.equal(r.usage.cache_write, i === 1 ? 20 : null, `cache_write of request ${i}`);
    assert.ok(has(r.usage, 'cached') && has(r.usage, 'input'), 'existing usage fields stay');
  });
  const calls = ev.filter(e => e.event === 'tool_call');
  assert.equal(calls.length, 44);
  const shells = calls.filter(c => c.name === 'shell');
  assert.equal(shells.length, 40);
  for (const c of shells) {
    assert.ok(isInt(c.bytes_before_cut) && c.bytes_before_cut >= 40960 && c.bytes_before_cut <= 42000, `bytes_before_cut ${c.bytes_before_cut}`);
    assert.ok(isInt(c.bytes_delivered) && c.bytes_delivered > 0 && c.bytes_delivered <= 16384, `bytes_delivered ${c.bytes_delivered}`);
  }
  for (const c of calls.filter(c => c.name !== 'shell')) {
    assert.ok(!has(c, 'bytes_before_cut') && !has(c, 'bytes_delivered'), `no cut fields on ${c.name}`);
  }
  for (const c of calls) {
    assert.ok(has(c, 'arguments') && has(c, 'result') && has(c, 'call_id'), 'existing tool_call fields stay');
    if (c.name !== 'read_file') assert.ok(!has(c, 'source') && !has(c, 'content_sha256'), `no source on ${c.name}`);
  }
  const reads = calls.filter(c => c.name === 'read_file');
  assert.equal(reads.length, 1);
  source(reads[0], NOTES, 2, 3, false, CONTENT);
  const rev = ev.filter(e => e.event === 'review_tool_call');
  assert.equal(rev.length, 2);
  source(rev[0], 'app.txt', 1, 1, true, 'candidate\n');
  source(rev[1], NOTES, 1, 2, false, CONTENT);
  for (const c of rev) assert.ok(has(c, 'arguments') && has(c, 'result'), 'existing review_tool_call fields stay');
  const resets = ev.filter(e => e.event === 'window_reset');
  assert.ok(resets.length >= 1, 'a window_reset event');
  for (const r of resets) {
    assert.equal(r.owner, 'build');
    assert.ok(isInt(r.input_tokens_before) && isInt(r.input_tokens_after) && r.input_tokens_after > 0, 'reset tokens');
    assert.ok(r.input_tokens_before > r.input_tokens_after, 'the reset shrinks the window');
    assert.ok(isInt(r.carried_items) && r.carried_items >= 1, 'carried_items');
  }
  const text = JSON.stringify(ev.filter(e => ['request', 'tool_call', 'review_tool_call', 'window_reset'].includes(e.event)));
  assert.ok(!text.includes(NOTES) && !text.includes('K9-CONTENT-SENTINEL'), 'no raw path or file content in the records');
}

function checkShape(d) {
  assert.equal(d.error_text, '', d.error_text);
  assert.equal(d.exit, 0);
  assert.equal(d.published, true);
  assert.deepEqual(d.audit_requests, [true, false, false], 'audit, then two shaper requests');
  const calls = d.provider_calls;
  sizesMatch(calls, d.provider_sizes);
  assert.deepEqual(calls.map(c => c.shape_attempt), [1, 1, 2]);
  for (const c of calls) assert.ok(!has(c, 'build_round') && !has(c, 'review_round'), 'only the applicable round field');
}

function goodBuild() {
  const usage = cw => ({ input: 1, cached: 0, output: 1, reasoning: 0, cache_write: cw });
  const ev = [];
  const sizes = [];
  const req = (role, i) => {
    const r = { event: 'request', role, usage: usage(i === 1 ? 20 : null), request_bytes: 1000 + i };
    if (role === 'build') r.build_round = 1; else r.review_round = 1;
    sizes.push(1000 + i); ev.push(r);
  };
  let i = 0;
  const call = (name, extra) => ev.push({ event: 'tool_call', call_id: `c${i}`, name, arguments: {}, result: {}, ...extra });
  req('build', i++); call('write_file'); call('write_file');
  req('build', i++); call('read_file', { source: { kind: 'file', path_sha256: sha(NOTES), start_line: 2, end_line: 3, whole: false }, content_sha256: sha(CONTENT) });
  for (let k = 0; k < 40; k++) { req('build', i++); call('shell', { bytes_before_cut: 40960, bytes_delivered: 16384 }); }
  ev.push({ event: 'window_reset', owner: 'build', input_tokens_before: 900, input_tokens_after: 300, carried_items: 4 });
  req('build', i++); call('finish');
  req('review', i++);
  ev.push({ event: 'review_tool_call', arguments: {}, result: {}, name: 'read_file', source: { kind: 'file', path_sha256: sha('app.txt'), start_line: 1, end_line: 1, whole: true }, content_sha256: sha('candidate\n') });
  ev.push({ event: 'review_tool_call', arguments: {}, result: {}, name: 'read_file', source: { kind: 'file', path_sha256: sha(NOTES), start_line: 1, end_line: 2, whole: false }, content_sha256: sha(CONTENT) });
  req('review', i++);
  return { exit: 0, error_text: '', events: ev, provider_sizes: sizes };
}
function goodShape() {
  const calls = [1, 1, 2].map((a, i) => ({ event: 'provider_call', shape_attempt: a, request_bytes: 500 + i }));
  return { exit: 0, error_text: '', published: true, audit_requests: [true, false, false], provider_calls: calls, provider_sizes: [500, 501, 502] };
}

function controls(kind) {
  checkBuild(goodBuild()); checkShape(goodShape());
  if (kind === 'good') { console.log('k9 observer good'); return; }
  assert.equal(kind, 'bad');
  const badBuild = (mutate) => { const c = goodBuild(); mutate(c); assert.throws(() => checkBuild(c), 'accepted a known-bad build fixture'); };
  const badShape = (mutate) => { const c = goodShape(); mutate(c); assert.throws(() => checkShape(c), 'accepted a known-bad shape fixture'); };
  const reqs = c => c.events.filter(e => e.event === 'request');
  const calls = c => c.events.filter(e => e.event === 'tool_call');
  const rev = c => c.events.filter(e => e.event === 'review_tool_call');
  badBuild(c => { delete reqs(c)[3].build_round; });
  badBuild(c => { reqs(c)[3].build_round = 2; });
  badBuild(c => { reqs(c)[3].shape_attempt = 1; });
  badBuild(c => { delete reqs(c)[43].review_round; });
  badBuild(c => { reqs(c)[43].build_round = 1; });
  badBuild(c => { delete reqs(c)[5].request_bytes; });
  badBuild(c => { reqs(c)[5].request_bytes = 1; });
  badBuild(c => { delete reqs(c)[0].usage.cache_write; });
  badBuild(c => { reqs(c)[1].usage.cache_write = null; });
  badBuild(c => { reqs(c)[2].usage.cache_write = 20; });
  badBuild(c => { delete calls(c)[5].bytes_before_cut; });
  badBuild(c => { calls(c)[5].bytes_delivered = 20000; });
  badBuild(c => { calls(c)[5].bytes_before_cut = 100; });
  badBuild(c => { calls(c)[0].bytes_before_cut = 10; calls(c)[0].bytes_delivered = 10; });
  badBuild(c => { calls(c)[2].source.whole = true; });
  badBuild(c => { calls(c)[2].source.start_line = 1; });
  badBuild(c => { calls(c)[2].source.path_sha256 = NOTES; });
  badBuild(c => { calls(c)[2].content_sha256 = sha('x'); });
  badBuild(c => { delete calls(c)[2].source; });
  badBuild(c => { calls(c)[5].source = calls(c)[2].source; });
  badBuild(c => { rev(c)[0].source.whole = false; });
  badBuild(c => { delete rev(c)[1].content_sha256; });
  badBuild(c => { c.events = c.events.filter(e => e.event !== 'window_reset'); });
  badBuild(c => { c.events.find(e => e.event === 'window_reset').carried_items = null; });
  badBuild(c => { c.events.find(e => e.event === 'window_reset').input_tokens_after = 2000; });
  badBuild(c => { calls(c)[2].raw = NOTES; });
  badBuild(c => { calls(c)[2].raw = 'K9-CONTENT-SENTINEL-2'; });
  badBuild(c => { c.exit = 1; });
  badShape(c => { delete c.provider_calls[0].shape_attempt; });
  badShape(c => { c.provider_calls[2].shape_attempt = 1; });
  badShape(c => { c.provider_calls[1].shape_attempt = 2; });
  badShape(c => { c.provider_calls[0].build_round = 1; });
  badShape(c => { delete c.provider_calls[1].request_bytes; });
  badShape(c => { c.provider_calls[1].request_bytes = 9; });
  badShape(c => { c.provider_calls.pop(); });
  console.log('k9 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the k9 Build plays one round, one review and a reset against the fake provider', { timeout: 290000 }, function () { this.k9 = observe('build'); });
  Then('the k9 Build run record carries the six fields', function () { checkBuild(this.k9); });
  When('the k9 Shape plays a request audit and a refused first submission against the fake provider', { timeout: 290000 }, function () { this.k9 = observe('shape'); });
  Then('the k9 Shape run records carry shape_attempt and request_bytes on every request', function () { checkShape(this.k9); });
}
