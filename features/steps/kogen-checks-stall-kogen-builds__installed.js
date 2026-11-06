// Acceptance of kogen-checks-stall-kogen-builds: kogen's installed-binary Go tests are hermetic and
// package one release per package test run. Every Go run happens in a scratch copy of this checkout
// under the system temporary directory; the first step starts them all together and each scenario
// awaits its own. Run directly,
// `node features/steps/kogen-checks-stall-kogen-builds__installed.js --control good|bad`
// qualifies the observers on real runs: good inputs must be accepted, bad ones rejected.
'use strict';
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const STEP = 115000;
const LOGIN = 'TestInstalledKeyLoginUnderPipesAndATerminal';
const PROVIDERS = ['opencode-go', 'anthropic', 'openai-compatible'];
const LOGIN_TESTS = [LOGIN, ...PROVIDERS.flatMap(p => [`${LOGIN}/${p}_piped_invalid_UTF-8`, `${LOGIN}/${p}_terminal`])];
// The deliberately broken login: piped invalid UTF-8 is saved as a replacement key (exit 0) and the
// terminal state is never restored after the key is read.
const LOGIN_REGRESSION = PROVIDERS.flatMap(p => [
  [`${LOGIN}/${p}_piped_invalid_UTF-8`, `${p}: key saved (not verified)`],
  [`${LOGIN}/${p}_terminal`, 'terminal was not restored'],
]);

let scratch;
const children = new Set();
function scratchDir() {
  if (!scratch) {
    scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'kcskb-'));
    process.on('exit', () => {
      for (const child of children) try { child.kill('SIGKILL'); } catch {}
      try { fs.rmSync(scratch, { recursive: true, force: true }); } catch {}
    });
  }
  return scratch;
}

function tail(text) {
  return text.length > 12000 ? '...' + text.slice(-12000) : text;
}

// mutate replaces the one occurrence of from in a scratch copy's file; a missing anchor is a broken
// fixture, not product red.
function mutate(dir, file, from, to) {
  const p = path.join(dir, file);
  const text = fs.readFileSync(p, 'utf8');
  const n = text.split(from).length - 1;
  if (n !== 1) throw new Error(`broken fixture: ${file} holds ${n} copies of ${JSON.stringify(from)}, want 1`);
  fs.writeFileSync(p, text.replace(from, () => to));
}

// tree is a scratch copy of this checkout without .git, dist, node_modules or .kogen/local:
// clean, broken (login custody and resume regressions) or stale (packaging ships stale testing rules).
const trees = {};
function tree(kind) {
  if (trees[kind]) return trees[kind];
  const dest = path.join(scratchDir(), kind);
  fs.cpSync(root, dest, {
    recursive: true,
    filter: src => {
      const rel = path.relative(root, src);
      const parts = rel.split(path.sep);
      return !parts.includes('node_modules') && !['.git', 'dist'].includes(parts[0]) && rel !== path.join('.kogen', 'local');
    },
  });
  if (kind === 'broken') {
    const keys = 'cli/third_party/kogen-loop/provider/keys.go';
    mutate(dest, keys, '\t\tdefer stty(strings.TrimSpace(state))\n', '\t\t_ = state\n');
    mutate(dest, keys, 'utf8.Valid(r.data), false, nil', 'true, false, nil');
    mutate(dest, keys, 'key := strings.TrimFunc(value, unicode.IsSpace)', 'key := strings.ToValidUTF8(strings.TrimFunc(value, unicode.IsSpace), "\\uFFFD")');
    mutate(dest, 'cli/main.go', 'func main() {\n', 'func main() {\n\tif len(os.Args) > 2 && os.Args[1] == "intent" && os.Args[2] == "resume" {\n\t\tos.Stdout.WriteString("synthetic resume regression\\n")\n\t\tos.Exit(1)\n\t}\n');
  }
  if (kind === 'stale') {
    mutate(dest, 'packaging/package.sh', 'mkdir -p "$work/docs" && cp docs/testing-rules.md docs/configuration.md "$work/docs/"', 'mkdir -p "$work/docs" && cp docs/configuration.md "$work/docs/" && printf \'stale testing rules\\n\' > "$work/docs/testing-rules.md"');
  }
  return (trees[kind] = dest);
}

// baseEnv is a child's environment: the acceptance runner's own variables removed, and
// GOFLAGS=-trimpath as the configured go-test check uses.
function baseEnv() {
  const env = { ...process.env, GOFLAGS: '-trimpath' };
  for (const k of ['NODE_PATH', 'KOGEN_ACCEPTANCE_FEATURES', 'KOGEN_ACCEPTANCE_REPORT']) delete env[k];
  return env;
}

// startProxy is a local HTTP proxy that refuses every request and CONNECT tunnel with 403 and
// records the host each one asked for.
function startProxy() {
  const hosts = [];
  const server = http.createServer((req, res) => {
    hosts.push(req.headers.host || req.url);
    res.writeHead(403);
    res.end('blocked by the acceptance proxy\n');
  });
  server.on('connect', (req, socket) => {
    hosts.push(req.url);
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => {
    server.unref();
    resolve({ hosts, url: `http://127.0.0.1:${server.address().port}` });
  }));
}

// blocked is an environment whose HTTP(S) traffic goes to a refusing proxy. With fake set, python3
// and python on PATH are a toolchain shim that, like the rate-limited one, fails with GitHub's 403.
async function blocked(name, fake) {
  const dir = fs.mkdtempSync(path.join(scratchDir(), name + '-'));
  const proxy = await startProxy();
  const env = baseEnv();
  delete env.NO_PROXY;
  delete env.no_proxy;
  for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']) env[k] = proxy.url;
  const interpreters = path.join(dir, 'interpreters.log');
  fs.writeFileSync(interpreters, '');
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  for (const name of ['python3', 'python']) {
    fs.writeFileSync(path.join(bin, name), `#!/bin/sh\nprintf '%s\\n' "$0 $*" >> '${interpreters}'\necho 'mise ERROR failed to install core:python@3.13.16: GitHub artifact attestations: 403 API rate limit exceeded' >&2\nexit 1\n`, { mode: 0o755 });
  }
  if (fake) env.PATH = bin + path.delimiter + env.PATH;
  return { env, proxy, interpreters, fakeBin: bin };
}

// counted is an environment whose npm records every invocation (directory and arguments) before
// running the real npm: packaging/package.sh runs `npm ci` in lib/quint once per release it packages.
function counted(name) {
  const dir = fs.mkdtempSync(path.join(scratchDir(), name + '-'));
  const env = baseEnv();
  const which = spawnSync('sh', ['-c', 'command -v npm'], { env, encoding: 'utf8' });
  const real = (which.stdout || '').trim();
  if (which.status !== 0 || !real) throw new Error(`npm is not on PATH: ${which.stderr || ''}`);
  const npmLog = path.join(dir, 'npm.log');
  fs.writeFileSync(npmLog, '');
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'npm'), `#!/bin/sh\nprintf '%s %s\\n' "$PWD" "$*" >> '${npmLog}'\nexec '${real}' "$@"\n`, { mode: 0o755 });
  env.PATH = bin + path.delimiter + env.PATH;
  return { env, npmLog };
}

// goTest runs `go test -json` in a scratch copy's cli module.
function goTest(copy, args, env) {
  const argv = ['test', '-json', '-timeout=105s', ...args];
  const cwd = path.join(copy, 'cli');
  const command = `cd ${cwd} && GOFLAGS=-trimpath go ${argv.join(' ')}`;
  return new Promise(resolve => {
    let out = '';
    let err = '';
    let done = false;
    const finish = (status, signal, error) => {
      if (done) return;
      done = true;
      children.delete(child);
      const events = out.split('\n').filter(l => l.startsWith('{')).map(l => { try { return JSON.parse(l); } catch { return {}; } });
      const plain = out.split('\n').filter(l => !l.startsWith('{')).join('\n');
      resolve({ command, status, signal, error, events, plain: plain + err });
    };
    const child = spawn('go', argv, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
    children.add(child);
    child.stdout.on('data', d => { out += d; });
    child.stderr.on('data', d => { err += d; });
    child.on('error', e => finish(null, null, e));
    child.on('close', (status, signal) => finish(status, signal, null));
  });
}

function describe(run) {
  return `command: ${run.command}; exit=${run.status} signal=${run.signal || 'none'} error=${run.error || 'none'}${run.plain.trim() ? '\n' + tail(run.plain) : ''}`;
}
function actions(run, test) {
  return run.events.filter(e => e.Test === test && ['run', 'pass', 'fail', 'skip'].includes(e.Action)).map(e => e.Action);
}
function output(run, test) {
  return run.events.filter(e => e.Test === test && e.Action === 'output').map(e => e.Output).join('');
}

// passed requires each named test to have run and passed every time it ran.
function passed(run, tests) {
  for (const test of tests) {
    const acts = actions(run, test);
    const runs = acts.filter(a => a === 'run').length;
    if (runs === 0) throw new Error(`required test ${test} is absent or ran zero times; ${describe(run)}`);
    const passes = acts.filter(a => a === 'pass').length;
    if (passes !== runs) {
      const how = acts.includes('skip') ? 'was skipped' : acts.includes('fail') ? 'failed' : 'did not finish';
      throw new Error(`required test ${test} ${how} (ran ${runs}, passed ${passes}); ${describe(run)}\n${tail(output(run, test))}`);
    }
  }
}

// failedWith requires each named test to have run and failed, its output containing the text.
function failedWith(run, rows) {
  for (const [test, text] of rows) {
    const acts = actions(run, test);
    if (!acts.includes('run')) throw new Error(`required test ${test} is absent or ran zero times; ${describe(run)}`);
    const got = output(run, test);
    if (acts[acts.length - 1] !== 'fail') throw new Error(`required test ${test} did not fail (actions ${acts.join(',')}); want a failure containing ${JSON.stringify(text)}; ${describe(run)}\n${tail(got)}`);
    if (!got.includes(text)) throw new Error(`required test ${test} failed without ${JSON.stringify(text)} in its output; ${describe(run)}\n${tail(got)}`);
  }
}

// packagedOnce requires exactly one `npm ci` in lib/quint, i.e. one packaged release, in the run.
function packagedOnce(run) {
  const lines = fs.readFileSync(run.npmLog, 'utf8').split('\n').filter(Boolean);
  const releases = lines.filter(l => /\/lib\/quint ci( |$)/.test(l)).length;
  if (releases !== 1) throw new Error(`the run packaged ${releases} releases (npm ci in lib/quint ${releases} times), want exactly 1 per package test run; npm calls:\n${lines.join('\n')}\n${describe(run)}`);
}

function noInterpreter(run) {
  const calls = fs.readFileSync(run.interpreters, 'utf8');
  if (calls) throw new Error(`the run started a python interpreter from PATH, the toolchain lookup that reaches GitHub:\n${calls}${describe(run)}`);
}

function noGitHub(run) {
  const github = run.proxy.hosts.filter(h => /(^|[./])github(usercontent)?\.com(:\d+)?(\/|$)/i.test(h));
  if (github.length) throw new Error(`the run asked the proxy for GitHub: ${github.join(', ')}; ${describe(run)}`);
}

async function loginRun(kind, fake) {
  const b = await blocked(`login-${kind}`, fake);
  const run = await goTest(tree(kind), ['-count=1', '-run', `^${LOGIN}$`, '.'], b.env);
  return { ...run, ...b };
}
async function packagingRun(kind, name, args) {
  const c = counted(name);
  const run = await goTest(tree(kind), args, c.env);
  return { ...run, ...c };
}

const RUNS = {
  'hermetic login': () => loginRun('clean', true),
  'login regression': () => loginRun('broken', true),
  'cli shared release': () => packagingRun('clean', 'cli', ['-count=1', '-run', '^(TestAssemblyUsesThePinnedComponents|TestUsageLimitPackagingIsolationRound2)$', '.']),
  'buildprogram shared release': () => packagingRun('clean', 'buildprogram', ['-count=1', '-run', '^(TestBaselinePerBaseInstalled|TestBaselinePackagingIsolation)$', './buildprogram']),
  'resume regression': () => packagingRun('broken', 'resume', ['-count=1', '-run', '^(TestAssemblyUsesThePinnedComponents|TestUsageLimitResumeInstalledRound2)$', '.']),
  'stale packaging': () => packagingRun('stale', 'stale', ['-count=1', '-run', '^(TestBaselinePerBaseInstalled|TestBaselinePackagingIsolation)$', './buildprogram']),
};
let started;
function startAll() {
  if (!started) {
    started = {};
    for (const [name, start] of Object.entries(RUNS)) started[name] = Promise.resolve().then(start).catch(error => ({ failure: error }));
  }
}

// control qualifies the observers on real runs of the unchanged tree and synthetic proxy/PATH hits.
async function control(mode) {
  const settle = p => p.then(() => null, e => e);
  if (mode === 'good') {
    const results = await Promise.all([
      settle(loginRun('clean', false).then(run => { passed(run, LOGIN_TESTS); noInterpreter(run); noGitHub(run); })),
      settle(loginRun('broken', false).then(run => { failedWith(run, LOGIN_REGRESSION); noGitHub(run); })),
      settle(packagingRun('clean', 'good', ['-count=1', '-run', '^TestAssemblyUsesThePinnedComponents$', '.']).then(run => { passed(run, ['TestAssemblyUsesThePinnedComponents']); packagedOnce(run); })),
    ]);
    const errors = results.filter(Boolean);
    if (errors.length) { console.log(errors.map(e => e.stack || String(e)).join('\n\n')); return 2; }
    console.log('accepted');
    return 0;
  }
  if (mode === 'bad') {
    const rejects = (label, p) => p.then(() => `accepted bad input: ${label}`, () => null);
    const results = await Promise.all([
      rejects('GitHub request through the proxy', blocked('bad-proxy', true).then(async b => {
        await new Promise((resolve, reject) => {
          const u = new URL(b.proxy.url);
          const req = http.request({ host: u.hostname, port: u.port, method: 'CONNECT', path: 'api.github.com:443' });
          req.on('connect', res => { res.destroy(); resolve(); });
          req.on('error', reject);
          req.end();
        });
        noGitHub({ ...b, command: 'CONNECT api.github.com:443', status: null, plain: '' });
      })),
      rejects('python from PATH', blocked('bad-python', true).then(b => {
        spawnSync('python3', ['-c', 'pass'], { env: b.env });
        noInterpreter({ ...b, command: 'python3 -c pass', status: null, plain: '' });
      })),
      rejects('unbroken login judged as a regression', loginRun('clean', false).then(run => failedWith(run, LOGIN_REGRESSION))),
      rejects('two package test runs judged as one', (async () => {
        const c = counted('bad-count');
        const args = ['-count=1', '-run', '^TestAssemblyUsesThePinnedComponents$', '.'];
        const first = await goTest(tree('clean'), args, c.env);
        passed(first, ['TestAssemblyUsesThePinnedComponents']);
        const second = await goTest(tree('clean'), args, c.env);
        passed(second, ['TestAssemblyUsesThePinnedComponents']);
        packagedOnce({ ...second, ...c });
      })()),
    ]);
    const accepted = results.filter(Boolean);
    if (accepted.length) { console.log(accepted.join('\n')); return 3; }
    console.log('rejected');
    return 1;
  }
  console.log('usage: --control good|bad');
  return 64;
}

if (require.main === module) {
  const i = process.argv.indexOf('--control');
  control(i > 0 ? process.argv[i + 1] : '').then(code => process.exit(code), e => { console.log(e.stack || String(e)); process.exit(70); });
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  const P = 'kogen-checks-stall-kogen-builds: ';
  let current;
  Given(P + 'the installed-test runs have started in scratch copies of this checkout', function () {
    startAll();
  });
  When(P + 'the {string} run finishes', { timeout: STEP }, async function (name) {
    if (!started || !started[name]) throw new Error(`no run named ${name}; runs: ${Object.keys(RUNS).join(', ')}`);
    current = await started[name];
    if (current.failure) throw current.failure;
  });
  Then(P + 'the run passed these Go tests:', function (table) {
    passed(current, table.raw().slice(1).map(row => row[0]));
  });
  Then(P + 'the run failed these Go tests, each output containing its text:', function (table) {
    failedWith(current, table.raw().slice(1));
  });
  Then(P + 'the run packaged exactly one release', function () {
    packagedOnce(current);
  });
  Then(P + 'the run started no python interpreter from PATH', function () {
    noInterpreter(current);
  });
  Then(P + 'the run asked its proxy for no GitHub host', function () {
    noGitHub(current);
  });
}
