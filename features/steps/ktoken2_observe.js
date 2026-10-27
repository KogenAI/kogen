'use strict';
// Pure observation of what the fake `claude` recorded for each credential-relevant invocation.
// A call is {args: string[], env: {NAME: value}, fd3: string|null} (fd3 is null when fd 3 was not open).
const assert = require('node:assert/strict');

const NEVER = ['CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB', 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR'];
const credentialCalls = calls => calls.filter(x => x.args[0] === 'auth' || x.args[0] === '-p');

// Every auth-status and round child received the stored token on fd 3 and nowhere else.
function checkStored(calls, token, sentinels) {
  const cc = credentialCalls(calls);
  assert.ok(cc.some(x => x.args[0] === 'auth'), 'no auth status call');
  assert.ok(cc.some(x => x.args[0] === '-p' && !x.args.includes('--resume')), 'no first round');
  assert.ok(cc.some(x => x.args[0] === '-p' && x.args.includes('--resume')), 'no --resume round');
  for (const x of cc) {
    const label = x.args.slice(0, 3).join(' ');
    assert.equal(x.env.CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR, '3', 'FILE_DESCRIPTOR in ' + label);
    assert.equal(x.fd3, token, 'fd 3 content in ' + label);
    for (const k of NEVER) assert.equal(x.env[k], undefined, k + ' in ' + label);
    for (const v of Object.values(x.env)) {
      assert.ok(!v.includes(token), 'token in env of ' + label);
      for (const s of sentinels) assert.ok(!v.includes(s), 'inherited value ' + s + ' in env of ' + label);
    }
    assert.ok(!JSON.stringify(x.args).includes(token), 'token in argv of ' + label);
  }
}

// Without a stored token no child has fd 3 or any of the credential variables.
function checkNoToken(calls, sentinels) {
  const cc = credentialCalls(calls);
  assert.ok(cc.some(x => x.args[0] === 'auth'), 'no auth status call');
  for (const x of cc) {
    assert.equal(x.fd3, null, 'fd 3 open');
    assert.equal(x.env.CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR, undefined, 'FILE_DESCRIPTOR set');
    for (const k of NEVER) assert.equal(x.env[k], undefined, k);
    for (const v of Object.values(x.env)) for (const s of sentinels) assert.ok(!v.includes(s), 'inherited value ' + s);
  }
}

module.exports = {checkStored, checkNoToken};
