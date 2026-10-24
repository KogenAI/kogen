const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const H = require('./go_driver_support.js');
const { fn: f, sha: digest } = H;
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
// These predicates judge real captured replay, not compiler stdout or a model's pass claim.
function replayCustody(d) {
  if (!d.windows.length || !d.expected.length || !d.files.length) return false;
  for (const input of d.windows) {
    const pending = new Set();
    for (const item of input) {
      if (item.type === 'function_call') { if (pending.has(item.call_id)) return false; pending.add(item.call_id); }
      if (item.type === 'function_call_output') { if (!pending.delete(item.call_id)) return false; }
    }
    if (pending.size) return false;
  }
  return d.expected.every(group => d.windows.some(w => {
    for (let i = 0; i <= w.length - group.length; i++) if (same(w.slice(i, i + group.length), group)) return true;
    return false;
  })) && d.files.every(f => f.file_mode === 384 && f.dir_mode === 448);
}

// What a Build replays of a received item (the supported fields only, in received order), written independently here.
const take = (item, keys) => Object.fromEntries(keys.filter(k => k in item).map(k => [k, item[k]]));
function replayItem(item) {
  if (item.type === 'function_call') return take(item, ['type', 'id', 'call_id', 'name', 'arguments', 'status']);
  if (item.type === 'reasoning') return take(item, ['type', 'id', 'encrypted_content', 'summary', 'status']);
  if (item.type === 'message' && Array.isArray(item.content)) {
    const content = item.content.flatMap(b => b.type === 'output_text' && typeof b.text === 'string' ? [{ type: 'output_text', text: b.text }] : b.type === 'refusal' && typeof b.refusal === 'string' ? [{ type: 'refusal', refusal: b.refusal }] : []);
    return content.length ? { ...take(item, ['type', 'id', 'role', 'phase', 'status']), content } : null;
  }
  return null;
}
const outputItem = (call, text) => ({ type: 'function_call_output', call_id: call.call_id, output: text });

// The control: the production tool, replay and output functions of package kogen/agent, called from a tiny Go program.
const controlSource = String.raw`package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"kogen/agent"
)

func encode(v any) string {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		panic(err)
	}
	return string(bytes.TrimRight(b.Bytes(), "\n"))
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func main() {
	tmp, err := os.MkdirTemp("", "continuity-control-")
	must(err)
	defer os.RemoveAll(tmp)
	must(os.Chmod(tmp, 0o700))
	literal := "  Δ🙂\r\n/path with spaces/診断.txt\nHTML title — personal suffix  "
	call := map[string]any{"type": "function_call", "id": "native-control-call", "call_id": "control-1", "name": "write_file", "arguments": encode(map[string]any{"path": "native.txt", "content": literal})}
	reasoning := map[string]any{"type": "reasoning", "id": "native-control-reasoning", "encrypted_content": "opaque+/==\nDo not decode Δ", "summary": []any{}}
	message := map[string]any{"type": "message", "id": "native-control-message", "role": "assistant", "phase": "commentary", "content": []any{map[string]any{"type": "output_text", "text": "UNFINISHED: exact native progress"}}}
	tools := &agent.Tools{Root: tmp, Enabled: []string{"write_file"}}
	out, err := tools.Run("write_file", map[string]any{"path": "native.txt", "content": literal})
	must(err)
	written, err := os.ReadFile(filepath.Join(tmp, "native.txt"))
	must(err)
	if out.Text != "ok" || string(written) != literal {
		must(fmt.Errorf("native fixture did not write exact bytes"))
	}
	group := []any{agent.ReplayItem(reasoning), agent.ReplayItem(message), agent.ReplayItem(call), agent.OutputItem("control-1", out.Text)}
	file := filepath.Join(tmp, "window.json")
	must(os.WriteFile(file, []byte(encode(map[string]any{"input": group})), 0o600))
	must(os.Chmod(file, 0o600))
	raw, err := os.ReadFile(file)
	must(err)
	var doc map[string]any
	must(json.Unmarshal(raw, &doc))
	fst, err := os.Stat(file)
	must(err)
	dst, err := os.Stat(tmp)
	must(err)
	fmt.Println(encode(map[string]any{"windows": []any{doc["input"]}, "expected": []any{group}, "files": []any{map[string]any{"file_mode": int(fst.Mode().Perm()), "dir_mode": int(dst.Mode().Perm())}}}))
}
`;

// The measurement control: the production request measure of package kogen/agent, called on bodies given as JSON.
const measureSource = String.raw`package main

import (
	"encoding/json"
	"fmt"
	"os"

	"kogen/agent"
)

func main() {
	var bodies []map[string]any
	if err := json.NewDecoder(os.Stdin).Decode(&bodies); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	var rows []map[string]any
	for _, body := range bodies {
		m, err := agent.Measure(body)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		rows = append(rows, map[string]any{"rendered_bytes": m.RenderedBytes, "input_budget_bytes": m.InputBudgetBytes, "output_reserve_tokens": m.OutputReserveTokens, "fits": m.Fits})
	}
	b, _ := json.Marshal(rows)
	fmt.Println(string(b))
}
`;

if (require.main === module && process.argv[2] === '--control') {
  (async () => {
    try {
      const control = await H.goDriver('continuity-control', controlSource);
      const r = await control();
      if (r.code !== 0) throw new Error(r.out);
      const good = JSON.parse(r.out);
      assert.equal(replayCustody(good), true, 'actual native fixture must be known good');
      if (process.argv[3] === 'good') { process.stdout.write('accepted\n'); }
      else if (process.argv[3] === 'bad') {
        const mutations = [
          d => d.windows[0].pop(),
          d => d.windows[0][0].encrypted_content += 'changed',
          d => d.windows[0][1].phase = 'final',
          d => { const a = JSON.parse(d.windows[0][2].arguments); a.content = a.content.trim(); d.windows[0][2].arguments = JSON.stringify(a); },
          d => d.windows[0].reverse(),
          d => d.files[0].file_mode = 420,
          d => d.files[0].dir_mode = 493,
        ];
        for (const mutate of mutations) { const bad = structuredClone(good); mutate(bad); assert.equal(replayCustody(bad), false, 'counterexample accepted'); }
        process.stdout.write('rejected\n'); process.exitCode = 1;
      } else throw new Error('unknown control');
    } catch (e) { process.stderr.write(String(e) + '\n'); process.exitCode = 2; }
  })();
} else {
  const { isDeepStrictEqual } = require('node:util');
  const { When, Then } = require('@cucumber/cucumber');
  const count = c => c.server.providerRequests().length;
  const script = (c, actions) => c.server.setScript(actions);
  const git = (c, a) => H.git(c, a);
  const put = (c, p, b) => { const file = path.join(c.repo, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, b); };
  const read = p => { try { return fs.readFileSync(p, 'latin1'); } catch (e) { return `error:${e.code}`; } };
  const custody = async (c, slug) => ({ head: await git(c, ['rev-parse', 'HEAD']), index: read(path.join(c.repo, '.git/index')), approval: read(H.approvalPath(c.repo, slug)), app: read(path.join(c.repo, 'app.txt')) });
  const approve = async (c, slug) => { const r = await H.approve(c, slug); return [r.card, r.hash, r.out]; };
  const cps = c => H.wildcard(path.join(c.repo, '.kogen/local/runs/*/checkpoint.json'));
  const archives = c => H.wildcard(path.join(c.repo, '.kogen/local/runs/*/working-context/*/*.json'));
  const modeOf = p => fs.statSync(p).mode & 0o777;
  const isPrivate = paths => paths.length > 0 && paths.every(p => modeOf(p) === 0o600 && modeOf(path.dirname(p)) === 0o700);
  const textOf = i => typeof i.content === 'string' ? i.content : Array.isArray(i.content) ? i.content.map(b => b.text || '').join('') : '';
  const handoffs = requests => requests.flatMap(r => (r.json.input || []).filter(i => textOf(i).startsWith('Local working-window reset\n')).map(i => JSON.parse(textOf(i).slice('Local working-window reset\n'.length))));
  const inputText = H.FakeProvider.inputText;

  async function growth(c, spec, mode) {
    if (mode === 'mandatory') {
      put(c, 'README.md', 'M'.repeat(spec.mandatory_bytes));
      await git(c, ['add', 'README.md']); await git(c, ['commit', '-qm', 'Large mandatory instructions']);
      await approve(c, 'fixture');
      const before = await custody(c, 'fixture'); const n = count(c);
      const { out: o, code: k } = await H.runKogen(c, ['intent', 'build', 'fixture']);
      return { refused: k !== 0, no_model_on_refusal: count(c) === n, custody_unchanged: same(await custody(c, 'fixture'), before), actionable: o.includes('checkpoint') && o.includes('approval'), budget_diagnostic: o.includes('candidate/context_budget_exceeded') && o.includes(String(spec.budget)) && o.includes(String(spec.reserve)) };
    }
    const literal = spec.literal;
    const md = path.join(c.repo, H.intentMd('fixture'));
    fs.writeFileSync(md, `${fs.readFileSync(md, 'utf8')}\nApproved exact literal:\n${literal}\n`);
    await approve(c, 'fixture');
    const before = await custody(c, 'fixture');
    const external = path.join(c.root, 'archived-native-production.txt');
    fs.writeFileSync(external, 'native preserved production\n');
    const context = path.join(c.root, 'reuse-context.txt');
    const reuse = `${spec.reuse}\nAbsolute preserved native production: ${external}\nSHA-256: ${digest(fs.readFileSync(external))}\nOld check result: green for OLD candidate only. Do not import protected acceptance bytes.\n`;
    fs.writeFileSync(context, reuse);
    const shell = `cat '${external}' > app.txt; printf 'once\\n' >> .kogen/local/continuity-effects`;
    const groups = [];
    for (const owner of ['build', 'review']) for (let i = 1; i <= spec.turns; i++) {
      const id = `${owner}-${i}`;
      const payload = `${literal}\n${id}\n${'x'.repeat(spec.payload_bytes)}`;
      const call = { type: 'function_call', id: `item-${id}`, call_id: `call-${id}`, name: 'write_file', arguments: JSON.stringify({ path: 'app.txt', content: payload }) };
      const msg = { type: 'message', id: `message-${id}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: `${owner} ${spec.unfinished}\n${spec.finding}` }] };
      const reasoning = { type: 'reasoning', id: `reasoning-${id}`, encrypted_content: spec.opaque + id, summary: [] };
      groups.push({ owner, items: [reasoning, msg, call], expected: [reasoning, msg, call].map(replayItem).concat([outputItem(call, 'ok')]) });
    }
    const build = groups.filter(g => g.owner === 'build').map(g => ({ items: g.items }));
    const review = groups.filter(g => g.owner === 'review').map(g => ({ items: g.items }));
    script(c, [f('shell', { command: shell }), ...build, f('finish', { summary: 'current candidate ready' }), ...review]);
    const n = count(c);
    const { out, code: k } = await H.runKogen(c, ['intent', 'build', 'fixture', '--context', context]);
    const requests = c.server.providerRequests().slice(n);
    const ap = archives(c);
    const windows = ap.map(p => JSON.parse(fs.readFileSync(p, 'utf8')).input);
    const wire = requests.map(r => r.json.input);
    const replay = { windows: windows.concat(wire), expected: groups.map(g => g.expected), files: ap.map(p => ({ file_mode: modeOf(p), dir_mode: modeOf(path.dirname(p)) })) };
    const h = handoffs(requests);
    const owners = h.map(x => x.owner);
    const resets = { reset_build: owners.includes('build'), reset_review: owners.includes('review') };
    const checkpointFiles = cps(c);
    if (checkpointFiles.length !== 1) return { ...resets, replay, output: out, code: k };
    const [cp] = checkpointFiles;
    const id = path.basename(path.dirname(cp)); const result = path.join(path.dirname(cp), 'result.json'); const originalResult = read(result);
    const saved = requests[requests.length - 1];
    const old = await custody(c, 'fixture');
    fs.writeFileSync(context, 'POISON replacement\n'); fs.rmSync(external);
    if (mode === 'archive-drift' && ap.length) fs.writeFileSync(ap[0], '{"input": []}\n');
    if (mode === 'grow-legacy') {
      // A checkpoint of the older format: version 2, without the working context or the source provenance.
      const doc = JSON.parse(fs.readFileSync(cp, 'utf8'));
      if (doc.state && typeof doc.state === 'object') { delete doc.state.working_context; delete doc.state.source_provenance; }
      doc.version = 2;
      fs.writeFileSync(cp, JSON.stringify(doc));
    }
    // Since 7e15bf2 an approval needs every pinned review-source part read first (main's own release refuses the
    // bare approval the same way), so the resumed reviewer reads them, then approves.
    const srcs = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/review-source/*/*.json'));
    script(c, [...srcs.map(p => f('read_file', { path: p })), f('submit_review', { verdict: 'approve', findings: [] })]);
    const next = count(c);
    const { out: resume, code: rk } = await H.runKogen(c, ['intent', 'resume', id]);
    const resumed = c.server.providerRequests().slice(next);
    const rejection = { refused: rk !== 0, no_model_on_refusal: resumed.length === 0, custody_unchanged: same(await custody(c, 'fixture'), old), actionable: /history|archive|checkpoint|unsupported|custody/i.test(resume) };
    const sameOwner = resumed.length > 0 && same(resumed[0].json.input, saved.json.input) && c.server.reviewRequests().some(r => r === resumed[0]);
    const committed = rk === 0 && (await git(c, ['rev-list', '--count', `${before.head}..HEAD`])) === '1';
    const landed = H.listFiles(path.join(c.repo, '.kogen/local/runs')).filter(p => p.endsWith('/result.json')).map(p => JSON.parse(fs.readFileSync(p, 'utf8'))).filter(r => r.outcome === 'landed');
    const fresh = rk === 0 && resume.includes('landed') && landed.some(r => r.passes >= 2 && r.reviews === 1);
    const legacyRefusal = mode === 'grow-legacy' && rejection.refused && rejection.no_model_on_refusal && rejection.custody_unchanged && rejection.actionable;
    const common = {
      ...resets, replay, bounded: requests.length > 0 && requests.every(r => Buffer.byteLength(r.body) <= spec.budget),
      authority_exact: requests.every(r => inputText(r).includes(literal) && inputText(r).includes('# Testing rules')),
      progress_exact: h.length > 0 && h.every(x => { const t = JSON.stringify(x); return t.includes(spec.unfinished) && t.includes(spec.finding) && x.candidate_tree != null && x.approval_sha256 != null && ['not_run', 'stale', 'failed'].includes(x.checks.status); }),
      review_independent: c.server.reviewRequests().length > 0 && c.server.reviewRequests().every(r => !JSON.stringify(r.json.input).includes('message-build-')),
      private: isPrivate(ap), no_commit_before_resume: k !== 0 && old.head === before.head,
      completed_effect_once: fs.readFileSync(path.join(c.repo, '.kogen/local/continuity-effects'), 'utf8') === 'once\n',
      old_result_unchanged: read(result) === originalResult, original_input_disposable: !fs.existsSync(external) && fs.readFileSync(context, 'utf8') === 'POISON replacement\n',
      reuse_diagnostic_only: requests[0].body.includes(external) && requests[0].body.includes(digest('native preserved production\n')) && !(await git(c, ['ls-tree', '-r', '--name-only', 'HEAD'])).includes('diagnostic-context'),
      same_saved_owner: sameOwner, one_commit: committed, fresh_checks_review: fresh, legacy_refusal: legacyRefusal,
      resume_outcome_safe: (sameOwner && committed && fresh) || legacyRefusal,
    };
    return mode === 'archive-drift' ? { ...common, ...rejection } : common;
  }

  async function provenance(c, spec, mode) {
    // The shared factory leaves its default Intent uncommitted; captured owns a different step.
    // Commit that unrelated fixture before Shape/approval so their HEAD binding stays current.
    await git(c, ['add', '.kogen/intents/fixture', 'features/steps/integration_steps.js']);
    await git(c, ['commit', '-qm', 'Commit unrelated provenance fixture baseline']);
    assert.equal(await git(c, ['status', '--porcelain']), '');
    const slug = 'captured';
    const input = path.join(c.root, 'original request.txt');
    const request = `${spec.request}\nSelected settled context:\n${spec.selected_context}\nWrong-example counterexample: ${spec.wrong_example}\n`;
    fs.writeFileSync(input, request);
    const question = { question: spec.question, options: [{ label: 'Keep exactly — Almir Δ🙂', recommended: true }, { label: 'Obsolete suffix' }] };
    const dir = H.intentDir(slug), step = 'features/steps/captured.js';
    const feature = 'Feature: Source fixture\n  Scenario: Approved scope stays bounded\n    Then the approved fixture stays bounded\n';
    const body = "const {Then}=require('@cucumber/cucumber');const fs=require('node:fs');const assert=require('node:assert/strict');Then('the approved fixture stays bounded',()=>assert.equal(fs.readFileSync('app.txt','utf8'),'baseline\\n'));\n";
    const md = `# Preserve bounded source scope\n\nSlug: ${slug}\nModel: not applicable — provenance fixture\nAcceptance:\n- ${dir}/acceptance.feature\n- ${step}\n\nKeep app.txt baseline. The private original cannot add a title suffix to this approved scope.\n\n## Decisions\n- Preserve approved scope. (source: request)\n\n## Source comparison\n- omitted: ${spec.omission}; source answer 1; contract has no title rule.\n- addressed: private source retrieval and no original-request override.\n\n## Tests\n- approved scope: actual file (scenario)\n\n## Feasibility\n- none\n`;
    const pack = [{ path: H.intentMd(slug), content: md }, { path: H.featurePath(slug), content: feature }, { path: step, content: body }];
    script(c, [f('submit', { questions: [question] })]);
    const q = await H.runKogen(c, ['intent', 'shape', slug, input]); assert.equal(q.code, 5, q.out);
    const answers = path.join(c.root, 'answers.txt'); fs.writeFileSync(answers, spec.answer);
    // Shape publishes files only after a completed inspection call in the same conversation (shaping-technical-discovery).
    script(c, [H.inspectThenSubmit('files', { files: pack }, 'continuity')]);
    const shape = await H.runKogen(c, ['intent', 'shape', slug, answers]); assert.equal(shape.code, 0, shape.out);
    const source = path.join(c.repo, `.kogen/local/provenance/${slug}/current.json`);
    if (!fs.existsSync(source)) return { successful_source: false, output: shape.out };
    const bytes = fs.readFileSync(source); const doc = JSON.parse(bytes.toString('utf8'));
    const [card, hash] = await approve(c, slug);
    const approval = read(H.approvalPath(c.repo, slug));
    const basic = {
      successful_source: true, exact_request: doc.request.text === request,
      exact_answer: (doc.rounds || []).some(r => r.input === spec.answer && same(r.questions, [question]) && JSON.stringify(r.answers).includes('Almir')),
      source_identity: doc.request.source_path === input && doc.request.sha256 === digest(request) && doc.contract_sha256 === hash,
      private: isPrivate([source]), card_comparison: card.includes(spec.omission) && card.includes('provenance') && card.includes(digest(bytes)),
      card_no_raw_request: !card.includes(request), approval_bound: approval.includes(digest(bytes)),
      source_untracked: !(await git(c, ['ls-files'])).includes('.kogen/local/provenance'),
    };
    if (['refine-source', 'refuse-refine'].includes(mode)) {
      const correction = path.join(c.root, 'correction.txt'); fs.writeFileSync(correction, spec.correction);
      if (mode === 'refuse-refine') script(c, [f('submit_refinement', { constraint: 'preserve original; cannot safely correct' })]);
      else script(c, [f('submit_refinement', { files: [{ path: H.intentMd(slug), content: `${md.replaceAll(`- omitted: ${spec.omission}`, `- addressed: ${spec.correction}`)}\nApproved title suffix: ${spec.literal}\n` }] })]);
      const { out: o, code: k } = await H.runKogen(c, ['intent', 'refine', slug, hash, correction]);
      const now = fs.readFileSync(source); const updated = JSON.parse(now.toString('utf8'));
      const prior = H.listFiles(path.dirname(source)).some(p => p !== source && fs.readFileSync(p).equals(bytes));
      if (mode === 'refuse-refine') return { ...basic, refine_safe: k !== 0, prior_source_preserved: now.equals(bytes), correction_exact: now.equals(bytes), approval_safe: read(H.approvalPath(c.repo, slug)) === approval };
      return { ...basic, refine_safe: k === 0, prior_source_preserved: prior, correction_exact: (updated.corrections || []).some(x => (x.text === spec.correction || (x.request && x.request.text === spec.correction)) && JSON.stringify(x).includes(hash)), approval_safe: !fs.existsSync(H.approvalPath(c.repo, slug)), output: o };
    }
    if (mode === 'source-drift') {
      fs.writeFileSync(source, Buffer.concat([bytes, Buffer.from(' ')]));
      const before = await custody(c, slug); const n = count(c);
      const { out: o, code: k } = await H.runKogen(c, ['intent', 'build', slug]);
      return { ...basic, refused: k !== 0, no_model_on_refusal: count(c) === n, custody_unchanged: same(await custody(c, slug), before), actionable: /source|provenance/i.test(o) };
    }
    fs.writeFileSync(input, 'POISON replacement'); fs.rmSync(answers);
    const relative = path.relative(c.repo, source);
    script(c, [f('read_file', { path: relative }), f('finish', { summary: 'approved scope only' }), f('read_file', { path: relative }), f('submit_review', { verdict: 'approve', findings: [] })]);
    const n = count(c); const { out: o, code: k } = await H.runKogen(c, ['intent', 'build', slug]);
    const reqs = c.server.providerRequests().slice(n); const rev = c.server.reviewRequests();
    const text = reqs.map(r => inputText(r));
    const outputs = c.server.toolOutputs();
    const escaped = JSON.stringify(request).slice(1, -1);
    const retrieved = outputs.filter(x => typeof x === 'string' && x.includes(escaped));
    const tracked = await git(c, ['ls-tree', '-r', '--name-only', 'HEAD']);
    const reference = r => { const t = inputText(r); return t.includes(relative) || t.includes('source-provenance.json'); };
    return {
      ...basic,
      build_retrieval: retrieved.length > 0 && reqs.some(r => !rev.includes(r) && reference(r)),
      review_retrieval: rev.some(reference) && retrieved.length >= 2,
      diagnostic_not_authority: text.some(t => /diagnostic[\s\S]*provenance|provenance[\s\S]*diagnostic/i.test(t)) && text.some(t => /approved[\s\S]*Intent/i.test(t)),
      no_auto_scope: k === 0 && fs.readFileSync(path.join(c.repo, 'app.txt'), 'utf8') === 'baseline\n', source_untracked: !tracked.includes('.kogen/local/provenance'),
      input_replacement_ignored: !text.some(t => t.includes('POISON replacement')) && fs.readFileSync(source).equals(bytes), output: o,
    };
  }

  async function measure(spec) {
    const base = { model: 'gpt-6.1-sol', input: [{ role: 'user', content: spec.literal }], tools: [{ name: 'sample', type: 'function' }], store: false, stream: true };
    const size = x => Buffer.byteLength(JSON.stringify(x));
    const body = target => ({ ...base, padding: 'x'.repeat(target - size({ ...base, padding: '' })) });
    const check = await H.goDriver('request-measure', measureSource);
    const r = await check([], { input: JSON.stringify([base, ...[spec.budget - 1, spec.budget, spec.budget + 1].map(body)]) });
    assert.equal(r.code, 0, r.out);
    const [initial, ...rows] = JSON.parse(r.out);
    return { supported: true, boundary_bytes: rows.map(x => x.rendered_bytes), boundary_fits: rows.map(x => x.fits), complete_envelope: initial.rendered_bytes === size(base) && initial.input_budget_bytes === spec.budget && initial.output_reserve_tokens === spec.reserve, unicode_exact: base.input[0].content === spec.literal, metadata_is_not_threshold: spec.last_completed_input === 883138 && spec.rejected_request_usage === null };
  }

  When('I exercise native continuity {string} with:', { timeout: 300000 }, async function (mode, json) {
    const spec = JSON.parse(json);
    let d;
    if (mode === 'measure') d = await measure(spec);
    else {
      const suite = await H.setupSuite(); let c;
      try {
        c = await H.project(suite, [], { stagedIntent: false });
        d = ['provenance', 'refine-source', 'refuse-refine', 'source-drift'].includes(mode) ? await provenance(c, spec, mode) : await growth(c, spec, mode);
      } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
    }
    if (d.replay) { d.replay_custody = replayCustody(d.replay); delete d.replay; }
    this.nativeContinuity = d; await this.attach(JSON.stringify(d), 'application/json');
  });
  Then('the native continuity observations include:', function (json) {
    assert.ok(this.nativeContinuity, 'no actual native observations');
    for (const [key, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.nativeContinuity[key], expected, `${key}: ${JSON.stringify(this.nativeContinuity)}`);
  });
}
