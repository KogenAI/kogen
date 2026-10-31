'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFile } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
function observe(r, name) {
  const message = `${r.command}: required ${name}; exit ${r.code}; absent, skipped or zero-run tests are not passes\n${r.out}`;
  assert.equal(r.code, 0, message);
  const events = r.out.split('\n').filter(x => x.startsWith('{')).map(x => JSON.parse(x));
  assert.equal(events.filter(e => e.Test === name && e.Action === 'run').length, 1, message);
  assert.equal(events.filter(e => e.Test === name && e.Action === 'pass').length, 1, message);
  assert.equal(events.filter(e => ['fail', 'skip'].includes(e.Action)).length, 0, message);
  assert.equal(events.filter(e => !e.Test && e.Action === 'pass').length, 1, message);
}
if (require.main === module) {
  const name = 'TestChecktimeClockReadiness';
  const events = [{Test:name,Action:'run'},{Test:name,Action:'pass'},{Action:'pass'}];
  const result = e => ({command:'control go test ./build', code:0, out:e.map(x => JSON.stringify(x)).join('\n')});
  observe(result(events), name);
  if (process.argv[3] === 'good') console.log('clock observer accepted good');
  else {
    const bad = [[], events.filter(e => e.Test !== name), events.map(e => e.Test && e.Action === 'pass' ? {...e,Action:'skip'} : e), [...events,events[0]], events.slice(0,2)];
    for (const e of bad) assert.throws(() => observe(result(e), name));
    assert.throws(() => observe({...result(events),code:1}, name));
    console.log('clock observer rejected bad');
    process.exitCode = 1;
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('clock acceptance runs {string} in package {string}', {timeout:120000}, async function(name, pkg) {
    const args = ['test','-count=1','-json','-run',`^${name}$`,pkg];
    this.clockRun = await new Promise(resolve => execFile('go', args, {cwd:path.join(root,'cli'),maxBuffer:16*1024*1024}, (error,stdout,stderr) => resolve({command:`go ${args.join(' ')}`,code:error ? error.code : 0,out:stdout+stderr})));
  });
  Then('clock acceptance observes {string} ran once and passed', function(name) { observe(this.clockRun,name); });
  Then('the clock measurement note exists at {string}', function(file) {
    assert.ok(fs.existsSync(path.join(root,file)), `missing measured before/after accounting: ${file}`);
    assert.ok(fs.readFileSync(path.join(root,file),'utf8').trim(), `empty measurement note: ${file}`);
  });
}
