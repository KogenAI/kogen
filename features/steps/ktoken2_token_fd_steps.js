const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn} = require('node:child_process');
const {Given, When, Then, After, AfterAll} = require('@cucumber/cucumber');
const H = require('./go_driver_support.js');
const O = require('./ktoken2_observe.js');

const ROOT = path.resolve(__dirname, '../..');
const FAKE = path.join(ROOT, 'test/acceptance/fixtures/claude/fake-claude.js');
const INHERITED = 'sk-ant-oat01-SYNTHETIC-INHERITED-TOKEN-0000';
const SENTINELS = ['SYNTHETIC-INHERITED', 'SYNTHETIC_INHERITED'];
const RUNNER = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
// The shaper's output names another slug than the one requested, so Kogen rejects it and sends
// feedback in --resume rounds of the same session.
const SCRIPT = {roles: {shape: {rounds: [{actions: [], structured_intent: {name: 'is-even'}}]}}};
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

// POSIX-sh shim, the `claude` first on PATH. For `auth status` and `-p` it records argv, the
// credential-relevant environment and, if fd 3 is open, everything readable from fd 3. It
// answers `auth status --json` itself (signed in only when fd 3 held the accepted token) and
// otherwise runs the repository's fake claude.
const SHIM = [
  '#!/bin/sh',
  'state="$KT_STATE"',
  'if [ "$1" = auth ] || [ "$1" = -p ]; then',
  '  mkdir -p "$state/inv"',
  '  n=$(ls "$state/inv" | wc -l | tr -d " ")',
  '  d="$state/inv/$n"; mkdir "$d"',
  '  printf "%s\\n" "$@" > "$d/args"',
  '  env | grep -E "^(ANTHROPIC_|CLAUDE_|AWS_|GOOGLE_|AZURE_)" > "$d/env"',
  '  if ( : <&3 ) 2>/dev/null; then cat <&3 > "$d/fd3"; fi',
  'fi',
  'if [ "$1" = auth ]; then',
  '  if [ -f "$d/fd3" ] && [ "$(cat "$d/fd3")" = "$(cat "$state/accepted")" ]; then',
  '    echo \'{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}\'',
  '  else',
  '    echo \'{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}\'',
  '  fi',
  '  exit 0',
  'fi',
  'exec ' + JSON.stringify(process.execPath) + ' ' + JSON.stringify(FAKE) + ' "$@"',
  '',
].join('\n');

function yaml() {
  return "version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - {name: local-check, run: 'true'}\n  acceptance:\n    run: '" + RUNNER + "'\n    steps_dir: features/steps\nprotect: []\nmodels:\n  shape: {executor: claude-code, model: claude-sonnet-5-5, effort: high}\n  build: {provider: chatgpt, model: gpt-6.1-sol, effort: medium}\n  review: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\nshape_workers:\n  enabled: false\n";
}

async function setup(world, accepted) {
  const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-ktoken2-')));
  const home = path.join(d, 'home'), repo = path.join(d, 'repo'), bin = path.join(d, 'bin'), state = path.join(d, 'state');
  for (const x of [home, repo, bin, state]) fs.mkdirSync(x, {recursive: true});
  put(path.join(bin, 'claude'), SHIM, 0o755);
  put(path.join(state, 'accepted'), accepted);
  put(path.join(state, 'script.json'), JSON.stringify(SCRIPT));
  put(path.join(home, '.gitconfig'), '');
  const env = {...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig'), PATH: bin + path.delimiter + process.env.PATH, KT_STATE: state, KOGEN_FAKE_CLAUDE_SCRIPT: path.join(state, 'script.json'), KOGEN_FAKE_CLAUDE_STATE: path.join(state, 'fake')};
  for (const k of Object.keys(env)) if (/^(ANTHROPIC_|CLAUDE_CODE_|AWS_|GOOGLE_)/.test(k)) delete env[k];
  put(path.join(repo, 'README.md'), '# Fixture\n');
  put(path.join(repo, '.gitignore'), '.kogen/local/\n');
  put(path.join(repo, '.kogen/project.yaml'), yaml());
  put(path.join(repo, 'features/steps/fixture_steps.js'), "const {Then}=require('@cucumber/cucumber');Then('the fixture holds',()=>{});\n");
  put(path.join(d, 'request.md'), 'Preserve the fixture.\n');
  for (const a of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'T'], ['config', 'user.email', 't@example.invalid'], ['add', '.'], ['commit', '-qm', 'baseline']]) {
    const r = await run('git', a, repo, env); assert.equal(r.code, 0, r.out);
  }
  world.k2 = {d, home, repo, state, env, bin: await install(), outputs: [], token: null};
}
function k2(world) { assert.ok(world.k2, 'no fd 3 token project'); return world.k2; }
function calls(world) {
  const dir = path.join(k2(world).state, 'inv');
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir).sort((a, b) => Number(a) - Number(b)).map(n => {
    const p = path.join(dir, n);
    const env = {};
    if (fs.existsSync(p + '/env')) for (const line of fs.readFileSync(p + '/env', 'utf8').split('\n').filter(Boolean)) { const i = line.indexOf('='); env[line.slice(0, i)] = line.slice(i + 1); }
    return {args: fs.readFileSync(p + '/args', 'utf8').split('\n').slice(0, -1), env, fd3: fs.existsSync(p + '/fd3') ? fs.readFileSync(p + '/fd3', 'utf8') : null};
  });
}
function credFile(world) { return path.join(k2(world).home, '.kogen/credentials/claude-code.json'); }
function walk(dir, skip, out = []) {
  for (const e of fs.readdirSync(dir, {withFileTypes: true})) {
    const p = path.join(dir, e.name);
    if (skip(p)) continue;
    if (e.isDirectory()) walk(p, skip, out); else if (e.isFile()) out.push(p);
  }
  return out;
}

Given('a Claude Code fd 3 project whose fake claude accepts the token {string}', {timeout: 240000}, async function (token) { await setup(this, token); });
Given('the caller environment exports inherited Claude Code credential variables including both FILE_DESCRIPTOR variables', function () {
  const e = k2(this).env;
  e.CLAUDE_CODE_OAUTH_TOKEN = INHERITED;
  e.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = '1';
  e.CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR = '9';
  e.CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR = '9';
  e.ANTHROPIC_API_KEY = 'SYNTHETIC_INHERITED_ANTHROPIC_API_KEY';
});
When('I save the fd 3 Claude Code token {string} from stdin', async function (token) {
  const c = k2(this); c.token = token;
  const r = await run(c.bin, ['provider', 'login', 'claude-code'], c.repo, c.env, token + '\n');
  assert.equal(r.code, 0, r.out); c.outputs.push(r.out);
});
When('I run Shape with the Claude Code executor for the fd 3 project', {timeout: 240000}, async function () {
  const c = k2(this);
  c.last = await run(c.bin, ['intent', 'shape', 'fixture', path.join(c.d, 'request.md')], c.repo, c.env); c.outputs.push(c.last.out);
});

Then('every Claude Code child got the stored token on fd 3 and only the FILE_DESCRIPTOR variable, in the first round and in a --resume round', function () {
  const c = k2(this);
  O.checkStored(calls(this), c.token, SENTINELS);
});
Then('no Claude Code child had fd 3 or any credential variable', function () {
  O.checkNoToken(calls(this), SENTINELS);
});
Then('the fd 3 Claude Code run was refused as {string}', function (reason) {
  const c = k2(this);
  assert.notEqual(c.last.code, 0, c.last.out);
  assert.ok(c.last.out.includes(reason), c.last.out);
});
Then('no Claude Code model round was started in the fd 3 project', function () {
  assert.ok(!calls(this).some(x => x.args[0] === '-p'));
});
Then('no output, log, run record or file outside the credential file holds the fd 3 token', function () {
  const c = k2(this); const cred = credFile(this);
  for (const o of c.outputs) assert.ok(!o.includes(c.token), 'output leaks token');
  const skip = p => p === cred || p === c.state || p.endsWith('.lock') || p.includes(path.sep + '.git' + path.sep);
  for (const f of [...walk(c.repo, skip), ...walk(c.home, skip)]) {
    assert.ok(!fs.readFileSync(f).includes(c.token), 'token found in ' + f);
  }
});

After(function () { if (this.k2) { fs.rmSync(this.k2.d, {recursive: true, force: true}); this.k2 = null; } });
AfterAll(function () { if (installed) { const p = installed; installed = null; return p.then(H.cleanupSuite); } });
