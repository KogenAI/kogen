'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const P = 'k-cli-inspect-unknown-run-names-next-command';
const quote = s => `'${String(s).replaceAll("'", "'\\''")}'`;

// Pure observers over what the CLI printed; `--control good|bad` runs them on known transcripts.
const sortKeys = o => Object.fromEntries(Object.entries(o).sort(([a], [b]) => (a < b ? -1 : 1)));
// The one JSON line a run-not-found read must print: the existing fields (keys in the encoder's sorted order) plus the error text.
const jsonLine = (checkout, error) => JSON.stringify({ checkout: sortKeys(checkout), data: null, error: sortKeys(error), kind: 'run', schema_version: 1 }) + '\n';
// What a pseudo-terminal returns: script echoes the end of its input as ^D, and lines end in CRLF. The shell appends exit=<code>.
function terminalRun(raw) {
  const text = raw.replace(/^\^D\x08\x08/, '').replaceAll('\r\n', '\n');
  const m = /^((?:.*\n)*?)exit=(\d+)\n$/.exec(text);
  assert.ok(m, `no exit marker at the end of the terminal output: ${JSON.stringify(raw)}`);
  return { body: m[1], code: Number(m[2]) };
}
const same = (what, actual, expected) => assert.equal(actual, expected, `${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);

if (require.main === module && process.argv[2] === '--control') {
  const checkout = { git_dir: '/r/.git', id: 'a'.repeat(64), root: '/r' };
  const error = { class: 'intent', reason: 'run_not_found', detail: 'no run with this id in this checkout', paths: [], next: 'kogen intent list' };
  const line = jsonLine(checkout, error), sentence = 'no run with this id in this checkout. Next: kogen intent list\n';
  const crlf = s => s.replaceAll('\n', '\r\n');
  const accepts = (raw, expected, code) => { const r = terminalRun(raw); same('terminal output', r.body, expected); same('exit code', String(r.code), String(code)); };
  const good = [
    () => accepts('^D\b\b' + crlf(line + sentence) + 'exit=1\r\n', line + sentence, 1),
    () => accepts(crlf(line) + 'exit=1\r\n', line, 1),
    () => same('line', line, '{"checkout":{"git_dir":"/r/.git","id":"' + 'a'.repeat(64) + '","root":"/r"},"data":null,"error":{"class":"intent","detail":"no run with this id in this checkout","next":"kogen intent list","paths":[],"reason":"run_not_found"},"kind":"run","schema_version":1}\n'),
  ];
  const bad = [
    () => accepts(crlf(sentence + line) + 'exit=1\r\n', line + sentence, 1),
    () => accepts(crlf(line) + 'exit=1\r\n', line + sentence, 1),
    () => accepts(crlf(line + sentence + sentence) + 'exit=1\r\n', line + sentence, 1),
    () => accepts(crlf(line + sentence) + 'exit=0\r\n', line + sentence, 1),
    () => accepts(crlf(line + sentence), line + sentence, 1),
    () => accepts(crlf(line + sentence) + 'exit=1\r\n', line, 1),
  ];
  if (process.argv[3] === 'good') {
    try { good.forEach(f => f()); process.stdout.write(`${P} observer good\n`); } catch (e) { process.stderr.write(e.message + '\n'); process.exitCode = 1; }
  } else {
    const accepted = bad.filter(f => { try { f(); return true; } catch { return false; } }).length;
    if (accepted) { process.stdout.write(`${P} observer accepted ${accepted} bad transcripts\n`); } else { process.stdout.write(`${P} observer rejected ${bad.length} bad transcripts\n`); process.exitCode = 1; }
  }
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  const temporary = [];
  const scratch = prefix => { const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`))); temporary.push(d); return d; };
  AfterAll(() => { for (const d of temporary) fs.rmSync(d, { recursive: true, force: true }); });

  let built;
  const binary = () => {
    if (!built) {
      built = path.join(scratch('kogen-inspect-bin'), 'kogen');
      const env = { ...process.env, GOFLAGS: '-buildvcs=false', GOPROXY: 'off', GOTOOLCHAIN: 'local', GOWORK: 'off' };
      const r = spawnSync('go', ['build', '-o', built, '.'], { cwd: path.join(ROOT, 'cli'), env, encoding: 'utf8', timeout: 540000 });
      assert.equal(r.status, 0, `go build of the kogen CLI failed (${r.status}): ${r.stdout}${r.stderr}${r.error || ''}`);
    }
    return built;
  };
  const run = (w, args, stdio) => spawnSync(w.bin, args, { cwd: w.repo, env: w.env, encoding: 'utf8', stdio, timeout: 60000 });
  // A command line run by sh on a pseudo-terminal (script), so its standard output and standard error are terminals.
  const onTerminal = (w, line) => {
    const argv = process.platform === 'darwin' ? ['-q', '/dev/null', '/bin/sh', '-c', line] : ['-qec', line, '/dev/null'];
    const r = spawnSync('script', argv, { cwd: w.repo, env: w.env, encoding: 'utf8', stdio: [fs.openSync('/dev/null', 'r'), 'pipe', 'pipe'], timeout: 60000 });
    assert.ok(!r.error, `script could not run: ${r.error}`);
    return r.stdout;
  };
  const inspect = (w, id) => `${quote(w.bin)} intent inspect ${quote(id)}`;
  const fill = (w, text) => text.replaceAll('<checkout id>', w.checkout.id);

  Given(`${P}: a Kogen project checkout and the CLI built from the current sources`, { timeout: 600000 }, function () {
    const bin = binary();
    const repo = scratch('kogen-inspect-repo'), home = scratch('kogen-inspect-home');
    fs.writeFileSync(path.join(home, '.gitconfig'), '');
    const env = { PATH: process.env.PATH, HOME: home, GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig'), GIT_CONFIG_NOSYSTEM: '1' };
    assert.equal(spawnSync('git', ['init', '-q', repo], { env, encoding: 'utf8' }).status, 0, 'git init failed');
    fs.mkdirSync(path.join(repo, '.kogen'));
    fs.writeFileSync(path.join(repo, '.kogen/project.yaml'), 'version: 1\n');
    this.k = { bin, repo, env };
    const ctx = run(this.k, ['context'], ['ignore', 'pipe', 'pipe']);
    const doc = JSON.parse(ctx.stdout);
    assert.equal(ctx.status, 0, `kogen context failed: ${ctx.stdout}${ctx.stderr}`);
    assert.equal(doc.checkout.root, repo, 'the checkout root is the canonical repository path');
    assert.match(doc.checkout.id, /^[0-9a-f]{64}$/, 'the checkout has an identity');
    this.k.checkout = doc.checkout;
  });

  Given(`${P}: a recorded run {string} with the record:`, function (id, record) {
    const file = path.join(this.k.repo, '.kogen/local/facts', `${id}.json`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, fill(this.k, record));
  });

  When(`${P}: I run kogen intent inspect {string} with standard output piped`, function (id) {
    const r = run(this.k, ['intent', 'inspect', id], ['ignore', 'pipe', 'pipe']);
    this.k.result = { code: r.status, stdout: r.stdout, stderr: r.stderr };
  });
  When(`${P}: I run kogen intent inspect {string} with --json and standard output piped`, function (id) {
    const r = run(this.k, ['intent', 'inspect', id, '--json'], ['ignore', 'pipe', 'pipe']);
    this.k.result = { code: r.status, stdout: r.stdout, stderr: r.stderr };
  });
  When(`${P}: I run kogen intent inspect {string} with standard output discarded`, function (id) {
    const r = run(this.k, ['intent', 'inspect', id], ['ignore', 'ignore', 'pipe']);
    this.k.result = { code: r.status, stdout: '', stderr: r.stderr };
  });
  When(`${P}: I run kogen intent inspect {string} on a terminal`, function (id) {
    const t = terminalRun(onTerminal(this.k, `${inspect(this.k, id)}; echo "exit=$?"`));
    this.k.result = { code: t.code, terminal: t.body };
  });
  When(`${P}: I run kogen intent inspect {string} piped to cat on a terminal`, function (id) {
    const t = terminalRun(onTerminal(this.k, `${inspect(this.k, id)} | cat; echo "exit=$?"`));
    this.k.result = { code: t.code, terminal: t.body };
  });

  Then(`${P}: the exit code is {int}`, function (code) { same('exit code', this.k.result.code, code); });
  Then(`${P}: standard error is empty`, function () { same('standard error', this.k.result.stderr, ''); });
  Then(`${P}: standard output is exactly the one JSON line for this checkout with the error:`, function (error) {
    same('standard output', this.k.result.stdout, jsonLine(this.k.checkout, JSON.parse(error)));
  });
  Then(`${P}: standard output is exactly:`, function (text) { same('standard output', this.k.result.stdout, text + '\n'); });
  Then(`${P}: the JSON error is null and the JSON data is:`, function (data) {
    const doc = JSON.parse(this.k.result.stdout);
    assert.deepEqual({ schema_version: doc.schema_version, kind: doc.kind, checkout: doc.checkout, error: doc.error }, { schema_version: 1, kind: 'run', checkout: this.k.checkout, error: null });
    assert.deepEqual(doc.data, JSON.parse(fill(this.k, data)));
  });
  Then(`${P}: the terminal output is the JSON line for this checkout with the error:`, function (error) {
    same('terminal output', this.k.result.terminal, jsonLine(this.k.checkout, JSON.parse(error)));
  });
  Then(`${P}: the terminal output is the JSON line for this checkout with the error, then the line {string}:`, function (sentence, error) {
    same('terminal output', this.k.result.terminal, jsonLine(this.k.checkout, JSON.parse(error)) + sentence + '\n');
  });
  Then(`${P}: the terminal output is exactly:`, function (text) { same('terminal output', this.k.result.terminal, text + '\n'); });
}
