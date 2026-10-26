const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');

async function publicArchiveSteps(world, label) {
  if (label === 'I package public payloads with all executable bit classes under both caller umasks') {
    const driver = path.resolve(__dirname, 'public_archive_modes.py');
    const result = await new Promise((resolve, reject) => {
      const child = spawn(process.env.KOGEN_TEST_PYTHON_BIN || 'python3', [driver], {
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      let output = '';
      child.stdout.on('data', chunk => { output += chunk; });
      child.stderr.on('data', chunk => { output += chunk; });
      child.on('error', reject);
      child.on('close', code => resolve({ code, output }));
    });
    await world.attach(JSON.stringify(result), 'application/json');
    assert.equal(result.code, 0, result.output);
    world.publicModesReceipt = JSON.parse(result.output);
    return true;
  }
  if (label === 'the public payloads preserve their contents and inputs with explicit public modes') {
    const receipt = world.publicModesReceipt;
    assert.deepEqual(receipt.umasks, ['077', '022']);
    assert.equal(receipt.entries.length, 2);
    assert.ok(receipt.entries.every(count => count > 0));
    assert.deepEqual(receipt.offline_rows, [['quint', 'cucumber'], ['quint', 'cucumber']]);
    for (const field of ['verified', 'inputs_unchanged', 'private_unchanged', 'cache_unchanged', 'cleaned']) {
      assert.equal(receipt[field], true, field);
    }
    assert.match(receipt.preparation_identity, /^[0-9a-f]{64}$/);
    return true;
  }
  return false;
}

module.exports = { publicArchiveSteps };
