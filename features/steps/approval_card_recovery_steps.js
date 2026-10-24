const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(__dirname, 'approval_card_recovery_driver.exs');

function run(program, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 240000);
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => { clearTimeout(timer); resolve({ code, output }); });
  });
}
let prepared;
async function environment() {
  if (!prepared) prepared = (async () => {
    const dirs = [];
    for (const tool of ['mix', 'erl', 'go', 'node', 'npm', 'python3']) {
      const r = await run('mise', ['which', tool], { cwd: ROOT });
      assert.equal(r.code, 0, r.output); dirs.push(path.dirname(r.output.trim()));
    }
    const env = { ...process.env, PATH: [...dirs, process.env.PATH].join(path.delimiter), ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
    const r = await run('/bin/sh', ['packaging/package.sh'], { cwd: ROOT, env });
    assert.equal(r.code, 0, r.output);
    const archive = r.output.split('\n').find(s => s.startsWith('/') && s.endsWith('.tar.gz'));
    assert.ok(archive && fs.existsSync(archive), r.output);
    return { ...env, KOGEN_ARCHIVE: archive };
  })();
  return prepared;
}
async function exercise(mode, slug) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-approval-recovery-'));
  try {
    const receipt = path.join(temp, 'observed.json');
    const env = await environment();
    const result = await run('mix', ['run', DRIVER], { cwd: ROOT, env: { ...env, ACR_MODE: mode, ACR_SLUG: slug, ACR_RECEIPT: receipt } });
    return { ...result, observed: fs.existsSync(receipt) ? JSON.parse(fs.readFileSync(receipt, 'utf8')) : null };
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
}
function observe(result, rows) {
  assert.equal(result.code, 0, result.output);
  assert.ok(result.observed, result.output);
  for (const [key, value] of rows) assert.deepEqual(result.observed[key], JSON.parse(value), key + ': ' + JSON.stringify(result.observed));
}
if (require.main === module) {
  (async () => {
    const which = process.argv[2] === '--control' && process.argv[3];
    assert.ok(['good', 'bad'].includes(which));
    // A normal matching-approved Refine/approve/Build journey reaches history and
    // final lifecycle assertions on today's code, independently of stale-card red.
    const result = await exercise('control-' + which, 'approval-control');
    assert.equal(result.code, 0, result.output);
    assert.ok(result.observed, result.output);
    const rows = ['refinement succeeded', 'approval revoked', 'history retained', 'source originals preserved', 'fresh approval required', 'correction retained', 'HEAD and index preserved', 'exact current approval', 'current source bound', 'fresh Build landed', 'independent review ran', 'new approval consumed', 'staged Build retained'].map(k => [k, 'true']);
    try { observe(result, rows); process.stdout.write('accepted\n'); }
    catch (e) {
      if (!(e instanceof assert.AssertionError)) throw e;
      process.stdout.write('rejected\n'); process.exitCode = 1;
    }
  })().catch(e => { process.stderr.write(String(e) + '\n'); process.exitCode = 3; });
} else {
  const { When, Then } = require('@cucumber/cucumber');
  When('I exercise approval card recovery {string} for {string}', { timeout: 300000 }, async function (mode, slug) {
    this.approvalRecovery = await exercise(mode, slug);
    if (this.approvalRecovery.observed) await this.attach(JSON.stringify(this.approvalRecovery.observed), 'application/json');
  });
  Then('the approval recovery observations are:', function (table) { observe(this.approvalRecovery, table.raw()); });
}
