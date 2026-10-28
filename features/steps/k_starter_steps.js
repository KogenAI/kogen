'use strict';
// K-STARTER: `kogen starter <dir>` through the installed `kogen` command in temp directories with an empty HOME, a
// scratch global Git configuration and synthetic credentials only. Shaping uses a scripted local provider; no real
// provider, no network beyond 127.0.0.1.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');

let sharedSuite;
const suiteOnce = () => sharedSuite || (sharedSuite = H.setupSuite());
const roots = [];
const servers = [];

async function workspace(w, identity) {
  const suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kstarter-')));
  roots.push(root);
  const home = path.join(root, 'home'), tmp = path.join(root, 'tmp');
  fs.mkdirSync(home); fs.mkdirSync(tmp);
  const gitconfig = path.join(home, '.gitconfig');
  fs.writeFileSync(gitconfig, identity ? '[user]\n\tname = Starter Fixture\n\temail = starter@example.invalid\n[commit]\n\tgpgsign = false\n' : '');
  Object.assign(w, {
    suite, root, home, gitconfig, repo: null, dir: null,
    env: { HOME: home, PATH: suite.path, GIT_CONFIG_GLOBAL: gitconfig, GIT_CONFIG_NOSYSTEM: '1', TMPDIR: tmp },
  });
}

function git(w, args, allowFail) {
  const r = spawnSync('git', ['-C', w.repo, ...args], { encoding: 'utf8', env: { PATH: w.suite.path, HOME: w.home, GIT_CONFIG_GLOBAL: w.gitconfig, GIT_CONFIG_NOSYSTEM: '1' } });
  if (!allowFail) assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stdout}${r.stderr}`);
  return { status: r.status, out: r.stdout.trim() };
}

function snapshot(dir) {
  const entries = [];
  const walk = (d, rel) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = path.join(d, e.name), r = path.join(rel, e.name);
      if (e.isDirectory()) { entries.push(`${r}/`); walk(p, r); } else entries.push(`${r}:${fs.statSync(p).mode}:${H.sha(fs.readFileSync(p))}`);
    }
  };
  walk(dir, '');
  return entries;
}

const read = (w, rel) => fs.readFileSync(path.join(w.repo, rel), 'utf8');
const parseDoctor = out => out.split('\n').flatMap(line => {
  const m = /^(ok|fail|skip) (\S+) - (.*)$/.exec(line);
  if (m) return [{ check: m[2], status: m[1], detail: m[3], fix: '' }];
  return [];
});
function doctorLines(out) {
  const checks = [];
  for (const line of out.split('\n')) {
    const m = /^(ok|fail|skip) (\S+) - (.*)$/.exec(line);
    if (m) { checks.push({ check: m[2], status: m[1], detail: m[3], fix: '' }); continue; }
    const f = /^ {2}fix: (.*)$/.exec(line);
    if (f && checks.length) checks[checks.length - 1].fix = f[1];
  }
  return checks;
}
void parseDoctor;
const doctorLine = (w, name) => {
  const c = doctorLines(w.doctor.out).find(x => x.check === name);
  assert.ok(c, `no ${name} line in: ${w.doctor.out}`);
  return c;
};

Given('a starter workspace with a Git identity', { timeout: 900000 }, async function () { await workspace(this, true); });
Given('a starter workspace without a Git identity', { timeout: 900000 }, async function () { await workspace(this, false); });
Given('a non-empty starter target {string}', function (dir) {
  const full = path.join(this.root, dir);
  fs.mkdirSync(full);
  fs.writeFileSync(path.join(full, 'keep.txt'), 'keep\n');
  this.before = snapshot(full);
});
Given('an empty starter target {string}', function (dir) {
  fs.mkdirSync(path.join(this.root, dir));
  this.before = [];
});

When('I run kogen starter on {string}', { timeout: 300000 }, async function (dir) {
  this.dir = dir;
  this.repo = path.join(this.root, dir);
  const r = await H.run(this.suite.release, ['starter', dir], { cwd: this.root, env: this.env });
  assert.equal(r.timed, false, 'kogen starter timed out');
  this.result = { code: r.code, out: r.out };
});
When('I save a synthetic ChatGPT login for the starter workspace', function () { H.seedCredentials({ home: this.home }); });
When('I run the quick doctor in the starter project', { timeout: 300000 }, async function () {
  const r = await H.run(this.suite.release, ['doctor', '--quick'], { cwd: this.repo, env: this.env });
  assert.equal(r.timed, false, 'doctor timed out');
  this.doctor = { code: r.code, out: r.out };
});
When('I run the full doctor in the starter project', { timeout: 600000 }, async function () {
  const r = await H.run(this.suite.release, ['doctor'], { cwd: this.repo, env: this.env });
  assert.equal(r.timed, false, 'doctor timed out');
  this.doctor = { code: r.code, out: r.out };
});

When('I shape slugify from request.md in the starter with a scripted provider', { timeout: 900000 }, async function () {
  const intentMd = `# Add slugify to the text library

Slug: slugify
Model: not applicable — a pure string function with no state
Acceptance:
- .kogen/intents/slugify/acceptance.feature
- features/steps/slugify_steps.js

Add slugify(text) to lib/text.js, exported next to titleCase: lower-case, runs of non-alphanumeric characters become one hyphen, trimmed at both ends.

## Decisions
- Alphanumeric means ASCII letters and digits. (source: request)

## Source comparison
- addressed: slugify(text) with three examples and two rules; source request.md; contract acceptance.feature.

## Tests
- slugify examples: scenario through the library function (scenario)

## Feasibility
- none
`;
  const feature = 'Feature: slugify\n  Scenario: The three examples\n    Then slugify returns the expected slug for each example\n';
  const step = "const { Then } = require('@cucumber/cucumber');\nconst assert = require('node:assert/strict');\nThen('slugify returns the expected slug for each example', () => {\n  const { slugify } = require('../../lib/text.js');\n  assert.equal(slugify('Hello, World!'), 'hello-world');\n  assert.equal(slugify('  Node.js   &   Kogen  '), 'node-js-kogen');\n  assert.equal(slugify(\"---Rock'n'Roll 101---\"), 'rock-n-roll-101');\n});\n";
  const files = [
    { path: '.kogen/intents/slugify/intent.md', content: intentMd },
    { path: '.kogen/intents/slugify/acceptance.feature', content: feature },
    { path: 'features/steps/slugify_steps.js', content: step },
  ];
  const server = await new H.FakeProvider([
    H.fn('read_file', { path: 'request.md' }),
    H.fn('read_file', { path: '.kogen/project.yaml' }),
    H.fn('submit', { files }),
    H.fn('submit', { files }),
  ]).start();
  servers.push(server);
  this.server = server;
  this.shapeCtx = { suite: this.suite, root: this.root, repo: this.repo, home: this.home, server,
    env: { ...this.env, KOGEN_PROVIDER_URL: `http://127.0.0.1:${server.port}`, KOGEN_AUTH_URL: `http://127.0.0.1:${server.port}` }, started: new Set() };
  this.shape = await H.runKogen(this.shapeCtx, ['intent', 'shape', 'slugify', 'request.md']);
});

Then('the starter exits with status {int}', function (code) { assert.equal(this.result.code, code, this.result.out); });
Then('the starter output is exactly the five next commands for {string}', function (dir) {
  assert.ok(this.result.out.endsWith('\n'), 'output ends with a newline');
  const lines = this.result.out.slice(0, -1).split('\n');
  assert.equal(lines.length, 5, this.result.out);
  assert.equal(lines[0], `cd ${dir}`);
  assert.equal(lines[1], 'kogen doctor');
  assert.equal(lines[2], 'kogen intent shape slugify request.md');
  assert.ok(lines[3].startsWith('kogen intent approve slugify'), lines[3]);
  assert.equal(lines[4], 'kogen intent build slugify');
});
Then('the starter project contains its library, tests, request, README and configuration', function () {
  for (const f of ['lib/text.js', 'test/text.test.js', 'request.md', 'README.md', '.kogen/project.yaml', '.gitignore']) {
    assert.ok(fs.statSync(path.join(this.repo, f)).isFile(), `missing ${f}`);
  }
  const lib = read(this, 'lib/text.js');
  assert.match(lib, /titleCase/);
  assert.doesNotMatch(lib, /slugify/);
  assert.match(read(this, 'test/text.test.js'), /titleCase/);
});
Then('the starter project configuration names the test check and the bundled Cucumber', function () {
  const yaml = read(this, '.kogen/project.yaml');
  assert.ok(yaml.includes('"$KOGEN_NODE" --test'), yaml);
  assert.ok(yaml.includes('$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js'), yaml);
  assert.ok(yaml.includes('features/steps'), yaml);
  assert.ok(yaml.includes('gpt-6.1-sol'), yaml);
});
Then('the starter repository has one commit by the identity, a clean tree and no Git settings written', function () {
  assert.equal(git(this, ['rev-list', '--count', 'HEAD']).out, '1');
  assert.equal(git(this, ['status', '--porcelain', '--untracked-files=all']).out, '');
  assert.equal(git(this, ['log', '-1', '--format=%an <%ae>']).out, 'Starter Fixture <starter@example.invalid>');
  for (const key of ['user.name', 'user.email']) assert.equal(git(this, ['config', '--local', '--get', key], true).status, 1, `local ${key} was written`);
});

Then('the starter doctor exits with status {int}', function (code) { assert.equal(this.doctor.code, code, this.doctor.out); });
Then('the starter doctor line {string} is {string}', function (name, status) { assert.equal(doctorLine(this, name).status, status, this.doctor.out); });
Then('the starter doctor line {string} has a fix containing {string}', function (name, text) { const c = doctorLine(this, name); assert.ok(c.fix.includes(text), `fix: ${JSON.stringify(c.fix)}`); });
Then('the starter doctor line {string} has detail containing {string}', function (name, text) { const c = doctorLine(this, name); assert.ok(c.detail.includes(text), `detail: ${c.detail}`); });
Then('no starter doctor line failed', function () { assert.deepEqual(doctorLines(this.doctor.out).filter(c => c.status === 'fail'), [], this.doctor.out); });

Then('the starter output contains {string}', function (text) { assert.ok(this.result.out.includes(text), this.result.out); });
Then('the starter target is unchanged and has no Git repository', function () {
  assert.deepEqual(snapshot(path.join(this.root, this.dir)), this.before);
  assert.equal(fs.existsSync(path.join(this.root, this.dir, '.git')), false);
});
Then('the starter target does not exist', function () { assert.equal(fs.existsSync(path.join(this.root, this.dir)), false); });

Then('the starter request has exactly the three examples and the two rules', function () {
  const text = read(this, 'request.md');
  const examples = [...text.matchAll(/^- ("(?:[^"\\]|\\.)*") → ("(?:[^"\\]|\\.)*")$/gm)].map(m => [JSON.parse(m[1]), JSON.parse(m[2])]);
  assert.deepEqual(examples, [
    ['Hello, World!', 'hello-world'],
    ['  Node.js   &   Kogen  ', 'node-js-kogen'],
    ["---Rock'n'Roll 101---", 'rock-n-roll-101'],
  ]);
  assert.ok(text.includes('slugify(text)'), 'names slugify(text)');
  assert.match(text, /lower-case/);
  assert.match(text, /hyphen/);
  assert.match(text, /non-alphanumeric/);
  assert.match(text, /trimmed/);
  assert.ok(text.includes('lib/text.js') && text.includes('test/text.test.js'));
});
Then('a reference slugify reproduces every example and wrong variants contradict an example', function () {
  const text = read(this, 'request.md');
  const examples = [...text.matchAll(/^- ("(?:[^"\\]|\\.)*") → ("(?:[^"\\]|\\.)*")$/gm)].map(m => [JSON.parse(m[1]), JSON.parse(m[2])]);
  assert.equal(examples.length, 3);
  const reference = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  const wrong = {
    'no trimming': s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
    'no run collapsing': s => s.toLowerCase().replace(/[^a-z0-9]/g, '-').replace(/^-+|-+$/g, ''),
    'no lower-casing': s => s.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-+|-+$/g, ''),
  };
  for (const [input, output] of examples) assert.equal(reference(input), output, `reference on ${JSON.stringify(input)}`);
  for (const [name, fn] of Object.entries(wrong)) assert.ok(examples.some(([input, output]) => fn(input) !== output), `examples do not contradict: ${name}`);
});
Then('the starter README states the commands and the known result', function () {
  const readme = read(this, 'README.md');
  for (const needle of ['kogen doctor', 'kogen intent shape slugify request.md', 'kogen intent approve slugify', 'kogen intent build slugify', 'slugify("Hello, World!")', '"hello-world"', 'one commit', '--test']) {
    assert.ok(readme.includes(needle), `README lacks ${needle}`);
  }
});

Then('the shaped slugify Intent is ready, can be approved by its hash and the starter still has one commit', { timeout: 600000 }, async function () {
  assert.equal(this.shape.code, 0, `${this.shape.out}\n${JSON.stringify(this.server.toolOutputs())}`);
  for (const f of ['.kogen/intents/slugify/intent.md', '.kogen/intents/slugify/acceptance.feature', 'features/steps/slugify_steps.js']) {
    assert.ok(fs.existsSync(path.join(this.repo, f)), `missing ${f}`);
  }
  const first = this.server.providerRequests()[0];
  assert.ok(H.FakeProvider.inputText(first).includes('slugify(text)'), 'the request text reached the shaper');
  const { card, hash } = await H.approve(this.shapeCtx, 'slugify');
  assert.match(hash, /^[0-9a-f]{64}$/);
  assert.ok(card.includes(hash));
  assert.equal(git(this, ['rev-list', '--count', 'HEAD']).out, '1');
});

After(async function () {
  if (this.server) { await this.server.stop().catch(() => {}); servers.splice(servers.indexOf(this.server), 1); }
  const i = roots.indexOf(this.root);
  if (i >= 0) { fs.rmSync(this.root, { recursive: true, force: true }); roots.splice(i, 1); }
});
AfterAll(async () => {
  for (const r of roots.splice(0)) fs.rmSync(r, { recursive: true, force: true });
  for (const s of servers.splice(0)) await s.stop().catch(() => {});
  if (sharedSuite) { const s = await sharedSuite; sharedSuite = null; H.cleanupSuite(s); }
});
