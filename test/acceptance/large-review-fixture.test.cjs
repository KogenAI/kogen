const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { FakeServers } = require('./support/fake-servers');

test('large review builder generates oversized Unicode source with bounded response arguments', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'large-review-fixture-'));
  try {
    fs.writeFileSync(path.join(dir, ':(glob)*'), 'deleted literal source\n');
    const server = new FakeServers();
    let sourceBytes = 0;
    for (let ordinal = 1; ordinal <= 2; ordinal++) {
      const response = server.buildResponse('build-large-review-evidence', ordinal, {}, {});
      assert.ok(response.items.reduce((sum, item) => sum + Buffer.byteLength(item.arguments), 0) <= 131072);
      for (const item of response.items) {
        assert.equal(item.name, 'shell');
        const result = spawnSync('sh', ['-c', JSON.parse(item.arguments).command], { cwd: dir, encoding: 'utf8' });
        assert.equal(result.status, 0, result.stderr);
      }
      const source = fs.readFileSync(path.join(dir, `large-source-${ordinal}.txt`));
      assert.equal(source.toString('utf8'), `source-${ordinal}-sentinel\n` + 'literal Δ🙂\r\n'.repeat(24000));
      sourceBytes += source.length;
    }
    assert.ok(sourceBytes > 524288);
    assert.equal(fs.existsSync(path.join(dir, ':(glob)*')), false);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
