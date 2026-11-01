'use strict';
// K-SHAPE-ACCEPTANCE-CONTRADICTS. Shape checks the acceptance examples of every complete candidate against the rules the
// Intent states, with one fresh read-only example check whose only tool is submit_example_check; Kogen alone compares
// each expected value with the value the checker derived from the example's input. A contradiction goes back to the
// shaper; a contradiction the shaper keeps ends Shape not ready and `kogen intent approve` refuses that package.
//
// The installed release runs through its CLI against the scripted local provider of go_driver_support.js; nothing
// contacts a real provider. The prepared packages are fixtures whose step definitions are trivial: only Kogen's shape
// and approve outcome is asserted. The scripted example check answers with the value the package's rule gives for the
// example's input; "the example check of the prepared package derives ..." recomputes that value with the reference
// rule below first, so a scripted derivation that does not follow from its input is a fixture error, not product red.
//
// Run directly, `node features/steps/k_shape_acceptance_contradicts_steps.js --control good|bad` qualifies the
// observers and the reference rules: known-good observations are accepted (exit 0), known-bad ones rejected (exit 1).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const CHECK_TOOL = 'submit_example_check';
const EXAMPLE_STEPS = 'features/steps/example_steps.js';

// ------------------------------------------------------------------ the prepared packages (fixtures)

const unit = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const PACKAGES = {
  durations: {
    title: 'Render durations in words',
    request: 'Render a number of seconds as hours, minutes and seconds in words.\n',
    intro: 'A whole number of seconds renders as hours, minutes and seconds, for example `2 hours, 1 minute, 5 seconds`; a unit is singular when its count is 1 and plural otherwise.',
    reference: input => { const s = Number(input); return [unit(Math.floor(s / 3600), 'hour'), unit(Math.floor((s % 3600) / 60), 'minute'), unit(s % 60, 'second')].join(', '); },
  },
  amounts: {
    title: 'Read the amount field of a record',
    request: 'Read the amount of a fixed-width record.\n',
    intro: 'A record is one line of fixed-width fields; columns are counted from 1 and a column range includes both ends.',
    reference: input => (Number(input.slice(9, 13)) / 100).toFixed(2),
  },
  'key-order': {
    title: 'List the keys of a JSON object',
    request: 'List the keys of a JSON object in a stable order.\n',
    intro: '`keys` reads one JSON object and lists its keys.',
    reference: input => Object.keys(JSON.parse(input)).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))).join(', '),
  },
};

// The three files of a prepared package whose one example expects `expected`.
function packageFiles(k, expected) {
  const p = PACKAGES[k.slug];
  const feature = `.kogen/intents/${k.slug}/acceptance.feature`;
  return [
    { path: `.kogen/intents/${k.slug}/intent.md`, content: `# ${p.title}

Slug: ${k.slug}
Model: not applicable — one stateless rule
Acceptance:
- ${feature}
- ${EXAMPLE_STEPS}

${p.intro} Rule: ${k.rule}.

## Decisions
- The output follows the rule stated above (source: request)

## Source comparison
- addressed: the rule and its example; source request; contract prose and acceptance.feature.

## Tests
- the rule: the acceptance scenario (scenario)

## Feasibility
- none
` },
    { path: feature, content: `Feature: ${p.title}
  Scenario: ${k.scenario}
    Given the input '${k.input}'
    Then the output is '${expected}'
` },
    { path: EXAMPLE_STEPS, content: `const { Given, Then } = require('@cucumber/cucumber');

Given('the input {string}', function (input) {
  this.input = input;
});

Then('the output is {string}', function (output) {
  this.output = output;
});
` },
  ];
}

// What a checker answers for one candidate: the example's quotes copied from the candidate and the derived value.
const checkItem = (k, expected) => ({ scenario: k.scenario, input: k.input, expected, rule: k.rule, derived: k.derived, why: k.why });

// A scripted derivation must be what the rule gives for the input; otherwise the fixture, not Kogen, is wrong.
function fixtureProblems(k) {
  const p = PACKAGES[k.slug];
  if (!p) return [`fixture error: no prepared package ${JSON.stringify(k.slug)}`];
  let derived;
  try { derived = p.reference(k.input); } catch (e) { return [`fixture error: the ${k.slug} rule cannot read input ${JSON.stringify(k.input)}: ${e.message}`]; }
  return derived === k.derived ? [] : [`fixture error: the ${k.slug} rule gives ${JSON.stringify(derived)} for input ${JSON.stringify(k.input)}, but the scripted example check derives ${JSON.stringify(k.derived)}`];
}

// ------------------------------------------------------------------ observers

const lines = text => String(text).split('\n').map(l => l.replace(/\r$/, ''));

function linesInOrderProblems(out, text, what) {
  const have = lines(out);
  let at = 0;
  for (const want of lines(text)) {
    const found = have.indexOf(want, at);
    if (found < 0) return [`${what} did not print the line ${JSON.stringify(want)} (in order) in:\n${out}`];
    at = found + 1;
  }
  return [];
}

const outputText = o => typeof o === 'string' ? o : Array.isArray(o) ? o.map(b => (b && (b.text || b.output)) || '').join('') : JSON.stringify(o);

// The tool result Kogen returned for the shaper's first submission, exactly.
function feedbackProblems(obs, expected) {
  const call = 'call-submit-prepared-1';
  const outputs = obs.requests.flatMap(r => (r.json.input || []).filter(i => i.type === 'function_call_output' && i.call_id === call));
  if (!outputs.length) return [`the shaper was told nothing after its first submission: no later request carries the result of ${call} (shape exit ${obs.shape.code}):\n${obs.shape.out}`];
  const told = outputText(outputs[0].output);
  return told === expected ? [] : [`after its first submission the shaper was told:\n${told}\nexpected exactly:\n${expected}`];
}

// One example check request per submitted candidate, each offering only the check tool and carrying the request text,
// the candidate intent.md and the candidate acceptance.feature.
function checkRequestProblems(obs) {
  const checks = obs.requests.filter(r => r.kind === 'check');
  const problems = [];
  if (checks.length !== obs.submissions.length) problems.push(`${checks.length} example check requests for ${obs.submissions.length} submitted candidates (one each expected)`);
  checks.forEach((r, i) => {
    const tools = (r.json.tools || []).map(t => t.name);
    if (JSON.stringify(tools) !== JSON.stringify([CHECK_TOOL])) problems.push(`example check request ${i + 1} offers tools ${JSON.stringify(tools)}, expected only ${CHECK_TOOL}`);
    const files = obs.submissions[i];
    if (!files) return;
    const text = r.text;
    for (const [what, content] of [['the request text', obs.requestText], ['the candidate intent.md', files[0].content], ['the candidate acceptance.feature', files[1].content]]) {
      if (!text.includes(content.trimEnd())) problems.push(`example check request ${i + 1} does not carry ${what}:\n${content}`);
    }
  });
  return problems;
}

// The example_check events of the shaping evidence, in order, each with one item of the given result.
function eventProblems(obs, results) {
  const events = obs.events.filter(e => e.event === 'example_check');
  const got = events.map(e => (Array.isArray(e.items) ? e.items.map(i => i.result) : []).join('+'));
  if (JSON.stringify(got) !== JSON.stringify(results)) return [`example_check events record results ${JSON.stringify(got)}, expected ${JSON.stringify(results)}`];
  const problems = [];
  events.forEach((e, i) => {
    const counts = { follows: 0, contradicts: 0, unquoted: 0 };
    for (const it of e.items) counts[it.result] = (counts[it.result] || 0) + 1;
    for (const key of Object.keys(counts)) if (e[key] !== counts[key]) problems.push(`example_check event ${i + 1} counts ${key}=${JSON.stringify(e[key])}, its items give ${counts[key]}`);
  });
  return problems;
}

function packageProblems(obs, files) {
  const problems = [];
  for (const f of files) {
    const have = obs.disk[f.path];
    if (have !== f.content) problems.push(`${f.path} on disk is ${have === null || have === undefined ? 'missing' : JSON.stringify(have)}, expected exactly ${JSON.stringify(f.content)}`);
  }
  return problems;
}

// ------------------------------------------------------------------ controls

function control(which) {
  const k = { slug: 'durations', rule: 'H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60', scenario: '5430 seconds render as hours, minutes and seconds', input: '5430', derived: '1 hour, 30 minutes, 30 seconds', why: '5430 = 1*3600 + 30*60 + 30' };
  const good = [
    k,
    { slug: 'amounts', input: 'ACCT00042-120EUR', derived: '-1.20' },
    { slug: 'key-order', input: '{"b":1,"a":2,"C":3}', derived: 'C, a, b' },
  ];
  for (const g of good) { const p = fixtureProblems(g); if (p.length) throw new Error(`known-good fixture rejected: ${p.join('; ')}`); }
  const first = packageFiles(k, '1 hour, 1 minute, 30 seconds'), second = packageFiles(k, k.derived);
  const told = 'Example check: 1 acceptance example(s) contradict the Intent\'s rules; nothing was published.\n- scenario: x';
  const requestText = PACKAGES.durations.request;
  const checkText = files => `Slug: durations\n\n# Request\n\n${requestText}\n\n# Candidate intent.md\n\n${files[0].content}\n\n# Candidate acceptance.feature\n\n${files[1].content}`;
  const checkReq = files => ({ kind: 'check', json: { tools: [{ type: 'function', name: CHECK_TOOL }] }, text: checkText(files) });
  const shaperReq = (outputs = []) => ({ kind: 'shaper', json: { tools: [{ name: 'read_file' }, { name: 'submit' }], input: outputs }, text: '' });
  const event = result => ({ event: 'example_check', follows: result === 'follows' ? 1 : 0, contradicts: result === 'contradicts' ? 1 : 0, unquoted: result === 'unquoted' ? 1 : 0, items: [{ ...checkItem(k, 'x'), result }] });
  const disk = files => Object.fromEntries(files.map(f => [f.path, f.content]));
  const obs = {
    shape: { code: 0, out: 'kogen: shaping (request 1, 0 s)\nNext: kogen intent approve durations\n' },
    requestText, submissions: [first, second],
    requests: [shaperReq(), checkReq(first), shaperReq([{ type: 'function_call_output', call_id: 'call-inspect-prepared-1', output: '# Fixture project' }, { type: 'function_call_output', call_id: 'call-submit-prepared-1', output: told }]), checkReq(second)],
    events: [{ event: 'step_selfcheck' }, event('contradicts'), event('follows')],
    disk: disk(second),
  };
  const all = (o, results, files, text) => [...linesInOrderProblems(o.shape.out, 'Next: kogen intent approve durations', 'shape'), ...feedbackProblems(o, text), ...checkRequestProblems(o), ...eventProblems(o, results), ...packageProblems(o, files)];
  const ok = all(obs, ['contradicts', 'follows'], second, told);
  if (ok.length) throw new Error(`known-good observation rejected: ${ok.join('; ')}`);
  if (which === 'good') return 'accepted';
  const variant = change => { const o = structuredClone(obs); change(o); return o; };
  const bad = [
    // fixtures whose scripted derivation does not follow from the input
    () => fixtureProblems({ ...k, derived: '1 hour, 1 minute, 30 seconds' }),
    () => fixtureProblems({ slug: 'amounts', input: 'ACCT00042-120EUR', derived: '-12.00' }),
    () => fixtureProblems({ slug: 'key-order', input: '{"b":1,"a":2,"C":3}', derived: 'b, a, C' }),
    () => fixtureProblems({ slug: 'unknown', input: '1', derived: '1' }),
    // the old behavior: published at once, no check, no feedback
    () => all(variant(o => { o.requests = [shaperReq()]; o.events = [{ event: 'step_selfcheck' }]; o.disk = disk(first); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.requests[2].json.input[1].output = `${told}\nextra`; }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.requests[2].json.input[1].call_id = 'call-submit-other'; }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.requests.pop(); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.requests[1].json.tools.push({ name: 'read_file' }); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.requests[3].text = checkText(first); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.requests[1].text = o.requests[1].text.replace(requestText, ''); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.events.reverse(); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.events[1].contradicts = 0; }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.events = o.events.slice(0, 2); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.disk = disk(first); }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { delete o.disk[EXAMPLE_STEPS]; }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.disk[second[0].path] += '\n'; }), ['contradicts', 'follows'], second, told),
    () => all(variant(o => { o.shape.out = 'kogen: shaping (request 1, 0 s)\n'; }), ['contradicts', 'follows'], second, told),
    () => linesInOrderProblems('b\na\n', 'a\nb', 'shape'),
  ];
  bad.forEach((counterexample, i) => { if (!counterexample().length) throw new Error(`counterexample ${i + 1} accepted`); });
  return 'rejected';
}

if (require.main === module) {
  try {
    if (process.argv[2] !== '--control' || !['good', 'bad'].includes(process.argv[3])) throw new Error('usage: --control good|bad');
    const verdict = control(process.argv[3]);
    process.stdout.write(`${verdict}\n`);
    process.exitCode = verdict === 'accepted' ? 0 : 1;
  } catch (e) { process.stderr.write(`${e.message}\n`); process.exitCode = 2; }
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  const H = require('./go_driver_support.js');

  let suite;
  const sharedSuite = () => { if (!suite) suite = H.setupSuite(); return suite; };

  // Answers shaper requests and example check requests (those offering submit_example_check) from separate queues, so
  // each check answer belongs to the candidate it checks; every /v1/responses request is kept with its kind and text.
  function route(server, shaper, checks) {
    server.flowRequests = [];
    server.handle = async function (req, res) {
      if (req.url !== '/v1/responses') return H.FakeProvider.prototype.handle.call(this, req, res);
      const chunks = []; for await (const b of req) chunks.push(b);
      let json;
      try { json = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return this.send(res, 400, 'application/json', JSON.stringify(H.REFUSED)); }
      const kind = (json.tools || []).some(t => t && t.name === CHECK_TOOL) ? 'check' : 'shaper';
      const index = this.next++;
      const request = { method: req.method, path: req.url, json, headers: req.headers };
      this.provider.push(request);
      let text = '';
      try { text = H.FakeProvider.inputText(request); } catch { text = JSON.stringify(json.input || ''); }
      server.flowRequests.push({ kind, json, text });
      const queue = kind === 'check' ? checks : shaper;
      return this.respond(res, queue.length ? queue.shift() : { http: [400, H.REFUSED] }, index);
    };
  }

  function readText(file) { try { return fs.readFileSync(file, 'utf8'); } catch { return null; } }

  // Shapes the prepared package once per expected value submitted (in order), then observes what Kogen printed, sent,
  // recorded and left on disk, and runs the approval card (and, when asked, approval with the full hash).
  async function shapeFlow(k, expectations, { hash = false } = {}) {
    const submissions = expectations.map(e => packageFiles(k, e));
    const shaper = submissions.map((files, i) => H.inspectThenSubmit('submit', { files }, `prepared-${i + 1}`));
    const checks = expectations.map(e => H.fn(CHECK_TOOL, { examples: [checkItem(k, e)] }));
    const c = await H.project(await sharedSuite(), []);
    try {
      route(c.server, shaper, checks);
      const requestText = PACKAGES[k.slug].request;
      const requestFile = path.join(c.root, 'request.md');
      fs.writeFileSync(requestFile, requestText);
      const shape = await H.runKogen(c, ['intent', 'shape', k.slug, requestFile], { timeout: 8 * H.MIN });
      const at = rel => path.join(c.repo, rel);
      const events = (readText(at(`.kogen/local/shaping/${k.slug}/events.ndjson`)) || '').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return { unparsed: l }; } });
      const disk = Object.fromEntries(submissions[0].map(f => [f.path, readText(at(f.path))]));
      const readiness = fs.existsSync(at(`.kogen/local/readiness/${k.slug}.json`));
      const receipt = fs.existsSync(at(`.kogen/local/provenance/${k.slug}/current.json`));
      const card = await H.runKogen(c, ['intent', 'approve', k.slug]);
      let approval = null;
      if (hash) {
        const sha = await H.baselineHash(c, k.slug);
        const r = await H.runKogen(c, ['intent', 'approve', k.slug, sha]);
        approval = { code: r.code, out: r.out, marker: fs.existsSync(H.approvalPath(c.repo, k.slug)) };
      }
      return { shape, requestText, submissions, requests: c.server.flowRequests.slice(), events, disk, readiness, receipt, card, approval };
    } finally { await H.cleanupCase(c); }
  }

  const prepared = world => { assert.ok(world.prepared, 'no prepared package in this scenario'); return world.prepared; };
  const observed = world => { assert.ok(world.preparedObs, 'the prepared package was not shaped in this scenario'); return world.preparedObs; };
  const none = problems => assert.deepEqual(problems, [], problems.join('\n'));

  Given('the prepared package {string} states the rule {string}', function (slug, rule) {
    assert.ok(PACKAGES[slug], `fixture error: no prepared package ${JSON.stringify(slug)}`);
    this.prepared = { slug, rule };
  });

  Given('the prepared example {string} has input {string}', function (scenario, input) {
    Object.assign(prepared(this), { scenario, input });
  });

  Given('the example check of the prepared package derives {string} because {string}', function (derived, why) {
    const k = Object.assign(prepared(this), { derived, why });
    none(fixtureProblems(k));
  });

  When('the shaper submits the prepared example expecting {string}, then expecting {string}', { timeout: 20 * 60000 }, async function (first, second) {
    this.preparedObs = await shapeFlow(prepared(this), [first, second]);
  });

  When('the shaper submits the prepared example expecting {string} three times', { timeout: 20 * 60000 }, async function (expected) {
    this.preparedObs = await shapeFlow(prepared(this), [expected, expected, expected], { hash: true });
  });

  When('the shaper submits the prepared example expecting {string}', { timeout: 20 * 60000 }, async function (expected) {
    this.preparedObs = await shapeFlow(prepared(this), [expected]);
  });

  Then('shaping the prepared package exited with status {int}', function (status) {
    const o = observed(this);
    assert.equal(o.shape.code, status, `kogen intent shape exited ${o.shape.code}, expected ${status}:\n${o.shape.out}`);
  });

  Then('shaping the prepared package printed the line {string}', function (line) {
    const o = observed(this);
    assert.ok(lines(o.shape.out).includes(line), `kogen intent shape did not print the line ${JSON.stringify(line)}:\n${o.shape.out}`);
  });

  Then('shaping the prepared package printed these lines in order:', function (text) {
    none(linesInOrderProblems(observed(this).shape.out, text, 'kogen intent shape'));
  });

  Then('after its first prepared submission the shaper was told exactly:', function (text) {
    none(feedbackProblems(observed(this), text));
  });

  Then('every example check request offered only the tool {string} and carried the request and the candidate package', function (tool) {
    assert.equal(tool, CHECK_TOOL);
    none(checkRequestProblems(observed(this)));
  });

  Then('the prepared package\'s shaping events record example check results {string}', function (results) {
    none(eventProblems(observed(this), results.split(',').map(s => s.trim())));
  });

  Then('the published prepared package is exactly the one expecting {string}', function (expected) {
    none(packageProblems(observed(this), packageFiles(prepared(this), expected)));
  });

  Then('the approval card of the prepared package exits {int} and lists {string}', function (status, item) {
    const o = observed(this);
    assert.equal(o.card.code, status, `kogen intent approve ${prepared(this).slug} exited ${o.card.code}, expected ${status}:\n${o.card.out}`);
    assert.ok(lines(o.card.out).includes(`  - ${item}`), `the approval card does not list ${JSON.stringify(item)}:\n${o.card.out}`);
  });

  Then('the prepared package has no readiness evidence and no source receipt', function () {
    const o = observed(this), slug = prepared(this).slug;
    assert.equal(o.readiness, false, `.kogen/local/readiness/${slug}.json exists after the shape (exit ${o.shape.code}):\n${o.shape.out}`);
    assert.equal(o.receipt, false, `.kogen/local/provenance/${slug}/current.json exists after the shape (exit ${o.shape.code}):\n${o.shape.out}`);
  });

  Then('the approval card of the prepared package exits {int} and printed these lines in order:', function (status, text) {
    const o = observed(this);
    assert.equal(o.card.code, status, `kogen intent approve ${prepared(this).slug} exited ${o.card.code}, expected ${status}:\n${o.card.out}`);
    none(linesInOrderProblems(o.card.out, text, `kogen intent approve ${prepared(this).slug}`));
  });

  Then('approving the prepared package with its full hash exits {int}, prints {string} and writes no approval marker', function (status, line) {
    const o = observed(this), slug = prepared(this).slug;
    assert.ok(o.approval, 'approval with the full hash did not run');
    assert.equal(o.approval.code, status, `kogen intent approve ${slug} <full hash> exited ${o.approval.code}, expected ${status}:\n${o.approval.out}`);
    assert.ok(lines(o.approval.out).includes(line), `kogen intent approve ${slug} <full hash> did not print ${JSON.stringify(line)}:\n${o.approval.out}`);
    assert.equal(o.approval.marker, false, `.kogen/local/approvals/${slug}.json exists after approval with the full hash`);
  });

  Then('the shaping specification names the example check:', function (table) {
    for (const row of table.hashes()) {
      const text = fs.readFileSync(path.join(H.ROOT, row.path), 'utf8');
      assert.ok(text.includes(row.text), `${row.path} does not contain ${JSON.stringify(row.text)}`);
    }
  });
}
