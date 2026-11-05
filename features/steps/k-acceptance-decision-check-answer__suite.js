'use strict';
// Runs scenarios of kogen's own acceptance suite (test/acceptance) against the release archive
// built from this checkout, and against that release with kogen rebuilt with another component
// version in a disposable copy of cli/, judging the suite's Cucumber JSON report and exit code.
// `node features/steps/k-acceptance-decision-check-answer__suite.js --control good|bad` checks the
// judgments below on a real suite run and real `go version -m` output (Feasibility observer controls).
const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const acceptance = path.join(root, 'test/acceptance');
const PLATFORM = process.platform === 'darwin' ? 'darwin-arm64' : 'linux-x86_64';
const STEP_TIMEOUT = 115000;
const SHAPING = 'github.com/KogenAI/kogen-shaping';
const GENERATED_FEATURE = 'decision-check-fault.feature';

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function tail(text) {
  const limit = 8000;
  return text.length > limit ? `[... ${text.length - limit} characters omitted ...]\n${text.slice(-limit)}` : text;
}

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { maxBuffer: 256 * 1024 * 1024, timeout: 110000, ...options }, (error, stdout, stderr) => {
      if (error && typeof error.code !== 'number') {
        reject(new Error(`${command} ${args.join(' ')} did not finish (${error.signal || error.code || error.message}):\n${tail(String(stdout) + String(stderr))}`));
        return;
      }
      resolve({ code: error ? error.code : 0, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

async function must(command, args, options) {
  const result = await run(command, args, options);
  if (result.code !== 0) throw new Error(`${command} ${args.join(' ')} exited ${result.code}:\n${tail(result.stdout + result.stderr)}`);
  return result.stdout;
}

// The newest archive for this platform in dist/, as test/acceptance/support/hooks.js picks it.
function releaseArchive() {
  const dist = path.join(root, 'dist');
  const files = fs.existsSync(dist)
    ? fs.readdirSync(dist).filter(name => name.startsWith('kogen-') && name.endsWith(`-${PLATFORM}.tar.gz`))
      .map(name => path.join(dist, name)).filter(file => fs.statSync(file).isFile())
    : [];
  files.sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  assert.ok(files[0], `no kogen release archive for ${PLATFORM} in ${dist}; build one with sh packaging/package.sh`);
  return { archive: files[0], work: null, label: `release ${path.basename(files[0])} built from this checkout` };
}

async function topOf(archive) {
  const listing = await must('tar', ['-tzf', archive]);
  return listing.split('\n').filter(Boolean)[0].split('/')[0];
}

// `go version -m` lists every dependency as `dep <module> <version> <sum>`.
function judgeCarries(info, module, version, binary) {
  assert.match(info, new RegExp(`^\\s*dep\\s+${escapeRegex(module)}\\s+${escapeRegex(version)}\\s`, 'm'),
    `the kogen binary ${binary} does not carry ${module} ${version}; go version -m printed:\n${info}`);
}

// Rebuilds the release's kogen from a disposable copy of cli/ that requires module@version.
async function rebuild(release, module, version) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'kadc-release-'));
  const source = fs.mkdtempSync(path.join(os.tmpdir(), 'kadc-cli-'));
  try {
    const topName = await topOf(release.archive);
    await must('tar', ['-xzf', release.archive, '-C', work]);
    const cli = path.join(source, 'cli');
    fs.cpSync(path.join(root, 'cli'), cli, { recursive: true, dereference: true });
    assert.ok(!fs.realpathSync(path.join(cli, 'go.mod')).startsWith(`${fs.realpathSync(root)}${path.sep}`), `the disposable copy ${cli} resolves into the checkout`);
    const env = { ...process.env, CGO_ENABLED: '0', GOFLAGS: '-mod=mod', GONOSUMDB: 'github.com/KogenAI/*', GOWORK: 'off' };
    await must('go', ['mod', 'edit', `-require=${module}@${version}`], { cwd: cli, env });
    const binary = path.join(work, topName, 'bin/kogen');
    await must('go', ['build', '-trimpath', '-buildvcs=false', '-o', binary, '.'], { cwd: cli, env });
    judgeCarries(await must('go', ['version', '-m', binary], { env }), module, version, binary);
    const archive = path.join(work, `kogen-variant-${PLATFORM}.tar.gz`);
    await must('tar', ['-czf', archive, '-C', work, topName]);
    release.archive = archive;
    release.work = work;
    release.label = `release whose kogen was rebuilt with ${module}@${version}`;
  } catch (error) {
    fs.rmSync(work, { recursive: true, force: true });
    throw error;
  } finally {
    fs.rmSync(source, { recursive: true, force: true });
  }
}

function scenarioNames(text) {
  return text.split('\n').map(line => line.match(/^\s*Scenario(?: Outline)?:\s*(.*?)\s*$/)).filter(Boolean).map(match => match[1]);
}

// Runs the listed rows ({feature, scenario} of spec/features), or every scenario of a generated
// feature text, with KOGEN_ARCHIVE set to the release; one run per release.
async function runSuite(release, rows, featureText = null) {
  const reports = fs.mkdtempSync(path.join(os.tmpdir(), 'kadc-report-'));
  try {
    assert.ok(release.archive && fs.existsSync(release.archive), `the ${release.label} has no archive to run against`);
    const cucumber = path.join(acceptance, 'node_modules/@cucumber/cucumber/bin/cucumber.js');
    assert.ok(fs.existsSync(cucumber), `${cucumber} is missing; run (cd test/acceptance && npm ci)`);
    const report = path.join(reports, 'report.json');
    let features;
    let names = [];
    if (featureText !== null) {
      const file = path.join(reports, GENERATED_FEATURE);
      fs.writeFileSync(file, featureText.endsWith('\n') ? featureText : `${featureText}\n`);
      rows = scenarioNames(featureText).map(scenario => ({ feature: GENERATED_FEATURE, scenario }));
      features = [file];
    } else {
      features = [...new Set(rows.map(row => row.feature))].map(feature => path.join('../../spec/features', feature));
      names = rows.flatMap(row => ['--name', `^${escapeRegex(row.scenario)}$`]);
    }
    assert.ok(rows.length > 0, 'no scenarios were requested');
    const args = [cucumber, '--parallel', '4', '--strict', '--tags', 'not @live', '--require', 'steps/*.js', '--require', 'support/*.js',
      '--format', 'progress', '--format', `json:${report}`, ...names, ...features];
    const env = { ...process.env, KOGEN_ARCHIVE: release.archive };
    for (const name of ['KOGEN_ACCEPTANCE_REPORT', 'KOGEN_ACCEPTANCE_FEATURES', 'NODE_PATH']) delete env[name];
    const result = await run(process.execPath, args, { cwd: acceptance, env, timeout: 105000 });
    let parsed = null;
    try { parsed = JSON.parse(fs.readFileSync(report, 'utf8')); } catch { parsed = null; }
    return {
      code: result.code, output: result.stdout + result.stderr, report: parsed, rows, label: release.label,
      command: `(cd test/acceptance && KOGEN_ARCHIVE=${release.archive} node ${args.join(' ')})`,
    };
  } finally {
    fs.rmSync(reports, { recursive: true, force: true });
    if (release.work) fs.rmSync(release.work, { recursive: true, force: true });
    release.work = null;
  }
}

function where(result) {
  return `the ${result.label}; ${result.command} exited ${result.code}; output:\n${tail(result.output)}`;
}

function scenarios(result, row) {
  assert.ok(Array.isArray(result.report), `cucumber wrote no JSON report against ${where(result)}`);
  return result.report.filter(feature => path.basename(feature.uri) === row.feature)
    .flatMap(feature => feature.elements || []).filter(element => element.name === row.scenario);
}

function stepText(step) {
  return `${step.keyword}${step.name || ''} (${step.result ? step.result.status : 'no result'})${step.result && step.result.error_message ? `\n${step.result.error_message}` : ''}`;
}

// Every requested scenario ran, every step and hook of each passed, and cucumber exited 0.
function judgePassed(result) {
  for (const row of result.rows) {
    const found = scenarios(result, row);
    assert.ok(found.length > 0, `${row.feature}: "${row.scenario}" did not run against ${where(result)}`);
    for (const element of found) {
      const bad = (element.steps || []).find(step => !step.result || step.result.status !== 'passed');
      assert.ok(!bad, `${row.feature}: "${row.scenario}" did not pass at ${bad && stepText(bad)}\nagainst ${where(result)}`);
    }
  }
  assert.equal(result.code, 0, `cucumber did not exit 0 against ${where(result)}`);
}

// Neither the suite's output nor any step error in its report mentions text.
function judgeNoText(result, text) {
  const hits = [];
  if (result.output.includes(text)) hits.push('the suite output');
  for (const feature of result.report || []) {
    for (const element of feature.elements || []) {
      for (const step of element.steps || []) {
        if (step.result && String(step.result.error_message || '').includes(text)) hits.push(`${path.basename(feature.uri)}: "${element.name}" at ${stepText(step)}`);
      }
    }
  }
  assert.deepEqual(hits, [], `the suite run reported ${JSON.stringify(text)} against ${where(result)}:\n${hits.join('\n')}`);
}

function defineSteps() {
  const { Given, When, Then } = require('@cucumber/cucumber');

  Given(/^k-acceptance-decision-check-answer: the release archive built from this checkout$/, function () {
    this.kadcRelease = releaseArchive();
  });

  Given(/^k-acceptance-decision-check-answer: the release's kogen is rebuilt with "([^"]+)" at "([^"]+)"$/, { timeout: STEP_TIMEOUT }, async function (module, version) {
    await rebuild(this.kadcRelease, module, version);
  });

  When(/^k-acceptance-decision-check-answer: kogen's acceptance suite runs these scenarios against the release:$/, { timeout: STEP_TIMEOUT }, async function (table) {
    this.kadcSuite = await runSuite(this.kadcRelease, table.hashes());
  });

  When(/^k-acceptance-decision-check-answer: kogen's acceptance suite runs this feature against the release:$/, { timeout: STEP_TIMEOUT }, async function (text) {
    this.kadcSuite = await runSuite(this.kadcRelease, [], text);
  });

  Then(/^k-acceptance-decision-check-answer: every requested scenario passed$/, function () {
    judgePassed(this.kadcSuite);
  });

  Then(/^k-acceptance-decision-check-answer: the suite run reported no "([^"]+)"$/, function (text) {
    judgeNoText(this.kadcSuite, text);
  });
}

// The kogen-shaping version cli/go.mod requires and real `go version -m` output of the release's kogen.
async function pinnedShaping() {
  const mod = fs.readFileSync(path.join(root, 'cli/go.mod'), 'utf8');
  const match = mod.match(new RegExp(`^\\s*${escapeRegex(SHAPING)}\\s+(\\S+)\\s*$`, 'm'));
  assert.ok(match, `cli/go.mod does not require ${SHAPING}`);
  const release = releaseArchive();
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'kadc-pinned-'));
  try {
    const topName = await topOf(release.archive);
    await must('tar', ['-xzf', release.archive, '-C', work]);
    const binary = path.join(work, topName, 'bin/kogen');
    return { info: await must('go', ['version', '-m', binary]), version: match[1], binary };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

function changed(result, mutate, extra = {}) {
  const copy = { ...result, ...extra, report: JSON.parse(JSON.stringify(result.report)) };
  mutate(copy.report);
  return copy;
}

// Known-good: a real passing suite run and the release's real version listing. Known-bad: that
// real report with a failed step or without the scenario, a nonzero exit, the stop message in
// the output, and a version the binary does not carry.
async function control(kind) {
  const row = { feature: '02-shaping.feature', scenario: 'A question the check does not class as UI/UX goes back to the shaper and is not asked' };
  const plain = await runSuite(releaseArchive(), [row]);
  const pinned = await pinnedShaping();
  const holds = judgment => {
    try { judgment(); return true; } catch (error) {
      if (error instanceof assert.AssertionError) return false;
      throw error;
    }
  };
  const stop = 'shape/decision_check_invalid: the decision check answer is not a valid submit_decision_check payload (expected one submit_decision_check call); nothing was published';
  if (kind === 'good') {
    return [
      holds(() => judgePassed(plain)),
      holds(() => judgeNoText(plain, 'decision_check_invalid')),
      holds(() => judgeCarries(pinned.info, SHAPING, pinned.version, pinned.binary)),
    ].every(Boolean);
  }
  if (!holds(() => judgePassed(plain))) throw new Error(`the known-good run needed by the bad control was not accepted against ${where(plain)}`);
  const failedStep = changed(plain, report => {
    const element = report.flatMap(feature => feature.elements || []).find(item => item.name === row.scenario);
    const last = element.steps.filter(step => !step.hidden).at(-1);
    last.result = { status: 'failed', error_message: `AssertionError [ERR_ASSERTION]: ${stop}` };
  }, { code: 1 });
  const missing = changed(plain, report => {
    for (const feature of report) feature.elements = (feature.elements || []).filter(item => item.name !== row.scenario);
  });
  return [
    !holds(() => judgePassed(failedStep)),
    !holds(() => judgeNoText(failedStep, 'decision_check_invalid')),
    !holds(() => judgePassed(missing)),
    !holds(() => judgePassed({ ...plain, code: 1 })),
    !holds(() => judgeNoText({ ...plain, output: `${plain.output}\n${stop}\n` }, 'decision_check_invalid')),
    !holds(() => judgeCarries(pinned.info, SHAPING, 'v0.0.0-20000101000000-000000000000', pinned.binary)),
  ].every(Boolean);
}

if (require.main === module) {
  const kind = process.argv[2] === '--control' ? process.argv[3] : null;
  if (kind !== 'good' && kind !== 'bad') {
    process.stderr.write('usage: node features/steps/k-acceptance-decision-check-answer__suite.js --control good|bad\n');
    process.exit(2);
  }
  control(kind).then(expected => {
    const accepted = kind === 'good' ? expected : !expected;
    process.stdout.write(accepted ? 'observer accepted\n' : 'observer rejected\n');
    process.exit(accepted ? 0 : 1);
  }, error => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exit(2);
  });
} else {
  defineSteps();
}
