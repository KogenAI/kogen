'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
function observe(result, expected) {
  assert.deepEqual({status: result.status, timed_out: result.timed_out, output: result.output},
    {status: 0, timed_out: false, output: expected});
}
if (require.main === module) {
  const expected = 'build-cache=same\nmodule-cache=same\nsecret=absent\nhome=private\nbuild-cache=populated\n';
  try {
    observe({status: 0, timed_out: false, output: process.argv[2] === 'good' ? expected : expected.replace('secret=absent', 'secret=caller-only-sentinel')}, expected);
    console.log('accepted');
  } catch { console.log('rejected'); process.exitCode = 1; }
} else {
  const {When, Then, After} = require('@cucumber/cucumber');
  const {goDriver, shellQuote} = require('./go_driver_support');
  After(function () { if (this.kpgDir) fs.rmSync(this.kpgDir, {recursive:true, force:true}); });
  When('a Go cache regression probe builds a minimal Go package with caller secret {string}', {timeout: 90000}, async function (secret) {
    const dir = this.kpgDir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kpg-')));
    const project = path.join(dir, 'project'), cache = path.join(dir, 'build-cache'), mod = path.join(dir, 'module-cache'), home = path.join(dir, 'caller-home');
    for (const p of [project, cache, mod, home]) fs.mkdirSync(p);
    fs.writeFileSync(path.join(project, 'go.mod'), 'module example.test/cacheprobe\n\ngo 1.23\n');
    fs.writeFileSync(path.join(project, 'probe.go'), 'package cacheprobe\nconst Answer = 42\n');
    fs.writeFileSync(path.join(home, '.profile'), 'export KPG_SECRET=startup-leaked\n');
    const env = ['PATH=' + process.env.PATH, 'HOME=' + home, 'GOCACHE=' + cache, 'GOMODCACHE=' + mod, 'KPG_SECRET=' + secret];
    for (const key of ['GOROOT', 'GOPATH', 'GOTOOLDIR', 'MISE_DATA_DIR', 'MISE_CONFIG_DIR', 'MISE_CACHE_DIR', 'ASDF_DIR', 'ASDF_DATA_DIR']) if (process.env[key]) env.push(key + '=' + process.env[key]);
    const envFile = path.join(dir, 'env.json'); fs.writeFileSync(envFile, JSON.stringify(env));
    const command = `set -e\nif test "$(go env GOCACHE)" = ${shellQuote(cache)}; then echo build-cache=same; else echo build-cache=different; fi\nif test "$(go env GOMODCACHE)" = ${shellQuote(mod)}; then echo module-cache=same; else echo module-cache=different; fi\nprintf 'secret=%s\\n' "\${KPG_SECRET-absent}"\nif test "$HOME" != ${shellQuote(home)} && test ! -f "$HOME/.profile"; then echo home=private; else echo home=caller; fi\ngo build ./...\nif test -n "$(find ${shellQuote(cache)} -type f -name '*-d' -print)"; then echo build-cache=populated; else echo build-cache=empty; fi`;
    const driver = await goDriver('k-probe-gocache', fs.readFileSync(path.join(__dirname, 'k_probe_mix_home_driver.go'), 'utf8'));
    const r = await driver([project, envFile, command]);
    assert.equal(r.code, 0, 'verify.RunProbe driver failed: ' + r.out);
    this.kpgResult = JSON.parse(r.out.trim().split('\n').pop());
  });
  Then('the Go cache probe reports exactly:', function (expected) { observe(this.kpgResult, expected + '\n'); });
}
