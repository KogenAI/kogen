const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { createRequire } = require('node:module');
const crypto = require('node:crypto');
const ROOT = path.resolve(__dirname, '../..');
// The prompt-cache fake and its observers (a local HTTP server per provider wire that reuses
// real byte prefixes) live apart from this protected file's older helpers.
const cacheFake = require('../../test/migration/cache-fake/fake.js');
const reopenProducer = require('./reopen_blocked_review_producer.js'), reopenC3 = require('./reopen_blocked_review_c3.js');
let c3Producer; // the built C3 producer, once per run
const cucumber = () => path.join(process.env.KOGEN_CUCUMBER, '@cucumber/cucumber/bin/cucumber.js');
const work = new Set();
let packed;
function temporary() { const p = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-go-migration-')); work.add(p); return p; }
function put(p, text) { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, text); }
function start(file, args, cwd = ROOT, env = {}, input = '') {
  const child = spawn(file, args, { cwd, env: { ...process.env, ERL_FLAGS: process.env.ERL_FLAGS || '+S 2:2 +SDcpu 1 +SDio 1', ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  const result = new Promise((resolve, reject) => {
    let out = ''; child.stdout.on('data', b => { out += b; }); child.stderr.on('data', b => { out += b; });
    child.stdin.on('error', () => {}); child.stdin.end(input);
    child.once('error', reject); child.once('close', code => resolve({ code, out }));
  });
  return { child, result };
}
function run(file, args, cwd = ROOT, env = {}, input = '') { return start(file, args, cwd, env, input).result; }
async function must(file, args, cwd, env, input) { const r = await run(file, args, cwd, env, input); assert.equal(r.code, 0, r.out); return r.out; }
function compare(actual, expected) { for (const [k, v] of Object.entries(expected)) { assert.ok(Object.hasOwn(actual, k), 'missing ' + k); assert.deepEqual(actual[k], v, k + ': ' + JSON.stringify(actual)); } }
function gherkin() { const req = createRequire(path.join(ROOT, 'spec/package.json')); return { g: req('@cucumber/gherkin'), m: req('@cucumber/messages') }; }
function parse(file) {
  const { g, m } = gherkin(), id = m.IdGenerator.uuid();
  return { g, id, doc: new g.Parser(new g.AstBuilder(id), new g.GherkinClassicTokenMatcher()).parse(fs.readFileSync(file, 'utf8')) };
}
// Scenario (and outline) names of a feature, by AST node id, whatever their tags.
function scenarioNames(file) { return namesOf(parse(file).doc); }
function namesOf(doc) {
  const names = new Map();
  const take = children => children.forEach(c => { if (c.scenario) names.set(c.scenario.id, c.scenario.name); if (c.rule) take(c.rule.children); });
  take(doc.feature ? doc.feature.children : []);
  return names;
}
// Example rows of a feature, by AST node id: their line and first cell (an outline's pickles share its name).
function rowsOf(doc, rows = new Map()) {
  const take = children => children.forEach(c => {
    if (c.rule) take(c.rule.children);
    for (const ex of (c.scenario && c.scenario.examples) || []) for (const r of ex.tableBody || []) rows.set(r.id, { line: r.location.line, first: r.cells[0] && r.cells[0].value, cells: r.cells.map(c => c.value).join(' / ') });
  });
  take(doc.feature ? doc.feature.children : []);
  return rows;
}
const rowOf = (rows, p) => rows.get(p.astNodeIds[1]) || { line: 0, first: undefined, cells: undefined };
// An example row is named by its first cell, or by all its cells joined with ' / ' when the first is not unique.
const rowNamed = (row, example) => example === undefined || example === row.first || example === row.cells;
function pickles(files, cwd) {
  return files.flatMap(f => {
    const file = path.resolve(cwd, f), { g, id, doc } = parse(file), names = namesOf(doc), rows = rowsOf(doc);
    return g.compile(doc, file, id).filter(p => !p.tags.some(t => t.name === '@live')).map(p => Object.assign(p, { scenarioName: names.get(p.astNodeIds[0]), row: rowOf(rows, p) }));
  });
}
// `Given these accumulated scenarios are superseded by prompt caching:` / `... by open model selection:` (slug | exact scenario
// name). Every named scenario must exist, by exact name, in that slug's acceptance feature;
// anything else is a mistake in the table, never a silent skip.
// An optional third column names one example row of an outline by its first cell; without it the whole
// scenario (every row) is superseded.
function exclusions(rows, base = ROOT) {
  const out = [];
  for (const [slug, name, cell] of rows) {
    const example = cell === '' ? undefined : cell;
    const file = path.join(base, '.kogen/intents', slug, 'acceptance.feature');
    assert.ok(fs.existsSync(file), 'superseded scenario names a missing feature: ' + slug);
    assert.ok([...scenarioNames(file).values()].includes(name), 'superseded scenario is not in ' + slug + ': ' + name);
    if (example !== undefined) assert.equal(pickles([file], base).filter(p => p.scenarioName === name && rowNamed(p.row, example)).length, 1, 'superseded example row is not exactly one row of ' + slug + ': ' + name + ' | ' + example);
    assert.ok(!out.some(e => e.file === file && e.name === name && (e.example === undefined || example === undefined || e.example === example)), 'superseded scenario listed twice: ' + slug + ': ' + name);
    out.push({ file, name, example });
  }
  return out;
}
const identity = (p, cwd) => path.resolve(cwd, p.uri) + '\0' + p.name + '\0' + p.row.line;
// The pickles a run must pass (expected) and the superseded ones whose outcome is ignored.
function selection(inputs, cwd, excluded) {
  const all = pickles(inputs, cwd), skip = all.filter(p => excluded.some(e => e.file === path.resolve(cwd, p.uri) && e.name === p.scenarioName && rowNamed(p.row, e.example)));
  return { expected: all.filter(p => !skip.includes(p)), ignored: new Set(skip.map(p => identity(p, cwd))), all };
}
// Cucumber's own exit code counts superseded scenarios too, so with exclusions it is judged
// here: 0, or 1 only when a superseded scenario really failed (the others are judged by
// checkReport, step by step).
function judgeExit(code, failedIgnored, excluding) {
  if (!excluding) return assert.equal(code, 0, 'cucumber exit ' + code);
  assert.ok(code === 0 || code === 1, 'cucumber stopped abnormally: exit ' + code);
  if (code === 1) assert.ok(failedIgnored > 0, 'cucumber failed but no superseded scenario failed');
}
function checkReport(envelopes, expected, cwd, ignored = new Set()) {
  const p = new Map(), tc = new Map(), starts = new Map(), results = new Map(), finishes = [];
  const rows = new Map();
  for (const e of envelopes) if (e.gherkinDocument) rowsOf(e.gherkinDocument, rows);
  for (const e of envelopes) {
    if (e.pickle) p.set(e.pickle.id, Object.assign(e.pickle, { row: rowOf(rows, e.pickle) }));
    if (e.testCase) tc.set(e.testCase.id, e.testCase);
    if (e.testCaseStarted) { assert.ok(!starts.has(e.testCaseStarted.id)); starts.set(e.testCaseStarted.id, e.testCaseStarted); }
    if (e.testStepFinished) { const s = e.testStepFinished; const key = s.testCaseStartedId + ':' + s.testStepId; assert.ok(!results.has(key), 'duplicate step'); results.set(key, s.testStepResult.status); }
    if (e.testCaseFinished) finishes.push(e.testCaseFinished);
  }
  const wanted = expected.map(p => identity(p, cwd)).sort(), observed = [], failedKept = []; let failedIgnored = 0;
  assert.ok(wanted.length, 'empty suite');
  const seen = new Set();
  for (const f of finishes) {
    assert.ok(!seen.has(f.testCaseStartedId), 'duplicate finish'); seen.add(f.testCaseStartedId);
    const start = starts.get(f.testCaseStartedId); assert.ok(start); assert.equal(start.attempt, 0); assert.equal(f.willBeRetried, false);
    const test = tc.get(start.testCaseId); assert.ok(test && test.testSteps.length); const pickle = p.get(test.pickleId); assert.ok(pickle);
    if (ignored.has(identity(pickle, cwd))) {
      // Superseded by prompt caching: its outcome is ignored (recorded only to judge the exit code).
      if (test.testSteps.some(step => results.get(start.id + ':' + step.id) !== 'PASSED')) failedIgnored++;
      continue;
    }
    observed.push(identity(pickle, cwd));
    if (test.testSteps.some(step => results.get(start.id + ':' + step.id) !== 'PASSED')) failedKept.push(pickle.uri + ': ' + pickle.name + (pickle.row.line ? ' (example line ' + pickle.row.line + ')' : ''));
  }
  // Every failing kept scenario is named, not only the first.
  assert.deepEqual(failedKept, [], 'incomplete or nonpassing kept scenarios');
  assert.equal(starts.size, finishes.length, 'unfinished case');
  assert.deepEqual(observed.sort(), wanted, 'scenario coverage');
  // testRunFinished.success covers superseded scenarios too; judged over the others above when some are ignored.
  const ended = envelopes.filter(e => e.testRunFinished); assert.equal(ended.length, 1); if (!ignored.size) assert.equal(ended[0].testRunFinished.success, true);
  return failedIgnored;
}
async function candidate() {
  if (!packed) packed = (async () => {
    // KOGEN_ARCHIVE names a private copy of the packaging output (never a file in dist/ another run may rebuild).
    const out = process.env.KOGEN_ARCHIVE ? process.env.KOGEN_ARCHIVE + '\n' : await must('/bin/sh', ['packaging/package.sh']);
    const archive = out.trim().split('\n').at(-1); assert.ok(path.isAbsolute(archive) && fs.statSync(archive).isFile(), out);
    const temp = temporary(), extract = path.join(temp, 'extract'); fs.mkdirSync(extract);
    await must('tar', ['-xzf', archive, '-C', extract]);
    const tops = fs.readdirSync(extract); assert.equal(tops.length, 1); const release = path.join(extract, tops[0]);
    // Poison, rather than use, any former core: a candidate that still ships one gets a trap in
    // its place, so an old-core invocation fails as product red. A candidate without one stays
    // as built, and spec chapter 10 then checks that the installed release has no lib/release.
    if (fs.existsSync(path.join(release, 'lib/release'))) {
      fs.rmSync(path.join(release, 'lib/release'), { recursive: true, force: true });
      const trap = path.join(release, 'lib/release/bin/kogen'); put(trap, '#!/bin/sh\necho "GO_CORE_REQUIRED: Elixir core execution is forbidden in this gate" >&2\nexit 86\n'); fs.chmodSync(trap, 0o755);
    }
    const nativeArchive = path.join(temp, 'native.tar.gz'); await must('tar', ['-czf', nativeArchive, '-C', extract, tops[0]]);
    return { archive, nativeArchive, temp, release };
  })();
  return packed;
}
function localEnv(home) { return { HOME: home, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: path.join(home, '.gitconfig'), KOGEN_PROVIDER_URL: 'http://127.0.0.1:1', KOGEN_AUTH_URL: 'http://127.0.0.1:1', ANTHROPIC_API_KEY: '', OPENAI_API_KEY: '', KOGEN_NO_BROWSER: '1' }; }
async function authority() {
  const c = await candidate(), temp = temporary(), home = path.join(temp, 'home'), repo = path.join(temp, 'repo'), prefix = path.join(temp, 'prefix');
  fs.mkdirSync(home); fs.mkdirSync(repo); put(path.join(home, '.gitconfig'), ''); const env = localEnv(home);
  // Install the real candidate; the sentinel must not be needed even for version.
  await must('sh', [path.join(c.release, 'install.sh'), '--prefix', prefix], ROOT, env);
  const bin = path.join(prefix, 'bin/kogen'); const cli = (args, input) => run(bin, args, repo, env, input);
  const exits = [];
  for (const provider of ['opencode-go', 'anthropic']) { const r = await cli(['provider', 'login', provider], 'SYNTHETIC_MIGRATION_KEY\n'); exits.push(r.code); assert.equal(r.code, 0, r.out); }
  const listed = await cli(['provider', 'list']); exits.push(listed.code);
  const runner = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
  put(path.join(repo, '.gitignore'), '.kogen/local/\n'); put(path.join(repo, 'README.md'), '# Migration fixture\n'); put(path.join(repo, 'app.txt'), 'kept\n');
  put(path.join(repo, '.kogen/project.yaml'), `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: '${runner}'\n    steps_dir: features/steps\nprotect: []\n`);
  const md = '.kogen/intents/native-fixture/intent.md', ft = '.kogen/intents/native-fixture/acceptance.feature', step = 'features/steps/native_fixture_steps.js';
  put(path.join(repo, md), `# Preserve fixture text\n\nSlug: native-fixture\nModel: not applicable — text wiring\nAcceptance:\n- ${ft}\n- ${step}\n\nKeep app.txt unchanged.\n\n## Decisions\n- Keep text (source: request)\n\n## Source comparison\n- addressed: fixture text is preserved by the scenario.\n\n## Tests\n- Keep text: scenario (scenario)\n\n## Feasibility\n- none\n`);
  put(path.join(repo, ft), 'Feature: Native authority\n  Scenario: Preserve text\n    Then the migration fixture text is preserved\n');
  put(path.join(repo, step), 'const {Then}=require("@cucumber/cucumber");Then("the migration fixture text is preserved",()=>{require("node:assert/strict").equal(require("node:fs").readFileSync("app.txt","utf8"),"kept\\n");});\n');
  const git = args => must('git', args, repo, env); await git(['init', '-q']); await git(['config', 'user.name', 'Migration Fixture']); await git(['config', 'user.email', 'migration@example.invalid']); await git(['add', '.']); await git(['commit', '-qm', 'Fixture baseline']);
  const head = (await git(['rev-parse', 'HEAD'])).trim(), index = fs.readFileSync(path.join(repo, '.git/index'));
  const sha = s => crypto.createHash('sha256').update(s).digest('hex'); const baseline = [md, ft, step, '.kogen/project.yaml'];
  const expectedHash = sha(baseline.sort().map(p => p + '\0' + sha(fs.readFileSync(path.join(repo, p))) + '\n').join(''));
  const approval = path.join(repo, '.kogen/local/approvals/native-fixture.json');
  const card = await cli(['intent', 'approve', 'native-fixture']); exits.push(card.code);
  const absent = !fs.existsSync(approval);
  const wrong = await cli(['intent', 'approve', 'native-fixture', '0'.repeat(64)]); exits.push(wrong.code); const wrongKept = !fs.existsSync(approval);
  const approved = await cli(['intent', 'approve', 'native-fixture', expectedHash]); exits.push(approved.code);
  const approvalBytes = fs.existsSync(approval) ? fs.readFileSync(approval) : Buffer.from('null');
  fs.appendFileSync(path.join(repo, ft), '\n# changed protected bytes\n');
  const stale = await cli(['intent', 'build', 'native-fixture']); exits.push(stale.code);
  return { exits, statuses: listed.out.trim().split('\n'), hash_matches: card.out.includes('SHA-256: ' + expectedHash), no_approval_on_card_or_mismatch: absent && wrongKept, approved_exact: JSON.parse(approvalBytes).sha256 === expectedHash, stale_refused: stale.out.includes('intent/changed_since_approval:'), custody: fs.existsSync(approval) && fs.readFileSync(approval).equals(approvalBytes) && fs.readFileSync(path.join(repo, '.git/index')).equals(index) && (await git(['rev-parse', 'HEAD'])).trim() === head && fs.readFileSync(path.join(repo, 'app.txt'), 'utf8') === 'kept\n', modes: ['opencode-go', 'anthropic'].map(p => fs.statSync(path.join(home, '.kogen/credentials', p + '.json')).mode & 511) };
}
async function suites(files, installed, excluded = []) {
  const c = await candidate(), temp = temporary(), home = path.join(temp, 'home'); fs.mkdirSync(home); put(path.join(home, '.gitconfig'), '');
  const cwd = installed ? path.join(ROOT, 'test/acceptance') : ROOT;
  const inputs = files.map(f => path.resolve(ROOT, f)); const { expected, ignored } = selection(inputs, cwd, excluded), report = path.join(temp, 'messages.ndjson');
  const args = [cucumber(), '--strict', '--tags', 'not @live', '--format', 'message:' + report, '--require', installed ? 'steps/*.js' : 'features/steps/*.js'];
  if (installed) args.push('--require', 'support/*.js'); args.push(...inputs);
  const r = await run(process.execPath, args, cwd, { ...localEnv(home), NODE_PATH: process.env.KOGEN_CUCUMBER, KOGEN_ARCHIVE: c.nativeArchive });
  if (!excluded.length) assert.equal(r.code, 0, r.out);
  assert.ok(fs.existsSync(report), 'missing scenario report\n' + r.out);
  // KOGEN_MIGRATION_REPORTS keeps each inner report (evidence tables are made from what the gate ran).
  if (process.env.KOGEN_MIGRATION_REPORTS) { fs.mkdirSync(process.env.KOGEN_MIGRATION_REPORTS, { recursive: true }); fs.copyFileSync(report, path.join(process.env.KOGEN_MIGRATION_REPORTS, `${Date.now()}-${installed ? 'specs' : 'contracts'}-${files.length}.ndjson`)); }
  let failedIgnored;
  try { failedIgnored = checkReport(fs.readFileSync(report, 'utf8').trim().split('\n').map(JSON.parse), expected, cwd, ignored); judgeExit(r.code, failedIgnored, excluded.length > 0); }
  catch (e) { e.message += '\n' + r.out.slice(-6000); throw e; }
  return { passed: expected.length, ignored: ignored.size, complete: true };
}
// ---- Prompt caching: one approved Intent built and independently reviewed with the installed candidate ----
const CACHE_MODELS = { chatgpt: 'gpt-6.1-sol', supergrok: 'grok-4.7', 'opencode-go': 'kimi-k3', anthropic: 'claude-sonnet-5-5', 'openai-compatible': 'qwen3-coder:30b' };
function cacheRoles(provider, baseUrl) {
  // ChatGPT is the default provider: its roles omit the provider field, as an older project does.
  // OpenAI-compatible names its host with base_url (the fake's /v1), never through KOGEN_PROVIDER_URL.
  const role = effort => `{${provider === 'chatgpt' ? '' : 'provider: ' + provider + ', '}model: ${CACHE_MODELS[provider]}, effort: ${effort}${provider === 'openai-compatible' ? ', base_url: ' + baseUrl : ''}}`;
  return `models:\n  shape: ${role('high')}\n  build: ${role('high')}\n  review: ${role('high')}\nshape_workers:\n  enabled: false\n`;
}
function seedLogin(home, provider) {
  // Credentials stored the way each provider's login stores them (0600 file in a 0700 private folder).
  const data = provider === 'supergrok'
    ? { client_id: 'b1a00492-073a-47ea-816f-4c329264a828', referrer: 'kogen', access_token: 'SYNTHETIC_CACHE_ACCESS', refresh_token: 'SYNTHETIC_CACHE_REFRESH', expires_at: Math.floor(Date.now() / 1000) + 3600, scope: 'openid profile email offline_access grok-cli:access api:access' }
    : { client_id: 'oaiapp_synthetic', access_token: 'SYNTHETIC_CACHE_ACCESS', refresh_token: 'SYNTHETIC_CACHE_REFRESH', expires_at: Math.floor(Date.now() / 1000) + 3600, scope: 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct' };
  const dir = path.join(home, '.kogen/credentials'); fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  for (const d of [path.dirname(dir), dir]) fs.chmodSync(d, 0o700);
  const file = path.join(dir, provider + '.json'); fs.writeFileSync(file, JSON.stringify(data), { mode: 0o600 }); fs.chmodSync(file, 0o600);
}
function runLogAttempts(repo) {
  const runs = path.join(repo, '.kogen/local/runs'), seen = new Set(), out = [];
  if (!fs.existsSync(runs)) return out;
  for (const id of fs.readdirSync(runs).sort()) {
    const log = path.join(runs, id, 'log.jsonl'); if (!fs.existsSync(log)) continue;
    for (const line of fs.readFileSync(log, 'utf8').split('\n').filter(Boolean)) {
      let e; try { e = JSON.parse(line); } catch { continue; }
      if (e.event === 'provider_attempt' && e.provider && !seen.has(e.provider.attempt_id ?? line)) { seen.add(e.provider.attempt_id ?? line); out.push(e.provider); }
    }
  }
  return out;
}
async function cacheJourney(provider) {
  assert.ok(Object.hasOwn(CACHE_MODELS, provider), 'unknown caching provider: ' + provider);
  const c = await candidate(), temp = temporary(), home = path.join(temp, 'home'), repo = path.join(temp, 'repo'), prefix = path.join(temp, 'prefix');
  fs.mkdirSync(home); fs.mkdirSync(repo); put(path.join(home, '.gitconfig'), '');
  // The builder's second request is held until the harness interrupts kogen (exit 130).
  const fake = await cacheFake.startFake(provider, { hold: { phase: 'build', after: 1 } }), sink = await cacheFake.startSink();
  try {
    // OpenAI-compatible is reached only through its role's base_url: KOGEN_PROVIDER_URL stays unusable.
    const env = { ...localEnv(home), ...(provider === 'openai-compatible' ? {} : { KOGEN_PROVIDER_URL: fake.url }), KOGEN_AUTH_URL: sink.url };
    await must('sh', [path.join(c.release, 'install.sh'), '--prefix', prefix], ROOT, env);
    const bin = path.join(prefix, 'bin/kogen'), cli = (args, input) => run(bin, args, repo, env, input), git = args => must('git', args, repo, env);
    if (provider === 'opencode-go' || provider === 'anthropic') { const r = await cli(['provider', 'login', provider], 'SYNTHETIC_CACHE_KEY\n'); assert.equal(r.code, 0, 'provider login ' + provider + ': ' + r.out); }
    else if (provider !== 'openai-compatible') seedLogin(home, provider); // openai-compatible runs keyless: no login at all
    const runner = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
    put(path.join(repo, '.gitignore'), '.kogen/local/\n'); put(path.join(repo, 'README.md'), '# Prompt caching fixture\n'); put(path.join(repo, 'app.txt'), 'baseline\n');
    put(path.join(repo, '.kogen/project.yaml'), `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: '${runner}'\n    steps_dir: features/steps\nprotect: []\n${cacheRoles(provider, fake.url + '/v1')}`);
    put(path.join(repo, '.kogen/intents/fixture/intent.md'), '# Preserve the caching fixture\n\nSlug: fixture\nModel: not applicable — plain fixture wiring\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/fixture_steps.js\n\nAllow baseline or candidate text in app.txt.\n\n## Decisions\n- Preserve fixture text (source: request)\n\n## Source comparison\n- addressed: fixture request; prose and scenario preserve text.\n\n## Tests\n- Fixture text: local scenario (scenario)\n\n## Feasibility\n- none\n');
    put(path.join(repo, '.kogen/intents/fixture/acceptance.feature'), 'Feature: Fixture\n  Scenario: Preserve text\n    Then caching fixture text is present\n');
    put(path.join(repo, 'features/steps/fixture_steps.js'), "const {Then}=require('@cucumber/cucumber');const fs=require('node:fs');Then('caching fixture text is present',()=>{if(!['baseline\\n','candidate\\n'].includes(fs.readFileSync('app.txt','utf8')))throw Error('invalid text');});\n");
    for (const args of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Caching Fixture'], ['config', 'user.email', 'caching@example.invalid'], ['add', '.'], ['commit', '-qm', 'baseline']]) await git(args);
    const card = await cli(['intent', 'approve', 'fixture']), hash = /SHA-256: ([0-9a-f]{64})/.exec(card.out)?.[1];
    assert.ok(hash, 'approval card has no SHA-256: ' + card.out);
    const approved = await cli(['intent', 'approve', 'fixture', hash]); assert.equal(approved.code, 0, 'approve: ' + approved.out);
    const head = (await git(['rev-parse', 'HEAD'])).trim();
    // Build until the builder's second request is in flight, then interrupt.
    const build = start(bin, ['intent', 'build', 'fixture'], repo, env);
    let timer; const guard = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('the builder never reached its second request')), 240000); });
    const early = build.result.then(r => { throw new Error('build ended (exit ' + r.code + ') before its second request was held: ' + r.out.slice(-3000) + ' [requests: ' + fake.records.length + ']'); });
    try { await Promise.race([fake.reached, early, guard]); } finally { clearTimeout(timer); }
    build.child.kill('SIGINT');
    const interrupted = await build.result;
    assert.equal(interrupted.code, 130, 'interrupted build must exit 130: ' + interrupted.out.slice(-3000));
    const runs = path.join(repo, '.kogen/local/runs'), ids = fs.existsSync(runs) ? fs.readdirSync(runs).filter(n => /^[0-9a-f]{8}/.test(n)) : [];
    assert.equal(ids.length, 1, 'one interrupted run expected: ' + interrupted.out.slice(-3000));
    const resumed = await cli(['intent', 'resume', ids[0]]);
    const phases = ph => fake.records.filter(r => r.phase === ph && r.answered).length;
    assert.equal(resumed.code, 0, 'resume must finish the Build (exit ' + resumed.code + '; answered build ' + phases('build') + ', review ' + phases('review') + '): ' + resumed.out.slice(-3000));
    assert.deepEqual([phases('build'), phases('review')], [2, 2], 'builder and reviewer did not follow the script');
    assert.equal((await git(['show', 'HEAD:app.txt'])), 'candidate\n', 'the Build did not land the candidate');
    assert.notEqual((await git(['rev-parse', 'HEAD'])).trim(), head, 'no commit landed');
    if (provider === 'openai-compatible') {
      // Keyless: no Authorization header, and every request went to <base_url>/chat/completions.
      assert.ok(fake.records.length > 0 && fake.records.every(r => r.headers.authorization === undefined), 'a keyless openai-compatible request carried Authorization');
      assert.ok(fake.records.every(r => r.path === '/v1/chat/completions' && r.method === 'POST'), 'openai-compatible must post to <base_url>/chat/completions: ' + fake.records.map(r => r.method + ' ' + r.path));
    }
    const usage = await cli(['intent', 'usage', '--json']); let report = null; try { report = JSON.parse(usage.out); } catch {}
    return { ...cacheFake.observe(provider, fake.records), recorded_cached_matches_fake: cacheFake.recordedMatches(fake.records, runLogAttempts(repo)), usage_reports_cached_share: cacheFake.usageMatches(fake.records, report) };
  } finally { await fake.close(); await sink.close(); }
}
// ---- A genuine C3 (c3ee2a8e) version-2 checkpoint, resumed by the installed candidate ----
// Pinned from main 76109e1 on 2026-10-24: its own release archive (kogen-76109e1a-darwin-arm64.tar.gz) installed and given the same
// genuine C3 blocked run (green pass, red final pass, latest review `changes`, written by the C3 producer built from the
// provenance-bound fixture in test/migration/fixtures/c3-producer) answered `kogen intent resume <id>` with exit 1 and exactly
//   candidate/resume_refused: Build <id>: incompatible checkpoint version 2; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build
//     no newly created Build run; correct the named prerequisite before trying again
// (nothing on stderr), made no provider request, created no run directory and changed no byte of HEAD, index, approvals, the run
// directory, the checkpoint or the working tree. Its read-only `kogen intent inspect <id>` exited 1 with the JSON
// {"kind":"run","data":null,"error":{"class":"intent","reason":"run_not_found","detail":"run_not_found"}}: inspect reads
// `.kogen/local/facts/<id>.json`, which only a run of the current Kogen writes, so main does not read a C3 run either. The
// installed candidate gave the identical code, text and byte-identity (checked the same day).
async function c3Checkpoint() {
  const c = await candidate(), temp = temporary(), home = path.join(temp, 'home'), prefix = path.join(temp, 'prefix');
  fs.mkdirSync(home); put(path.join(home, '.gitconfig'), '');
  await must('sh', [path.join(c.release, 'install.sh'), '--prefix', prefix], ROOT, localEnv(home));
  const producer = await (c3Producer ||= reopenProducer.localProducer(os.tmpdir()));
  let codesign = true; // only macOS signs; elsewhere there is no signature to verify
  if (process.platform === 'darwin') codesign = (await run('codesign', ['--verify', producer.bin])).code === 0;
  const r = await reopenC3.c3ResumeObservations({ candidatePrefix: prefix, bin: producer.bin }), refusal = `candidate/resume_refused: Build ${r.id}: incompatible checkpoint version 2; inspect the checkpoint and checkout, correct drift or obtain fresh approval for a new Build\n  no newly created Build run; correct the named prerequisite before trying again\n`;
  let inspected = null; try { inspected = JSON.parse(r.inspect.stdout); } catch {}
  return {
    c3_version_line: r.c3Version === 'kogen c3ee2a8e (2026-10-19)' && r.c3VersionCode === 0 && producer.version === r.c3Version,
    c3_codesign_verified: codesign,
    candidate_is_not_c3: !/c3ee2a8e/.test(r.candidateVersion),
    blocked_run_reproduced: r.blocked,
    checkpoint_version: r.checkpointVersion,
    resume_exit: r.resume.code,
    resume_output_exact: r.resume.stdout === refusal && r.resume.stderr === '',
    provider_requests_during_resume: r.resumeRequests,
    new_build_run_directories: r.newRunDirs,
    state_unchanged_after_resume: r.unchangedAfterResume,
    inspect_exit: r.inspect.code,
    inspect_error: inspected && inspected.kind === 'run' && inspected.data === null && inspected.error ? inspected.error.class + '/' + inspected.error.reason : null,
    state_unchanged_after_inspect: r.unchangedAfterInspect,
  };
}
function compareC3(actual, expected) {
  assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort(), 'observed and tabled keys differ');
  for (const [k, v] of Object.entries(expected)) assert.deepEqual(actual[k], v, k + ': ' + JSON.stringify(actual));
}
// ---- Open model selection (KOGEN-057): any model and effort reach every provider unchanged ----
const OPEN_MODEL = 'model-nobody-listed-1', OPEN_EFFORT = 'effort-nobody-listed', OPEN_SECRET = 'SYNTHETIC_LOCAL_HOST_KEY';
const OPEN_LABELS = { chatgpt: 'ChatGPT', supergrok: 'SuperGrok', 'opencode-go': 'OpenCode Go', anthropic: 'Anthropic', 'openai-compatible': 'OpenAI-compatible' };
const OPEN_REFUSAL = { status: 404, body: { error: { message: 'The model does not exist or you do not have access to it.', type: 'invalid_request_error', code: 'model_not_found' } } };
// What a request carries as its model and effort, per wire (the effort is absent when none is sent).
function sentModelEffort(provider, body) {
  if (provider === 'anthropic') return { model: body.model, effort: body.output_config?.effort };
  if (cacheFake.PATHS[provider].endsWith('/chat/completions')) return { model: body.model, effort: body.reasoning_effort };
  return { model: body.model, effort: body.reasoning?.effort };
}
// A fresh project and home against a fake that answers every request with `refuse` (a model
// refusal by default), then one command of the installed candidate. `role` is the YAML of the
// provider-specific part of every role; `fakeBase` puts the fake's /v1 into it as base_url.
async function openModelCase(c, prefix, { provider, model = OPEN_MODEL, effort = OPEN_EFFORT, roleExtra = '', refuse = OPEN_REFUSAL, key = null, command = 'shape', login = false }) {
  const temp = temporary(), home = path.join(temp, 'home'), repo = path.join(temp, 'repo');
  fs.mkdirSync(home); fs.mkdirSync(repo); put(path.join(home, '.gitconfig'), '');
  const fake = await cacheFake.startFake(provider, { refuse });
  try {
    // KOGEN_PROVIDER_URL reaches only the four built-in providers; openai-compatible must use its base_url.
    const env = { ...localEnv(home), ...(provider === 'openai-compatible' ? {} : { KOGEN_PROVIDER_URL: fake.url }) };
    const bin = path.join(prefix, 'bin/kogen'), cli = (args, input) => run(bin, args, repo, env, input), git = args => must('git', args, repo, env);
    const out = {};
    if (key !== null) { const l = await cli(['provider', 'login', provider], key + '\n'); out.login = l; assert.equal(l.code, 0, 'provider login: ' + l.out); }
    else if (provider === 'opencode-go' || provider === 'anthropic') { const l = await cli(['provider', 'login', provider], 'SYNTHETIC_OPEN_MODEL_KEY\n'); assert.equal(l.code, 0, l.out); }
    else if (provider === 'chatgpt' || provider === 'supergrok') seedLogin(home, provider);
    out.list = await cli(['provider', 'list']);
    const base = provider === 'openai-compatible' ? roleExtra.replace('<fake>', fake.url) : roleExtra;
    const role = `{${provider === 'chatgpt' ? '' : 'provider: ' + provider + ', '}model: ${model}, effort: ${effort}${base}}`;
    const runner = 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require "features/steps/*.js" --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"';
    put(path.join(repo, '.gitignore'), '.kogen/local/\n'); put(path.join(repo, 'README.md'), '# Open model selection fixture\n');
    put(path.join(repo, '.kogen/project.yaml'), `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: '${runner}'\n    steps_dir: features/steps\nprotect: []\nmodels:\n  shape: ${role}\n  build: ${role}\n  review: ${role}\nshape_workers:\n  enabled: false\n`);
    put(path.join(repo, 'request.md'), 'Add a greeting file.\n');
    for (const args of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Open Model Fixture'], ['config', 'user.email', 'open-model@example.invalid'], ['add', '.'], ['commit', '-qm', 'baseline']]) await git(args);
    out.run = await cli(['intent', command, 'greeting', 'request.md']);
    out.records = fake.records; out.home = home;
    return out;
  } finally { await fake.close(); }
}
async function openModel() {
  const c = await candidate(), temp = temporary(), prefix = path.join(temp, 'prefix');
  await must('sh', [path.join(c.release, 'install.sh'), '--prefix', prefix], ROOT, localEnv(path.join(temp, 'install-home')));
  const obs = {}, trimmed = out => out.split('\n').map(l => l.trim());
  // The lines of a command's output that carry the provider's first error and the model hint.
  const errorLine = out => trimmed(out).find(l => /^provider\/[a-z_]+: /.test(l)) ?? null;
  const hintLine = out => trimmed(out).find(l => /^model .* was sent to /.test(l)) ?? null;
  // The refusal of a configuration, without the temporary checkout's own path.
  const configLines = out => trimmed(out).filter(Boolean).map(l => l.replace(/^(environment\/project_config_invalid:) .*(\.kogen\/project\.yaml)$/, '$1 <checkout>/$2'));
  const base = ', base_url: <fake>/v1';
  // (a) and (b): a model and effort no list knows reach every provider unchanged; its refusal is clear.
  for (const provider of Object.keys(OPEN_LABELS)) {
    const r = await openModelCase(c, prefix, { provider, roleExtra: provider === 'openai-compatible' ? base : '' }), first = r.records[0] && JSON.parse(r.records[0].raw);
    Object.assign(obs, {
      [provider + ': exit']: r.run.code, [provider + ': requests']: r.records.length, [provider + ': path']: r.records[0]?.path ?? null,
      [provider + ': model sent']: first ? sentModelEffort(provider, first).model : null, [provider + ': effort sent']: first ? sentModelEffort(provider, first).effort : null,
      [provider + ': error line']: errorLine(r.run.out), [provider + ': hint line']: hintLine(r.run.out),
    });
  }
  // Effort "default" means no reasoning_effort at all on the chat wires.
  for (const provider of ['opencode-go', 'openai-compatible']) {
    const r = await openModelCase(c, prefix, { provider, effort: 'default', roleExtra: provider === 'openai-compatible' ? base : '' }), first = r.records[0] && JSON.parse(r.records[0].raw);
    Object.assign(obs, {
      [provider + ' with effort default: requests']: r.records.length, [provider + ' with effort default: model sent']: first?.model ?? null,
      [provider + ' with effort default: reasoning_effort']: first ? (Object.hasOwn(first, 'reasoning_effort') ? first.reasoning_effort : 'absent') : null,
    });
  }
  // A host that refuses without any error code (Ollama style, 404) and an invalid effort (400): still one request, with the hint.
  const ollama = { status: 404, body: { error: { message: 'model "model-nobody-listed-1" not found, try pulling it first', type: 'api_error', param: null, code: null } } };
  const invalid = { status: 400, body: { error: { message: 'invalid reasoning_effort', type: 'invalid_request_error', param: 'reasoning_effort', code: 'invalid_request_error' } } };
  for (const [name, refuse] of [['no error code (404)', ollama], ['invalid effort (400)', invalid]]) {
    const r = await openModelCase(c, prefix, { provider: 'openai-compatible', roleExtra: base, refuse });
    Object.assign(obs, { ['openai-compatible ' + name + ': exit']: r.run.code, ['openai-compatible ' + name + ': requests']: r.records.length, ['openai-compatible ' + name + ': error line']: errorLine(r.run.out), ['openai-compatible ' + name + ': hint line']: hintLine(r.run.out) });
  }
  // (c) The key is optional: none sends no Authorization and lists nothing new; a saved one is sent as a Bearer token.
  const keyless = await openModelCase(c, prefix, { provider: 'openai-compatible', roleExtra: base });
  const keyed = await openModelCase(c, prefix, { provider: 'openai-compatible', roleExtra: base, key: OPEN_SECRET });
  const mode = fs.statSync(path.join(keyed.home, '.kogen/credentials/openai-compatible.json')).mode & 511;
  Object.assign(obs, {
    'keyless openai-compatible: provider list': trimmed(keyless.list.out).filter(Boolean), 'keyless openai-compatible: Authorization header': keyless.records[0]?.headers.authorization ?? 'absent',
    'keyless openai-compatible: exit': keyless.run.code,
    'openai-compatible login: exit': keyed.login.code, 'openai-compatible login: output': trimmed(keyed.login.out).filter(Boolean), 'openai-compatible login: credential file mode': mode,
    'saved key: provider list': trimmed(keyed.list.out).filter(Boolean), 'saved key: Authorization header': keyed.records[0]?.headers.authorization ?? 'absent', 'saved key: exit': keyed.run.code, 'saved key: requests': keyed.records.length,
  });
  // (d) base_url belongs to openai-compatible alone, and openai-compatible needs a valid one: refused before any request.
  const refusals = [
    ['base_url on chatgpt', { provider: 'chatgpt', roleExtra: ', base_url: http://127.0.0.1:1/v1' }],
    ['base_url on supergrok', { provider: 'supergrok', roleExtra: ', base_url: http://127.0.0.1:1/v1' }],
    ['base_url on opencode-go', { provider: 'opencode-go', roleExtra: ', base_url: http://127.0.0.1:1/v1' }],
    ['base_url on anthropic', { provider: 'anthropic', roleExtra: ', base_url: http://127.0.0.1:1/v1' }],
    ['openai-compatible without base_url', { provider: 'openai-compatible', roleExtra: '' }],
    ['openai-compatible with base_url ftp://host/v1', { provider: 'openai-compatible', roleExtra: ', base_url: ftp://host/v1' }],
  ];
  for (const [name, spec] of refusals) {
    const r = await openModelCase(c, prefix, spec);
    Object.assign(obs, { [name + ': exit']: r.run.code, [name + ': requests']: r.records.length, [name + ': output']: configLines(r.run.out) });
  }
  return obs;
}
// Every row of the table is an observation and every observation is a row; values are exact JSON.
function compareOpen(actual, expected) {
  assert.deepEqual(Object.keys(actual).sort(), Object.keys(expected).sort(), 'observed and tabled keys differ');
  for (const [k, v] of Object.entries(expected)) assert.deepEqual(actual[k], v, k + ': ' + JSON.stringify(actual[k]));
}
// The caching control: the same fake and observers judge synthetic request sequences, a good
// one per provider (which must meet the table exactly) and deliberately cache-breaking ones
// (each of which must produce violations or a refused table). The fake's HTTP behaviour is
// checked against the same cache model through real requests.
async function cacheControl(bad) {
  const ok = { recorded_cached_matches_fake: true, usage_reports_cached_share: true };
  const table = p => ({ ...cacheFake.EXPECTED(p), ...ok });
  const providers = Object.keys(CACHE_MODELS);
  for (const p of providers) {
    const records = cacheFake.synthetic(p), seen = { ...cacheFake.observe(p, records), ...ok };
    cacheFake.compareCache(assert, seen, table(p));
    cacheFake.compareCache(assert, { ...seen, min_cached_share_after_first: 1 }, { min_cached_share_after_first: 0.9 }); // a minimum: more is fine
    const served = await cacheFake.startFake(p);
    try {
      for (const r of records) await new Promise((resolve, reject) => { const q = require('node:http').request(served.url + cacheFake.PATHS[p], { method: 'POST', headers: r.headers }, res => { res.resume(); res.on('end', resolve); }); q.on('error', reject); q.end(r.raw); });
      assert.deepEqual(served.records.map(r => r.usage), records.map(r => r.usage), p + ': served cache differs from the model');
      assert.ok(served.records.every(r => r.answered), p + ': fake did not answer every request');
    } finally { await served.close(); }
  }
  if (!bad) return;
  const flaws = { 'openai-compatible': ['clock', 'rewrite', 'vendor', 'vendorbody'], chatgpt: ['clock', 'rotate', 'rewrite', 'nokey', 'options'], supergrok: ['clock', 'rotate', 'rewrite', 'nokey'], 'opencode-go': ['clock', 'rotate', 'rewrite', 'nokey'], anthropic: ['clock', 'rewrite', 'extra', 'nomark'] };
  for (const p of providers) for (const flaw of flaws[p]) {
    const seen = { ...cacheFake.observe(p, cacheFake.synthetic(p, flaw)), ...ok };
    assert.throws(() => cacheFake.compareCache(assert, seen, table(p)), undefined, p + ' accepted the ' + flaw + ' sequence: ' + JSON.stringify(seen));
  }
  const good = table('chatgpt');
  for (const key of Object.keys(good)) {
    const corrupt = structuredClone(good); delete corrupt[key]; assert.throws(() => cacheFake.compareCache(assert, corrupt, good), undefined, 'missing ' + key);
    const wrong = structuredClone(good); wrong[key] = key === 'min_cached_share_after_first' ? 0.89 : null; assert.throws(() => cacheFake.compareCache(assert, wrong, good), undefined, 'wrong ' + key);
  }
}
// The exclusion control: a real Cucumber report in which one superseded scenario fails.
async function exclusionControl(bad) {
  const base = temporary(), feature = path.join(base, '.kogen/intents/ctl/acceptance.feature'), steps = path.join(base, 'steps.cjs'), report = path.join(base, 'messages.ndjson');
  put(feature, 'Feature: Exclusion control\n  Scenario: Kept\n    Then the observer control passes\n  Scenario: Superseded\n    Then the observer control fails\n  Scenario Outline: Kept outline <value>\n    Then the observer control passes\n    Examples:\n      | value |\n      | first |\n      | second |\n  Scenario Outline: Row outline\n    Then the observer control <result>\n    Examples:\n      | result |\n      | passes |\n      | fails  |\n');
  put(steps, 'const {Then}=require("@cucumber/cucumber");Then("the observer control passes",()=>{});Then("the observer control fails",()=>{throw new Error("superseded failure");});\n');
  const r = await run(process.execPath, [cucumber(), '--strict', '--require', steps, '--format', 'message:' + report, feature], ROOT, { NODE_PATH: process.env.KOGEN_CUCUMBER });
  assert.equal(r.code, 1, r.out);
  const envelopes = fs.readFileSync(report, 'utf8').trim().split('\n').map(JSON.parse), rows = [['ctl', 'Superseded'], ['ctl', 'Row outline', 'fails']];
  const { expected, ignored, all } = selection([feature], ROOT, exclusions(rows, base));
  // One whole scenario and one example row of an outline whose rows share their name are superseded.
  assert.equal(all.length, 6); assert.equal(expected.length, 4); assert.equal(ignored.size, 2);
  const failed = checkReport(envelopes, expected, ROOT, ignored); assert.equal(failed, 2); judgeExit(r.code, failed, true);
  assert.equal(exclusions([['ctl', 'Kept outline <value>']], base).length, 1); // an outline is named by its own title
  if (!bad) return;
  assert.throws(() => checkReport(envelopes, all, ROOT), undefined, 'a failing scenario passed without an exclusion');
  assert.throws(() => exclusions([['ctl', 'Superseded scenario']], base), undefined, 'a missing scenario was accepted');
  assert.throws(() => exclusions([['ctl', 'superseded']], base), undefined, 'a scenario name is exact');
  assert.throws(() => exclusions([['nowhere', 'Superseded']], base), undefined, 'a missing feature was accepted');
  assert.throws(() => exclusions([['ctl', 'Superseded'], ['ctl', 'Superseded']], base), undefined, 'a duplicate was accepted');
  assert.throws(() => exclusions([['ctl', 'Row outline', 'missing']], base), undefined, 'a missing example row was accepted');
  assert.equal(exclusions([['ctl', 'Row outline', 'fails']], base).length, 1);
  assert.throws(() => exclusions([['ctl', 'Row outline', 'fails'], ['ctl', 'Row outline', '']], base), undefined, 'a row superseded twice was accepted');
  { const only = selection([feature], ROOT, exclusions([['ctl', 'Superseded']], base));
    assert.throws(() => checkReport(envelopes, only.expected, ROOT, only.ignored), undefined, 'a failing example row passed without its own exclusion'); }
  assert.throws(() => judgeExit(1, 0, true)); assert.throws(() => judgeExit(2, 1, true)); assert.throws(() => judgeExit(1, 1, false)); assert.throws(() => judgeExit(null, 1, true));
  const failing = structuredClone(envelopes), kept = envelopes.findIndex(e => e.testStepFinished && e.testStepFinished.testStepResult.status === 'PASSED'); // only kept scenarios pass a step here
  failing[kept].testStepFinished.testStepResult.status = 'FAILED'; assert.throws(() => checkReport(failing, expected, ROOT, ignored), undefined, 'a failing kept scenario was ignored');
  const absent = envelopes.filter(e => !e.testCaseFinished); assert.throws(() => checkReport(absent, expected, ROOT, ignored), undefined, 'missing kept scenarios were accepted');
  const twice = [...envelopes, envelopes.find(e => e.testCaseFinished)]; assert.throws(() => checkReport(twice, expected, ROOT, ignored), undefined, 'a duplicate finish was accepted');
}
async function control(bad) {
  const temp = temporary(), feature = path.join(temp, 'control.feature'), steps = path.join(temp, 'steps.cjs'), report = path.join(temp, 'messages.ndjson');
  put(feature, 'Feature: Observer control\n  Scenario: One\n    Then the observer control passes\n  Scenario Outline: Ordered <value>\n    Then the observer control passes\n    Examples:\n      | value |\n      | first |\n      | second |\n');
  put(steps, 'require("@cucumber/cucumber").Then("the observer control passes",()=>{});\n');
  await must(process.execPath, [cucumber(), '--strict', '--require', steps, '--format', 'message:' + report, feature], ROOT, { NODE_PATH: process.env.KOGEN_CUCUMBER });
  const expected = pickles([feature], ROOT), envelopes = fs.readFileSync(report, 'utf8').trim().split('\n').map(JSON.parse); checkReport(envelopes, expected, ROOT);
  const good = { exits: [0, 0, 0, 5, 1, 0, 1], statuses: ['chatgpt: not signed in', 'supergrok: not signed in', 'opencode-go: key saved (not verified)', 'anthropic: key saved (not verified)'], hash_matches: true, no_approval_on_card_or_mismatch: true, approved_exact: true, stale_refused: true, custody: true, modes: [384, 384] }; compare(structuredClone(good), good);
  const open = { 'a: exit': 4, 'a: error line': 'x', 'b: requests': 1 }; compareOpen(structuredClone(open), open);
  await exclusionControl(bad); await cacheControl(bad);
  const c3 = { c3_version_line: true, c3_codesign_verified: true, checkpoint_version: 2, resume_exit: 1, resume_output_exact: true, provider_requests_during_resume: 0, new_build_run_directories: 0, state_unchanged_after_resume: true, inspect_exit: 1, inspect_error: 'intent/run_not_found' };
  compareC3(structuredClone(c3), c3);
  if (bad) {
    for (const key of Object.keys(open)) { const corrupt = structuredClone(open); delete corrupt[key]; assert.throws(() => compareOpen(corrupt, open), undefined, 'missing ' + key); const wrong = structuredClone(open); wrong[key] = null; assert.throws(() => compareOpen(wrong, open), undefined, 'wrong ' + key); }
    assert.throws(() => compareOpen({ ...open, extra: 1 }, open), undefined, 'an unlisted observation was accepted');
    for (const key of Object.keys(c3)) { const corrupt = structuredClone(c3); delete corrupt[key]; assert.throws(() => compareC3(corrupt, c3), undefined, 'missing C3 ' + key); const wrong = structuredClone(c3); wrong[key] = typeof c3[key] === 'number' ? c3[key] + 1 : typeof c3[key] === 'boolean' ? !c3[key] : null; assert.throws(() => compareC3(wrong, c3), undefined, 'wrong C3 ' + key); }
    assert.throws(() => compareC3({ ...c3, extra: 1 }, c3), undefined, 'an unlisted C3 observation was accepted');
    for (const key of Object.keys(good)) { const corrupt = structuredClone(good); delete corrupt[key]; assert.throws(() => compare(corrupt, good)); const wrong = structuredClone(good); wrong[key] = null; assert.throws(() => compare(wrong, good)); }
    const absent = envelopes.filter(e => !e.testCaseFinished); assert.throws(() => checkReport(absent, expected, ROOT));
    const duplicate = [...envelopes, envelopes.find(e => e.testCaseFinished)]; assert.throws(() => checkReport(duplicate, expected, ROOT));
    const skipped = structuredClone(envelopes); skipped.find(e => e.testStepFinished).testStepFinished.testStepResult.status = 'SKIPPED'; assert.throws(() => checkReport(skipped, expected, ROOT));
    const missing = expected.slice(1); assert.throws(() => checkReport(envelopes, missing, ROOT));
    process.stdout.write('rejected\n'); process.exitCode = 1;
  } else process.stdout.write('accepted\n');
}
if (require.main === module) {
  control(process.argv[3] === 'bad').catch(e => { console.error(e.stack); process.exitCode = 2; }).finally(() => { for (const p of work) fs.rmSync(p, { recursive: true, force: true }); });
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  When('I exercise Go migration local authority', { timeout: 600000 }, async function () { this.goMigration = await authority(); });
  Then('the Go migration authority observations are:', function (table) { compare(this.goMigration, Object.fromEntries(table.raw().map(([k, v]) => [k, JSON.parse(v)]))); });
  When('I run these Go migration installed specifications:', { timeout: 1800000 }, async function (table) { this.goMigration = await suites(table.raw().map(r => r[0]), true); });
  // Each approved change declares its own superseded scenarios (prompt caching: KOGEN-054; open model selection:
  // KOGEN-057); a scenario superseded twice is still a table mistake.
  const supersede = function (table) { this.goSupersededRows = [...(this.goSupersededRows || []), ...table.raw()]; this.goSuperseded = exclusions(this.goSupersededRows); };
  Given('these accumulated scenarios are superseded by prompt caching:', supersede);
  Given('these accumulated scenarios are superseded by open model selection:', supersede);
  Given('these accumulated scenarios are superseded by main\'s version-3 checkpoint rule:', supersede);
  When('I resume a genuine C3 version-2 checkpoint with the installed candidate', { timeout: 900000 }, async function () { this.goC3 = await c3Checkpoint(); if (process.env.KOGEN_MIGRATION_VERBOSE) console.error(JSON.stringify(this.goC3, null, 1)); });
  Then('the Go migration C3 checkpoint observations are:', function (table) {
    compareC3(this.goC3, Object.fromEntries(table.raw().map(([k, v]) => [k, JSON.parse(v)])));
  });
  When('I run these accumulated Go migration contracts:', { timeout: 3600000 }, async function (table) { this.goMigration = await suites(table.raw().map(r => '.kogen/intents/' + r[0] + '/acceptance.feature'), false, this.goSuperseded || []); });
  When('I build and independently review one approved Intent with the installed candidate on the caching {word} fake, interrupting the builder once and resuming it', { timeout: 900000 }, async function (provider) { this.goCache = await cacheJourney(provider); if (process.env.KOGEN_MIGRATION_VERBOSE) console.error(provider + ' ' + JSON.stringify(this.goCache)); });
  // min_cached_share_after_first is a minimum (the table value is a lower bound); every other key is exact.
  When('I run the open model selection journeys with the installed candidate', { timeout: 1800000 }, async function () { this.goOpen = await openModel(); if (process.env.KOGEN_MIGRATION_VERBOSE) console.error(JSON.stringify(this.goOpen, null, 1)); });
  Then('the Go migration open model observations are:', function (table) { compareOpen(this.goOpen, Object.fromEntries(table.raw().map(([k, v]) => [k, JSON.parse(v)]))); });
  Then('the Go migration cache observations are:', function (table) { cacheFake.compareCache(assert, this.goCache, Object.fromEntries(table.raw().map(([k, v]) => [k, JSON.parse(v)]))); });
  Then('every selected Go migration scenario passed exactly once', function () { assert.ok(this.goMigration.complete && this.goMigration.passed > 0); });
  When('I inspect Go migration source and archive for removed paths:', { timeout: 600000 }, async function (table) {
    const c = await candidate(); const listing = (await must('tar', ['-tzf', c.archive])).split('\n');
    for (const [p] of table.raw()) assert.ok(!fs.existsSync(path.join(ROOT, p)), 'obsolete core path remains: ' + p);
    assert.ok(!listing.some(p => /\/(release|erts-[^/]+|ebin)\//.test(p) || /\.(beam|ex|exs)$/.test(p)), 'Elixir runtime/source remains in archive');
    for (const dir of ['features/steps', 'test/kogen', 'test/integration']) if (fs.existsSync(path.join(ROOT, dir))) assert.ok(!fs.readdirSync(path.join(ROOT, dir)).some(n => /\.exs?$/.test(n)), 'unported Elixir tests: ' + dir);
    this.goMigration = { removed: true };
  });
  Then('the Go migration no longer ships an Elixir core', function () { assert.equal(this.goMigration.removed, true); });
  When('I run the Go migration deterministic delivery commands:', { timeout: 3600000 }, async function (table) {
    for (const [cwd, command] of table.raw()) await must('/bin/sh', ['-c', command], path.join(ROOT, cwd), { KOGEN_ARCHIVE: (await candidate()).archive });
    this.goMigration = { checked: true };
  });
  Then('the Go migration deterministic delivery commands all passed', function () { assert.equal(this.goMigration.checked, true); });
  AfterAll(async () => { if (c3Producer) reopenProducer.removeProducer(await c3Producer.catch(() => undefined)); for (const p of work) fs.rmSync(p, { recursive: true, force: true }); });
}
