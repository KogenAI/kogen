'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');

const BODY_LINE = '0123456789abcdef-line\n';
const BIG = BODY_LINE.repeat(14000);
const sha = text => crypto.createHash('sha256').update(text).digest('hex');
// One normalization for every comparison between the parts and on_demand modes
// (separate repositories: different start HEAD and temp folder, so raw bytes/hashes of
// anything embedding them are only comparable within one run):
// temp paths to "T/", then runs of 7..64 lowercase hex digits to "H".
const norm = text => text.replace(/[^"\s]*TestKRevodObservation[0-9]+\/[0-9]+\//g, 'T/').replace(/[0-9a-f]{7,64}/g, 'H');
// read_file output is line-numbered: a part read is "1\t" followed by the one-line part JSON.
const stripLineNumber = text => {
  assert.ok(text.startsWith('1\t'), 'a part read lacks the line-number prefix "1\\t"');
  return text.slice(2);
};
const FILE_KEYS = ['bytes', 'git_object', 'mode', 'path', 'sha256', 'status'];
const OLD_CATALOG_KEYS = ['binding', 'candidate_tree', 'files', 'parts', 'source_bytes', 'source_sha256', 'start_head', 'version'];
const ON_DEMAND_SENTENCE = 'Read only the parts you need; no part is required before a verdict.';
const UNREAD = /^invalid verdict:\nRead all pinned source evidence before approving: \d+ unread part\(s\); use read_file on /;

function observe(scenario) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-krevod-'));
  fs.chmodSync(dir, 0o700);
  try {
    const input = path.join(dir, 'input.json'), output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(input, JSON.stringify({ scenario }), { mode: 0o600 });
    fs.writeFileSync(overlay, JSON.stringify({ Replace: {
      [path.join(ROOT, 'cli/build/krevod_acceptance_test.go')]: path.join(__dirname, 'krevod_driver.go'),
    } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestKRevodObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 280000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_KREVOD_INPUT: input, KOGEN_KREVOD_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    return JSON.parse(fs.readFileSync(output, 'utf8'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const landed = d => {
  assert.equal(d.exit, 0, d.output);
  assert.equal(d.outcome, 'landed', d.output);
  assert.equal(d.head_changed, true);
};
const lastMaterial = d => {
  assert.ok(Array.isArray(d.material_events) && d.material_events.length >= 1, 'no review_material run-log event');
  return d.material_events[d.material_events.length - 1];
};

function checkDefault(d) {
  landed(d);
  assert.deepEqual(d.catalog_keys, OLD_CATALOG_KEYS, 'the catalog gained or lost keys');
  assert.deepEqual(d.file_keys, FILE_KEYS);
  assert.deepEqual(d.part_keys, ['path', 'sha256']);
  assert.equal(d.tail_exact, true, 'the review guidance text changed');
  assert.equal(d.has_body, true, 'the opening request no longer carries the native part data it carries today');
  assert.equal(d.parts_match_disk, true);
  assert.ok(d.catalog.parts.length >= 20);
  assert.ok(d.feedback.length >= 1 && UNREAD.test(d.feedback[0]), `the first approval was not refused for unread parts: ${JSON.stringify(d.feedback)}`);
  const ev = lastMaterial(d);
  assert.equal(ev.mode, 'parts');
  assert.equal(ev.parts, d.catalog.parts.length);
  assert.equal(ev.parts_read, ev.parts);
}

function checkOpening(d) {
  const c = d.catalog;
  for (const k of OLD_CATALOG_KEYS) assert.ok(k in c, `catalog lacks ${k}`);
  assert.equal(c.mode, 'on_demand');
  assert.equal(d.has_body, false, 'a part body or file text is in the opening request');
  assert.ok(d.source_text.includes(ON_DEMAND_SENTENCE), 'on-demand guidance missing');
  assert.ok(!d.source_text.includes('Read EVERY part'), 'the read-every-part rule is still stated');
  assert.equal(d.parts_match_disk, true, 'catalog part hashes do not match the pinned files');
  assert.ok(c.parts.length >= 20);
  const byPath = Object.fromEntries(c.files.map(f => [f.path, f]));
  const app = byPath['app.txt'], extra = byPath['extra.txt'];
  assert.ok(app && extra, 'manifest lacks the changed paths');
  assert.equal(app.status, 'changed');
  assert.equal(app.bytes, BIG.length);
  assert.equal(app.sha256, sha(BIG));
  assert.deepEqual(app.diff_stat, { added: 14000, deleted: 1 });
  assert.deepEqual(app.hunks, [{ old_start: 1, old_count: 1, new_start: 1, new_count: 14000, header: '@@ -1 +1,14000 @@' }]);
  assert.equal(extra.status, 'added');
  assert.equal(extra.bytes, 14);
  assert.equal(extra.sha256, sha('one\ntwo\nthree\n'));
  assert.deepEqual(extra.diff_stat, { added: 3, deleted: 0 });
  assert.deepEqual(extra.hunks, [{ old_start: 0, old_count: 0, new_start: 1, new_count: 3, header: '@@ -0,0 +1,3 @@' }]);
  let prev = null;
  c.parts.forEach((p, i) => {
    assert.equal(p.part, i + 1);
    assert.ok(typeof p.path === 'string' && /^[0-9a-f]{64}$/.test(p.sha256));
    assert.ok(Array.isArray(p.covers) && p.covers.length > 0, `part ${i + 1} covers nothing`);
    for (const cv of p.covers) {
      assert.ok(typeof cv.path === 'string' && ['diff', 'file'].includes(cv.kind), JSON.stringify(cv));
      assert.ok(Number.isInteger(cv.first_line) && Number.isInteger(cv.last_line) && 1 <= cv.first_line && cv.first_line <= cv.last_line, JSON.stringify(cv));
    }
    const cv = p.covers.find(x => x.path === 'app.txt' && x.kind === 'file');
    if (cv) {
      if (prev) {
        assert.ok(cv.first_line >= prev.first_line && cv.first_line <= prev.last_line + 1, 'file ranges are not contiguous');
        assert.ok(cv.last_line >= prev.last_line);
      } else assert.equal(cv.first_line, 1);
      prev = cv;
    }
  });
  assert.ok(prev, 'no part covers the text of app.txt');
  assert.equal(prev.last_line, 14000);
}

function checkOnDemandApproval(d, read) {
  landed(d);
  checkOpening(d);
  assert.ok(!d.feedback.some(t => /pinned part\(s\) unread|Read all pinned/.test(t)), 'unread-part feedback in on_demand mode');
  const ev = lastMaterial(d);
  assert.equal(ev.mode, 'on_demand');
  assert.equal(ev.parts, d.catalog.parts.length);
  assert.equal(ev.parts_read, read);
}

function checkReads(d) {
  landed(d.parts); landed(d.on_demand);
  assert.equal(d.parts.authority_sha, d.on_demand.authority_sha, 'authority changed');
  // within each run the raw part hashes must equal that run's catalog exactly
  assert.equal(d.parts.parts_match_disk, true, 'parts mode: catalog part hashes do not match the pinned files');
  assert.equal(d.on_demand.parts_match_disk, true, 'on_demand mode: catalog part hashes do not match the pinned files');
  for (const k of ['part1', 'range']) {
    assert.ok(d.parts.reads[k] && d.parts.reads[k].length > 0, `no ${k} read in parts mode`);
    assert.ok(d.on_demand.reads[k] && d.on_demand.reads[k].length > 0, `no ${k} read in on_demand mode`);
    assert.equal(norm(d.on_demand.reads[k]), norm(d.parts.reads[k]), `${k} read differs`);
  }
  assert.equal(JSON.parse(stripLineNumber(d.parts.reads.part1)).review_source.part, 1);
  assert.ok(d.parts.reads.range.includes('0123456789abcdef-line'));
  // across runs: SHA-256 of each part's normalized bytes (every part read)
  assert.ok(Array.isArray(d.parts.part_norm_sha) && d.parts.part_norm_sha.length >= 20, 'normalized part hashes missing');
  assert.equal(d.parts.part_norm_sha.length, d.parts.catalog.parts.length);
  assert.equal(d.on_demand.part_norm_sha.length, d.on_demand.catalog.parts.length);
  assert.deepEqual(d.on_demand.part_norm_sha, d.parts.part_norm_sha, 'normalized part hashes differ');
}

function checkInline(d) {
  landed(d.default); landed(d.on_demand);
  assert.equal(d.default.evidence_events, 0);
  assert.equal(d.on_demand.evidence_events, 0);
  assert.equal(d.default.material_events.length, 0);
  assert.equal(d.on_demand.material_events.length, 0);
  assert.ok(d.default.normalized.includes('Full text of every changed or added file'));
  assert.equal(norm(d.on_demand.normalized), norm(d.default.normalized), 'the request differs');
}

function checkConfig(d) {
  for (const k of ['absent', 'parts', 'on_demand']) assert.equal(d[k].ok, true, `${k}: ${d[k].error}`);
  assert.equal(d.bad_value.ok, false);
  assert.ok(d.bad_value.error.includes('line 3: review_material.mode must be parts or on_demand'), d.bad_value.error);
  assert.equal(d.bad_key.ok, false);
  assert.ok(d.bad_key.error.includes('line 4: unknown key extra'), d.bad_key.error);
  assert.equal(d.scalar.ok, false);
  assert.ok(d.scalar.error.includes('line 2: review_material must be a mapping'), d.scalar.error);
}

function checkDocs() {
  const text = fs.readFileSync(path.join(ROOT, 'docs/configuration.md'), 'utf8');
  const line = text.split('\n').find(l => l.includes('review_material'));
  assert.ok(line, 'docs/configuration.md does not mention review_material');
  assert.ok(/experimental/i.test(line) && /off by default/i.test(line) && line.includes('on_demand') && line.includes('parts'), line);
  assert.ok(text.indexOf('review_material') > text.indexOf('shape_decision_check'), 'not next to the other levers');
}

// ---- observer controls ----
function goodCatalog(digit = 'a') {
  const parts = Array.from({ length: 22 }, (_, i) => ({
    path: `/p/${i + 1}.json`, sha256: digit.repeat(64), part: i + 1,
    covers: [{ path: 'app.txt', kind: 'file', first_line: i * 650 + 1, last_line: i === 21 ? 14000 : (i + 1) * 650 }],
  }));
  const mk = (p, status, bytes, content, stat, hunk) => ({ path: p, status, mode: '100644', git_object: 'b'.repeat(40), bytes, sha256: sha(content), diff_stat: stat, hunks: [hunk] });
  return {
    version: 1, candidate_tree: 't', binding: 'candidate', start_head: 'h', source_bytes: 1, source_sha256: 'c'.repeat(64), mode: 'on_demand', parts,
    files: [
      mk('app.txt', 'changed', BIG.length, BIG, { added: 14000, deleted: 1 }, { old_start: 1, old_count: 1, new_start: 1, new_count: 14000, header: '@@ -1 +1,14000 @@' }),
      mk('extra.txt', 'added', 14, 'one\ntwo\nthree\n', { added: 3, deleted: 0 }, { old_start: 0, old_count: 0, new_start: 1, new_count: 3, header: '@@ -0,0 +1,3 @@' }),
    ],
  };
}
function goodOnDemand(read) {
  const catalog = goodCatalog();
  return { exit: 0, outcome: 'landed', head_changed: true, output: '', catalog, has_body: false, parts_match_disk: true, feedback: [],
    source_text: 'x ' + ON_DEMAND_SENTENCE, material_events: [{ event: 'review_material', mode: 'on_demand', parts: 22, parts_read: read }] };
}
function goodDefault() {
  const catalog = { version: 1, candidate_tree: 't', binding: 'candidate', start_head: 'h', source_bytes: 1, source_sha256: 'c', files: [], parts: Array.from({ length: 22 }, () => ({})) };
  return { exit: 0, outcome: 'landed', head_changed: true, output: '', catalog, catalog_keys: OLD_CATALOG_KEYS, file_keys: FILE_KEYS, part_keys: ['path', 'sha256'],
    tail_exact: true, has_body: true, parts_match_disk: true, feedback: ['invalid verdict:\nRead all pinned source evidence before approving: 9 unread part(s); use read_file on /a'],
    material_events: [{ mode: 'parts', parts: 22, parts_read: 22 }] };
}
function controls(kind) {
  // part reads are line-numbered by read_file: "1\t" then the one-line part JSON
  const reads = { part1: '1\t{"review_source":{"part":1}}', range: '0123456789abcdef-line\n' };
  const norms = Array.from({ length: 22 }, (_, i) => sha(`part ${i}`));
  const reading = { ...goodOnDemand(0), reads, authority_sha: 'x', normalized: 'Full text of every changed or added file', part_norm_sha: norms };
  const cfg = ok => ({ ok, error: '' });
  const goodConfig = { absent: cfg(true), parts: cfg(true), on_demand: cfg(true),
    bad_value: { ok: false, error: 'line 3: review_material.mode must be parts or on_demand' },
    bad_key: { ok: false, error: 'line 4: unknown key extra' }, scalar: { ok: false, error: 'line 2: review_material must be a mapping' } };
  checkDefault(goodDefault());
  checkOnDemandApproval(goodOnDemand(0), 0); checkOnDemandApproval(goodOnDemand(1), 1);
  checkReads({ parts: { ...reading, catalog: goodCatalog() }, on_demand: { ...reading, catalog: goodCatalog() } });
  // two separate runs: reads and raw catalog hashes differ only by temp path/start HEAD; normalized content is equal
  const withHead = (h, tmp) => ({ ...reads, part1: `1\t{"review_source":{"part":1,"text":"# Diff of existing/deleted paths against start HEAD ${h}\\n${tmp}accept.sh"}}` });
  checkReads({
    parts: { ...reading, reads: withHead('1234567', '/tmp/TestKRevodObservation111/001/'), catalog: goodCatalog('a') },
    on_demand: { ...reading, reads: withHead('abcdef0123', '/tmp/TestKRevodObservation222/003/'), catalog: goodCatalog('d') },
  });
  checkInline({ default: { ...reading, evidence_events: 0, material_events: [] }, on_demand: { ...reading, evidence_events: 0, material_events: [] } });
  checkConfig(goodConfig);
  if (kind === 'good') { console.log('krevod observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, d, mutate) => { const c = structuredClone(d); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  bad(checkDefault, goodDefault(), d => { d.feedback = []; });
  bad(checkDefault, goodDefault(), d => { d.catalog_keys = [...OLD_CATALOG_KEYS, 'mode']; });
  bad(checkDefault, goodDefault(), d => { d.has_body = false; });
  bad(checkDefault, goodDefault(), d => { d.tail_exact = false; });
  bad(d => checkOnDemandApproval(d, 0), goodOnDemand(0), d => { d.has_body = true; });
  bad(d => checkOnDemandApproval(d, 0), goodOnDemand(0), d => { d.catalog.files[0].hunks = []; });
  bad(d => checkOnDemandApproval(d, 0), goodOnDemand(0), d => { d.catalog.parts[3].covers = []; });
  bad(d => checkOnDemandApproval(d, 0), goodOnDemand(0), d => { d.catalog.parts[5].covers[0].first_line = 9000; });
  bad(d => checkOnDemandApproval(d, 0), goodOnDemand(0), d => { d.feedback = ['invalid verdict:\n3 pinned part(s) unread; read them before a verdict;']; });
  bad(d => checkOnDemandApproval(d, 1), goodOnDemand(0), () => {});
  bad(d => checkOnDemandApproval(d, 0), goodOnDemand(0), d => { d.source_text = 'Read EVERY part ' + ON_DEMAND_SENTENCE; });
  bad(checkReads, { parts: { ...reading, catalog: goodCatalog() }, on_demand: { ...reading, catalog: goodCatalog(), reads: { ...reads, range: 'other' } } }, () => {});
  bad(checkReads, { parts: { ...reading, catalog: goodCatalog() }, on_demand: { ...reading, catalog: goodCatalog(), reads: { ...reads, part1: '1\t{"review_source":{"part":1,"x":1}}' } } }, () => {});
  bad(checkReads, { parts: { ...reading, reads: { ...reads, part1: '{"review_source":{"part":1}}' }, catalog: goodCatalog() }, on_demand: { ...reading, reads: { ...reads, part1: '{"review_source":{"part":1}}' }, catalog: goodCatalog() } }, () => {});
  bad(checkReads, { parts: { ...reading, catalog: goodCatalog() }, on_demand: { ...reading, catalog: goodCatalog(), part_norm_sha: norms.map((s, i) => (i === 7 ? sha('other') : s)) } }, () => {});
  bad(checkReads, { parts: { ...reading, catalog: goodCatalog() }, on_demand: { ...reading, catalog: goodCatalog(), parts_match_disk: false } }, () => {});
  bad(checkInline, { default: { ...reading, evidence_events: 0, material_events: [] }, on_demand: { ...reading, normalized: 'different', evidence_events: 0, material_events: [] } }, () => {});
  bad(checkConfig, goodConfig, d => { d.bad_value = { ok: true, error: '' }; });
  bad(checkConfig, goodConfig, d => { d.bad_value.error = 'line 3: mode is wrong'; });
  console.log('krevod observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else if (require.main !== module) {
  const { When, Then } = require('@cucumber/cucumber');
  const cache = new Map();
  When('the krevod observation {string} runs', { timeout: 290000 }, function (scenario) {
    if (!cache.has(scenario)) cache.set(scenario, observe(scenario));
    this.krevod = cache.get(scenario);
  });
  Then('the krevod default opening is unchanged and the unread approval was refused', function () { checkDefault(this.krevod); });
  Then('the krevod opening carries the manifest and no part body', function () { checkOpening(this.krevod); });
  Then('the krevod approval with no part read was accepted', function () { checkOnDemandApproval(this.krevod, 0); });
  Then('the krevod approval after one part read was accepted', function () { checkOnDemandApproval(this.krevod, 1); });
  Then('the krevod part and line-range reads equal the default mode bytes', function () { checkReads(this.krevod); });
  Then('the krevod on_demand request equals the parts request when the source fits', function () { checkInline(this.krevod); });
  Then('the krevod config refuses invalid review_material values naming the key', function () { checkConfig(this.krevod); });
  Then('the krevod configuration documentation presents review_material as experimental and off by default', function () { checkDocs(); });
}
