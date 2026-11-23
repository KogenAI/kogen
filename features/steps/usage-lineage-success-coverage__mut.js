'use strict';
const { Given, Then } = require('@cucumber/cucumber');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const P = 'usage-lineage-success-coverage: ';
const unique = (s, from) => {
  assert.strictEqual(s.split(from).length - 1, 1, 'fixture anchor must occur once in cli/usage.go: ' + from);
};
const MUTATIONS = {
  'selecting only the requested run': ['if lineage && s.selected[id] {', 'if false && s.selected[id] {'],
  'selecting every run': ['(s.selected[stringValue(m["resumed_from"])] ||', '(true ||'],
  'reporting lineage selection as disabled': ['"lineage": lineage, "filters": filters}', '"lineage": false, "filters": filters}'],
  'omitting the requested run id from the scope': ['data["scope"].(object)["run_id"] = id', 'data["scope"].(object)["run_id"] = nil'],
  'ignoring the shared root build': [' || stringValue(m["root_build"]) == root', ''],
  'not following resumed_from to the original run': ['root = p\n', 'break\n'],
};

function goTest(dir, label) {
  const src = fs.readFileSync(path.join(dir, 'usage_test.go'), 'utf8');
  const names = [...src.matchAll(/^func (Test\w+)\(t \*testing\.T\)/gm)].map((m) => m[1]);
  assert.ok(names.length > 0, label + ': no Test functions found in cli/usage_test.go');
  const r = spawnSync('go', ['test', '-count=1', '-run', '^(' + names.join('|') + ')$', '.'], {
    cwd: dir, encoding: 'utf8', timeout: 100000, env: { ...process.env, GOFLAGS: '-trimpath' },
  });
  return { status: r.status, out: (r.stdout || '') + (r.stderr || ''), names };
}

Given(P + 'a scratch copy of the cli module', function () {
  const src = path.join(process.cwd(), 'cli');
  assert.ok(fs.existsSync(path.join(src, 'usage.go')), 'cli/usage.go missing under ' + process.cwd());
  this.dir = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'usage-lineage-')), 'cli');
  fs.cpSync(src, this.dir, { recursive: true });
});

for (const [phrase, [from, to]] of Object.entries(MUTATIONS)) {
  Then(P + 'the usage tests reject ' + phrase, function () {
    const base = goTest(this.dir, 'unmodified usage command');
    assert.strictEqual(base.status, 0, 'go test of usage_test.go tests (' + base.names.join(', ') + ') must pass on the unmodified command:\n' + base.out);
    const file = path.join(this.dir, 'usage.go');
    const s = fs.readFileSync(file, 'utf8');
    unique(s, from);
    fs.writeFileSync(file, s.replace(from, to));
    const r = goTest(this.dir, phrase);
    assert.ok(/--- FAIL/.test(r.out) && r.status !== 0,
      'cli/usage_test.go tests (' + r.names.join(', ') + ') must fail when the command is ' + phrase +
      ' (go test status ' + r.status + '); output:\n' + r.out.slice(-1500));
  });
}
