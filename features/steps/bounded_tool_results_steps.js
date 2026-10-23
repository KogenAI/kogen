const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const driver = path.join(__dirname, 'bounded_tool_results_driver.exs');
const feature = path.join(root, '.kogen/intents/bounded-tool-results/acceptance.feature');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
function textResult(actual, original, spec) {
  assert.equal(typeof actual, 'string');
  const bytes = Buffer.from(actual), source = Buffer.from(original);
  assert.equal(bytes.toString('utf8'), actual, 'invalid UTF-8 display');
  assert.ok(bytes.length <= spec.limit, `unbounded result: ${bytes.length}`);
  if (source.length <= spec.limit) return assert.equal(actual, original, 'fitting result changed');
  const m = actual.match(/^([\s\S]*)\n\[\.\.\. (\d+) bytes omitted \.\.\.\]\n([\s\S]*)$/);
  assert.ok(m, 'oversized result lacks the honest omission marker');
  const head = Buffer.from(m[1]), tail = Buffer.from(m[3]);
  let end = spec.head;
  while (Buffer.from(source.subarray(0, end).toString('utf8')).compare(source.subarray(0, end)) !== 0) end--;
  assert.equal(head.compare(source.subarray(0, end)), 0, 'wrong head');
  assert.equal(tail.compare(source.subarray(source.length - tail.length)), 0, 'wrong tail');
  assert.equal(Number(m[2]), source.length - head.length - tail.length, 'incorrect omitted byte count');
  // Existing cutter reserves marker width from the original count; allow that
  // conservative decimal-width difference and a partial UTF-8 character.
  assert.ok(bytes.length >= spec.limit - 6, 'suffix needlessly discarded');
}
function boundary(data, spec) {
  assert.equal(data.mode, 'boundary');
  assert.equal(data.results.length, spec.sizes.length + 3);
  for (const row of data.results) {
    textResult(row.actual, row.source, spec);
    assert.equal(row.again, row.actual, 'bounding is not idempotent');
    assert.equal(row.call_id, row.expected_call_id, 'tool pair changed');
  }
  assert.deepEqual(data.typed.actual, data.typed.source, 'typed image content changed');
  assert.equal(data.typed.call_id, data.typed.expected_call_id);
  assert.deepEqual(data.measure.bytes, [spec.ceiling - 1, spec.ceiling, spec.ceiling + 1]);
  assert.deepEqual(data.measure.fits, [true, true, false]);
  assert.deepEqual(data.measure.reserves, [spec.reserve, spec.reserve, spec.reserve]);
}
function native(data, spec) {
  assert.equal(data.exit, spec.statuses[data.mode], data.output);
  assert.ok(!data.output.includes('candidate/context_budget_exceeded'), data.output);
  assert.ok(data.requests.length > 1, 'no continuation reached the provider');
  const windows = data.requests.map(r => {
    assert.ok(Buffer.byteLength(r.body) <= spec.ceiling, 'oversized provider request');
    assert.deepEqual(JSON.parse(r.body), r.json, 'wrong rendered body');
    return r.json.input;
  });
  for (const file of data.history) {
    const bytes = Buffer.from(file.bytes, 'base64');
    assert.equal(hash(bytes), file.sha256, 'changed custody');
    assert.equal(file.mode, 384); assert.equal(file.dir_mode, 448);
    windows.push(JSON.parse(bytes).input);
  }
  for (const [phase, authority] of Object.entries(data.authorities)) {
    assert.ok(JSON.stringify(authority).includes(JSON.stringify(spec.packet).slice(1, -1)), 'original packet missing');
    const requests = data.requests.filter(r => r.phase === phase);
    assert.ok(requests.length > 1, `missing ${phase} continuation`);
    // Responses renders plain user strings as one typed input_text block.
    const rendered = typeof authority.content === 'string' ? { ...authority, content: [{ type: 'input_text', text: authority.content }] } : authority;
    for (const r of requests) assert.deepEqual(r.json.input.find(i => i.role === 'user'), rendered, 'authority clipped or changed');
  }
  for (const g of data.groups) {
    let delivered = false;
    for (const w of windows) {
      const n = w.findIndex(i => i.type === 'function_call' && i.call_id === g.calls[0].call_id);
      if (n < 2 || !same(w.slice(n - 2, n), g.prefix) || !same(w.slice(n, n + g.calls.length), g.calls)) continue;
      const outputs = w.slice(n + g.calls.length, n + 2 * g.calls.length);
      if (outputs.length !== g.calls.length) continue;
      for (let j = 0; j < outputs.length; j++) {
        const out = outputs[j], expected = g.sources[j];
        assert.equal(out.type, 'function_call_output');
        assert.equal(out.call_id, g.calls[j].call_id, 'reordered/unpaired tool output');
        let source = expected.text;
        if (expected.probe) {
          const metadata = out.output.match(/^exit status: 0\ntimed_out: false\nwall: [\d.]+ s\n/);
          assert.ok(metadata, 'probe metadata was lost');
          source = metadata[0] + source;
        }
        textResult(out.output, source, spec);
      }
      delivered = true; break;
    }
    assert.ok(delivered, `complete replay not delivered: ${g.calls[0].call_id}`);
  }
  assert.deepEqual(data.files_after, data.files_before, 'read fixtures changed');
  assert.equal(data.ordinary, spec.ordinary, 'ordinary ranged read semantics changed');
  if (data.mode === 'shape') {
    assert.ok(data.history.length > 0, 'did not exercise a real working-window reset');
    assert.ok(data.output.includes(spec.question), 'did not reach the next product question');
    assert.equal(data.head_after, data.head_before, 'Shape committed');
    assert.equal(data.approval_after, data.approval_before, 'Shape changed approval');
    assert.ok(data.groups.some(g => g.calls.some(c => c.name === 'read_file' && JSON.parse(c.arguments).path === data.history[0].path)), 'actual reset custody was not read');
  } else if (data.mode === 'refine') {
    assert.ok(data.output.includes('refined fixture'), data.output);
    assert.equal(data.head_after, data.head_before, 'Refine committed');
    assert.equal(data.published, data.proposed, 'owned correction not published');
    assert.equal(data.approval_after, null, 'old approval not revoked');
  } else {
    assert.notEqual(data.head_after, data.head_before, 'Build did not land');
    assert.equal(data.app_after, 'bounded implementation\n');
    assert.ok(Object.hasOwn(data.authorities, 'build') && Object.hasOwn(data.authorities, 'review'), 'independent review absent');
    assert.equal(data.approval_after, null, 'landed approval not consumed');
  }
}
function observe(data, spec) {
  if (data.mode === 'boundary') boundary(data, spec); else native(data, spec);
}
function runDriver(mode, spec, archive) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bounded-results-'));
  try {
    const input = path.join(dir, 'input.json'), receipt = path.join(dir, 'receipt.json');
    fs.writeFileSync(input, JSON.stringify(spec));
    const r = spawnSync('mix', ['run', '--no-start', driver, mode, input, receipt], {
      cwd: root, env: { ...process.env, MIX_ENV: 'test', TMPDIR: dir, ...(archive ? { KOGEN_ARCHIVE: archive } : {}) },
      encoding: 'utf8', timeout: 240000, maxBuffer: 4 * 1024 * 1024,
    });
    assert.equal(r.error, undefined, String(r.error));
    assert.equal(r.status, 0, r.stdout + r.stderr);
    return JSON.parse(fs.readFileSync(receipt, 'utf8'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
if (require.main === module && process.argv[2] === '--control') {
  const spec = JSON.parse(fs.readFileSync(feature, 'utf8').match(/"""json\s*([\s\S]*?)\s*"""/)[1]);
  const fixtures = runDriver('control', spec);
  for (const fixture of fixtures) observe(fixture, spec);
  if (process.argv[3] === 'good') process.stdout.write('bounded observer accepted good fixtures\n');
  else if (process.argv[3] === 'bad') {
    // Independently corrupt every observation branch, including assertions after the
    // primary missing-feature red. Controls use actual locally serialized fixture bytes.
    for (const fixture of fixtures) {
      const mutations = fixture.mode === 'boundary' ? [
        d => { d.results[0].actual += 'x'; },
        d => { d.results[2].actual = d.results[2].source; },
        d => { d.results[2].actual = d.results[2].actual.replace(/\d+ bytes omitted/, '1 bytes omitted'); },
        d => { d.results[3].actual = 'wrong'; },
        d => { d.results[4].again += 'x'; },
        d => { d.results[5].call_id += 'wrong'; },
        d => { d.typed.actual[1].image_url += 'wrong'; },
        d => { d.measure.fits[1] = false; },
        d => { d.measure.reserves[0] = 0; },
      ] : [
        d => { d.exit = 1; },
        d => { d.requests = []; },
        d => { d.requests[0].body = 'x'.repeat(spec.ceiling + 1); },
        d => { d.history[0].sha256 = '0'.repeat(64); },
        d => { d.history[0].mode = 420; },
        d => { d.authorities[Object.keys(d.authorities)[0]] = { role: 'user', content: 'clipped' }; },
        d => { for (const r of d.requests) for (const i of r.json.input) if (i.type === 'function_call_output') i.output = 'wrong'; for (const r of d.requests) r.body = JSON.stringify(r.json); d.history = []; },
        d => { d.groups[0].prefix[0].encrypted_content += 'changed'; },
        d => { d.groups[0].prefix[1].phase = 'final'; },
        d => { d.groups[0].calls.reverse(); },
        d => { d.files_after = {}; },
        d => { d.ordinary = 'wrong'; },
        d => { if (d.mode === 'shape') d.output = ''; else if (d.mode === 'refine') d.published = 'wrong'; else d.head_after = d.head_before; },
        d => { d.approval_after = 'wrong'; },
      ];
      for (const mutate of mutations) {
        const bad = structuredClone(fixture); mutate(bad);
        assert.throws(() => observe(bad, spec), 'accepted a bad fixture');
      }
    }
    process.stdout.write('bounded observer rejected bad fixtures\n'); process.exitCode = 1;
  } else throw new Error('unknown control');
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  let archive;
  Given('this bounded tool-result contract:', function (json) { this.boundedSpec = JSON.parse(json); });
  When('I exercise bounded tool results through {string}', { timeout: 540000 }, function (mode) {
    if (mode !== 'boundary' && !archive) {
      const r = spawnSync('/bin/sh', ['packaging/package.sh'], { cwd: root, encoding: 'utf8', timeout: 240000, maxBuffer: 4 * 1024 * 1024 });
      assert.equal(r.error, undefined, String(r.error)); assert.equal(r.status, 0, r.stdout + r.stderr);
      archive = r.stdout.split('\n').map(s => s.trim()).find(s => s.startsWith('/') && s.endsWith('.tar.gz'));
      assert.ok(archive && fs.statSync(archive).isFile(), r.stdout + r.stderr);
    }
    this.boundedObservations = runDriver(mode, this.boundedSpec, archive);
  });
  Then('the bounded tool-result observations satisfy the contract', function () { observe(this.boundedObservations, this.boundedSpec); });
}
