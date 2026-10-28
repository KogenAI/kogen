'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
function passed(text, name) {
  const events = text.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  return events.some(e => e.Test === name && e.Action === 'run') &&
    events.filter(e => e.Test === name && e.Action === 'pass').length === 1 &&
    !events.some(e => e.Action === 'fail' || e.Action === 'skip');
}
if (process.argv[2] === '--control') {
  const name = 'TestControl';
  const events = [{Action:'run',Test:name},{Action:process.argv[3] === 'good' ? 'pass' : 'skip',Test:name},{Action:'pass',Package:'fixture'}];
  const ok = passed(events.map(e => JSON.stringify(e)).join('\n'), name);
  console.log(ok ? 'observer accepted' : 'observer rejected');
  process.exitCode = ok ? 0 : 1;
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the K-NOPROG Go gate {string} runs in {string}', {timeout:300000}, function (name, pkg) {
    this.noprogName = name;
    this.noprogResult = spawnSync('go', ['test','-json','./'+pkg,'-run','^'+name+'$','-count=1'], {
      cwd:path.resolve(__dirname,'../../cli'), encoding:'utf8', timeout:280000, maxBuffer:16*1024*1024
    });
  });
  Then('the K-NOPROG gate actually passed', function () {
    const r = this.noprogResult;
    assert.ifError(r.error);
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.ok(passed(r.stdout, this.noprogName), 'Required behavioral test did not execute and pass: '+this.noprogName+'\n'+r.stdout+r.stderr);
  });
}
