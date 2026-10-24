const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

const H = require('./go_driver_support.js');

// Reuse the existing installed-release fixture and recording fake provider.
// Capture the request, never scrape the source heredoc or simulate model judgment.
const contentText = x => typeof x.content === 'string' ? x.content : Array.isArray(x.content) ? x.content.map(b => b.text || '').join('') : '';
async function capture() {
  const suite = await H.setupSuite(); let c;
  try {
    const script = [H.fn('write_file', { path: 'app.txt', content: 'verified edit\n' }), H.fn('finish', { summary: 'The fixture edit is ready.' }), H.fn('submit_review', { verdict: 'approve', findings: [] })];
    c = await H.project(suite, script);
    const { out: output, code: status } = await H.runKogen(c, ['intent', 'build', 'fixture']);
    const reviews = c.server.reviewRequests();
    if (reviews.length === 0) throw new Error(`no actual reviewer request: ${output}`);
    const request = reviews[0].json;
    // The policy is the request's instructions or, for a model with prompt caching, its developer message.
    const instructions = request.instructions || request.input.filter(i => i.role === 'developer').map(contentText).join('\n');
    const material = request.input.filter(i => i.role !== 'developer').map(contentText).join('\n');
    const committed = await H.gitBang(c, ['show', 'HEAD:app.txt']);
    return { instructions, material, 'build status': status, 'reviewer requests': reviews.length, 'committed builder contents': committed.replace(/\n+$/, ''), 'reviewer response tool': 'submit_review' };
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

const normalize = text => text.replace(/\s+/g, ' ').trim().toLowerCase();
When('I capture the installed reviewer style policy', { timeout: 250000 }, async function () {
  this.stylePolicy = await capture();
  const material = this.stylePolicy.material;
  const marker = '# Testing rules (docs/testing-rules.md)';
  const start = material.indexOf(marker);
  const end = material.indexOf('# Check results of the final pass', start);
  assert.ok(start >= 0 && end > start, 'installed testing rules missing from reviewer request');
  const installedTesting = material.slice(start + marker.length, end);
  const section = installedTesting.match(/## The reviewer\s+([\s\S]*?)(?=\n## |$)/);
  assert.ok(section, 'reviewer section missing from installed testing rules');
  const sourceTesting = fs.readFileSync(path.join(ROOT, 'docs/testing-rules.md'), 'utf8');
  assert.ok(installedTesting.includes(sourceTesting.trim()), 'installed testing rules differ from current source');
  const spec = fs.readFileSync(path.join(ROOT, 'spec/prose/06-reviewing.md'), 'utf8');
  const rev4 = spec.match(/\*\*REV-4[^\n]*[\s\S]*?(?=\n\*\*REV-5)/);
  assert.ok(rev4, 'maintained REV-4 missing');
  this.styleOwners = { instructions: this.stylePolicy.instructions, testing: section[1], spec: rev4[0] };
});

function assertContains(text, table, column) {
  const missing = table.hashes().map(row => row[column]).filter(value => !normalize(text).includes(normalize(value)));
  assert.deepEqual(missing, [], 'missing emitted policy text');
}
Then('the emitted reviewer instructions contain these paragraphs:', function (table) {
  assertContains(this.stylePolicy.instructions, table, 'paragraph');
});
Then('the emitted reviewer instructions retain these safeguards:', function (table) {
  assertContains(this.stylePolicy.instructions, table, 'text');
});
Then('none of these reviewer policy owners retain these permissions:', function (table) {
  const failures = table.hashes().filter(row => {
    assert.ok(Object.hasOwn(this.styleOwners, row.owner), row.owner);
    return normalize(this.styleOwners[row.owner]).includes(normalize(row.forbidden));
  });
  assert.deepEqual(failures, [], 'obsolete opportunistic cleanup permission');
});
Then('the maintained reviewer sections cover these policy terms:', function (table) {
  const missing = table.hashes().filter(row => {
    assert.ok(Object.hasOwn(this.styleOwners, row.owner), row.owner);
    return !new RegExp(row.pattern, 'i').test(normalize(this.styleOwners[row.owner]));
  });
  assert.deepEqual(missing, [], 'maintained policy guidance missing');
});
Then('the style-policy fixture observations are:', function (table) {
  for (const row of table.hashes()) {
    assert.ok(Object.hasOwn(this.stylePolicy, row.observation), row.observation);
    assert.equal(String(this.stylePolicy[row.observation]), row.expected, row.observation);
  }
});
