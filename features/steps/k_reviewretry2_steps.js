'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
function observe(result, name) {
  const label = `go test -json ./build -run ^${name}$ -count=1: required test ${name}`;
  assert.ok(!result.error, `${label}: process error ${result.error}`);
  assert.equal(result.status, 0, `${label}: exit ${result.status}\n${result.stdout}\n${result.stderr}`);
  const rows = result.stdout.split('\n').filter(Boolean).map(s => JSON.parse(s));
  const own = rows.filter(r => r.Test === name);
  assert.equal(own.filter(r => r.Action === 'run').length, 1, `${label}: absent or duplicate run`);
  assert.equal(own.filter(r => r.Action === 'pass').length, 1, `${label}: absent pass or skipped test`);
  assert.ok(!rows.some(r => r.Action === 'fail' || (r.Test === name && r.Action === 'skip')), `${label}: failed or skipped`);
}
if (require.main === module && process.argv[2] === '--control') {
  const name = 'TestKReviewRetry2LogReplay';
  const result = {status: 0, stdout: [{Test:name,Action:'run'},{Test:name,Action:'pass'}].map(r => JSON.stringify(r)).join('\n'), stderr:''};
  if (process.argv[3] === 'good') {
    observe(result, name);
    console.log('reviewretry2 good');
  } else {
    try { observe({...result,stdout:'{"Action":"pass"}\n'}, name); }
    catch (_) { console.log('reviewretry2 rejected absent test'); process.exitCode = 1; }
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('reviewretry2 Go test {string} runs', {timeout:290000}, function(name) {
    assert.match(name, /^TestKReviewRetry(?:2(?:LogReplay|AnyEnd|ForcedReset|DiscardEdits)|UnchangedValidRequests|SeparateAllowances|ReviewOnlyResume)$/);
    this.reviewretry2 = spawnSync('go', ['test','-json','./build','-run','^'+name+'$','-count=1'], {cwd:path.resolve(__dirname,'../../cli'),encoding:'utf8',timeout:280000,maxBuffer:32*1024*1024});
  });
  Then('reviewretry2 test {string} ran once and passed', function(name) { observe(this.reviewretry2,name); });
}
