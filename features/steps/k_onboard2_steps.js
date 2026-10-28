'use strict';
// K-ONBOARD2: the getting-started guide must work for a user without ChatGPT. Pure guide checks, the real CLI (`<tokens> --help`
// parses commands and executes nothing) and a scripted run in a temporary repository with only an Anthropic key stored.
// `node features/steps/k_onboard2_steps.js --control good|bad` runs the pure checks against a known-good synthetic guide and
// independently mutated bad guides.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const GUIDE = path.join(ROOT, 'docs/getting-started.md');
const CONFIG_DOC = path.join(ROOT, 'docs/configuration.md');
const PRESET = path.join(ROOT, 'docs/presets/anthropic-only.yaml');
const INIT_ID = 'without-chatgpt-init';
const DOCTOR_ID = 'without-chatgpt-doctor';
const KEY = 'sk-ant-FIXTURE-KEY';
const PRESET_LINES = [
  'version: 1',
  '  shape: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}',
  '  build: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}',
  '  review: {provider: anthropic, model: claude-opus-5-5, effort: medium}',
];

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
const sectionOf = (text, n) => text.split(/\n(?=## )/).find(c => c.startsWith(`## ${n}`)) || '';
function subsectionOf(text) {
  const step4 = sectionOf(text, '4.');
  const i = step4.indexOf('\n### Without ChatGPT');
  if (i < 0) return '';
  const rest = step4.slice(i + 1);
  const j = rest.indexOf('\n### ', 5);
  return j < 0 ? rest : rest.slice(0, j);
}
const fenceOf = (text, info) => scan(text).fences.find(f => f.info === info);

function guideProblems(text) {
  const p = [];
  const need = (where, body, frag) => { if (!body.includes(frag)) p.push(`${where} does not contain: ${frag}`); };
  const s2 = sectionOf(text, '2.'), s3 = sectionOf(text, '3.'), sub = subsectionOf(text);
  need('step 3', s3, 'needs a ChatGPT login');
  need('step 3', s3, 'configuration-first');
  need('step 3', s3, 'step 4');
  if (s2.includes('two lines')) p.push('step 2 still says "two lines"');
  const outside = fenceOf(s2, 'output doctor-outside-repo');
  if (!outside) p.push('step 2 has no doctor-outside-repo excerpt');
  else for (const pre of ['ok install - ', 'fail git - ', 'fail config - ', 'fail models - ', 'skip commands - ']) {
    if (!outside.lines.some(l => l.startsWith(pre))) p.push(`step 2 excerpt has no line starting: ${pre}`);
  }
  if (!sub) { p.push('step 4 has no "### Without ChatGPT" subsection'); return p; }
  for (const f of ['anthropic-only.yaml', '.kogen/project.yaml', 'go mod download', 'go test ./...', 'kogen init', 'kogen doctor', 'kogen provider login anthropic']) need('Without ChatGPT', sub, f);
  const yaml = fenceOf(sub, 'yaml');
  if (!yaml) p.push('Without ChatGPT has no yaml example');
  else {
    const body = yaml.lines.join('\n');
    for (const f of ['version: 1', 'go mod download', 'go test ./...', 'acceptance:', 'steps_dir:', 'KOGEN_ACCEPTANCE_FEATURES', 'provider: anthropic', 'claude-opus-5-5']) need('the yaml example', body, f);
  }
  for (const id of [INIT_ID, DOCTOR_ID]) if (!fenceOf(sub, `text ${id}`)) p.push(`Without ChatGPT has no "text ${id}" excerpt`);
  return p;
}

function kogenCommands(text) {
  const { fences, prose } = scan(text);
  const tok = seg => {
    const t = seg.replace(/\s#.*$/, '').trim().split(/\s+/).slice(1);
    const cut = t.findIndex(x => ['>', '>>', '2>&1', '&&', ';'].includes(x));
    return cut < 0 ? t : t.slice(0, cut);
  };
  const found = [];
  for (const f of fences) if (f.info === 'sh') for (const l of f.lines) { const m = /^\s*(kogen\s.*)$/.exec(l); if (m) found.push(tok(m[1])); }
  for (const l of prose) for (const m of l.matchAll(/`(kogen\s[^`]*)`/g)) found.push(tok(m[1]));
  return found.filter(t => t.length);
}
const cmdPath = t => (t[0] === 'intent' || t[0] === 'provider') ? t.slice(0, 2).join(' ') : (t[0] || '');

const placeholderRe = line => new RegExp('^' + line.trim().split(/(<[A-Za-z][^<>]*>)/).map((x, i) => i % 2 ? '.+' : x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('') + '$');
function excerptProblems(lines, actual) {
  const want = lines.map(l => l.trim()).filter(l => l && l !== '...');
  if (!want.length) return ['empty output excerpt'];
  const act = String(actual).split('\n').map(l => l.trim());
  return want.filter(l => !act.some(a => placeholderRe(l).test(a))).map(l => `excerpt line is not in the actual output: ${l}`);
}

// ------------------------------------------------------------------ controls

const F = '`'.repeat(3);
function goodGuide() {
  return [
    '# Getting started', '',
    '## 2. Check', '',
    F + 'output doctor-outside-repo',
    'ok install - <version>; node, cucumber and quint run',
    'fail git - <directory> is not inside a Git repository',
    '  fix: a',
    'fail config - .kogen/project.yaml is missing',
    '  fix: b',
    'fail models - shape: chatgpt has no stored login',
    '  fix: c',
    'skip commands - skipped: the configuration is not valid',
    F, '',
    '## 3. Log in', '',
    'The automatic discovery of `kogen init` needs a ChatGPT login; otherwise use the configuration-first path in step 4.', '',
    '## 4. Initialise the project', '',
    '### Without ChatGPT', '',
    'Copy anthropic-only.yaml to .kogen/project.yaml, run kogen provider login anthropic, then kogen init and kogen doctor.', '',
    F + 'sh', 'kogen provider login anthropic', 'kogen init', 'kogen doctor', F, '',
    F + 'yaml', 'version: 1', 'commands:', '  setup:', "    - 'go mod download'", '  checks:', "    - {name: test, run: 'go test ./...'}",
    '  acceptance:', '    run: "$KOGEN_ACCEPTANCE_FEATURES"', "    steps_dir: 'features/steps'",
    'models:', '  shape: {provider: anthropic, model: claude-opus-5-5, effort: medium}', F, '',
    F + 'text ' + INIT_ID, 'Initialized Kogen in <repo>', F, '',
    F + 'text ' + DOCTOR_ID, 'ok config - .kogen/project.yaml is valid', F, '',
    '## 5. Shape', '',
  ].join('\n');
}
const MUTATIONS = [
  t => t.replace('needs a ChatGPT login', 'needs a login'),
  t => t.replace('### Without ChatGPT', '### Other'),
  t => t.replace('## 2. Check\n', '## 2. Check\n\nDoctor prints two lines.\n'),
  t => t.replace(/^fail models - .*\n {2}fix: c\n/m, ''),
  t => t.replace('steps_dir:', 'dir:'),
  t => t.replace('text ' + INIT_ID, 'text other'),
  t => t.replace("'go mod download'", "'make'").replace('go mod download', 'make'),
  t => t.replace(/^ok install.*\n/m, ''),
];
function control(mode) {
  const good = goodGuide();
  const base = guideProblems(good);
  if (base.length) { console.log('good fixture rejected: ' + base.join('; ')); process.exitCode = 2; return; }
  for (const [i, m] of MUTATIONS.entries()) {
    if (!guideProblems(m(good)).length) { console.log(`mutation ${i} was accepted`); process.exitCode = 2; return; }
  }
  const actual = 'Initialized Kogen in /tmp/x\nCommit: abc12345 Add Kogen configuration\n';
  if (excerptProblems(['Initialized Kogen in <repo>', 'Commit: <commit> Add Kogen configuration', '...'], actual).length || !excerptProblems(['Commit: <commit> Add Other'], actual).length) {
    console.log('excerpt matcher is wrong'); process.exitCode = 2; return;
  }
  if (mode === 'bad') {
    const problems = guideProblems(MUTATIONS[3](good));
    process.stdout.write(problems.length ? 'rejected\n' : 'accepted\n');
    process.exitCode = problems.length ? 1 : 0;
    return;
  }
  process.stdout.write('accepted\n');
}

// ------------------------------------------------------------------ scripted runs

let H, sharedSuite, journeyPromise;
const helper = () => H || (H = require('./go_driver_support.js'));
const suiteOnce = () => sharedSuite || (sharedSuite = helper().setupSuite());
const dirs = [];

async function newCase(withRepo) {
  const Hh = helper();
  const suite = await suiteOnce();
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'konboard2-')));
  dirs.push(root);
  const repo = path.join(root, 'repo'), home = path.join(root, 'home'), tmp = path.join(root, 'tmp');
  for (const d of [repo, home, tmp]) fs.mkdirSync(d, { recursive: true });
  const globalConfig = path.join(home, '.gitconfig');
  fs.writeFileSync(globalConfig, '');
  const env = { HOME: home, PATH: suite.path, GIT_CONFIG_GLOBAL: globalConfig, GIT_CONFIG_NOSYSTEM: '1', TMPDIR: tmp };
  const c = { suite, root, repo, home, tmp, env, globalConfig, started: new Set() };
  if (withRepo) {
    fs.writeFileSync(path.join(repo, 'README.md'), '# Go fixture\n');
    fs.writeFileSync(path.join(repo, 'go.mod'), 'module example.invalid/fixture\n\ngo 1.21\n');
    fs.writeFileSync(path.join(repo, 'main.go'), 'package main\n\nfunc main() {}\n');
    for (const a of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Kogen Onboard2'], ['config', 'user.email', 'onboard2@example.invalid'], ['config', 'commit.gpgsign', 'false'], ['add', 'README.md', 'go.mod', 'main.go'], ['commit', '-q', '-m', 'Initial commit']]) await Hh.gitBang(c, a);
  }
  return c;
}
const login = async c => {
  const r = await helper().runKogen(c, ['provider', 'login', 'anthropic'], { input: KEY + '\n' });
  assert.equal(r.code, 0, `provider login anthropic: ${r.out}`);
};

async function runJourney(guide) {
  const Hh = helper();
  const c = await newCase(true);
  const outputs = {};
  await login(c);
  const list = await Hh.runKogen(c, ['provider', 'list']);
  assert.equal(list.code, 0, list.out);
  assert.ok(/^anthropic: key saved \(not verified\)$/m.test(list.out), list.out);

  const bare = await Hh.runKogen(c, ['init']);
  assert.notEqual(bare.code, 0, `bare init must fail without ChatGPT: ${bare.out}`);
  assert.ok(bare.out.includes('kogen provider login chatgpt'), bare.out);
  assert.ok(!fs.existsSync(path.join(c.repo, '.kogen/project.yaml')), 'bare init wrote a configuration');

  const yaml = fenceOf(subsectionOf(guide), 'yaml');
  assert.ok(yaml, 'the guide has no yaml example in Without ChatGPT');
  fs.mkdirSync(path.join(c.repo, '.kogen'), { recursive: true });
  fs.copyFileSync(PRESET, path.join(c.repo, '.kogen/project.yaml'));
  const written = yaml.lines.join('\n') + '\n';
  fs.writeFileSync(path.join(c.repo, '.kogen/project.yaml'), written);

  const init = await Hh.runKogen(c, ['init']);
  outputs[INIT_ID] = init.out;
  const doctor = await Hh.runKogen(c, ['doctor']);
  outputs[DOCTOR_ID] = doctor.out;
  const subject = await Hh.git(c, ['log', '-1', '--format=%s']);
  const committed = await Hh.gitBang(c, ['show', 'HEAD:.kogen/project.yaml']);
  const chatgpt = fs.existsSync(path.join(c.home, '.kogen/credentials/chatgpt.json'));
  return { outputs, init, doctor, subject, committed, written, chatgpt };
}
const journeyOnce = guide => journeyPromise || (journeyPromise = runJourney(guide));

if (require.main === module) {
  control(process.argv[3]);
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  const guideText = () => { assert.ok(fs.existsSync(GUIDE), 'docs/getting-started.md does not exist'); return fs.readFileSync(GUIDE, 'utf8'); };
  const none = problems => assert.deepEqual(problems, []);

  Given('the K-ONBOARD2 guide exists', function () { this.guide = guideText(); });
  Then('the guide tells a user without ChatGPT to use the configuration-first path', function () { none(guideProblems(this.guide)); });

  When('the commands of the Without ChatGPT subsection and step 3 are checked against the CLI', { timeout: 900000 }, async function () {
    const Hh = helper();
    const suite = await suiteOnce();
    const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'konboard2-parse-')));
    dirs.push(root);
    const cmds = [...kogenCommands(subsectionOf(this.guide)), ...kogenCommands(sectionOf(this.guide, '3.'))];
    this.cmdPaths = new Set(cmds.map(cmdPath));
    this.cmdProblems = [];
    const seen = new Set();
    for (const t of cmds) {
      const key = t.join(' ');
      if (seen.has(key)) continue;
      seen.add(key);
      const r = await Hh.run(suite.release, [...t, '--help'], { cwd: root, env: { HOME: root, PATH: suite.path }, timeout: 60000 });
      if (r.code !== 0) this.cmdProblems.push(`kogen ${key}: exit ${r.code}: ${r.out.split('\n')[0]}`);
    }
  });
  Then('every kogen command there is a known command with known options', function () {
    none(this.cmdProblems);
    for (const p of ['init', 'doctor', 'provider login']) assert.ok(this.cmdPaths.has(p), `no kogen ${p} command found`);
  });

  When('I run kogen doctor outside any Git repository with no stored login', { timeout: 900000 }, async function () {
    const c = await newCase(false);
    this.outside = await helper().runKogen(c, ['doctor'], { cd: c.home });
    assert.equal(this.outside.code, 1, this.outside.out);
  });
  Then('the step 2 excerpt of the guide occurs in the actual doctor output', function () {
    const f = fenceOf(sectionOf(this.guide, '2.'), 'output doctor-outside-repo');
    assert.ok(f, 'no doctor-outside-repo excerpt in step 2');
    none(excerptProblems(f.lines, this.outside.out));
  });

  When('I follow the Without ChatGPT steps in a temporary Go repository with only an Anthropic key stored', { timeout: 1800000 }, async function () {
    this.journey = await journeyOnce(this.guide);
  });
  Then('kogen init succeeds and commits the configuration as {string}', function (subject) {
    const j = this.journey;
    assert.equal(j.init.code, 0, j.init.out);
    assert.equal(j.subject, subject, j.init.out);
    assert.equal(j.committed, j.written);
    assert.equal(j.chatgpt, false, 'a ChatGPT login exists');
  });
  Then('kogen doctor reports config and models ok', function () {
    const out = this.journey.doctor.out;
    assert.ok(/^ok config - \.kogen\/project\.yaml is valid$/m.test(out), out);
    assert.ok(/^ok models - shape, build, review ready$/m.test(out), out);
    assert.ok(!/^fail (config|models) /m.test(out), out);
  });
  Then('the init and doctor excerpts of the guide occur in the actual output', function () {
    const sub = subsectionOf(this.guide);
    for (const id of [INIT_ID, DOCTOR_ID]) {
      const f = fenceOf(sub, `text ${id}`);
      assert.ok(f, `no text ${id} excerpt`);
      none(excerptProblems(f.lines, this.journey.outputs[id]));
    }
  });

  Given('the anthropic-only preset exists', function () { assert.ok(fs.existsSync(PRESET), 'docs/presets/anthropic-only.yaml does not exist'); this.preset = fs.readFileSync(PRESET, 'utf8'); });
  Then('the preset gives shape and build claude-sonnet-5-5 medium and review claude-opus-5-5 medium on anthropic', function () {
    const lines = this.preset.split('\n');
    for (const l of PRESET_LINES) assert.ok(lines.includes(l), `preset lacks the line: ${l}`);
    assert.equal(lines.filter(l => /provider: /.test(l)).length, 3);
  });
  Then('kogen doctor accepts the preset as the configuration with an Anthropic key', { timeout: 900000 }, async function () {
    const c = await newCase(true);
    await login(c);
    fs.mkdirSync(path.join(c.repo, '.kogen'), { recursive: true });
    fs.copyFileSync(PRESET, path.join(c.repo, '.kogen/project.yaml'));
    const r = await helper().runKogen(c, ['doctor', '--quick']);
    assert.ok(/^ok config - \.kogen\/project\.yaml is valid$/m.test(r.out), r.out);
    assert.ok(/^ok models - shape, build, review ready$/m.test(r.out), r.out);
  });
  Then('the configuration documentation lists the preset with the other presets', function () {
    const text = fs.readFileSync(CONFIG_DOC, 'utf8');
    assert.ok(/\]\(presets\/anthropic-only\.yaml\)/.test(text), 'configuration.md has no link to presets/anthropic-only.yaml');
    assert.ok(text.includes('presets/opencode-go-only.yaml'));
  });

  AfterAll(async () => {
    for (const d of dirs.splice(0)) fs.rmSync(d, { recursive: true, force: true });
    if (sharedSuite) { const s = await sharedSuite; sharedSuite = null; helper().cleanupSuite(s); }
  });
}
