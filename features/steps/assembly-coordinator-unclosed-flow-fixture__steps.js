'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');

const cli = resolve(__dirname, '../../cli');
const pkg = './consumes/kogen-coordinator';
const test = 'TestParseConfigRefusalsAreSysErrorsWithLines/unclosed_flow';
const command = `go test -count=1 ${pkg}`;
const missing = `${command}: ${test} did not run and pass, or the package did not pass`;

function runConsumerPackage() {
  const { status, error, stdout, stderr } = spawnSync('go', ['test', '-count=1', pkg], {
    cwd: cli,
    encoding: 'utf8',
    env: { ...process.env, GOFLAGS: `${process.env.GOFLAGS || ''} -json`.trim() },
    timeout: 90_000,
  });
  if (error || status !== 0) {
    throw new Error(`${command}: could not verify ${test} (status ${status}): ${error || ''}\n${stderr}\n${stdout}`);
  }
  const events = stdout.trim().split('\n').map(line => JSON.parse(line))
    .filter(event => event.Package === `kogen/${pkg.slice(2)}`);
  const seen = (action, name) => events.some(event => event.Action === action && event.Test === name);
  if (!seen('run', test) || !seen('pass', test) || !seen('pass', undefined)) {
    throw new Error(missing);
  }
}

if (require.main === module) {
  try {
    runConsumerPackage();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
} else {
  const { Then } = require('@cucumber/cucumber');

  Then('assembly-coordinator-unclosed-flow-fixture: go test -count=1 .\\/consumes\\/kogen-coordinator passes from cli and runs TestParseConfigRefusalsAreSysErrorsWithLines\\/unclosed_flow', { timeout: 100_000 }, runConsumerPackage);

  Then('assembly-coordinator-unclosed-flow-fixture: the tracked refusal case has this exact input and unchanged assertions', function (expected) {
    const file = resolve(cli, 'consumes/kogen-coordinator/config_test.go');
    const body = readFileSync(file, 'utf8').split('func TestParseConfigRefusalsAreSysErrorsWithLines(t *testing.T) {\n')[1];
    assert.ok(body && `${body.split('\n}\n')[0]}\n}`.endsWith(`\n${expected}`),
      `After ${command}, ${test} in config_test.go must use the exact unclosed commands fixture and preserve the refusal assertions`);
  });
}
