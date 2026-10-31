'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');

const cli = path.resolve(__dirname, '../../cli');

// command is the exact go test invocation a scenario runs for one named test.
function command(name) {
  return ['go', 'test', '-json', '-count=1', '-run', '^' + name + '$', './shape'];
}

function shown(name) {
  return '(cd cli && ' + command(name).map(a => (/^[\w./=-]+$/.test(a) ? a : "'" + a + "'")).join(' ') + ')';
}

// problem is why the named test does not count as passed (null when it does): it must have
// run, passed, and nothing in the run may have been skipped or failed.
function problem(code, events, name) {
  const own = events.filter(e => e.Test === name || (typeof e.Test === 'string' && e.Test.startsWith(name + '/')));
  if (!own.some(e => e.Test === name && e.Action === 'run')) return 'absent: it ran zero times';
  if (own.some(e => e.Action === 'skip')) return 'skipped';
  if (events.some(e => e.Action === 'fail')) return 'failed';
  if (!own.some(e => e.Test === name && e.Action === 'pass')) return 'did not pass';
  if (code !== 0) return 'go test exited ' + code;
  return null;
}

function message(name, code, why, output) {
  return name + ' ' + why + '; command: ' + shown(name) + '; exit: ' + code + '\n' + output.slice(-6000);
}

if (require.main === module) {
  const name = 'TestControl';
  const ran = [{ Test: name, Action: 'run' }, { Test: name, Action: 'pass' }];
  if (process.argv[2] === 'good') {
    assert.equal(problem(0, ran, name), null);
    console.log('accepted');
  } else {
    const bad = [
      [0, [], name, 'absent: it ran zero times'],
      [0, [{ Action: 'pass' }], name, 'absent: it ran zero times'],
      [0, ran.slice(0, 1), name, 'did not pass'],
      [1, ran, name, 'go test exited 1'],
      [0, ran.concat({ Test: name + '/child', Action: 'skip' }), name, 'skipped'],
      [0, ran.concat({ Test: name, Action: 'skip' }), name, 'skipped'],
      [1, ran.concat({ Action: 'fail' }), name, 'failed'],
      [0, ran, 'TestOther', 'absent: it ran zero times'],
    ];
    for (const [code, events, n, why] of bad) {
      assert.equal(problem(code, events, n), why);
      assert.ok(message(n, code, why, '').startsWith(n + ' ' + why + '; command: (cd cli && go test -json -count=1 -run \'^' + n + '$\' ./shape); exit: ' + code));
    }
    console.log('rejected');
    process.exitCode = 1;
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('the long-reply Shape test {string} runs', { timeout: 240000 }, function (name) {
    const [bin, ...args] = command(name);
    const r = spawnSync(bin, args, { cwd: cli, encoding: 'utf8', timeout: 230000, maxBuffer: 32 * 1024 * 1024 });
    assert.ifError(r.error);
    const events = r.stdout.split('\n').filter(l => l.startsWith('{')).map(l => JSON.parse(l));
    this.longReply = { name, code: r.status, events, output: r.stdout + r.stderr };
  });
  Then('that long-reply Shape test passed without skipping', function () {
    const r = this.longReply;
    const why = problem(r.code, r.events, r.name);
    assert.ok(why === null, message(r.name, r.code, why, r.output));
  });
}
