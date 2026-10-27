const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');

const ROOT = path.resolve(__dirname, '../..');
const HEAD = '33e7f4ec8ba899fc4aa621127379e5cb26b77648';
const DEFAULT_SOURCE = '/Users/almirsarajcic/Areas/Kogen/delivery/kogen-loop';
const EXCLUDED = p => p.startsWith('.kogen/') || p.startsWith('features/');

function walk(dir, base = dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(file, base, out);
    else out.push(path.relative(base, file).split(path.sep).join('/'));
  }
  return out.sort();
}

function git(cwd, ...args) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' });
}

// Pure comparison: the vendored file list and bytes against the source's tracked list and bytes.
function compareTrees(vendored, source) {
  const v = Object.keys(vendored).sort();
  const s = Object.keys(source).sort();
  assert.deepEqual(v, s, 'vendored file list differs from the source checkout');
  for (const name of v) assert.ok(vendored[name].equals(source[name]), `bytes differ: ${name}`);
}

When('I compare the vendored loop with the clean kogen-loop source checkout', function () {
  const vendoredRoot = path.join(ROOT, 'cli/third_party/kogen-loop');
  const vendored = {};
  for (const f of walk(vendoredRoot)) vendored[f] = fs.readFileSync(path.join(vendoredRoot, f));
  this.k5 = { vendored, source: null };
  const dir = process.env.KOGEN_LOOP_SOURCE || DEFAULT_SOURCE;
  if (!fs.existsSync(path.join(dir, '.git'))) return;
  assert.equal(git(dir, 'rev-parse', 'HEAD').trim(), HEAD, 'source checkout is not at the pinned commit');
  assert.equal(git(dir, 'status', '--porcelain', '--untracked-files=all').trim(), '', 'source checkout is not clean');
  const source = {};
  for (const f of git(dir, 'ls-files').split('\n').filter(Boolean)) {
    if (!EXCLUDED(f)) source[f] = fs.readFileSync(path.join(dir, f));
  }
  this.k5.source = source;
});

Then('the vendored loop has {int} files, none under .kogen or features, and equals the source checkout when one is available', function (count) {
  const names = Object.keys(this.k5.vendored);
  assert.equal(names.length, count);
  assert.ok(!names.some(EXCLUDED), 'vendored copy contains .kogen/ or features/ paths');
  if (this.k5.source) {
    assert.equal(Object.keys(this.k5.source).length, count);
    compareTrees(this.k5.vendored, this.k5.source);
  }
});

When('I read the re-pin documentation and the Kogen sources', function () {
  const read = p => fs.readFileSync(path.join(ROOT, p), 'utf8');
  const evidenceDir = path.join(ROOT, 'docs/evidence');
  const evidence = walk(evidenceDir).map(f => ({ f, text: fs.readFileSync(path.join(evidenceDir, f), 'utf8') }));
  const goFiles = [];
  (function scan(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory()) { if (entry.name !== 'third_party' && entry.name !== 'node_modules') scan(file); }
      else if (entry.name.endsWith('.go')) goFiles.push({ f: path.relative(ROOT, file), text: fs.readFileSync(file, 'utf8') });
    }
  })(path.join(ROOT, 'cli'));
  this.k5docs = {
    chatgpt: read('spec/prose/08-chatgpt.md'),
    prose: fs.readdirSync(path.join(ROOT, 'spec/prose')).map(f => read('spec/prose/' + f)).join('\n'),
    oldEvidence: read('docs/evidence/extract-loop-executors/README.md'),
    evidence, goFiles,
  };
});

Then('the specification documents the Anthropic provider failure map and the usage decision', function () {
  const p = this.k5docs.prose;
  for (const needle of ['anthropic_invalid', 'invalid_response', 'error_type', 'stop_reason', 'block_type', 'delta_type', 'unknown', 'provider_failure_code']) {
    assert.ok(p.includes(needle), `spec/prose does not mention ${needle}`);
  }
  assert.ok(this.k5docs.chatgpt.includes('provider_failure'), 'ChatGPT paragraph removed');
});

Then('a re-pin evidence note names the new commit, 107 files and the new digest while the old evidence keeps its history', function () {
  const digest = '3f99ae913cfe08c356bc0543746ae0ebf581880531081633e8d23559d0a74c2c';
  const note = this.k5docs.evidence.find(e => e.text.includes(HEAD) && e.text.includes(digest) && e.text.includes('107'));
  assert.ok(note, 'no evidence note under docs/evidence names 33e7f4ec, 107 files and the new digest');
  assert.ok(this.k5docs.oldEvidence.includes('bbf3fdd6d2e79b96eab6af23bcd6d66212893388'), 'old evidence history was rewritten');
  assert.ok(this.k5docs.oldEvidence.includes('4e1332b9f0aa686d76040466a965a43a5169ba9295631cf7bb9b8f62fb946638'), 'old evidence history was rewritten');
  assert.ok(/third_party\/kogen-loop/.test(this.k5docs.evidence.map(e => e.text).join('\n')) && /\.\/\.\.\./.test(this.k5docs.evidence.map(e => e.text).join('\n')), 'nested-module note missing');
});

Then('Kogen sources never set a shell timeout and its probe passes a context', function () {
  for (const { f, text } of this.k5docs.goFiles) {
    if (f.endsWith('_test.go')) continue;
    assert.ok(!/ShellTimeout/.test(text), `${f} sets or names ShellTimeout`);
  }
  const probe = this.k5docs.goFiles.find(g => g.f === 'cli/verify/probe.go');
  assert.ok(probe, 'probe.go missing');
  assert.match(probe.text, /sys\.Options\{[^}]*Context:[^}]*\}/, 'probe does not pass Context');
  assert.match(probe.text, /sys\.Options\{[^}]*Timeout: deadline[^}]*\}/, 'probe lost its deadline');
});
