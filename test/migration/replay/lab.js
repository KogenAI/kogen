'use strict';
// The harness around one installed `kogen`: a temporary HOME with fake credentials, a temporary Git repository,
// the scripted local provider, and the observations. An observation is a snapshot taken while kogen is blocked
// (it waits for the scripted provider's answer, or it has ended): the Build's own records (run log, facts,
// checkpoint, result) plus what the harness sees in Git and in the files. Nothing here knows the model.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const { startFake, TOKEN, REFRESH } = require('./fake.js');

const SLUG = 'add-greeting';
const REPO_ROOT = path.resolve(__dirname, '../../..');
const FIXTURE = path.join(REPO_ROOT, 'test/migration/fixtures/lab-project');
const PACKAGE = [`.kogen/intents/${SLUG}/intent.md`, `.kogen/intents/${SLUG}/acceptance.feature`, 'features/steps/add_greeting_steps.js'];
const BASELINE = [...PACKAGE, '.kogen/project.yaml'];
const ACCEPTANCE = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';

const sha256 = x => crypto.createHash('sha256').update(x).digest('hex');
const readJSON = file => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const clip = (text, n = 1500) => { text = String(text); return text.length <= n ? text : `${text.slice(0, n / 2)}\n[... ${text.length - n} characters cut ...]\n${text.slice(-n / 2)}`; };

// The baseline hash Kogen approves: the files sorted, each as "<path>\0<sha256 of its bytes>\n", hashed.
function baselineHash(root, files) {
  return sha256([...files].sort().map(f => `${f}\0${sha256(fs.readFileSync(path.join(root, f)))}\n`).join(''));
}

class Lab {
  constructor({ kogen, node, label, strict }) {
    this.kogen = kogen; this.node = node; this.label = label; this.strict = strict;
    this.deviations = []; this.commands = []; this.notes = []; this.refusals = [];
    this.chains = []; this.chain = null; this.cursors = new Map(); this.children = new Set();
    this.snapshotErrors = [];
  }

  async init() {
    this.dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `kogen-replay-${this.label}-`)));
    this.home = path.join(this.dir, 'home'); this.repo = path.join(this.dir, 'repo'); this.tmp = path.join(this.dir, 'tmp');
    for (const d of [this.home, this.repo, this.tmp]) fs.mkdirSync(d);
    fs.writeFileSync(path.join(this.home, '.gitconfig'), '[user]\n\tname = Replay Fixture\n\temail = replay@example.invalid\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n');
    const credDir = path.join(this.home, '.kogen/credentials');
    fs.mkdirSync(credDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(path.join(this.home, '.kogen'), 0o700); fs.chmodSync(credDir, 0o700);
    fs.writeFileSync(path.join(credDir, 'chatgpt.json'), JSON.stringify({
      access_token: TOKEN, client_id: 'oaiapp_replay', email: 'replay@example.invalid', expires_at: Math.floor(Date.now() / 1000) + 3600,
      refresh_token: REFRESH, scope: 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
    }), { mode: 0o600 });
    this.fake = await startFake();
    const git = which('git');
    if (!git) throw new Error('git is not on PATH');
    this.env = {
      HOME: this.home, TMPDIR: this.tmp, LANG: 'C', LC_ALL: 'C',
      PATH: [path.dirname(this.kogen), path.dirname(this.node), path.dirname(git), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(path.delimiter),
      GIT_CONFIG_GLOBAL: path.join(this.home, '.gitconfig'), GIT_CONFIG_NOSYSTEM: '1',
      KOGEN_PROVIDER_URL: this.fake.url, KOGEN_AUTH_URL: this.fake.url, KOGEN_NO_BROWSER: '1',
    };
    return this;
  }

  async close() {
    for (const child of this.children) { try { child.kill('SIGKILL'); } catch {} }
    await this.fake.close();
    fs.rmSync(this.dir, { recursive: true, force: true });
  }

  // ---- files and Git (synchronous: kogen is never waiting on this process while these run, except at snapshots) ----
  put(rel, bytes, mode) { const f = path.join(this.repo, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, bytes, mode ? { mode } : {}); return f; }
  read(rel) { return fs.readFileSync(path.join(this.repo, rel)); }
  git(args, env = {}) {
    const r = cp.spawnSync('git', args, { cwd: this.repo, env: { ...this.env, ...env }, encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${r.stderr}`);
    return r.stdout.trim();
  }

  // A committed project as `kogen init` leaves it, with the fixture Intent package left uncommitted.
  project({ withPackage }) {
    this.git(['init', '-q']);
    this.put('.gitignore', '.kogen/local/\n');
    this.put('README.md', '# Replay fixture\n\nA tiny project for the production replay.\n');
    const role = (name, effort) => `  ${name}:\n    model: gpt-6.1-sol\n    effort: ${effort}\n`;
    this.put('.kogen/project.yaml', `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: '${ACCEPTANCE}'\n    steps_dir: 'features/steps'\nprotect: []\nmodels:\n${role('shape', 'high')}${role('build', 'medium')}${role('review', 'high')}`);
    this.git(['add', '-A']); this.git(['commit', '-qm', 'Initial commit']);
    if (withPackage) this.addPackage();
  }
  addPackage() { for (const rel of PACKAGE) this.put(rel, fs.readFileSync(path.join(FIXTURE, rel))); }
  packageFiles() { return PACKAGE.map(p => ({ path: p, content: fs.readFileSync(path.join(FIXTURE, p), 'utf8') })); }

  // ---- kogen ----
  start(args, { input, timeout = 5 * 60000 } = {}) {
    const child = cp.spawn(this.kogen, args, { cwd: this.repo, env: this.env, stdio: [input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'] });
    this.children.add(child);
    const out = [], err = [];
    child.stdout.on('data', b => out.push(b)); child.stderr.on('data', b => err.push(b));
    if (input !== undefined) { child.stdin.on('error', () => {}); child.stdin.end(input); }
    const timer = setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, timeout);
    const done = new Promise(resolve => child.once('close', (code, signal) => {
      clearTimeout(timer); this.children.delete(child);
      const result = { args, code, signal, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8') };
      this.commands.push({ args, code, signal, stdout: clip(result.stdout), stderr: clip(result.stderr) });
      resolve(result);
    }));
    return { child, pid: child.pid, done };
  }
  run(args, opts) { return this.start(args, opts).done; }

  // The strict run (the installed kogen under test) must behave as the journey says; a mutant may not.
  expect(condition, message) {
    if (condition) return true;
    if (this.strict) throw new Error(message);
    this.deviations.push(message);
    return false;
  }

  beginChain(name) { this.chain = { name, snapshots: [] }; }
  note(kind, data) { this.notes.push({ kind, ...data }); }
  refusal(label, result, before) {
    this.refusals.push({ label, exit: result.code, ...before, firstLine: (result.stdout + result.stderr).split('\n').find(Boolean) || '' });
  }

  // ---- observations ----
  runIds() { const dir = path.join(this.repo, '.kogen/local/runs'); return fs.existsSync(dir) ? fs.readdirSync(dir).filter(d => /^[a-f0-9]{8}$/.test(d)) : []; }
  latestRun() {
    const dir = path.join(this.repo, '.kogen/local/runs');
    const stamp = id => { const st = fs.statSync(path.join(dir, id)); return st.birthtimeMs || st.ctimeMs; };
    return this.runIds().sort((a, b) => stamp(b) - stamp(a))[0] || null;
  }

  // One snapshot of the chain in progress. The Build is blocked: the checkpoint on disk is the one it saved
  // before the request it waits on, or its last one.
  async snap(label) {
    try {
      const chain = this.chain; if (!chain) throw new Error('no chain begun');
      const id = this.latestRun(); if (!id) throw new Error('no run folder');
      const s = this.observe(label, id, chain);
      chain.snapshots.push(s);
      if (!this.chains.includes(chain)) this.chains.push(chain);
      return s;
    } catch (e) {
      this.snapshotErrors.push(`${label}: ${e.message}`);
      if (this.strict) throw e;
      return null;
    }
  }

  observe(label, id, chain) {
    const dir = path.join(this.repo, '.kogen/local/runs', id);
    const log = (fs.existsSync(path.join(dir, 'log.jsonl')) ? fs.readFileSync(path.join(dir, 'log.jsonl'), 'utf8') : '').split('\n').filter(Boolean).map(l => JSON.parse(l));
    const seen = this.cursors.get(`${chain.name}/${id}`) || 0;
    this.cursors.set(`${chain.name}/${id}`, log.length);
    const facts = readJSON(path.join(this.repo, '.kogen/local/facts', `${id}.json`)) || {};
    const trees = new Map((facts.verification || []).map(v => [v.n, v.tree]));
    const doc = readJSON(path.join(dir, 'checkpoint.json'));
    const state = doc ? doc.state : null;
    const result = readJSON(path.join(dir, 'result.json'));
    const start = state ? state.start : this.git(['rev-parse', 'HEAD']);
    const events = log.slice(seen).map(e => simplify(e, trees)).filter(Boolean);
    // Commits are counted from where the chain began: a resume that starts from a later HEAD must not hide the first commit.
    const base = chain.snapshots.length ? chain.snapshots[0].start : start;

    // Git: what is on the branch since the Build started, and whose commits they are.
    const rows = this.git(['log', '--format=%H%x1f%P%x1f%T%x1f%B%x1e', `${base}..HEAD`]).split('\x1e').map(r => r.replace(/^\n/, '')).filter(Boolean).map(r => {
      const [sha, parent, tree, message] = r.split('\x1f'); return { sha, parent, tree, kogen: message.includes(`Kogen-Intent: ${SLUG}`) };
    });
    const head = this.git(['rev-parse', 'HEAD']);

    // Custody of the approval: the baseline files hash to what was approved, and the approval file is the one the
    // checkpoint saved (it is gone only after the commit).
    let custody = null;
    if (doc) {
      const savedApproval = Buffer.from(doc.approval, 'base64');
      const savedSha = JSON.parse(savedApproval.toString('utf8')).sha256;
      const file = path.join(this.repo, `.kogen/local/approvals/${SLUG}.json`);
      const current = fs.existsSync(file) ? fs.readFileSync(file) : null;
      const filesSha = baselineHash(this.repo, state.baseline);
      const approvalFile = current === null ? 'absent' : current.equals(savedApproval) ? 'same' : 'changed';
      custody = { approvedSha: savedSha, baselineSha: filesSha, approvalFile };
    }
    const landedStage = state && state.continuation.stage === 'landed';
    const baselineIntact = custody !== null && custody.baselineSha === custody.approvedSha
      && (custody.approvalFile === 'same' || (custody.approvalFile === 'absent' && (landedStage || rows.some(r => r.kogen))));
    const candidate = doc ? doc.candidate : null;
    const own = this.candidateTree(start);
    if (candidate && candidate !== own) this.expect(false, `${label}: the checkpoint's candidate tree ${candidate} is not the tree the harness computes (${own})`);

    return {
      label, run: id, parent: state && state.parent ? state.parent : null,
      stage: state ? state.continuation.stage : null, owner: state ? state.continuation.owner || null : null,
      outcome: result ? result.outcome : null, resumedFrom: result ? result.resumed_from : (state ? state.parent : null),
      candidate: candidate || own, start, head, headTree: this.git(['rev-parse', `${head}^{tree}`]),
      commits: rows.filter(r => r.kogen).map(({ sha, parent, tree }) => ({ sha, parent, tree })),
      foreignCommits: rows.filter(r => !r.kogen).length,
      custody, baselineIntact, events,
    };
  }

  // The tree of the working files on top of `start`, in a private index, as the checkpoint names it.
  candidateTree(start) {
    const index = path.join(this.dir, 'candidate-index');
    const env = { GIT_INDEX_FILE: index };
    try { this.git(['read-tree', start], env); this.git(['add', '-A', '--', '.'], env); return this.git(['write-tree'], env); }
    finally { fs.rmSync(index, { force: true }); }
  }

  // Copy what the run records hold (for the evidence folder).
  runRecords(outDir) {
    for (const id of this.runIds()) {
      const from = path.join(this.repo, '.kogen/local/runs', id), to = path.join(outDir, 'runs', id);
      fs.mkdirSync(to, { recursive: true });
      for (const f of ['log.jsonl', 'result.json']) if (fs.existsSync(path.join(from, f))) fs.copyFileSync(path.join(from, f), path.join(to, f));
    }
  }
}

// The log events the trace generator may see, reduced to what they say; everything else is dropped here.
function simplify(e, trees) {
  switch (e.event) {
    case 'start': return { k: 'start' };
    case 'resume': return { k: 'resume', parent: e.parent };
    case 'request': return { k: 'request', role: e.role };
    case 'pass': return { k: 'pass', n: e.pass, green: e.green, tree: trees.get(e.pass) || null };
    case 'review': return e.verdict === 'invalid' ? null : { k: 'review', verdict: e.verdict, tree: e.tree, n: e.review, attempt: e.attempt };
    case 'commit': return { k: 'commit', tree: e.tree };
    case 'builder_blocker': return { k: 'blocker', valid: true };
    case 'tool_call': return e.name === 'report_blocker' && typeof e.result === 'object' ? { k: 'blocker', valid: false } : null;
    case 'outcome': return { k: 'outcome', outcome: e.outcome };
    default: return null;
  }
}

function which(name, searchPath = process.env.PATH || '') {
  for (const dir of searchPath.split(path.delimiter)) {
    const file = path.join(dir, name);
    try { fs.accessSync(file, fs.constants.X_OK); if (fs.statSync(file).isFile()) return file; } catch {}
  }
  return null;
}

module.exports = { Lab, SLUG, PACKAGE, BASELINE, baselineHash, sha256, sleep, which, clip };
