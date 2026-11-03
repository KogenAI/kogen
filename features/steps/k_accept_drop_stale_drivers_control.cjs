'use strict';
// Observer controls of k_accept_drop_stale_drivers_steps.js (Intent k-accept-drop-stale-drivers). They run the real
// runners once in this checkout (Go's test runner in cli and the bundled Cucumber over the Intents' features) and
// judge those real outputs with the step file's own judging functions:
//   node features/steps/k_accept_drop_stale_drivers_control.cjs good   accepts the known-good observations (exit 0)
//   node features/steps/k_accept_drop_stale_drivers_control.cjs bad    rejects every known-bad variant (exit 1)
// The known-bad variants are the real outputs with one defect each, or judged against an expectation they miss.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

process.env.KOGEN_DSD_CONTROL = '1';
const S = require('./k_accept_drop_stale_drivers_steps.js');

const ROOT = path.resolve(__dirname, '../..');
const USAGE = ['TestUsageLimitResumeInstalledRound2', 'TestUsageLimitResumeInstalledRound3', 'TestUsageLimitPackagingIsolationRound2', 'TestUsageLimitPackagingIsolationRound3'];
const PASSING = 'TestAssemblyUsesThePinnedComponents';
const REVOD = '.kogen/intents/k-revod/acceptance.feature';
const REVOD_DOCS = 'The key is documented as experimental and off by default';
const REVOD_DIGEST = 'd035bc2eff5b490cd0e8845a60e8b8e2e078f9bf7d1ffe28e43a3f6ce6eb05bd';

function observe() {
  const dry = S.dryRun();
  const undefinedIn = {};
  let total = 0;
  if (Array.isArray(dry.report)) {
    const all = S.scenariosOf(dry.report);
    total = all.length;
    for (const s of all) if (s.statuses.includes('undefined')) undefinedIn[s.feature] = (undefinedIn[s.feature] || 0) + 1;
  }
  const keptRows = [{ feature: REVOD, scenario: REVOD_DOCS, runs: '1' }];
  const kept = S.runKept(keptRows);
  for (const [what, run] of [['dry run', dry], ['kept run', kept]]) {
    assert.ok(Array.isArray(run.report), `the real ${what} (${run.command}) produced no report: status ${run.status}\n${run.output.slice(-2000)}`);
  }
  return { listed: S.listTests('.', '^TestUsageLimit'), named: S.runNamedTest(PASSING, '.'), keptRows, kept, dry, total, undefinedIn };
}

function good(o) {
  const checks = [
    () => S.judgeListed(o.listed, USAGE),
    () => S.judgeNamedTest(o.named, PASSING),
    () => S.judgeKeptRun(o.kept, o.keptRows),
    () => S.judgeDryRun(o.dry, o.total, o.undefinedIn),
    () => assert.ok(S.scenarioBlocks(fs.readFileSync(path.join(ROOT, REVOD), 'utf8')).some(b => b.scenario === REVOD_DOCS && b.sha256 === REVOD_DIGEST), 'the k-revod documentation block digest'),
  ];
  for (const check of checks) check();
  return checks.length;
}

function bad(o) {
  const clone = v => structuredClone(v);
  const firstScenario = report => report.find(f => (f.elements || []).some(e => e.type !== 'background')).elements.find(e => e.type !== 'background');
  const variants = [
    ['a listed test is missing', () => S.judgeListed(o.listed, [...USAGE, 'TestUsageLimitResumeInstalledRound4'])],
    ['an unexpected test is listed', () => S.judgeListed(o.listed, USAGE.slice(1))],
    ['the named test did not run', () => S.judgeNamedTest(o.named, 'TestUsageLimitResumeInstalledRound2')],
    ['the named test failed', () => S.judgeNamedTest({ ...o.named, status: 1, output: o.named.output.replace(`--- PASS: ${PASSING}`, `--- FAIL: ${PASSING}`) }, PASSING)],
    ['a kept scenario ran fewer times than expected', () => S.judgeKeptRun(o.kept, [{ ...o.keptRows[0], runs: '2' }])],
    ['a kept scenario has a failed step', () => { const k = clone(o.kept); firstScenario(k.report).steps.at(-1).result.status = 'failed'; S.judgeKeptRun(k, o.keptRows); }],
    ['the kept run produced no report', () => S.judgeKeptRun({ ...o.kept, report: null }, o.keptRows)],
    ['the dry run has another number of scenarios', () => S.judgeDryRun(o.dry, o.total + 1, o.undefinedIn)],
    ['the dry run has an ambiguous step', () => { const d = clone(o.dry); firstScenario(d.report).steps.at(-1).result.status = 'ambiguous'; S.judgeDryRun(d, o.total, o.undefinedIn); }],
    ['the dry run has an undefined step in another feature', () => { const d = clone(o.dry); firstScenario(d.report).steps.at(-1).result.status = 'undefined'; S.judgeDryRun(d, o.total, o.undefinedIn); }],
  ];
  const accepted = [];
  for (const [label, check] of variants) {
    try { check(); accepted.push(label); } catch (e) { if (!(e instanceof assert.AssertionError)) throw e; }
  }
  return { total: variants.length, accepted };
}

const mode = process.argv[2];
const o = observe();
if (mode === 'good') {
  const n = good(o);
  console.log(`good: accepted ${n} known-good observations`);
} else if (mode === 'bad') {
  const { total, accepted } = bad(o);
  if (accepted.length) { console.log(`bad: accepted ${accepted.join('; ')}`); process.exitCode = 2; }
  else { console.log(`bad: rejected ${total} of ${total} known-bad observations`); process.exitCode = 1; }
} else {
  console.log('usage: k_accept_drop_stale_drivers_control.cjs good|bad');
  process.exitCode = 64;
}
