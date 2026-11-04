'use strict';
// Runs scenarios of kogen's own acceptance suite (test/acceptance) against real release archives:
// the one built from this checkout, one whose kogen is rebuilt with another component tuple, and
// ones whose kogen passes its review cards through a wrapper that can drop one line.
// `node features/steps/k-acceptance-no-card-hash__suite.js --control good|bad` checks the
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
const LOOP_REPOSITORY = 'https://github.com/KogenAI/kogen-loop.git';

// The review card form `kogen intent approve <slug>` is logged and loses the lines in kogen-drop;
// every other command runs kogen-real unchanged.
const WRAPPER = String.raw`#!/bin/sh
self=$(readlink "$0" 2>/dev/null) || self=$0
dir=$(dirname "$self")
log=__LOG__
if [ "$#" -eq 3 ] && [ "$1" = intent ] && [ "$2" = approve ]; then
  out=$("$dir/kogen-real" "$@")
  code=$?
  printf 'approve %s\n' "$3" >> "$log"
  if [ -s "$dir/kogen-drop" ]; then
    printf '%s\n' "$out" | grep -xF -f "$dir/kogen-drop" | sed 's/^/dropped: /' >> "$log"
    printf '%s\n' "$out" | grep -vxF -f "$dir/kogen-drop"
  else
    printf '%s\n' "$out"
  fi
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

async function extracted(release) {
  if (release.work) return;
  release.work = fs.mkdtempSync(path.join(os.tmpdir(), 'kanc-release-'));
  const listing = await must('tar', ['-tzf', release.archive]);
  release.topName = listing.split('\n').filter(Boolean)[0].split('/')[0];
  await must('tar', ['-xzf', release.archive, '-C', release.work]);
  release.top = path.join(release.work, release.topName);
}

async function rebuild(release, loopRevision, rows) {
  assert.ok(rows.length > 0, 'no component versions were listed');
  await extracted(release);
  const source = fs.mkdtempSync(path.join(os.tmpdir(), 'kanc-tuple-'));
  try {
    const cli = path.join(source, 'cli');
    fs.cpSync(path.join(root, 'cli'), cli, { recursive: true, dereference: true });
    assert.ok(!fs.realpathSync(path.join(cli, 'go.mod')).startsWith(`${fs.realpathSync(root)}${path.sep}`), `the disposable copy ${cli} resolves into the checkout`);
    const loop = path.join(source, 'kogen-loop');
    await must('git', ['clone', '-q', LOOP_REPOSITORY, loop]);
    const full = (await must('git', ['-C', loop, 'rev-parse', '--verify', `${loopRevision}^{commit}`])).trim();
    assert.ok(full.startsWith(loopRevision), `kogen-loop ${loopRevision} resolved to ${full} in ${LOOP_REPOSITORY}`);
    const vendored = path.join(cli, 'third_party/kogen-loop');
    fs.rmSync(vendored, { recursive: true, force: true });
    fs.mkdirSync(vendored, { recursive: true });
    await must('sh', ['-c', 'git -C "$1" archive "$2" | tar -xf - -C "$3"', 'sh', loop, full, vendored]);
    const env = { ...process.env, CGO_ENABLED: '0', GOFLAGS: '-mod=mod', GONOSUMDB: 'github.com/KogenAI/*', GOWORK: 'off' };
    await must('go', ['mod', 'edit', ...rows.map(row => `-require=${row.module}@${row.version}`)], { cwd: cli, env });
    const binary = path.join(release.top, 'bin/kogen');
    await must('go', ['build', '-trimpath', '-buildvcs=false', '-o', binary, '.'], { cwd: cli, env });
    const info = await must('go', ['version', '-m', binary], { env });
    for (const row of rows) {
      assert.match(info, new RegExp(`^\\s*dep\\s+${escapeRegex(row.module)}\\s+${escapeRegex(row.version)}\\s`, 'm'),
        `the rebuilt kogen does not carry ${row.module} ${row.version}; go version -m ${binary} printed:\n${info}`);
    }
    release.label = `kogen rebuilt with kogen-loop ${full} and ${rows.map(row => `${row.module}@${row.version}`).join(', ')}`;
  } finally {
    fs.rmSync(source, { recursive: true, force: true });
  }
}

async function wrap(release, drop) {
  await extracted(release);
  const bin = path.join(release.top, 'bin');
  fs.renameSync(path.join(bin, 'kogen'), path.join(bin, 'kogen-real'));
  fs.writeFileSync(path.join(bin, 'kogen-drop'), drop === null ? '' : `${drop}\n`);
  release.log = path.join(release.work, 'review-cards.log');
  fs.writeFileSync(release.log, '');
  fs.writeFileSync(path.join(bin, 'kogen'), WRAPPER.replace('__LOG__', shellQuote(release.log)), { mode: 0o755 });
  const version = await run(path.join(bin, 'kogen'), ['version']);
  assert.equal(version.code, 0, `the wrapped kogen did not run kogen version: ${version.stdout}${version.stderr}`);
  release.label = drop === null
    ? 'release whose kogen passes its review cards through a wrapper unchanged'
    : `release whose kogen review cards lose the line ${JSON.stringify(drop)}`;
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
  const reports = fs.mkdtempSync(path.join(os.tmpdir(), 'kanc-report-'));
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

function judgeFailedAt(result, name, expected) {
  const found = scenarios(result, name);
  assert.ok(found.length > 0, `"${name}" did not run against ${where(result)}`);
  const stops = found.map(element => (element.steps || []).filter(step => !step.hidden).find(step => !step.result || step.result.status !== 'passed'));
  const atExpected = stop => stop && stop.result && stop.result.status === 'failed' && stop.name === expected;
  assert.ok(stops.some(atExpected), `"${name}" did not fail at its step "${expected}"; it stopped at ${stops.map(stop => (stop ? stepText(stop) : 'no step: it passed')).join('; ')}\nagainst ${where(result)}`);
  for (const stop of stops.filter(Boolean)) assert.ok(atExpected(stop), `"${name}" also stopped at ${stepText(stop)}\nagainst ${where(result)}`);
  assert.notEqual(result.code, 0, `cucumber exited 0 although "${name}" failed against ${where(result)}`);
}

function judgeWrapped(release) {
  assert.ok(release.logText !== null, `the ${release.label} has no review-card wrapper log`);
  assert.match(release.logText, /^approve \S+$/m, `the ${release.label} never handled a review card (kogen intent approve <slug>); wrapper log:\n${release.logText}`);
}

function judgeDropped(release, line) {
  judgeWrapped(release);
  assert.ok(release.logText.split('\n').includes(`dropped: ${line}`), `the ${release.label} never dropped the line ${JSON.stringify(line)} from a review card; wrapper log:\n${release.logText}`);
}

const HASH_WORDS = /baselineHash|createHash|sha-?256|digest|assert/i;

function judgeNoHashLines(grep) {
  assert.ok(grep.code === 0 || grep.code === 1, `${grep.command} failed with exit ${grep.code}:\n${grep.stdout}${grep.stderr}`);
  const offending = grep.stdout.split('\n').filter(line => line && HASH_WORDS.test(line));
  assert.deepEqual(offending, [], `${grep.command} still finds a hash comparison:\n${offending.join('\n')}`);
}

function filesMentioning(dir, text) {
  const hits = [];
  const walk = current => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      if (entry.name === 'node_modules') continue;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && fs.readFileSync(full, 'utf8').includes(text)) hits.push(path.relative(root, full));
    }
  };
  walk(path.join(root, dir));
  return hits;
}

function defineSteps() {
  const { Given, When, Then } = require('@cucumber/cucumber');

  Given(/^k-acceptance-no-card-hash: the release archive built from this checkout$/, function () {
    this.kancRelease = releaseArchive();
  });

  Given(/^k-acceptance-no-card-hash: the release's kogen is rebuilt with kogen-loop "([0-9a-f]+)" and these component versions:$/, { timeout: STEP_TIMEOUT }, async function (loop, table) {
    await rebuild(this.kancRelease, loop, table.hashes());
  });

  Given(/^k-acceptance-no-card-hash: the release's kogen drops the line "([^"]+)" from its review cards$/, { timeout: STEP_TIMEOUT }, async function (line) {
    await wrap(this.kancRelease, line);
  });

  Given(/^k-acceptance-no-card-hash: the release's kogen passes its review cards through unchanged$/, { timeout: STEP_TIMEOUT }, async function () {
    await wrap(this.kancRelease, null);
  });

  When(/^k-acceptance-no-card-hash: kogen's acceptance suite runs these scenarios against the release:$/, { timeout: STEP_TIMEOUT }, async function (table) {
    this.kancSuite = await runSuite(this.kancRelease, table.hashes());
  });

  Then(/^k-acceptance-no-card-hash: every listed scenario passed$/, function () {
    judgePassed(this.kancSuite);
  });

  Then(/^k-acceptance-no-card-hash: the scenario "([^"]+)" failed at its step:$/, function (name, step) {
    judgeFailedAt(this.kancSuite, name, step.trim());
  });

  Then(/^k-acceptance-no-card-hash: the release's kogen dropped the line "([^"]+)" from a review card$/, function (line) {
    judgeDropped(this.kancRelease, line);
  });

  Then(/^k-acceptance-no-card-hash: the release's kogen passed a review card through$/, function () {
    judgeWrapped(this.kancRelease);
  });

  When(/^k-acceptance-no-card-hash: the command "(.+)" runs in the checkout$/, { timeout: STEP_TIMEOUT }, async function (command) {
    this.kancGrep = { ...(await run('/bin/sh', ['-c', command], { cwd: root })), command };
  });

  Then(/^k-acceptance-no-card-hash: no line it printed compares a hash$/, function () {
    judgeNoHashLines(this.kancGrep);
  });

  Then(/^k-acceptance-no-card-hash: no file under "([^"]+)" outside node_modules contains "([^"]+)"$/, function (dir, text) {
    assert.deepEqual(filesMentioning(dir, text), [], `files under ${dir} still contain ${text}`);
  });
}

// Known-good and known-bad real suite runs for the judgments above.
async function control(kind) {
  const approving = { feature: '03-approval-and-build-start.feature', scenario: "Approving with the card's hash records the approval and starts nothing" };
  const refusals = { feature: '03-approval-and-build-start.feature', scenario: 'Approval refusals' };
  const notFound = 'intent/not_found: Intent does not exist';
  const plainRelease = releaseArchive();
  const plain = await runSuite(plainRelease, [approving]);
  const faultyRelease = releaseArchive();
  await wrap(faultyRelease, notFound);
  const faulty = await runSuite(faultyRelease, [refusals]);
  const holds = judgment => {
    try { judgment(); return true; } catch (error) {
      if (error instanceof assert.AssertionError) return false;
      throw error;
    }
  };
  const approveStep = 'the caller approves "is-even" with the hash from its review card';
  if (kind === 'good') {
    return [
      holds(() => judgePassed(plain)),
      holds(() => judgeFailedAt(faulty, refusals.scenario, `stdout contains "${notFound}"`)),
      holds(() => judgeWrapped(faultyRelease)),
      holds(() => judgeDropped(faultyRelease, notFound)),
    ].every(Boolean);
  }
  return [
    !holds(() => judgePassed(faulty)),
    !holds(() => judgeFailedAt(plain, approving.scenario, approveStep)),
    !holds(() => judgeWrapped(plainRelease)),
    !holds(() => judgeDropped(faultyRelease, 'Files')),
  ].every(Boolean);
}

if (require.main === module) {
  const kind = process.argv[2] === '--control' ? process.argv[3] : null;
  if (kind !== 'good' && kind !== 'bad') {
    process.stderr.write('usage: node features/steps/k-acceptance-no-card-hash__suite.js --control good|bad\n');
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
