const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(__dirname, 'build_unblocking_recovery_driver.exs');

function observe(receipt, rows) {
  assert.ok(receipt, 'no actual installed observations');
  for (const [key, value] of rows) assert.deepEqual(receipt[key], JSON.parse(value), `${key}: ${JSON.stringify(receipt)}`);
}

// These controls qualify the archive observer and the later lifecycle assertions
// separately. The lifecycle fixture uses today's manual clean-start path; it
// neither implements recovery nor pretends the missing command already works.
if (require.main === module) {
  const choice = process.argv[2] === '--control' && process.argv[3];
  assert.ok(['good', 'bad', 'journey-good', 'journey-bad'].includes(choice), 'select a control');
  const journey = choice.startsWith('journey-');
  const good = choice.endsWith('good');
  const temp = journey ? fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-journey-control-')) : null;
  const receipt = temp && path.join(temp, 'receipt.json');
  let accepted;
  try {
    const r = spawnSync('mix', journey ? ['run', DRIVER] : ['run', '--no-start', DRIVER], {
      cwd: ROOT, encoding: 'utf8', timeout: journey ? 240000 : 60000,
      env: { ...process.env, BUR_MODE: journey ? 'fixture-lifecycle' : `control-${choice}`, BUR_RECEIPT: receipt || '', ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' },
    });
    if (journey) {
      if (r.error || r.status !== 0 || !fs.existsSync(receipt)) throw Error((r.stdout || '') + (r.stderr || '') + String(r.error || 'invalid fixture outcome'));
      const data = JSON.parse(fs.readFileSync(receipt, 'utf8'));
      // Known bad evidence: a final reviewer edit was not externally verified.
      if (!good) data['independent changed-tree verification'] = false;
      try {
        observe(data, [
          ['refinement exit', '0'], ['fresh approval required', 'true'],
          ['fresh build exit', '0'], ['one signed commit', 'true'],
          ['independent changed-tree verification', 'true'],
          ['landed approval consumed', 'true'], ['handoff used not imported', 'true'],
        ]);
        accepted = true;
      } catch (e) {
        if (!(e instanceof assert.AssertionError)) throw e;
        accepted = false;
      }
    } else {
      const expected = good ? 'ARCHIVE_ACCEPTED' : 'ARCHIVE_REJECTED';
      if (r.error || r.status !== (good ? 0 : 1) || !(r.stdout || '').includes(expected)) throw Error((r.stdout || '') + (r.stderr || '') + String(r.error || 'invalid control outcome'));
      accepted = good;
    }
  } catch (e) {
    process.stderr.write(String(e)); process.exitCode = 3;
  } finally {
    if (temp) fs.rmSync(temp, { recursive: true, force: true });
  }
  if (process.exitCode === 3) process.exit(3);
  process.stdout.write(accepted ? 'accepted\n' : 'rejected\n');
  process.exit(accepted ? 0 : 1);
} else {
  const { When, Then, AfterAll } = require('@cucumber/cucumber');
  let temp, prepared;
  function run(file, args, options = {}) {
    return new Promise((resolve, reject) => {
      const p = spawn(file, args, { ...options, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '';
      p.stdout.on('data', b => { output += b; }); p.stderr.on('data', b => { output += b; });
      const timer = setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch {} }, 240000);
      p.on('error', e => { clearTimeout(timer); reject(e); });
      p.on('close', code => { clearTimeout(timer); resolve({ code, output }); });
    });
  }
  async function prepare() {
    if (!prepared) prepared = (async () => {
      temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-unblocking-'));
      const dirs = [];
      for (const tool of ['mix', 'erl', 'go', 'node', 'npm', 'python3']) {
        const r = await run('mise', ['which', tool], { cwd: ROOT });
        assert.equal(r.code, 0, r.output); dirs.push(path.dirname(r.output.trim()));
      }
      const env = { ...process.env, PATH: [...dirs, process.env.PATH].join(path.delimiter), ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1' };
      const packed = await run('/bin/sh', ['packaging/package.sh'], { cwd: ROOT, env });
      assert.equal(packed.code, 0, packed.output);
      const archive = packed.output.split('\n').find(s => s.startsWith('/') && s.endsWith('.tar.gz'));
      assert.ok(archive && fs.existsSync(archive), packed.output);
      return { ...env, KOGEN_ARCHIVE: archive };
    })();
    return prepared;
  }
  AfterAll(function () { if (temp) fs.rmSync(temp, { recursive: true, force: true }); });
  When('I exercise native unblocking in mode {string}', { timeout: 300000 }, async function (mode) {
    const env = await prepare();
    const work = fs.mkdtempSync(path.join(temp, 'case-'));
    const receipt = path.join(work, 'receipt.json');
    const r = await run('mix', ['run', DRIVER], { cwd: ROOT, env: { ...env, BUR_MODE: mode, BUR_RECEIPT: receipt } });
    assert.equal(r.code, 0, r.output);
    assert.ok(fs.existsSync(receipt), r.output);
    this.unblocking = JSON.parse(fs.readFileSync(receipt, 'utf8'));
    await this.attach(JSON.stringify(this.unblocking), 'application/json');
  });
  Then('the unblocking observations are:', function (table) {
    observe(this.unblocking, table.raw());
  });
  Then('every unblocking control is independently qualified:', function (table) {
    for (const [name] of table.raw()) assert.deepEqual(this.unblocking[name], {
      wrongRefused: true, correctedReady: true, exactProof: true, productRed: true,
    }, `${name}: ${JSON.stringify(this.unblocking)}`);
  });
}
