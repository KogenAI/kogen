'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
function observe(result, name) {
  const label = `go test -json ./build -run ^${name}$ -count=1: required test ${name}`;
  assert.ok(!result.error, `${label}: process error ${result.error}`);
  assert.equal(result.status, 0, `${label}: exit ${result.status}\n${result.stdout}\n${result.stderr}`);
  const rows = result.stdout.split('\n').filter(Boolean).map(s => JSON.parse(s));
  const own = rows.filter(r => r.Test === name);
  assert.equal(own.filter(r => r.Action === 'run').length, 1, `${label}: absent or duplicate run`);
  assert.equal(own.filter(r => r.Action === 'pass').length, 1, `${label}: absent pass or skipped`);
  assert.ok(!rows.some(r => r.Action === 'fail' || r.Action === 'skip'), `${label}: failed or skipped`);
}
if (require.main === module && process.argv[2] === '--control') {
  const name = 'TestKReviewVerdictStrandReset';
  const stdout = process.argv[3] === 'good' ? [{Test:name,Action:'run'},{Test:name,Action:'pass'}].map(JSON.stringify).join('\n') : '{"Action":"pass"}\n';
  try { observe({status:0,stdout,stderr:''}, name); console.log('accepted named test'); }
  catch (e) { if (process.argv[3] !== 'bad') throw e; console.log('rejected absent named test'); process.exitCode = 1; }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('verdict-strand regression {string} runs', {timeout:290000}, function(name) {
    assert.match(name, /^TestKReviewVerdictStrand(?:Reset|PinnedResume|Safety)$/);
    this.verdictStrandResult = spawnSync('go', ['test','-json','./build','-run','^'+name+'$','-count=1'], {cwd:path.resolve(__dirname,'../../cli'),encoding:'utf8',timeout:280000,maxBuffer:32*1024*1024});
  });
  Then('verdict-strand regression {string} ran and passed', function(name) { observe(this.verdictStrandResult, name); });
}
