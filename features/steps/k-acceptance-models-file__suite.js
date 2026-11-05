'use strict';
// Runs scenarios of kogen's own acceptance suite (test/acceptance) against the release archive
// built from this checkout, and against that release whose kogen passes its standard output
// through a wrapper that can drop the lines containing given texts.
// `node features/steps/k-acceptance-models-file__suite.js --control good|bad` checks the
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

// Every kogen command is logged; its stdout loses the lines containing a text in kogen-drop.
const WRAPPER = String.raw`#!/bin/sh
self=$(readlink "$0" 2>/dev/null) || self=$0
dir=$(dirname "$self")
log=__LOG__
printf 'run %s\n' "$*" >> "$log"
out=$(mktemp) || exit 70
"$dir/kogen-real" "$@" > "$out"
code=$?
if [ -s "$dir/kogen-drop" ]; then
  grep -F -f "$dir/kogen-drop" "$out" | sed 's/^/dropped: /' >> "$log"
  grep -v -F -f "$dir/kogen-drop" "$out"
else
  cat "$out"
fi
rm -f "$out"
exit "$code"
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
  release.work = fs.mkdtempSync(path.join(os.tmpdir(), 'kamf-release-'));
  const listing = await must('tar', ['-tzf', release.archive]);
  release.topName = listing.split('\n').filter(Boolean)[0].split('/')[0];
  await must('tar', ['-xzf', release.archive, '-C', release.work]);
  release.top = path.join(release.work, release.topName);
}

function discard(release) {
  if (release.work) fs.rmSync(release.work, { recursive: true, force: true });
  release.work = null;
}

async function wrap(release, texts) {
  await extracted(release);
  const bin = path.join(release.top, 'bin');
  fs.renameSync(path.join(bin, 'kogen'), path.join(bin, 'kogen-real'));
  fs.writeFileSync(path.join(bin, 'kogen-drop'), texts.length === 0 ? '' : `${texts.join('\n')}\n`);
  release.log = path.join(release.work, 'kogen-wrapper.log');
  fs.writeFileSync(release.log, '');
  fs.writeFileSync(path.join(bin, 'kogen'), WRAPPER.replace('__LOG__', shellQuote(release.log)), { mode: 0o755 });
  const version = await run(path.join(bin, 'kogen'), ['version']);
  assert.equal(version.code, 0, `the wrapped kogen did not run kogen version: ${version.stdout}${version.stderr}`);
  release.label = texts.length === 0
    ? 'release whose kogen passes its standard output through a wrapper unchanged'
    : `release whose kogen drops the stdout lines containing ${texts.map(text => JSON.stringify(text)).join(', ')}`;
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
  const reports = fs.mkdtempSync(path.join(os.tmpdir(), 'kamf-report-'));
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
    discard(release);
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

// Each scenario's first step that did not pass is the expected step, failed with the expected error.
function judgeFailedAt(result, expectations) {
  assert.ok(expectations.length > 0, 'no failing steps were listed');
  for (const { scenario, step, error } of expectations) {
    const found = scenarios(result, scenario);
    assert.ok(found.length > 0, `"${scenario}" did not run against ${where(result)}`);
    for (const element of found) {
      const stop = (element.steps || []).filter(each => !each.hidden).find(each => !each.result || each.result.status !== 'passed');
      assert.ok(stop, `"${scenario}" passed although it should fail at its step "${step}"\nagainst ${where(result)}`);
      assert.ok(stop.result && stop.result.status === 'failed' && stop.name === step && String(stop.result.error_message || '').includes(error),
        `"${scenario}" did not fail at its step "${step}" with "${error}"; it stopped at ${stepText(stop)}\nagainst ${where(result)}`);
    }
  }
  assert.notEqual(result.code, 0, `cucumber exited 0 although listed scenarios failed against ${where(result)}`);
}

function judgeWrapped(release) {
  assert.ok(release.logText !== null, `the ${release.label} has no wrapper log`);
  assert.match(release.logText, /^run intent /m, `the ${release.label} never ran a kogen intent command through the wrapper; wrapper log:\n${release.logText}`);
}

function judgeDropped(release, text) {
  judgeWrapped(release);
  const dropped = release.logText.split('\n').filter(line => line.startsWith('dropped: ') && line.includes(text));
  assert.ok(dropped.length > 0, `the ${release.label} never dropped a stdout line containing ${JSON.stringify(text)}; wrapper log:\n${release.logText}`);
}

function requiredVersion(module) {
  const file = path.join(root, 'cli/go.mod');
  const text = fs.readFileSync(file, 'utf8');
  const match = text.match(new RegExp(`^\\s*(?:require\\s+)?${escapeRegex(module)}\\s+(v\\S+)`, 'm'));
  assert.ok(match, `cli/go.mod requires no ${module}:\n${text}`);
  return match[1];
}

function pseudoDate(module, version) {
  const match = version.match(/-(\d{14})-[0-9a-f]{12}$/);
  assert.ok(match, `cli/go.mod requires ${module} ${version}, which is not a pseudo-version with a commit date`);
  return match[1];
}

async function releaseModuleVersion(release, module) {
  await extracted(release);
  try {
    const binary = path.join(release.top, 'bin/kogen');
    const info = await must('go', ['version', '-m', binary]);
    const match = info.match(new RegExp(`^\\s*dep\\s+${escapeRegex(module)}\\s+(\\S+)`, 'm'));
    assert.ok(match, `the ${release.label} carries no ${module}; go version -m ${binary} printed:\n${info}`);
    return match[1];
  } finally {
    discard(release);
  }
}

function requirementLine(file, id) {
  const text = fs.readFileSync(path.join(root, file), 'utf8');
  const lines = text.split('\n').filter(line => line.startsWith(`**${id} — `));
  assert.equal(lines.length, 1, `${file} has ${lines.length} lines starting "**${id} — "`);
  return lines[0];
}

function defineSteps() {
  const { Given, When, Then } = require('@cucumber/cucumber');

  Given(/^k-acceptance-models-file: the release archive built from this checkout$/, function () {
    this.kamfRelease = releaseArchive();
  });

  Given(/^k-acceptance-models-file: the release's kogen drops from its standard output every line containing one of:$/, { timeout: STEP_TIMEOUT }, async function (texts) {
    const list = texts.split('\n').map(text => text.trim()).filter(Boolean);
    assert.ok(list.length > 0, 'no texts to drop were listed');
    await wrap(this.kamfRelease, list);
  });

  Given(/^k-acceptance-models-file: the release's kogen passes its standard output through unchanged$/, { timeout: STEP_TIMEOUT }, async function () {
    await wrap(this.kamfRelease, []);
  });

  When(/^k-acceptance-models-file: kogen's acceptance suite runs these scenarios against the release:$/, { timeout: STEP_TIMEOUT }, async function (table) {
    this.kamfSuite = await runSuite(this.kamfRelease, table.hashes());
  });

  Then(/^k-acceptance-models-file: every listed scenario passed$/, function () {
    judgePassed(this.kamfSuite);
  });

  Then(/^k-acceptance-models-file: the listed scenarios failed at these steps:$/, function (table) {
    judgeFailedAt(this.kamfSuite, table.hashes());
  });

  Then(/^k-acceptance-models-file: the release's kogen dropped a line containing "([^"]+)"$/, function (text) {
    judgeDropped(this.kamfRelease, text);
  });

  Then(/^k-acceptance-models-file: the release's kogen ran through the wrapper$/, function () {
    judgeWrapped(this.kamfRelease);
  });

  Then(/^k-acceptance-models-file: cli\/go\.mod requires "([^"]+)" at a pseudo-version dated at or after "(\d{14})"$/, function (module, earliest) {
    const version = requiredVersion(module);
    const date = pseudoDate(module, version);
    assert.ok(date >= earliest, `cli/go.mod requires ${module} ${version}, dated ${date}, before ${earliest}`);
  });

  Then(/^k-acceptance-models-file: the release's kogen carries the "([^"]+)" version that cli\/go\.mod requires$/, { timeout: STEP_TIMEOUT }, async function (module) {
    const required = requiredVersion(module);
    const carried = await releaseModuleVersion(this.kamfRelease, module);
    assert.equal(carried, required, `the ${this.kamfRelease.label} carries ${module} ${carried}, but cli/go.mod requires ${required}`);
  });

  Then(/^k-acceptance-models-file: the "([A-Z]+-\d+)" line of "([^"]+)" contains:$/, function (id, file, expected) {
    const line = requirementLine(file, id);
    assert.ok(line.includes(expected.trim()), `the ${id} line of ${file} does not contain:\n${expected.trim()}\nIt is:\n${line}`);
  });
}

// Known-good and known-bad real suite runs for the judgments above.
async function control(kind) {
  const notReady = { feature: '03-approval-and-build-start.feature', scenario: 'A not-ready Intent has no card and cannot be approved' };
  const stop = { scenario: notReady.scenario, step: 'stdout contains "intent/not_ready: the Intent is not ready to build"', error: 'stdout did not contain expected text' };
  const plainRelease = releaseArchive();
  const plain = await runSuite(plainRelease, [notReady]);
  const faultyRelease = releaseArchive();
  await wrap(faultyRelease, ['intent/not_ready']);
  const faulty = await runSuite(faultyRelease, [notReady]);
  const holds = judgment => {
    try { judgment(); return true; } catch (error) {
      if (error instanceof assert.AssertionError) return false;
      throw error;
    }
  };
  if (kind === 'good') {
    return [
      holds(() => judgePassed(plain)),
      holds(() => judgeFailedAt(faulty, [stop])),
      holds(() => judgeWrapped(faultyRelease)),
      holds(() => judgeDropped(faultyRelease, 'intent/not_ready')),
    ].every(Boolean);
  }
  return [
    !holds(() => judgePassed(faulty)),
    !holds(() => judgeFailedAt(plain, [stop])),
    !holds(() => judgeWrapped(plainRelease)),
    !holds(() => judgeDropped(faultyRelease, 'candidate/baseline_changed')),
  ].every(Boolean);
}

if (require.main === module) {
  const kind = process.argv[2] === '--control' ? process.argv[3] : null;
  if (kind !== 'good' && kind !== 'bad') {
    process.stderr.write('usage: node features/steps/k-acceptance-models-file__suite.js --control good|bad\n');
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
