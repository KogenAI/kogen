const { Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const config = 'docs/configuration.md';
const guide = 'docs/getting-started.md';
const read = file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n').replace(/<!--[\s\S]*?-->/g, '');
const normalize = text => text.toLowerCase().replace(/\s+/g, ' ');
const paragraphs = text => text.split(/\n\s*\n/);

function ordered(text, table) {
  let at = 0;
  const body = normalize(text);
  for (const [value] of table.raw()) {
    const needle = normalize(value);
    at = body.indexOf(needle, at);
    if (at === -1) return false;
    at += needle.length;
  }
  return true;
}

function sections(text) {
  const prose = text.replace(/^ {0,3}(`{3,}|~{3,})[^\n]*\n[\s\S]*?^ {0,3}\1[^\n]*/gm, '');
  const headings = [...prose.matchAll(/^(#{1,6}) +([^\n]+)$/gm)];
  return headings.map((m, i) => {
    const end = headings.slice(i + 1).find(n => n[1].length <= m[1].length);
    const anchor = m[2].toLowerCase().replace(/[^\w\s-]/g, '').replace(/\s+/g, '-');
    return { title: m[2], anchor, body: prose.slice(m.index + m[0].length, end?.index ?? prose.length) };
  });
}

function linkedSections(text, from, destination) {
  return [...text.replace(/`[^`\n]*`/g, '').matchAll(/\[[^\]\n]+\]\(([^\s)#]+)#([^\s)]+)\)/g)].flatMap(([, file, anchor]) => {
    if (path.posix.normalize(path.posix.join(path.posix.dirname(from), file)) !== destination) return [];
    return sections(read(destination)).filter(section => section.anchor === anchor);
  });
}

Then('docs-protected-dependency-changes: {string} guidance in Getting Started links to the dependency handoff in Configuration', function (refusal, table) {
  const shape = sections(read(guide)).find(s => /^\d+\. Shape$/.test(s.title));
  assert.ok(shape, 'Getting Started: Shape section is missing');
  const guidance = paragraphs(shape.body).filter(p => p.includes('`' + refusal + '`'));
  const targets = linkedSections(guidance.join('\n\n'), guide, config);
  assert.ok(targets.some(s => ordered(s.body, table)), 'Shape guidance must link to the Configuration heading with the outside-Build handoff');
});

Then('docs-protected-dependency-changes: {string} distinguishes Shape refusal from recovery and links to {string}', function (file, command) {
  const distinction = paragraphs(read(file)).find(p => /Shape refusal starts no Build/i.test(p) && /does not need recovery/i.test(p));
  assert.ok(distinction, `${file}: explain that a Shape refusal starts no Build and needs no recovery`);
  assert.ok(linkedSections(distinction, file, guide).some(s => s.body.includes('`' + command + '`')),
    `${file}: link to the existing protected-Build recovery instructions`);
});

function checkBlocks(file, table, blocks) {
  const subject = table.raw()[0][0];
  assert.ok(blocks.some(block => ordered(block, table)), `${file}: missing or out-of-order guidance for ${subject}`);
}

Then('docs-protected-dependency-changes: {string} explains ordinary dependency work', function (file, table) {
  checkBlocks(file, table, paragraphs(read(file)));
});

Then('docs-protected-dependency-changes: {string} explains whole-file protection', function (file, table) {
  checkBlocks(file, table, paragraphs(read(file)));
});

Then('docs-protected-dependency-changes: {string} explains a mixed manifest', function (file, table) {
  checkBlocks(file, table, paragraphs(read(file)));
});

Then('docs-protected-dependency-changes: {string} reviews a new required check before enabling it', function (file, table) {
  checkBlocks(file, table, paragraphs(read(file)));
});

Then('docs-protected-dependency-changes: {string} gives the baseline handoff in order', function (file, table) {
  assert.ok(ordered(read(file), table), `${file}: review, fresh-checkout verification, commit and re-Shape must be documented in order`);
});
