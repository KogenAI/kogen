// Offline well-formedness check for the Kogen specification.
// Usage: node tools/check.mjs [--dump-steps] [--trace]
// Needs @cucumber/gherkin and @cucumber/messages (see README "Checking the spec").
// Checks: every feature parses; every scenario (also under Rule:) carries a
// requirement tag that exists in prose and compiles to at least one test case;
// every requirement has a scenario; every requirement id used in prose, README
// and STEPS.md is defined; every @model:x names a Quint file; every Quint name
// cited in prose is a conjunct of that model's `val Safety`; every step matches
// exactly one pattern in features/STEPS.md. --trace prints requirement -> scenarios -> Quint.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const specDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const require = createRequire(path.join(process.env.KOGEN_SPEC_NODE_MODULES || path.join(specDir, 'node_modules'), 'x.js'));
const gherkin = require('@cucumber/gherkin');
const messages = require('@cucumber/messages');

const errors = [];
const fail = (msg) => errors.push(msg);

// ---- prose requirements ----
const proseDir = path.join(specDir, 'prose');
const reqs = new Map(); // id -> {file, title}
const proseTexts = new Map(); // file -> text
for (const f of fs.readdirSync(proseDir).filter((n) => n.endsWith('.md')).sort()) {
  const text = fs.readFileSync(path.join(proseDir, f), 'utf8');
  proseTexts.set(f, text);
  for (const m of text.matchAll(/\*\*([A-Z]+-\d+a?) — ([^*]+?)\*\*/g)) {
    if (reqs.has(m[1])) fail(`duplicate requirement ${m[1]} in ${f}`);
    reqs.set(m[1], { file: f, title: m[2].replace(/\.$/, '') });
  }
}
// Every requirement id used in prose, README and STEPS.md must be defined.
const idRe = /\b(?:SET|SHP|AUT|LOOP|VER|REV|GIT|GPT|CLI|INS|REL)-\d+a?\b/g;
const idSources = [...proseTexts].map(([f, t]) => [`prose/${f}`, t]);
for (const f of ['README.md', path.join('features', 'STEPS.md')]) idSources.push([f, fs.readFileSync(path.join(specDir, f), 'utf8')]);
for (const [f, text] of idSources) {
  for (const id of new Set(text.match(idRe) || [])) if (!reqs.has(id)) fail(`${f}: uses requirement id ${id}, which is not defined in prose`);
}

// ---- quint definitions ----
const quintDir = path.join(specDir, 'quint');
const quintFiles = fs.readdirSync(quintDir).filter((n) => n.endsWith('.qnt')).sort();
const quintModels = quintFiles.map((n) => n.replace(/\.qnt$/, ''));
const safetyOf = new Map(); // model -> Set of conjunct names of `val Safety`
for (const f of quintFiles) {
  const text = fs.readFileSync(path.join(quintDir, f), 'utf8');
  const m = text.match(/\bval\s+Safety\s*=([\s\S]*?)(?=\n\s*\n|\n\s*\/\/|\n\s*(?:val|def|action|run)\b)/);
  if (!m) { fail(`quint/${f}: has no val Safety`); continue; }
  safetyOf.set(f.replace(/\.qnt$/, ''), new Set(m[1].split(/\band\b/).map((x) => x.trim()).filter(Boolean)));
}
// A clause ends before the chapter's footer or the next heading.
const clauseOf = (id) => {
  const text = proseTexts.get(reqs.get(id).file);
  const clause = text.split(/\n(?=\*\*[A-Z]+-\d+a? — )/).find((c) => c.startsWith(`**${id} — `)) || '';
  return clause.split(/\n(?:#{1,6} |Scenarios: )/)[0];
};
// Quint names cited in a clause, per spec model file (bare or with the quint/ prefix).
const modelRe = new RegExp('(?:quint/)?\\b(' + quintModels.join('|') + ')\\.qnt`?\\s*((?:`[A-Z]\\w+`(?:,\\s*)?)*)', 'g');
const citesOf = (id) => {
  const out = new Map(); // model -> [names]
  for (const m of clauseOf(id).matchAll(modelRe)) {
    if (!out.has(m[1])) out.set(m[1], []);
    for (const n of m[2].matchAll(/`(\w+)`/g)) if (!out.get(m[1]).includes(n[1])) out.get(m[1]).push(n[1]);
  }
  return out;
};
for (const id of reqs.keys()) {
  for (const [model, names] of citesOf(id)) {
    for (const n of names) if (!(safetyOf.get(model) || new Set()).has(n)) fail(`${id}: cites ${model}.qnt ${n}, which is not a conjunct of val Safety in quint/${model}.qnt`);
  }
}

// ---- step vocabulary ----
const stepsMd = fs.readFileSync(path.join(specDir, 'features', 'STEPS.md'), 'utf8');
const block = stepsMd.match(/```steps\n([\s\S]*?)```/);
if (!block) fail('features/STEPS.md has no ```steps block');
const patterns = (block ? block[1] : '').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'))
  .map((l) => ({ src: l, re: new RegExp(l) }));
const used = new Map(patterns.map((p) => [p.src, 0]));

// ---- features ----
const featDir = path.join(specDir, 'features');
const scenariosByReq = new Map();
const modelTagsByReq = new Map();
const stepTexts = new Map();
let scenarioCount = 0, pickleCount = 0;
const newId = messages.IdGenerator.uuid();
for (const f of fs.readdirSync(featDir).filter((n) => n.endsWith('.feature')).sort()) {
  const data = fs.readFileSync(path.join(featDir, f), 'utf8');
  let doc;
  try {
    const parser = new gherkin.Parser(new gherkin.AstBuilder(newId), new gherkin.GherkinClassicTokenMatcher());
    doc = parser.parse(data);
  } catch (e) { fail(`${f}: does not parse: ${e.message}`); continue; }
  const featureTags = doc.feature.tags.map((t) => t.name);
  const pickles = gherkin.compile(doc, f, newId);
  pickleCount += pickles.length;
  const scenarios = [];
  for (const child of doc.feature.children) {
    if (child.scenario) scenarios.push({ sc: child.scenario, inherited: [] });
    if (child.rule) {
      const ruleTags = child.rule.tags.map((t) => t.name);
      for (const rc of child.rule.children) if (rc.scenario) scenarios.push({ sc: rc.scenario, inherited: ruleTags });
    }
  }
  for (const { sc, inherited } of scenarios) {
    scenarioCount++;
    const tags = [...featureTags, ...inherited, ...sc.tags.map((t) => t.name)];
    const reqTags = tags.filter((t) => /^@[A-Z]+-\d+a?$/.test(t)).map((t) => t.slice(1));
    if (reqTags.length === 0) fail(`${f}:${sc.location.line}: scenario "${sc.name}" has no requirement tag`);
    const modelTags = tags.filter((t) => t.startsWith('@model:'));
    for (const r of reqTags) {
      if (!reqs.has(r)) fail(`${f}:${sc.location.line}: tag @${r} is not a requirement in prose`);
      if (!scenariosByReq.has(r)) scenariosByReq.set(r, []);
      scenariosByReq.get(r).push(`${f}:${sc.location.line}`);
      if (!modelTagsByReq.has(r)) modelTagsByReq.set(r, new Set());
      for (const t of modelTags) modelTagsByReq.get(r).add(t.slice(7));
    }
    for (const t of modelTags) {
      if (!quintFiles.includes(`${t.slice(7)}.qnt`)) fail(`${f}:${sc.location.line}: ${t} names no quint file`);
    }
    if (pickles.filter((p) => p.astNodeIds[0] === sc.id).length === 0) fail(`${f}:${sc.location.line}: scenario "${sc.name}" compiles to no test case`);
    if (sc.steps.length === 0) fail(`${f}:${sc.location.line}: scenario has no steps`);
    if (!sc.steps.some((s) => s.keyword.trim() === 'Then')) fail(`${f}:${sc.location.line}: scenario has no Then step`);
  }
  for (const p of pickles) {
    for (const s of p.steps) {
      // Like a Cucumber runner: exactly one pattern may match (else undefined or ambiguous).
      const hits = patterns.filter((pt) => pt.re.test(s.text));
      if (hits.length === 0) fail(`${f}: step has no vocabulary pattern: ${s.text}`);
      else if (hits.length > 1) fail(`${f}: step matches ${hits.length} patterns (ambiguous): ${s.text} -> ${hits.map((h) => h.src).join(' | ')}`);
      else used.set(hits[0].src, used.get(hits[0].src) + 1);
      stepTexts.set(s.text, (stepTexts.get(s.text) || 0) + 1);
    }
  }
}
for (const [id] of reqs) if (!scenariosByReq.has(id)) fail(`requirement ${id} has no scenario`);
for (const [src, n] of used) if (n === 0) fail(`unused step pattern: ${src}`);

if (process.argv.includes('--dump-steps')) {
  for (const t of [...stepTexts.keys()].sort()) console.log(t);
}

// ---- Trace: requirement -> chapter -> scenarios -> Quint, printed with --trace ----
const quintColumn = (id) => {
  const byModel = citesOf(id);
  for (const model of modelTagsByReq.get(id) || []) if (!byModel.has(model)) byModel.set(model, []);
  return [...byModel].sort((a, b) => a[0].localeCompare(b[0])).map(([model, names]) => `${model}.qnt${names.length ? ' ' + names.join(', ') : ''}`).join('; ');
};
if (process.argv.includes('--trace')) {
  console.log('| Requirement | Chapter | Scenarios | Quint |\n| --- | --- | --- | --- |');
  for (const [id, r] of [...reqs].sort((a, b) => a[0].localeCompare(b[0], 'en', { numeric: true }))) {
    console.log(`| ${id} ${r.title} | ${r.file} | ${(scenariosByReq.get(id) || []).join(', ')} | ${quintColumn(id)} |`);
  }
}

console.log(`requirements ${reqs.size}, scenarios ${scenarioCount}, pickles ${pickleCount}, step patterns ${patterns.length}, distinct steps ${stepTexts.size}`);
if (errors.length) {
  console.log(`${errors.length} problem(s):`);
  for (const e of errors) console.log('  ' + e);
  process.exit(1);
}
console.log('spec check: ok');
