'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');

const ROOT = path.resolve(__dirname, '../..');
const P = 'read-command-project-answers-name-the-folder';
const temporary = [];
const scratch = prefix => { const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`))); temporary.push(d); return d; };
AfterAll(() => { for (const d of temporary) fs.rmSync(d, { recursive: true, force: true }); });

let built;
const binary = () => {
  if (!built) {
    built = path.join(scratch('kogen-folder-bin'), 'kogen');
    const env = { ...process.env, GOFLAGS: '-buildvcs=false', GOPROXY: 'off', GOTOOLCHAIN: 'local', GOWORK: 'off' };
    const r = spawnSync('go', ['build', '-o', built, '.'], { cwd: path.join(ROOT, 'cli'), env, encoding: 'utf8', timeout: 540000 });
    assert.equal(r.status, 0, `go build of the kogen CLI failed (${r.status}): ${r.stdout}${r.stderr}${r.error || ''}`);
  }
  return built;
};
const fill = (w, s) => { let t = s.replaceAll('<base>', w.base); for (const [k, v] of Object.entries(w.dirs)) t = t.replaceAll(`<${k}>`, v); return t; };

Given(`${P}: the kogen CLI built from the current sources`, { timeout: 600000 }, function () {
  const base = scratch('kogen-folder-base');
  const home = path.join(base, 'home');
  fs.mkdirSync(home);
  fs.writeFileSync(path.join(home, '.gitconfig'), '');
  const work = path.join(base, 'work');
  fs.mkdirSync(work);
  this.k = { bin: binary(), base: work, dirs: {}, env: { PATH: process.env.PATH, HOME: home, GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig'), GIT_CONFIG_NOSYSTEM: '1', GIT_CEILING_DIRECTORIES: work } };
});
Given(`${P}: a folder {string} that is not a Git checkout`, function (name) {
  const d = path.join(this.k.base, name); fs.mkdirSync(d); this.k.dirs[name] = d;
});
Given(`${P}: a Git checkout {string} without .kogen\\/project.yaml`, function (name) {
  const d = path.join(this.k.base, name); fs.mkdirSync(d); this.k.dirs[name] = d;
  assert.equal(spawnSync('git', ['init', '-q', d], { env: this.k.env }).status, 0, 'git init failed');
});
Given(`${P}: no folder {string}`, function (name) {
  const d = path.join(this.k.base, name); assert.ok(!fs.existsSync(d)); this.k.dirs[name] = d;
});
const run = (w, line, cwd) => {
  const r = spawnSync(w.bin, fill(w, line).split(' '), { cwd, env: w.env, encoding: 'utf8', timeout: 60000 });
  w.result = { code: r.status, stdout: r.stdout, stderr: r.stderr };
};
When(`${P}: I run kogen {string}`, function (line) { run(this.k, line, this.k.base); });
When(`${P}: I run kogen {string} from the folder {string}`, function (line, name) { run(this.k, line, this.k.dirs[name]); });

Then(`${P}: the exit code is {int}`, function (code) {
  assert.equal(this.k.result.code, code, `exit code: expected ${code}, got ${this.k.result.code}; stdout ${this.k.result.stdout} stderr ${this.k.result.stderr}`);
});
Then(`${P}: the answer is one JSON line of kind {string} with null checkout, null data and exactly the error class {string}, reason {string}, no paths and detail {string}`, function (kind, cls, reason, detail) {
  const out = this.k.result.stdout;
  assert.ok(out.endsWith('\n') && out.indexOf('\n') === out.length - 1, `not exactly one line: ${JSON.stringify(out)}`);
  const doc = JSON.parse(out);
  assert.deepEqual(doc, { schema_version: 1, kind, checkout: null, data: null, error: { class: cls, reason, detail: fill(this.k, detail), paths: [] } });
});
Then(`${P}: the answer is the successful context outside a project`, function () {
  const doc = JSON.parse(this.k.result.stdout);
  assert.equal(doc.error, null);
  assert.equal(doc.data.project, false);
  assert.equal(doc.checkout, null);
});
const text = file => fs.readFileSync(path.join(ROOT, file), 'utf8');
Then(`${P}: the file {string} contains the text {string}`, function (file, t) { assert.ok(text(file).includes(t), `${file} lacks ${JSON.stringify(t)}`); });
Then(`${P}: the file {string} does not contain the text {string}`, function (file, t) { assert.ok(!text(file).includes(t), `${file} still contains ${JSON.stringify(t)}`); });
