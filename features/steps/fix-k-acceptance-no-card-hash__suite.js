'use strict';
// Runs scenarios of kogen's own acceptance suite (test/acceptance) against the release archive
// built from this checkout, unchanged or with its kogen passing review cards through a wrapper
// that can replace one exact line.
// `node features/steps/fix-k-acceptance-no-card-hash__suite.js --control good|bad` checks the
// judgments below against real suite runs (Feasibility observer controls).
const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const acceptance = path.join(root, 'test/acceptance');
const PLATFORM = process.platform === 'darwin' ? 'darwin-arm64' : 'linux-x86_64';
const STEP_TIMEOUT = 115000;

// The review card form `kogen intent approve <slug>` is logged, and its line equal to kogen-from
// becomes the line in kogen-to; every other command runs kogen-real unchanged.
const WRAPPER = String.raw`#!/bin/sh
self=$(readlink "$0" 2>/dev/null) || self=$0
dir=$(dirname "$self")
log=__LOG__
if [ "$#" -eq 3 ] && [ "$1" = intent ] && [ "$2" = approve ]; then
  out=$("$dir/kogen-real" "$@")
  code=$?
  printf 'approve %s\n' "$3" >> "$log"
  from=$(cat "$dir/kogen-from")
  to=$(cat "$dir/kogen-to")
  printf '%s\n' "$out" | while IFS= read -r line; do
    if [ -n "$from" ] && [ "$line" = "$from" ]; then
      printf 'replaced: %s\n' "$line" >> "$log"
      printf '%s\n' "$to"
    else
      printf '%s\n' "$line"
    fi
  done
  exit "$code"
fi
exec "$dir/kogen-real" "$@"
`;

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function shellQuote(text) {
  return `'${text.replace(/'/g, `'\\''`)}'`;
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
  return { archive: files[0], work: null, top: null, topName: null, log: null, logText: null, label: `release ${path.basename(files[0])} built from this checkout` };
}

async function wrap(release, from, to) {
  assert.equal(release.work, null, 'the release is already wrapped');
  release.work = fs.mkdtempSync(path.join(os.tmpdir(), 'fkanc-release-'));
  const listing = await must('tar', ['-tzf', release.archive]);
  release.topName = listing.split('\n').filter(Boolean)[0].split('/')[0];
  await must('tar', ['-xzf', release.archive, '-C', release.work]);
  release.top = path.join(release.work, release.topName);
  const bin = path.join(release.top, 'bin');
  fs.renameSync(path.join(bin, 'kogen'), path.join(bin, 'kogen-real'));
  fs.writeFileSync(path.join(bin, 'kogen-from'), from === null ? '' : `${from}\n`);
  fs.writeFileSync(path.join(bin, 'kogen-to'), to === null ? '' : `${to}\n`);
  release.log = path.join(release.work, 'review-cards.log');
  fs.writeFileSync(release.log, '');
  fs.writeFileSync(path.join(bin, 'kogen'), WRAPPER.replace('__LOG__', shellQuote(release.log)), { mode: 0o755 });
  const version = await run(path.join(bin, 'kogen'), ['version']);
  assert.equal(version.code, 0, `the wrapped kogen did not run kogen version: ${version.stdout}${version.stderr}`);
  release.label = from === null
    ? 'release whose kogen passes its review cards through a wrapper unchanged'
    : `release whose kogen review cards show ${JSON.stringify(to)} instead of ${JSON.stringify(from)}`;
}

async function runSuite(release, rows) {
  assert.ok(rows.length > 0, 'no scenarios were listed');
  const cucumber = path.join(acceptance, 'node_modules/@cucumber/cucumber/bin/cucumber.js');
  assert.ok(fs.existsSync(cucumber), `${cucumber} is missing; run (cd test/acceptance && npm ci)`);
  let archive = release.archive;
  if (release.work) {
    archive = path.join(release.work, `kogen-variant-${PLATFORM}.tar.gz`);
    await must('tar', ['-czf', archive, '-C', release.work, release.topName]);
  }
  const reports = fs.mkdtempSync(path.join(os.tmpdir(), 'fkanc-report-'));
  const report = path.join(reports, 'report.json');
  const features = [...new Set(rows.map(row => row.feature))].map(feature => path.join('../../spec/features', feature));
  const args = [cucumber, '--parallel', '4', '--strict', '--tags', 'not @live', '--require', 'steps/*.js', '--require', 'support/*.js',
    '--format', 'progress', '--format', `json:${report}`, ...rows.flatMap(row => ['--name', `^${escapeRegex(row.scenario)}$`]), ...features];
  const env = { ...process.env, KOGEN_ARCHIVE: archive };
  for (const name of ['KOGEN_ACCEPTANCE_REPORT', 'KOGEN_ACCEPTANCE_FEATURES', 'NODE_PATH']) delete env[name];
  try {
    const result = await run(process.execPath, args, { cwd: acceptance, env, timeout: 105000 });
    let parsed = null;
    try { parsed = JSON.parse(fs.readFileSync(report, 'utf8')); } catch { parsed = null; }
    return {
      code: result.code, output: result.stdout + result.stderr, report: parsed, rows, label: release.label,
      command: `(cd test/acceptance && KOGEN_ARCHIVE=${archive} node ${args.join(' ')})`,
    };
  } finally {
    if (release.log && fs.existsSync(release.log)) release.logText = fs.readFileSync(release.log, 'utf8');
    if (release.work) fs.rmSync(release.work, { recursive: true, force: true });
    release.work = null;
    fs.rmSync(reports, { recursive: true, force: true });
  }
}

function where(result) {
  return `the ${result.label}; ${result.command} exited ${result.code}; output:\n${tail(result.output)}`;
}

function scenarios(result, name) {
  assert.ok(Array.isArray(result.report), `cucumber wrote no JSON report against ${where(result)}`);
  const features = new Set(result.rows.map(row => row.feature));
  return result.report.filter(feature => features.has(path.basename(feature.uri)))
    .flatMap(feature => feature.elements || []).filter(element => element.name === name);
}

function stepText(step) {
  return `${step.keyword}${step.name || ''} (${step.result ? step.result.status : 'no result'})${step.result && step.result.error_message ? `\n${step.result.error_message}` : ''}`;
}

function judgePassed(result) {
  for (const row of result.rows) {
    const found = scenarios(result, row.scenario);
    assert.ok(found.length > 0, `${row.feature}: "${row.scenario}" did not run against ${where(result)}`);
    for (const element of found) {
      const bad = (element.steps || []).find(step => !step.result || step.result.status !== 'passed');
      assert.ok(!bad, `${row.feature}: "${row.scenario}" did not pass at ${bad && stepText(bad)}\nagainst ${where(result)}`);
    }
  }
  assert.equal(result.code, 0, `cucumber did not exit 0 against ${where(result)}`);
}

// The scenario stopped at the expected step, failing there with a message containing `message`.
function judgeFailedAt(result, name, expected, message) {
  const found = scenarios(result, name);
  assert.ok(found.length > 0, `"${name}" did not run against ${where(result)}`);
  const stops = found.map(element => (element.steps || []).filter(step => !step.hidden).find(step => !step.result || step.result.status !== 'passed'));
  const atExpected = stop => stop && stop.result && stop.result.status === 'failed' && stop.name === expected;
  assert.ok(stops.some(atExpected), `"${name}" did not fail at its step "${expected}"; it stopped at ${stops.map(stop => (stop ? stepText(stop) : 'no step: it passed')).join('; ')}\nagainst ${where(result)}`);
  for (const stop of stops.filter(Boolean)) {
    assert.ok(atExpected(stop), `"${name}" also stopped at ${stepText(stop)}\nagainst ${where(result)}`);
    assert.ok(String(stop.result.error_message || '').includes(message), `"${name}" failed at "${expected}" without the message ${JSON.stringify(message)}: ${stepText(stop)}\nagainst ${where(result)}`);
  }
  assert.notEqual(result.code, 0, `cucumber exited 0 although "${name}" failed against ${where(result)}`);
}

function judgeWrapped(release) {
  assert.ok(release.logText !== null, `the ${release.label} has no review-card wrapper log`);
  assert.match(release.logText, /^approve \S+$/m, `the ${release.label} never handled a review card (kogen intent approve <slug>); wrapper log:\n${release.logText}`);
}

function judgeReplaced(release, line) {
  judgeWrapped(release);
  assert.ok(release.logText.split('\n').includes(`replaced: ${line}`), `the ${release.label} never replaced the line ${JSON.stringify(line)} in a review card; wrapper log:\n${release.logText}`);
}

function defineSteps() {
  const { Given, When, Then } = require('@cucumber/cucumber');

  Given(/^fix-k-acceptance-no-card-hash: the release archive built from this checkout$/, function () {
    this.fkancRelease = releaseArchive();
  });

  Given(/^fix-k-acceptance-no-card-hash: the release's kogen shows the line "([^"]+)" instead of "([^"]+)" in its review cards$/, { timeout: STEP_TIMEOUT }, async function (to, from) {
    await wrap(this.fkancRelease, from, to);
  });

  Given(/^fix-k-acceptance-no-card-hash: the release's kogen passes its review cards through unchanged$/, { timeout: STEP_TIMEOUT }, async function () {
    await wrap(this.fkancRelease, null, null);
  });

  When(/^fix-k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:$/, { timeout: STEP_TIMEOUT }, async function (table) {
    this.fkancSuite = await runSuite(this.fkancRelease, table.hashes());
  });

  Then(/^fix-k-acceptance-no-card-hash: every listed scenario passed$/, function () {
    judgePassed(this.fkancSuite);
  });

  Then(/^fix-k-acceptance-no-card-hash: the release's kogen replaced the line "([^"]+)" in a review card$/, function (line) {
    judgeReplaced(this.fkancRelease, line);
  });

  Then(/^fix-k-acceptance-no-card-hash: the release's kogen passed a review card through$/, function () {
    judgeWrapped(this.fkancRelease);
  });

  Then(/^fix-k-acceptance-no-card-hash: the scenario "([^"]+)" failed at its step "(.+)" with the message:$/, function (name, step, message) {
    judgeFailedAt(this.fkancSuite, name, step, message.trim());
  });
}

// Known-good and known-bad real suite runs for the judgments above. The faulty release replaces a
// Files path, which the unchanged content rule already rejects at the card step.
async function control(kind) {
  const card = { feature: '03-approval-and-build-start.feature', scenario: 'The review card shows the Intent, its scenarios and its files' };
  const cardStep = 'stdout shows the review card of "is-even"';
  const from = '  - features/steps/is_even_steps.js';
  const message = 'review card of is-even has no path features/steps/is_even_steps.js between Files and "Approve with:"';
  const plainRelease = releaseArchive();
  const plain = await runSuite(plainRelease, [card]);
  const faultyRelease = releaseArchive();
  await wrap(faultyRelease, from, '  - features/steps/is_odd_steps.js');
  const faulty = await runSuite(faultyRelease, [card]);
  const holds = judgment => {
    try { judgment(); return true; } catch (error) {
      if (error instanceof assert.AssertionError) return false;
      throw error;
    }
  };
  if (kind === 'good') {
    return [
      holds(() => judgePassed(plain)),
      holds(() => judgeFailedAt(faulty, card.scenario, cardStep, message)),
      holds(() => judgeWrapped(faultyRelease)),
      holds(() => judgeReplaced(faultyRelease, from)),
    ].every(Boolean);
  }
  return [
    !holds(() => judgePassed(faulty)),
    !holds(() => judgeFailedAt(plain, card.scenario, cardStep, message)),
    !holds(() => judgeFailedAt(faulty, card.scenario, cardStep, 'review card of is-even has no line "Approver: <name> <<email>>"')),
    !holds(() => judgeWrapped(plainRelease)),
    !holds(() => judgeReplaced(faultyRelease, 'Files')),
  ].every(Boolean);
}

if (require.main === module) {
  const kind = process.argv[2] === '--control' ? process.argv[3] : null;
  if (kind !== 'good' && kind !== 'bad') {
    process.stderr.write('usage: node features/steps/fix-k-acceptance-no-card-hash__suite.js --control good|bad\n');
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
