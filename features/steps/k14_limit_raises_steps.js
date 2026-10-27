'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');

const count = (text, needle) => needle ? String(text).split(needle).length - 1 : 0;

// The recorded observation: the native reviewer's provider request and the external reviewer's
// task, for one diff that raises a limit.
function observe() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-k14-'));
  fs.chmodSync(dir, 0o700);
  try {
    const output = path.join(dir, 'output.json'), overlay = path.join(dir, 'overlay.json');
    fs.writeFileSync(overlay, JSON.stringify({ Replace: {
      [path.join(ROOT, 'cli/build/k14_limit_raises_acceptance_test.go')]: path.join(__dirname, 'k14_limit_raises_driver.go'),
    } }), { mode: 0o600 });
    const r = spawnSync('go', ['test', '-overlay', overlay, './build', '-run', '^TestK14LimitRaiseObservation$', '-count=1'], {
      cwd: path.join(ROOT, 'cli'), encoding: 'utf8', timeout: 240000, maxBuffer: 8 * 1024 * 1024,
      env: { ...process.env, KOGEN_K14_OUTPUT: output },
    });
    assert.ifError(r.error);
    assert.equal(r.status, 0, `observation failed:\n${r.stdout}\n${r.stderr}`);
    // Go success alone is not proof: the requested test must have written its observation.
    return JSON.parse(fs.readFileSync(output, 'utf8'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function checkRoute(obs, route, field, rule) {
  const r = obs[route];
  assert.ok(r, `no ${route} observation`);
  assert.equal(r.exit, 0, `${route} build: ${r.output}`);
  assert.equal(r.requests, 1, `${route} review requests`);
  assert.equal(count(r[field], rule), 1, `the rule must appear exactly once in the ${route} review ${field}`);
}
const checkNative = (obs, rule) => checkRoute(obs, 'native', 'instructions', rule);
const checkExternal = (obs, rule) => checkRoute(obs, 'external', 'stable', rule);
function checkDiff(obs, from, to) {
  for (const [route, field] of [['native', 'material'], ['external', 'dynamic']]) {
    const text = obs[route] && obs[route][field];
    assert.ok(text, `no ${route} ${field}`);
    assert.ok(text.includes(`-${from}`) && text.includes(`+${to}`), `the ${route} review does not carry the diff ${from} -> ${to}`);
  }
}

// Final-byte observer controls: the checks accept a good observation and reject bad ones.
function controls(kind) {
  const rule = 'RULE TEXT.';
  const good = {
    native: { exit: 0, requests: 1, instructions: `base\n\n${rule}\n`, material: '-timeout: 600\n+timeout: 1800\n', output: '' },
    external: { exit: 0, requests: 1, stable: `authority\n${rule}\n`, dynamic: '-timeout: 600\n+timeout: 1800\n', output: '' },
  };
  checkNative(good, rule); checkExternal(good, rule); checkDiff(good, 'timeout: 600', 'timeout: 1800');
  if (kind === 'good') { console.log('k14 observer good'); return; }
  assert.equal(kind, 'bad');
  const bad = (fn, mutate) => { const c = structuredClone(good); mutate(c); assert.throws(() => fn(c), 'accepted a known-bad fixture'); };
  bad(o => checkNative(o, rule), o => { o.native.instructions = 'base'; });
  bad(o => checkNative(o, rule), o => { o.native.instructions += rule; });
  bad(o => checkNative(o, rule), o => { o.native.exit = 1; });
  bad(o => checkExternal(o, rule), o => { o.external.stable = 'authority'; });
  bad(o => checkExternal(o, rule), o => { o.external.requests = 0; });
  bad(o => checkDiff(o, 'timeout: 600', 'timeout: 1800'), o => { o.external.dynamic = '+timeout: 1800'; });
  bad(o => checkDiff(o, 'timeout: 600', 'timeout: 1800'), o => { o.native.material = ''; });
  console.log('k14 observer rejected bad fixtures');
  process.exitCode = 1;
}

if (require.main === module && process.argv[2] === '--control') {
  controls(process.argv[3]);
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('Kogen reviews a diff that raises {string} to {string} with no profile through the native and the external review routes', { timeout: 250000 }, function (from, to) {
    this.k14 = observe();
    this.k14diff = [from, to];
  });
  Then('the native review instructions contain this rule exactly once:', function (rule) { checkNative(this.k14, rule); });
  Then('the external review request contains this rule exactly once:', function (rule) { checkExternal(this.k14, rule); });
  Then('both review requests carry the raise from the old value to the new value', function () { checkDiff(this.k14, ...this.k14diff); });
}
