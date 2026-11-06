// Acceptance of k-integrate-pins-20261106t140132z: kogen's qualification on the new component
// tuple, where model roles live only in .kogen/models.yaml and .kogen/local/models.yaml. The
// installed-release steps install the newest dist/kogen-*-<platform>.tar.gz (built by setup's
// `sh packaging/package.sh`) into a fresh HOME and drive the installed kogen.
// Run directly, `node features/steps/k-integrate-pins-20261106t140132z__qualification.js --control good|bad`
// qualifies the observers. good: the named-Go-test observer accepts an existing passing test; the
// claude-code-only drive lands its feature with the installed release; the ChatGPT observer accepts
// the real outputs of the drive's commands after kogen init. bad: the named-Go-test observer
// rejects a test that does not exist; the ChatGPT observer rejects the real output of `kogen
// provider` (its usage page); the models-line observer rejects the real kogen init output of a
// project whose lineup has no login.
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '../..');
const STEP = 110000;
const PREFIX = 'k-integrate-pins-20261106t140132z: ';
const CLAUDE_CODE_VERSION = '2.1.312';
const FAKE_CLAUDE = path.join(root, 'test/acceptance/fixtures/claude/fake-claude.js');

function tail(text) {
  return text.length > 20000 ? '...' + text.slice(-20000) : text;
}

// goEnv is the environment of a go command: the acceptance runner's own variables removed, and
// GOFLAGS=-trimpath as the configured go-test check uses.
function goEnv() {
  const e = { ...process.env, GOFLAGS: '-trimpath' };
  for (const k of ['NODE_PATH', 'KOGEN_ACCEPTANCE_FEATURES', 'KOGEN_ACCEPTANCE_REPORT']) delete e[k];
  return e;
}

function run(dir, command) {
  const r = spawnSync('sh', ['-c', command], { cwd: path.join(root, dir), encoding: 'utf8', env: goEnv(), timeout: STEP - 5000, maxBuffer: 512 * 1024 * 1024 });
  return { status: r.status, error: r.error, out: (r.stdout || '') + (r.stderr || '') };
}

// passes runs the named top-level Go tests ([name, package] pairs) of cli/ in one go test and
// requires that each ran exactly once in its package and passed.
function passes(tests) {
  const names = [...new Set(tests.map(([name]) => name))];
  const pkgs = [...new Set(tests.map(([, pkg]) => pkg))];
  const args = ['test', '-json', '-count=1', '-run', `^(${names.join('|')})$`, ...pkgs];
  const r = spawnSync('go', args, { cwd: path.join(root, 'cli'), encoding: 'utf8', env: goEnv(), timeout: STEP - 5000, maxBuffer: 512 * 1024 * 1024 });
  const rows = (r.stdout || '').split('\n').filter(l => l.startsWith('{')).map(l => { try { return JSON.parse(l); } catch { return {}; } });
  const command = `GOFLAGS=-trimpath go ${args.join(' ')} in cli; exit=${r.status}, error=${r.error || 'none'}`;
  assert(!r.error, `${names.join(', ')}: ${command}\n${tail(r.stderr || '')}`);
  for (const [name, pkg] of tests) {
    const full = pkg === '.' ? 'kogen' : 'kogen/' + pkg.replace(/^\.\//, '');
    const mine = rows.filter(x => x.Test === name && x.Package === full);
    const outcome = mine.filter(x => ['pass', 'fail', 'skip'].includes(x.Action)).map(x => x.Action).join(',') || 'absent (ran zero times)';
    const output = mine.filter(x => x.Action === 'output').map(x => x.Output).join('');
    const diagnostic = `${name} in ${full}: ${command}, outcome=${outcome}\n${tail(output || ((r.stdout || '') + (r.stderr || '')))}`;
    assert.equal(mine.filter(x => x.Action === 'run').length, 1, `${name} did not run exactly once; ${diagnostic}`);
    assert.equal(outcome, 'pass', `${name} did not pass; ${diagnostic}`);
  }
  assert.equal(r.status, 0, `${names.join(', ')}: go test exited nonzero; ${command}\n${tail((r.stdout || '') + (r.stderr || ''))}`);
}

// ---- the installed release in a fresh HOME ----

function platform() {
  const arch = { arm64: 'arm64', x64: 'x86_64' }[process.arch] || process.arch;
  return `${process.platform}-${arch}`;
}

// newestRelease is the newest dist/kogen-*-<platform>.tar.gz of this checkout.
function newestRelease() {
  const dist = path.join(root, 'dist');
  const suffix = `-${platform()}.tar.gz`;
  const names = fs.existsSync(dist) ? fs.readdirSync(dist).filter(n => n.startsWith('kogen-') && n.endsWith(suffix)) : [];
  assert(names.length > 0, `no dist/kogen-*${suffix}; setup runs sh packaging/package.sh`);
  return names.map(n => path.join(dist, n)).sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
}

// freshEnv is the environment of the installed kogen: the fresh HOME, its ~/.local/bin first on
// PATH, no Kogen, provider, Claude or acceptance-runner variable of the host, and Git without the
// host's global or system configuration.
function freshEnv(home) {
  const e = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (/^(KOGEN_|NODE_PATH$|ANTHROPIC_|CLAUDE_|OPENAI_|XAI_|OPENCODE|GIT_)/.test(k)) continue;
    e[k] = v;
  }
  return { ...e, HOME: home, PATH: `${path.join(home, '.local/bin')}:${process.env.PATH}`, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_TERMINAL_PROMPT: '0' };
}

function install(world) {
  const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-kip-')));
  const home = path.join(tmp, 'home');
  const unpacked = path.join(tmp, 'archive');
  fs.mkdirSync(home);
  fs.mkdirSync(unpacked);
  const archive = newestRelease();
  const x = spawnSync('tar', ['-xzf', archive, '-C', unpacked], { encoding: 'utf8' });
  assert.equal(x.status, 0, `tar -xzf ${archive}: ${x.stderr}`);
  const folder = fs.readdirSync(unpacked).find(n => n.startsWith('kogen-'));
  assert(folder, `${archive} holds no kogen-* folder`);
  world.kip = { tmp, home, env: freshEnv(home), outputs: [] };
  const r = cmd(world, unpacked, 'sh', [path.join(unpacked, folder, 'install.sh')]);
  assert.equal(r.status, 0, `install.sh of ${archive}: exit ${r.status}\n${r.out}`);
  world.kip.bin = path.join(home, '.local/bin/kogen');
  assert(fs.existsSync(world.kip.bin), `install.sh did not install ${world.kip.bin}\n${r.out}`);
}

// cmd runs one command in the fresh HOME and records its combined output.
function cmd(world, cwd, file, args, input) {
  const r = spawnSync(file, args, { cwd, env: world.kip.env, input: input || '', encoding: 'utf8', timeout: STEP - 5000, maxBuffer: 64 * 1024 * 1024 });
  const out = (r.stdout || '') + (r.stderr || '');
  const label = `${path.basename(file)} ${args.join(' ')}`;
  world.kip.outputs.push({ label, out });
  assert(!r.error, `${label}: ${r.error}\n${tail(out)}`);
  return { status: r.status, stdout: r.stdout || '', out, label };
}

function kogen(world, args, input) {
  return cmd(world, world.kip.project, world.kip.bin, args, input);
}

function git(world, dir, ...args) {
  const r = cmd(world, dir, 'git', args);
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.out}`);
  return r.stdout.trim();
}

// newProject creates a Git project with one commit of the given files.
function newProject(world, files) {
  const dir = fs.mkdtempSync(path.join(world.kip.tmp, 'project-'));
  git(world, dir, 'init', '-q', '--initial-branch=main');
  git(world, dir, 'config', 'user.name', 'Kogen Acceptance');
  git(world, dir, 'config', 'user.email', 'kogen@example.invalid');
  git(world, dir, 'config', 'commit.gpgsign', 'false');
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  git(world, dir, 'add', '-A');
  git(world, dir, 'commit', '-qm', 'Initial commit');
  world.kip.project = dir;
  return dir;
}

// ---- the claude-code-only lineup: a fake claude that plays init, Shape, Build and Review ----

const SLUG = 'greet';
const intentMD = `# Make the greeting say hello

Slug: ${SLUG}
Model: not applicable — a one-line text change without state
Acceptance:
- .kogen/intents/${SLUG}/acceptance.feature
- features/steps/${SLUG}__steps.js

greeting.txt holds the single line hello instead of hi.

## Decisions
- The greeting is the single line hello. (source: request)

## Tests
- greeting.txt holds hello: the acceptance scenario (scenario)

## Source comparison
- addressed: source request greeting text; contract Decisions, Tests and acceptance.feature.

## Feasibility
- none
`;
const featureText = `Feature: greeting

  Scenario: The greeting says hello
    Given ${SLUG}: the project checkout
    Then ${SLUG}: greeting.txt holds "hello"
`;
const stepsText = `const { Given, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const fs = require('node:fs');

Given('${SLUG}: the project checkout', function () {});
Then('${SLUG}: greeting.txt holds {string}', function (text) {
  assert.equal(fs.readFileSync('greeting.txt', 'utf8').trim(), text);
});
`;
const intentFiles = [
  { path: `.kogen/intents/${SLUG}/intent.md`, content: intentMD },
  { path: `.kogen/intents/${SLUG}/acceptance.feature`, content: featureText },
  { path: `features/steps/${SLUG}__steps.js`, content: stepsText },
];

// The fake's shape role serves init's discovery (invocation 1), then Shape (2) and its
// acknowledgment of the missing-feature red (3).
const claudeScript = {
  roles: {
    shape: { rounds: [
      { actions: [], structured: { setup: [], fix: [], checks: [], protect: [] } },
      { actions: [{ read: 'README.md' }], structured: { files: intentFiles } },
      { actions: [], structured: { files: [intentFiles[1]] } },
    ] },
    build: { rounds: [{ actions: [{ write: { path: 'greeting.txt', content: 'hello\n' } }], claim: 'greeting.txt says hello.' }] },
    review: { rounds: [{ actions: [{ read: 'greeting.txt' }], structured: { verdict: 'approve', findings: [] } }] },
  },
};

function installFakeClaude(world) {
  const state = path.join(world.kip.tmp, 'fake-claude-state');
  fs.mkdirSync(state, { recursive: true });
  const script = path.join(world.kip.tmp, 'fake-claude-script.json');
  fs.writeFileSync(script, JSON.stringify(claudeScript));
  const runtime = path.join(world.kip.home, '.kogen/claude-code', CLAUDE_CODE_VERSION, 'claude');
  fs.mkdirSync(path.dirname(runtime), { recursive: true });
  const q = s => `'${String(s).replaceAll("'", "'\\''")}'`;
  fs.writeFileSync(runtime, `#!/bin/sh\nKOGEN_FAKE_CLAUDE_SCRIPT=${q(script)} KOGEN_FAKE_CLAUDE_STATE=${q(state)} exec ${q(process.execPath)} ${q(FAKE_CLAUDE)} "$@"\n`, { mode: 0o755 });
  world.kip.claudeState = state;
}

function roleCalls(world, role) {
  const file = path.join(world.kip.claudeState, `calls-${role}`);
  return fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8').trim()) : 0;
}

function expectExit(r, code) {
  assert.equal(r.status, code, `${r.label}: exit ${r.status}, want ${code}\n${tail(r.out)}`);
}

// claudeOnlyLandsAFeature: a claude-code login, init, shape, approve and build, in a fresh HOME
// with no other login. It records every command's output; the Then steps judge the readiness line
// and the ChatGPT hints.
function claudeOnlyLandsAFeature(world) {
  const login = cmd(world, world.kip.tmp, world.kip.bin, ['provider', 'login', 'claude-code'], 'fake-claude-code-token-0001\n');
  expectExit(login, 0);
  installFakeClaude(world);
  const project = newProject(world, { 'README.md': '# Greeter\n\nA tiny project: greeting.txt holds the greeting.\n', 'greeting.txt': 'hi\n' });
  const start = git(world, project, 'rev-parse', 'HEAD');

  const init = kogen(world, ['init']);
  expectExit(init, 0);
  world.kip.init = init;
  world.kip.afterInit = world.kip.outputs.length;
  const projectYAML = fs.readFileSync(path.join(project, '.kogen/project.yaml'), 'utf8');
  assert(!/^models\s*:/m.test(projectYAML), `kogen init wrote a models key into .kogen/project.yaml:\n${projectYAML}`);
  const modelsYAML = fs.readFileSync(path.join(project, '.kogen/models.yaml'), 'utf8');
  for (const role of ['shape', 'build', 'review']) {
    const block = modelsYAML.match(new RegExp(`^  ${role}:\\n((?:    .*\\n)+)`, 'm'));
    assert(block && /^    executor: claude-code$/m.test(block[1]), `.kogen/models.yaml has no claude-code ${role} role:\n${modelsYAML}`);
  }
  const committed = git(world, project, 'show', '--name-only', '--format=', 'HEAD').split('\n').filter(p => p.startsWith('.kogen/'));
  assert.deepEqual(committed, ['.kogen/models.yaml', '.kogen/project.yaml'], 'the .kogen files of the kogen init commit');

  const shape = kogen(world, ['intent', 'shape', SLUG, '-'], 'Make greeting.txt say hello instead of hi.\n');
  expectExit(shape, 0);
  const card = kogen(world, ['intent', 'approve', SLUG]);
  const hash = (card.stdout.match(/^SHA-256: ([0-9a-f]{64})$/m) || [])[1];
  assert(card.status === 5 && hash, `kogen intent approve ${SLUG}: exit ${card.status}, no SHA-256 line\n${tail(card.out)}`);
  expectExit(kogen(world, ['intent', 'approve', SLUG, hash]), 0);
  expectExit(kogen(world, ['intent', 'build', SLUG]), 0);

  assert.equal(git(world, project, 'rev-list', '--count', `${start}..HEAD`), '2', 'commits after the start: the kogen init commit and the landed Build');
  assert.equal(git(world, project, 'show', 'HEAD:greeting.txt'), 'hello', 'the landed greeting.txt');
  assert.equal(git(world, project, 'status', '--porcelain', '--untracked-files=no'), '', 'tracked files changed after the Build');
  assert.deepEqual(['shape', 'build', 'review'].map(r => roleCalls(world, r)), [3, 1, 1], 'fake claude invocations of shape (init, Shape, acknowledgment), build and review');
}

// printedLine judges that the recorded command printed the exact stdout line.
function printedLine(r, want) {
  assert(r.stdout.split('\n').includes(want), `${r.label} did not print the line ${JSON.stringify(want)}\n${tail(r.out)}`);
}

// noChatGPTHint judges that no recorded output and no lineup file of the project mentions ChatGPT.
function noChatGPTHint(outputs, project) {
  const found = outputs.filter(o => /chatgpt/i.test(o.out)).map(o => `${o.label}:\n${tail(o.out)}`);
  for (const rel of ['.kogen/project.yaml', '.kogen/models.yaml', '.kogen/local/models.yaml']) {
    const file = path.join(project, rel);
    if (fs.existsSync(file) && /chatgpt/i.test(fs.readFileSync(file, 'utf8'))) found.push(`${rel} mentions chatgpt`);
  }
  assert.deepEqual(found, [], 'a ChatGPT hint appeared');
}

// presetLines runs kogen init in an initialized project whose .kogen/models.yaml is the preset,
// and requires the config line, the models line and the fix line (printed after two spaces).
function presetLines(world, preset, models, fix) {
  newProject(world, { 'README.md': '# Fixture\n', '.gitignore': '.kogen/local/\n', '.kogen/project.yaml': 'version: 1\n', '.kogen/models.yaml': fs.readFileSync(path.join(root, 'docs/presets', preset), 'utf8') });
  const r = kogen(world, ['init']);
  expectExit(r, 0);
  printedLine(r, 'ok config - .kogen/project.yaml is valid');
  printedLine(r, models);
  printedLine(r, `  ${fix}`);
}

// docsWithProjectModels lists the fenced examples of the documentation that hold both the
// project configuration's `version: 1` and a root `models:` key.
function docsWithProjectModels() {
  const files = [path.join(root, 'README.md')];
  const walk = dir => {
    for (const n of fs.readdirSync(dir)) {
      const p = path.join(dir, n);
      if (fs.statSync(p).isDirectory()) walk(p);
      else if (p.endsWith('.md')) files.push(p);
    }
  };
  walk(path.join(root, 'docs'));
  walk(path.join(root, 'spec/prose'));
  const found = [];
  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    for (const m of text.matchAll(/^```[^\n]*\n([\s\S]*?)^```/gm)) {
      if (/^version:\s*1\s*$/m.test(m[1]) && /^models\s*:/m.test(m[1])) found.push(`${path.relative(root, file)}:${text.slice(0, m.index).split('\n').length}`);
    }
  }
  return found;
}

function rejects(f) {
  try { f(); return false; } catch { return true; }
}

if (require.main === module && process.argv[2] === '--control') {
  let ok = false;
  try {
    if (process.argv[3] === 'good') {
      passes([['TestConfigPathAndModelRoles', './consumes/kogen-coordinator']]);
      const world = {};
      install(world);
      claudeOnlyLandsAFeature(world);
      noChatGPTHint(world.kip.outputs.slice(world.kip.afterInit), path.join(world.kip.tmp, 'none'));
      ok = true;
    } else {
      const world = {};
      install(world);
      const help = kogen({ kip: { ...world.kip, project: world.kip.tmp } }, ['provider']);
      newProject(world, { 'README.md': '# Fixture\n', '.gitignore': '.kogen/local/\n', '.kogen/project.yaml': 'version: 1\n', '.kogen/models.yaml': 'models:\n  shape: {provider: supergrok, model: grok-4.7, effort: high}\n' });
      const init = kogen(world, ['init']);
      ok = !(rejects(() => passes([['TestKIntegratePinsNoSuchTest', './consumes/kogen-coordinator']])) &&
        rejects(() => noChatGPTHint([help], world.kip.project)) &&
        rejects(() => printedLine(init, 'ok models - shape, build, review ready')));
    }
  } catch {
    ok = false;
  }
  console.log(ok ? 'observer accepted' : 'observer rejected');
  if (!ok) process.exitCode = 1;
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');

  Then(PREFIX + 'these Go tests pass in one run:', { timeout: STEP }, function (table) {
    passes(table.rows());
  });

  Then(PREFIX + 'the cli module resolves the components:', { timeout: STEP }, function (table) {
    for (const [module, version] of table.rows()) {
      const r = run('cli', `go list -m -f '{{.Path}} {{.Version}}{{with .Replace}} => {{.Path}}{{end}}' ${module}`);
      assert.equal(r.status, 0, `go list -m ${module} in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
      assert.equal(r.out.trim(), `${module} ${version}`, `go list -m ${module} in cli`);
    }
  });

  Then(PREFIX + 'the loop pin names module {string} at source head {string}', function (module, head) {
    const pin = JSON.parse(fs.readFileSync(path.join(root, 'cli/loop-pin.json'), 'utf8'));
    assert.equal(pin.module, module, 'cli/loop-pin.json module');
    assert.equal(pin.source_head, head, 'cli/loop-pin.json source_head');
  });

  Then(PREFIX + 'gofmt lists no file in cli', { timeout: STEP }, function () {
    const r = run('cli', 'gofmt -l .');
    assert.equal(r.status, 0, `gofmt -l . in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
    assert.equal(r.out, '', 'gofmt -l . in cli lists unformatted files');
  });

  Then(PREFIX + '{string} in {string} succeeds', { timeout: STEP }, function (command, dir) {
    const r = run(dir, command);
    assert(!r.error && r.status === 0, `${command} in ${dir}: exit=${r.status}, error=${r.error || 'none'}\n${tail(r.out)}`);
  });

  Given(PREFIX + 'the release built from this checkout is installed in a fresh home', { timeout: STEP }, function () {
    install(this);
  });

  When(PREFIX + 'a claude-code login alone inits, shapes, approves and builds a feature that lands', { timeout: STEP }, function () {
    claudeOnlyLandsAFeature(this);
  });

  Then(PREFIX + 'kogen init printed the line {string}', function (want) {
    printedLine(this.kip.init, want);
  });

  Then(PREFIX + 'no output and no lineup file mentions ChatGPT', function () {
    noChatGPTHint(this.kip.outputs, this.kip.project);
  });

  Then(PREFIX + 'kogen init in an initialized project whose team models file is each preset prints its models and fix lines:', { timeout: STEP }, function (table) {
    for (const [preset, models, fix] of table.rows()) presetLines(this, preset, models, fix);
  });

  Given(PREFIX + 'an initialized project with these files:', { timeout: STEP }, function (docString) {
    const files = { 'README.md': '# Fixture\n', '.gitignore': '.kogen/local/\n', '.kogen/project.yaml': 'version: 1\n' };
    for (const block of docString.split(/^=== /m).filter(Boolean)) {
      const nl = block.indexOf('\n');
      files[block.slice(0, nl).trim()] = block.slice(nl + 1).replace(/\n*$/, '\n');
    }
    newProject(this, files);
  });

  When(PREFIX + 'kogen init runs in the project', { timeout: STEP }, function () {
    this.kip.last = kogen(this, ['init']);
  });

  Then(PREFIX + 'kogen init exits {int} and prints the lines:', function (code, docString) {
    expectExit(this.kip.last, code);
    for (const want of docString.split('\n')) printedLine(this.kip.last, want);
  });

  Then(PREFIX + 'no fenced example in README.md, docs or the spec prose sets both version 1 and a root models key', function () {
    assert.deepEqual(docsWithProjectModels(), [], 'documentation examples of .kogen/project.yaml with a models key');
  });
}
