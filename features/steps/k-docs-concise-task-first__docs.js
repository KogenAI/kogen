const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');

const root = process.cwd();
const P = 'k-docs-concise-task-first: ';

function read(rel) {
  const full = path.join(root, rel);
  assert.ok(fs.existsSync(full), `${rel} does not exist`);
  return fs.readFileSync(full, 'utf8');
}

function lines(text) {
  return text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
}

function fences(text) {
  const out = [];
  let cur = null;
  for (const line of text.split('\n')) {
    if (/^\s*```/.test(line)) {
      if (cur === null) cur = [];
      else { out.push(cur.join('\n')); cur = null; }
    } else if (cur !== null) cur.push(line);
  }
  return out;
}

Then(P + '{word} has fewer than {int} lines', function (file, n) {
  const got = lines(read(file));
  assert.ok(got < n, `${file} has ${got} lines, expected fewer than ${n}`);
});

Then(P + '{word} exists', function (file) {
  read(file);
});

Then(P + '{word} contains the text {string}', function (file, text) {
  assert.ok(read(file).includes(text), `${file} does not contain: ${text}`);
});

Then(P + '{word} does not contain the text {string}', function (file, text) {
  assert.ok(!read(file).includes(text), `${file} must not contain: ${text}`);
});

Then(P + '{word} contains the line {string}', function (file, text) {
  const ok = read(file).split('\n').some((l) => l.trim() === text);
  assert.ok(ok, `${file} has no line equal to: ${text}`);
});

Then(P + '{word} shows {string} inside a fenced block', function (file, text) {
  const ok = fences(read(file)).some((b) => b.includes(text));
  assert.ok(ok, `${file} has no fenced block containing: ${text}`);
});

Then(P + '{word} has no line over {int} characters', function (file, n) {
  const bad = read(file).split('\n').filter((l) => l.length > n);
  assert.strictEqual(bad.length, 0, `${file} has ${bad.length} lines over ${n} characters, first: ${bad[0]}`);
});

Then(P + '{word} has at least {int} fenced blocks', function (file, n) {
  const got = fences(read(file)).length;
  assert.ok(got >= n, `${file} has ${got} fenced blocks, expected at least ${n}`);
});

Then(P + 'docs contains exactly the files {string}', function (list) {
  const want = list.split(',').map((s) => s.trim()).sort();
  const got = fs.readdirSync(path.join(root, 'docs')).sort();
  assert.deepStrictEqual(got, want, `docs/ holds ${got.join(', ')}; expected ${want.join(', ')}`);
});

Then(P + 'docs&#47;testing-rules.md is unchanged', function () {
  const out = execFileSync('git', ['status', '--porcelain', '--', 'docs/testing-rules.md'], { cwd: root, encoding: 'utf8' });
  assert.strictEqual(out.trim(), '', `docs/testing-rules.md changed: ${out}`);
});

Then(P + 'every relative link in README.md and docs resolves to an existing file', function () {
  const files = ['README.md'];
  for (const f of fs.readdirSync(path.join(root, 'docs'))) if (f.endsWith('.md')) files.push('docs/' + f);
  const missing = [];
  for (const f of files) {
    const text = read(f);
    const re = /\]\(([^)\s]+)\)/g;
    let m;
    while ((m = re.exec(text))) {
      let target = m[1];
      if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('#')) continue;
      target = target.split('#')[0];
      if (!target) continue;
      if (!fs.existsSync(path.resolve(root, path.dirname(f), target))) missing.push(`${f} -> ${m[1]}`);
    }
  }
  assert.deepStrictEqual(missing, [], `broken relative links: ${missing.join('; ')}`);
});

Then(P + 'the working tree changes only documentation, spec additions, steps and tests', function () {
  const out = execFileSync('git', ['status', '--porcelain', '--untracked-files=all'], { cwd: root, encoding: 'utf8' });
  const bad = [];
  for (const l of out.split('\n').filter(Boolean)) {
    const code = l.slice(0, 2);
    const p = l.slice(3).split(' -> ').pop();
    if (p === 'README.md' || p.startsWith('docs/') || p.startsWith('.kogen/')) continue;
    if (p === 'packaging/package.sh') continue;
    if (p === 'features/steps/k-docs-concise-task-first__docs.js') continue;
    if (p.startsWith('spec/') && /^(\?\?|A |AM)/.test(code)) continue;
    bad.push(l);
  }
  assert.deepStrictEqual(bad, [], `unexpected changes: ${bad.join('; ')}`);
});
