'use strict';
// Reads README.md and the docs/ files its "More" list links, relative to the repository root.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Given, Then } = require('@cucumber/cucumber');

const root = path.resolve(__dirname, '../..');

// Splits Markdown into heading-delimited sections; lines inside ``` or ~~~ fences are never headings.
// A section's body is every line after its heading up to the next heading of any level,
// without leading and trailing blank lines.
function sections(text) {
  const lines = text.split('\n');
  const found = [];
  let current = null;
  let fence = null;
  for (const line of lines) {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (fence) {
      if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && line.trim() === marker[1]) fence = null;
    } else if (marker) {
      fence = marker[1];
    } else {
      const heading = line.match(/^(#{1,6})[ \t]+(.*?)[ \t]*$/);
      if (heading) {
        current = { level: heading[1].length, title: heading[2], lines: [] };
        found.push(current);
        continue;
      }
    }
    if (current) current.lines.push(line);
  }
  for (const s of found) {
    const body = s.lines.slice();
    while (body.length && body[0].trim() === '') body.shift();
    while (body.length && body[body.length - 1].trim() === '') body.pop();
    s.body = body.join('\n');
    s.sha256 = crypto.createHash('sha256').update(s.body, 'utf8').digest('hex');
    delete s.lines;
  }
  return found;
}

function readmeSection(world, title) {
  const matches = world.readmeLineupSections.filter((s) => s.title === title);
  assert.equal(matches.length, 1, `README.md must have exactly one heading "${title}"; it has ${matches.length}. Headings: ${world.readmeLineupSections.map((s) => '#'.repeat(s.level) + ' ' + s.title).join(' | ')}`);
  return matches[0];
}

function fencedBlocks(body) {
  const blocks = [];
  let open = null;
  for (const line of body.split('\n')) {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (open) {
      if (marker && marker[1][0] === open.fence[0] && marker[1].length >= open.fence.length && marker[2].trim() === '') {
        blocks.push(open);
        open = null;
      } else {
        open.lines.push(line);
      }
    } else if (marker) {
      open = { fence: marker[1], info: marker[2].trim(), lines: [] };
    }
  }
  return blocks;
}

function cells(row) {
  return row.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

Given('k-readme-lineup: the repository README', function () {
  this.readmeLineupText = fs.readFileSync(path.join(root, 'README.md'), 'utf8');
  this.readmeLineupSections = sections(this.readmeLineupText);
});

Then('k-readme-lineup: the README has fewer than {int} lines', function (limit) {
  const text = this.readmeLineupText;
  const count = text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
  assert.ok(count < limit, `README.md has ${count} lines; it must have fewer than ${limit}`);
});

Then('k-readme-lineup: the README headings are exactly:', function (doc) {
  const want = doc.split('\n').map((l) => l.trim()).filter((l) => l !== '');
  const got = this.readmeLineupSections.map((s) => '#'.repeat(s.level) + ' ' + s.title);
  assert.deepEqual(got, want, `README.md headings (outside code fences) differ.\nactual:\n${got.join('\n')}\nexpected:\n${want.join('\n')}`);
});

Then('k-readme-lineup: the README section {string} contains {string}', function (title, text) {
  const section = readmeSection(this, title);
  assert.ok(section.body.includes(text), `README.md section "${title}" does not contain: ${text}`);
});

Then('k-readme-lineup: the README section {string} has exactly one mermaid block:', function (title, doc) {
  const section = readmeSection(this, title);
  const all = fencedBlocks(this.readmeLineupText).filter((b) => b.info === 'mermaid');
  const here = fencedBlocks(section.body).filter((b) => b.info === 'mermaid');
  assert.equal(all.length, 1, `README.md must have exactly one fenced \`\`\`mermaid block; it has ${all.length}`);
  assert.equal(here.length, 1, `the \`\`\`mermaid block must be in README.md section "${title}"`);
  const norm = (lines) => lines.map((l) => l.trim()).filter((l) => l !== '');
  assert.deepEqual(norm(here[0].lines), norm(doc.split('\n')), `the mermaid diagram in README.md section "${title}" differs (lines compared without surrounding whitespace and blank lines)`);
});

Then('k-readme-lineup: the README section {string} has this table:', function (title, table) {
  const section = readmeSection(this, title);
  const rows = [];
  let outside = true;
  for (const line of section.body.split('\n')) {
    if (/^ {0,3}(`{3,}|~{3,})/.test(line)) outside = !outside;
    else if (outside && line.trim().startsWith('|')) rows.push(line);
  }
  assert.ok(rows.length >= 2, `README.md section "${title}" has no Markdown table`);
  assert.ok(cells(rows[1]).every((c) => /^:?-{3,}:?$/.test(c)), `the second table row in README.md section "${title}" is not a separator row: ${rows[1]}`);
  const got = [cells(rows[0]), ...rows.slice(2).map(cells)];
  assert.deepEqual(got, table.raw(), `the table in README.md section "${title}" differs`);
});

Then('k-readme-lineup: every one of these original README sections is in a docs file linked from the More list:', function (table) {
  const more = readmeSection(this, 'More');
  const targets = [];
  for (const line of more.body.split('\n')) {
    if (!/^\s*[-*+] /.test(line)) continue;
    for (const m of line.matchAll(/\]\(([^)\s]+)\)/g)) targets.push(m[1]);
  }
  const files = [...new Set(targets
    .map((t) => path.posix.normalize(t.split('#')[0]))
    .filter((t) => t.startsWith('docs/') && fs.statSync(path.join(root, t), { throwIfNoEntry: false })?.isFile()))];
  assert.ok(files.length > 0, `the README.md "More" list links no existing docs/ file; link targets: ${targets.join(', ') || '(none)'}`);
  const docs = files.map((file) => ({ file, sections: sections(fs.readFileSync(path.join(root, file), 'utf8')) }));
  const missing = [];
  for (const { heading, sha256 } of table.hashes()) {
    const found = docs.some((d) => d.sections.some((s) => s.title === heading && s.sha256 === sha256));
    if (!found) {
      const sameTitle = docs.flatMap((d) => d.sections.filter((s) => s.title === heading).map((s) => `${d.file} (body sha256 ${s.sha256})`));
      missing.push(`"${heading}" with body sha256 ${sha256}: ${sameTitle.length ? 'heading found with a different body in ' + sameTitle.join(', ') : 'no such heading'}`);
    }
  }
  assert.deepEqual(missing, [], `original README sections not found verbatim in the docs files linked from the "More" list (${files.join(', ')}):\n${missing.join('\n')}`);
});
