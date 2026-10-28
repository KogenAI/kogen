'use strict';
// K-ONBOARD: docs/getting-started.md is checked against the real CLI. Commands in the guide are parsed by the installed
// `kogen` through its own help path (`<tokens> --help`: this validates command, subcommand and options and executes
// nothing). Output excerpts (fenced blocks whose info string is `output <step-id>`) are compared with the actual output of
// a scripted run (fake provider, temporary repository, synthetic credentials). `node features/steps/k_onboard_steps.js
// --control good|bad` runs the pure guide checks against a known-good guide and independently mutated bad guides.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const GUIDE = path.join(ROOT, 'docs/getting-started.md');
const README = path.join(ROOT, 'README.md');
const HEADINGS = ['1. Install', '2. Check', '3. Log in', '4. Initialise', '5. Shape', '6. Revise', '7. Approve', '8. Build', '9. Where records live'];
const REQUIRED_PATHS = ['version', 'doctor', 'provider login', 'provider list', 'init', 'intent shape', 'intent refine', 'intent approve', 'intent build', 'intent recover', 'intent resume', 'uninstall'];
const GIT_FIX = "run this inside your project's repository (cd <repo>), or git init to start a new one";
const CONFIG_FIX = 'in your project, run kogen init';
const REQUIRED_TEXT = ['install-kogen.sh', 'packaging/install.sh', 'build_blocked', '.kogen/local/', GIT_FIX, CONFIG_FIX, 'home directory'];
const OUTPUT_COMMAND = {
  version: 'version', 'doctor-outside-repo': 'doctor', 'doctor-before-init': 'doctor', 'provider-list': 'provider list', init: 'init',
  'doctor-after-init': 'doctor', 'shape-questions': 'intent shape', 'shape-ready': 'intent shape', refine: 'intent refine',
  'approve-card': 'intent approve', approve: 'intent approve', build: 'intent build',
};

// ------------------------------------------------------------------ pure guide checks

function scan(text) {
  const fences = [], prose = [];
  let cur = null;
  for (const line of text.split('\n')) {
    const m = /^```(.*)$/.exec(line);
    if (m) { if (cur) { fences.push(cur); cur = null; } else cur = { info: m[1].trim(), lines: [] }; continue; }
    if (cur) cur.lines.push(line); else prose.push(line);
  }
  return { fences, prose };
}
const isOutput = f => /^output(\s|$)/.test(f.info);
function tokensOf(segment) {
  const t = segment.trim().split(/\s+/).slice(1);
  const cut = t.findIndex(x => ['>', '>>', '2>&1', '&&', ';'].includes(x));
  return cut < 0 ? t : t.slice(0, cut);
}
function lineCommands(lines) {
  const found = [];
  for (const l of lines) { const m = /(?:^\s*|\|\s*)(kogen\s[^|#]*)/.exec(l); if (m) found.push(tokensOf(m[1])); }
  return found;
}
function commandsOf(text) {
  const { fences, prose } = scan(text);
  const found = [];
  for (const f of fences) if (!isOutput(f)) found.push(...lineCommands(f.lines));
  for (const l of prose) for (const m of l.matchAll(/`(kogen\s[^`]*)`/g)) found.push(tokensOf(m[1]));
  return found.filter(t => t.length > 0);
}
const cmdPath = t => (t[0] === 'intent' || t[0] === 'provider') ? t.slice(0, 2).join(' ') : (t[0] || '');

function headingProblems(text) {
  const heads = scan(text).prose.filter(l => /^## /.test(l)).map(l => l.slice(3).trim());
  const problems = [];
  let from = 0;
  for (const h of HEADINGS) {
    const at = heads.findIndex((x, i) => i >= from && x.startsWith(h));
    if (at < 0) problems.push(`missing or out of order level-2 heading: ${h}`); else from = at + 1;
  }
  return problems;
}
async function commandProblems(text, validate) {
  const cmds = commandsOf(text);
  const problems = [];
  const seen = new Set();
  for (const t of cmds) {
    const key = t.join(' ');
    if (seen.has(key)) continue;
    seen.add(key);
    const err = await validate(t);
    if (err) problems.push(`kogen ${key}: ${err}`);
  }
  const paths = new Set(cmds.map(cmdPath));
  for (const p of REQUIRED_PATHS) if (!paths.has(p)) problems.push(`no kogen ${p} command in the guide`);
  return problems;
}
const placeholderRe = line => new RegExp('^' + line.trim().split(/(<[A-Za-z][^<>]*>)/).map((p, i) => i % 2 ? '.+' : p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('') + '$');
function outputProblems(text, outputs) {
  const { fences } = scan(text);
  const problems = [];
  const seen = new Set();
  fences.forEach((f, i) => {
    if (!isOutput(f)) return;
    const id = f.info.split(/\s+/)[1];
    if (!id || !Object.hasOwn(OUTPUT_COMMAND, id)) { problems.push(`unknown output step ${JSON.stringify(f.info)}`); return; }
    seen.add(id);
    const prev = fences[i - 1];
    if (!prev || isOutput(prev) || !lineCommands(prev.lines).some(t => cmdPath(t) === OUTPUT_COMMAND[id])) problems.push(`${id}: the block before the output is not a kogen ${OUTPUT_COMMAND[id]} command`);
    const lines = f.lines.map(l => l.trim()).filter(l => l && l !== '...');
    if (!lines.length) problems.push(`${id}: empty output excerpt`);
    const actual = String(outputs[id] ?? '').split('\n').map(l => l.trim());
    for (const l of lines) if (!actual.some(a => placeholderRe(l).test(a))) problems.push(`${id}: excerpt line is not in the actual output: ${l}`);
  });
  for (const id of Object.keys(OUTPUT_COMMAND)) if (!seen.has(id)) problems.push(`no output excerpt for step ${id}`);
  return problems;
}
const contentProblems = text => REQUIRED_TEXT.filter(t => !text.includes(t)).map(t => `the guide does not contain: ${t}`);
function readmeProblems(readme) {
  const at = readme.indexOf('\n## Getting started');
  if (at < 0) return ['README has no Getting started section'];
  const rest = readme.slice(at + 1);
  const end = rest.indexOf('\n## ', 3);
  return (end < 0 ? rest : rest.slice(0, end)).includes('docs/getting-started.md') ? [] : ['README Getting started does not link docs/getting-started.md'];
}

// ------------------------------------------------------------------ the scripted journey

let H, sharedSuite, journeyPromise, journeyCtx;
const helper = () => H || (H = require('./go_driver_support.js'));
const suiteOnce = () => sharedSuite || (sharedSuite = helper().setupSuite());
const dirs = [];

const SLUG = 'greeting';
const DIR = `.kogen/intents/${SLUG}`;
const STEP_FILE = 'features/steps/greeting_steps.js';
const featureText = title => `Feature: ${title}\n  Scenario: The greeting is available\n    Then the greeting is printed\n`;
const packageFiles = () => [
  { path: `${DIR}/intent.md`, content: `# Print the greeting

Slug: ${SLUG}
Model: not applicable — the greeting has no state

Acceptance:
- ${DIR}/acceptance.feature
- ${STEP_FILE}

The application greets with Hello, world.

## Decisions
- Use the wording Hello, world. (source: answer 1)

## Source comparison
- addressed: print the greeting; source request; contract outcome and acceptance.

## Tests
- the greeting is printed: the acceptance scenario (scenario)

## Feasibility
- none
` },
  { path: `${DIR}/acceptance.feature`, content: featureText('Greeting') },
  { path: STEP_FILE, content: "const { Then } = require('@cucumber/cucumber');\nThen('the greeting is printed', () => {});\n" },
];

async function runJourney() {
  const Hh = helper();
  const suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'konboard-')));
  dirs.push(root);
  const repo = path.join(root, 'repo'), home = path.join(root, 'home'), tmp = path.join(root, 'tmp');
  for (const d of [repo, home, tmp]) fs.mkdirSync(d, { recursive: true });
  const globalConfig = path.join(home, '.gitconfig');
  fs.writeFileSync(globalConfig, '');
  const server = await new Hh.FakeProvider([]).start();
  const env = { HOME: home, PATH: suite.path, GIT_CONFIG_GLOBAL: globalConfig, GIT_CONFIG_NOSYSTEM: '1', KOGEN_PROVIDER_URL: `http://127.0.0.1:${server.port}`, KOGEN_AUTH_URL: `http://127.0.0.1:${server.port}`, TMPDIR: tmp };
  const c = { suite, root, repo, home, tmp, env, globalConfig, server, started: new Set() };
  journeyCtx = c;
  const outputs = {};
  const step = async (id, args, expected, options) => {
    const r = await Hh.runKogen(c, args, options);
    outputs[id] = r.out;
    assert.equal(r.code, expected, `${id}: kogen ${args.join(' ')} exited ${r.code}, expected ${expected}:\n${r.out}`);
    return r;
  };
  const identity = ['-c', 'user.name=Kogen Onboard', '-c', 'user.email=onboard@example.invalid', '-c', 'commit.gpgsign=false'];

  await step('version', ['version'], 0);
  await step('doctor-outside-repo', ['doctor'], 1, { cd: home });

  fs.writeFileSync(path.join(repo, 'README.md'), '# Fixture project\n');
  fs.writeFileSync(path.join(repo, 'app.txt'), 'baseline\n');
  await Hh.gitBang(c, ['init', '-q', '--initial-branch=main']);
  await Hh.gitBang(c, ['add', 'README.md', 'app.txt']);
  await Hh.gitBang(c, [...identity, 'commit', '-q', '-m', 'Initial commit']);
  await step('doctor-before-init', ['doctor'], 1);

  await Hh.gitBang(c, ['config', 'user.name', 'Kogen Onboard']);
  await Hh.gitBang(c, ['config', 'user.email', 'onboard@example.invalid']);
  Hh.seedCredentials(c, 'valid');
  await step('provider-list', ['provider', 'list'], 0);

  server.setScript([Hh.fn('submit_configuration', { setup: [], fix: [], checks: [{ name: 'app', run: 'test -f app.txt' }], protect: [] })]);
  await step('init', ['init'], 0);
  await step('doctor-after-init', ['doctor'], 0);

  const request = path.join(root, 'request.md');
  fs.writeFileSync(request, 'Add a greeting to the application.\n');
  server.setScript([Hh.fn('read_file', { path: 'README.md' }), Hh.fn('submit', { questions: [{ question: 'Which greeting wording should the feature use?', options: [{ label: 'Hello, world', recommended: true }, { label: 'Hi there' }] }] })]);
  await step('shape-questions', ['intent', 'shape', SLUG, request], 5);

  const answers = path.join(root, 'answers.txt');
  fs.writeFileSync(answers, '1: a\n');
  server.setScript([Hh.fn('read_file', { path: 'README.md' }), Hh.fn('read_file', { path: 'app.txt' }), Hh.fn('submit', { files: packageFiles() })]);
  await step('shape-ready', ['intent', 'shape', SLUG, answers], 0);

  const hashOf = out => { const m = /SHA-256: ([0-9a-f]{64})/.exec(out); assert.ok(m, `no SHA-256 in: ${out}`); return m[1]; };
  const first = await Hh.runKogen(c, ['intent', 'approve', SLUG]);
  assert.equal(first.code, 5, first.out);
  const correction = path.join(root, 'correction.md');
  fs.writeFileSync(correction, 'Rename the feature to Greeting feature, keeping the scenario and the steps.\n');
  const ft = `${DIR}/acceptance.feature`;
  server.setScript([Hh.fn('read_file', { path: ft }), Hh.fn('submit_refinement', { files: [{ path: ft, content: featureText('Greeting feature') }] })]);
  await step('refine', ['intent', 'refine', SLUG, hashOf(first.out), correction], 0);

  const card = await step('approve-card', ['intent', 'approve', SLUG], 5);
  await step('approve', ['intent', 'approve', SLUG, hashOf(card.out)], 0);

  const before = Number(await Hh.git(c, ['rev-list', '--count', 'HEAD']));
  server.setScript([
    Hh.fn('read_file', { path: 'app.txt' }), Hh.fn('write_file', { path: 'app.txt', content: 'Hello, world\n' }), Hh.fn('finish', { summary: 'Print the greeting' }),
    Hh.fn('read_file', { path: 'app.txt' }), Hh.fn('submit_review', { verdict: 'approve', findings: [] }),
  ]);
  await step('build', ['intent', 'build', SLUG], 0);
  const after = Number(await Hh.git(c, ['rev-list', '--count', 'HEAD']));
  assert.ok(outputs.build.includes(`landed ${SLUG}`), outputs.build);
  assert.equal(after, before + 1, 'the Build makes exactly one commit');
  return { outputs };
}
const journeyOnce = () => journeyPromise || (journeyPromise = runJourney());

async function realValidator() {
  const Hh = helper();
  const suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'konboard-parse-')));
  dirs.push(root);
  const env = { HOME: root, PATH: suite.path };
  return async tokens => {
    const r = await Hh.run(suite.release, [...tokens, '--help'], { cwd: root, env, timeout: 60000 });
    return r.code === 0 ? null : `exit ${r.code}: ${r.out.split('\n')[0]}`;
  };
}

async function doctorRun(kind) {
  const Hh = helper();
  const suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'konboard-doctor-')));
  dirs.push(root);
  const home = path.join(root, 'home'), dir = path.join(root, 'plain');
  for (const d of [home, dir]) fs.mkdirSync(d, { recursive: true });
  const gc = path.join(home, '.gitconfig');
  fs.writeFileSync(gc, '');
  const c = { suite, repo: dir, env: { HOME: home, PATH: suite.path, GIT_CONFIG_GLOBAL: gc, GIT_CONFIG_NOSYSTEM: '1' } };
  if (kind === 'repo') {
    fs.writeFileSync(path.join(dir, 'README.md'), '# Plain\n');
    for (const a of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Kogen Onboard'], ['config', 'user.email', 'onboard@example.invalid'], ['add', 'README.md'], ['commit', '-q', '-m', 'Initial commit']]) await Hh.gitBang(c, a);
  }
  return Hh.runKogen(c, ['doctor']);
}
function doctorLine(out, check) {
  const lines = out.split('\n');
  const at = lines.findIndex(l => new RegExp(`^(ok|fail|skip) ${check} - `).test(l));
  assert.ok(at >= 0, `no ${check} line in: ${out}`);
  return { status: lines[at].split(' ')[0], fix: /^ {2}fix: (.*)$/.exec(lines[at + 1] || '')?.[1] };
}

// ------------------------------------------------------------------ controls

const LEAVES = { version: [], doctor: ['project', 'quick', 'json'], init: [], uninstall: [], 'provider login': [], 'provider list': ['json'], 'intent shape': ['project'], 'intent refine': ['project'], 'intent approve': ['project', 'by'], 'intent build': ['project', 'context'], 'intent recover': ['project', 'output'], 'intent resume': ['project'] };
const stubValidate = async t => {
  const p = cmdPath(t);
  if (!Object.hasOwn(LEAVES, p)) return `unknown command ${p}`;
  for (const x of t) if (x.startsWith('--') && x !== '--help' && !LEAVES[p].includes(x.slice(2).split('=')[0])) return `unknown option ${x}`;
  return null;
};
const STUB_COMMAND = { version: 'kogen version', 'doctor-outside-repo': 'kogen doctor', 'doctor-before-init': 'kogen doctor', 'provider-list': 'kogen provider list', init: 'kogen init', 'doctor-after-init': 'kogen doctor', 'shape-questions': 'kogen intent shape greeting request.md', 'shape-ready': 'kogen intent shape greeting answers.txt', refine: 'kogen intent refine greeting <sha256> correction.md', 'approve-card': 'kogen intent approve greeting', approve: 'kogen intent approve greeting <sha256>', build: 'kogen intent build greeting' };
const stubOutputs = Object.fromEntries(Object.keys(OUTPUT_COMMAND).map(id => [id, `first line of ${id} 0123abcd\n  second line of ${id}\n`]));
function goodGuide() {
  let t = '# Getting started\n\n';
  for (const h of HEADINGS) t += `## ${h}\n\nText.\n\n`;
  for (const id of Object.keys(OUTPUT_COMMAND)) t += `\`\`\`sh\n${STUB_COMMAND[id]}\n\`\`\`\n\n\`\`\`output ${id}\nfirst line of ${id} <hash>\n...\n  second line of ${id}\n\`\`\`\n\n`;
  t += "```sh\nkogen provider login chatgpt   # signs in\nprintf '1: a\\n' | kogen intent shape greeting -\nkogen intent recover <build-id> --output ../archive\nkogen intent resume <build-id>\nkogen uninstall\n```\n\n";
  t += 'Also `kogen doctor --json` and `kogen intent build greeting --project ../repo`.\n\n';
  t += REQUIRED_TEXT.join('\n') + '\n';
  return t;
}
const allProblems = async (text, outputs) => [...headingProblems(text), ...await commandProblems(text, stubValidate), ...outputProblems(text, outputs), ...contentProblems(text)];
const MUTATIONS = [
  t => t.replace('## 2. Check', '## 2x. Check').replace('## 3. Log in', '## 2. Check').replace('## 2x. Check', '## 3. Log in'),
  t => t.replace('## 9. Where records live\n', ''),
  t => t + '```sh\nkogen frobnicate\n```\n',
  t => t + '```sh\nkogen intent build x --detach\n```\n',
  t => t + '\nRun `kogen queue start`.\n',
  t => t.replace(/^kogen intent recover.*\n/m, ''),
  t => t.replace('```output build\n', '```output build\nnot in the run\n'),
  t => t.replace('```output approve\n', '```output bogus\n'),
  t => t.replace(/```output build\n[\s\S]*?```\n/, ''),
  t => t.replace(CONFIG_FIX, ''),
  t => t.replace('kogen version\n```', 'kogen doctor\n```'),
];
const goodReadme = '# Kogen\n\n## Getting started\n\nSee [guide](docs/getting-started.md).\n\n## Specification\n';
async function control(mode) {
  const good = goodGuide();
  const base = await allProblems(good, stubOutputs);
  if (base.length || readmeProblems(goodReadme).length) { console.log('good fixture rejected: ' + base.concat(readmeProblems(goodReadme)).join('; ')); process.exitCode = 2; return; }
  for (const [i, m] of MUTATIONS.entries()) {
    if (!(await allProblems(m(good), stubOutputs)).length) { console.log(`mutation ${i} was accepted`); process.exitCode = 2; return; }
  }
  if (!readmeProblems(goodReadme.replace('docs/getting-started.md', 'docs/other.md')).length) { console.log('README mutation was accepted'); process.exitCode = 2; return; }
  if (mode === 'bad') {
    const bad = MUTATIONS[2](MUTATIONS[6](good));
    const problems = await allProblems(bad, stubOutputs);
    process.stdout.write(problems.length ? 'rejected\n' : 'accepted\n');
    process.exitCode = problems.length ? 1 : 0;
    return;
  }
  process.stdout.write('accepted\n');
}

if (require.main === module) {
  control(process.argv[3]).catch(e => { console.error(e.stack); process.exitCode = 2; });
} else {
  const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
  const guide = () => { assert.ok(fs.existsSync(GUIDE), 'docs/getting-started.md does not exist'); return fs.readFileSync(GUIDE, 'utf8'); };
  const none = problems => assert.deepEqual(problems, []);

  Given('the onboarding guide exists', function () { this.guide = guide(); });
  Then('the guide has the nine step headings in order', function () { none(headingProblems(this.guide)); });
  Then('the guide explains the install, doctor and recovery facts it must cover', function () { none(contentProblems(this.guide)); });
  Then('the README Getting started section links to the guide', function () { none(readmeProblems(fs.readFileSync(README, 'utf8'))); });

  When('the onboarding guide commands are checked against the CLI command table', { timeout: 900000 }, async function () {
    this.commandProblems = await commandProblems(this.guide, await realValidator());
  });
  Then('every kogen command in the guide is a known command with known options', function () {
    none(this.commandProblems.filter(p => !p.startsWith('no kogen ')));
  });
  Then('the guide shows the commands of all nine steps', function () {
    none(this.commandProblems.filter(p => p.startsWith('no kogen ')));
  });

  When('I run the onboarding journey with the fake provider in a temporary repository', { timeout: 1800000 }, async function () {
    this.journey = await journeyOnce();
  });
  Then('every output excerpt in the guide occurs in the actual output of its step', function () {
    none(outputProblems(this.guide, this.journey.outputs));
  });

  When('I run kogen doctor from a directory outside any Git repository', { timeout: 900000 }, async function () { this.doctor = await doctorRun('outside'); });
  When('I run kogen doctor in a Git repository that has no project configuration', { timeout: 900000 }, async function () { this.doctor = await doctorRun('repo'); });
  Then('the onboarding doctor {string} line fails with the fix {string}', function (check, fix) {
    const l = doctorLine(this.doctor.out, check);
    assert.equal(l.status, 'fail', this.doctor.out);
    assert.equal(l.fix, fix, this.doctor.out);
  });
  Then('the onboarding doctor {string} line is {string}', function (check, status) {
    assert.equal(doctorLine(this.doctor.out, check).status, status, this.doctor.out);
  });

  After(function () { this.guide = undefined; });
  AfterAll(async () => {
    if (journeyCtx) { await journeyCtx.server.stop().catch(() => {}); journeyCtx = null; }
    for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true });
    if (sharedSuite) { const s = await sharedSuite; sharedSuite = null; helper().cleanupSuite(s); }
  });
}
