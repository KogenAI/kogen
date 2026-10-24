const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Given, When, Then } = require('@cucumber/cucumber');

// Independent installed-CLI observer: the installed `kogen` (the one Go program), the files it keeps and a scripted local
// provider. Only installation/project/server facilities are shared, never implementation-test assertions.
const H = require('./go_driver_support.js');
const { fn: f } = H;
const sha = x => crypto.createHash('sha256').update(x).digest('hex');
const put = (c, p, bytes) => { const target = path.join(c.repo, p); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, bytes); };
const shapeRequests = c => c.server.providerRequests().filter(r => (r.json.tools || []).some(t => t.name === 'submit'));
// The text blocks of the first user message of an input (the mandatory contract and the navigation descriptor).
const contract = input => {
  const m = (input || []).find(i => i.role === 'user');
  if (!m) return [];
  if (Array.isArray(m.content)) return m.content.map(b => b.text);
  return typeof m.content === 'string' ? [m.content] : [];
};
const lines = p => fs.existsSync(p) ? fs.readFileSync(p, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l)) : [];
const json = p => fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : null;
const mode0 = p => fs.statSync(p).mode & 0o777;
const bytes = s => Buffer.byteLength(s);

async function runExercise(cfg) {
  const { mode } = cfg;
  const suite = await H.setupSuite();
  let c;
  try {
    c = await H.project(suite, [], { stagedIntent: false });
    const slug = 'index-observed', state = path.join(c.repo, `.kogen/local/shaping/${slug}`);
    const trace = path.join(c.root, 'readiness-executions');
    const testingRules = fs.readFileSync(path.join(suite.prefix, 'lib/kogen/docs/testing-rules.md'), 'utf8');
    const yaml = fs.readFileSync(path.join(c.repo, '.kogen/project.yaml'), 'utf8');
    const stepsDir = /steps_dir: '?([^'\n]+)'?/.exec(yaml)[1];
    const acceptanceRun = /^    run: '((?:[^']|'')*)'$/m.exec(yaml)[1].replaceAll("''", "'");
    H.configure(c, { protect: ['protected.txt'], acceptance: { run: `if grep -q 'Scenario:' "$KOGEN_ACCEPTANCE_FEATURES"; then printf 'ran\\n' >> '${trace}'; fi; ${acceptanceRun}`, stepsDir } });
    const readme = '# Fixture authority \u0394\r\nKeep exact authority and investigate relevant files.\r\n';
    put(c, 'README.md', readme);
    put(c, 'protected.txt', 'protected literal\n');
    const selected = 'selected/source.txt';
    put(c, selected, 'NAVIGATION_SOURCE_SENTINEL \u0394\nsecond exact line\n');
    put(c, 'padding.txt', 'discovery padding line\n'.repeat(1800));
    for (let n = 1; n <= cfg.files; n++) {
      const id = String(n).padStart(5, '0');
      put(c, `inventory/branch-${id}/source-${id}.ex`, `defmodule Inventory${id} do\n  def navigation_declaration_${id}(value), do: value\n  def another_navigation_declaration_${id}(value), do: value\nend\n`);
    }
    await H.gitBang(c, ['add', '.']);
    await H.gitBang(c, ['commit', '-qm', 'Seed native navigation fixture']);
    const head = await H.git(c, ['rev-parse', 'HEAD']);
    // ShapeContext.revision: the candidate tree (start commit plus everything not ignored) without .kogen/local (ignored by the fixture's .gitignore, so absent from it).
    const revisionTree = await H.candidateTree(c, head);
    const index = fs.readFileSync(path.join(c.repo, '.git/index'));
    const approvalPath = H.approvalPath(c.repo, 'fixture');
    const originalApproval = fs.readFileSync(approvalPath);
    const source = cfg.source + (mode === 'irreducible' ? '\n' + 'M'.repeat(600000) : '');
    const requestPath = path.join(c.root, 'request.txt');
    fs.writeFileSync(requestPath, source);
    const mdpath = H.intentMd(slug), ftpath = H.featurePath(slug), helper = 'features/steps/index_observed.js';
    const md = `# Preserve the navigation fixture\n\nSlug: ${slug}\nModel: not applicable \u2014 a stateless fixture\nAcceptance:\n- ${ftpath}\n- ${helper}\n\nKeep the full supplied source packet as diagnostic provenance; this fixture implements no migration or operator monitoring.\n\n## Source comparison\n- addressed: complete source packet is the native request; this local contract tests Shape plumbing and preserves the source receipt.\n\n## Tests\n- Baseline source stays readable: actual filesystem scenario (regression)\n\n## Feasibility\n- none\n`;
    const ft = 'Feature: Navigation fixture\n  Scenario: Read the actual baseline\n    Then the navigation fixture baseline is readable\n';
    const js = "const assert = require('node:assert/strict');\nconst fs = require('node:fs');\nconst { Then } = require('@cucumber/cucumber');\nThen('the navigation fixture baseline is readable', function () { assert.equal(fs.readFileSync('app.txt', 'utf8'), 'baseline\\n'); });\n";
    const files = [{ path: mdpath, content: md }, { path: ftpath, content: ft }, { path: helper, content: js }];
    const question = { question: 'Which fixture label should be retained?', options: [{ label: 'Keep the full fixture scope', recommended: true }, { label: 'Use the alternate fixture label' }] };
    const answered = mode === 'answers';
    // A real shaper inspects the repository before it submits anything (shape/uninspected otherwise).
    const inspect = [f('read_file', { path: 'README.md' })];
    let input = requestPath;
    if (answered) {
      c.server.setScript([...inspect, f('submit', { questions: [question] })]);
      const first = await H.runKogen(c, ['intent', 'shape', slug, requestPath]);
      assert.equal(first.code, 5, `product-question precondition was not reached: ${first.out}`);
      assert.ok(first.out.includes(question.question), `product-question precondition was not reached: ${first.out}`);
      input = path.join(c.root, 'answers.txt');
      fs.writeFileSync(input, '1: b\n');
    }
    const beforeRequests = shapeRequests(c).length;
    const actions = [f('submit', { files }), f('list_files', { path: 'selected' }), f('search_text', { path: 'selected', pattern: 'NAVIGATION_SOURCE_SENTINEL' }), f('read_file', { path: selected, start_line: 1, end_line: 2 }),
      f('submit', { files: [{ path: mdpath, content: md + '- documentation-lookup: retrieved https://example.invalid/never-looked-up\n' }, files[1], files[2]] })];
    const growth = cfg.reads > 0 ? Array.from({ length: cfg.reads }, () => f('read_file', { path: 'padding.txt' })) : [];
    c.server.setScript([...actions, ...growth, f('submit', { files })]);
    const run = await H.runKogen(c, ['intent', 'shape', slug, input]);
    const status = run.code, output = run.out;
    const reqs = shapeRequests(c).slice(beforeRequests);
    const events = lines(path.join(state, 'events.ndjson'));
    const resets = events.filter(e => e.event === 'working_context_reset'), stops = events.filter(e => e.event === 'working_context_stop');
    const archives = [...resets, ...stops].map(e => e.archive).map(ref => {
      const b = fs.readFileSync(ref.path);
      return { ref, bytes: b, doc: JSON.parse(b.toString('utf8')), mode: mode0(ref.path), dirMode: mode0(path.dirname(ref.path)) };
    });
    const allContracts = [...reqs.map(r => contract(r.json.input)), ...archives.map(a => contract(a.doc.input))];
    const firstContract = allContracts[0] || [];
    const stable = firstContract[0] || '', dynamic = firstContract[1] || '';
    const expectedNavigation = { root: c.repo, revision: { head, tree: revisionTree }, retrieval: 'read_file exact bytes and line ranges; list_files directories; search_text exact signatures' };
    let navigation = false;
    if (dynamic.startsWith('Context navigation: ')) {
      const text = dynamic.slice('Context navigation: '.length);
      try {
        assert.deepEqual(JSON.parse(text.replace(/\n$/, '')), expectedNavigation);
        navigation = text.endsWith('\n') && !text.replace(/\n$/, '').includes('\n');
      } catch { navigation = false; }
    }
    const outputs = c.server.toolOutputs();
    const provenance = json(path.join(c.repo, `.kogen/local/provenance/${slug}/current.json`));
    const ready = json(path.join(c.repo, `.kogen/local/readiness/${slug}.json`));
    const published = fs.existsSync(path.join(c.repo, mdpath));
    const hash = published ? await H.baselineHash(c, slug, ['protected.txt']) : null;
    const baseline = published ? await H.baselinePaths(c, slug, ['protected.txt']) : [];
    const exactQa = !answered || (stable.includes(question.question) && stable.includes('answer: 1: b') && stable.includes('Use the alternate fixture label') && provenance !== null &&
      JSON.stringify(provenance.rounds?.[0]?.inputs) === JSON.stringify(['1: b\n']) && provenance.rounds?.[0]?.answers?.['1'] === 'b' && provenance.rounds?.[0]?.resolved_answers?.['1'] === 'Use the alternate fixture label');
    const archiveIntegrity = archives.length > 0 && archives.every(a => sha(a.bytes) === a.ref.sha256 && a.mode === 0o600 && a.dirMode === 0o700 && a.doc.owner === 'shape' && JSON.stringify(contract(a.doc.input)) === JSON.stringify(firstContract));
    const resetMeasurement = resets.length > 0 && resets.every(e => reqs.some(r => bytes(r.body) === e.after_bytes) && e.before_bytes > e.after_bytes && e.after_bytes <= 524288 && e.input_budget_bytes === 524288 && e.output_reserve_tokens === 131072);
    const authority = allContracts.length > 0 && allContracts.every(blocks => {
      const text = blocks[0] || '';
      return blocks.length === 2 && text === stable && text.includes(`# Request\n\n${source}\n`) && text.includes(readme) && text.includes(testingRules) &&
        text.includes('configured protect patterns: ["protected.txt"]') && text.includes('paths currently matched by those patterns: ["protected.txt"]') &&
        text.includes('automatic baseline: every file in') && text.includes('.kogen/intents/index-observed/') && text.includes('automatic paths currently present or listed: [".kogen/project.yaml"]') &&
        text.includes('Full contract inclusions: exact request, Q&A, README, testing rules and protection/automatic baseline are authoritative and are not clipped.');
    });
    const unchanged = (await H.git(c, ['rev-parse', 'HEAD'])) === head && fs.readFileSync(path.join(c.repo, '.git/index')).equals(index) && fs.readFileSync(path.join(c.repo, 'protected.txt'), 'utf8') === 'protected literal\n' &&
      fs.readFileSync(approvalPath).equals(originalApproval) && !fs.existsSync(H.approvalPath(c.repo, slug));
    const sourceOk = provenance !== null && provenance.request?.text === source && provenance.request?.sha256 === sha(source) && provenance.contract_sha256 === hash;
    const sameJson = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
    const readyOk = ready !== null && ready.version === 3 && ready.sha256 === hash && ready.head === head && sameJson(ready.baseline, baseline) && typeof ready.candidate_tree === 'string' && ready.candidate_tree === (await H.candidateTree(c, head)) &&
      (ready.scenarios || []).length > 0 && ready.scenarios.every(s => s.status === 'passed');
    const traceText = fs.existsSync(trace) ? fs.readFileSync(trace, 'utf8') : null;
    const observed = {
      status,
      'Shape provider request count': reqs.length,
      'navigation shape and identity': navigation && allContracts.every(b => b[1] === dynamic),
      'descriptor maximum bytes': bytes(dynamic),
      'exact authority': authority,
      'exact question and answer': exactQa,
      'inspection refused before reads': outputs.some(o => o.includes('shape/uninspected')),
      'fabricated documentation refused': outputs.some(o => o.includes('shape/undocumented')),
      'list search and read reached source': outputs.includes(selected) && outputs.includes(`${selected}:1:NAVIGATION_SOURCE_SENTINEL \u0394`) && outputs.includes('1\tNAVIGATION_SOURCE_SENTINEL \u0394\n2\tsecond exact line'),
      'inventory absent from mandatory': !(stable + dynamic).includes('inventory/branch-') && !(stable + dynamic).includes('navigation_declaration_'),
      'actual readiness ran': traceText === 'ran\n',
      'exact provenance and readiness': sourceOk && readyOk,
      'no approval or Git mutation': unchanged,
      'all sent requests within ceiling': reqs.length > 0 && reqs.every(r => bytes(r.body) <= 524288),
      'a real working window reset': resets.length > 0,
      'archives bind exact mandatory': archiveIntegrity,
      'reset measures actual rendered body': resetMeasurement,
      'honest budget stop': status === 1 && output.includes('candidate/context_budget_exceeded') && output.includes('ceiling 524288; reserve 131072 tokens') && output.includes('fresh identical retry is not recovery') && stops.length > 0 &&
        stops.every(e => e.input_budget_bytes === 524288 && e.output_reserve_tokens === 131072 && e.measured_bytes > 524288),
      'exact unsent input custody': reqs.length === 0 && archiveIntegrity && archives.every(a => (contract(a.doc.input)[0] || '').includes(source)),
      'no publication': provenance === null && ready === null && !published && !fs.existsSync(path.join(c.repo, helper)),
    };
    return { observed, output };
  } finally {
    await H.cleanupCase(c);
    H.cleanupSuite(suite);
  }
}
Given('the exact Shape index source packet:', function (source) { this.shapeIndexSource = source; });
When('I exercise native Shape index mode {string} with {int} inventory files and {int} extra reads', { timeout: 250000 }, async function (mode, files, reads) {
  assert.ok(['answers', 'large', 'windows', 'irreducible'].includes(mode));
  assert.equal(typeof this.shapeIndexSource, 'string');
  this.shapeIndexResult = await runExercise({ mode, files, reads, source: this.shapeIndexSource });
});
Then('the Shape index contract observations are:', function (table) {
  assert.ok(this.shapeIndexResult);
  const { observed, output } = this.shapeIndexResult;
  const failures = [];
  for (const row of table.hashes()) {
    assert.ok(Object.hasOwn(observed, row.observation), `unknown observation ${row.observation}`);
    const actual = observed[row.observation];
    const expected = JSON.parse(row.expected);
    const pass = row.observation === 'descriptor maximum bytes' ? actual > 0 && actual <= expected : actual === expected;
    if (!pass) failures.push(`${row.observation}: expected ${row.observation === 'descriptor maximum bytes' ? 'at most ' : ''}${expected}, got ${JSON.stringify(actual)}`);
  }
  assert.deepEqual(failures, [], `${failures.join('\n')}\nInstalled CLI output:\n${output.slice(-12000)}`);
});
