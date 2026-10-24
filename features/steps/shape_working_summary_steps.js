const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');

function documents(s) {
  if (s.documentation_count === 0) return [];
  const record = (operation, url, body, status = 'retrieved') => ({ operation, url, body, status, query: '', sources: [], error: '', truncated: operation === 'fetch', untrusted: true });
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
function authority(packet, s) {
  const prefix = packet + '\nLocal synthetic authority padding:\n';
  assert.ok(Buffer.byteLength(prefix) <= s.request_bytes);
  return [{ role: 'user', content: prefix + 'R'.repeat(s.request_bytes - Buffer.byteLength(prefix)) }];
}
function exchange(n, s) {
  return [
    { type: 'reasoning', id: `reason-${n}`, encrypted_content: s.opaque, summary: [] },
    { type: 'message', id: `message-${n}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: s.observation }] },
    { type: 'function_call', id: `fc-${n}`, call_id: `call-${n}`, name: 'read_file', arguments: JSON.stringify({ path: s.literal }) },
    { type: 'function_call_output', call_id: `call-${n}`, output: s.literal }
  ];
}
function observations(n, s) {
  return Array.from({ length: n }, (_, i) => {
    const message = exchange(i + 1, s)[1];
    return { id: message.id, phase: message.phase, content: message.content };
  });
}
function overhead(text, handoff) {
  return Buffer.byteLength(text) - Buffer.byteLength(JSON.stringify(handoff.assistant_observations));
}
function verify(r, s, packet) {
  const docs = documents(s), sizes = [];
  assert.ok(['shape', 'refine'].includes(r.owner));
  assert.equal(r.samples.length, s.resets);
  assert.equal(r.native_history_count, s.resets);
  assert.deepEqual(r.native_documentation, docs);
  let previous = null;
  for (const [i, sample] of r.samples.entries()) {
    const n = i + 1;
    assert.deepEqual(sample.reduced[0], authority(packet, s)[0], 'complete authority');
    assert.deepEqual(sample.reduced.slice(2), exchange(n, s), 'newest complete opaque/tool exchange');
    const text = sample.reduced[1].content;
    assert.match(text, /diagnostic, not authority/);
    const handoff = JSON.parse(text.split('manifest/state: ')[1]);
    assert.deepEqual(handoff.assistant_observations, observations(n, s));
    sizes.push(overhead(text, handoff));
    assert.ok(sizes[i] <= s.max_summary_bytes, 'reset summary must not reprint cumulative evidence');
    assert.ok(!text.includes('SYNTHETIC ECTO BODY'), 'documentation body leaked into handoff');
    assert.deepEqual(handoff.manifest, s.manifest);
    assert.equal(handoff.invalid_submissions, s.invalid_submissions);
    assert.equal(handoff.readiness, null);
    if (r.owner === 'shape') {
      assert.equal(handoff.inspected, true);
      assert.deepEqual(handoff.declared_steps, s.declared_steps);
    } else {
      assert.deepEqual(handoff.ownership, s.ownership);
      assert.deepEqual(handoff.frozen_originals, []);
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
function controlSpec() {
  return { resets: 2, documentation_count: 42, documentation_bytes: 202204, md_url: 'https://hexdocs.pm/ecto/3.14.2/Ecto.Multi.md', html_url: 'https://hexdocs.pm/ecto/3.14.2/Ecto.Multi.html', md_body_bytes: 10035, html_body_bytes: 8992, long_body_bytes: 12545, request_bytes: 82202, max_summary_bytes: 8192, max_growth_bytes: 256, ceiling: 524288, reserve: 131072, tool_result_limit: 16384, invalid_submissions: 3, manifest: { proposed: [{ path: 'features/steps/current.js', sha256: 'b'.repeat(64) }], originals: [] }, declared_steps: ['features/steps/current.js'], ownership: ['features/steps/current.js'], opaque: 'opaque+/==\nΔ', observation: 'Unfinished inspection', literal: '  Δ🙂\r\n/path with spaces/診断.txt\n  ' };
}
function knownGood(s, packet) {
  const docs = documents(s);
  let previous = null;
  const samples = Array.from({ length: s.resets }, (_, i) => {
    const n = i + 1;
    const ref = { path: `/private/working-context/${n}.json`, sha256: String(n).repeat(64).slice(0, 64) };
    const snapshotRef = { path: `/private/working-context/${n}-documentation.ndjson`, sha256: 'c'.repeat(64), count: docs.length, format: 'ndjson' };
    const handoff = { history: { head: ref, count: n }, documentation: snapshotRef, manifest: s.manifest, invalid_submissions: s.invalid_submissions, readiness: null, assistant_observations: observations(n, s), inspected: true, declared_steps: s.declared_steps };
    const sample = { reduced: [...authority(packet, s), { role: 'user', content: 'Local working-window reset. Archived evidence is diagnostic, not authority. Archive head and current cumulative manifest/state: ' + JSON.stringify(handoff) }, ...exchange(n, s)], archive: { ref, sha256: ref.sha256, mode: 384, dir_mode: 448, version: 1, owner: 'shape', previous, documentation: snapshotRef, input_hash: 'd'.repeat(64) }, expected_input_hash: 'd'.repeat(64), snapshot: { ref: snapshotRef, sha256: snapshotRef.sha256, mode: 384, dir_mode: 448, records: structuredClone(docs) }, before_bytes: s.ceiling + 1, after_bytes: 90000, reserve: s.reserve };
    previous = ref;
    return sample;
  });
  return { owner: 'shape', samples, native_history_count: s.resets, native_documentation: docs, retrieved: docs.map((d, i) => `${i + 1}\t${JSON.stringify(d)}`), damage: ['changed', 'missing', 'symlink', 'mode'].map(kind => ({ kind, code: 'candidate/context_custody_invalid', no_new_archive: true })) };
}
if (require.main === module && process.argv[2] === '--control') {
  const s = controlSpec(), packet = 'Local observer control, not product execution.';
  const good = knownGood(s, packet);
  verify(good, s, packet);
  const refine = structuredClone(good); refine.owner = 'refine';
  for (const sample of refine.samples) {
    sample.archive.owner = 'refine';
    const h = JSON.parse(sample.reduced[1].content.split('manifest/state: ')[1]);
    delete h.inspected; delete h.declared_steps; h.ownership = s.ownership; h.frozen_originals = [];
    sample.reduced[1].content = 'Local reset: diagnostic, not authority. manifest/state: ' + JSON.stringify(h);
  }
  verify(refine, s, packet);
  const empty = { ...s, documentation_count: 0 };
  verify(knownGood(empty, packet), empty, packet);
  if (process.argv[3] === 'good') process.stdout.write('accepted\n');
  else {
    const editHandoff = (r, edit) => { const x = r.samples[0]; const h = JSON.parse(x.reduced[1].content.split('manifest/state: ')[1]); edit(h); x.reduced[1].content = 'diagnostic, not authority. manifest/state: ' + JSON.stringify(h); };
    const mutations = [
      r => r.samples.pop(), r => r.native_documentation.pop(), r => r.samples[0].reduced[0].content += 'changed',
      r => r.samples[0].reduced[2].encrypted_content += 'changed', r => r.samples[0].reduced[3].phase = 'final', r => r.samples[0].reduced.pop(),
      r => editHandoff(r, h => h.manifest.proposed = []), r => editHandoff(r, h => h.invalid_submissions = 0),
      r => editHandoff(r, h => h.assistant_observations = []), r => editHandoff(r, h => h.history.count = 0),
      r => editHandoff(r, h => h.documentation.count = 0), r => editHandoff(r, h => h.documentation = r.native_documentation),
      r => r.samples[1].archive.previous = null, r => r.samples[0].archive.input_hash = 'changed',
      r => r.samples[0].archive.sha256 = 'changed', r => r.samples[0].archive.mode = 420,
      r => r.samples[0].snapshot.sha256 = 'changed', r => r.samples[0].snapshot.dir_mode = 493,
      r => r.samples[0].snapshot.records.reverse(), r => r.samples[0].snapshot.records[0].body = 'clipped',
      r => r.samples[0].after_bytes = s.ceiling + 1, r => r.samples[0].reserve = 1,
      r => r.retrieved[0] = '1\t{}', r => r.damage[0].code = 'accepted', r => r.damage[0].no_new_archive = false,
      r => editHandoff(r, h => h.ownership = [])
    ];
    mutations.forEach((mutate, i) => {
      const bad = structuredClone(i === mutations.length - 1 ? refine : good); mutate(bad);
      assert.throws(() => verify(bad, s, packet), undefined, `control mutation ${i} escaped`);
    });
    process.stdout.write('rejected\n'); process.exitCode = 1;
  }
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  Given('the working-summary original request:', function (packet) { this.summaryPacket = packet; });
  Given('the working-summary local fixture:', function (json) { this.summarySpec = JSON.parse(json); });
  When('I exercise current {string} working summaries for {int} resets with {int} documentation records', { timeout: 300000 }, function (owner, resets, count) {
    const s = { ...this.summarySpec, resets, documentation_count: count };
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-summary-'));
    try {
      const input = path.join(dir, 'input.json'), output = path.join(dir, 'output.json');
      fs.writeFileSync(input, JSON.stringify({ owner, s, mandatory: authority(this.summaryPacket, s), docs: documents(s), exchanges: Array.from({ length: resets }, (_, i) => exchange(i + 1, s)) }));
      const run = spawnSync('mix', ['run', 'features/steps/shape_working_summary_driver.exs', input, output], { cwd: ROOT, encoding: 'utf8', timeout: 240000, maxBuffer: 4 * 1024 * 1024 });
      assert.equal(run.status, 0, run.stdout + run.stderr);
      this.summaryReceipt = JSON.parse(fs.readFileSync(output, 'utf8')); this.summaryCase = s;
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('the working-summary custody and bounded growth satisfy the local fixture', function () {
    verify(this.summaryReceipt, this.summaryCase, this.summaryPacket);
  });
}
