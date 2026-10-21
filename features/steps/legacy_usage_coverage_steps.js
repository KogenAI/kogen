const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { Given, When, Then, After, AfterAll } = require('@cucumber/cucumber');
const ROOT = path.resolve(__dirname, '../..');
const PRIVATE = 'LEGACY_COVERAGE_PRIVATE_BODY';
let installation;
let installRoot;

function run(file, args, cwd, env = {}) {
  return new Promise((resolve, reject) => {
    const p = spawn(file, args, { cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, ERL_FLAGS: '+S 2:2 +SDcpu 1 +SDio 1', ...env } });
    let out = '', err = '';
    p.stdout.on('data', b => { out += b; });
    p.stderr.on('data', b => { err += b; });
    const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 240000);
    p.once('error', e => { clearTimeout(timer); reject(e); });
    p.once('close', code => { clearTimeout(timer); resolve({ code, out, err }); });
  });
}
async function checked(file, args, cwd, env) {
  const r = await run(file, args, cwd, env);
  assert.equal(r.code, 0, `${file} ${args.join(' ')}\n${r.out}\n${r.err}`);
  return r;
}
async function installedCLI() {
  if (!installation) installation = (async () => {
    installRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'legacy-coverage-install-'));
    const home = path.join(installRoot, 'home'), extract = path.join(installRoot, 'extract');
    fs.mkdirSync(home); fs.mkdirSync(extract);
    // Always package current candidate code: an archive from pre-Build setup can be stale.
    const packaged = await checked('sh', ['packaging/package.sh'], ROOT);
    const archive = path.resolve(ROOT, packaged.out.trim().split('\n').at(-1));
    assert.ok(fs.statSync(archive).isFile(), archive);
    await checked('tar', ['-xzf', archive, '-C', extract], ROOT);
    const entries = fs.readdirSync(extract);
    assert.equal(entries.length, 1, JSON.stringify(entries));
    const release = path.join(extract, entries[0]), prefix = path.join(installRoot, 'prefix');
    await checked('sh', [path.join(release, 'install.sh'), '--prefix', prefix], release, { HOME: home });
    return path.join(prefix, 'bin', 'kogen');
  })();
  return installation;
}
AfterAll(function () { if (installRoot) fs.rmSync(installRoot, { recursive: true, force: true }); });
After(function () { if (this.legacyCoverageRoot) fs.rmSync(this.legacyCoverageRoot, { recursive: true, force: true }); });

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value) + '\n');
}
function snapshot(root) {
  const entries = {};
  function visit(dir) {
    for (const name of fs.readdirSync(dir).sort()) {
      const file = path.join(dir, name), st = fs.lstatSync(file), key = path.relative(root, file);
      if (st.isSymbolicLink()) entries[key] = ['link', fs.readlinkSync(file)];
      else if (st.isDirectory()) { entries[key] = ['directory', st.mode]; visit(file); }
      else entries[key] = ['file', st.mode, crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')];
    }
  }
  visit(root); return entries;
}
function physical(row, index, runID, slug) {
  const at = new Date(Date.UTC(2026, 9, 21, 10, 0, index)).toISOString();
  const usage = Object.fromEntries(['input', 'cached', 'output', 'reasoning'].map(k => [k, row[k] ?? null]));
  const phase = row.phase || 'build';
  if (row.legacy) return { event: 'request', at, role: phase, model: 'gpt-6.1-sol', effort: 'medium', usage, wall_ms: 10 };
  const operation = row.operation || `operation_${runID}_${index}`;
  const outcome = row.outcome || 'completed';
  return { event: 'provider_attempt', at, provider: {
    operation_id: operation, attempt_id: `attempt_${runID}_${index}`, conversation_id: `conversation_${runID}_${phase}`,
    timestamp: at, phase, role: phase, run_id: runID, slug, lineage: null,
    provider_response_id: outcome === 'completed' ? `response_${runID}_${index}` : null,
    configured_model: 'gpt-6.1-sol', configured_effort: 'medium', effective_model: null, effective_effort: null,
    usage: { ...usage, write: null, write_30m: null, write_12h: null },
    usage_state: outcome === 'completed' ? 'partial' : 'unknown', outcome,
    error: outcome === 'completed' ? null : 'provider_failure', wall_ms: 10, ttft_ms: null,
    cache: { status: row.cache_status || 'unknown', boundaries: [] }
  } };
}
Given('legacy coverage evidence:', { timeout: 300000 }, async function (text) {
  const spec = JSON.parse(text);
  this.legacyCoverageCLI = await installedCLI();
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'legacy-coverage-case-'));
  this.legacyCoverageRoot = root;
  const repo = path.join(root, 'repo'), home = path.join(root, 'home');
  fs.mkdirSync(repo); fs.mkdirSync(home);
  this.legacyCoverageRepo = repo;
  this.legacyCoverageEnv = { HOME: home, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: 'commit.gpgsign', GIT_CONFIG_VALUE_0: 'false' };
  for (const args of [['init', '-q'], ['config', 'user.name', 'Coverage Fixture'], ['config', 'user.email', 'coverage@example.invalid']]) await checked('git', args, repo, this.legacyCoverageEnv);
  fs.mkdirSync(path.join(repo, '.kogen'));
  fs.writeFileSync(path.join(repo, '.kogen/project.yaml'), 'version: 1\n');
  fs.writeFileSync(path.join(repo, '.gitignore'), '.kogen/local/\n');
  fs.writeFileSync(path.join(repo, 'app.txt'), 'baseline\n');
  await checked('git', ['add', '.'], repo, this.legacyCoverageEnv);
  await checked('git', ['commit', '-qm', 'fixture'], repo, this.legacyCoverageEnv);
  for (const [id, data] of Object.entries(spec.runs || {})) {
    assert.match(id, /^[a-f0-9]{8}$/);
    const dir = path.join(repo, '.kogen/local/runs', id), slug = 'go-core-migration';
    fs.mkdirSync(dir, { recursive: true });
    const events = [];
    let index = 0;
    for (const row of data.rows || []) {
      const repeat = row.repeat ?? 1;
      assert.ok(Number.isInteger(repeat) && repeat >= 1 && repeat <= 100);
      for (let n = 0; n < repeat; n++) events.push(physical(row, index++, id, slug));
    }
    if (data.logical_completions) {
      for (const ev of [...events]) if (ev.provider?.outcome === 'completed') events.push({
        event: 'request', at: ev.at, operation_id: ev.provider.operation_id,
        role: ev.provider.role, model: 'gpt-6.1-sol', effort: 'medium',
        usage: ev.provider.usage, wall_ms: 10
      });
    }
    events.push({ event: 'tool_call', at: '2026-10-21T11:00:00Z', output: PRIVATE });
    fs.writeFileSync(path.join(dir, 'log.jsonl'), events.map(e => JSON.stringify(e)).join('\n') + '\n');
    if (data.summary) writeJSON(path.join(dir, 'result.json'), {
      build: id, slug, outcome: 'stopped', resumed_from: null, root_build: null,
      usage: { input: 999999, cached: 99999, output: 9999, reasoning: 999 },
      attempt_usage: { input: 888888, cached: 88888, output: 8888, reasoning: 888 },
      ...data.summary
    });
    writeJSON(path.join(dir, 'review-1.json'), { usage: { input: 777777 }, private: PRIVATE });
    // Traps and decoys are deliberately not maintained summary/request sources.
    fs.mkdirSync(path.join(dir, 'checkpoint.json'));
    fs.writeFileSync(path.join(dir, 'checkpoint.json', 'private'), PRIVATE);
    if (spec.decoys) {
      writeJSON(path.join(dir, 'archive/result.json'), { build: id, unknown_requests: 99 });
      const nested = path.join(repo, 'archive/copied-repo/.kogen/local/runs/deadbeef');
      writeJSON(path.join(nested, 'result.json'), { build: 'deadbeef', unknown_requests: 99 });
      fs.writeFileSync(path.join(nested, 'log.jsonl'), JSON.stringify(physical({ legacy: true, input: 999999, cached: 99999, output: 99, reasoning: 9 }, 0, 'deadbeef', slug)) + '\n');
    }
  }
  this.legacyCoverageBefore = snapshot(repo);
});
When('I read installed legacy coverage with arguments:', { timeout: 60000 }, async function (text) {
  const args = JSON.parse(text);
  assert.ok(Array.isArray(args) && args.every(x => typeof x === 'string'));
  const base = ['intent', 'usage', ...args, '--project', this.legacyCoverageRepo];
  this.legacyCoverageMachine = await checked(this.legacyCoverageCLI, [...base, '--json'], this.legacyCoverageRepo, this.legacyCoverageEnv);
  this.legacyCoverageReport = JSON.parse(this.legacyCoverageMachine.out);
  assert.equal(this.legacyCoverageReport.kind, 'usage');
  assert.equal(this.legacyCoverageReport.error, null);
  this.legacyCoverageHuman = await checked(this.legacyCoverageCLI, base, this.legacyCoverageRepo, this.legacyCoverageEnv);
});
Then('legacy coverage reporting leaves evidence unchanged', function () {
  assert.deepEqual(snapshot(this.legacyCoverageRepo), this.legacyCoverageBefore);
  for (const result of [this.legacyCoverageMachine, this.legacyCoverageHuman]) {
    assert.ok(!result.out.includes(PRIVATE), result.out);
    assert.ok(!result.err.includes(PRIVATE), result.err);
    assert.doesNotMatch(result.out, /\$\s*\d|\b\d+(?:\.\d+)?%\s+(?:weekly|quota)/i);
  }
});
Then('the legacy coverage JSON contains:', function (table) {
  const errors = [];
  for (const [key, expected] of table.raw()) {
    const actual = key.split('.').reduce((v, k) => v?.[k], this.legacyCoverageReport);
    try { assert.deepEqual(actual, JSON.parse(expected)); }
    catch (e) { errors.push(`${key}: ${e.message}`); }
  }
  assert.deepEqual(errors, [], this.legacyCoverageMachine.out + '\n' + errors.join('\n'));
});
Then('the legacy coverage limitations include:', function (table) {
  const limitations = this.legacyCoverageReport.data.limitations;
  assert.deepEqual(limitations, [...limitations].sort());
  for (const [expected] of table.raw()) assert.ok(limitations.includes(expected), JSON.stringify(limitations));
});
Then('the legacy coverage human output includes:', function (table) {
  for (const [expected] of table.raw()) assert.ok(this.legacyCoverageHuman.out.includes(expected), this.legacyCoverageHuman.out + '\nMissing: ' + expected);
});
