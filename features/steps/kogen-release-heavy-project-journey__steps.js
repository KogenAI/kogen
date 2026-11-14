'use strict';
const { When, Then } = require('@cucumber/cucumber');
const assert = require('node:assert/strict');
const cp = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const P = 'kogen-release-heavy-project-journey: ';
const ROOT = process.cwd();
const LIVE = path.join(ROOT, 'test/live');

function sh(script, env, cwd) {
  const r = cp.spawnSync('sh', ['-c', script], {
    cwd: cwd || ROOT, encoding: 'utf8', timeout: 60000,
    env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1', ...env },
  });
  return { code: r.status, out: `${r.stdout || ''}${r.stderr || ''}` };
}
const git = 'git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null';

When(P + 'the journey concludes after stages {string} with final commit {string}', function (stages, mode) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'journey-'));
  const proj = path.join(dir, 'project');
  const runDir = path.join(dir, 'run');
  fs.mkdirSync(proj); fs.mkdirSync(runDir);
  let script = `set -e\ncd ${proj}\ngit init -q\n${git} commit -q --allow-empty -m base\nstart=$(git rev-parse HEAD)\n`;
  if (mode !== 'none') {
    if (mode !== 'no-file') script += 'mkdir -p lib && echo x > lib/probe.ex && git add -A\n';
    const body = mode === 'no-trailer' ? 'Kogen-Intent: other' : 'Kogen-Intent: probe';
    script += `${git} commit -q --allow-empty -m Title -m '${body}'\n`;
  }
  const calls = stages.split(' ').filter(Boolean).map(s => { const [n, st] = s.split('='); return `journey_stage ${n} ${st}`; }).join('\n');
  script += `run_dir=${runDir}; SLUG=probe\nsay() { echo "$*"; }\nfail() { echo "FAIL: $*"; exit 1; }\n. ${LIVE}/journey.sh\njourney_begin\n${calls}\njourney_conclude "$start" lib/probe.ex\n`;
  this.result = sh(script);
  fs.rmSync(dir, { recursive: true, force: true });
});

Then(P + 'the conclusion exits {int} printing {string}', function (code, text) {
  assert.equal(this.result.code, code, this.result.out);
  assert.ok(this.result.out.includes(text), `expected "${text}" in:\n${this.result.out}`);
});

When(P + 'the Studio settings are sourced with environment {string}', function (envText) {
  const env = {};
  for (const kv of envText.split(' ').filter(Boolean)) { const i = kv.indexOf('='); env[kv.slice(0, i)] = kv.slice(i + 1); }
  const run = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-run-'));
  this.result = sh(`here=${LIVE}; KOGEN_LIVE_RUN_DIR=${run}; export KOGEN_LIVE_RUN_DIR; . ${LIVE}/projects/studio.sh || exit 1\nfor f in configure verify_without_kogen prepare_repo; do type $f >/dev/null || { echo missing $f; exit 2; }; done\nprintf '%s %s\\n%s\\n' "$STUDIO_REVISION" "$SLUG" "$REQUEST"`, env);
  fs.rmSync(run, { recursive: true, force: true });
});

Then(P + 'the settings exit {int} printing {string}', function (code, text) {
  assert.equal(this.result.code, code, this.result.out);
  assert.ok(this.result.out.includes(text), `expected "${text}" in:\n${this.result.out}`);
});

Then(P + 'the request names {string} and {string} and {string}', function (a, b, c) {
  for (const t of [a, b, c]) assert.ok(this.result.out.includes(t), `request lacks ${t}`);
});

When(P + 'prepare_repo runs against the missing source {string}', function (url) {
  const run = fs.mkdtempSync(path.join(os.tmpdir(), 'studio-run-'));
  this.result = sh(`here=${LIVE}; . ${LIVE}/projects/studio.sh && prepare_repo`, { KOGEN_LIVE_RUN_DIR: run, KOGEN_STUDIO_URL: url });
  fs.rmSync(run, { recursive: true, force: true });
});

Then(P + 'prepare_repo exits nonzero printing {string}', function (text) {
  assert.notEqual(this.result.code, 0, this.result.out);
  assert.ok(this.result.out.includes(text), `expected "${text}" in:\n${this.result.out}`);
});

Then(P + 'the wiring and documentation are in place', function () {
  const read = f => fs.readFileSync(path.join(ROOT, f), 'utf8');
  const real = read('test/live/real-use.sh');
  for (const t of ['journey_conclude', 'journey_stage', 'prepare_repo']) assert.ok(real.includes(t), `real-use.sh lacks ${t}`);
  assert.ok(fs.existsSync(path.join(LIVE, 'projects/example.sh')) && fs.existsSync(path.join(LIVE, 'projects/kogen.sh')), 'existing journeys retained');
  assert.ok(read('test/suite.sh').includes('check-journey.sh'), 'suite.sh does not run check-journey.sh');
  for (const s of ['check-verify.sh', 'check-journey.sh']) {
    const r = sh(`sh test/live/${s}`);
    assert.equal(r.code, 0, `${s}: ${r.out}`);
  }
  const doc = read('docs/live-release-journey.md');
  for (const t of ['sh test/live/real-use.sh studio', 'KOGEN_STUDIO_URL', 'KOGEN_STUDIO_CORPUS_UPDATE', 'claude-code', 'chatgpt', 'blocked', 'b93ff1d6c0748d74ee410615ed07cafbb7de1f07', '1bb47857-fa97-4354-99df-ebcea0db29ae'])
    assert.ok(doc.includes(t), `docs lack ${t}`);
});
