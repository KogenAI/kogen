'use strict';
// K-EXAMPLES-OUTLINE. Shape's example check gives the checker every Scenario Outline expanded, one Scenario per Examples
// row with that row's values in place of its <placeholders>, and checks the quotes against that expanded text: a
// consistent outline is accepted unchanged, and a row whose expected value contradicts the rule is still refused, naming
// that row. The regression (d1ffe29, shaping L-YIELD-SNAPSHOT-RACE): an expected value quoted with its unsubstituted
// placeholders was compared with the row's value, so every row of a consistent outline was refused.
//
// The installed release runs through its CLI against the scripted local provider of go_driver_support.js; nothing
// contacts a real provider. The outline packages' features are prepared fixture files in k_examples_outline/, each with
// the exact text the check must be given in <name>.expanded.feature; their step definitions are trivial. The scripted
// example check answers what the scenario's tables say; "the example check answers candidate ..." first recomputes every
// derived value with the package's reference rule, so a scripted derivation that does not follow from its input is a
// fixture error, not product red. Before shaping, every fixture's expanded file is checked against the reference
// expansion below.
//
// Run directly, `node features/steps/k_examples_outline_steps.js --control good|bad` qualifies the observers and the
// fixtures: known-good observations are accepted (exit 0), known-bad ones rejected (exit 1).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const CHECK_TOOL = 'submit_example_check';
const EXAMPLE_STEPS = 'features/steps/example_steps.js';
const FIXTURES = path.join(__dirname, 'k_examples_outline');
const FEATURE_HEADING = '# Candidate acceptance.feature\n\n';
const FIELDS = ['scenario', 'input', 'expected', 'rule', 'derived', 'why'];

const fixture = name => fs.readFileSync(path.join(FIXTURES, `${name}.feature`), 'utf8');

// ------------------------------------------------------------------ the prepared outline fixtures

// The rows of a fixture's one Examples table as objects keyed by its header, cells trimmed.
function examplesRows(text) {
  const table = text.split('\n').filter(l => l.trim().startsWith('|')).map(l => l.trim().slice(1, -1).split('|').map(c => c.trim()));
  const [header, ...rows] = table;
  return rows.map(r => Object.fromEntries(header.map((h, i) => [h, r[i]])));
}

// The Intent's expansion for the fixtures' shape (one Scenario Outline of plain step lines and one Examples table): the
// lines from the keyword line through the last row become one Scenario per row, indented like the keyword line, its name
// and steps with the row's values in place of <header>, separated by one empty line; every other line is kept.
function referenceExpand(text) {
  const lines = text.split('\n');
  const start = lines.findIndex(l => /^\s*Scenario (Outline|Template):/.test(l));
  if (start < 0) return text;
  let end = start;
  lines.forEach((l, i) => { if (i > start && l.trim().startsWith('|')) end = i; });
  const examplesAt = lines.findIndex((l, i) => i > start && /^\s*(Examples|Scenarios):/.test(l));
  const indent = /^\s*/.exec(lines[start])[0];
  const name = lines[start].replace(/^\s*Scenario (Outline|Template):/, '').trim();
  const steps = lines.slice(start + 1, examplesAt).filter(l => /^\s*(Given|When|Then|And|But|\*) /.test(l));
  const subst = (s, row) => Object.entries(row).reduce((t, [k, v]) => t.replaceAll(`<${k}>`, v), s);
  const expanded = examplesRows(text).map(row => [`${indent}Scenario: ${subst(name, row)}`, ...steps.map(s => subst(s, row))].join('\n'));
  return [...lines.slice(0, start), expanded.join('\n\n'), ...lines.slice(end + 1)].join('\n');
}

function expansionProblems(name, expanded = fixture(`${name}.expanded`)) {
  const want = referenceExpand(fixture(name));
  return expanded === want ? [] : [`fixture error: ${name}.expanded.feature is not the expansion of ${name}.feature:\n${expanded}\nexpected:\n${want}`];
}

const unit = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const PACKAGES = {
  durations: {
    title: 'Render durations in words',
    request: 'Render a number of seconds as hours, minutes and seconds in words.\n',
    intro: 'A whole number of seconds renders as hours, minutes and seconds, for example `2 hours, 1 minute, 5 seconds`; a unit is singular when its count is 1 and plural otherwise.',
    steps: `const { Given, Then } = require('@cucumber/cucumber');

Given('the input {string}', function (input) {
  this.input = input;
});

Then('the output is {string}', function (output) {
  this.output = output;
});
`,
    reference: item => {
      if (!/^\d+$/.test(item.input)) throw new Error('not a whole number of seconds');
      const s = Number(item.input);
      return [unit(Math.floor(s / 3600), 'hour'), unit(Math.floor((s % 3600) / 60), 'minute'), unit(s % 60, 'second')].join(', ');
    },
  },
  'yield-regressions': {
    title: 'Keep the yield snapshot regressions passing',
    request: 'Fix the yield snapshot race; the existing shell lifecycle, retrieval and attempt cleanup regression tests keep passing.\n',
    intro: 'The yield snapshot fix keeps the existing shell lifecycle, retrieval and attempt cleanup regressions passing.',
    steps: `const { Then } = require('@cucumber/cucumber');

Then('the yield snapshot regression {string} in package {string} ran and passed', function (test, pkg) {
  this.regression = { test, pkg };
});
`,
    reference: item => {
      const row = examplesRows(fixture('yield-regressions')).find(r => r.test === item.input);
      if (!row) throw new Error('no Examples row names this test');
      return `the yield snapshot regression "${row.test}" in package "${row.package}" ran and passed`;
    },
  },
};

// The three files of an outline package whose acceptance.feature is the fixture `name`.
function packageFiles(k, name) {
  const p = PACKAGES[k.slug];
  const feature = `.kogen/intents/${k.slug}/acceptance.feature`;
  return [
    { path: `.kogen/intents/${k.slug}/intent.md`, content: `# ${p.title}

Slug: ${k.slug}
Model: not applicable — one stateless rule
Acceptance:
- ${feature}
- ${EXAMPLE_STEPS}

${p.intro}

Rule: ${k.rule}

## Decisions
- The output follows the rule stated above (source: request)

## Source comparison
- addressed: the rule and its examples; source request; contract prose and acceptance.feature.

## Tests
- the rule: the acceptance scenario outline (scenario)

## Feasibility
- none
` },
    { path: feature, content: fixture(name) },
    { path: EXAMPLE_STEPS, content: p.steps },
  ];
}

// A scripted answer must quote the package's rule and derive what the rule gives for its input; otherwise the fixture,
// not Kogen, is wrong.
function fixtureProblems(k) {
  const p = PACKAGES[k.slug];
  if (!p) return [`fixture error: no outline package ${JSON.stringify(k.slug)}`];
  const problems = [];
  (k.answers || []).forEach((items, c) => items.forEach(it => {
    if (it.rule !== k.rule) problems.push(`fixture error: candidate ${c + 1} answers with the rule ${JSON.stringify(it.rule)}, the package states ${JSON.stringify(k.rule)}`);
    let derived;
    try { derived = p.reference(it); } catch (e) { problems.push(`fixture error: the ${k.slug} rule cannot read input ${JSON.stringify(it.input)}: ${e.message}`); return; }
    if (derived !== it.derived) problems.push(`fixture error: the ${k.slug} rule gives ${JSON.stringify(derived)} for input ${JSON.stringify(it.input)}, but candidate ${c + 1}'s scripted example check derives ${JSON.stringify(it.derived)}`);
  }));
  return problems;
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
  const call = 'call-submit-outline-1';
  const outputs = obs.requests.flatMap(r => (r.json.input || []).filter(i => i.type === 'function_call_output' && i.call_id === call));
  if (!outputs.length) return [`the shaper was told nothing after its first submission: no later request carries the result of ${call} (shape exit ${obs.shape.code}):\n${obs.shape.out}`];
  const told = outputText(outputs[0].output);
  return told === expected ? [] : [`after its first submission the shaper was told:\n${told}\nexpected exactly:\n${expected}`];
}

// One example check request per submitted candidate, in order, each offering only the check tool and carrying the request
// text and the candidate intent.md, and giving as acceptance.feature (everything after its heading) exactly the expanded
// fixture text.
function checkRequestProblems(obs, expanded) {
  const checks = obs.requests.filter(r => r.kind === 'check');
  const problems = [];
  if (checks.length !== expanded.length) problems.push(`${checks.length} example check requests for ${obs.submissions.length} submitted candidates, expected ${expanded.length} (one per candidate) (shape exit ${obs.shape.code}):\n${obs.shape.out}`);
  checks.forEach((r, i) => {
    const tools = (r.json.tools || []).map(t => t.name);
    if (JSON.stringify(tools) !== JSON.stringify([CHECK_TOOL])) problems.push(`example check request ${i + 1} offers tools ${JSON.stringify(tools)}, expected only ${CHECK_TOOL}`);
    const files = obs.submissions[i];
    if (!files || !expanded[i]) return;
    for (const [what, content] of [['the request text', obs.requestText], ['the candidate intent.md', files[0].content]]) {
      if (!r.text.includes(content.trimEnd())) problems.push(`example check request ${i + 1} does not carry ${what}:\n${content}`);
    }
    const at = r.text.lastIndexOf(FEATURE_HEADING);
    const given = at < 0 ? null : r.text.slice(at + FEATURE_HEADING.length);
    if (given !== expanded[i].text) problems.push(`example check request ${i + 1} gave the checker as acceptance.feature:\n${given === null ? '(no "# Candidate acceptance.feature" heading)' : given}\nexpected exactly ${expanded[i].name}.feature:\n${expanded[i].text}`);
  });
  return problems;
}

// The example_check events of the shaping evidence, in order: the results of each event's items joined by "+".
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

function cardProblems(obs, status, item) {
  const problems = [];
  if (obs.card.code !== status) problems.push(`the approval card exited ${obs.card.code}, expected ${status}:\n${obs.card.out}`);
  if (!lines(obs.card.out).includes(`  - ${item}`)) problems.push(`the approval card does not list ${JSON.stringify(item)}:\n${obs.card.out}`);
  return problems;
}

function approvalProblems(obs, status, prefix) {
  const a = obs.approval;
  if (!a) return ['approval with the full hash did not run'];
  const problems = [];
  if (a.code !== status) problems.push(`approval with the full hash exited ${a.code}, expected ${status}:\n${a.out}`);
  const line = `${prefix} ${a.sha.slice(0, 8)}`;
  if (!lines(a.out).includes(line)) problems.push(`approval with the full hash did not print ${JSON.stringify(line)}:\n${a.out}`);
  if (a.marker !== true) problems.push(`approval with the full hash wrote no approval marker:\n${a.out}`);
  return problems;
}

// ------------------------------------------------------------------ controls

function control(which) {
  const FIXTURE_NAMES = ['yield-regressions', 'durations-consistent', 'durations-contradicting'];
  const rule = 'H is seconds div 3600, M is (seconds mod 3600) div 60 and S is seconds mod 60';
  const item = (s, input, expected, derived, why) => ({ scenario: `${s} seconds render as hours, minutes and seconds`, input, expected, rule, derived, why });
  const row3725 = item('3725', '3725', '1 hour, 2 minutes, 5 seconds', '1 hour, 2 minutes, 5 seconds', '3725 = 1*3600 + 2*60 + 5');
  const kept5430 = item('5430', '5430', '1 hour, 1 minute, 30 seconds', '1 hour, 30 minutes, 30 seconds', '5430 = 1*3600 + 30*60 + 30');
  const row5430 = { ...kept5430, expected: '1 hour, 30 minutes, 30 seconds' };
  const k = { slug: 'durations', rule, answers: [[row3725, kept5430], [row3725, row5430]] };
  const yRule = 'The existing tests in the scenario outline pass before and after.';
  const yItem = (test, pkg) => ({ scenario: 'Existing shell lifecycle, retrieval and attempt cleanup keep passing', input: test, expected: 'the yield snapshot regression "<test>" in package "<package>" ran and passed', rule: yRule, derived: `the yield snapshot regression "${test}" in package "${pkg}" ran and passed`, why: 'an existing test' });
  const y = { slug: 'yield-regressions', rule: yRule, answers: [[yItem('TestShellLifecycleSuccessCleanup', './conformance'), yItem('TestShellYieldRetrievalScope', './tools')]] };
  const known = [...FIXTURE_NAMES.flatMap(n => expansionProblems(n)), ...fixtureProblems(k), ...fixtureProblems(y)];
  if (known.length) throw new Error(`known-good fixture rejected: ${known.join('; ')}`);

  const first = packageFiles(k, 'durations-contradicting'), second = packageFiles(k, 'durations-consistent');
  const line = it => `- scenario: ${it.scenario} | input: ${it.input} | expected: ${it.expected} | rule: ${it.rule} | derived: ${it.derived} | why: ${it.why}`;
  const told = `Example check: 1 acceptance example(s) contradict the Intent's rules; nothing was published. Correct the expected value, the input or the rule so that each expected value follows from its input under the Intent's rules; do not remove or weaken an example to pass this check.\n${line(kept5430)}`;
  const requestText = PACKAGES.durations.request;
  const checkText = (files, feature) => `Slug: durations\n\n# Request\n\n${requestText}\n\n# Candidate intent.md\n\n${files[0].content}\n\n# Candidate acceptance.feature\n\n${feature}`;
  const checkReq = (files, feature) => ({ kind: 'check', json: { tools: [{ type: 'function', name: CHECK_TOOL }] }, text: checkText(files, feature) });
  const shaperReq = (outputs = []) => ({ kind: 'shaper', json: { tools: [{ name: 'read_file' }, { name: 'submit' }], input: outputs }, text: '' });
  const event = results => ({ event: 'example_check', follows: results.filter(r => r === 'follows').length, contradicts: results.filter(r => r === 'contradicts').length, unquoted: results.filter(r => r === 'unquoted').length, items: results.map(result => ({ ...row3725, result })) });
  const disk = files => Object.fromEntries(files.map(f => [f.path, f.content]));
  const expanded = ['durations-contradicting.expanded', 'durations-consistent.expanded'].map(name => ({ name, text: fixture(name) }));
  const sha = 'c0ffee12'.repeat(8);
  const cardItem = '<seconds> seconds render as hours, minutes and seconds (2 examples) (passes now)';
  const obs = {
    shape: { code: 0, out: 'kogen: shaping (request 1, 0 s)\nNext: kogen intent approve durations\n' },
    requestText, submissions: [first, second],
    requests: [shaperReq(), checkReq(first, expanded[0].text), shaperReq([{ type: 'function_call_output', call_id: 'call-inspect-outline-1', output: '# Fixture project' }, { type: 'function_call_output', call_id: 'call-submit-outline-1', output: told }]), checkReq(second, expanded[1].text)],
    events: [{ event: 'step_selfcheck' }, event(['follows', 'contradicts']), event(['follows', 'follows'])],
    disk: disk(second),
    card: { code: 5, out: `Acceptance\n  - ${cardItem}\n` },
    approval: { sha, code: 0, out: `approved durations ${sha.slice(0, 8)}\n`, marker: true },
  };
  const results = ['follows+contradicts', 'follows+follows'];
  const all = o => [...linesInOrderProblems(o.shape.out, 'Next: kogen intent approve durations', 'shape'), ...feedbackProblems(o, told), ...checkRequestProblems(o, expanded), ...eventProblems(o, results), ...packageProblems(o, second), ...cardProblems(o, 5, cardItem), ...approvalProblems(o, 0, 'approved durations')];
  const ok = [...all(obs), ...eventProblems({ events: [event(['unquoted', 'unquoted'])] }, ['unquoted+unquoted'])];
  if (ok.length) throw new Error(`known-good observation rejected: ${ok.join('; ')}`);
  if (which === 'good') return 'accepted';

  const variant = change => { const o = structuredClone(obs); change(o); return o; };
  const bad = [
    // fixtures that do not follow the rule or the Intent's expansion
    () => fixtureProblems({ ...k, answers: [[{ ...row5430, derived: '1 hour, 1 minute, 30 seconds' }]] }),
    () => fixtureProblems({ ...k, answers: [[{ ...row3725, rule: 'S is seconds' }]] }),
    () => fixtureProblems({ ...k, answers: [[{ ...row3725, input: 'about an hour' }]] }),
    () => fixtureProblems({ ...y, answers: [[{ ...y.answers[0][0], derived: y.answers[0][0].expected }]] }),
    () => fixtureProblems({ slug: 'unknown', rule, answers: [] }),
    () => expansionProblems('durations-consistent', fixture('durations-consistent')),
    () => expansionProblems('durations-consistent', fixture('durations-contradicting.expanded')),
    () => expansionProblems('yield-regressions', fixture('yield-regressions.expanded').replace('\n\n  Scenario', '\n  Scenario')),
    // the old behavior: the checker is given the raw outline, its quotes are unquoted and the contradiction is published
    () => all(variant(o => { o.requests[1].text = checkText(first, fixture('durations-contradicting')); o.requests[3].text = checkText(second, fixture('durations-consistent')); })),
    () => all(variant(o => { o.requests = [shaperReq(), checkReq(first, fixture('durations-contradicting'))]; o.events = [{ event: 'step_selfcheck' }, event(['unquoted', 'unquoted'])]; o.disk = disk(first); })),
    () => eventProblems({ events: [event(['contradicts', 'contradicts'])] }, ['unquoted+unquoted']),
    () => eventProblems({ events: [event(['unquoted', 'unquoted'])] }, ['follows+follows']),
    // other wrong observations
    () => all(variant(o => { o.requests[3].text = checkText(second, `${expanded[1].text}\n`); })),
    () => all(variant(o => { o.requests[3].text = checkText(second, expanded[0].text); })),
    () => all(variant(o => { o.requests[1].json.tools.push({ name: 'read_file' }); })),
    () => all(variant(o => { o.requests[1].text = o.requests[1].text.replace(requestText, ''); })),
    () => all(variant(o => { o.requests.pop(); })),
    () => all(variant(o => { o.requests[2].json.input[1].output = `${told}\n${line(row3725)}`; })),
    () => all(variant(o => { o.requests[2].json.input[1].call_id = 'call-submit-other'; })),
    () => all(variant(o => { o.events.reverse(); })),
    () => all(variant(o => { o.events[1].contradicts = 0; })),
    () => all(variant(o => { o.disk = disk(first); })),
    () => all(variant(o => { delete o.disk[EXAMPLE_STEPS]; })),
    () => all(variant(o => { o.shape.out = 'kogen: shaping (request 1, 0 s)\n'; })),
    () => all(variant(o => { o.card.out = o.card.out.replace('passes now', 'fails now'); })),
    () => all(variant(o => { o.card.code = 1; })),
    () => all(variant(o => { o.approval.code = 1; })),
    () => all(variant(o => { o.approval.marker = false; })),
    () => all(variant(o => { o.approval.out = 'approved durations 00000000\n'; })),
    () => all(variant(o => { o.approval = null; })),
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

  // Shapes the outline package once per fixture submitted (in order), the scripted check answering each candidate with
  // its table, then observes what Kogen printed, sent, recorded and left on disk, and runs the approval card (and, when
  // asked, approval with the full hash).
  async function shapeFlow(k, names, { hash = false } = {}) {
    none([...names.flatMap(n => expansionProblems(n)), ...fixtureProblems(k)]);
    assert.equal((k.answers || []).length, names.length, `fixture error: the example check answers ${(k.answers || []).length} candidate(s), ${names.length} are submitted`);
    const submissions = names.map(n => packageFiles(k, n));
    const shaper = submissions.map((files, i) => H.inspectThenSubmit('submit', { files }, `outline-${i + 1}`));
    const checks = k.answers.map(items => H.fn(CHECK_TOOL, { examples: items }));
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
      const card = await H.runKogen(c, ['intent', 'approve', k.slug]);
      let approval = null;
      if (hash) {
        const sha = await H.baselineHash(c, k.slug);
        const r = await H.runKogen(c, ['intent', 'approve', k.slug, sha]);
        approval = { sha, code: r.code, out: r.out, marker: fs.existsSync(H.approvalPath(c.repo, k.slug)) };
      }
      return { shape, requestText, submissions, requests: c.server.flowRequests.slice(), events, disk, card, approval };
    } finally { await H.cleanupCase(c); }
  }

  const outline = world => { assert.ok(world.outline, 'no outline package in this scenario'); return world.outline; };
  const observed = world => { assert.ok(world.outlineObs, 'the outline package was not shaped in this scenario'); return world.outlineObs; };
  const none = problems => assert.deepEqual(problems, [], problems.join('\n'));
  const names = list => list.split(',').map(s => s.trim());

  Given('the outline package {string} states the rule {string}', function (slug, rule) {
    assert.ok(PACKAGES[slug], `fixture error: no outline package ${JSON.stringify(slug)}`);
    this.outline = { slug, rule, answers: [] };
  });

  Given('the example check answers outline candidate {int} with:', function (n, table) {
    const k = outline(this);
    const rows = table.hashes();
    for (const r of rows) assert.deepEqual(Object.keys(r), FIELDS, `fixture error: an answer table has the columns ${JSON.stringify(Object.keys(r))}, expected ${JSON.stringify(FIELDS)}`);
    assert.equal(k.answers.length, n - 1, `fixture error: answers for outline candidate ${n} follow ${k.answers.length} candidate(s)`);
    k.answers.push(rows);
    none(fixtureProblems({ ...k, answers: [rows] }));
  });

  When('the shaper submits the outline fixture {string}', { timeout: 20 * 60000 }, async function (name) {
    this.outlineObs = await shapeFlow(outline(this), [name], { hash: true });
  });

  When('the shaper submits the outline fixture {string}, then the outline fixture {string}', { timeout: 20 * 60000 }, async function (first, second) {
    this.outlineObs = await shapeFlow(outline(this), [first, second]);
  });

  Then('shaping the outline package exited with status {int}', function (status) {
    const o = observed(this);
    assert.equal(o.shape.code, status, `kogen intent shape exited ${o.shape.code}, expected ${status}:\n${o.shape.out}`);
  });

  Then('after its first outline submission the shaper was told exactly:', function (text) {
    none(feedbackProblems(observed(this), text));
  });

  Then('the example check requests offered only the tool {string} and gave the checker, in order, the request, the candidate intent.md and the acceptance text of {string}', function (tool, list) {
    assert.equal(tool, CHECK_TOOL);
    none(checkRequestProblems(observed(this), names(list).map(name => ({ name, text: fixture(name) }))));
  });

  Then('the outline package\'s shaping events record example check results {string}', function (results) {
    none(eventProblems(observed(this), names(results)));
  });

  Then('shaping the outline package printed the line {string}', function (line) {
    const o = observed(this);
    assert.ok(lines(o.shape.out).includes(line), `kogen intent shape did not print the line ${JSON.stringify(line)}:\n${o.shape.out}`);
  });

  Then('the published outline package is exactly the one with the fixture {string}', function (name) {
    none(packageProblems(observed(this), packageFiles(outline(this), name)));
  });

  Then('the approval card of the outline package exits {int} and lists {string}', function (status, item) {
    none(cardProblems(observed(this), status, item));
  });

  Then('approving the outline package with its full hash exits {int}, prints {string} and the first eight characters of that hash, and writes an approval marker', function (status, prefix) {
    none(approvalProblems(observed(this), status, prefix));
  });
}
