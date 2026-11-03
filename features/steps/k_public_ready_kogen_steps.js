'use strict';
const assert = require('node:assert/strict');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Given, When, Then } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');

// The host and personal names are ROT13-encoded so that this file does not itself carry what it looks for.
const rot13 = s => s.replace(/[a-z]/gi, c => {
  const base = c <= 'Z' ? 65 : 97;
  return String.fromCharCode(base + (c.charCodeAt(0) - base + 13) % 26);
});
const HOSTS = ['xbtra-ehaare', 'xbtra-znpobbx-ehaare', 'xbtra-yvahk-znpobbx', 'xbtra-orapu-rh2', 'rh2'].map(rot13);
const NAMES = ['nyzve', 'fnenw'].map(rot13);
const KINDS = [
  ['home path', /(?<![A-Za-z0-9_.$}~-])\/(?:Users|home)\/[^/<\s]+\//],
  ['runner path', /\.n[o]index\b|\/var\/folders\/(?!\.\.\.|<)/],
  ['host name', new RegExp(`(?<![A-Za-z0-9_-])(?:${HOSTS.join('|')})(?![A-Za-z0-9_-])|MacBook-Pro\\.local`)],
  ['personal name', new RegExp(NAMES.join('|'), 'i')],
];

// Tracked files plus new files Git does not ignore, as the Build's candidate tree holds them.
function treeFiles() {
  const out = cp.execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: ROOT, maxBuffer: 1 << 28 });
  return [...new Set(out.toString('utf8').split('\0').filter(Boolean))].sort();
}

function leftOut(world, rel) {
  return world.publicReadyLeftOut.some(p => (p.endsWith('/') ? rel.startsWith(p) : rel === p));
}

function readText(rel) {
  let bytes;
  try { bytes = fs.readFileSync(path.join(ROOT, rel)); } catch { return null; }
  if (bytes.subarray(0, 8192).includes(0)) return null;
  return bytes.toString('utf8');
}

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

function count(text, needle) {
  let n = 0;
  for (let i = text.indexOf(needle); i >= 0; i = text.indexOf(needle, i + needle.length)) n++;
  return n;
}

Given('the public-ready scan leaves out these paths, where a trailing slash marks a folder:', function (table) {
  this.publicReadyLeftOut = table.raw().map(r => r[0]);
});

When('the public-ready scan reads every text file in the tree', function () {
  this.publicReadyScanned = [];
  this.publicReadyHits = [];
  for (const rel of treeFiles()) {
    if (leftOut(this, rel)) continue;
    const text = readText(rel);
    if (text === null) continue;
    this.publicReadyScanned.push(rel);
    text.split('\n').forEach((line, i) => {
      for (const [kind, re] of KINDS) {
        const m = re.exec(line);
        if (m) this.publicReadyHits.push(`${rel}:${i + 1} ${kind}: ${line.slice(Math.max(0, m.index - 30), m.index + 50)}`);
      }
    });
  }
});

Then('the public-ready scan read at least {int} files, including:', function (min, table) {
  const scanned = this.publicReadyScanned;
  assert.ok(scanned.length >= min, `the scan read ${scanned.length} text files, expected at least ${min}`);
  const missing = table.raw().map(r => r[0]).filter(rel => !scanned.includes(rel));
  assert.deepEqual(missing, [], `the scan did not read: ${missing.join(', ')}`);
});

Then('the public-ready scan finds no home path, runner path, host name or personal name', function () {
  const hits = this.publicReadyHits;
  assert.equal(hits.length, 0, `${hits.length} hits remain:\n${hits.join('\n')}`);
});

Then('the public-ready file {string} contains:', function (rel, text) {
  assert.ok(read(rel).includes(text), `${rel} does not contain:\n${text}`);
});

Then('the public-ready file {string} contains {string} exactly once', function (rel, text) {
  const n = count(read(rel), text);
  assert.equal(n, 1, `${rel} contains ${JSON.stringify(text)} ${n} times, expected exactly once`);
});

Then('the public-ready file {string} contains none of these:', function (rel, table) {
  const body = read(rel);
  const found = table.raw().map(r => r[0]).filter(s => body.includes(s));
  assert.deepEqual(found, [], `${rel} still contains: ${found.map(s => JSON.stringify(s)).join(', ')}`);
});

Then('the public-ready README introduction, before its first {string} heading, contains:', function (marker, text) {
  const body = read('README.md');
  const at = body.search(new RegExp(`^${marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`, 'm'));
  const intro = at < 0 ? body : body.slice(0, at);
  assert.ok(intro.includes(text), `the README introduction (before the first "${marker}" heading) does not contain:\n${text}\n--- introduction ---\n${intro}`);
});

Then('the public-ready file {string} has SHA-256 {string}', function (rel, want) {
  const got = crypto.createHash('sha256').update(fs.readFileSync(path.join(ROOT, rel))).digest('hex');
  assert.equal(got, want, `${rel} changed: SHA-256 ${got}, expected ${want}`);
});

Then('no file named {string}, {string} or {string} is in the tree, in any folder or letter case', function (a, b, c) {
  const names = [a, b, c].map(s => s.toLowerCase());
  const found = treeFiles().filter(rel => names.includes(path.posix.basename(rel).toLowerCase()));
  assert.deepEqual(found, [], `the tree holds: ${found.join(', ')}`);
});

function markdownFiles(world) {
  return treeFiles().filter(rel => rel.toLowerCase().endsWith('.md') && !leftOut(world, rel) && fs.existsSync(path.join(ROOT, rel)));
}

function linkTargets(text) {
  const prose = text.replace(/^ {0,3}(```|~~~)[\s\S]*?^ {0,3}\1/gm, '').replace(/`[^`\n]*`/g, '');
  const targets = [];
  for (const m of prose.matchAll(/!?\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g)) targets.push(m[1]);
  for (const m of prose.matchAll(/^ {0,3}\[[^\]\n]+\]:\s*<?([^\s>]+)>?/gm)) targets.push(m[1]);
  return targets;
}

function linkProblem(rel, target) {
  if (target.startsWith('#')) return null;
  if (/^[a-z][a-z0-9+.-]*:/i.test(target)) {
    if (target === 'mailto:contact@kogen.dev') return null;
    let url;
    try { url = new URL(target); } catch { return 'is not a valid URL'; }
    if (url.protocol !== 'https:') return 'is not a public https link';
    const host = url.hostname.toLowerCase();
    if (host.includes('kogen') && host !== 'kogen.dev') return 'is a Kogen-wide link outside https://kogen.dev';
    if (host === 'github.com' && /^\/kogenai\//i.test(url.pathname) && !/^\/KogenAI\/kogen(\/|$)/.test(url.pathname)) return 'is a Kogen-wide link outside https://github.com/KogenAI/kogen';
    return null;
  }
  let file = target.split('#')[0].split('?')[0];
  try { file = decodeURIComponent(file); } catch { return 'is not a valid path'; }
  const resolved = path.resolve(file.startsWith('/') ? ROOT : path.join(ROOT, path.dirname(rel)), file.replace(/^\/+/, ''));
  if (resolved !== ROOT && !resolved.startsWith(ROOT + path.sep)) return 'points outside the repository';
  if (!fs.existsSync(resolved)) return 'names nothing in the repository';
  return null;
}

Then('every Markdown link in the tree outside the left-out paths resolves publicly', function () {
  const problems = [];
  let links = 0;
  for (const rel of markdownFiles(this)) {
    for (const target of linkTargets(read(rel))) {
      links++;
      const problem = linkProblem(rel, target);
      if (problem) problems.push(`${rel}: ${target} ${problem}`);
    }
  }
  assert.ok(links > 0, 'the link check found no Markdown links at all');
  assert.deepEqual(problems, [], `links that do not resolve publicly:\n${problems.join('\n')}`);
});

Then('no Markdown file outside the left-out paths, {string} and {string} mentions any of these private workspace locations:', function (recordsA, recordsB, table) {
  const needles = table.raw().map(r => r[0]);
  const found = [];
  for (const rel of markdownFiles(this)) {
    if (rel.startsWith(recordsA) || rel.startsWith(recordsB)) continue;
    read(rel).split('\n').forEach((line, i) => {
      for (const needle of needles) if (line.includes(needle)) found.push(`${rel}:${i + 1}: ${needle}`);
    });
  }
  assert.deepEqual(found, [], `private workspace locations remain:\n${found.join('\n')}`);
});
