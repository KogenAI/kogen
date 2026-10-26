// Step definitions for the Build-executor scenarios (spec/features/STEPS.md "Fake claude").
// dispatch() in handlers.js delegates the labels below here before its own routing.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { ACCEPTANCE, mkdirp } = require('./world');

const FIXTURES = path.join(ACCEPTANCE, 'fixtures/claude');

function shell(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

// Installs an executable `claude` first on the scenario's PATH. It runs the Node fake with the
// named script; the state folder lives outside the project, so it never joins Build custody.
function installFakeClaude(world, name) {
  const script = path.join(FIXTURES, `${name}.json`);
  assert.ok(fs.existsSync(script), `no fake claude script named ${name}`);
  const root = path.join(world.workspace, 'fake-claude');
  const binDir = path.join(root, 'bin');
  const stateDir = path.join(root, 'state');
  mkdirp(binDir);
  mkdirp(stateDir);
  const shim = path.join(binDir, 'claude');
  fs.writeFileSync(shim, `#!/bin/sh\nKOGEN_FAKE_CLAUDE_SCRIPT=${shell(script)} KOGEN_FAKE_CLAUDE_STATE=${shell(stateDir)} exec ${shell(process.execPath)} ${shell(path.join(FIXTURES, 'fake-claude.js'))} "$@"\n`);
  fs.chmodSync(shim, 0o755);
  world.fakeClaude = { binDir, stateDir, script };
}

function stateDir(world) {
  assert.ok(world.fakeClaude, 'no fake claude was put on PATH');
  return world.fakeClaude.stateDir;
}

function calls(world) {
  const file = path.join(stateDir(world), 'calls');
  return fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8').trim()) : 0;
}

function argv(world, round) {
  const file = path.join(stateDir(world), `argv-${round}.json`);
  assert.ok(fs.existsSync(file), `the fake claude has no round ${round}`);
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function flagValue(list, name) {
  const index = list.indexOf(name);
  return index >= 0 ? list[index + 1] : undefined;
}

// The events of the Build's run log (log.jsonl of the run folder the harness resolves).
function runLogEvents(latestRunDir) {
  const dir = latestRunDir();
  assert.ok(dir, 'no run folder exists');
  const log = path.join(dir, 'log.jsonl');
  assert.ok(fs.existsSync(log), 'the run folder has no log.jsonl');
  return fs.readFileSync(log, 'utf8').split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
}

// Returns true when the label was an executor step.
async function executorSteps(world, label, args, latestRunDir) {
  if (label.startsWith('a fake claude with script ')) {
    installFakeClaude(world, args[0]);
    return true;
  }
  if (label.startsWith('the fake claude ran ')) {
    assert.equal(calls(world), Number(args[0]));
    return true;
  }
  if (label.startsWith('fake claude round ') && label.includes(' received the argument ')) {
    assert.ok(argv(world, Number(args[0])).includes(args[1]), `round ${args[0]} did not receive ${args[1]}`);
    return true;
  }
  if (label.startsWith('no fake claude round received the argument ')) {
    for (let round = 1; round <= calls(world); round++) {
      assert.ok(!argv(world, round).includes(args[0]), `round ${round} received ${args[0]}`);
    }
    return true;
  }
  if (label.startsWith('no fake claude round had the environment variable ')) {
    const rounds = calls(world);
    assert.ok(rounds > 0, 'the fake claude was never run for a round');
    for (let round = 1; round <= rounds; round++) {
      const names = JSON.parse(fs.readFileSync(path.join(stateDir(world), `env-${round}.json`), 'utf8'));
      assert.ok(!names.includes(args[0]), `round ${round} had the environment variable ${args[0]}`);
    }
    return true;
  }
  if (label.startsWith('fake claude round ') && label.includes(' resumed the session it started in round 1')) {
    const round = Number(args[0]);
    const started = flagValue(argv(world, 1), '--session-id');
    assert.ok(started, 'round 1 did not name a session');
    assert.equal(flagValue(argv(world, round), '--resume'), started);
    return true;
  }
  if (label.startsWith('fake claude round ') && label.includes(' received a prompt containing ')) {
    const file = path.join(stateDir(world), `prompt-${args[0]}.txt`);
    assert.ok(fs.existsSync(file), `the fake claude has no round ${args[0]}`);
    assert.ok(fs.readFileSync(file, 'utf8').includes(args[1]), `round ${args[0]} prompt did not contain ${args[1]}`);
    return true;
  }
  if (label === 'the fake claude emitted no tool call') {
    assert.ok(!fs.existsSync(path.join(stateDir(world), 'tool-calls.jsonl')), 'the fake claude emitted a tool call');
    return true;
  }
  if (label.startsWith('the run log records ') && label.includes(' executor round')) {
    const events = runLogEvents(latestRunDir);
    assert.equal(events.filter(event => event.event === 'executor_round_ended').length, Number(args[0]));
    return true;
  }
  if (label.startsWith('the run log shows an executor hook decision ')) {
    const events = runLogEvents(latestRunDir);
    assert.ok(events.some(event => event.event === 'executor_hook' && event.decision === args[0] && event.tool_name === args[1]),
      `run log has no executor_hook decision ${args[0]} for ${args[1]}`);
    return true;
  }
  return false;
}

module.exports = { executorSteps };
