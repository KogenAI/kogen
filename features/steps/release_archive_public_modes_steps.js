const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { When, Then } = require('@cucumber/cucumber');
const root = path.resolve(__dirname, '../..');
const driver = path.join(__dirname, 'release_archive_public_modes.py');
function run(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.env.KOGEN_TEST_PYTHON_BIN || 'python3', [driver, ...args], { cwd: root, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', b => { output += b; });
    child.stderr.on('data', b => { output += b; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, output }));
  });
}
When('I package isolated public payloads with:', { timeout: 600000 }, async function (table) {
  this.publicArchiveRows = table.hashes();
  const result = await run(['exercise', JSON.stringify(this.publicArchiveRows)]);
  await this.attach(JSON.stringify(result), 'application/json');
  assert.equal(result.code, 0, result.output);
  this.publicArchiveReceipt = JSON.parse(result.output);
});
Then('both public archives preserve all payload paths, bytes, types, links and executable distinctions', function () {
  const r = this.publicArchiveReceipt;
  assert.deepEqual(r.umasks, this.publicArchiveRows.map(row => row.umask));
  assert.equal(r.verified, true);
  assert.ok(r.entries.every(n => n > 0));
  assert.deepEqual(r.offline_rows, this.publicArchiveRows.map(() => ['quint', 'cucumber']));
});
Then('the public archive inputs and private symlink referent are unchanged and test outputs are cleaned', function () {
  assert.equal(this.publicArchiveReceipt.inputs_unchanged, true);
  assert.equal(this.publicArchiveReceipt.private_unchanged, true);
  assert.equal(this.publicArchiveReceipt.cleaned, true);
  assert.equal(this.publicArchiveReceipt.cache_unchanged, true);
  assert.match(this.publicArchiveReceipt.preparation_identity, /^[0-9a-f]{64}$/);
});
When('I run the public archive observer controls', { timeout: 30000 }, async function () {
  this.publicArchiveControls = {};
  for (const name of ['good', 'bad']) this.publicArchiveControls[name] = await run(['control', name]);
});
Then('the public archive control results are:', function (table) {
  for (const row of table.hashes()) {
    const r = this.publicArchiveControls[row.control];
    assert.equal(r.code, Number(row.exit), r.output);
    assert.equal(r.output, row.output + '\n');
  }
});
When('I run the public npm preparation controls', { timeout: 60000 }, async function () {
  this.publicNpmControls = {};
  for (const name of ['good', 'bad']) this.publicNpmControls[name] = await run(['cache-control', name]);
});
Then('the public npm preparation control results are:', function (table) {
  for (const row of table.hashes()) {
    const r = this.publicNpmControls[row.control];
    assert.equal(r.code, Number(row.exit), r.output);
    assert.equal(r.output, row.output + '\n');
  }
});
