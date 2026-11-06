// Acceptance of k-integrate-pins-20261106t060003z: kogen's qualification on the adopted component
// tuple, within the 120-second acceptance limit. Run directly,
// `node features/steps/k-integrate-pins-20261106t060003z__qualification.js --control good|bad`
// qualifies the scenario-run observer on a real run of an existing passing acceptance scenario
// (good) and on a run of no scenario and corruptions of the real run (bad).
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '../..');
const STEP = 110000;

// env is the environment of a child command: the acceptance runner's own variables removed, and
// GOFLAGS=-trimpath as the configured go-test check uses.
function env() {
  const e = { ...process.env, GOFLAGS: '-trimpath' };
  for (const k of ['NODE_PATH', 'KOGEN_ACCEPTANCE_FEATURES', 'KOGEN_ACCEPTANCE_REPORT']) delete e[k];
  return e;
}

function tail(text) {
  return text.length > 20000 ? '...' + text.slice(-20000) : text;
}

function run(dir, command) {
  const r = spawnSync('sh', ['-c', command], { cwd: path.join(root, dir), encoding: 'utf8', env: env(), timeout: STEP - 5000, maxBuffer: 512 * 1024 * 1024 });
  return { status: r.status, error: r.error, out: (r.stdout || '') + (r.stderr || '') };
}

// scenarios runs the scenarios of the spec feature file `feature` selected by the tag expression
// `tags` in the acceptance suite (test/acceptance, against the packaged release in dist/), as its
// configured cucumber check does, with a JSON report.
function scenarios(feature, tags) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'k-integrate-pins-'));
  const report = path.join(dir, 'report.json');
  const command = `npx cucumber-js --parallel 4 --strict --tags "${tags}" --require "steps/*.js" --require "support/*.js" --format "json:${report}" ../../${feature}`;
  const r = run('test/acceptance', command);
  let rows = null;
  try { rows = JSON.parse(fs.readFileSync(report, 'utf8')); } catch { rows = null; }
  fs.rmSync(dir, { recursive: true, force: true });
  return { what: `${command} in test/acceptance; exit=${r.status}, error=${r.error || 'none'}`, status: r.status, error: r.error, out: r.out, rows };
}

function ran(result) {
  return result.rows.flatMap(f => (f.elements || []).filter(e => e.type !== 'background').map(e => ({ name: e.name, steps: e.steps || [] })));
}

// judge requires that the run exited 0, that its report holds exactly the named scenarios (in any
// order, each once) and that every step and hook of each passed.
function judge(result, names) {
  assert(!result.error && result.status === 0, `the run did not succeed: ${result.what}\n${tail(result.out)}`);
  assert(Array.isArray(result.rows), `the run wrote no JSON report: ${result.what}\n${tail(result.out)}`);
  const list = ran(result);
  assert(list.length > 0, `the run ran no scenario: ${result.what}\n${tail(result.out)}`);
  for (const s of list) {
    const bad = s.steps.filter(x => !x.result || x.result.status !== 'passed');
    assert(s.steps.length > 0 && bad.length === 0, `scenario "${s.name}" did not pass every step: ${bad.map(x => `${x.keyword || ''}${x.name || ''} (${x.result ? x.result.status : 'no result'})`).join('; ')}; ${result.what}\n${tail(result.out)}`);
  }
  assert.deepEqual([...list.map(s => s.name)].sort(), [...names].sort(), `the scenarios the run ran: ${result.what}`);
}

// ends requires that the named scenario's steps (after its Background) end with exactly `steps`,
// as step text without keyword, in this order.
function ends(result, name, steps) {
  const s = ran(result).filter(x => x.name === name);
  assert.equal(s.length, 1, `scenario "${name}" ran ${s.length} times: ${result.what}`);
  const texts = s[0].steps.filter(x => !x.hidden).map(x => x.name);
  assert.deepEqual(texts.slice(-steps.length), steps, `the last steps of scenario "${name}": ${result.what}`);
}

const CONTROL = 'The shaping request requires documentation lookup';
const CONTROL_STEPS = [
  'the fake ChatGPT server plays script "shape-ready-is-even"',
  'the caller runs "kogen intent shape is-even -" with stdin:',
  'the exit code is 0',
  'request 1 contains "When a request materially depends on external, protocol, provider or library facts, Shape finds and retrieves current authoritative documentation itself."',
  'request 1 contains "Shape documentation lookup discovers sources and retrieves current authoritative documentation."',
  'request 1 contains "A trivial local edit needs no documentation lookup and no network access."',
];

if (require.main === module && process.argv[2] === '--control') {
  const real = scenarios('spec/features/02-shaping.feature', '@SHP-13 and not @live');
  const accepts = f => { try { f(); return true; } catch { return false; } };
  const good = () => { judge(real, [CONTROL]); ends(real, CONTROL, CONTROL_STEPS); };
  if (process.argv[3] === 'good') {
    const ok = accepts(good);
    console.log(ok ? 'observer accepted' : 'observer rejected');
    if (!ok) process.exitCode = 1;
  } else if (!accepts(good)) {
    console.log('control run broken');
    process.exitCode = 2;
  } else {
    const corrupt = change => { const c = structuredClone({ ...real, error: undefined }); change(c); return c; };
    const none = scenarios('spec/features/02-shaping.feature', '@k-integrate-pins-no-such-tag and not @live');
    const bad = [
      () => judge(none, []),
      () => judge(real, [CONTROL, 'A scenario that did not run']),
      () => judge(real, []),
      () => judge(corrupt(c => { c.status = 1; }), [CONTROL]),
      () => judge(corrupt(c => { c.rows = null; }), [CONTROL]),
      () => judge(corrupt(c => { ran(c).find(s => s.name === CONTROL).steps.find(x => !x.hidden).result.status = 'failed'; }), [CONTROL]),
      () => judge(corrupt(c => { ran(c).find(s => s.name === CONTROL).steps.filter(x => !x.hidden).at(-1).result.status = 'skipped'; }), [CONTROL]),
      () => ends(real, CONTROL, [...CONTROL_STEPS, 'stdout contains "a) I have signed in (recommended)"']),
      () => ends(real, CONTROL, CONTROL_STEPS.slice(1).concat(CONTROL_STEPS[0])),
    ];
    const accepted = bad.filter(f => accepts(f)).length;
    console.log(accepted === 0 ? 'observer rejected' : 'observer accepted');
    if (accepted === 0) process.exitCode = 1;
  }
} else {
  const { When, Then } = require('@cucumber/cucumber');

  When('k-integrate-pins-20261106t060003z: the acceptance suite runs the scenarios tagged {string} of {string}', { timeout: STEP }, function (tags, feature) {
    this.kIntegratePins20261106 = scenarios(feature, tags);
  });

  Then('k-integrate-pins-20261106t060003z: exactly these scenarios ran and passed every step:', function (table) {
    judge(this.kIntegratePins20261106, table.rows().map(([name]) => name));
  });

  Then('k-integrate-pins-20261106t060003z: the scenario {string} ends with these steps:', function (name, table) {
    ends(this.kIntegratePins20261106, name, table.rows().map(([step]) => step));
  });

  Then('k-integrate-pins-20261106t060003z: the cli module resolves the components:', { timeout: STEP }, function (table) {
    for (const [module, version] of table.rows()) {
      const r = run('cli', `go list -m -f '{{.Path}} {{.Version}}{{with .Replace}} => {{.Path}}{{end}}' ${module}`);
      assert.equal(r.status, 0, `go list -m ${module} in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
      assert.equal(r.out.trim(), `${module} ${version}`, `go list -m ${module} in cli`);
    }
  });

  Then('k-integrate-pins-20261106t060003z: the loop pin names module {string} at source head {string}', function (module, head) {
    const pin = JSON.parse(fs.readFileSync(path.join(root, 'cli/loop-pin.json'), 'utf8'));
    assert.equal(pin.module, module, 'cli/loop-pin.json module');
    assert.equal(pin.source_head, head, 'cli/loop-pin.json source_head');
  });

  Then('k-integrate-pins-20261106t060003z: gofmt lists no file in cli', { timeout: STEP }, function () {
    const r = run('cli', 'gofmt -l .');
    assert.equal(r.status, 0, `gofmt -l . in cli: exit=${r.status}, error=${r.error || 'none'}\n${r.out}`);
    assert.equal(r.out, '', 'gofmt -l . in cli lists unformatted files');
  });

  Then('k-integrate-pins-20261106t060003z: {string} in {string} succeeds', { timeout: STEP }, function (command, dir) {
    const r = run(dir, command);
    assert(!r.error && r.status === 0, `${command} in ${dir}: exit=${r.status}, error=${r.error || 'none'}\n${tail(r.out)}`);
  });
}
