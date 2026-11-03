'use strict';
// Observation only: runs an acceptance runner the way Kogen's acceptance suite runs its fake
// runner, on the is-even fixture feature, and accounts the report with the real verify.Account of
// kogen-verification at the version cli/go.mod pins and at 11a5244 (k_fake_runner_step_evidence_driver.go).
// Usage: node k_fake_runner_step_evidence_check.cjs <runner> <mode> <exit> <statuses> <problems>
// prints one line per kogen-verification version and exits 0 only when both match.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const FIXTURE = path.join(ROOT, 'test/acceptance/fixtures/intents/is-even/acceptance.feature');
const FEATURE = '.kogen/intents/is-even/acceptance.feature';
const PROOF = 'v0.0.0-20261103052035-11a5244e95ee';
const PROOF_SUMS = [
  `github.com/KogenAI/kogen-verification ${PROOF} h1:816vh2SZcQUtls5jEHe8n070dyCa7slroqKllNsTLLM=`,
  `github.com/KogenAI/kogen-verification ${PROOF}/go.mod h1:7ZHQajaSEvj6Fz2EKVFGB7IzCGOv4T6uPFeILU8s30Y=`,
];

let work;
process.on('exit', () => { if (work) fs.rmSync(work, { recursive: true, force: true }); });
const workDir = () => { if (!work) work = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-kfr-'))); return work; };

function pinned(name) {
  const mod = fs.readFileSync(path.join(ROOT, 'cli/go.mod'), 'utf8');
  const match = mod.match(new RegExp(`^\\s*github\\.com/KogenAI/${name} (\\S+)$`, 'm'));
  if (!match) throw new Error(`cli/go.mod pins no github.com/KogenAI/${name}`);
  return match[1];
}

const drivers = new Map();
// The driver built against kogen-verification at version: the pinned one or 11a5244.
function driver(label, version) {
  if (drivers.has(label)) return drivers.get(label);
  const dir = path.join(workDir(), `driver-${drivers.size}`);
  fs.mkdirSync(dir);
  fs.copyFileSync(path.join(__dirname, 'k_fake_runner_step_evidence_driver.go'), path.join(dir, 'main.go'));
  fs.writeFileSync(path.join(dir, 'go.mod'), [
    'module kfrdriver', '', 'go 1.27.2', '', 'require (',
    `\tgithub.com/KogenAI/kogen-coordinator ${pinned('kogen-coordinator')}`,
    `\tgithub.com/KogenAI/kogen-verification ${version}`,
    '\tkogen-loop v0.0.0', ')', '',
    `replace kogen-loop => ${path.join(ROOT, 'cli/third_party/kogen-loop')}`, '',
  ].join('\n'));
  const sums = fs.readFileSync(path.join(ROOT, 'cli/go.sum'), 'utf8');
  fs.writeFileSync(path.join(dir, 'go.sum'), `${sums}${PROOF_SUMS.filter(line => !sums.includes(line)).join('\n')}\n`);
  const r = spawnSync('go', ['build', '-o', 'driver', '.'], {
    cwd: dir, encoding: 'utf8', timeout: 240000, env: { ...process.env, GOWORK: 'off', GOFLAGS: '-mod=mod' },
  });
  if (r.error || r.status !== 0) throw new Error(`go build of the driver against kogen-verification ${version} failed (${r.error || r.status}):\n${r.stdout}${r.stderr}`);
  const file = path.join(dir, 'driver');
  drivers.set(label, file);
  return file;
}

// Runs runner as Kogen's acceptance suite configures it, then accounts its report with both versions.
function observe(runner, mode) {
  const project = fs.mkdtempSync(path.join(workDir(), 'project-'));
  fs.mkdirSync(path.join(project, path.dirname(FEATURE)), { recursive: true });
  fs.copyFileSync(FIXTURE, path.join(project, FEATURE));
  const report = path.join(project, '.kogen/local/runs/fixture/acceptance.ndjson');
  const env = { ...process.env, KOGEN_ACCEPTANCE_FEATURES: FEATURE, KOGEN_ACCEPTANCE_REPORT: report, KOGEN_TEST_ACCEPTANCE_MODE: mode };
  if (process.env.KOGEN_CUCUMBER) env.NODE_PATH = process.env.KOGEN_CUCUMBER;
  const run = spawnSync(process.env.KOGEN_NODE || process.execPath, [path.resolve(ROOT, runner),
    '--strict', '--require', 'features/steps/*.js', '--format', `message:${report}`, FEATURE], { cwd: project, encoding: 'utf8', timeout: 60000, env });
  if (run.error || run.status === null) throw new Error(`fixture runner ${runner} mode ${mode} did not exit: ${run.error || run.signal}`);
  const versions = [['current pin', pinned('kogen-verification')], ['11a5244', PROOF]];
  return versions.map(([label, version]) => {
    const r = spawnSync(driver(label, version), [project, FEATURE, report, String(run.status)], { encoding: 'utf8', timeout: 60000 });
    if (r.error || r.status !== 0) throw new Error(`the ${label} driver failed (${r.error || r.status}):\n${r.stdout}${r.stderr}`);
    const account = JSON.parse(r.stdout);
    return { label, exit: run.status, statuses: account.statuses.join(','), problems: account.problems.length ? account.problems.join(' / ') : '(none)' };
  });
}

// One line per version: "as expected", or what it accounted against what was expected.
function verdicts(runner, mode, want) {
  return observe(runner, mode).map(got => {
    const same = got.exit === want.exit && got.statuses === want.statuses && got.problems === want.problems;
    return { ok: same, line: same ? `${got.label} ${mode}: as expected`
      : `${got.label} ${mode}: got exit ${got.exit}, ${got.statuses}, problems ${got.problems}; want exit ${want.exit}, ${want.statuses}, problems ${want.problems}` };
  });
}

module.exports = { verdicts };

if (require.main === module) {
  const [runner, mode, exit, statuses, problems] = process.argv.slice(2);
  const lines = verdicts(runner, mode, { exit: Number(exit), statuses, problems });
  for (const { line } of lines) console.log(line);
  process.exit(lines.every(l => l.ok) ? 0 : 1);
}
