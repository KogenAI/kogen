'use strict';
// Release check: every file that the archive's README links, directly or through another shipped Markdown file,
// must be in the archive. Usage: node packaging/check-archive.cjs <archive folder | .tar.gz>
// Exit 0 when all references are satisfied, 1 when one is missing, 2 on a usage error.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function usage(message) {
  process.stderr.write(`check-archive: ${message}\nusage: node packaging/check-archive.cjs <archive folder | archive.tar.gz>\n`);
  process.exit(2);
}

// The relative references of a Markdown file: [{ target, base }] where base is the folder they resolve against.
function references(text, fromDir) {
  const found = [];
  let fence = null;
  for (const line of text.split('\n')) {
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
      continue;
    }
    if (fence) continue;
    for (const m of line.matchAll(/\]\(\s*<?([^)\s>]+)>?(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)/g)) {
      const target = m[1].replace(/[#?].*$/, '');
      if (!target || /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(m[1])) continue;
      let decoded = target;
      try { decoded = decodeURI(target); } catch { /* keep the raw target */ }
      found.push({ target: decoded, base: fromDir });
    }
    for (const m of line.matchAll(/`(docs\/[A-Za-z0-9_.\/-]+\.(?:md|yaml))`/g)) {
      found.push({ target: m[1], base: '' });
    }
  }
  return found;
}

function check(root) {
  const realRoot = fs.realpathSync(root);
  const isFile = rel => {
    if (rel.startsWith('../') || rel === '..' || path.isAbsolute(rel)) return false;
    try {
      const full = path.join(realRoot, rel);
      if (!fs.lstatSync(full).isFile()) return false;
      return (fs.realpathSync(path.dirname(full)) + path.sep).startsWith(realRoot + path.sep);
    } catch { return false; }
  };
  const problems = [];
  const seenPairs = new Set();
  const referenced = new Set();
  const visited = new Set(['README.md']);
  if (!isFile('README.md')) return { problems: ['  missing README.md (linked from README.md)'], count: 0 };
  const queue = ['README.md'];
  while (queue.length) {
    const file = queue.shift();
    const fromDir = path.posix.dirname(file) === '.' ? '' : path.posix.dirname(file);
    const text = fs.readFileSync(path.join(realRoot, file), 'utf8');
    for (const { target, base } of references(text, fromDir)) {
      const rel = path.posix.normalize(path.posix.join(base, target));
      const pair = `${file}\0${rel}`;
      if (seenPairs.has(pair)) continue;
      seenPairs.add(pair);
      if (!isFile(rel)) { problems.push(`  missing ${rel} (linked from ${file})`); continue; }
      if (rel !== 'README.md') referenced.add(rel);
      if (rel.endsWith('.md') && !visited.has(rel)) { visited.add(rel); queue.push(rel); }
    }
  }
  return { problems, count: referenced.size };
}

const args = process.argv.slice(2);
if (args.length !== 1) usage('expected exactly one path');
const input = path.resolve(args[0]);
let stat;
try { stat = fs.statSync(input); } catch { usage(`cannot read ${args[0]}`); }

let tmp = null;
let root = input;
let code = 0;
try {
  if (stat.isFile()) {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'check-archive-'));
    const x = spawnSync('tar', ['-xzf', input, '-C', tmp], { encoding: 'utf8' });
    if (x.status !== 0) usage(`cannot extract ${args[0]}: ${(x.stderr || '').trim()}`);
    const entries = fs.readdirSync(tmp);
    if (entries.length !== 1 || !fs.statSync(path.join(tmp, entries[0])).isDirectory()) {
      process.stderr.write(`archive link check failed:\n  ${args[0]} must hold exactly one top-level folder\n`);
      code = 1;
    } else {
      root = path.join(tmp, entries[0]);
    }
  } else if (!stat.isDirectory()) {
    usage(`${args[0]} is neither a folder nor a .tar.gz file`);
  }
  if (code === 0) {
    const { problems, count } = check(root);
    if (problems.length) {
      process.stderr.write(`archive link check failed:\n${problems.join('\n')}\n`);
      code = 1;
    } else {
      process.stdout.write(`archive links ok: ${count} linked files present\n`);
    }
  }
} finally {
  if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
}
process.exit(code);
