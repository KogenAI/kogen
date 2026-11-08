'use strict';
// Independent observer for release-archive-ships-getting-started: it builds the real archive with
// `sh packaging/package.sh`, inspects the shipped files and README, and drives packaging/check-archive.cjs on copies
// of the extracted archive. It never installs Kogen and never touches the caller's home.
const { When, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const MIN = 60000;
const tail = text => (text.length > 4000 ? '...' + text.slice(-4000) : text);

function run(command, args, { cwd, timeout }) {
  return new Promise(resolve => {
    const child = spawn(command, args, { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let out = '';
    child.stdout.on('data', d => { stdout += d; out += d; });
    child.stderr.on('data', d => { out += d; });
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout);
    child.on('error', error => { clearTimeout(timer); resolve({ code: -1, stdout, out: out + String(error) }); });
    child.on('close', (code, signal) => { clearTimeout(timer); resolve({ code: code === null ? `signal ${signal}` : code, stdout, out }); });
  });
}

function archivePath(stdout) {
  return stdout.trim().split('\n').findLast(line => line.startsWith('/') && line.endsWith('.tar.gz'));
}

// One real archive per run, shared by the scenarios that inspect it.
let packaged;
function archive() {
  packaged ??= (async () => {
    const r = await run('/bin/sh', ['packaging/package.sh', '--version', 'getting-started-links'], { cwd: ROOT, timeout: 25 * MIN });
    assert.equal(r.code, 0, `sh packaging/package.sh exited ${r.code}: ${tail(r.out)}`);
    const file = archivePath(r.stdout);
    assert.ok(file && fs.existsSync(file), `sh packaging/package.sh printed no archive path: ${tail(r.stdout)}`);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'archive-links-'));
    process.on('exit', () => {
      fs.rmSync(dir, { recursive: true, force: true });
      fs.rmSync(file, { force: true });
    });
    const x = spawnSync('tar', ['-xzf', file, '-C', dir], { encoding: 'utf8' });
    assert.equal(x.status, 0, `tar -xzf ${file} failed: ${x.stderr}`);
    const [name] = fs.readdirSync(dir);
    assert.ok(name, `archive ${file} is empty`);
    return { file, name, top: path.join(dir, name) };
  })();
  return packaged;
}

When('release-archive-ships-getting-started: I package the checkout with package.sh', { timeout: 30 * MIN }, async function () {
  this.pkg = await archive();
});

Then('release-archive-ships-getting-started: the archive holds these files', function (table) {
  const missing = table.hashes().map(row => row.path).filter(p => {
    try { return !fs.statSync(path.join(this.pkg.top, p)).isFile(); } catch { return true; }
  });
  assert.deepEqual(missing, [], `archive ${this.pkg.file} lacks these regular files: ${missing.join(', ')}`);
});

Then('release-archive-ships-getting-started: the archive file {string} equals the checkout file {string}', function (shipped, source) {
  const a = fs.readFileSync(path.join(this.pkg.top, shipped));
  const b = fs.readFileSync(path.join(ROOT, source));
  assert.equal(Buffer.compare(a, b), 0, `archive ${shipped} differs from checkout ${source}`);
});

function readme(pkg) {
  return fs.readFileSync(path.join(pkg.top, 'README.md'), 'utf8');
}

Then('release-archive-ships-getting-started: the archive README links {string}', function (target) {
  assert.ok(readme(this.pkg).includes(`](${target})`), `archive README.md has no link to ${target}`);
});

Then('release-archive-ships-getting-started: the archive README section {string} has exactly two lines containing', function (title, table) {
  const text = readme(this.pkg);
  const match = text.match(new RegExp(`^#{1,6} ${title}[ \\t]*\\n([\\s\\S]*?)(?=^#{1,6} |(?![\\s\\S]))`, 'm'));
  assert.ok(match, `archive README.md has no section titled "${title}"`);
  const lines = match[1].split('\n').map(l => l.trim()).filter(Boolean);
  assert.equal(lines.length, 2, `section "${title}" must hold exactly two non-blank lines, found ${lines.length}: ${JSON.stringify(lines)}`);
  for (const row of table.hashes()) {
    const line = lines[Number(row.line) - 1];
    assert.ok(line && line.includes(row.text), `line ${row.line} of section "${title}" must contain ${JSON.stringify(row.text)}: ${JSON.stringify(line)}`);
  }
});

Then('release-archive-ships-getting-started: the release check gives', { timeout: 10 * MIN }, async function (table) {
  const failures = [];
  for (const row of table.hashes()) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'archive-links-check-'));
    try {
      const copy = path.join(tmp, this.pkg.name);
      fs.cpSync(this.pkg.top, copy, { recursive: true, verbatimSymlinks: true });
      if (row.removed !== '-') {
        assert.ok(fs.existsSync(path.join(copy, row.removed)), `fixture: ${row.removed} is not in the archive copy`);
        fs.rmSync(path.join(copy, row.removed));
      }
      let target = copy;
      if (row.form === 'archive') {
        target = path.join(tmp, 'repacked.tar.gz');
        const t = spawnSync('tar', ['-C', tmp, '-czf', target, this.pkg.name], { encoding: 'utf8' });
        assert.equal(t.status, 0, `fixture: tar failed: ${t.stderr}`);
      } else {
        assert.equal(row.form, 'directory', `unknown form ${row.form}`);
      }
      const r = await run(process.execPath, ['packaging/check-archive.cjs', target], { cwd: ROOT, timeout: 5 * MIN });
      const label = `${row.form} without ${row.removed}`;
      if (String(r.code) !== row.exit) failures.push(`${label}: exit ${r.code}, expected ${row.exit}: ${tail(r.out)}`);
      else if (!r.out.includes(row.output)) failures.push(`${label}: output lacks ${JSON.stringify(row.output)}: ${tail(r.out)}`);
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  }
  assert.deepEqual(failures, [], `packaging/check-archive.cjs results differ:\n${failures.join('\n')}`);
});

When('release-archive-ships-getting-started: I package a checkout copy without {string}', { timeout: 30 * MIN }, async function (removed) {
  const copy = fs.mkdtempSync(path.join(os.tmpdir(), 'archive-links-copy-'));
  this.copyRoot = copy;
  process.on('exit', () => fs.rmSync(copy, { recursive: true, force: true }));
  const t = spawnSync('sh', ['-c', 'tar -C "$1" -cf - --exclude=node_modules --exclude=dist --exclude=cli/kogen LICENSE NOTICE cli packaging docs | tar -C "$2" -xf -', 'sh', ROOT, copy], { encoding: 'utf8' });
  assert.equal(t.status, 0, `fixture: copying the checkout failed: ${t.stderr}`);
  assert.ok(fs.existsSync(path.join(copy, removed)), `fixture: ${removed} is not in the checkout copy`);
  fs.rmSync(path.join(copy, removed));
  this.copyRun = await run('/bin/sh', ['packaging/package.sh', '--version', 'link-gate-check'], { cwd: copy, timeout: 25 * MIN });
});

Then('release-archive-ships-getting-started: packaging fails naming {string} and publishes no archive', function (line) {
  const r = this.copyRun;
  assert.notEqual(r.code, 0, `packaging a copy with a missing linked file must fail, but exited ${r.code}: ${tail(r.out)}`);
  assert.ok(r.out.includes(line), `package.sh output lacks ${JSON.stringify(line)}: ${tail(r.out)}`);
  const dist = path.join(this.copyRoot, 'dist');
  const archives = fs.existsSync(dist) ? fs.readdirSync(dist).filter(f => f.endsWith('.tar.gz')) : [];
  assert.deepEqual(archives, [], `package.sh published an archive despite the missing link: ${archives.join(', ')}`);
});
