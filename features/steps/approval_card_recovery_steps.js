'use strict';
// Approval-card recovery on the installed Go program: a scripted local provider, local Git projects and the `kogen`
// command only. Every observation is read from files, Git state, provider requests and the program's own output.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { isDeepStrictEqual } = require('node:util');
const H = require('./go_driver_support.js');

let sharedSuite;
const suiteOnce = () => sharedSuite || (sharedSuite = H.setupSuite());
async function cleanup() { if (sharedSuite) { const s = await sharedSuite; sharedSuite = null; H.cleanupSuite(s); } }

const put = (c, p, bytes) => { const full = path.join(c.repo, p); fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, bytes); };
const read = (c, p) => fs.readFileSync(path.join(c.repo, p));
const git = (c, args) => H.git(c, args);
const sha = (c, slug) => H.baselineHash(c, slug);
const marker = (c, slug) => H.approvalPath(c.repo, slug);
const provenancePath = (c, slug) => path.join(c.repo, `.kogen/local/provenance/${slug}/current.json`);
const readOrNull = file => { try { return fs.readFileSync(file); } catch (e) { if (e.code === 'ENOENT') return null; throw e; } };
const bytesEqual = (a, b) => (a === null || b === null) ? a === b : a.equals(b);
const state = async c => ({ head: await git(c, ['rev-parse', 'HEAD']), index: fs.readFileSync(path.join(c.repo, '.git/index')) });
const sameState = (a, b) => a.head === b.head && a.index.equals(b.index);
const count = c => c.server.providerRequests().length;
const append = (c, items) => { c.server.script.push(...items); };
const call = (name, args) => H.fn(name, args);
const docHash = bytes => H.sha(bytes);

async function invoke(c, args, exit) {
  const { out, code } = await H.runKogen(c, args);
  if (code !== exit) console.error('tool feedback', JSON.stringify(c.server.toolOutputs(), null, 1));
  assert.equal(code, exit, `expected ${exit}, got ${code}: ${out}`);
  return out;
}

function files(slug, helper, title) {
  const dir = `.kogen/intents/${slug}`;
  return {
    [`${dir}/intent.md`]: `# ${title}

Slug: ${slug}
Model: not applicable — stateless fixture
Acceptance:
- ${dir}/acceptance.feature
- ${helper}

Write verified edit followed by a newline to app.txt when building this fixture.

## Decisions
- Keep native authority checks. (source: request)

## Source comparison
- addressed: requested verified edit newline in app.txt; source request; contract outcome and acceptance.

## Tests
- fixture availability: real Cucumber (scenario)

## Stages
\`\`\`json
{"version":1,"stages":[{"id":"prepare","title":"Prepare fixture","goal":"Keep the seeded app available","checks":["test -f app.txt"]},{"id":"deliver","title":"Deliver fixture","goal":"Write the approved text","checks":["test -f app.txt"]}]}
\`\`\`

## Feasibility
- none
`,
    [`${dir}/acceptance.feature`]: 'Feature: Approval recovery fixture\n  Scenario: Fixture is available\n    Then the approval recovery fixture passes\n',
    [helper]: "const {Then}=require('@cucumber/cucumber');\nThen('the approval recovery fixture passes',()=>{});\n",
  };
}

// A real shaper reads the repository before it submits files: the scripted conversation inspects the seeded
// application file and the project configuration, then submits the package.
async function shape(c, slug, pkg, requestText) {
  const request = path.join(c.root, 'request.md');
  fs.writeFileSync(request, requestText);
  append(c, [
    call('read_file', { path: 'app.txt' }),
    call('read_file', { path: '.kogen/project.yaml' }),
    call('submit', { files: Object.entries(pkg).map(([p, content]) => ({ path: p, content })) }),
  ]);
  await invoke(c, ['intent', 'shape', slug, request], 0);
}

function allFiles(root) {
  let names;
  try { names = fs.readdirSync(root); } catch (e) { if (e.code === 'ENOENT') return []; throw e; }
  return names.sort().flatMap(name => {
    const p = path.join(root, name), st = fs.lstatSync(p);
    return st.isDirectory() ? allFiles(p) : st.isFile() ? [p] : [];
  });
}

function retained(c, slug, oldApproval, oldSource) {
  const excluded = [marker(c, slug), provenancePath(c, slug)];
  const paths = allFiles(path.join(c.repo, '.kogen/local')).filter(p => !excluded.includes(p));
  const found = bytes => bytes === null || paths.some(p => fs.readFileSync(p).equals(bytes));
  return found(oldApproval) && found(oldSource);
}
const sourceBytes = (c, slug) => readOrNull(provenancePath(c, slug));
const pick = (object, keys) => Object.fromEntries(keys.filter(k => Object.hasOwn(object, k)).map(k => [k, object[k]]));
function sourceOk(c, slug, original) {
  const bytes = sourceBytes(c, slug);
  if (bytes === null) return original === null;
  if (original === null) return true;
  const keys = ['request', 'rounds', 'origin'];
  return isDeepStrictEqual(pick(JSON.parse(bytes), keys), pick(JSON.parse(original), keys));
}
async function currentBound(c, slug) {
  const approval = JSON.parse(read(c, `.kogen/local/approvals/${slug}.json`));
  const ref = approval.source_provenance;
  const doc = JSON.parse(sourceBytes(c, slug));
  const current = await sha(c, slug);
  return approval.sha256 === current && ref.contract_sha256 === current && doc.contract_sha256 === current &&
    ref.sha256 === docHash(fs.readFileSync(path.resolve(c.repo, ref.path)));
}
function park(c, slug, helper) {
  const archive = path.join(c.root, `parked-package-${Date.now()}-${Math.random().toString(16).slice(2)}`);
  fs.mkdirSync(archive, { recursive: true });
  fs.renameSync(path.join(c.repo, `.kogen/intents/${slug}`), path.join(archive, 'intent'));
  fs.renameSync(path.join(c.repo, helper), path.join(archive, 'helper.js'));
  return archive;
}

async function setup(c, slug, mode) {
  const helper = mode.includes('shared') ? 'features/steps/workspace-project-access.js' : 'features/steps/approval_fixture.js';
  const pkg = files(slug, helper, 'Preserve the authority fixture');
  const legacy = mode === 'legacy-refine';
  if (legacy) for (const [p, b] of Object.entries(pkg)) put(c, p, b);
  else await shape(c, slug, pkg, `Original source for ${slug}: write verified edit newline to app.txt.\n`);
  await invoke(c, ['intent', 'approve', slug, await sha(c, slug)], 0);
  const oldApproval = fs.readFileSync(marker(c, slug));
  const oldSource = sourceBytes(c, slug);
  if (mode.includes('parked') || mode === 'missing-history') {
    park(c, slug, helper);
    await shape(c, slug, files(slug, helper, 'Review the fresh authority fixture'), `Fresh same-slug request for ${slug}: write verified edit newline to app.txt.\n`);
  } else if (mode.includes('shared')) {
    const consumer = files('shared-consumer', helper, 'Preserve shared acceptance');
    delete consumer[helper];
    for (const [p, b] of Object.entries(consumer)) put(c, p, b);
    await git(c, ['add', '-A']);
    await git(c, ['commit', '-qm', 'Land the shared acceptance fixture']);
    put(c, helper, pkg[helper] + '\n// Legitimate separately landed shared helper change.\n');
    await git(c, ['add', helper]);
    await git(c, ['commit', '-qm', 'Change the shared acceptance helper']);
    assert.ok(bytesEqual(sourceBytes(c, slug), oldSource));
  } else if (legacy) {
    const p = `.kogen/intents/${slug}/intent.md`;
    put(c, p, pkg[p] + '\nClarify the ready unapproved draft.\n');
  }
  return { oldApproval, oldSource };
}

async function build(c, slug, observations) {
  const before = await git(c, ['rev-parse', 'HEAD']);
  const reviews = c.server.reviewRequests().length;
  append(c, [
    call('write_file', { path: 'app.txt', content: 'verified edit\n' }),
    call('finish', { summary: 'Prepare' }),
    call('finish', { summary: 'Deliver' }),
    call('finish', { summary: 'Ready' }),
    call('submit_review', { verdict: 'approve', findings: [] }),
  ]);
  const out = await invoke(c, ['intent', 'build', slug], 0);
  const results = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/result.json'));
  assert.equal(results.length, 1, `expected one result: ${results}`);
  const progress = JSON.parse(fs.readFileSync(results[0], 'utf8')).stage_progress;
  return {
    ...observations,
    'staged Build retained': !!progress && progress.total === 2 && isDeepStrictEqual(progress.completed, ['prepare', 'deliver']),
    'fresh Build landed': out.includes(`landed ${slug}`) && await git(c, ['rev-parse', 'HEAD']) !== before && read(c, 'app.txt').toString() === 'verified edit\n',
    'independent review ran': c.server.reviewRequests().length > reviews,
    'new approval consumed': !fs.existsSync(marker(c, slug)),
  };
}

async function refine(c, slug, oldApproval, oldSource, control) {
  const before = await state(c);
  const originalSource = sourceBytes(c, slug);
  const p = `.kogen/intents/${slug}/intent.md`;
  const body = read(c, p).toString() + '\nA supported narrow correction.\n';
  const correction = path.join(c.root, 'correction.md');
  fs.writeFileSync(correction, 'Clarify only the owned Intent prose; retain executable behavior.\n');
  append(c, [
    call('read_file', { path: 'app.txt' }),
    call('read_file', { path: p }),
    call('submit_refinement', { files: [{ path: p, content: body }] }),
  ]);
  await invoke(c, ['intent', 'refine', slug, await sha(c, slug), correction], 0);
  // Damage real retained marker files after supported normal Refine. Final approval and Build still run, so the
  // deep history assertion is not masked.
  if (control === 'control-bad') {
    for (const f of allFiles(path.join(c.repo, '.kogen/local'))) if (fs.readFileSync(f).equals(oldApproval)) fs.writeFileSync(f, Buffer.concat([oldApproval, Buffer.from(' ')]));
  }
  let observations = {
    'refinement succeeded': true,
    'approval revoked': !fs.existsSync(marker(c, slug)),
    'history retained': retained(c, slug, oldApproval, oldSource),
    'source originals preserved': sourceOk(c, slug, originalSource),
    'correction retained': read(c, p).toString() === body,
    'HEAD and index preserved': sameState(await state(c), before),
  };
  const out = await invoke(c, ['intent', 'build', slug], 5);
  observations['fresh approval required'] = out.includes('intent/not_approved');
  if (!control) return observations;
  await invoke(c, ['intent', 'approve', slug, await sha(c, slug)], 0);
  observations = { ...observations, 'exact current approval': true, 'current source bound': await currentBound(c, slug) };
  return build(c, slug, observations);
}

async function approveFlow(c, slug, oldApproval, oldSource) {
  const before = await state(c);
  const originalSource = sourceBytes(c, slug);
  const n = count(c);
  const mismatch = await invoke(c, ['intent', 'build', slug], 1);
  const wrong = await invoke(c, ['intent', 'approve', slug, JSON.parse(oldApproval).sha256], 1);
  const current = await sha(c, slug);
  const stable = sameState(await state(c), before) && fs.readFileSync(marker(c, slug)).equals(oldApproval);
  const card = await invoke(c, ['intent', 'approve', slug], 5);
  let observations = {
    'stale Build refused without inference': mismatch.includes('intent/changed_since_approval') && count(c) === n,
    'wrong approval hash preserved state': wrong.includes('intent/hash_mismatch') && wrong.includes(current) && stable,
    'current card full hash': card.includes(`SHA-256: ${current}`) && card.includes(`kogen intent approve ${slug} ${current}`),
    'complete staged card': ['Staged plan', '1. Prepare fixture (prepare): Keep the seeded app available', '2. Deliver fixture (deliver): Write the approved text', 'test -f app.txt'].every(s => card.includes(s)),
    'stale authority visible': card.includes('Stale approval') && card.includes(JSON.parse(oldApproval).sha256),
    'card did not replace approval': fs.readFileSync(marker(c, slug)).equals(oldApproval) && sameState(await state(c), before),
  };
  const out = await invoke(c, ['intent', 'approve', slug, current], 0);
  observations = {
    ...observations,
    'exact current approval': out.includes(`approved ${slug}`) && JSON.parse(read(c, `.kogen/local/approvals/${slug}.json`)).sha256 === current,
    'history retained': retained(c, slug, oldApproval, oldSource),
    'current source bound': await currentBound(c, slug),
    'source originals preserved': sourceOk(c, slug, originalSource),
  };
  return build(c, slug, observations);
}

async function unsafe(c, slug, mode, oldApproval, oldSource) {
  const p = provenancePath(c, slug);
  if (mode === 'missing-history') {
    for (const f of allFiles(path.dirname(p))) if (fs.readFileSync(f).equals(oldSource)) fs.rmSync(f);
  } else if (mode === 'missing-current') fs.rmSync(p);
  else fs.writeFileSync(p, Buffer.concat([fs.readFileSync(p), Buffer.from(' ')]));
  const before = await state(c);
  const source = readOrNull(p);
  const n = count(c);
  const results = [];
  for (const args of [['intent', 'approve', slug], ['intent', 'approve', slug, await sha(c, slug)]]) results.push(await H.runKogen(c, args));
  return {
    'custody refused': results.every(r => r.code === 1 && r.out.includes('source_provenance_changed')),
    'actual cause and next action': results.every(r => r.out.includes('provenance') && r.out.includes(slug) && /restore/i.test(r.out) && !r.out.includes('obtain fresh exact approval')),
    'approval and source unchanged': fs.readFileSync(marker(c, slug)).equals(oldApproval) && bytesEqual(readOrNull(p), source),
    'HEAD and index preserved': sameState(await state(c), before),
    'no provider inference': count(c) === n,
  };
}

async function invalid(c, slug, oldApproval) {
  const p = `.kogen/intents/${slug}/intent.md`;
  put(c, p, read(c, p).toString().replace('Model: not applicable — stateless fixture', 'Model: invalid'));
  const before = await state(c);
  const source = sourceBytes(c, slug);
  const pkg = read(c, p);
  const n = count(c);
  const { out, code } = await H.runKogen(c, ['intent', 'approve', slug]);
  return {
    'invalid package cause': code === 1 && out.includes('intent/lint') && out.includes('Model:') && !out.includes('source_provenance_changed'),
    'approval and source unchanged': fs.readFileSync(marker(c, slug)).equals(oldApproval) && bytesEqual(sourceBytes(c, slug), source),
    'HEAD and index preserved': sameState(await state(c), before),
    'package unchanged': read(c, p).equals(pkg),
    'no provider inference': count(c) === n,
  };
}

async function runMode(mode, slug) {
  const suite = await suiteOnce();
  const c = await H.project(suite, [], { stagedIntent: false });
  try {
    await git(c, ['add', '-A']);
    await git(c, ['commit', '-qm', 'Commit the seed fixture']);
    const { oldApproval, oldSource } = await setup(c, slug, mode);
    if (mode === 'invalid-shared') return await invalid(c, slug, oldApproval);
    if (mode.startsWith('control-')) return await refine(c, slug, oldApproval, oldSource, mode);
    if (mode.includes('refine')) return await refine(c, slug, oldApproval, oldSource, null);
    if (['missing-current', 'tampered-current', 'missing-history'].includes(mode)) return await unsafe(c, slug, mode, oldApproval, oldSource);
    return await approveFlow(c, slug, oldApproval, oldSource);
  } finally {
    await H.cleanupCase(c);
  }
}

async function exercise(mode, slug) {
  try { return { code: 0, output: '', observed: await runMode(mode, slug) }; }
  catch (e) { return { code: 1, output: String(e && e.stack || e), observed: null }; }
}
function observe(result, rows) {
  assert.equal(result.code, 0, result.output);
  assert.ok(result.observed, result.output);
  for (const [key, value] of rows) assert.deepEqual(result.observed[key], JSON.parse(value), key + ': ' + JSON.stringify(result.observed));
}
if (require.main === module) {
  (async () => {
    const which = process.argv[2] === '--control' && process.argv[3];
    assert.ok(['good', 'bad'].includes(which));
    // A normal matching-approved Refine/approve/Build journey reaches history and final lifecycle assertions on
    // today's code, independently of stale-card red.
    const result = await exercise('control-' + which, 'approval-control');
    assert.equal(result.code, 0, result.output);
    assert.ok(result.observed, result.output);
    const rows = ['refinement succeeded', 'approval revoked', 'history retained', 'source originals preserved', 'fresh approval required', 'correction retained', 'HEAD and index preserved', 'exact current approval', 'current source bound', 'fresh Build landed', 'independent review ran', 'new approval consumed', 'staged Build retained'].map(k => [k, 'true']);
    try { observe(result, rows); process.stdout.write('accepted\n'); }
    catch (e) {
      if (!(e instanceof assert.AssertionError)) throw e;
      process.stdout.write('rejected\n'); process.exitCode = 1;
    }
  })().catch(e => { process.stderr.write(String(e) + '\n'); process.exitCode = 3; }).finally(() => cleanup());
} else {
  const { When, Then, AfterAll } = require('@cucumber/cucumber');
  When('I exercise approval card recovery {string} for {string}', { timeout: 300000 }, async function (mode, slug) {
    this.approvalRecovery = await exercise(mode, slug);
    if (this.approvalRecovery.observed) await this.attach(JSON.stringify(this.approvalRecovery.observed), 'application/json');
  });
  Then('the approval recovery observations are:', function (table) { observe(this.approvalRecovery, table.raw()); });
  AfterAll(() => cleanup());
}
