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

// ---- the per-role records of a fake claude that scripts roles (lineup scenarios) ----

function roleCalls(world, role) {
  const file = path.join(stateDir(world), `calls-${role}`);
  return fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8').trim()) : 0;
}

function roleArgv(world, role, n) {
  const file = path.join(stateDir(world), `argv-${role}-${n}.json`);
  assert.ok(fs.existsSync(file), `the fake claude has no ${role} invocation ${n}`);
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function rolePrompt(world, role, n) {
  const file = path.join(stateDir(world), `prompt-${role}-${n}.txt`);
  assert.ok(fs.existsSync(file), `the fake claude has no ${role} invocation ${n}`);
  return fs.readFileSync(file, 'utf8');
}

function sessions(world) {
  const file = path.join(stateDir(world), 'sessions.jsonl');
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line)) : [];
}

// The session a role invocation belongs to: the one it started, or the one it resumed.
function sessionOf(world, role, n) {
  const record = sessions(world).find(entry => entry.role === role && entry.n === n);
  assert.ok(record, `no ${role} invocation ${n} was recorded`);
  return record.start || record.resume;
}

function lineupSteps(world, label, args, latestRunDir) {
  if (label.startsWith('fake claude role ') && label.includes(' ran ')) {
    assert.equal(roleCalls(world, args[0]), Number(args[1]), `${args[0]} invocations`);
    return true;
  }
  if (label.startsWith('fake claude role ') && label.includes(' did not receive any of the arguments ')) {
    const argv = roleArgv(world, args[0], Number(args[1]));
    for (const name of args[2].split(',')) assert.ok(!argv.includes(name), `${args[0]} invocation ${args[1]} received ${name}`);
    return true;
  }
  if (label.startsWith('fake claude role ') && label.includes(' received the argument ')) {
    assert.ok(roleArgv(world, args[0], Number(args[1])).includes(args[2]), `${args[0]} invocation ${args[1]} did not receive ${args[2]}`);
    return true;
  }
  if (label.startsWith('fake claude role ') && label.includes(' received a prompt not containing ')) {
    assert.ok(!rolePrompt(world, args[0], Number(args[1])).includes(args[2]), `${args[0]} invocation ${args[1]} prompt contains ${args[2]}`);
    return true;
  }
  if (label.startsWith('fake claude role ') && label.includes(' received a prompt containing ')) {
    assert.ok(rolePrompt(world, args[0], Number(args[1])).includes(args[2]), `${args[0]} invocation ${args[1]} prompt lacks ${args[2]}`);
    return true;
  }
  if (label.startsWith('fake claude role ') && label.includes(' resumed the session of its invocation ')) {
    const resumed = roleArgv(world, args[0], Number(args[1]));
    assert.equal(flagValue(resumed, '--resume'), sessionOf(world, args[0], Number(args[2])));
    assert.ok(!resumed.includes('--session-id'), 'a resumed invocation started another session');
    return true;
  }
  if (label.startsWith('fake claude role ') && label.includes(' started a session of its own')) {
    const record = sessions(world).find(entry => entry.role === args[0] && entry.n === Number(args[1]));
    assert.ok(record && record.start, 'the invocation did not start a session');
    assert.ok(!record.resume, 'the invocation resumed a session');
    for (const other of sessions(world)) {
      if (!(other.role === record.role && other.n === record.n) && other.start) assert.notEqual(other.start, record.start, 'the session is shared with another invocation');
    }
    return true;
  }
  if (label.startsWith('the fake claude roles used ')) {
    const started = new Set(sessions(world).map(entry => entry.start).filter(Boolean));
    assert.equal(started.size, Number(args[0]));
    return true;
  }
  if (label === 'the review material evidence records delivery of the complete source') {
    const dir = path.join(latestRunDir(), 'executor-review');
    const evidence = JSON.parse(fs.readFileSync(path.join(dir, 'review-1-material.json'), 'utf8'));
    const source = fs.readFileSync(path.join(dir, 'review-1-source.txt'), 'utf8');
    const authority = fs.readFileSync(path.join(dir, 'review-1-authority.txt'), 'utf8');
    assert.equal(evidence.delivered, true);
    assert.ok(evidence.delivered_round >= 1 && evidence.session_id);
    assert.equal(evidence.source.bytes, Buffer.byteLength(source));
    const prompt = rolePrompt(world, 'review', 1);
    assert.ok(prompt.includes(authority) && prompt.includes(source), 'the review prompt lacks the complete retained material');
    assert.ok(evidence.parts.some(part => part.path === 'calc.py'), 'the parts do not name calc.py');
    return true;
  }
  if (label === 'no Kogen documentation record exists for the shape run') {
    const dir = path.join(world.project, '.kogen/local/shaping/is-even');
    const events = fs.readFileSync(path.join(dir, 'events.ndjson'), 'utf8').split('\n').filter(Boolean).map(line => JSON.parse(line));
    assert.ok(events.some(event => event.event === 'executor_summary'), 'no executor summary was recorded');
    assert.ok(!events.some(event => /documentation/.test(event.event)), 'a Kogen documentation record exists');
    return true;
  }
  return false;
}

// Returns true when the label was an executor step.
async function executorSteps(world, label, args, latestRunDir) {
  if (lineupSteps(world, label, args, latestRunDir)) return true;
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
