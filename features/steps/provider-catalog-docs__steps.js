'use strict';
const { Given, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const GUIDE = 'docs/providers.md';
const LABEL = 'experimental: Build verified with Claude Review; Shape and Review not qualified';
const ROLES = ['Shape', 'Build', 'Review'];
const COLUMNS = ['Provider', 'Account or key needed', 'Roles verified', 'Built in or custom endpoint', 'Setup'];

function read(rel) {
  assert.ok(fs.existsSync(rel), `${rel} does not exist`);
  return fs.readFileSync(rel, 'utf8');
}

function cells(line) {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

// Rows of the comparison table: { header: [...], rows: { name: [cells] } }.
function table(page) {
  const lines = page.split('\n').filter((l) => l.trim().startsWith('|') && l.trim().endsWith('|'));
  const out = { header: null, rows: {} };
  for (const line of lines) {
    const c = cells(line);
    const name = c[0].replace(/`/g, '');
    if (name === 'Provider') { out.header = c; continue; }
    if (/^[-: ]+$/.test(name)) continue;
    out.rows[name] = c;
  }
  return out;
}

// Returns a problem description, or null when every role is "not qualified" or "verified" with an
// existing record that names the provider and the role.
function roleProblem(provider, cell) {
  const seen = new Set();
  for (const entry of cell.split(';')) {
    const m = entry.trim().match(/^(Shape|Build|Review): (.+)$/);
    if (!m) return `${provider}: roles entry '${entry.trim()}' is not 'Role: status'`;
    const [, role, status] = m;
    seen.add(role);
    if (status === 'not qualified') continue;
    if (!status.startsWith('verified')) return `${provider} ${role}: status '${status}' is neither not qualified nor verified with a record`;
    const paths = [...status.matchAll(/`([^`]+)`/g)].map((x) => x[1]);
    if (paths.length === 0) return `${provider} ${role} is verified without a qualification record path`;
    for (const p of paths) {
      if (!fs.existsSync(p) || !fs.statSync(p).isFile()) return `${provider} ${role} is verified by ${p}, which does not exist`;
      const text = fs.readFileSync(p, 'utf8').toLowerCase();
      if (!text.includes(provider) || !text.includes(role.toLowerCase())) return `${provider} ${role} cites ${p}, which does not name that provider and role`;
    }
  }
  for (const role of ROLES) if (!seen.has(role)) return `${provider} has no ${role} entry`;
  return null;
}

function tableProblem(text) {
  const t = table(text);
  const names = Object.keys(t.rows);
  if (names.length === 0) return 'no table rows';
  for (const name of names) {
    if (t.rows[name].length !== 5) return `row ${name} has ${t.rows[name].length} cells, want 5`;
    const problem = roleProblem(name, t.rows[name][2]);
    if (problem) return problem;
  }
  return null;
}

function accepted() {
  const source = read('cli/main.go');
  const m = source.match(/unknown provider '%s' \(supported: ([a-z, -]+)\)/);
  assert.ok(m, 'cli/main.go has no unknown-provider message listing the accepted names');
  return m[1].split(',').map((s) => s.trim());
}

function qwen() {
  const page = read(GUIDE);
  const i = page.indexOf('### QwenCloud');
  assert.ok(i >= 0, `${GUIDE} has no QwenCloud section`);
  const start = page.indexOf('\n', i) + 1;
  const next = page.slice(start).search(/^#{1,3} /m);
  return page.slice(i, next < 0 ? undefined : start + next);
}

function slug(heading) {
  return heading.toLowerCase().replace(/[^a-z0-9 -]/g, '').replace(/ /g, '-');
}

function headings(text) {
  return text.split('\n').filter((l) => /^#{1,6} /.test(l)).map((l) => slug(l.replace(/^#+ /, '')));
}

function linksTo(file, target) {
  const dir = path.dirname(file);
  return [...read(file).matchAll(/\]\(([^)\s]+)\)/g)].some((m) => {
    const t = m[1].split('#')[0];
    return t !== '' && path.normalize(path.join(dir, t)) === path.normalize(target);
  });
}

let acceptedNames;

Given('provider-catalog-docs: the accepted provider names are read from the CLI source', function () {
  acceptedNames = accepted();
  assert.ok(acceptedNames.length > 0, 'no accepted provider names');
});

Then('provider-catalog-docs: the accepted names are these', function (dataTable) {
  assert.deepEqual(acceptedNames, dataTable.raw().map((r) => r[0]));
});

Then('provider-catalog-docs: the Providers guide table has the five required columns', function () {
  assert.deepEqual(table(read(GUIDE)).header, COLUMNS);
});

Then('provider-catalog-docs: the Providers guide table has a row for every accepted name', function () {
  const rows = table(read(GUIDE)).rows;
  for (const name of acceptedNames) assert.ok(rows[name], `the comparison table of ${GUIDE} has no row for provider ${name}`);
});

Then('provider-catalog-docs: every row links to its setup instructions', function () {
  const rows = table(read(GUIDE)).rows;
  const own = headings(read(GUIDE));
  const started = headings(read('docs/getting-started.md'));
  for (const name of acceptedNames) {
    const row = rows[name];
    assert.ok(row, `no row for ${name}`);
    const m = row[4] && row[4].match(/\]\(([^)\s]+)\)/);
    assert.ok(m, `the setup cell of ${name} has no link`);
    const [file, anchor] = m[1].split('#');
    if (file === '') assert.ok(own.includes(anchor), `${name}: no section #${anchor} on the page`);
    else {
      assert.equal(file, 'getting-started.md', `${name}: setup link goes to ${file}`);
      assert.ok(anchor === undefined || started.includes(anchor), `${name}: getting-started.md has no section #${anchor}`);
    }
  }
});

Then('provider-catalog-docs: every role marked verified in the Providers guide names an existing record', function () {
  assert.equal(tableProblem(read(GUIDE)), null);
});

Then('provider-catalog-docs: the Providers guide marks exactly these roles verified', function (dataTable) {
  const expected = dataTable.raw().map((r) => `${r[0]} ${r[1]}`).sort();
  const got = [];
  for (const [name, row] of Object.entries(table(read(GUIDE)).rows)) {
    for (const entry of row[2].split(';')) {
      const m = entry.trim().match(/^(Shape|Build|Review): verified/);
      if (m) got.push(`${name} ${m[1]}`);
    }
  }
  assert.deepEqual(got.sort(), expected);
});

Then('provider-catalog-docs: the QwenCloud section does not call Shape or Review verified', function () {
  const rest = qwen().split(LABEL).join('');
  assert.ok(!/verified/i.test(rest), 'the QwenCloud section uses the word verified outside its label');
});

Then('provider-catalog-docs: the role check rejects this table', function (docString) {
  assert.notEqual(tableProblem(docString), null, 'the role check accepted a verified role with a missing record');
});

Then('provider-catalog-docs: the role check accepts this table', function (docString) {
  assert.equal(tableProblem(docString), null);
});

Then('provider-catalog-docs: the QwenCloud section carries the exact label', function () {
  assert.ok(qwen().includes(LABEL), `the QwenCloud section lacks the label: ${LABEL}`);
});

Then('provider-catalog-docs: the Providers guide contains the text {string}', function (text) {
  assert.ok(read(GUIDE).includes(text), `${GUIDE} does not contain: ${text}`);
});

Then('provider-catalog-docs: the QwenCloud section names Token Plan terms and pay-as-you-go in one sentence', function () {
  const sentences = qwen().replace(/\s+/g, ' ').split(/(?<=\.) /);
  assert.ok(sentences.some((s) => s.includes('Token Plan terms') && s.includes('pay-as-you-go')), 'no sentence names Token Plan terms and pay-as-you-go');
});

Then('provider-catalog-docs: the QwenCloud section says the Chat Completions route does not yet stream and names the 45 second first-byte watchdog', function () {
  const text = qwen().replace(/\s+/g, ' ');
  assert.ok(text.includes('does not yet stream'), 'no statement that the route does not yet stream');
  assert.ok(text.includes('45 seconds') && text.includes('first-byte watchdog'), 'no 45 seconds first-byte watchdog statement');
});

Then('provider-catalog-docs: the Providers guide does not mention messages-compatible', function () {
  assert.ok(!read(GUIDE).toLowerCase().includes('messages-compatible'));
});

Then('provider-catalog-docs: the Providers guide uses no emoji and no unqualified works or supported claim', function () {
  const page = read(GUIDE);
  assert.ok(!/\p{Extended_Pictographic}/u.test(page), 'the page contains an emoji');
  const claim = page.match(/\b(works|supported)\b/i);
  assert.ok(!claim, `the page makes an unqualified claim: ${claim && claim[0]}`);
});

Then('provider-catalog-docs: {word} links to the Providers guide', function (file) {
  assert.ok(linksTo(file, GUIDE), `${file} has no link to ${GUIDE}`);
});

Then('provider-catalog-docs: docs\\/configuration.md names claude-code and QwenCloud', function () {
  const text = read('docs/configuration.md');
  assert.ok(text.includes('claude-code') && text.includes('QwenCloud'));
});

Then('provider-catalog-docs: the packaging script copies the Providers guide into the archive docs folder', function () {
  const ok = read('packaging/package.sh').split('\n').some((l) => /^\s*mkdir\b/.test(l) && l.includes('cp ') && l.includes('docs/providers.md') && l.includes('"$work/docs/"'));
  assert.ok(ok, 'no line of packaging/package.sh copies docs/providers.md to "$work/docs/"');
});

Then('provider-catalog-docs: a Go test in the cli package reads the Providers guide and the CLI source', function () {
  const hits = fs.readdirSync('cli').filter((f) => f.endsWith('_test.go')).filter((f) => {
    const text = fs.readFileSync(path.join('cli', f), 'utf8');
    return text.includes('providers.md') && text.includes('main.go');
  });
  assert.ok(hits.length >= 1, 'no cli/*_test.go file reads docs/providers.md and main.go');
});
