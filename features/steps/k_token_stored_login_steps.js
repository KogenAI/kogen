const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {Given, When, Then, After, AfterAll} = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');

const ROOT = path.resolve(__dirname, '../..');
const FAKE = path.join(ROOT, 'test/acceptance/fixtures/claude/fake-claude.js');
const SCRIPT = path.join(ROOT, 'test/acceptance/fixtures/claude/lineup-shape-questions.json');
const STRIPPED = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'ANTHROPIC_PROFILE', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_PROFILE', 'GOOGLE_APPLICATION_CREDENTIALS', 'ANTHROPIC_FOUNDRY_API_KEY', 'CLAUDE_CODE_EFFORT_LEVEL'];
const INHERITED = 'sk-ant-oat01-SYNTHETIC-INHERITED-TOKEN-0000';
const RUNNER = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
let installed;
async function install() { if (!installed) installed = H.setupSuite(); return (await installed).release; }

function put(p, s, mode) { fs.mkdirSync(path.dirname(p), {recursive: true}); fs.writeFileSync(p, s); if (mode) fs.chmodSync(p, mode); }
function run(file, args, cwd, env, input = '') {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, {cwd, env, detached: true, stdio: ['pipe', 'pipe', 'pipe']});
    let out = '';
    const t = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 180000);
    p.stdout.on('data', b => out += b); p.stderr.on('data', b => out += b);
    p.stdin.on('error', () => {}); p.stdin.end(input);
    p.once('error', e => { clearTimeout(t); reject(e); });
    p.once('close', code => { clearTimeout(t); resolve({code, out}); });
  });
}

// The shim is the `claude` first on PATH. It records the argv and the credential-relevant
// environment of every invocation, answers `auth status --json` itself from the token it
// received (signed in only when that token equals the accepted one), and otherwise runs the
// repository's fake claude with the scripted Shape questions.
const SHIM = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const state = process.env.KT_STATE;
const args = process.argv.slice(2);
const env = {};
for (const [k, v] of Object.entries(process.env)) if (/^(ANTHROPIC_|CLAUDE_|AWS_|GOOGLE_|AZURE_)/.test(k)) env[k] = v;
fs.appendFileSync(path.join(state, 'invocations.jsonl'), JSON.stringify({args, env}) + '\\n');
if (args[0] === 'auth' && args[1] === 'status') {
  const ok = fs.readFileSync(path.join(state, 'accepted'), 'utf8').trim();
  const signedIn = process.env.CLAUDE_CODE_OAUTH_TOKEN === ok && ok !== '';
  process.stdout.write(JSON.stringify(signedIn ? {loggedIn: true, authMethod: 'claude.ai', apiProvider: 'firstParty', subscriptionType: 'max'} : {loggedIn: false, authMethod: 'none', apiProvider: 'firstParty'}) + '\\n');
  process.exit(0);
}
const r = cp.spawnSync(process.execPath, [${JSON.stringify(FAKE)}, ...args], {stdio: 'inherit', env: {...process.env, KOGEN_FAKE_CLAUDE_SCRIPT: ${JSON.stringify(SCRIPT)}, KOGEN_FAKE_CLAUDE_STATE: path.join(state, 'fake')}});
process.exit(r.status === null ? 1 : r.status);
`;

function yaml() {
  return "version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - {name: local-check, run: 'true'}\n  acceptance:\n    run: '" + RUNNER + "'\n    steps_dir: features/steps\nprotect: []\nmodels:\n  shape: {executor: claude-code, model: claude-sonnet-5-5, effort: high}\n  build: {provider: chatgpt, model: gpt-6.1-sol, effort: medium}\n  review: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\nshape_workers:\n  enabled: false\n";
}

async function setup(world, accepted) {
  const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-ktoken-')));
  const home = path.join(d, 'home'), repo = path.join(d, 'repo'), bin = path.join(d, 'bin'), state = path.join(d, 'state');
  for (const x of [home, repo, bin, state]) fs.mkdirSync(x, {recursive: true});
  put(path.join(bin, 'claude'), SHIM, 0o755);
  put(path.join(state, 'accepted'), accepted);
  put(path.join(home, '.gitconfig'), '');
  const env = {...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig'), PATH: bin + path.delimiter + process.env.PATH, KT_STATE: state};
  for (const k of Object.keys(env)) if (/^(ANTHROPIC_|CLAUDE_CODE_|AWS_|GOOGLE_)/.test(k)) delete env[k];
  put(path.join(repo, 'README.md'), '# Fixture\n');
  put(path.join(repo, '.gitignore'), '.kogen/local/\n');
  put(path.join(repo, '.kogen/project.yaml'), yaml());
  put(path.join(repo, 'features/steps/fixture_steps.js'), "const {Then}=require('@cucumber/cucumber');Then('the fixture holds',()=>{});\n");
  put(path.join(d, 'request.md'), 'Preserve the fixture.\n');
  for (const a of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'T'], ['config', 'user.email', 't@example.invalid'], ['add', '.'], ['commit', '-qm', 'baseline']]) {
    const r = await run('git', a, repo, env); assert.equal(r.code, 0, r.out);
  }
  world.kt = {d, home, repo, state, env, bin: await install(), outputs: [], tokens: []};
}
function kt(world) { assert.ok(world.kt, 'no Claude token project'); return world.kt; }
function invocations(world) {
  const f = path.join(kt(world).state, 'invocations.jsonl');
  return fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(Boolean).map(JSON.parse) : [];
}
function credFile(world) { return path.join(kt(world).home, '.kogen/credentials/claude-code.json'); }
function walk(dir, skip, out = []) {
  for (const e of fs.readdirSync(dir, {withFileTypes: true})) {
    const p = path.join(dir, e.name);
    if (skip(p)) continue;
    if (e.isDirectory()) walk(p, skip, out); else if (e.isFile()) out.push(p);
  }
  return out;
}

Given('a Claude Code Shape project whose fake claude accepts the token {string}', {timeout: 240000}, async function (token) { await setup(this, token); this.kt.tokens.push(token); });
Given('the caller environment exports a different CLAUDE_CODE_OAUTH_TOKEN and the other stripped variables', function () {
  const e = kt(this).env;
  e.CLAUDE_CODE_OAUTH_TOKEN = INHERITED;
  for (const k of STRIPPED) e[k] = 'SYNTHETIC_INHERITED_' + k;
  kt(this).tokens.push(INHERITED);
});
When('I save the Claude Code token {string} from stdin', async function (token) {
  const c = kt(this); c.tokens.push(token.trim());
  c.last = await run(c.bin, ['provider', 'login', 'claude-code'], c.repo, c.env, token + '\n'); c.outputs.push(c.last.out);
});
When('I save Claude Code stdin text {string}', async function (text) {
  const c = kt(this);
  c.last = await run(c.bin, ['provider', 'login', 'claude-code'], c.repo, c.env, text.replaceAll('\\n', '\n').replaceAll('\\t', '\t')); c.outputs.push(c.last.out);
});
When('I list the providers', async function () {
  const c = kt(this); c.list = await run(c.bin, ['provider', 'list'], c.repo, c.env); c.outputs.push(c.list.out);
});
When('I run Shape with the Claude Code executor', {timeout: 240000}, async function () {
  const c = kt(this);
  c.last = await run(c.bin, ['intent', 'shape', 'fixture', path.join(c.d, 'request.md')], c.repo, c.env); c.outputs.push(c.last.out);
});

Then('the Claude Code login succeeded and printed none of the saved token', function () {
  const c = kt(this);
  assert.equal(c.last.code, 0, c.last.out);
  for (const t of c.tokens) assert.ok(!c.last.out.includes(t), 'token printed: ' + c.last.out);
});
Then('the Claude Code credential file is private and holds the token {string}', function (token) {
  const f = credFile(this);
  assert.equal(fs.statSync(f).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(f)).mode & 0o777, 0o700);
  assert.ok(fs.readFileSync(f, 'utf8').includes(token));
});
Then('the Claude Code credential file does not hold {string}', function (token) {
  assert.ok(!fs.readFileSync(credFile(this), 'utf8').includes(token));
});
Then('the provider list shows the line {string}', function (line) {
  const c = kt(this);
  assert.equal(c.list.code, 0, c.list.out);
  assert.ok(c.list.out.split('\n').includes(line), c.list.out);
});
Then('the Claude Code login was refused with a message about the token and no credential file exists', function () {
  const c = kt(this);
  assert.notEqual(c.last.code, 0, c.last.out);
  assert.match(c.last.out, /token/i);
  assert.match(c.last.out, /whitespace|empty|blank|single|one/i);
  assert.ok(!fs.existsSync(credFile(this)));
});
Then('every Claude Code child saw the CLAUDE_CODE_OAUTH_TOKEN {string} and none of the other stripped variables', function (token) {
  const calls = invocations(this);
  assert.ok(calls.some(x => x.args[0] === 'auth'), 'no auth status call');
  assert.ok(calls.some(x => x.args[0] === '-p'), 'no run call');
  for (const x of calls.filter(y => y.args[0] === 'auth' || y.args[0] === '-p')) {
    assert.equal(x.env.CLAUDE_CODE_OAUTH_TOKEN, token, JSON.stringify(Object.keys(x.env)));
    for (const k of STRIPPED) assert.equal(x.env[k], undefined, k + ' reached the child');
  }
});
Then('no Claude Code child saw any CLAUDE_CODE_OAUTH_TOKEN', function () {
  const calls = invocations(this);
  assert.ok(calls.some(x => x.args[0] === 'auth'), 'no auth status call');
  for (const x of calls) assert.equal(x.env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
});
Then('the Claude Code run was refused as {string}', function (reason) {
  const c = kt(this);
  assert.notEqual(c.last.code, 0, c.last.out);
  assert.ok(c.last.out.includes(reason), c.last.out);
});
Then('the Claude Code run asked its Shape question', function () {
  const c = kt(this);
  assert.ok(c.last.out.includes('What should is_even do with a non-integer?'), c.last.out);
});
Then('the refusal tells the user to run {string} and {string}', function (a, b) {
  const out = kt(this).last.out;
  assert.ok(out.includes(a) && out.includes(b), out);
});
Then('no Claude Code model round was started', function () {
  assert.ok(!invocations(this).some(x => x.args[0] === '-p'));
});
Then('no Claude Code child argv contained a token', function () {
  const c = kt(this); const all = JSON.stringify(invocations(this).map(x => x.args));
  for (const t of c.tokens) assert.ok(!all.includes(t));
});
Then('no output, log, run record or file outside the credential file holds the token {string}', function (token) {
  const c = kt(this); const cred = credFile(this);
  for (const o of c.outputs) assert.ok(!o.includes(token), 'output leaks token');
  const skip = p => p === cred || p === c.state || p.endsWith('.lock') || p.includes(path.sep + '.git' + path.sep);
  for (const f of [...walk(c.repo, skip), ...walk(c.home, skip)]) {
    assert.ok(!fs.readFileSync(f).includes(token), 'token found in ' + f);
  }
});
When('I read the Claude Code token documentation', function () {
  this.ktDocs = Object.fromEntries(['README.md', 'docs/configuration.md', 'docs/executor-contract.md'].map(f => [f, fs.readFileSync(path.join(ROOT, f), 'utf8')]));
});
Then('every Claude Code token document mentions {string}', function (s) {
  for (const [f, t] of Object.entries(this.ktDocs)) assert.ok(t.includes(s), f + ' lacks: ' + s);
});
Then('the Claude Code token document {string} mentions {string}', function (f, s) {
  assert.ok(this.ktDocs[f].includes(s), f + ' lacks: ' + s);
});

After(function () { if (this.kt) { fs.rmSync(this.kt.d, {recursive: true, force: true}); this.kt = null; } });
AfterAll(function () { if (installed) { const p = installed; installed = null; return p.then(H.cleanupSuite); } });
