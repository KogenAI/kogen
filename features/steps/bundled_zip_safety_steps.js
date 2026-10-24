const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const { When, Then, AfterAll } = require('@cucumber/cucumber');
const REPO = fs.realpathSync(path.resolve(__dirname, '../..'));
const scratch = [];
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const json = p => JSON.parse(fs.readFileSync(p, 'utf8'));
function temp() { const d = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-zip-repair-'))); scratch.push(d); return d; }
function put(root, p, text) { const f = path.join(root, p); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); }
function run(program, args, cwd = REPO, env = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { cwd, env: { ...process.env, ...env }, detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { output += b; });
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 480000);
    child.on('error', e => { clearTimeout(timer); reject(e); });
    child.on('close', code => { clearTimeout(timer); resolve({ command: [program, ...args], cwd, code, output }); });
  });
}
function ok(r) { assert.equal(r.code, 0, JSON.stringify(r)); return r; }
function packages(nm, found = []) {
  if (!fs.existsSync(nm)) return found;
  for (const n of fs.readdirSync(nm)) {
    if (n.startsWith('.')) continue;
    const d = path.join(nm, n);
    if (n.startsWith('@')) { packages(d, found); continue; }
    const f = path.join(d, 'package.json');
    if (!fs.existsSync(f)) continue;
    found.push({ ...json(f), dir: d }); packages(path.join(d, 'node_modules'), found);
  }
  return found;
}
let built;
function build() {
  if (!built) built = (async () => {
    const root = temp();
    const receipt = ok(await run('/bin/sh', ['packaging/package.sh']));
    const archive = receipt.output.trim().split('\n').at(-1);
    assert.ok(fs.existsSync(archive), receipt.output);
    const extract = path.join(root, 'extract'); fs.mkdirSync(extract);
    ok(await run('tar', ['-xzf', archive, '-C', extract]));
    const dirs = fs.readdirSync(extract); assert.equal(dirs.length, 1);
    const release = path.join(extract, dirs[0]); const prefix = path.join(root, 'prefix');
    const home = path.join(root, 'home'); fs.mkdirSync(home);
    const install = ok(await run('/bin/sh', [path.join(release, 'install.sh'), '--prefix', prefix], REPO, { HOME: home }));
    const runtime = path.join(prefix, 'lib/kogen');
    const node = fs.readFileSync(path.join(runtime, 'node-path'), 'utf8').trim();
    const quint = path.join(runtime, 'lib/quint/node_modules/@informalsystems/quint/dist/src/cli.js');
    return { root, archive, runtime, node, quint, prefix, receipts: [receipt, install] };
  })();
  return built;
}
const modelText = `module zip_compat {
 var count: int
 action init = all { count' = 0 }
 action step = all { count' = count + 1 }
 val Nonnegative = count >= 0
 val FalseClaim = count < 0
 run incrementTest = init.then(step).expect(count == 1)
}
`;
async function installedBoundary(b, receipts) {
  const repo = path.join(b.root, 'boundary'); fs.mkdirSync(repo);
  const dir = '.kogen/intents/compat';
  const intent = inv => `# Check packaged Quint\n\nSlug: compat\nModel: ${dir}/model.qnt invariants=${inv} seed=7 samples=10 steps=5\nAcceptance:\n- ${dir}/acceptance.feature\n- features/steps/compat.js\n\nCheck installed compatibility.\n\n## Decisions\n- Preserve verification. (source: request)\n\n## Tests\n- Model remains valid: compatibility fixture (scenario)\n\n## Feasibility\n- none\n`;
  put(repo, dir + '/intent.md', intent('Nonnegative'));
  put(repo, dir + '/model.qnt', modelText);
  put(repo, dir + '/acceptance.feature', 'Feature: Compatibility\n  Scenario: Ready\n    Then packaged compatibility works\n');
  // Readiness keeps its local observations in .kogen/local, which a project ignores as `kogen init` configures it.
  put(repo, '.gitignore', '.kogen/local/\n');
  put(repo, 'features/steps/compat.js', "const {Then}=require('@cucumber/cucumber'); Then('packaged compatibility works', function() {});\n");
  put(repo, '.kogen/project.yaml', `version: 1
commands:
  setup: []
  fix: []
  checks: []
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require ''features/steps/*.js'' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: features/steps
protect: []
`);
  // The fixture repository has its own test identity: it must not depend on the caller's global Git configuration.
  for (const args of [['init', '-q'], ['config', 'user.name', 'Kogen Fixture'], ['config', 'user.email', 'fixture@example.invalid'], ['add', '.'], ['commit', '-qm', 'compatibility fixture']]) receipts.push(ok(await run('git', args, repo)));
  const cli = path.join(b.prefix, 'bin/kogen');
  const good = await run(cli, ['intent', 'approve', 'compat', '--by', 'Probe'], repo); receipts.push(good);
  put(repo, dir + '/intent.md', intent('FalseClaim'));
  const bad = await run(cli, ['intent', 'approve', 'compat', '--by', 'Probe'], repo); receipts.push(bad);
  return {
    installed_good_card: good.code === 5 && good.output.includes('Ready (passes now)') && good.output.includes('SHA-256:'),
    installed_false_rejected: bad.code === 1 && bad.output.includes('intent/not_ready') && bad.output.includes('invariant FalseClaim violated (seed 7)') && bad.output.includes('[violation]') && bad.output.includes('error: Invariant violated'),
  };
}
When('I inspect a freshly built ZIP repair package and isolated install', { timeout: 600000 }, async function () {
  const b = await build(); const receipts = [...b.receipts]; const o = {};
  const manifest = json(path.join(REPO, 'packaging/quint/package.json'));
  o.override = manifest.overrides?.['adm-zip'] || 'missing';
  const isolated = path.join(b.root, 'isolated'); fs.mkdirSync(isolated);
  for (const f of ['package.json', 'package-lock.json']) fs.copyFileSync(path.join(REPO, 'packaging/quint', f), path.join(isolated, f));
  const before = fs.readFileSync(path.join(isolated, 'package-lock.json'));
  receipts.push(ok(await run('npm', ['ci', '--ignore-scripts', '--no-audit', '--no-fund'], isolated)));
  o.isolated_lock_unchanged = before.equals(fs.readFileSync(path.join(isolated, 'package-lock.json')));
  const qroot = path.join(b.runtime, 'lib/quint');
  o.installed_lock_matches = before.equals(fs.readFileSync(path.join(qroot, 'package-lock.json')));
  const installed = packages(path.join(qroot, 'node_modules'));
  const iso = packages(path.join(isolated, 'node_modules'));
  o.isolated_zip_versions = iso.filter(p => p.name === 'adm-zip').map(p => p.version).sort().join(',');
  o.installed_zip_versions = installed.filter(p => p.name === 'adm-zip').map(p => p.version).sort().join(',');
  const lock = json(path.join(isolated, 'package-lock.json'));
  const specLock = json(path.join(REPO, 'spec/package-lock.json'));
  o.zip_integrity_matches_spec = Object.entries(lock.packages).filter(([p]) => /(^|\/)node_modules\/adm-zip$/.test(p)).every(([, p]) => p.version === '0.6.1' && p.resolved === 'https://registry.npmjs.org/adm-zip/-/adm-zip-0.6.1.tgz' && p.integrity === specLock.packages['node_modules/adm-zip'].integrity);
  const inventory = fs.readFileSync(path.join(b.runtime, 'licenses/npm-packages.md'), 'utf8');
  const rows = inventory.split('\n').filter(l => /^\| quint \| adm-zip \|/.test(l));
  if (rows.length === 1) {
    const cells = rows[0].split('|').map(c => c.trim());
    o.inventory_zip_version = cells[3]; o.inventory_zip_license = cells[4];
    const text = fs.readFileSync(path.join(b.runtime, cells[5]), 'utf8');
    const zip = installed.find(p => p.name === 'adm-zip');
    const license = fs.readdirSync(zip.dir).find(n => /^licen[cs]e/i.test(n));
    o.license_text_shipped = text === fs.readFileSync(path.join(zip.dir, license), 'utf8') && /Permission is hereby granted, free of charge/.test(text) && /THE SOFTWARE IS PROVIDED/.test(text);
  }
  const q = async args => { const r = await run(b.node, [b.quint, ...args], b.root); receipts.push(r); return r; };
  o.quint_version = ok(await q(['--version'])).output.trim();
  put(b.root, 'zip_compat.qnt', modelText);
  const typed = await q(['typecheck', 'zip_compat.qnt']); o.typecheck = typed.code === 0;
  const tests = await q(['test', 'zip_compat.qnt', '--backend', 'typescript', '--match', 'Test']);
  o.tests = tests.code === 0 && /1 passing/.test(tests.output) && /incrementTest/.test(tests.output);
  const args = inv => ['run', 'zip_compat.qnt', '--backend', 'typescript', '--invariant', inv, '--seed', '7', '--max-samples', '10', '--max-steps', '5'];
  const pass = await q(args('Nonnegative')); o.seeded_typescript_run = pass.code === 0 && pass.output.includes('[ok] No violation found') && pass.output.includes('--backend=typescript');
  const fail = await q(args('FalseClaim')); o.false_invariant_refuted = fail.code !== 0 && fail.output.includes('[violation]') && fail.output.includes('error: Invariant violated');
  Object.assign(o, await installedBoundary(b, receipts));
  const specUnchanged = sha(fs.readFileSync(path.join(REPO, 'spec/package.json'))) === 'beb979fe2d707c7c6f9043f2e6e831e095fa0449d4730dc0c1d3ba2bd4511a2f' && sha(fs.readFileSync(path.join(REPO, 'spec/package-lock.json'))) === '938d609f3363f6b33983c50f6d6a79357898fd3f21915a1582a420854cef9f1c';
  o.spec_checked_if_changed = specUnchanged;
  if (!specUnchanged) {
    const ci = await run('npm', ['ci'], path.join(REPO, 'spec')); receipts.push(ci);
    const check = await run('/bin/sh', ['check.sh'], path.join(REPO, 'spec')); receipts.push(check);
    o.spec_checked_if_changed = ci.code === 0 && check.code === 0 && check.output.includes('spec checks: all ok');
  }
  this.zipRepair = o;
  await this.attach(JSON.stringify({ observations: o, archive: b.archive, archive_sha256: sha(fs.readFileSync(b.archive)), node: b.node, receipts }, null, 2), 'application/json');
});
When('I compare old and freshly packaged ZIP extraction with overwrite enabled', { timeout: 600000 }, async function () {
  const b = await build(); const root = temp();
  const old = path.join(root, 'old'); fs.mkdirSync(old);
  put(old, 'package.json', JSON.stringify({ private: true, dependencies: { 'adm-zip': '0.5.18' } }));
  const receipt = ok(await run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund'], old));
  const oldLock = json(path.join(old, 'package-lock.json')).packages['node_modules/adm-zip'];
  assert.equal(oldLock.integrity, 'sha512-ufJnssQGbxzLNS1Ho9bCtX4rQKCCvoVuDLHoJyc3F9dOGDB4BkWs2Ci0kv53lqocAEQ/Cbi+I2XCsNYGqVYqng==');
  const installed = packages(path.join(b.runtime, 'lib/quint/node_modules')).filter(p => p.name === 'adm-zip'); assert.equal(installed.length, 1);
  const OldZip = require(path.join(old, 'node_modules/adm-zip'));
  const NewZip = require(installed[0].dir);
  const archive = new OldZip(); archive.addFile('link/sentinel.txt', Buffer.from('replacement'));
  const bytes = archive.toBuffer(); assert.ok(bytes.length < 4096);
  const o = { old_version: oldLock.version, packaged_version: installed[0].version };
  for (const [label, Zip] of [['old', OldZip], ['packaged', NewZip]]) {
    const base = path.join(root, label + '-fixture'); const dest = path.join(base, 'dest'); const outside = path.join(base, 'outside');
    fs.mkdirSync(dest, { recursive: true }); fs.mkdirSync(outside); fs.writeFileSync(path.join(outside, 'sentinel.txt'), 'unchanged');
    fs.symlinkSync(outside, path.join(dest, 'link'), 'dir');
    let error = null;
    try { new Zip(bytes).extractAllTo(dest, true); } catch (e) { error = e; }
    o[label + '_refuses'] = error !== null;
    o[label + '_outside_sentinel'] = fs.readFileSync(path.join(outside, 'sentinel.txt'), 'utf8');
    new Zip(bytes).extractAllTo(path.join(base, 'normal'), true);
    o[label + '_normal_content'] = fs.readFileSync(path.join(base, 'normal/link/sentinel.txt'), 'utf8');
  }
  this.zipRepair = o; await this.attach(JSON.stringify({ observations: o, receipt }, null, 2), 'application/json');
});
Then('the ZIP repair observations are:', function (table) {
  assert.ok(this.zipRepair);
  const errors = [];
  for (const { observation, expected } of table.hashes()) if (String(this.zipRepair[observation]) !== expected) errors.push(`${observation}: expected ${expected}, got ${this.zipRepair[observation]}`);
  assert.deepEqual(errors, []);
});
When('I read the ZIP repair evidence and refreshed official advisory snapshots', function () {
  const dir = path.join(REPO, 'docs/evidence/bundled-zip-safety');
  this.zipEvidence = { dir, text: fs.readFileSync(path.join(dir, 'README.md'), 'utf8'), retrievals: json(path.join(dir, 'refresh/retrievals.json')) };
});
Then('the ZIP repair evidence covers these advisories:', function (table) {
  const { dir, text, retrievals } = this.zipEvidence;
  assert.ok(Array.isArray(retrievals.sources));
  for (const { id, historical_first_patched } of table.hashes()) {
    assert.ok(text.includes(id), `missing repair discussion for ${id}`);
    const file = `advisory-${id}.json`; const bytes = fs.readFileSync(path.join(dir, 'refresh', file)); const advisory = JSON.parse(bytes);
    assert.equal(advisory.ghsa_id, id);
    const v = advisory.vulnerabilities.find(v => v.package.name === 'adm-zip' && v.package.ecosystem === 'npm');
    assert.ok(v); assert.ok('first_patched_version' in v); assert.equal(typeof v.vulnerable_version_range, 'string');
    const r = retrievals.sources.find(r => r.file === file); assert.ok(r, `missing receipt for ${id}`);
    assert.equal(r.url, `https://api.github.com/advisories/${id}`); assert.equal(r.sha256, sha(bytes)); assert.ok(Number.isFinite(Date.parse(r.retrieved_at)));
    // Read back both the refreshed value and the separately documented historical finding.
    assert.ok(text.includes(v.vulnerable_version_range), `missing refreshed range for ${id}`);
    assert.ok(text.includes(String(v.first_patched_version)), `missing refreshed first-patched readback for ${id}`);
    assert.ok(text.includes(historical_first_patched));
  }
  for (const pattern of [/eaa35fa/, /null/, /TypeScript/i, /0\.6\.0/, /0\.6\.1/, /exposure/i, /metadata/i, /sentinel/i, /sha256|sha-256/i, /npm ci/, /packaging\/package\.sh/]) assert.match(text, pattern);
});
AfterAll(function () { for (const d of scratch) fs.rmSync(d, { recursive: true, force: true }); });
