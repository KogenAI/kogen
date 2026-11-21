const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { Then } = require('@cucumber/cucumber');

const PREFIX = 'spec-baseline-guard-restores-first-edit: ';
const FEATURE = 'spec/features/05-verifying.feature';
const SERVERS = 'test/acceptance/support/fake-servers.js';
const SUPPORT = 'test/acceptance/support';

function blocks(text) {
  const lines = text.split('\n');
  const starts = [];
  lines.forEach((line, i) => {
    if (!/^\s*Scenario( Outline)?:/.test(line)) return;
    let s = i;
    while (s > 0 && /^\s*@/.test(lines[s - 1])) s--;
    starts.push({ s, i });
  });
  const out = starts.map((start, k) => {
    const end = k + 1 < starts.length ? starts[k + 1].s : lines.length;
    const own = lines.slice(start.s, end);
    while (own.length && own[own.length - 1].trim() === '') own.pop();
    const tags = own.slice(0, start.i - start.s).join(' ').split(/\s+/).filter(Boolean);
    const outline = /^\s*Scenario Outline:/.test(lines[start.i]);
    const name = lines[start.i].replace(/^\s*Scenario( Outline)?:\s*/, '').trim();
    const steps = own.filter(l => /^\s*(Given|When|Then|And|But) /.test(l)).map(l => l.trim());
    const at = own.findIndex(l => /^\s*Examples:/.test(l));
    const rows = at < 0 ? [] : own.slice(at + 1).filter(l => l.trim().startsWith('|'))
      .map(l => l.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim()));
    const column = rows.length ? rows[0].indexOf('path') : -1;
    const paths = column < 0 ? [] : rows.slice(1).map(r => r[column]);
    return { text: own.join('\n'), tags, outline, name, steps, paths };
  });
  const first = starts.length ? starts[0].s : lines.length;
  return { preamble: lines.slice(0, first).join('\n'), list: out };
}

const current = () => blocks(fs.readFileSync(FEATURE, 'utf8'));
const head = () => blocks(execFileSync('git', ['show', `HEAD:${FEATURE}`], { encoding: 'utf8', maxBuffer: 1 << 24 }));

Then(PREFIX + 'the spec has exactly one outline containing {string} tagged {string} with the example paths {string}', function (marker, tags, paths) {
  const found = current().list.filter(b => b.outline && b.text.includes(marker));
  assert.equal(found.length, 1, `${FEATURE} has ${found.length} scenario outlines containing ${JSON.stringify(marker)}, expected exactly one`);
  this.outline = found[0];
  assert.deepEqual(this.outline.tags, tags.split(/\s+/), `tags of outline ${JSON.stringify(this.outline.name)}`);
  assert.deepEqual(this.outline.paths, paths.split(','), `example paths of outline ${JSON.stringify(this.outline.name)}`);
});

// The script name is whatever the outline plays; <script> stands for it in the expected steps.
Then(PREFIX + 'that outline has the steps:', function (docString) {
  assert.ok(this.outline, 'no outline was selected by an earlier step');
  const expected = docString.split('\n').map(l => l.trim()).filter(Boolean);
  const actual = this.outline.steps.map(s => s.replace(/plays script "[^"]+"/, 'plays script "<script>"'));
  assert.deepEqual(actual, expected, `steps of outline ${JSON.stringify(this.outline.name)}`);
});

Then(PREFIX + 'that outline plays the script {string}', function (script) {
  assert.ok(this.outline, 'no outline was selected by an earlier step');
  assert.ok(this.outline.steps.some(s => s.includes(`plays script "${script}" with command "<command>"`)), `outline ${JSON.stringify(this.outline.name)} does not play script ${script}`);
});

// Only what the request states: the outline plays a script other than the existing one, the fake server knows
// that script somewhere under test/acceptance/support, and the existing script keeps its code.
Then(PREFIX + 'that outline plays a script that the fake ChatGPT server knows, other than the unchanged script {string}', function (existing) {
  assert.ok(this.outline, 'no outline was selected by an earlier step');
  const used = (this.outline.steps.join('\n').match(/plays script "([^"]+)"/) || [])[1];
  assert.ok(used && used !== existing, `the outline plays ${used}, which must differ from ${existing}`);
  const files = fs.readdirSync(SUPPORT).filter(f => f.endsWith('.js')).map(f => path.join(SUPPORT, f));
  assert.ok(files.some(f => fs.readFileSync(f, 'utf8').includes(`'${used}'`)), `no file under ${SUPPORT} names the script ${used}`);
  const own = text => { const m = text.match(new RegExp(`    if \\(name === '${existing}'\\) \\{[\\s\\S]*?\\n    \\}\\n`)); return m ? m[0] : null; };
  const was = execFileSync('git', ['show', `HEAD:${SERVERS}`], { encoding: 'utf8', maxBuffer: 1 << 24 });
  const oldBlock = own(was);
  assert.ok(oldBlock, `HEAD ${SERVERS} lacks the ${existing} script`);
  assert.equal(own(fs.readFileSync(SERVERS, 'utf8')), oldBlock, `the ${existing} script changed`);
});

Then(PREFIX + 'the spec has no scenario named {string}', function (name) {
  const found = current().list.filter(b => b.name === name);
  assert.equal(found.length, 0, `${FEATURE} still has a scenario named ${JSON.stringify(name)}`);
});

// HEAD may hold the old outline (before the Build) or the new outlines (in a tree whose HEAD already
// includes the candidate spec), so the same filter drops the replaced and the added outlines from both lists.
Then(PREFIX + 'every other scenario of the spec file is unchanged from HEAD', function () {
  const now = current();
  const was = head();
  const replaced = new Set(['Weakening the baseline is refused or stops the Build at once']);
  const marked = b => b.outline && (b.text.includes('acceptance files cannot be edited') || b.text.includes('candidate/baseline_changed: the Build changed acceptance files: <path>; nothing was committed'));
  const dropped = b => replaced.has(b.name) || marked(b);
  assert.equal(now.preamble, was.preamble, 'the text before the first scenario changed');
  assert.deepEqual(now.list.filter(b => !dropped(b)).map(b => b.text), was.list.filter(b => !dropped(b)).map(b => b.text));
});
