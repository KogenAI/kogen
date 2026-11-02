'use strict';
// K-SHAPE-CONTRACT-CONSISTENT acceptance: an independent installed-CLI harness. The packaged `kogen` (go_driver_support.js
// installs the release archive) shapes against the scripted local provider; no real provider, account or credential is used.
//
// The three 2 Nov 2026 recurrences (Builds f63f53ce, fea7d4b7 and c8537207) are shaped in miniature in a fixture project:
// each contradicting package keeps the real contradicting expectation verbatim, and the fixture commits the unchanged code
// or text it contradicts (features/steps/README.md written by `kogen init`, the {format,value,references} wrapper of
// cli/cmd/runtime.go, addWorkspaceSchema of cli/cmd/mcp_schema.go, the SHP-4 sentence). A scripted shaper submits the
// contradicting package and then its correction; scripted contract reviewers and confirmers answer with findings and verdicts.
// Kogen alone decides which findings are evidenced and which candidates are refused.
//
// Run directly, `node features/steps/k_shape_contract_consistent_steps.js --control good|bad` qualifies the observers
// below: known-good observations are accepted (exit 0), known-bad counterexamples rejected (exit 1).

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const FEATURE = path.resolve(__dirname, '../../.kogen/intents/k-shape-contract-consistent/acceptance.feature');

// ------------------------------------------------------------------ the fixture project's unchanged code and text

const UNCHANGED = {
  'cli/cmd/json_references.go': `package cmd

const consultationReferenceFormat = "studio-consultation-dedup-v1"

// encodeJSONReferences wraps every consultation result as {format,value,references}.
func encodeJSONReferences(value any) map[string]any {
  return map[string]any{"format": consultationReferenceFormat, "value": value, "references": []any{}}
}
`,
  'cli/cmd/runtime.go': `package cmd

// publish prints the result of \`studio agent context PRODUCT\`; agent context always goes through the consultation encoding.
func publish(result any) any {
  var published any = result
  published = encodeJSONReferences(result)
  return published
}
`,
  'cli/cmd/mcp_schema.go': `package cmd

type schema map[string]any

func str() schema { return schema{"type": "string"} }

// toolSchemas applies addWorkspaceSchema to every tool schema, studio_artifact_read included.
func toolSchemas(out map[string]schema) map[string]schema {
  for _, s := range out {
    addWorkspaceSchema(s)
  }
  return out
}

func addWorkspaceSchema(s schema) {
  if branches, ok := s["oneOf"].([]any); ok {
    s["properties"].(schema)["workspace_id"] = str()
    for _, b := range branches {
      addWorkspaceSchema(b.(schema))
    }
    return
  }
  props := s["properties"].(schema)
  props["workspace_id"] = str()
  s["required"] = append(s["required"].([]string), "workspace_id")
}
`,
  'spec/prose/02-shaping.md': `# Shaping

**SHP-4 — Submission.** A valid complete merged submission is written, then the project's fixers run once in the repository root. The files are then checked for readiness (SHP-8); if the checks find problems, those go back to the shaper in the same way. After a not-ready attempt the shaper may also ask questions (SHP-6); the files of that attempt stay.
`,
};

// ------------------------------------------------------------------ the three cases in miniature

const intentText = ({ title, slug, model, steps, prose, decision }) => `# ${title}

Slug: ${slug}
Model: not applicable — ${model}
Acceptance:
- .kogen/intents/${slug}/acceptance.feature
- ${steps}

${prose}

## Decisions
- ${decision} (source: request)

## Source comparison
- addressed: ${decision}; source request; contract acceptance.feature.

## Tests
- ${decision}: the acceptance scenarios (scenario)

## Feasibility
- none
`;

const COLLISION_STEPS = 'features/steps/k_step_file_collision_steps.js';
const collisionSteps = (listing, refusal) => `'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { When, Then } = require('@cucumber/cucumber');

const own = slug => \`features/steps/\${slug}.js\`;
const A = 'greet-a', B = 'greet-b';

When('the Intents greet-a and greet-b have landed one after another', function () {
  for (const slug of [A, B]) assert.ok(fs.existsSync(own(slug)), \`\${own(slug)} has not landed\`);
});

When('greet-b was shaped with a package that borrows the step text of the landed greet-a', function () {
  assert.ok(fs.existsSync('.kogen/local/shaping/greet-b/events.ndjson'), 'greet-b has not been shaped');
});
${listing}${refusal}`;
const COLLISION_LIST_BAD = `
Then('main holds both Intents\\' own step files and nothing mixed', function () {
  const steps = fs.readdirSync('features/steps').filter(n => n !== 'k_step_file_collision_steps.js').sort();
  assert.deepEqual(steps, [own(A).split('/').pop(), own(B).split('/').pop(), 'integration_steps.js'], 'main must hold both Intents\\' own step files and nothing mixed');
});
`;
const COLLISION_REFUSAL_BAD = `
Then('the refused greet-b package is not published', function () {
  assert.equal(fs.existsSync('.kogen/intents/greet-b/intent.md'), false, '.kogen/intents/greet-b/intent.md must not be published');
});
`;
const COLLISION_LIST_GOOD = `
Then('main holds both Intents\\' own step files and its project step files', function () {
  const steps = fs.readdirSync('features/steps').filter(n => n !== 'k_step_file_collision_steps.js').sort();
  assert.deepEqual(steps, ['README.md', own(A).split('/').pop(), own(B).split('/').pop(), 'integration_steps.js'], 'main must hold both Intents\\' own step files and its project step files');
});
`;
const COLLISION_REFUSAL_GOOD = `
Then('the refused greet-b package stays as Shape left it', function () {
  assert.equal(fs.existsSync('.kogen/intents/greet-b/intent.md'), true, '.kogen/intents/greet-b/intent.md stays after the refused attempt (SHP-4)');
});
`;
const collisionFeature = (listing, refusal) => `Feature: Intents shaped in separate worktrees keep their own step files

  Scenario: Two Intents with the same step text land in either order
    When the Intents greet-a and greet-b have landed one after another
    Then ${listing}

  Scenario: Shape refuses a package that borrows another Intent's step text
    When greet-b was shaped with a package that borrows the step text of the landed greet-a
    Then ${refusal}
`;

const ROADMAP_STEPS = 'features/steps/s_roadmap_auto_steps.js';
const ROADMAP_STEP_TEXT = `'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { When, Then } = require('@cucumber/cucumber');

// Reads a dotted path; "name[]" maps the rest of the path over every item of a list and requires the key on each.
function select(value, parts) {
  if (parts.length === 0) return value;
  const [head, ...rest] = parts;
  const many = head.endsWith('[]'), key = many ? head.slice(0, -2) : head;
  assert.ok(value !== null && typeof value === 'object' && key in value, \`Missing \${key}\`);
  if (!many) return select(value[key], rest);
  assert.ok(Array.isArray(value[key]), \`\${key} is not a list\`);
  return value[key].map(item => select(item, rest));
}
function observe(result, raw, saved) {
  for (const e of JSON.parse(raw)) {
    const got = select(result, e.path.split('.'));
    assert.deepEqual(got, 'same' in e ? saved[e.same] : e.value, \`\${e.path}\`);
  }
}

When('the roadmap context of product {string} is read', function (product) {
  const file = \`fixtures/\${product}/roadmap-context.json\`;
  assert.ok(fs.existsSync(file), \`studio roadmap context \${product} printed nothing: \${file} is missing\`);
  this.roadmap = JSON.parse(fs.readFileSync(file, 'utf8'));
});

Then('the roadmap context has', function (raw) {
  observe(this.roadmap, raw, {});
});

Then('the agent context of product {string} has', function (product, raw) {
  const agent = JSON.parse(fs.readFileSync(\`fixtures/\${product}/agent-context.json\`, 'utf8'));
  observe(agent, raw, { projection: this.roadmap.projection });
});
`;
const roadmapFeature = (expect, agent) => `Feature: The product roadmap is derived from its owning records

  Scenario: Proposals and tasks are planned, and agent context carries the projection
    When the roadmap context of product "kogen" is read
    Then the roadmap context has
      """
      ${expect}
      """
    And the agent context of product "kogen" has
      """
      ${agent}
      """
`;

const DESIGN_STEPS = 'features/steps/s_design_guidance_steps.js';
const designSteps = read => `'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { When, Then } = require('@cucumber/cucumber');

// The MCP session of client c in workspace w; this fixture has none until the feature exists.
function session(c, w) {
  const file = \`fixtures/mcp/\${w}/\${c}.json\`;
  assert.ok(fs.existsSync(file), \`studio mcp serve for client \${c} in workspace \${w} is not available: \${file} is missing\`);
  const replies = JSON.parse(fs.readFileSync(file, 'utf8'));
  return { send: async (method, params) => replies[\`\${method} \${params.name} \${JSON.stringify(params.arguments)}\`] };
}
${read}
When('design client {string} in workspace {string} has guidance {string}', function (c, w, id) {
  this.design = session(c, w);
  this.guidance = id;
});

Then('design client {string} in workspace {string} exports guidance {string} containing', async function (c, w, id, raw) {
  const x = this.design;
  const r = await x.send('tools/call', { name: 'studio_guidance', arguments: { workspace_id: w, action: 'export', id } });
  assert.ok(r && !r.isError, JSON.stringify(r));
  const request = r.structuredContent.result.files.find(a => a.kind === 'request');
  const text = await read(x, w, request);
  for (const want of JSON.parse(raw)) assert.ok(text.includes(want), \`exported request \${id} lacks \${want}\`);
});
`;
const DESIGN_READ_BAD = `async function read(x, w, a) {
  const parts = []; let offset = 0;
  for (;;) {
    const c=await x.send('tools/call',{name:'studio_artifact_read',arguments:{artifact_id:a.artifact_id,offset,limit:4096}});
    assert.ok(c && !c.isError, JSON.stringify(c));
    const chunk = c.structuredContent.result; parts.push(chunk.text);
    if (chunk.next_offset === null) break;
    offset = chunk.next_offset;
  }
  return parts.join('');
}
`;
const DESIGN_READ_GOOD = DESIGN_READ_BAD.replace('arguments:{artifact_id:', 'arguments:{workspace_id:w,artifact_id:');
const DESIGN_FEATURE = `Feature: Design guidance reaches a fresh agent

  Scenario: A fresh agent exports the current design guidance
    When design client "owner" in workspace "atelier" has guidance "drops-badge"
    Then design client "owner" in workspace "atelier" exports guidance "drops-badge" containing
      """
      ["Design sources", "drops-badge"]
      """
`;

const intentOf = slug => `.kogen/intents/${slug}/intent.md`;
const featureOf = slug => `.kogen/intents/${slug}/acceptance.feature`;

const CASES = {
  'k-step-file-collision': {
    request: 'Keep the step files of Intents shaped in parallel worktrees apart.\n',
    intent: intentText({
      title: 'Keep step files of parallel Intents apart', slug: 'k-step-file-collision', steps: COLLISION_STEPS,
      model: 'a naming rule and the step files one acceptance run loads; no new states or transitions',
      prose: 'Two Intents greet-a and greet-b, shaped at the same time in two worktrees with the same step text, land one after another, and each Intent owns its step files by name. A package of greet-b that borrows the step text of greet-a is refused.\n\n' +
        '- Every other file in the steps folder is a project step file, for example `features/steps/go_driver_support.js`, `features/steps/greeting_steps.js` and a file named for a slug that has no Intent folder.\n' +
        '- Nothing else about shaping or building changes.',
      decision: 'An Intent\'s approved package never refers to or depends on another Intent\'s step file or step text',
    }),
    bad: { feature: collisionFeature('main holds both Intents\' own step files and nothing mixed', 'the refused greet-b package is not published'), steps: collisionSteps(COLLISION_LIST_BAD, COLLISION_REFUSAL_BAD) },
    good: { feature: collisionFeature('main holds both Intents\' own step files and its project step files', 'the refused greet-b package stays as Shape left it'), steps: collisionSteps(COLLISION_LIST_GOOD, COLLISION_REFUSAL_GOOD) },
    stepsPath: COLLISION_STEPS,
    review: [
      { scenario: 'Two Intents with the same step text land in either order',
        expectation: { path: COLLISION_STEPS, quote: "[own(A).split('/').pop(), own(B).split('/').pop(), 'integration_steps.js']" },
        contract: { path: 'features/steps/README.md', quote: 'Cucumber step definitions for Kogen acceptance scenarios.' },
        why: 'kogen init wrote and committed features/steps/README.md, a project step file that stays, so the steps folder on main also holds README.md and this exact list cannot match.' },
      { scenario: "Shape refuses a package that borrows another Intent's step text",
        expectation: { path: COLLISION_STEPS, quote: "'.kogen/intents/greet-b/intent.md must not be published'" },
        contract: { path: 'spec/prose/02-shaping.md', quote: 'the files of that attempt stay' },
        why: 'The borrowing package is written before the step self-check refuses it, and Shape keeps the files of a refused attempt, so intent.md exists after the refusal.' },
      { scenario: 'Two Intents with the same step text land in either order',
        expectation: { path: COLLISION_STEPS, quote: "[own(A).split('/').pop(), own(B).split('/').pop(), 'integration_steps.js']" },
        contract: { path: 'cli/shape/init.go', quote: 'initStepsReadmePath = "features/steps/README.md"' },
        why: 'kogen init writes features/steps/README.md.' },
    ],
    verdicts: [
      { finding: 1, verdict: 'confirmed', why: 'features/steps/README.md is committed at HEAD and the Intent keeps project step files, so the folder always lists it.' },
      { finding: 2, verdict: 'confirmed', why: 'Shape keeps the files of a refused attempt, so the borrowing package\'s intent.md is present after its refusal.' },
    ],
    second: [],
  },
  's-roadmap-auto': {
    request: 'Derive the product roadmap automatically from its owning records.\n',
    intent: intentText({
      title: 'Derive the product roadmap from its owning records', slug: 's-roadmap-auto', steps: ROADMAP_STEPS,
      model: 'the projection is a pure read-time derivation of existing owner records',
      prose: 'Every roadmap read returns a `projection`: every owner record of the product placed in exactly one of seven lanes. Every result shaped like roadmap context, including the `roadmap` object inside `studio agent context PRODUCT`, gains the key `projection`. The Go `roadmap`/`agent context` commands pass results through, so no CLI change.\n\n' +
        '| type | id / title / status | additional keys |\n| --- | --- | --- |\n' +
        "| `proposal` (Room proposal) | record ID / latest revision title / `retired` when the record is retired, otherwise the latest revision's status | `revision` (latest revision), `draft`: null when never attached, else `{state,order_position}` with the draft's `active`/`retired` state and its 1-based position in `ordered_ids` (null when not ordered) |\n" +
        '| `task` | task ID / latest content title / caller-reported `state.status` | `mode`, `holds`, `next_action`, `build` |',
      decision: 'The roadmap view is derived automatically at read time from owner records',
    }),
    bad: { feature: roadmapFeature(
      '[{"path": "projection.lanes[].items[].type", "value": [[], [], ["proposal", "proposal", "task"], [], [], [], []]}, {"path": "projection.lanes.2.items[].draft", "value": [{"state": "active", "order_position": 1}, null, null]}]',
      '[{"path": "roadmap.projection", "same": "projection"}]'), steps: ROADMAP_STEP_TEXT },
    good: { feature: roadmapFeature(
      '[{"path": "projection.lanes[].items[].type", "value": [[], [], ["proposal", "proposal", "task"], [], [], [], []]}, {"path": "projection.lanes.2.items.0.draft", "value": {"state": "active", "order_position": 1}}, {"path": "projection.lanes.2.items.1.draft", "value": null}]',
      '[{"path": "value.roadmap.projection", "same": "projection"}]'), steps: ROADMAP_STEP_TEXT },
    stepsPath: ROADMAP_STEPS,
    review: [
      { scenario: 'Proposals and tasks are planned, and agent context carries the projection',
        expectation: { path: featureOf('s-roadmap-auto'), quote: '{"path": "projection.lanes.2.items[].draft", "value": [{"state": "active", "order_position": 1}, null, null]}' },
        contract: { path: intentOf('s-roadmap-auto'), quote: '| `task` | task ID / latest content title / caller-reported `state.status` | `mode`, `holds`, `next_action`, `build` |' },
        why: 'The planned lane holds proposal, proposal, task; the contract gives draft to proposals only, so the task item has no draft key and reading draft on every item fails.' },
      { scenario: 'Proposals and tasks are planned, and agent context carries the projection',
        expectation: { path: featureOf('s-roadmap-auto'), quote: '[{"path": "roadmap.projection", "same": "projection"}]' },
        contract: { path: 'cli/cmd/runtime.go', quote: 'published = encodeJSONReferences(result)' },
        why: 'The unchanged Go CLI wraps agent context as {format,value,references}, so the projection is at value.roadmap.projection, never at a top-level roadmap.projection.' },
    ],
    verdicts: [
      { finding: 1, verdict: 'confirmed', why: 'Only proposals carry draft; the task in the planned lane has mode, holds, next_action and build.' },
      { finding: 2, verdict: 'confirmed', why: 'cli/cmd/runtime.go publishes encodeJSONReferences(result), whose top level is format, value and references.' },
    ],
    second: [],
  },
  's-design-guidance': {
    request: 'Let a fresh agent export the current design guidance.\n',
    intent: intentText({
      title: 'Export design guidance for fresh agents', slug: 's-design-guidance', steps: DESIGN_STEPS,
      model: 'guidance export reads existing records; no new state',
      prose: 'A fresh agent exports a product\'s design guidance through the MCP tool `studio_guidance` (action `export`) and reads the exported request file with `studio_artifact_read`. Existing MCP tool schemas stay unchanged.',
      decision: 'A fresh agent receives the current design guidance through the existing MCP tools',
    }),
    bad: { feature: DESIGN_FEATURE, steps: designSteps(DESIGN_READ_BAD) },
    good: { feature: DESIGN_FEATURE, steps: designSteps(DESIGN_READ_GOOD) },
    stepsPath: DESIGN_STEPS,
    review: [
      { scenario: 'A fresh agent exports the current design guidance',
        expectation: { path: DESIGN_STEPS, quote: 'arguments:{artifact_id:a.artifact_id,offset,limit:4096}' },
        contract: { path: 'cli/cmd/mcp_schema.go', quote: 's["required"] = append(s["required"].([]string), "workspace_id")' },
        why: 'addWorkspaceSchema makes workspace_id required on every tool schema, studio_artifact_read included, and the Intent keeps the schemas unchanged, so this read is rejected with missing properties: ["workspace_id"].' },
    ],
    verdicts: [
      { finding: 1, verdict: 'confirmed', why: 'The unchanged schema requires workspace_id and the read sends only artifact_id, offset and limit.' },
    ],
    second: [
      { scenario: 'A fresh agent exports the current design guidance',
        expectation: { path: DESIGN_STEPS, quote: 'limit:4096' },
        contract: { path: 'cli/cmd/mcp_schema.go', quote: 'props["workspace_id"] = str()' },
        why: 'The artifact read asks for 4096 bytes, more than the schema allows.' },
    ],
    secondVerdicts: [
      { finding: 1, verdict: 'refuted', why: 'The schema sets no maximum for limit, and the read now names its workspace_id.' },
    ],
  },
};
for (const [slug, c] of Object.entries(CASES)) {
  c.slug = slug;
  // The corrected package resubmits only what changed; the acknowledgment resubmits intent.md unchanged.
  c.fix = [];
  if (c.good.feature !== c.bad.feature) c.fix.push({ path: featureOf(slug), content: c.good.feature });
  if (c.good.steps !== c.bad.steps) c.fix.push({ path: c.stepsPath, content: c.good.steps });
}

// ------------------------------------------------------------------ the formats the Intent states (used by the controls)

const norm = s => String(s).split(/[ \t\r\n]+/).filter(Boolean).join(' ');
const headline = n => `Contract check: ${n} acceptance expectation(s) contradict the Intent or code it keeps unchanged, so no correct implementation can pass them; nothing was published. ` +
  'Correct each expectation, or the Intent where the Intent is what is wrong, so that a correct implementation passes; do not delete or weaken a scenario to pass this check. ' +
  'Resubmitting this candidate unchanged is refused again.';
const body = f => `expectation: ${norm(f.expectation.path)}: ${norm(f.expectation.quote)} | contract: ${norm(f.contract.path)}: ${norm(f.contract.quote)} | why: ${norm(f.why)}`;
const itemLine = (f, v) => `- ${norm(f.scenario)} | ${body(f)} | confirmed: ${norm(v.why)}`;
const findingLine = (f, i) => `${i + 1}. scenario: ${norm(f.scenario)} | ${body(f)}`;
const APPROVAL = slug => `intent/contract_contradicts: Shape's contract check found acceptance expectations that contradict the Intent or code it keeps unchanged; correct the Intent's files, or shape it again with kogen intent shape ${slug} <request-file>`;

// ------------------------------------------------------------------ observers (pure; qualified by the controls)

const lines = text => String(text).split('\n').map(l => l.replace(/\r$/, ''));
const strip = text => String(text).replace(/\n+$/, '');
function printedInOrder(out, expected, what) {
  const got = lines(out);
  let at = 0;
  for (const want of lines(strip(expected))) {
    const found = got.findIndex((l, i) => i >= at && l.includes(want));
    assert.ok(found >= 0, `${what} did not print ${JSON.stringify(want)} (in order) in:\n${out}`);
    at = found + 1;
  }
}
function exited(o, status) {
  assert.equal(o.code, status, `kogen intent shape ${o.slug} exited ${o.code}, expected ${status}:\n${o.out}`);
}
function requestKinds(o, expected) {
  const want = expected.split(',').map(s => s.trim());
  assert.deepEqual(o.kinds, want, `the requests of kogen intent shape ${o.slug} were ${JSON.stringify(o.kinds)}, expected ${JSON.stringify(want)}`);
}
const READ_ONLY = ['read_file', 'list_files', 'search_text'];
function checkTools(o) {
  let reviews = 0;
  o.kinds.forEach((k, i) => {
    if (k === 'shaper') return;
    reviews++;
    const want = [...READ_ONLY, k === 'review' ? 'submit_contract_review' : 'submit_contract_confirmation'].sort();
    assert.deepEqual([...o.tools[i]].sort(), want, `${k} request ${i + 1} of ${o.slug} offered the tools ${JSON.stringify(o.tools[i])}`);
  });
  assert.ok(reviews > 0, `kogen intent shape ${o.slug} made no contract review request`);
}
function reviewInput(o, c, observed) {
  const i = o.kinds.indexOf('review');
  assert.ok(i >= 0, `kogen intent shape ${o.slug} made no contract review request`);
  const text = o.inputs[i];
  const sections = [
    `Slug: ${o.slug}\n\n# Candidate intent.md\n\n${strip(c.intent)}\n\n# Candidate acceptance.feature\n\n${strip(c.bad.feature)}\n\n`,
    `\n\n# Candidate step file ${c.stepsPath}\n\n${strip(c.bad.steps)}\n\n`,
    '\n\n# Readiness observations\n\nReadiness observations\nChecked baseline: ',
  ];
  assert.ok(text.startsWith(sections[0]), `contract review request ${i + 1} of ${o.slug} does not begin with the slug, the candidate intent.md and acceptance.feature:\n${text.slice(0, 3000)}`);
  for (const s of sections.slice(1)) assert.ok(text.includes(s), `contract review request ${i + 1} of ${o.slug} lacks ${JSON.stringify(s.slice(0, 120))}:\n${text.slice(0, 6000)}`);
  for (const want of lines(strip(observed))) assert.ok(text.includes(want), `contract review request ${i + 1} of ${o.slug} lacks the readiness observation ${JSON.stringify(want)}`);
}
function reviewInstructions(o, expected) {
  const i = o.kinds.indexOf('review');
  assert.ok(i >= 0, `kogen intent shape ${o.slug} made no contract review request`);
  for (const want of lines(strip(expected))) assert.ok(String(o.instructions[i]).includes(want), `the contract review instructions of ${o.slug} lack ${JSON.stringify(want)}`);
}
function confirmationFindings(o, expected) {
  const i = o.kinds.indexOf('confirmation');
  assert.ok(i >= 0, `kogen intent shape ${o.slug} made no confirmation request`);
  const text = o.inputs[i];
  assert.ok(text.startsWith(`Slug: ${o.slug}\n\n# Candidate intent.md\n\n`), `confirmation request ${i + 1} of ${o.slug} does not carry the candidate:\n${text.slice(0, 2000)}`);
  assert.ok(text.endsWith(`\n\n# Findings to verify\n\n${strip(expected)}`), `confirmation request ${i + 1} of ${o.slug} does not end with exactly these findings:\n${strip(expected)}\nactual:\n${text.slice(-4000)}`);
}
function feedbackExactly(o, n, expected) {
  assert.equal(o.feedback[n], strip(expected), `the feedback to submission ${n} of ${o.slug} is not exactly the expected text`);
}
function feedbackObservations(o, n) {
  const text = o.feedback[n];
  assert.ok(typeof text === 'string' && text.includes('Readiness observations'), `the feedback to submission ${n} of ${o.slug} is not readiness observations:\n${text}`);
  assert.ok(!text.includes('Contract check:'), `the feedback to submission ${n} of ${o.slug} is a contract refusal:\n${text}`);
}
function publishedCorrection(o, c) {
  assert.equal(o.files[intentOf(o.slug)], c.intent, `${intentOf(o.slug)} on disk is not the shaped intent.md`);
  assert.equal(o.files[featureOf(o.slug)], c.good.feature, `${featureOf(o.slug)} on disk is not the corrected acceptance.feature`);
  assert.equal(o.files[c.stepsPath], c.good.steps, `${c.stepsPath} on disk is not the corrected step file`);
  assert.ok(lines(o.out).includes(`Next: kogen intent approve ${o.slug}`), `kogen intent shape ${o.slug} did not report the package ready:\n${o.out}`);
}
function reviewEvents(o, rows) {
  const got = o.reviews.map(e => ({ result: e.result, findings: String(e.findings), evidenced: String(e.evidenced), confirmed: String(e.confirmed) }));
  assert.deepEqual(got, rows, `the contract_review events of ${o.slug} were ${JSON.stringify(o.reviews)}`);
}
function refusedEvents(o, count, gate) {
  assert.equal(o.refused.length, count, `expected ${count} submission_refused events for ${o.slug}, got ${JSON.stringify(o.refused)}`);
  for (const e of o.refused) assert.equal(e.gate, gate, `a submission_refused event of ${o.slug} has gate ${JSON.stringify(e.gate)}: ${JSON.stringify(e)}`);
}
function readinessRuns(o, n) {
  assert.equal(o.observations, n, `readiness wrote ${o.observations} observation file(s) in kogen intent shape ${o.slug}, expected ${n}`);
}
function commandEnded(r, what, status, expected) {
  assert.ok(r, `${what} did not run`);
  assert.equal(r.code, status, `${what} exited ${r.code}, expected ${status}:\n${r.out}`);
  printedInOrder(r.out, expected, what);
}

// ------------------------------------------------------------------ the installed flows

function readOr(file) { return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null; }
function toolNames(r) { return ((r.json && r.json.tools) || []).map(t => t.name || (t.function && t.function.name)); }
function kindOf(r) {
  const names = toolNames(r);
  if (names.includes('submit_contract_review')) return 'review';
  if (names.includes('submit_contract_confirmation')) return 'confirmation';
  return 'shaper';
}
function inputText(r) {
  return ((r.json && r.json.input) || []).filter(i => i.role === 'user').map(i => typeof i.content === 'string' ? i.content : Array.isArray(i.content) ? i.content.map(b => b.text || '').join('') : '').join('\n');
}
// The instructions of a request: its instructions field and any developer message.
function instructionsText(r) {
  const dev = ((r.json && r.json.input) || []).filter(i => i.role === 'developer' || i.role === 'system').map(i => typeof i.content === 'string' ? i.content : Array.isArray(i.content) ? i.content.map(b => b.text || '').join('') : '');
  return [(r.json && r.json.instructions) || '', ...dev].join('\n');
}
// The shaper's submit calls in conversation order and the tool output each received.
function submissions(requests) {
  const ids = [], outputs = new Map();
  for (const r of requests) {
    for (const item of (r.json && r.json.input) || []) {
      if (item.type === 'function_call' && item.name === 'submit' && !ids.includes(item.call_id)) ids.push(item.call_id);
      if (item.type === 'function_call_output' && !outputs.has(item.call_id)) outputs.set(item.call_id, item.output);
    }
  }
  const feedback = {};
  ids.forEach((id, i) => { if (outputs.has(id)) feedback[i + 1] = outputs.get(id); });
  return feedback;
}
async function shapeOnce(H, c, slug, script) {
  const before = c.server.providerRequests().length;
  c.server.setScript(script);
  const request = path.join(c.root, `${slug}-request.md`); fs.writeFileSync(request, CASES[slug].request);
  const r = await H.runKogen(c, ['intent', 'shape', slug, request], { timeout: 6 * H.MIN });
  const requests = c.server.providerRequests().slice(before);
  const shaping = path.join(c.repo, `.kogen/local/shaping/${slug}`);
  const events = (readOr(path.join(shaping, 'events.ndjson')) || '').split('\n').filter(Boolean).map(l => JSON.parse(l));
  const k = CASES[slug];
  return {
    slug, code: r.code, out: r.out, request,
    kinds: requests.map(kindOf), tools: requests.map(toolNames), inputs: requests.map(inputText), instructions: requests.map(instructionsText),
    feedback: submissions(requests.filter(q => kindOf(q) === 'shaper')),
    reviews: events.filter(e => e.event === 'contract_review'),
    refused: events.filter(e => e.event === 'submission_refused'),
    observations: fs.existsSync(shaping) ? fs.readdirSync(shaping).filter(n => /^observations-\d+\.txt$/.test(n)).length : 0,
    files: Object.fromEntries([intentOf(slug), featureOf(slug), k.stepsPath].map(p => [p, readOr(path.join(c.repo, p))])),
  };
}
async function fixtureProject(H, suite) {
  const c = await H.project(suite, [], { stagedIntent: false });
  for (const [p, text] of Object.entries(UNCHANGED)) {
    const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text);
  }
  await H.git(c, ['add', '-A']);
  await H.git(c, ['commit', '-qm', 'Add the unchanged fixture code']);
  return c;
}

const cache = new Map();
// The three regressions, shaped one after another in one fixture project.
async function regressions() {
  if (cache.has('regressions')) return cache.get('regressions');
  const H = require('./go_driver_support.js');
  const f = H.fn;
  const suite = await H.setupSuite(); let c;
  try {
    c = await fixtureProject(H, suite);
    const all = {};
    for (const [slug, k] of Object.entries(CASES)) {
      all[slug] = await shapeOnce(H, c, slug, [
        H.inspectThenSubmit('submit', { files: [{ path: intentOf(slug), content: k.intent }, { path: featureOf(slug), content: k.bad.feature }, { path: k.stepsPath, content: k.bad.steps }] }, slug),
        f('submit_contract_review', { findings: k.review }),
        f('submit_contract_confirmation', { verdicts: k.verdicts }),
        f('submit', { files: k.fix }),
        f('submit_contract_review', { findings: k.second }),
        ...(k.secondVerdicts ? [f('submit_contract_confirmation', { verdicts: k.secondVerdicts })] : []),
        f('submit', { files: [{ path: intentOf(slug), content: k.intent }] }),
      ]);
    }
    cache.set('regressions', all);
    return all;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

// The contradicting S-DESIGN-GUIDANCE package submitted three times, then approval of the package Shape left.
async function persistent() {
  if (cache.has('persistent')) return cache.get('persistent');
  const H = require('./go_driver_support.js');
  const f = H.fn;
  const slug = 's-design-guidance', k = CASES[slug];
  const suite = await H.setupSuite(); let c;
  try {
    c = await fixtureProject(H, suite);
    const o = await shapeOnce(H, c, slug, [
      H.inspectThenSubmit('submit', { files: [{ path: intentOf(slug), content: k.intent }, { path: featureOf(slug), content: k.bad.feature }, { path: k.stepsPath, content: k.bad.steps }] }, slug),
      f('submit_contract_review', { findings: k.review }),
      f('submit_contract_confirmation', { verdicts: k.verdicts }),
      f('submit', { files: [{ path: intentOf(slug), content: k.intent }] }),
      f('submit', { files: [{ path: intentOf(slug), content: k.intent }] }),
    ]);
    o.left = fs.readFileSync(path.join(c.repo, k.stepsPath), 'utf8');
    o.card = await H.runKogen(c, ['intent', 'approve', slug]);
    const hash = await H.baselineHash(c, slug);
    o.hashed = await H.runKogen(c, ['intent', 'approve', slug, hash]);
    o.marker = fs.existsSync(H.approvalPath(c.repo, slug));
    fs.writeFileSync(path.join(c.repo, k.stepsPath), k.good.steps);
    o.corrected = await H.runKogen(c, ['intent', 'approve', slug]);
    cache.set('persistent', o);
    return o;
  } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
}

// ------------------------------------------------------------------ controls

// Known-good observations built from the scripted cases and the formats the Intent states, and the feature's own literals.
function controlObservations() {
  const feature = fs.readFileSync(FEATURE, 'utf8');
  const doc = name => {
    const at = feature.indexOf(name);
    assert.ok(at >= 0, `acceptance.feature lacks ${name}`);
    const open = feature.indexOf('"""', at), close = feature.indexOf('"""', open + 3);
    const indent = feature.slice(feature.lastIndexOf('\n', open) + 1, open);
    return feature.slice(open + 4, close).split('\n').map(l => l.startsWith(indent) ? l.slice(indent.length) : l.trim()).join('\n').replace(/\n+$/, '');
  };
  const out = {};
  for (const [slug, k] of Object.entries(CASES)) {
    const confirmed = k.review.map((r, i) => [r, k.verdicts.find(v => v.finding === i + 1)]).filter(([, v]) => v && v.verdict === 'confirmed');
    const evidenced = slug === 'k-step-file-collision' ? k.review.slice(0, 2) : k.review;
    const refusal = `${headline(confirmed.length)}\n${confirmed.map(([r, v]) => itemLine(r, v)).join('\n')}`;
    const confirm = evidenced.map(findingLine).join('\n');
    const kinds = ['shaper', 'review', 'confirmation', 'shaper', 'review', ...(k.secondVerdicts ? ['confirmation'] : []), 'shaper'];
    const obs = 'Readiness observations\nChecked baseline: abc\nHEAD: def\nAcceptance exit: 1\nEvidence: x\nScenario: s (acceptance.feature line 3)\nAssertionError: missing';
    const input = `Slug: ${slug}\n\n# Candidate intent.md\n\n${strip(k.intent)}\n\n# Candidate acceptance.feature\n\n${strip(k.bad.feature)}\n\n# Candidate step file ${k.stepsPath}\n\n${strip(k.bad.steps)}\n\n# Readiness observations\n\n${obs}`;
    out[slug] = {
      refusal, confirm, k, obs: 'AssertionError: missing',
      featureRefusal: doc(`the feedback to "${slug}" submission 1 was exactly:`),
      featureConfirm: doc(`the "${slug}" confirmation request listed exactly these findings:`),
      o: {
        slug, code: 0, out: `Intent: /x\nNext: kogen intent approve ${slug}\n`, kinds,
        tools: kinds.map(x => x === 'shaper' ? ['read_file', 'submit'] : [...READ_ONLY, x === 'review' ? 'submit_contract_review' : 'submit_contract_confirmation']),
        inputs: kinds.map(x => x === 'confirmation' ? `${input}\n\n# Findings to verify\n\n${confirm}` : x === 'review' ? input : 'shaper'),
        instructions: kinds.map(x => x === 'review' ? 'You check one candidate Intent before any Build.\nWhen unsure, report nothing.' : ''),
        feedback: { 1: refusal, 2: 'Inspect ...\nReadiness observations\nChecked baseline: x' },
        reviews: [{ result: 'refused', findings: k.review.length, evidenced: evidenced.length, confirmed: confirmed.length }, { result: 'clean', findings: k.second.length, evidenced: k.second.length, confirmed: 0 }],
        refused: [{ gate: 'contract_review' }], observations: 2,
        files: { [intentOf(slug)]: k.intent, [featureOf(slug)]: k.good.feature, [k.stepsPath]: k.good.steps },
      },
    };
  }
  const d = out['s-design-guidance'];
  const left = d.refusal.split('\n')[1];
  const persistentOk = {
    slug: 's-design-guidance', code: 1, kinds: ['shaper', 'review', 'confirmation', 'shaper', 'shaper'],
    out: `intent/not_ready: the Intent is not ready to build\n  ${left}\n`,
    feedback: { 1: d.refusal, 2: d.refusal }, reviews: [{ result: 'refused', findings: 1, evidenced: 1, confirmed: 1 }],
    refused: [1, 2, 3].map(() => ({ gate: 'contract_review' })), observations: 1,
    card: { code: 1, out: `${APPROVAL('s-design-guidance')}\n  ${left}\n` },
    hashed: { code: 1, out: `${APPROVAL('s-design-guidance')}\n  ${left}\n` },
    marker: false, corrected: { code: 5, out: 'Scenarios: 1 (1 fail now, 0 pass now)\nSHA-256: 0123\n' },
  };
  return { out, persistentOk, left, featureLeft: doc('the persistent "s-design-guidance" shape exited with status 1 and printed these lines in order:'), featureCard: doc('the persistent approval card exited with status 1 and printed these lines in order:'), featureHashed: doc('approving the persistent package by its full hash exited with status 1 and printed these lines in order:') };
}
const ROWS = o => o.reviews.map(e => ({ result: e.result, findings: String(e.findings), evidenced: String(e.evidenced), confirmed: String(e.confirmed) }));
function checkCase(o, x) {
  exited(o, 0); requestKinds(o, x.o.kinds.join(', '));
  checkTools(o); reviewInput(o, x.k, x.obs); reviewInstructions(o, 'When unsure, report nothing.');
  confirmationFindings(o, x.confirm); feedbackExactly(o, 1, x.refusal); feedbackObservations(o, 2);
  publishedCorrection(o, x.k); reviewEvents(o, ROWS(x.o)); refusedEvents(o, 1, 'contract_review');
}
function checkPersistent(o, x) {
  exited(o, 1); requestKinds(o, 'shaper, review, confirmation, shaper, shaper');
  printedInOrder(o.out, `intent/not_ready: the Intent is not ready to build\n${x.left}`, 'kogen intent shape');
  feedbackExactly(o, 1, x.out['s-design-guidance'].refusal); feedbackExactly(o, 2, x.out['s-design-guidance'].refusal);
  reviewEvents(o, [{ result: 'refused', findings: '1', evidenced: '1', confirmed: '1' }]); refusedEvents(o, 3, 'contract_review'); readinessRuns(o, 1);
  commandEnded(o.card, 'the approval card', 1, `${APPROVAL(o.slug)}\n${x.left}`);
  commandEnded(o.hashed, 'approval by the full hash', 1, `${APPROVAL(o.slug)}\n${x.left}`);
  assert.equal(o.marker, false, 'an approval marker was written');
  commandEnded(o.corrected, 'the card of the hand-corrected package', 5, 'SHA-256: ');
}

function control(kind) {
  const x = controlObservations();
  // The feature's literal expectations are exactly the Intent's formats applied to the scripted findings and verdicts.
  for (const [slug, y] of Object.entries(x.out)) {
    assert.equal(y.featureRefusal, y.refusal, `the feature's expected refusal for ${slug} is not the Intent's format of its scripted review`);
    assert.equal(y.featureConfirm, y.confirm, `the feature's expected confirmation findings for ${slug} are not the Intent's format of its evidenced findings`);
  }
  assert.equal(x.featureLeft, `intent/not_ready: the Intent is not ready to build\n${x.left}`, 'the feature\'s persistent not-ready lines are not the Intent\'s format');
  for (const text of [x.featureCard, x.featureHashed]) assert.equal(text, `${APPROVAL('s-design-guidance')}\n${x.left}`, 'the feature\'s approval refusal lines are not the Intent\'s format');
  for (const y of Object.values(x.out)) checkCase(y.o, y);
  checkPersistent(x.persistentOk, x);
  if (kind === 'good') return 'accepted';
  const bad = (check, base, change, y) => { const o = structuredClone(base); change(o); assert.throws(() => check(o, y), `accepted a known-bad ${base.slug} observation: ${change}`); };
  for (const y of Object.values(x.out)) {
    const o = y.o;
    // The old behaviour: no review, the contradicting package acknowledged and published.
    bad(checkCase, o, o => { o.kinds = ['shaper', 'shaper']; o.tools = [['submit'], ['submit']]; o.inputs = ['s', 's']; o.instructions = ['', '']; o.feedback = { 1: o.feedback[2] }; o.reviews = []; o.refused = []; }, y);
    bad(checkCase, o, o => { o.code = 1; }, y);
    bad(checkCase, o, o => { o.kinds.push('shaper'); }, y);
    bad(checkCase, o, o => { o.tools[1].push('write_file'); }, y);
    bad(checkCase, o, o => { o.tools[1] = o.tools[1].filter(t => t !== 'search_text'); }, y);
    bad(checkCase, o, o => { o.tools[2] = [...READ_ONLY, 'submit_contract_review']; }, y);
    bad(checkCase, o, o => { o.inputs[1] = o.inputs[1].replace('# Readiness observations', '# Observations'); }, y);
    bad(checkCase, o, o => { o.inputs[1] = o.inputs[1].replace(`# Candidate step file ${y.k.stepsPath}`, '# Step file'); }, y);
    bad(checkCase, o, o => { o.inputs[1] = o.inputs[1].replace('AssertionError: missing', ''); }, y);
    bad(checkCase, o, o => { o.inputs[1] = `Request\n\n${o.inputs[1]}`; }, y);
    bad(checkCase, o, o => { o.instructions[1] = 'You check one candidate Intent.'; }, y);
    bad(checkCase, o, o => { o.inputs[2] = `${o.inputs[2]}\n3. scenario: extra`; }, y);
    bad(checkCase, o, o => { o.inputs[2] = o.inputs[2].replace('\n\n# Findings to verify\n\n1. ', '\n\n# Findings to verify\n\n'); }, y);
    bad(checkCase, o, o => { o.feedback[1] = `${o.feedback[1]}\n`; }, y);
    bad(checkCase, o, o => { o.feedback[1] = o.feedback[1].replace(' | confirmed: ', ' | '); }, y);
    bad(checkCase, o, o => { o.feedback[1] = o.feedback[1].replace('Contract check: ', 'Contract check:  '); }, y);
    bad(checkCase, o, o => { o.feedback[2] = o.feedback[1]; }, y);
    bad(checkCase, o, o => { o.files[featureOf(o.slug)] = y.k.bad.feature; o.files[y.k.stepsPath] = y.k.bad.steps; }, y);
    bad(checkCase, o, o => { o.out = o.out.replace('Next: kogen intent approve', 'Next: kogen intent shape'); }, y);
    bad(checkCase, o, o => { o.reviews[0].confirmed = 0; }, y);
    bad(checkCase, o, o => { o.reviews[0].evidenced = o.reviews[0].findings + 1; }, y);
    bad(checkCase, o, o => { o.reviews.push({ result: 'clean', findings: 0, evidenced: 0, confirmed: 0 }); }, y);
    bad(checkCase, o, o => { o.refused.push({ gate: 'contract_review' }); }, y);
    bad(checkCase, o, o => { o.refused[0].gate = 'readiness'; }, y);
  }
  const p = x.persistentOk;
  bad(checkPersistent, p, o => { o.code = 0; o.kinds = ['shaper', 'shaper']; o.out = 'Next: kogen intent approve s-design-guidance\n'; }, x);
  bad(checkPersistent, p, o => { o.kinds = ['shaper', 'review', 'confirmation', 'shaper', 'review', 'confirmation', 'shaper']; }, x);
  bad(checkPersistent, p, o => { o.feedback[2] = 'accepted: unchanged checked observations acknowledged'; }, x);
  bad(checkPersistent, p, o => { o.out = 'intent/not_ready: the Intent is not ready to build\n'; }, x);
  bad(checkPersistent, p, o => { o.out = 'shape/invalid_output: the shaper\'s output was not a valid Intent after 3 attempts\n'; }, x);
  bad(checkPersistent, p, o => { o.refused = o.refused.slice(0, 2); }, x);
  bad(checkPersistent, p, o => { o.reviews.push(o.reviews[0]); }, x);
  bad(checkPersistent, p, o => { o.observations = 2; }, x);
  bad(checkPersistent, p, o => { o.card = { code: 5, out: 'SHA-256: 0123\n' }; }, x);
  bad(checkPersistent, p, o => { o.card.out = `${APPROVAL(o.slug)}\n`; }, x);
  bad(checkPersistent, p, o => { o.hashed = { code: 0, out: 'approved s-design-guidance 0123\n' }; }, x);
  bad(checkPersistent, p, o => { o.marker = true; }, x);
  bad(checkPersistent, p, o => { o.corrected = { code: 1, out: `${APPROVAL(o.slug)}\n` }; }, x);
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
  const { When, Then } = require('@cucumber/cucumber');
  const STEP = { timeout: 1200000 };
  const caseOf = (w, slug) => { assert.ok(w.contractShapes && w.contractShapes[slug], `the contract shape of ${slug} did not run`); return w.contractShapes[slug]; };
  const persistentOf = w => { assert.ok(w.contractPersistent, 'the persistent contract shape did not run'); return w.contractPersistent; };
  const known = slug => { assert.ok(CASES[slug], `unknown case ${slug}`); return CASES[slug]; };

  When('the contract shaper shapes {string} with its contradicting package and then its correction', STEP, async function (slug) {
    known(slug);
    this.contractShapes = await regressions();
  });
  When('the contract shaper submits the contradicting {string} package three times and its package is put to approval', STEP, async function (slug) {
    assert.equal(slug, 's-design-guidance', `the persistent case is s-design-guidance, not ${slug}`);
    this.contractPersistent = await persistent();
  });
  Then('the {string} shape exited with status {int} after the requests {string}', function (slug, status, kinds) { const o = caseOf(this, slug); exited(o, status); requestKinds(o, kinds); });
  Then('every {string} contract review and confirmation request offered exactly read_file, list_files, search_text and its own submit tool', function (slug) { checkTools(caseOf(this, slug)); });
  Then('the first {string} contract review request carried the candidate files and these readiness observations:', function (slug, text) { reviewInput(caseOf(this, slug), known(slug), text); });
  Then('the first {string} contract review request instructions contain:', function (slug, text) { reviewInstructions(caseOf(this, slug), text); });
  Then('the {string} confirmation request listed exactly these findings:', function (slug, text) { confirmationFindings(caseOf(this, slug), text); });
  Then('the feedback to {string} submission 1 was exactly:', function (slug, text) { feedbackExactly(caseOf(this, slug), 1, text); });
  Then('the feedback to {string} submission 2 was readiness observations, not a refusal', function (slug) { feedbackObservations(caseOf(this, slug), 2); });
  Then('the published {string} package is its correction', function (slug) { publishedCorrection(caseOf(this, slug), known(slug)); });
  Then('the {string} contract_review events were:', function (slug, table) { reviewEvents(caseOf(this, slug), table.hashes()); });
  Then('the {string} shaping events record {int} submission_refused event(s) with gate {string}', function (slug, n, gate) { refusedEvents(caseOf(this, slug), n, gate); });

  Then('the persistent {string} shape exited with status {int} and printed these lines in order:', function (slug, status, text) { const o = persistentOf(this); exited(o, status); printedInOrder(o.out, text, `kogen intent shape ${slug}`); });
  Then('the persistent shape made the requests {string}', function (kinds) { requestKinds(persistentOf(this), kinds); });
  Then('the feedback to persistent submissions 1 and 2 was exactly:', function (text) { const o = persistentOf(this); feedbackExactly(o, 1, text); feedbackExactly(o, 2, text); });
  Then('the persistent contract_review events were:', function (table) { reviewEvents(persistentOf(this), table.hashes()); });
  Then('the persistent shaping events record {int} submission_refused events with gate {string}', function (n, gate) { refusedEvents(persistentOf(this), n, gate); });
  Then('readiness ran {int} time(s) in the persistent shape', function (n) { readinessRuns(persistentOf(this), n); });
  Then('the persistent approval card exited with status {int} and printed these lines in order:', function (status, text) { commandEnded(persistentOf(this).card, 'the approval card', status, text); });
  Then('approving the persistent package by its full hash exited with status {int} and printed these lines in order:', function (status, text) { commandEnded(persistentOf(this).hashed, 'approval by the full hash', status, text); });
  Then('no approval marker was written for the persistent package', function () { assert.equal(persistentOf(this).marker, false, 'an approval marker was written'); });
  Then('the card of the persistent package corrected by hand exited with status {int} and printed {string}', function (status, text) { commandEnded(persistentOf(this).corrected, 'the card of the hand-corrected package', status, text); });
}
