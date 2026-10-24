const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const feature = path.join(root, '.kogen/intents/bounded-tool-results/acceptance.feature');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
function textResult(actual, original, spec) {
  assert.equal(typeof actual, 'string');
  const bytes = Buffer.from(actual), source = Buffer.from(original);
  assert.equal(bytes.toString('utf8'), actual, 'invalid UTF-8 display');
  assert.ok(bytes.length <= spec.limit, `unbounded result: ${bytes.length}`);
  if (source.length <= spec.limit) return assert.equal(actual, original, 'fitting result changed');
  const m = actual.match(/^([\s\S]*)\n\[\.\.\. (\d+) bytes omitted \.\.\.\]\n([\s\S]*)$/);
  assert.ok(m, 'oversized result lacks the honest omission marker');
  const head = Buffer.from(m[1]), tail = Buffer.from(m[3]);
  let end = spec.head;
  while (Buffer.from(source.subarray(0, end).toString('utf8')).compare(source.subarray(0, end)) !== 0) end--;
  assert.equal(head.compare(source.subarray(0, end)), 0, 'wrong head');
  assert.equal(tail.compare(source.subarray(source.length - tail.length)), 0, 'wrong tail');
  assert.equal(Number(m[2]), source.length - head.length - tail.length, 'incorrect omitted byte count');
  // Existing cutter reserves marker width from the original count; allow that
  // conservative decimal-width difference and a partial UTF-8 character.
  assert.ok(bytes.length >= spec.limit - 6, 'suffix needlessly discarded');
}
function boundary(data, spec) {
  assert.equal(data.mode, 'boundary');
  assert.equal(data.results.length, spec.sizes.length + 3);
  for (const row of data.results) {
    textResult(row.actual, row.source, spec);
    assert.equal(row.again, row.actual, 'bounding is not idempotent');
    assert.equal(row.call_id, row.expected_call_id, 'tool pair changed');
  }
  assert.deepEqual(data.typed.actual, data.typed.source, 'typed image content changed');
  assert.equal(data.typed.call_id, data.typed.expected_call_id);
  assert.deepEqual(data.measure.bytes, [spec.ceiling - 1, spec.ceiling, spec.ceiling + 1]);
  assert.deepEqual(data.measure.fits, [true, true, false]);
  assert.deepEqual(data.measure.reserves, [spec.reserve, spec.reserve, spec.reserve]);
}
function native(data, spec) {
  assert.equal(data.exit, spec.statuses[data.mode], data.output);
  assert.ok(!data.output.includes('candidate/context_budget_exceeded'), data.output);
  assert.ok(data.requests.length > 1, 'no continuation reached the provider');
  const windows = data.requests.map(r => {
    assert.ok(Buffer.byteLength(r.body) <= spec.ceiling, 'oversized provider request');
    assert.deepEqual(JSON.parse(r.body), r.json, 'wrong rendered body');
    return r.json.input;
  });
  for (const file of data.history) {
    const bytes = Buffer.from(file.bytes, 'base64');
    assert.equal(hash(bytes), file.sha256, 'changed custody');
    assert.equal(file.mode, 384); assert.equal(file.dir_mode, 448);
    windows.push(JSON.parse(bytes).input);
  }
  for (const [phase, authority] of Object.entries(data.authorities)) {
    assert.ok(JSON.stringify(authority).includes(JSON.stringify(spec.packet).slice(1, -1)), 'original packet missing');
    const requests = data.requests.filter(r => r.phase === phase);
    assert.ok(requests.length > 1, `missing ${phase} continuation`);
    // Responses renders plain user strings as one typed input_text block.
    const rendered = typeof authority.content === 'string' ? { ...authority, content: [{ type: 'input_text', text: authority.content }] } : authority;
    for (const r of requests) assert.deepEqual(r.json.input.find(i => i.role === 'user'), rendered, 'authority clipped or changed');
  }
  for (const g of data.groups) {
    let delivered = false;
    for (const w of windows) {
      const n = w.findIndex(i => i.type === 'function_call' && i.call_id === g.calls[0].call_id);
      if (n < 2 || !same(w.slice(n - 2, n), g.prefix) || !same(w.slice(n, n + g.calls.length), g.calls)) continue;
      const outputs = w.slice(n + g.calls.length, n + 2 * g.calls.length);
      if (outputs.length !== g.calls.length) continue;
      for (let j = 0; j < outputs.length; j++) {
        const out = outputs[j], expected = g.sources[j];
        assert.equal(out.type, 'function_call_output');
        assert.equal(out.call_id, g.calls[j].call_id, 'reordered/unpaired tool output');
        let source = expected.text;
        if (expected.probe) {
          const metadata = out.output.match(/^exit status: 0\ntimed_out: false\nwall: [\d.]+ s\n/);
          assert.ok(metadata, 'probe metadata was lost');
          source = metadata[0] + source;
        }
        textResult(out.output, source, spec);
      }
      delivered = true; break;
    }
    assert.ok(delivered, `complete replay not delivered: ${g.calls[0].call_id}`);
  }
  assert.deepEqual(data.files_after, data.files_before, 'read fixtures changed');
  assert.equal(data.ordinary, spec.ordinary, 'ordinary ranged read semantics changed');
  if (data.mode === 'shape') {
    assert.ok(data.history.length > 0, 'did not exercise a real working-window reset');
    assert.ok(data.output.includes(spec.question), 'did not reach the next product question');
    assert.equal(data.head_after, data.head_before, 'Shape committed');
    assert.equal(data.approval_after, data.approval_before, 'Shape changed approval');
    assert.ok(data.groups.some(g => g.calls.some(c => c.name === 'read_file' && JSON.parse(c.arguments).path === data.history[0].path)), 'actual reset custody was not read');
  } else if (data.mode === 'refine') {
    assert.ok(data.output.includes('refined fixture'), data.output);
    assert.equal(data.head_after, data.head_before, 'Refine committed');
    assert.equal(data.published, data.proposed, 'owned correction not published');
    assert.equal(data.approval_after, null, 'old approval not revoked');
  } else {
    assert.notEqual(data.head_after, data.head_before, 'Build did not land');
    assert.equal(data.app_after, 'bounded implementation\n');
    assert.ok(Object.hasOwn(data.authorities, 'build') && Object.hasOwn(data.authorities, 'review'), 'independent review absent');
    assert.equal(data.approval_after, null, 'landed approval not consumed');
  }
}
function observe(data, spec) {
  if (data.mode === 'boundary') boundary(data, spec); else native(data, spec);
}

// ---------------------------------------------------------------- the fixtures, driven through the installed program
const H = require('./go_driver_support.js');
const put = (root, rel, bytes) => { const p = path.join(root, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, bytes); };
const repeat = (s, n) => s.repeat(n);
const fixtureText = s => JSON.stringify({ input: repeat('x', s.fixtureBytes - 12) });
const readEntry = (p, source) => ['read_file', { path: p, start_line: 1, end_line: 35 }, { text: source }];
const ordinaryEntry = () => ['read_file', { path: 'ordinary.txt', start_line: 2, end_line: 3 }, { text: '2\t  Δ🙂\r\n3\tlast' }];
// A group of tool calls as a provider turn: unfinished reasoning and commentary, then the calls.
function group(id, entries) {
  const prefix = [
    { type: 'reasoning', id: `rs-${id}`, encrypted_content: `opaque+/==\nΔ ${id}`, summary: [] },
    { type: 'message', id: `msg-${id}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: `Unfinished bounded inspection ${id}` }] },
  ];
  const calls = entries.map(([name, args], n) => ({ type: 'function_call', id: `fc-${id}-${n}`, call_id: `call-${id}-${n}`, name, arguments: JSON.stringify(args) }));
  return { prefix: prefix.map(H.replayItem), calls, sources: entries.map(e => e[2]), items: [...prefix, ...calls] };
}
const strip = g => { const { items, ...rest } = g; return rest; };
const action = g => ({ items: g.items });
const tool = async (root, name, args) => { const run = await H.driverProgram('bounded_tool_results'); const r = await run(['tool', root, name, JSON.stringify(args)]); assert.equal(r.code, 0, r.out); return r.out; };
const cutText = async text => { const run = await H.driverProgram('bounded_tool_results'); const r = await run(['cut'], { input: text }); assert.equal(r.code, 0, r.out); return r.out; };

async function boundaryData(spec, dir) {
  const input = path.join(dir, 'input.json'); fs.writeFileSync(input, JSON.stringify(spec));
  const run = await H.driverProgram('bounded_tool_results');
  const r = await run(['boundary', input]); assert.equal(r.code, 0, r.out);
  return JSON.parse(r.out);
}

const approvalBytes = c => { try { return fs.readFileSync(H.approvalPath(c.repo, 'fixture'), 'utf8'); } catch { return null; } };
const filesOf = (c) => Object.fromEntries(['large.json', 'ordinary.txt', 'pad.txt', 'search.txt'].map(p => [p, H.sha(fs.readFileSync(path.join(c.repo, p)))]));
const toolContextRoot = c => c.repo;

async function seed(c, s, mode) {
  put(c.repo, 'large.json', fixtureText(s));
  put(c.repo, 'ordinary.txt', 'first\n  Δ🙂\r\nlast\n');
  put(c.repo, 'pad.txt', repeat('p', s.limit - 3) + '\n');
  put(c.repo, 'search.txt', 'MATCH' + repeat('q', s.fixtureBytes) + '\n');
  if (mode === 'shape') for (let n = 1; n <= 1100; n++) put(c.repo, `corpus/${n}-${repeat('name', 12)}`, '');
  const p = H.intentMd('fixture');
  put(c.repo, p, fs.readFileSync(path.join(c.repo, p), 'utf8') + '\nOriginal bounded-results source packet:\n' + s.packet + '\n');
  await H.git(c, ['add', '.']);
  await H.git(c, ['commit', '-qm', 'Seed bounded result fixtures']);
  return H.approve(c);
}
const history = c => H.wildcard(path.join(c.repo, '.kogen/local/shaping/bounded-case/working-context/*/*.json')).map(p => {
  const bytes = fs.readFileSync(p);
  return { path: p, bytes: bytes.toString('base64'), sha256: H.sha(bytes), mode: H.mode(p), dir_mode: H.mode(path.dirname(p)) };
});
function requestsOf(c, mode) {
  return c.server.providerRequests().filter(r => !(r.json.tools || []).some(t => t.name === 'submit_configuration')).map(r => {
    const names = (r.json.tools || []).map(t => t.name);
    const phase = names.includes('submit_review') ? 'review' : names.includes('finish') ? 'build' : names.includes('submit_refinement') ? 'refine' : mode;
    return { body: r.body, json: r.json, phase };
  });
}
async function exercise(suite, s, mode) {
  const c = await H.project(suite, [], { stagedIntent: false });
  try {
    const approved = await seed(c, s, mode);
    const filesBefore = filesOf(c), headBefore = await H.git(c, ['rev-parse', 'HEAD']), approvalBefore = approvalBytes(c);
    const g = group(`${mode}-read`, [readEntry('large.json', '1\t' + fixtureText(s)), ordinaryEntry()]);
    const correction = path.join(c.root, 'request.txt'); fs.writeFileSync(correction, s.packet);
    let out, status, groups, proposed = null;
    if (mode === 'shape') {
      const growth = Array.from({ length: s.growthTurns }, (_, i) => group(`growth-${i + 1}`, [readEntry('pad.txt', '1\t' + repeat('p', s.limit - 3))]));
      c.server.setScript([...growth.map(action), { pause: H.fn('read_file', { path: 'ordinary.txt' }) }]);
      const k = H.startKogen(c, ['intent', 'shape', 'bounded-case', correction]);
      const paused = await c.server.waitPaused(60000);
      const [archived] = history(c);
      assert.ok(archived, 'Shape did not reach a completed working-window reset');
      const custody = group('custody', [readEntry(archived.path, '1\t' + fs.readFileSync(archived.path, 'utf8').replace(/\n+$/, ''))]);
      put(c.repo, '.kogen/local/bounded-reproducer/1.json', fixtureText(s));
      const synthetic = group('ignored-single-line', [readEntry('.kogen/local/bounded-reproducer/1.json', '1\t' + fixtureText(s))]);
      const list = await tool(toolContextRoot(c), 'list_files', { path: 'corpus' });
      const search = await tool(toolContextRoot(c), 'search_text', { path: 'search.txt', pattern: 'MATCH' });
      const discovery = group('discovery', [
        ['list_files', { path: 'corpus' }, { text: list }],
        ['search_text', { path: 'search.txt', pattern: 'MATCH' }, { text: search }],
        ['probe', { command: 'cat search.txt' }, { text: fs.readFileSync(path.join(c.repo, 'search.txt'), 'utf8'), probe: true }],
      ]);
      // setScript keeps the answers already consumed and replaces only the rest: the tail after the reset, as the
      // Elixir driver's second script was ([custody, synthetic, g, discovery, submit]).
      c.server.setScript([action(custody), action(synthetic), action(g), action(discovery),
        H.fn('submit', { questions: [{ question: s.question, options: [{ label: 'Continue', recommended: true }] }] })]);
      paused.continue();
      const done = await k.awaitExit(90000);
      ({ out, code: status } = { out: done.out, code: done.code });
      groups = [...growth, custody, synthetic, g, discovery];
    } else if (mode === 'refine') {
      const p = H.intentMd('fixture');
      proposed = fs.readFileSync(path.join(c.repo, p), 'utf8') + '\nBounded result fixture correction.\n';
      c.server.setScript([action(g), H.fn('submit_refinement', { files: [{ path: p, content: proposed }] })]);
      const r = await H.runKogen(c, ['intent', 'refine', 'fixture', approved.hash, correction]);
      out = r.out; status = r.code; groups = [g];
    } else {
      const reviewer = group('independent-review-read', [readEntry('large.json', '1\t' + fixtureText(s)), ordinaryEntry()]);
      c.server.setScript([action(g), H.fn('write_file', { path: 'app.txt', content: 'bounded implementation\n' }), H.fn('finish', { summary: 'Implement fixture' }),
        action(reviewer), H.fn('submit_review', { verdict: 'approve', findings: [] })]);
      const r = await H.runKogen(c, ['intent', 'build', 'fixture']);
      out = r.out; status = r.code; groups = [g, reviewer];
    }
    const requests = requestsOf(c, mode);
    const authorities = Object.fromEntries(requests.map(r => [r.phase, r.json.input.find(i => i.role === 'user')]));
    return {
      mode, exit: status, output: out, requests, authorities, history: history(c), groups: groups.map(strip),
      files_before: filesBefore, files_after: filesOf(c), ordinary: await tool(c.repo, 'read_file', { path: 'ordinary.txt', start_line: 2, end_line: 3 }),
      head_before: headBefore, head_after: await H.git(c, ['rev-parse', 'HEAD']), approval_before: approvalBefore, approval_after: approvalBytes(c),
      proposed, published: fs.readFileSync(path.join(c.repo, H.intentMd('fixture')), 'utf8'), app_after: fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8'),
    };
  } finally { await H.cleanupCase(c); }
}

// Observer controls are local serialized fixtures, not claims that the product flow passed. Sources are actual file bytes
// read by the production tool; outputs use the production cutter.
const typedRequest = (authority, items, phase) => {
  const json = { model: 'fixture', reasoning: { effort: 'high' }, include: ['reasoning.encrypted_content'],
    input: [{ role: 'developer', content: [{ type: 'input_text', text: 'fixture policy' }] }, ...[authority, ...items].map(i => typeof i.content === 'string' ? { ...i, content: [{ type: 'input_text', text: i.content }] } : i)],
    stream: true, store: false };
  return { json, body: JSON.stringify(json), phase };
};
async function controls(spec) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bounded-observer-'));
  try {
    fs.chmodSync(dir, 0o700);
    put(dir, 'large.json', fixtureText(spec)); put(dir, 'ordinary.txt', 'first\n  Δ🙂\r\nlast\n');
    const source = await tool(dir, 'read_file', { path: 'large.json', start_line: 1, end_line: 35 });
    const display = async g => [...g.items.map(H.replayItem), ...await Promise.all(g.calls.map(async (call, i) => H.outputItem(call, await cutText(g.sources[i].text))))];
    const old = group('old', [readEntry('large.json', source), ordinaryEntry()]);
    const archive = path.join(dir, 'archive.json');
    const bytes = JSON.stringify({ input: await display(old) }) + '\n';
    fs.writeFileSync(archive, bytes); fs.chmodSync(archive, 0o600);
    const g = group('control', [readEntry(archive, '1\t' + bytes.replace(/\n+$/, '')), ordinaryEntry()]);
    const authority = { role: 'user', content: spec.packet };
    const ref = { path: archive, bytes: Buffer.from(bytes).toString('base64'), sha256: H.sha(bytes), mode: H.mode(archive), dir_mode: H.mode(dir) };
    const largeHash = H.sha(fs.readFileSync(path.join(dir, 'large.json')));
    const ordinary = await tool(dir, 'read_file', { path: 'ordinary.txt', start_line: 2, end_line: 3 });
    const shown = await display(g);
    const records = ['shape', 'refine', 'build-review'].map(mode => {
      const phases = mode === 'build-review' ? ['build', 'review'] : [mode];
      return {
        mode, exit: spec.statuses[mode], output: `${spec.question} refined fixture`,
        requests: phases.flatMap(phase => [typedRequest(authority, [], phase), typedRequest(authority, shown, phase)]),
        authorities: Object.fromEntries(phases.map(p => [p, authority])), history: [ref], groups: [strip(g)],
        files_before: { large: largeHash }, files_after: { large: largeHash }, ordinary,
        head_before: 'fixture-head', head_after: mode === 'build-review' ? 'landed-head' : 'fixture-head',
        approval_before: 'fixture-approval', approval_after: mode === 'shape' ? 'fixture-approval' : null,
        proposed: 'owned correction', published: 'owned correction', app_after: 'bounded implementation\n',
      };
    });
    return [await boundaryData(spec, dir), ...records];
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

if (require.main === module && process.argv[2] === '--control') {
  const spec = JSON.parse(fs.readFileSync(feature, 'utf8').match(/"""json\s*([\s\S]*?)\s*"""/)[1]);
  (async () => {
  const fixtures = await controls(spec);
  for (const fixture of fixtures) observe(fixture, spec);
  if (process.argv[3] === 'good') process.stdout.write('bounded observer accepted good fixtures\n');
  else if (process.argv[3] === 'bad') {
    // Independently corrupt every observation branch, including assertions after the
    // primary missing-feature red. Controls use actual locally serialized fixture bytes.
    for (const fixture of fixtures) {
      const mutations = fixture.mode === 'boundary' ? [
        d => { d.results[0].actual += 'x'; },
        d => { d.results[2].actual = d.results[2].source; },
        d => { d.results[2].actual = d.results[2].actual.replace(/\d+ bytes omitted/, '1 bytes omitted'); },
        d => { d.results[3].actual = 'wrong'; },
        d => { d.results[4].again += 'x'; },
        d => { d.results[5].call_id += 'wrong'; },
        d => { d.typed.actual[1].image_url += 'wrong'; },
        d => { d.measure.fits[1] = false; },
        d => { d.measure.reserves[0] = 0; },
      ] : [
        d => { d.exit = 1; },
        d => { d.requests = []; },
        d => { d.requests[0].body = 'x'.repeat(spec.ceiling + 1); },
        d => { d.history[0].sha256 = '0'.repeat(64); },
        d => { d.history[0].mode = 420; },
        d => { d.authorities[Object.keys(d.authorities)[0]] = { role: 'user', content: 'clipped' }; },
        d => { for (const r of d.requests) for (const i of r.json.input) if (i.type === 'function_call_output') i.output = 'wrong'; for (const r of d.requests) r.body = JSON.stringify(r.json); d.history = []; },
        d => { d.groups[0].prefix[0].encrypted_content += 'changed'; },
        d => { d.groups[0].prefix[1].phase = 'final'; },
        d => { d.groups[0].calls.reverse(); },
        d => { d.files_after = {}; },
        d => { d.ordinary = 'wrong'; },
        d => { if (d.mode === 'shape') d.output = ''; else if (d.mode === 'refine') d.published = 'wrong'; else d.head_after = d.head_before; },
        d => { d.approval_after = 'wrong'; },
      ];
      for (const mutate of mutations) {
        const bad = structuredClone(fixture); mutate(bad);
        assert.throws(() => observe(bad, spec), 'accepted a bad fixture');
      }
    }
    process.stdout.write('bounded observer rejected bad fixtures\n'); process.exitCode = 1;
  } else throw new Error('unknown control');
  })().catch(error => { process.stderr.write(`${error.stack}\n`); process.exit(2); });
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  let suite;
  Given('this bounded tool-result contract:', function (json) { this.boundedSpec = JSON.parse(json); });
  When('I exercise bounded tool results through {string}', { timeout: 540000 }, async function (mode) {
    if (mode === 'boundary') {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bounded-results-'));
      try { this.boundedObservations = await boundaryData(this.boundedSpec, dir); } finally { fs.rmSync(dir, { recursive: true, force: true }); }
      return;
    }
    suite = suite || await H.setupSuite();
    this.boundedObservations = await exercise(suite, this.boundedSpec, mode);
  });
  Then('the bounded tool-result observations satisfy the contract', function () { observe(this.boundedObservations, this.boundedSpec); });
  require('@cucumber/cucumber').AfterAll(function () { H.cleanupSuite(suite); });
}
