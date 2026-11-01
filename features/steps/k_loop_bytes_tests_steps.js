'use strict';
// Acceptance steps of k-loop-bytes-tests: Kogen's request-byte tests pin what Kogen itself
// sends and read the loop's text from the pinned loop. Each scratch copy of the working tree
// (tracked and untracked, not ignored, files) gets exactly one text replacement and runs named
// Go tests; the Build's tree is never edited. `node features/steps/k_loop_bytes_tests_steps.js
// good|bad` runs the observer controls of the Go-test, replacement and pin assertions without
// Cucumber.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const runLimitMs = 110000;

function tail(text, n = 4000) {
  return text.length > n ? '[...]' + text.slice(-n) : text;
}

function outcome(run) {
  const timedOut = run.timedOut ? ', timed out' : '';
  return `exit ${run.status}${run.signal ? `, signal ${run.signal}` : ''}${timedOut}${run.error ? `, ${run.error}` : ''}`;
}

function goEvents(stdout) {
  const events = [];
  for (const line of String(stdout || '').split('\n')) {
    if (!line.startsWith('{')) continue;
    try { events.push(JSON.parse(line)); } catch { /* not a test event */ }
  }
  return events;
}

// goTestProblem is why test `name` of package `pkg` did not run exactly once with the required
// result (`pass` or `fail`) in `run`, the go test command of copy `copy`, or null when it did.
function goTestProblem(copy, pkg, name, want, run) {
  const events = goEvents(run.stdout);
  const own = events.filter(e => e.Package === pkg && e.Test === name);
  const count = action => own.filter(e => e.Action === action).length;
  const packageOutput = events.filter(e => e.Package === pkg && e.Action === 'output').map(e => e.Output).join('');
  let state = null;
  if (run.error || run.signal || run.timedOut) state = 'did not get a finished go test command';
  else if (count('run') === 0) state = 'is absent: it ran zero times';
  else if (count('run') > 1) state = `ran ${count('run')} times`;
  else if (count('skip') > 0) state = 'was skipped';
  else if (want === 'pass') {
    if (count('fail') > 0) state = 'failed';
    else if (count('pass') !== 1) state = 'reported no pass';
  } else {
    if (count('pass') > 0) state = 'passed';
    else if (count('fail') !== 1) state = 'reported no failure';
    else if (run.status === 0) state = 'failed, but its go test command succeeded';
    else if (packageOutput.includes('panic: test timed out')) state = 'failed only by the go test timeout';
  }
  if (state === null) return null;
  const output = events.filter(e => e.Package === pkg && e.Action === 'output' && (e.Test === name || String(e.Test || '').startsWith(name + '/')))
    .map(e => e.Output).join('');
  return `${pkg} ${name} in copy "${copy}" ${state} (required: run once and ${want}); command: ${run.command}; ${outcome(run)}\n` +
    `${tail(output || String(run.stdout || ''))}${run.stderr ? '\nstderr: ' + tail(String(run.stderr)) : ''}`;
}

// replaceOnce is text with its only occurrence of `from` replaced by `to`.
function replaceOnce(text, from, to, where) {
  const n = text.split(from).length - 1;
  assert.ok(n === 1, `${where} contains "${from}" ${n} times, not exactly once`);
  return text.replace(from, () => to);
}

function sha256(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

// pinProblem is why folder `dir` does not match the digest and file count recorded in the pin
// file (the digest packaging/sync-kogen-loop.sh writes: sha256 over the byte-sorted lines
// "path NUL sha256(file) LF" of every regular file), or null when it does.
function pinProblem(dir, pinFile) {
  const pin = JSON.parse(fs.readFileSync(pinFile, 'utf8'));
  const files = [];
  const walk = rel => {
    for (const entry of fs.readdirSync(path.join(dir, rel), { withFileTypes: true })) {
      const child = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) walk(child);
      else if (entry.isFile()) files.push(child);
    }
  };
  walk('');
  files.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  const lines = files.map(f => `${f}\0${sha256(fs.readFileSync(path.join(dir, f)))}\n`).join('');
  const digest = sha256(Buffer.from(lines));
  if (digest === pin.digest && files.length === pin.files) return null;
  return `${dir} has digest ${digest} and ${files.length} files; ${pinFile} records ${pin.digest} and ${pin.files}`;
}

function goPackage(spec) {
  assert.match(spec, /^\.(\/[a-z0-9_]+)*$/, `package ${spec}`);
  const module = fs.readFileSync(path.join(root, 'cli/go.mod'), 'utf8').match(/^module (\S+)$/m)[1];
  return spec === '.' ? module : `${module}/${spec.slice(2)}`;
}

// State of this Cucumber process: the copies are made and the Go tests run once, concurrently,
// for every scenario of the feature.
const proof = { copiesKey: null, copies: null, base: null, runsKey: null, runs: null };

function workingTreeFiles() {
  const listed = spawnSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  assert.equal(listed.status, 0, `git ls-files in ${root}: ${listed.stderr}`);
  return [...new Set(listed.stdout.split('\0').filter(Boolean))];
}

function copyTree(files, dest) {
  for (const rel of files) {
    const from = path.join(root, rel);
    let stat;
    try { stat = fs.lstatSync(from); } catch { continue; } // deleted in the working tree
    const to = path.join(dest, rel);
    fs.mkdirSync(path.dirname(to), { recursive: true });
    if (stat.isSymbolicLink()) fs.symlinkSync(fs.readlinkSync(from), to);
    else if (stat.isFile()) { fs.copyFileSync(from, to); fs.chmodSync(to, stat.mode & 0o777); }
  }
}

function makeCopies(rows) {
  const key = JSON.stringify(rows);
  if (proof.copiesKey === key) return;
  assert.ok(proof.copiesKey === null, 'the scratch copies were already made with other replacements');
  for (const row of rows) {
    assert.match(row.copy, /^[a-z0-9]+(-[a-z0-9]+)*$/, `copy name ${row.copy}`);
    assert.ok(!path.isAbsolute(row.file) && !row.file.split('/').includes('..'), `file ${row.file}`);
  }
  assert.equal(new Set(rows.map(r => r.copy)).size, rows.length, 'each copy has exactly one replacement');
  proof.base = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'kogen-loop-bytes-'));
  const base = proof.base;
  process.on('exit', () => fs.rmSync(base, { recursive: true, force: true }));
  const files = workingTreeFiles();
  proof.copies = {};
  for (const row of rows) {
    const dir = path.join(base, row.copy);
    copyTree(files, dir);
    const file = path.join(dir, row.file);
    fs.writeFileSync(file, replaceOnce(fs.readFileSync(file, 'utf8'), row.old, row.new, `${row.file} of the working tree`));
    proof.copies[row.copy] = { dir, ...row };
  }
  proof.copiesKey = key;
}

function runGoTests(copy, rows) {
  const packages = [...new Set(rows.map(r => r.package))];
  const pattern = `^(${[...new Set(rows.map(r => r.test))].join('|')})$`;
  const args = ['test', '-json', '-count=1', '-timeout', '100s', ...packages, '-run', pattern];
  const command = `(cd <copy ${copy}>/cli && go ${args.slice(0, -1).join(' ')} '${pattern}')`;
  return new Promise(resolve => {
    const child = spawn('go', args, { cwd: path.join(proof.copies[copy].dir, 'cli'), env: process.env, detached: true });
    const out = [], err = [];
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; try { process.kill(-child.pid, 'SIGKILL'); } catch { /* gone */ } }, runLimitMs);
    child.stdout.on('data', d => out.push(d));
    child.stderr.on('data', d => err.push(d));
    child.on('error', e => { clearTimeout(timer); resolve({ command, status: null, signal: null, timedOut, error: e.message, stdout: '', stderr: '' }); });
    child.on('close', (status, signal) => {
      clearTimeout(timer);
      resolve({ command, status, signal, timedOut, error: null, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8') });
    });
  });
}

function startRuns(rows) {
  const key = JSON.stringify(rows);
  if (proof.runsKey === key) return proof.runs;
  assert.ok(proof.runsKey === null, 'the Go tests were already run with other rows');
  for (const row of rows) {
    assert.ok(proof.copies && proof.copies[row.copy], `no scratch copy "${row.copy}"`);
    assert.match(row.test, /^Test[A-Za-z0-9_]+$/, `test name ${row.test}`);
    goPackage(row.package);
  }
  const byCopy = {};
  for (const row of rows) (byCopy[row.copy] ||= []).push(row);
  proof.runsKey = key;
  proof.runs = Promise.all(Object.entries(byCopy).map(async ([copy, own]) => [copy, { rows: own, run: await runGoTests(copy, own) }]))
    .then(Object.fromEntries);
  return proof.runs;
}

async function problemsOf(copy, want, table) {
  assert.ok(proof.runs, 'no Go tests were run');
  const runs = await proof.runs;
  const entry = runs[copy];
  assert.ok(entry, `no Go tests were run in copy "${copy}"`);
  return table.hashes().map(row => {
    const ran = entry.rows.some(r => r.package === row.package && r.test === row.test);
    if (!ran) return `${row.test} of package ${row.package} was not among the tests run in copy "${copy}"`;
    return goTestProblem(copy, goPackage(row.package), row.test, want, entry.run);
  }).filter(Boolean);
}

function controls(mode) {
  const ev = (pkg, name, actions) => actions.map(Action => JSON.stringify({ Package: pkg, Test: name, Action })).join('\n') + '\n';
  const run = (status, stdout, extra = {}) => ({ command: 'go test', status, signal: null, timedOut: false, error: null, stdout, stderr: '', ...extra });
  const P = 'kogen/build', T = 'TestKReviewRetryUnchangedValidRequests';
  const attempt = f => { try { f(); return null; } catch (e) { return e.message; } };
  const pinFile = path.join(root, 'cli/loop-pin.json');
  const single = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-loop-bytes-control-'));
  fs.writeFileSync(path.join(single, 'go.mod'), 'module kogen-loop\n');
  const good = [
    goTestProblem('c', P, T, 'pass', run(1, ev(P, T, ['run', 'pass']) + ev(P, 'TestOther', ['run', 'fail']))),
    goTestProblem('c', P, T, 'fail', run(1, ev(P, T, ['run', 'fail']))),
    attempt(() => assert.equal(replaceOnce('a X b', 'X', 'Y$&', 'f'), 'a Y$& b')),
    pinProblem(path.join(root, 'cli/third_party/kogen-loop'), pinFile),
  ];
  const bad = [
    goTestProblem('c', P, T, 'pass', run(1, ev(P, T, ['run', 'fail']))),
    goTestProblem('c', P, T, 'pass', run(0, ev(P, T, ['run', 'skip']))),
    goTestProblem('c', P, T, 'pass', run(0, ev(P, 'TestOther', ['run', 'pass']))),
    goTestProblem('c', P, T, 'pass', run(0, ev(P, T, ['run', 'pass', 'run', 'pass']))),
    goTestProblem('c', P, T, 'pass', run(0, ev('kogen', T, ['run', 'pass']))),
    goTestProblem('c', P, T, 'pass', run(null, ev(P, T, ['run', 'pass']), { signal: 'SIGKILL', timedOut: true })),
    goTestProblem('c', P, T, 'fail', run(1, ev(P, T, ['run', 'pass']))),
    goTestProblem('c', P, T, 'fail', run(1, 'build/x.go:1:1: syntax error\nFAIL\tkogen/build [build failed]\n')),
    goTestProblem('c', P, T, 'fail', run(0, ev(P, T, ['run', 'fail']))),
    goTestProblem('c', P, T, 'fail', run(1, ev(P, T, ['run']) + JSON.stringify({ Package: P, Action: 'output', Output: 'panic: test timed out after 100s\n' }) + '\n' + ev(P, T, ['fail']))),
    attempt(() => replaceOnce('a b', 'X', 'Y', 'f')),
    attempt(() => replaceOnce('X X', 'X', 'Y', 'f')),
    pinProblem(single, pinFile),
  ];
  fs.rmSync(single, { recursive: true, force: true });
  const accepted = mode === 'good' ? good.every(p => p === null) : !bad.every(p => p !== null);
  console.log(accepted ? 'accepted' : 'rejected');
  if (!accepted) process.exitCode = 1;
}

if (require.main === module) {
  controls(process.argv[2]);
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');

  Given('loop-bytes proof makes these scratch copies of the working tree, each with exactly one replacement:', { timeout: 60000 }, function (table) {
    makeCopies(table.hashes());
  });

  When('loop-bytes proof runs these Go tests in those copies:', { timeout: 115000 }, async function (table) {
    await startRuns(table.hashes());
  });

  Then('loop-bytes proof finds {string} in the working tree matches the digest and file count in {string}', function (dir, pin) {
    const problem = pinProblem(path.join(root, dir), path.join(root, pin));
    assert.ok(problem === null, `the Build's tree changed the vendored loop: ${problem}`);
  });

  Then('loop-bytes proof finds {string} in copy {string} does not match the digest in {string}', function (dir, copy, pin) {
    assert.ok(proof.copies && proof.copies[copy], `no scratch copy "${copy}"`);
    assert.ok(pinProblem(path.join(proof.copies[copy].dir, dir), path.join(root, pin)) !== null,
      `copy "${copy}" still matches ${pin}: its replacement did not change ${dir}`);
  });

  Then('loop-bytes proof observed these Go tests run once and pass in copy {string}:', async function (copy, table) {
    const problems = await problemsOf(copy, 'pass', table);
    assert.ok(problems.length === 0, problems.join('\n\n'));
  });

  Then('loop-bytes proof observed these Go tests run once and pass in copy {string} and run once and fail in copy {string}:', async function (green, red, table) {
    const problems = [...await problemsOf(green, 'pass', table), ...await problemsOf(red, 'fail', table)];
    assert.ok(problems.length === 0, problems.join('\n\n'));
  });
}
