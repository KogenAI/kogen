// SuperGrok subscription acceptance (externally drafted helper; see the Intent's authoring origin).
// Scenarios run a generated ExUnit driver against an installed release and one local fake that
// serves xAI-shaped device/token/Responses paths plus the ChatGPT token path. The fake records
// headers, forms, bodies and receipt times; the predicates below judge those records. The same
// predicates are qualified by `--control good|bad` on current native producers and mutations.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const CLIENT_ID = 'b1a00492-073a-47ea-816f-4c329264a828';
const SCOPE = 'openid profile email offline_access grok-cli:access api:access';
const DEVICE_GRANT = 'urn:ietf:params:oauth:grant-type:device_code';
const OPAQUE = 'synthetic opaque+/==\nΔ🙂';
const BORROWED = 'BORROWED_HARNESS_TOKEN_MUST_NOT_BE_READ';
const TOLERANCE_MS = 50;
// Native 007087b9 rendering of ChatGPT.request_body(%{model: "gpt-6.1-sol", effort: "high"},
// "policy", [user "contract"], [read_file]); omitted provider must keep these exact bytes.
const LEGACY_BODY = '{"include":["reasoning.encrypted_content"],"input":[{"content":[{"prompt_cache_breakpoint":{"mode":"explicit"},"text":"policy","type":"input_text"}],"role":"developer"},{"content":[{"prompt_cache_breakpoint":{"mode":"explicit"},"text":"contract","type":"input_text"}],"role":"user"}],"model":"gpt-6.1-sol","prompt_cache_options":{"mode":"implicit","ttl":"30m"},"reasoning":{"effort":"high"},"store":false,"stream":true,"tool_choice":"auto","tools":[{"description":"Read","name":"read_file","parameters":{"additionalProperties":false,"properties":{"path":{"type":"string"}},"required":["path"],"type":"object"},"strict":true,"type":"function"}]}';
// Header names the native 007087b9 ChatGPT transport sends; SuperGrok adds only user-agent.
const LEGACY_HEADER_NAMES = ['accept', 'authorization', 'connection', 'content-length', 'content-type', 'host'];
const SUPERGROK_HEADER_NAMES = [...LEGACY_HEADER_NAMES, 'user-agent'].sort();
const BODY_KEYS = ['include', 'input', 'instructions', 'model', 'reasoning', 'store', 'stream', 'tool_choice', 'tools'];
const SECRET_PREFIXES = ['SG_FAKE_ACCESS_', 'SG_FAKE_REFRESH_', 'SG_FAKE_DEVICE_CODE_', 'SG_FAKE_SIGNATURE_'];
const WORKFLOW_EFFORTS = { shape: 'high', refine: 'high', build: 'medium', review: 'high' };

const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
const holds = f => { try { return f() !== false; } catch { return false; } };
const keys = o => Object.keys(o || {}).sort();

const REFUSALS = {
  missing_scope: { exit: 4, lines: ['provider/login_failed: SuperGrok API access was not granted; sign in again and allow it'], device: 1, polls: 1 },
  no_tokens: { exit: 4, lines: ['provider/login_failed: the SuperGrok sign-in returned no usable tokens'], device: 1, polls: 1 },
  denied: { exit: 4, lines: ['provider/login_failed: the SuperGrok sign-in was denied'], device: 1, polls: 2 },
  expired_token: { exit: 4, lines: ['provider/login_failed: the SuperGrok sign-in code expired'], device: 1, polls: 1 },
  deadline: { exit: 4, lines: ['provider/login_failed: the SuperGrok sign-in code expired'], device: 1, deadline: true },
  not_https: { exit: 4, lines: ['provider/login_failed: the SuperGrok verification address is not HTTPS'], device: 1, polls: 0 },
  incomplete: { exit: 4, lines: ['provider/login_failed: the SuperGrok device authorization response is incomplete'], device: 1, polls: 0 },
  rejected: { exit: 4, lines: ['provider/login_failed: the SuperGrok device authorization request failed (403 invalid_client)'], device: 1, polls: 0 },
  cancel: { exit: 130, lines: [], device: 1, cancel: true },
  unknown_grok: { exit: 2, lines: ["kogen provider login: unknown provider 'grok' (supported: chatgpt, supergrok)"], device: 0, polls: 0 },
  unknown_xai: { exit: 2, lines: ["kogen provider login: unknown provider 'xai' (supported: chatgpt, supergrok)"], device: 0, polls: 0 },
};
const LIMITS = {
  s401_twice: { exit: 4, lines: ['provider/login: the SuperGrok sign-in was rejected; run kogen provider login supergrok'], responses: 2, refreshes: 1 },
  s402: { exit: 4, lines: ['provider/refused: SuperGrok reported a billing or credit limit (402', 'never falls back to paid API usage'], responses: 1, refreshes: 0 },
  s403: { exit: 4, lines: ['provider/refused: SuperGrok denied API access for this sign-in (403', 'never falls back to an API key or another provider'], responses: 1, refreshes: 0 },
  s429: { exit: 4, lines: ['provider/unavailable: SuperGrok did not answer after 3 attempts'], responses: 3, refreshes: 0 },
  model: { exit: 4, lines: ['provider/model_unavailable: grok-4.7 is not available to this SuperGrok account'], responses: 1, refreshes: 0 },
  budget: { exit: 1, lines: ['candidate/context_budget_exceeded'], responses: 1, refreshes: 0 },
  bad_provider: { exit: 3, lines: ['environment/project_config_invalid', 'models.shape.provider must be chatgpt or supergrok'], responses: 0, refreshes: 0 },
  bad_model: { exit: 3, lines: ['environment/project_config_invalid', 'models.shape: supergrok supports model grok-4.7 with effort low, medium, high or xhigh'], responses: 0, refreshes: 0 },
  bad_effort: { exit: 3, lines: ['environment/project_config_invalid', 'models.shape: supergrok supports model grok-4.7 with effort low, medium, high or xhigh'], responses: 0, refreshes: 0 },
  not_signed_in: { exit: 4, lines: ['provider/login: not signed in; run kogen provider login supergrok'], responses: 0, refreshes: 0 },
  borrowed_file: { exit: 4, lines: ['provider/login: saved login cannot be used; run kogen provider login supergrok'], responses: 0, refreshes: 0 },
};

// ---- Predicates over fake-server records ----

const ofKind = (log, kind) => (log || []).filter(r => r.kind === kind);

// One honest device request, exact polls, server-supplied pacing and lifetime.
function deviceObserver(d, polls) {
  return holds(() => {
    const device = ofKind(d.log, 'device');
    assert.equal(device.length, 1);
    assert.deepEqual(device[0].form, { client_id: CLIENT_ID, scope: SCOPE, referrer: 'kogen' });
    for (const r of d.log) {
      assert.equal(r.headers['user-agent'], 'kogen/' + d.version_id);
      for (const h of ['x-xai-token-auth', 'cookie', 'authorization', 'referer', 'x-api-key']) assert.ok(!Object.hasOwn(r.headers, h), h);
    }
    const p = ofKind(d.log, 'poll');
    if (polls !== undefined) assert.equal(p.length, polls);
    let interval = d.device.interval ?? 5;
    if (interval < 1) interval = 1;
    let previous = d.issued_at;
    for (const r of p) {
      assert.deepEqual(r.form, { grant_type: DEVICE_GRANT, device_code: d.device.device_code, client_id: CLIENT_ID });
      assert.ok(r.at - previous >= interval * 1000 - TOLERANCE_MS, `poll after ${r.at - previous} ms; interval ${interval} s`);
      assert.ok(r.at < d.issued_at + d.device.expires_in * 1000 + 250, 'poll after the server lifetime');
      if (r.answer === 'slow_down') interval += 5;
      previous = r.at;
    }
  });
}

function credentialObserver(c, expected) {
  return holds(() => {
    assert.equal(c.file_mode, 0o600); assert.equal(c.dir_mode, 0o700); assert.equal(c.parent_mode, 0o700);
    assert.equal(c.lock_exists, false);
    const v = JSON.parse(c.text);
    const allowed = ['access_token', 'client_id', 'email', 'expires_at', 'referrer', 'refresh_token', 'scope'];
    assert.ok(keys(v).every(k => allowed.includes(k)), 'unexpected stored field');
    assert.equal(v.client_id, CLIENT_ID); assert.equal(v.referrer, 'kogen');
    assert.equal(v.access_token, expected.access); assert.equal(v.refresh_token, expected.refresh);
    assert.equal(v.scope, expected.scope);
    if (expected.email) assert.equal(v.email, expected.email); else assert.ok(!Object.hasOwn(v, 'email'));
    assert.ok(Number.isInteger(v.expires_at) && Math.abs(v.expires_at - (expected.at + 3600)) <= 120);
    for (const s of expected.never || []) assert.ok(!c.text.includes(s));
  });
}

// SuperGrok Responses request: exact identity/header set and a cache-control-free body.
function wireObserver(r, d) {
  return holds(() => {
    assert.equal(r.method, 'POST'); assert.equal(r.path, '/v1/responses');
    assert.equal(r.provider, 'supergrok');
    assert.ok(r.headers.authorization.startsWith('Bearer SG_FAKE_ACCESS_'));
    assert.equal(r.headers.accept, 'text/event-stream');
    assert.equal(r.headers['content-type'], 'application/json');
    assert.equal(r.headers['user-agent'], 'kogen/' + d.version_id);
    assert.deepEqual(keys(r.headers), SUPERGROK_HEADER_NAMES);
    const b = r.json;
    assert.deepEqual(keys(b), b.tools && b.tools.length ? BODY_KEYS : BODY_KEYS.filter(k => !['tool_choice', 'tools'].includes(k)));
    assert.equal(b.model, d.model || 'grok-4.7');
    assert.ok(['low', 'medium', 'high', 'xhigh'].includes(b.reasoning.effort)); assert.deepEqual(keys(b.reasoning), ['effort']);
    if (d.efforts) { assert.ok(Object.hasOwn(d.efforts, r.owner)); assert.equal(b.reasoning.effort, d.efforts[r.owner]); }
    assert.deepEqual(b.include, ['reasoning.encrypted_content']);
    assert.equal(b.stream, true); assert.equal(b.store, false);
    assert.equal(typeof b.instructions, 'string'); assert.ok(b.instructions.length > 0);
    if (b.tools && b.tools.length) assert.equal(b.tool_choice, 'auto');
    for (const item of b.input) {
      assert.notEqual(item.role, 'developer');
      if (Array.isArray(item.content)) for (const block of item.content) assert.ok(!Object.hasOwn(block, 'prompt_cache_breakpoint'));
    }
    assert.ok(r.bytes <= 524288);
  });
}

function chatgptHeadersSame(r) {
  return holds(() => { assert.equal(r.provider, 'chatgpt'); assert.deepEqual(keys(r.headers), LEGACY_HEADER_NAMES); });
}

// Each successful response's items are replayed exactly and in order by that owner's next request,
// every function call gets one matching output, and earlier replay items are never dropped.
function replayObserver(log, owner) {
  return holds(() => {
    const ok = ofKind(log, 'responses').filter(r => r.owner === owner && r.status === 200);
    assert.ok(ok.length >= 2);
    for (let k = 0; k + 1 < ok.length; k++) {
      const sent = ok[k].sent, next = ok[k + 1].json.input;
      let at = -1;
      for (let i = 0; i + sent.length <= next.length; i++) if (same(next.slice(i, i + sent.length), sent)) { at = i; break; }
      assert.ok(at >= 0, `owner ${owner} request ${k + 2} lacks exact replay`);
      for (const call of sent.filter(x => x.type === 'function_call')) {
        const outs = next.filter(x => x.type === 'function_call_output' && x.call_id === call.call_id);
        assert.equal(outs.length, 1);
        assert.ok(next.indexOf(outs[0]) > at);
      }
      const replayed = x => ['reasoning', 'function_call', 'function_call_output'].includes(x.type) || x.role === 'assistant';
      const before = ok[k].json.input.filter(replayed), after = next.filter(replayed);
      assert.ok(same(after.slice(0, before.length), before), 'earlier replay changed');
    }
  });
}

function containsAny(value, needles) {
  const text = JSON.stringify(value);
  return needles.some(n => text.includes(JSON.stringify(n).slice(1, -1)) || text.includes(n));
}

function independentObserver(log, s) {
  return holds(() => {
    const review = ofKind(log, 'responses').filter(r => r.owner === 'review');
    const build = ofKind(log, 'responses').filter(r => r.owner === 'build' && r.status === 200);
    assert.ok(review.length >= 2 && build.length >= 2);
    const builderOnly = build.flatMap(r => r.sent.flatMap(i => [i.id, i.call_id, i.encrypted_content, ...(i.content || []).map(c => c.text)])).filter(Boolean);
    assert.ok(builderOnly.some(x => x.startsWith(s.opaque)));
    for (const r of review) assert.ok(!containsAny(r.json.input, builderOnly), 'reviewer received builder conversation items');
    assert.ok(review.some(r => r.json.input.some(i => i.type === 'reasoning' && i.encrypted_content === s.opaque + '-review1')));
  });
}

function typedImageObserver(log, image) {
  return holds(() => {
    const outs = ofKind(log, 'responses').filter(r => r.owner === 'build').flatMap(r => r.json.input.filter(i => i.type === 'function_call_output' && i.call_id === 'call_sg_build_image'));
    assert.ok(outs.length >= 1);
    for (const o of outs) {
      assert.ok(Array.isArray(o.output)); assert.deepEqual(o.output.map(x => x.type), ['input_text', 'input_image']);
      const meta = JSON.parse(o.output[0].text);
      assert.equal(meta.sha256, sha(Buffer.from(image, 'base64'))); assert.equal(meta.format, 'png');
      assert.equal(o.output[1].image_url, 'data:image/png;base64,' + image);
    }
  });
}

function usageObserver(rows, provider, nullAbsent) {
  return holds(() => {
    assert.ok(Array.isArray(rows) && rows.length > 0);
    for (const r of rows) assert.equal(r.provider, provider);
    if (nullAbsent) {
      const done = rows.filter(r => r.outcome === 'completed');
      assert.ok(done.length > 0);
      for (const r of done) { assert.equal(r.usage.input, 11); assert.equal(r.usage.output, 7); assert.equal(r.usage.cached, null); assert.equal(r.usage.reasoning, null); }
    }
  });
}

// The scan must detect the credential file itself, so an empty hit list is not vacuous.
function secretsObserver(scan) {
  return holds(() => {
    assert.ok(scan.scanned > 0); assert.equal(scan.detects_credential, true);
    assert.deepEqual(scan.hits, []);
  });
}

function linesOk(r, lines) { return !!r && lines.every(l => (r.stdout || '').includes(l)); }

// ---- Scenario qualification ----

function qualify(d, s) {
  const o = {};
  if (d.mode === 'login') {
    const dev = d.device;
    const address = dev.verification_uri_complete || dev.verification_uri;
    o.exit = d.login.exit;
    o.stdout_exact = d.login.stdout === `Continue with SuperGrok\n${address}\nCode: ${dev.user_code}\nsupergrok signed in (sg-user@example.invalid)\n`;
    o.device_request_exact = holds(() => { const x = ofKind(d.log, 'device'); assert.equal(x.length, 1); assert.deepEqual(x[0].form, { client_id: CLIENT_ID, scope: SCOPE, referrer: 'kogen' }); });
    o.identity_honest = d.log.length > 0 && d.log.every(r => r.headers['user-agent'] === 'kogen/' + d.version_id && !Object.hasOwn(r.headers, 'x-xai-token-auth'));
    o.polls_exact = holds(() => ofKind(d.log, 'poll').length === 3 && ofKind(d.log, 'poll').every(r => same(r.form, { grant_type: DEVICE_GRANT, device_code: dev.device_code, client_id: CLIENT_ID })));
    o.paced_by_server = deviceObserver(d, 3);
    const p = ofKind(d.log, 'poll');
    o.slow_down_respected = p.length === 3 && p[1].answer === 'slow_down' && p[2].at - p[1].at >= 6000 - TOLERANCE_MS;
    o.credential_exact = !!d.credential && credentialObserver(d.credential, { access: 'SG_FAKE_ACCESS_0_DO_NOT_LEAK', refresh: 'SG_FAKE_REFRESH_DO_NOT_LEAK', scope: SCOPE, email: 'sg-user@example.invalid', at: d.written_at, never: [dev.device_code, dev.user_code, 'SG_FAKE_SIGNATURE_'] });
    o.private = !!d.credential && d.credential.file_mode === 0o600 && d.credential.dir_mode === 0o700 && d.credential.parent_mode === 0o700;
    o.lock_released = !!d.credential && d.credential.lock_exists === false;
    o.list_both = d.list.exit === 0 && d.list.stdout === 'chatgpt: not signed in\nsupergrok: signed in (sg-user@example.invalid)\n';
    o.list_offline = d.list.exit === 0 && d.list.stdout.includes('supergrok: ') && d.list_requests === 0;
    o.borrowed_unused = !containsAny(d.log, [s.borrowed]) && !!d.credential && !d.credential.text.includes(s.borrowed);
    o.secrets_safe = secretsObserver(d.scan) && !SECRET_PREFIXES.some(x => (d.login.stdout + d.login.stderr + d.list.stdout).includes(x)) && !(d.login.stdout + d.login.stderr).includes(dev.device_code);
    return o;
  }
  if (d.mode === 'login-refusals') {
    o.refusals = {};
    for (const c of d.cases) {
      const e = REFUSALS[c.name];
      const polls = ofKind(c.log, 'poll');
      const device = ofKind(c.log, 'device');
      o.refusals[c.name] = holds(() => {
        assert.equal(c.exit, e.exit); assert.ok(linesOk(c, e.lines));
        assert.equal(c.earlier_after, c.earlier_before);
        assert.equal(device.length, e.device);
        if (e.polls !== undefined) assert.equal(polls.length, e.polls);
        if (e.device) assert.ok(deviceObserver({ ...c, version_id: d.version_id }));
        if (e.deadline) {
          assert.ok(polls.length >= 1);
          assert.ok(polls.every(r => r.at < c.issued_at + c.device.expires_in * 1000 + 250));
          assert.ok(c.ended - c.issued_at <= c.device.expires_in * 1000 + 2500);
        }
        if (e.cancel) { assert.ok(polls.length >= 1); assert.ok(polls.every(r => r.at <= c.signal_at + 250)); }
        if (c.device && c.device.device_code) assert.ok(!(c.stdout + c.stderr).includes(c.device.device_code));
      });
    }
    return o;
  }
  if (d.mode === 'workflow') {
    const responses = ofKind(d.log, 'responses');
    o.shape_exit = d.shape.exit; o.refine_exit = d.refine.exit; o.approve_exit = d.approve.exit; o.build_exit = d.build.exit;
    o.one_commit = d.new_commits === 1 && d.trailer === true;
    o.wire_exact = responses.length >= 9 && responses.every(r => wireObserver(r, { ...d, efforts: WORKFLOW_EFFORTS }));
    // Activity-bound: zero requests must never satisfy a no-fallback, bound or leak claim.
    const active = responses.length >= 9 && ofKind(d.log, 'refresh').length >= 1;
    o.no_chatgpt = active && responses.every(r => r.provider === 'supergrok') && ofKind(d.log, 'chatgpt_auth').length === 0;
    o.replay_exact = ['shape', 'refine', 'build', 'review'].every(owner => replayObserver(d.log, owner));
    o.typed_image = typedImageObserver(d.log, d.image);
    o.bounded = active && responses.every(r => r.bytes <= s.budget);
    o.review_independent = independentObserver(d.log, s);
    const refreshes = ofKind(d.log, 'refresh');
    o.refresh_kept = refreshes.length === 2 && refreshes.every(r => same(r.form, { grant_type: 'refresh_token', refresh_token: 'SG_FAKE_REFRESH_DO_NOT_LEAK', client_id: CLIENT_ID })) &&
      !!d.credential && credentialObserver(d.credential, { access: 'SG_FAKE_ACCESS_2_DO_NOT_LEAK', refresh: 'SG_FAKE_REFRESH_DO_NOT_LEAK', scope: SCOPE, email: 'sg-user@example.invalid', at: d.refreshed_at });
    const unauthorized = responses.filter(r => r.status === 401);
    o.retry_once = unauthorized.length === 1 && holds(() => {
      const i = responses.indexOf(unauthorized[0]);
      assert.ok(same(responses[i + 1].json, unauthorized[0].json));
      assert.notEqual(responses[i + 1].headers.authorization, unauthorized[0].headers.authorization);
      assert.ok(d.log.indexOf(refreshes[1]) < d.log.indexOf(responses[i + 1]));
    });
    // The seeded file does not count: Kogen must have rewritten it with the refreshed token.
    o.credential_private = !!d.credential && JSON.parse(d.credential.text).access_token === 'SG_FAKE_ACCESS_2_DO_NOT_LEAK' && d.credential.file_mode === 0o600 && d.credential.dir_mode === 0o700 && d.credential.lock_exists === false;
    o.usage_provider = usageObserver(d.usage_rows, 'supergrok', false);
    o.usage_null_absent = usageObserver(d.usage_rows, 'supergrok', true);
    o.secrets_safe = active && secretsObserver(d.scan);
    return o;
  }
  if (d.mode === 'limits') {
    o.limits = {};
    for (const c of d.cases) {
      const e = LIMITS[c.name];
      const responses = ofKind(c.log, 'responses');
      o.limits[c.name] = holds(() => {
        assert.equal(c.exit, e.exit); assert.ok(linesOk(c, e.lines));
        assert.equal(responses.length, e.responses); assert.equal(ofKind(c.log, 'refresh').length, e.refreshes);
        assert.ok(responses.every(r => wireObserver(r, d)));
      });
    }
    const all = d.cases.flatMap(c => c.log);
    // Refusals after real SuperGrok traffic (402/403/429/401) must have occurred for these to mean anything.
    const active = ['s401_twice', 's402', 's403', 's429'].every(n => ofKind((d.cases.find(c => c.name === n) || {}).log, 'responses').some(r => r.provider === 'supergrok'));
    o.no_fallback = active && all.every(r => r.kind !== 'responses' || r.provider === 'supergrok') && ofKind(all, 'chatgpt_auth').length === 0;
    o.no_api_key = active && !containsAny(all, [s.borrowed]);
    o.secrets_safe = active && secretsObserver(d.scan) && d.cases.every(c => !SECRET_PREFIXES.some(x => (c.stdout + c.stderr).includes(x)));
    return o;
  }
  if (d.mode === 'legacy') {
    const responses = ofKind(d.log, 'responses');
    o.maps_exact = same(d.legacy_keys, { build: ['effort', 'model'], review: ['effort', 'model'], shape: ['effort', 'model'] });
    o.workers_exact = same(d.worker_keys, { draft: ['effort', 'model'], probe: ['effort', 'model'], read: ['effort', 'model'] });
    o.explicit_chatgpt = same(d.explicit_chatgpt, { model: 'gpt-6.1-sol', effort: 'high', provider: 'chatgpt' });
    o.body_bytes_same = d.legacy_body === LEGACY_BODY;
    o.chatgpt_headers_same = responses.length >= 4 && responses.every(chatgptHeadersSame);
    o.chatgpt_token_only = responses.every(r => r.provider === 'chatgpt') && ofKind(d.log, 'refresh').length === 0 && ofKind(d.log, 'device').length === 0;
    o.list_both = d.list.exit === 0 && d.list.stdout === 'chatgpt: signed in (integration@example.invalid)\nsupergrok: not signed in\n';
    o.checkpoint_legacy = d.checkpoint.version === 3 && same(d.checkpoint.model_keys, { build: ['effort', 'model'], review: ['effort', 'model'], shape: ['effort', 'model'] }) && d.checkpoint.config_equal === true;
    o.provider_edit_refused = d.edited_resume.exit !== 0 && ['baseline changed: .kogen/project.yaml', 'baseline/configuration changed'].some(x => d.edited_resume.stdout.includes(x)) && d.edited_resume.requests === 0 && d.edited_resume.checkpoint_unchanged === true;
    o.changed_since_approval = d.edited_build.exit === 1 && d.edited_build.stdout.includes('intent/changed_since_approval') && d.edited_build.requests === 0;
    o.resume_lands = d.resume.exit === 0 && d.new_commits === 1;
    o.usage_chatgpt = usageObserver(d.usage_rows, 'chatgpt', false);
    o.older_usage_null = Array.isArray(d.older_rows) && d.older_rows.length > 0 && d.older_rows.every(r => r.provider === null);
    return o;
  }
  throw new Error('unknown mode ' + d.mode);
}

// ---- Elixir sources shared by the control and the scenario driver ----

const FAKE = String.raw`
defmodule SgItems do
  def reasoning(label, opaque), do: %{"type" => "reasoning", "id" => "rs_" <> label, "encrypted_content" => opaque <> "-" <> label, "summary" => []}
  def note(label), do: %{"type" => "message", "id" => "msg_" <> label, "role" => "assistant", "phase" => "commentary", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "Working note " <> label <> "."}]}
  def call(label, name, args), do: %{"type" => "function_call", "id" => "fc_" <> label, "call_id" => "call_" <> label, "name" => name, "arguments" => JSON.encode!(args), "status" => "completed"}

  def png(w, h, target \\ nil) do
    chunk = fn type, data -> <<byte_size(data)::32>> <> type <> data <> <<:erlang.crc32(type <> data)::32>> end
    raw = :binary.copy(<<0>> <> :binary.copy(<<200, 30, 30>>, w), h)
    parts = [<<137, 80, 78, 71, 13, 10, 26, 10>>, chunk.("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>), chunk.("IDAT", :zlib.compress(raw)), chunk.("IEND", "")]
    parts = if target, do: List.insert_at(parts, 3, chunk.("tEXt", "padding" <> <<0>> <> :binary.copy("x", target - IO.iodata_length(parts) - 20))), else: parts
    IO.iodata_to_binary(parts)
  end
end

defmodule SgFake do
  @client "b1a00492-073a-47ea-816f-4c329264a828"
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"
  @scope "openid profile email offline_access grok-cli:access api:access"

  def defaults do
    %{log: [], device: nil, device_status: 200, device_error: %{}, answers: [], grant: %{}, responses: [],
      sg_access: nil, sg_refresh: nil, issued: 0, refreshes: 0, rotate: false, issued_at: nil,
      chatgpt_access: "fake-integration-access-token", usage: %{"input_tokens" => 11, "output_tokens" => 7}}
  end

  def start(cfg \\ %{}) do
    {:ok, l} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(l)
    {:ok, st} = Agent.start(fn -> Map.merge(defaults(), cfg) end)
    spawn(fn -> loop(l, st) end)
    %{listener: l, port: port, state: st, url: "http://127.0.0.1:" <> Integer.to_string(port)}
  end

  def stop(f) do
    :gen_tcp.close(f.listener)
    Agent.stop(f.state)
  catch
    :exit, _ -> :ok
  end

  def reset(f, cfg), do: Agent.update(f.state, fn s -> Map.merge(defaults(), Map.merge(Map.take(s, [:sg_access, :sg_refresh]), cfg)) end)
  def put(f, cfg), do: Agent.update(f.state, &Map.merge(&1, cfg))
  def get(f, key), do: Agent.get(f.state, &Map.get(&1, key))
  def log(f), do: f |> get(:log) |> Enum.reverse()

  def grant(extra \\ %{}) do
    payload = Base.url_encode64(JSON.encode!(%{"email" => "sg-user@example.invalid"}), padding: false)
    Map.merge(%{"access_token" => "SG_FAKE_ACCESS_0_DO_NOT_LEAK", "refresh_token" => "SG_FAKE_REFRESH_DO_NOT_LEAK", "expires_in" => 3600,
      "token_type" => "Bearer", "scope" => @scope, "id_token" => "fakeheader." <> payload <> ".SG_FAKE_SIGNATURE_0"}, extra)
  end

  defp loop(l, st) do
    case :gen_tcp.accept(l) do
      {:ok, socket} ->
        serve(socket, st)
        loop(l, st)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        loop(l, st)
    end
  end

  defp serve(socket, st) do
    case read(socket, "") do
      {:ok, r} -> reply(socket, st, r)
      _ -> :ok
    end
  after
    :gen_tcp.close(socket)
  end

  defp read(socket, data) do
    case :binary.match(data, "\r\n\r\n") do
      {at, 4} ->
        head = binary_part(data, 0, at)
        rest = binary_part(data, at + 4, byte_size(data) - at - 4)
        [line | lines] = String.split(head, "\r\n")
        [method, target | _] = String.split(line, " ")
        headers =
          Enum.reduce(lines, %{}, fn l, acc ->
            [k, v] = String.split(l, ":", parts: 2)
            Map.update(acc, String.downcase(k), String.trim(v), &(&1 <> "," <> String.trim(v)))
          end)
        size = String.to_integer(Map.get(headers, "content-length", "0"))
        if byte_size(rest) >= size,
          do: {:ok, %{method: method, path: target, headers: headers, body: binary_part(rest, 0, size)}},
          else: (case :gen_tcp.recv(socket, 0, 10_000) do {:ok, more} -> read(socket, data <> more); e -> e end)

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 10_000) do
          {:ok, more} -> read(socket, data <> more)
          e -> e
        end
    end
  end

  defp reply(socket, st, r) do
    type = Map.get(r.headers, "content-type", "")
    rec = %{at: System.monotonic_time(:millisecond), method: r.method, path: r.path, headers: r.headers, bytes: byte_size(r.body),
      form: if(String.contains?(type, "x-www-form-urlencoded"), do: URI.decode_query(r.body)),
      json: if(String.contains?(type, "json"), do: (case JSON.decode(r.body) do {:ok, v} -> v; _ -> nil end))}
    action = Agent.get_and_update(st, fn s -> {a, rec, s} = route(rec, s); {a, %{s | log: [rec | s.log]}} end)
    send_action(socket, action)
  end

  defp route(%{path: "/oauth2/device/code"} = rec, s) do
    rec = Map.put(rec, :kind, "device")
    if s.device_status == 200,
      do: {{:json, 200, s.device}, rec, %{s | issued_at: rec.at}},
      else: {{:json, s.device_status, s.device_error}, rec, %{s | issued_at: rec.at}}
  end

  defp route(%{path: "/oauth2/token", form: %{"grant_type" => @device_grant} = form} = rec, s) do
    exact = form == %{"grant_type" => @device_grant, "device_code" => (s.device || %{})["device_code"], "client_id" => @client}
    {answer, rest} = case s.answers do [a | rest] -> {a, rest}; [] -> {"pending", []} end
    rec = Map.merge(rec, %{kind: "poll", answer: if(exact, do: if(is_map(answer), do: "grant", else: answer), else: "invalid_request")})
    s = %{s | answers: rest}
    cond do
      not exact -> {{:json, 400, %{"error" => "invalid_request"}}, rec, s}
      is_map(answer) -> (g = grant(answer); {{:json, 200, g}, rec, %{s | sg_access: g["access_token"], sg_refresh: g["refresh_token"]}})
      answer == "denied" -> {{:json, 400, %{"error" => "access_denied"}}, rec, s}
      answer == "expired" -> {{:json, 400, %{"error" => "expired_token"}}, rec, s}
      answer == "slow_down" -> {{:json, 400, %{"error" => "slow_down"}}, rec, s}
      true -> {{:json, 400, %{"error" => "authorization_pending"}}, rec, s}
    end
  end

  defp route(%{path: "/oauth2/token", form: form} = rec, s) when is_map(form) do
    rec = Map.put(rec, :kind, "refresh")
    exact = form == %{"grant_type" => "refresh_token", "refresh_token" => s.sg_refresh, "client_id" => @client}
    if exact and is_binary(s.sg_refresh) do
      n = s.refreshes + 1
      access = "SG_FAKE_ACCESS_" <> Integer.to_string(n) <> "_DO_NOT_LEAK"
      body = %{"access_token" => access, "expires_in" => 3600, "token_type" => "Bearer"}
      body = if s.rotate, do: Map.put(body, "refresh_token", "SG_FAKE_REFRESH_ROTATED_" <> Integer.to_string(n)), else: body
      {{:json, 200, body}, rec, %{s | refreshes: n, sg_access: access, sg_refresh: Map.get(body, "refresh_token", s.sg_refresh)}}
    else
      {{:json, 400, %{"error" => "invalid_grant"}}, rec, s}
    end
  end

  defp route(%{path: "/api/accounts/oauth/token"} = rec, s), do: {{:json, 400, %{"error" => "invalid_grant"}}, Map.put(rec, :kind, "chatgpt_auth"), s}

  defp route(%{path: "/v1/responses"} = rec, s) do
    bearer = Map.get(rec.headers, "authorization")
    provider = cond do
      is_binary(s.sg_access) and bearer == "Bearer " <> s.sg_access -> "supergrok"
      bearer == "Bearer " <> s.chatgpt_access -> "chatgpt"
      true -> "unknown"
    end
    tools = Enum.map(((rec.json || %{})["tools"] || []), & &1["name"])
    owner = cond do
      "submit_review" in tools -> "review"
      "submit_refinement" in tools -> "refine"
      "submit" in tools -> "shape"
      "finish" in tools -> "build"
      true -> "other"
    end
    rec = Map.merge(rec, %{kind: "responses", provider: provider, owner: owner, sent: []})
    if provider == "unknown" do
      {{:json, 401, %{"error" => %{"code" => "unauthorized", "message" => "unknown bearer"}}}, Map.put(rec, :status, 401), s}
    else
      {action, rest} = case s.responses do [a | rest] -> {a, rest}; [] -> {{:http, 400, %{"error" => %{"code" => "invalid_request", "message" => "script exhausted"}}}, []} end
      s = %{s | responses: rest, issued: s.issued + 1}
      case action do
        {:items, items} -> {{:sse, items, s.issued, s.usage}, Map.merge(rec, %{status: 200, sent: items}), s}
        {:http, status, body} -> {{:json, status, body}, Map.put(rec, :status, status), s}
      end
    end
  end

  defp route(rec, s), do: {{:json, 404, %{"error" => "not found"}}, Map.put(rec, :kind, "other"), s}

  defp send_action(socket, {:json, status, body}), do: send_http(socket, status, "application/json", JSON.encode!(body))

  defp send_action(socket, {:sse, items, n, usage}) do
    events =
      items |> Enum.with_index() |> Enum.flat_map(fn {item, i} ->
        added = if item["type"] == "function_call", do: Map.put(item, "arguments", ""), else: item
        [%{"type" => "response.output_item.added", "output_index" => i, "item" => added}, %{"type" => "response.output_item.done", "output_index" => i, "item" => item}]
      end)
    done = %{"type" => "response.completed", "response" => %{"id" => "resp_sg_" <> Integer.to_string(n), "model" => "grok-4.7", "usage" => usage}}
    send_http(socket, 200, "text/event-stream", Enum.map_join(events ++ [done], "", &("event: " <> &1["type"] <> "\ndata: " <> JSON.encode!(&1) <> "\n\n")))
  end

  defp send_http(socket, status, type, body) do
    :gen_tcp.send(socket, ["HTTP/1.1 ", Integer.to_string(status), " Fixture\r\ncontent-type: ", type, "\r\nx-request-id: req-sg\r\ncontent-length: ",
      Integer.to_string(byte_size(body)), "\r\nconnection: close\r\n\r\n", body])
  end
end
`;

// Current native producers plus one reference device client; no Kogen login implementation exists here.
const CONTROL = FAKE + String.raw`
receipt = System.fetch_env!("SG_CONTROL_RECEIPT")
opaque = System.fetch_env!("SG_CONTROL_OPAQUE")
home = Kogen.tmp_path("sg-control-home")
creds = Path.join(home, ".kogen/credentials")
File.mkdir_p!(creds)
File.chmod!(Path.join(home, ".kogen"), 0o700)
File.chmod!(creds, 0o700)
File.write!(Path.join(creds, "chatgpt.json"), JSON.encode!(%{"client_id" => "oaiapp_fake-integration-client", "access_token" => "fake-integration-access-token",
  "refresh_token" => "fake-integration-refresh-token", "expires_at" => System.system_time(:second) + 86_400, "scope" => "openid", "email" => "integration@example.invalid"}))
yaml = fn models -> "version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: 'true'\n    steps_dir: features/steps\nprotect: []\n" <> models end
legacy = Kogen.Config.parse!(yaml.("models:\n  shape: {model: gpt-6.1-sol, effort: high}\n  build: {model: gpt-6.1-sol, effort: medium}\n  review: {model: gpt-6.1-sol, effort: high}\n"), "project.yaml")
role_keys = fn m -> Map.new(m, fn {k, v} -> {k, v |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()} end) end
tool = %{"type" => "function", "name" => "read_file", "description" => "Read", "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"], "additionalProperties" => false}, "strict" => true}
input = [%{"role" => "user", "content" => "contract"}]
legacy_body = JSON.encode!(Kogen.ChatGPT.request_body(%{model: "gpt-6.1-sol", effort: "high"}, "policy", input, [tool]))
fake = SgFake.start(%{responses: [{:items, [SgItems.reasoning("control1", opaque), SgItems.note("control1"), SgItems.call("control1", "read_file", %{"path" => "README.md"})]}, {:items, [SgItems.note("control2")]}]})
:persistent_term.put(:kogen_caller, %{env: %{"HOME" => home, "KOGEN_PROVIDER_URL" => fake.url}, cwd: home, install_root: nil})
role = %{model: "grok-4.7", effort: "high"}
r1 = Kogen.ChatGPT.respond(role, "policy", input, [tool])
call = Enum.find(r1.items, &(&1["type"] == "function_call"))
input2 = input ++ (Enum.map(r1.items, &Kogen.Shape.replay_item/1) |> Enum.reject(&is_nil/1)) ++ [Kogen.Shape.output(call, "# Fixture project\n")]
Kogen.ChatGPT.respond(role, "policy", input2, [tool])
native = SgFake.log(fake)
# Actual native image output and separately rendered builder/reviewer inputs qualify the
# observers even while SuperGrok config/login is missing. Identity overlays remain synthetic.
image = SgItems.png(1, 1)
File.write!(Path.join(home, "pixel.png"), image)
SgFake.reset(fake, %{responses: [
  {:items, [SgItems.reasoning("build1", opaque), SgItems.note("build1"), SgItems.call("sg_build_image", "view_image", %{"path" => "pixel.png"})]},
  {:items, [SgItems.note("build2")]},
  {:items, [SgItems.reasoning("review1", opaque), SgItems.note("review1"), SgItems.call("sg_review_read", "read_file", %{"path" => "README.md"})]},
  {:items, [SgItems.note("review2")]}
]})
finish = Map.put(tool, "name", "finish")
review_tool = Map.put(tool, "name", "submit_review")
image_tool = Map.put(tool, "name", "view_image")
build_tools = [tool, image_tool, finish]
review_tools = [tool, review_tool]
build_role = %{model: "grok-4.7", effort: "medium"}
b1 = Kogen.ChatGPT.respond(build_role, "policy", input, build_tools)
image_call = Enum.find(b1.items, &(&1["type"] == "function_call"))
image_output = Kogen.Image.read(%{"path" => "pixel.png"}, %{root: home})
true = is_list(image_output)
build_input = input ++ Enum.map(b1.items, &Kogen.Shape.replay_item/1) ++ [Kogen.Shape.output(image_call, image_output)]
Kogen.ChatGPT.respond(build_role, "policy", build_input, build_tools)
r1 = Kogen.ChatGPT.respond(role, "policy", input, review_tools)
review_call = Enum.find(r1.items, &(&1["type"] == "function_call"))
review_input = input ++ Enum.map(r1.items, &Kogen.Shape.replay_item/1) ++ [Kogen.Shape.output(review_call, "# Fixture project\n")]
Kogen.ChatGPT.respond(role, "policy", review_input, review_tools)
workflow_control = %{log: SgFake.log(fake), image: Base.encode64(image)}
device = %{"device_code" => "SG_FAKE_DEVICE_CODE_DO_NOT_LEAK", "user_code" => "SGK-2210", "verification_uri" => "https://accounts.x.ai/device",
  "verification_uri_complete" => "https://accounts.x.ai/device?user_code=SGK-2210", "expires_in" => 1800, "interval" => 1}
SgFake.reset(fake, %{device: device, answers: ["pending", "slow_down", %{}]})
:inets.start()
post = fn path, form ->
  {:ok, {{_, status, _}, _, body}} = :httpc.request(:post, {String.to_charlist(fake.url <> path), [{~c"accept", ~c"application/json"}, {~c"user-agent", ~c"kogen/007087b9"}],
    ~c"application/x-www-form-urlencoded", URI.encode_query(form)}, [], body_format: :binary)
  {status, JSON.decode!(body)}
end
{200, dev} = post.("/oauth2/device/code", %{"client_id" => "b1a00492-073a-47ea-816f-4c329264a828", "scope" => "openid profile email offline_access grok-cli:access api:access", "referrer" => "kogen"})
poll = fn poll, interval ->
  Process.sleep(interval * 1000)
  case post.("/oauth2/token", %{"grant_type" => "urn:ietf:params:oauth:grant-type:device_code", "device_code" => dev["device_code"], "client_id" => "b1a00492-073a-47ea-816f-4c329264a828"}) do
    {200, tok} -> tok
    {400, %{"error" => "slow_down"}} -> poll.(poll, interval + 5)
    {400, %{"error" => "authorization_pending"}} -> poll.(poll, interval)
  end
end
tok = poll.(poll, dev["interval"])
device_log = SgFake.log(fake)
issued_at = SgFake.get(fake, :issued_at)
SgFake.stop(fake)
stored = Path.join(creds, "supergrok.json")
File.write!(stored, "")
File.chmod!(stored, 0o600)
File.write!(stored, JSON.encode!(%{"client_id" => "b1a00492-073a-47ea-816f-4c329264a828", "referrer" => "kogen", "access_token" => tok["access_token"], "refresh_token" => tok["refresh_token"],
  "expires_at" => System.os_time(:second) + tok["expires_in"], "scope" => tok["scope"], "email" => "sg-user@example.invalid"}))
mode = fn p -> Bitwise.band(File.stat!(p).mode, 0o777) end
File.write!(receipt, JSON.encode!(%{legacy_keys: role_keys.(legacy.models), workers: legacy.shape_workers, legacy_body: legacy_body, native: native,
  workflow_control: workflow_control,
  device: %{log: device_log, issued_at: issued_at, device: device, version_id: "007087b9"},
  credential: %{text: File.read!(stored), file_mode: mode.(stored), dir_mode: mode.(creds), parent_mode: mode.(Path.join(home, ".kogen")), lock_exists: File.exists?(Path.join(creds, "supergrok.lock"))},
  written_at: System.os_time(:second)}))
File.rm_rf!(home)
`;

const DRIVER = String.raw`
Code.require_file(Path.expand("test/support/integration_helpers.ex", File.cwd!()))
` + FAKE + String.raw`
defmodule SuperGrokExercise do
  use ExUnit.Case
  alias Kogen.Integration.Helpers
  @moduletag timeout: 900_000
  @client "b1a00492-073a-47ea-816f-4c329264a828"
  @scope "openid profile email offline_access grok-cli:access api:access"
  @device %{"device_code" => "SG_FAKE_DEVICE_CODE_DO_NOT_LEAK", "user_code" => "SGK-2210", "verification_uri" => "https://accounts.x.ai/device",
    "verification_uri_complete" => "https://accounts.x.ai/device?user_code=SGK-2210", "expires_in" => 1800, "interval" => 1}
  @supergrok "  shape: {provider: supergrok, model: grok-4.7, effort: high}\n  build: {provider: supergrok, model: grok-4.7, effort: medium}\n  review: {provider: supergrok, model: grok-4.7, effort: high}\n"
  @legacy "  shape: {model: gpt-6.1-sol, effort: high}\n  build: {model: gpt-6.1-sol, effort: medium}\n  review: {model: gpt-6.1-sol, effort: high}\n"

  test "exercise the SuperGrok provider" do
    s = JSON.decode!(File.read!(System.fetch_env!("SG_INPUT")))
    mode = System.fetch_env!("SG_MODE")
    suite = Helpers.setup_suite!()
    fake = SgFake.start()
    try do
      version_id = suite.prefix |> Path.join("lib/kogen/lib/release/VERSION") |> File.read!() |> String.split() |> Enum.at(1)
      d = exercise(mode, %{suite: suite, fake: fake, s: s}) |> Map.merge(%{mode: mode, version_id: version_id})
      File.write!(System.fetch_env!("SG_RECEIPT"), JSON.encode!(d))
    after
      SgFake.stop(fake)
      Helpers.cleanup_suite(suite)
    end
  end

  # ---- Cases ----

  defp exercise("login", x) do
    c = context!(x, "login")
    borrowed!(c, x.s["borrowed"])
    SgFake.reset(x.fake, %{device: @device, answers: ["pending", "slow_down", %{}]})
    login = kogen(c, ["provider", "login", "supergrok"], %{"XAI_API_KEY" => x.s["borrowed"]})
    written_at = System.os_time(:second)
    before = length(SgFake.log(x.fake))
    list = kogen(c, ["provider", "list"])
    log = SgFake.log(x.fake)
    %{login: login, list: list, list_requests: length(log) - before, log: Enum.take(log, before), device: @device, issued_at: SgFake.get(x.fake, :issued_at),
      credential: credential(c), written_at: written_at, scan: scan(c, [login, list])}
  end

  defp exercise("login-refusals", x) do
    cases = [
      {"missing_scope", %{device: @device, answers: [%{"scope" => "openid profile email offline_access grok-cli:access"}]}},
      {"no_tokens", %{device: @device, answers: [%{"refresh_token" => nil}]}},
      {"denied", %{device: @device, answers: ["pending", "denied"]}},
      {"expired_token", %{device: @device, answers: ["expired"]}},
      {"deadline", %{device: Map.put(@device, "expires_in", 3), answers: []}},
      {"not_https", %{device: @device |> Map.put("verification_uri", "http://accounts.x.ai/device") |> Map.delete("verification_uri_complete"), answers: []}},
      {"incomplete", %{device: Map.delete(@device, "expires_in"), answers: []}},
      {"rejected", %{device: @device, device_status: 403, device_error: %{"error" => "invalid_client"}, answers: []}},
      {"cancel", %{device: @device, answers: []}},
      {"unknown_grok", %{device: @device, answers: []}},
      {"unknown_xai", %{device: @device, answers: []}}
    ]
    %{cases: Enum.map(cases, fn {name, cfg} -> refusal(x, name, cfg) end)}
  end

  defp exercise("workflow", x) do
    c = context!(x, "workflow")
    image = SgItems.png(1, 1)
    project!(c, @supergrok, %{"pixel.png" => image})
    seed_supergrok!(c, expired: true)
    borrowed!(c, x.s["borrowed"])
    o = x.s["opaque"]
    SgFake.reset(x.fake, %{sg_access: "SG_FAKE_ACCESS_0_DO_NOT_LEAK", sg_refresh: "SG_FAKE_REFRESH_DO_NOT_LEAK", responses: [
      {:items, [SgItems.reasoning("shape1", o), SgItems.note("shape1"), SgItems.call("sg_shape_read", "read_file", %{"path" => "README.md"})]},
      {:items, [SgItems.call("sg_shape_submit", "submit", %{"files" => package()})]},
      {:items, [SgItems.reasoning("refine1", o), SgItems.note("refine1"), SgItems.call("sg_refine_read", "read_file", %{"path" => "README.md"})]},
      {:items, [SgItems.call("sg_refine_submit", "submit_refinement", %{"files" => [hd(package())]})]},
      {:items, [SgItems.reasoning("build1", o), SgItems.note("build1"), SgItems.call("sg_build_image", "view_image", %{"path" => "pixel.png"})]},
      {:http, 401, %{"error" => %{"code" => "unauthorized", "message" => "token expired"}}},
      {:items, [SgItems.reasoning("build2", o), SgItems.call("sg_build_write", "write_file", %{"path" => "app.txt", "content" => "supergrok build\n"}), SgItems.call("sg_build_finish", "finish", %{"summary" => "done"})]},
      {:items, [SgItems.reasoning("review1", o), SgItems.note("review1"), SgItems.call("sg_review_read", "read_file", %{"path" => "app.txt"})]},
      {:items, [SgItems.call("sg_review_submit", "submit_review", %{"verdict" => "approve", "findings" => []})]}
    ]})
    env = %{"XAI_API_KEY" => x.s["borrowed"]}
    head = head(c)
    shape = kogen(c, ["intent", "shape", "fixture", request!(c)], env)
    refine = refine!(c, env)
    {approve, _} = approve!(c, env)
    build = kogen(c, ["intent", "build", "fixture"], env)
    refreshed_at = System.os_time(:second)
    usage = kogen(c, ["intent", "usage", "--json"])
    %{shape: shape, refine: refine, approve: approve, build: build, log: SgFake.log(x.fake), image: Base.encode64(image), credential: credential(c), refreshed_at: refreshed_at,
      new_commits: commits_since(c, head), trailer: trailer?(c), usage_rows: rows(usage), scan: scan(c, [shape, refine, approve, build, usage])}
  end

  defp exercise("limits", x) do
    big = SgItems.png(1, 1, 131_072)
    err = fn code, message -> %{"error" => %{"code" => code, "message" => message}} end
    cases = [
      {"s401_twice", @supergrok, [{:http, 401, err.("unauthorized", "rejected")}, {:http, 401, err.("unauthorized", "rejected")}], :valid},
      {"s402", @supergrok, [{:http, 402, err.("insufficient_credits", "credits exhausted")}], :valid},
      {"s403", @supergrok, [{:http, 403, err.("permission_denied", "oauth api access unavailable")}], :valid},
      {"s429", @supergrok, List.duplicate({:http, 429, err.("rate_limit_exceeded", "slow down")}, 3), :valid},
      {"model", @supergrok, [{:http, 400, err.("model_not_found", "no such model")}], :valid},
      {"budget", @supergrok, [{:items, for(n <- 1..3, do: SgItems.call("sg_budget_" <> Integer.to_string(n), "view_image", %{"path" => "big" <> Integer.to_string(n) <> ".png"}))}], :valid},
      {"bad_provider", "  shape: {provider: xai, model: grok-4.7, effort: high}\n", [], :valid},
      {"bad_model", "  shape: {provider: supergrok, model: grok-4.20-0309-reasoning, effort: high}\n", [], :valid},
      {"bad_effort", "  shape: {provider: supergrok, model: grok-4.7, effort: max}\n", [], :valid},
      {"not_signed_in", @supergrok, [], :absent},
      {"borrowed_file", @supergrok, [], :borrowed}
    ]
    results =
      Enum.map(cases, fn {name, models, script, login} ->
        c = context!(x, name)
        project!(c, models, if(name == "budget", do: %{"big1.png" => big, "big2.png" => big, "big3.png" => big}, else: %{}))
        Helpers.seed_credentials!(c)
        case login do
          :valid -> seed_supergrok!(c)
          :borrowed -> seed_supergrok!(c, referrer: "opencode")
          :absent -> :ok
        end
        borrowed!(c, x.s["borrowed"])
        SgFake.reset(x.fake, %{sg_access: "SG_FAKE_ACCESS_0_DO_NOT_LEAK", sg_refresh: "SG_FAKE_REFRESH_DO_NOT_LEAK", responses: script})
        r = kogen(c, ["intent", "shape", "fixture", request!(c)], %{"XAI_API_KEY" => x.s["borrowed"]})
        Map.merge(r, %{name: name, log: SgFake.log(x.fake), ctx: c})
      end)
    scans = Enum.map(results, &scan(&1.ctx, [&1]))
    %{cases: Enum.map(results, &Map.drop(&1, [:ctx])),
      scan: %{scanned: Enum.sum(Enum.map(scans, & &1.scanned)), detects_credential: Enum.all?(Enum.filter(scans, & &1.has_credential), & &1.detects_credential), hits: Enum.flat_map(scans, & &1.hits)}}
  end

  defp exercise("legacy", x) do
    yaml = fn models -> config(models) end
    keys = fn m -> Map.new(m, fn {k, v} -> {k, v |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()} end) end
    legacy = Kogen.Config.parse!(yaml.(@legacy), "project.yaml")
    workers = Kogen.Config.parse!(yaml.(@legacy) <> "shape_workers:\n  enabled: true\n  read: {model: gpt-6.1-sol, effort: low}\n  probe: {model: gpt-6.1-sol, effort: low}\n  draft: {model: gpt-6.1-sol, effort: medium}\n", "project.yaml")
    explicit =
      try do
        Kogen.Config.parse!(yaml.("  shape: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\n"), "project.yaml").models["shape"]
      rescue
        e -> %{error: Exception.message(e)}
      end
    tool = %{"type" => "function", "name" => "read_file", "description" => "Read", "parameters" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"], "additionalProperties" => false}, "strict" => true}
    legacy_body = JSON.encode!(Kogen.ChatGPT.request_body(%{model: "gpt-6.1-sol", effort: "high"}, "policy", [%{"role" => "user", "content" => "contract"}], [tool]))
    c = context!(x, "legacy")
    project!(c, @legacy, %{})
    Helpers.seed_credentials!(c)
    SgFake.reset(x.fake, %{responses: [
      {:items, [SgItems.call("legacy_shape_read", "read_file", %{"path" => "README.md"})]},
      {:items, [SgItems.call("legacy_shape_submit", "submit", %{"files" => package()})]},
      {:items, [SgItems.call("legacy_build_write", "write_file", %{"path" => "app.txt", "content" => "legacy build\n"})]},
      {:http, 500, %{"error" => %{"code" => "server_error", "message" => "outage"}}},
      {:http, 500, %{"error" => %{"code" => "server_error", "message" => "outage"}}},
      {:http, 500, %{"error" => %{"code" => "server_error", "message" => "outage"}}},
      {:items, [SgItems.call("legacy_build_write2", "write_file", %{"path" => "app.txt", "content" => "legacy build\n"}), SgItems.call("legacy_build_finish", "finish", %{"summary" => "done"})]},
      {:items, [SgItems.call("legacy_review_submit", "submit_review", %{"verdict" => "approve", "findings" => []})]}
    ]})
    list = kogen(c, ["provider", "list"])
    head = head(c)
    shape = kogen(c, ["intent", "shape", "fixture", request!(c)])
    approve!(c, %{})
    first = kogen(c, ["intent", "build", "fixture"])
    run = c.repo |> Path.join(".kogen/local/runs/*/checkpoint.json") |> Path.wildcard() |> List.first()
    checkpoint = checkpoint_facts(c, run, keys)
    config = Path.join(c.repo, ".kogen/project.yaml")
    original = File.read!(config)
    File.write!(config, String.replace(original, "  build: {model: gpt-6.1-sol, effort: medium}", "  build: {provider: supergrok, model: grok-4.7, effort: medium}"))
    saved = run && File.read!(run)
    n = length(SgFake.log(x.fake))
    edited = kogen(c, ["intent", "resume", run_id(run)])
    edited = Map.merge(edited, %{requests: length(SgFake.log(x.fake)) - n, checkpoint_unchanged: run != nil and File.read!(run) == saved})
    n = length(SgFake.log(x.fake))
    edited_build = kogen(c, ["intent", "build", "fixture"])
    edited_build = Map.put(edited_build, :requests, length(SgFake.log(x.fake)) - n)
    File.write!(config, original)
    resume = kogen(c, ["intent", "resume", run_id(run)])
    usage = kogen(c, ["intent", "usage", "--json"])
    %{legacy_keys: keys.(legacy.models), worker_keys: keys.(Map.take(workers.shape_workers, ["read", "probe", "draft"])), explicit_chatgpt: explicit,
      legacy_body: legacy_body, list: list, shape: shape, first_build: first, checkpoint: checkpoint, edited_resume: edited, edited_build: edited_build,
      resume: resume, new_commits: commits_since(c, head), log: SgFake.log(x.fake), usage_rows: rows(usage), older_rows: older_rows(c, run)}
  end

  defp refusal(x, name, cfg) do
    c = context!(x, name)
    earlier = seed_supergrok!(c, access: "SG_FAKE_ACCESS_EARLIER_DO_NOT_LEAK")
    SgFake.reset(x.fake, cfg)
    provider = case name do "unknown_grok" -> "grok"; "unknown_xai" -> "xai"; _ -> "supergrok" end
    r =
      if name == "cancel" do
        cancel(c, x.fake)
      else
        kogen(c, ["provider", "login", provider])
      end
    Map.merge(r, %{name: name, log: SgFake.log(x.fake), issued_at: SgFake.get(x.fake, :issued_at), device: cfg.device,
      earlier_before: earlier, earlier_after: File.read(Path.join(c.home, ".kogen/credentials/supergrok.json")) |> elem(1)})
  end

  defp cancel(c, fake) do
    started = System.monotonic_time(:millisecond)
    port = Helpers.start_kogen(c, ["provider", "login", "supergrok"])
    try do
      first = Helpers.await_output(port, "Code:", 15_000)
      wait_until(fn -> Enum.any?(SgFake.log(fake), &(&1.kind == "poll")) end, 15_000)
      signal_at = System.monotonic_time(:millisecond)
      Helpers.signal!(c, port, "INT")
      {out, status} = Helpers.await_exit(port, first, 20_000)
      Process.sleep(1_500)
      %{exit: status, stdout: out, stderr: "", started: started, ended: System.monotonic_time(:millisecond), signal_at: signal_at}
    rescue
      e -> %{exit: -1, stdout: Exception.message(e), stderr: "", started: started, ended: System.monotonic_time(:millisecond), signal_at: 0}
    end
  end

  # ---- Fixture helpers ----

  defp context!(x, name) do
    root = Path.join(x.suite.root, "case-" <> name <> "-" <> Integer.to_string(System.unique_integer([:positive])))
    [repo, home, tmp] = for d <- ~w(repo home tmp), do: Path.join(root, d)
    Enum.each([repo, home, tmp], &File.mkdir_p!/1)
    global = Path.join(home, ".gitconfig")
    File.write!(global, "")
    {:ok, ports} = Agent.start_link(fn -> [] end)
    env = %{"HOME" => home, "PATH" => x.suite.path, "ERL_FLAGS" => System.get_env("ERL_FLAGS") || "+S 2:2 +SDcpu 1 +SDio 1", "GIT_CONFIG_GLOBAL" => global,
      "GIT_CONFIG_NOSYSTEM" => "1", "KOGEN_PROVIDER_URL" => x.fake.url, "KOGEN_AUTH_URL" => x.fake.url, "KOGEN_NO_BROWSER" => "1", "TMPDIR" => tmp}
    %{suite: x.suite, root: root, repo: repo, home: home, tmp: tmp, env: env, ports: ports}
  end

  defp kogen(c, args, env \\ %{}) do
    err = Path.join(c.tmp, "stderr-" <> Integer.to_string(System.unique_integer([:positive])))
    started = System.monotonic_time(:millisecond)
    {out, status} = System.cmd("/bin/sh", ["-c", "exec \"$0\" \"$@\" 2>\"$SG_STDERR\"", c.suite.release | args], cd: c.repo, env: Helpers.env_for(c, Map.put(env, "SG_STDERR", err)))
    %{args: args, exit: status, stdout: out, stderr: File.read!(err), started: started, ended: System.monotonic_time(:millisecond)}
  end

  defp config(models) do
    "version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - name: present\n      run: 'test -f app.txt'\n  acceptance:\n" <>
      "    run: 'NODE_PATH=\"$KOGEN_CUCUMBER\" \"$KOGEN_NODE\" \"$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js\" --strict --require ''features/steps/*.js'' --format \"message:$KOGEN_ACCEPTANCE_REPORT\" \"$KOGEN_ACCEPTANCE_FEATURES\"'\n" <>
      "    steps_dir: 'features/steps'\nprotect: []\nmodels:\n" <> models
  end

  defp project!(c, models, files) do
    File.write!(Path.join(c.repo, "README.md"), "# Fixture project\n")
    File.write!(Path.join(c.repo, "app.txt"), "baseline\n")
    File.write!(Path.join(c.repo, ".gitignore"), ".kogen/local/\n")
    File.mkdir_p!(Path.join(c.repo, ".kogen"))
    File.mkdir_p!(Path.join(c.repo, "features/steps"))
    File.write!(Path.join(c.repo, "features/steps/README.md"), "Cucumber step definitions.\n")
    File.write!(Path.join(c.repo, ".kogen/project.yaml"), config(models))
    Enum.each(files, fn {p, b} -> File.write!(Path.join(c.repo, p), b) end)
    Helpers.git!(c, ["init", "-q", "--initial-branch=main"])
    Helpers.git!(c, ["config", "user.name", "Kogen Integration"])
    Helpers.git!(c, ["config", "user.email", "kogen-integration@example.invalid"])
    Helpers.git!(c, ["add", "-A"])
    Helpers.git!(c, ["commit", "-q", "-m", "fixture baseline"])
  end

  defp package do
    [
      %{"path" => ".kogen/intents/fixture/intent.md", "content" =>
        "# Preserve the fixture\n\nSlug: fixture\nModel: not applicable — no state for this fixture\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/fixture_steps.js\n\n" <>
        "app.txt stays readable.\n\n## Tests\n- the fixture stays readable: the acceptance scenario (existing)\n\n## Source comparison\n- addressed: source request keeps app.txt readable; contract Tests and acceptance.feature.\n\n## Feasibility\n- none\n"},
      %{"path" => ".kogen/intents/fixture/acceptance.feature", "content" => "Feature: Fixture\n  Scenario: The fixture is readable\n    Given the fixture is available\n    Then the fixture check passes\n"},
      %{"path" => "features/steps/fixture_steps.js", "content" =>
        "const { Given, Then } = require('@cucumber/cucumber');\nconst fs = require('node:fs');\nGiven('the fixture is available', function () { this.text = fs.readFileSync('app.txt', 'utf8'); });\nThen('the fixture check passes', function () { if (!this.text) throw new Error('app.txt is empty'); });\n"}
    ]
  end

  defp request!(c) do
    p = Path.join(c.root, "request.md")
    File.write!(p, "Keep app.txt readable.\n")
    p
  end

  defp refine!(c, env) do
    card = kogen(c, ["intent", "approve", "fixture"], env)
    case Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card.stdout) do
      [_, hash] ->
        correction = Path.join(c.root, "correction.md")
        File.write!(correction, "Validate this exact readable-fixture package without changing its scope.\n")
        kogen(c, ["intent", "refine", "fixture", hash, correction], env)
      _ -> Map.put(card, :exit, -1)
    end
  end

  defp approve!(c, env) do
    card = kogen(c, ["intent", "approve", "fixture"], env)
    case Regex.run(~r/SHA-256: ([0-9a-f]{64})/, card.stdout) do
      [_, hash] -> {kogen(c, ["intent", "approve", "fixture", hash], env), card}
      _ -> {Map.put(card, :exit, -1), card}
    end
  end

  defp seed_supergrok!(c, opts \\ []) do
    dir = Path.join(c.home, ".kogen/credentials")
    File.mkdir_p!(dir)
    File.chmod!(Path.dirname(dir), 0o700)
    File.chmod!(dir, 0o700)
    expires = if opts[:expired], do: System.os_time(:second) - 120, else: System.os_time(:second) + 86_400
    text = JSON.encode!(%{"client_id" => @client, "referrer" => opts[:referrer] || "kogen", "access_token" => opts[:access] || "SG_FAKE_ACCESS_0_DO_NOT_LEAK",
      "refresh_token" => "SG_FAKE_REFRESH_DO_NOT_LEAK", "expires_at" => expires, "scope" => @scope, "email" => "sg-user@example.invalid"})
    path = Path.join(dir, "supergrok.json")
    File.write!(path, text)
    File.chmod!(path, 0o600)
    text
  end

  # Other harnesses' stores and the API-key variable hold a marker no request may carry.
  defp borrowed!(c, marker) do
    for {p, v} <- [{".grok/auth.json", %{"access_token" => marker}}, {".local/share/opencode/auth.json", %{"xai" => %{"type" => "oauth", "access" => marker, "refresh" => marker}}},
                   {".pi/agent/auth.json", %{"xai" => %{"access" => marker, "refresh" => marker}}}] do
      file = Path.join(c.home, p)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, JSON.encode!(v))
    end
  end

  defp credential(c) do
    dir = Path.join(c.home, ".kogen/credentials")
    path = Path.join(dir, "supergrok.json")
    mode = fn p -> Bitwise.band(File.stat!(p).mode, 0o777) end
    if File.regular?(path),
      do: %{text: File.read!(path), file_mode: mode.(path), dir_mode: mode.(dir), parent_mode: mode.(Path.dirname(dir)), lock_exists: File.exists?(Path.join(dir, "supergrok.lock"))}
  end

  defp head(c), do: c |> Helpers.git!(["rev-parse", "HEAD"]) |> elem(0) |> String.trim()
  defp commits_since(c, head), do: c |> Helpers.git!(["rev-list", "--count", head <> "..HEAD"]) |> elem(0) |> String.trim() |> String.to_integer()
  defp trailer?(c), do: c |> Helpers.git!(["log", "-1", "--format=%B"]) |> elem(0) |> String.contains?("Kogen-Intent: fixture")
  defp run_id(nil), do: "missing"
  defp run_id(path), do: path |> Path.dirname() |> Path.basename()

  defp rows(%{exit: 0, stdout: out}) do
    case JSON.decode(out) do
      {:ok, %{"data" => %{"requests" => rows}}} -> Enum.map(rows, &Map.take(&1, ["provider", "outcome", "usage", "role", "phase"]))
      _ -> nil
    end
  end

  defp rows(_), do: nil

  defp checkpoint_facts(_c, nil, _keys), do: %{version: nil}

  defp checkpoint_facts(c, path, keys) do
    text = File.read!(path)
    case Kogen.Run.decode_checkpoint(text) do
      {:ok, _, saved} -> %{version: JSON.decode!(text)["version"], model_keys: keys.(saved.config.models), config_equal: saved.config == Kogen.Config.load!(c.repo)}
      other -> %{version: nil, error: inspect(other)}
    end
  rescue
    e -> %{version: nil, error: Exception.message(e)}
  end

  # A copy of actual retained run evidence without the new provider field stands for older records.
  defp older_rows(_c, nil), do: nil

  defp older_rows(c, checkpoint) do
    run = Path.dirname(checkpoint)
    other = Path.join(c.root, "older")
    target = Path.join([other, ".kogen/local/runs", Path.basename(run)])
    File.mkdir_p!(target)
    File.write!(Path.join(other, ".kogen/project.yaml"), "version: 1\n")
    File.write!(Path.join(other, ".gitignore"), ".kogen/local/\n")
    for f <- ["result.json"], File.exists?(Path.join(run, f)), do: File.cp!(Path.join(run, f), Path.join(target, f))
    stripped =
      run |> Path.join("log.jsonl") |> File.read!() |> String.split("\n", trim: true)
      |> Enum.map_join("", fn line ->
        case JSON.decode!(line) do
          %{"provider" => %{} = p} = e -> JSON.encode!(%{e | "provider" => Map.delete(p, "provider")}) <> "\n"
          e -> JSON.encode!(e) <> "\n"
        end
      end)
    File.write!(Path.join(target, "log.jsonl"), stripped)
    o = %{c | repo: other}
    Helpers.git!(o, ["init", "-q", "--initial-branch=main"])
    rows(kogen(o, ["intent", "usage", "--json"]))
  end

  # Secrets may live only in the credential file. Scanning that file itself must detect them.
  defp scan(c, results) do
    secret = ~r/SG_FAKE_(?:ACCESS|REFRESH|DEVICE_CODE|SIGNATURE)_/
    cred = Path.join(c.home, ".kogen/credentials/supergrok.json")
    files = for p <- Path.wildcard(Path.join(c.root, "**"), match_dot: true), File.regular?(p), p != cred, do: p
    hits = for p <- files, Regex.match?(secret, File.read!(p)), do: Path.relative_to(p, c.root)
    outs = for r <- results, Regex.match?(secret, (r[:stdout] || "") <> (r[:stderr] || "")), do: Enum.join(r[:args] || [], " ")
    has = File.regular?(cred)
    %{scanned: length(files), has_credential: has, detects_credential: has and Regex.match?(secret, File.read!(cred)), hits: hits ++ outs}
  end

  defp wait_until(f, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    Stream.repeatedly(fn -> f.() || (Process.sleep(20); System.monotonic_time(:millisecond) > deadline and raise("condition not reached")) end)
    |> Enum.find(& &1)
  end
end
`;

// ---- Controls and retained evidence ----

const PRECHECK = '/Users/almirsarajcic/Areas/Kogen/studio-work/provider-subscriptions-20261022/account-precheck';
function retainedEvidence() {
  const receipt = JSON.parse(fs.readFileSync(path.join(PRECHECK, 'receipt.json'), 'utf8'));
  const referrer = JSON.parse(fs.readFileSync(path.join(PRECHECK, 'kogen-referrer-preflight.json'), 'utf8'));
  assert.equal(receipt.run.exit, 0); assert.equal(receipt.run.model, 'xai/grok-4.7'); assert.equal(receipt.run.variant, 'low');
  assert.match(receipt.run.auth_route, /no API key/); assert.equal(receipt.tool_read_completed, true); assert.equal(receipt.final_contains_withheld_file_value, true);
  assert.deepEqual(referrer, { http_status: 200, own_referrer: 'kogen', device_code_returned: true, verification_uri_https: true, expires_in: 1800, no_token_polling_or_consent: true, code_not_retained: true });
  process.stdout.write('verified retained SuperGrok OpenCode read/replay and Kogen-referrer device answer; no account call\n');
}

function control() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-supergrok-control-'));
  try {
    const script = path.join(dir, 'control.exs'), receipt = path.join(dir, 'receipt.json');
    fs.writeFileSync(script, CONTROL);
    const r = spawnSync('mix', ['run', script], { cwd: ROOT, env: { ...process.env, SG_CONTROL_RECEIPT: receipt, SG_CONTROL_OPAQUE: OPAQUE }, encoding: 'utf8', timeout: 120000 });
    assert.equal(r.status, 0, (r.stdout || '') + (r.stderr || ''));
    return JSON.parse(fs.readFileSync(receipt, 'utf8'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// Pre-feature native requests turned into the contract's SuperGrok form (synthetic identity only).
function supergrokForm(native) {
  return native.map(r => ({ ...structuredClone(r), provider: 'supergrok', headers: { ...r.headers, authorization: 'Bearer SG_FAKE_ACCESS_0_DO_NOT_LEAK', 'user-agent': 'kogen/007087b9' } }));
}

function controlChecks(g) {
  const native = ofKind(g.native, 'responses');
  const good = {
    legacy_maps: same(g.legacy_keys, { build: ['effort', 'model'], review: ['effort', 'model'], shape: ['effort', 'model'] }) && same(g.workers, { enabled: false }),
    legacy_body: g.legacy_body === LEGACY_BODY,
    native_two: native.length === 2 && native.every(r => r.status === 200),
    legacy_headers: native.every(chatgptHeadersSame),
    native_replay: replayObserver(native.map(r => ({ ...r, owner: 'control' })), 'control'),
    wire: supergrokForm(native).every(r => wireObserver(r, { version_id: '007087b9' })),
    device: deviceObserver(g.device, 3) && ofKind(g.device.log, 'poll')[1].answer === 'slow_down',
    credential: credentialObserver(g.credential, { access: 'SG_FAKE_ACCESS_0_DO_NOT_LEAK', refresh: 'SG_FAKE_REFRESH_DO_NOT_LEAK', scope: SCOPE, email: 'sg-user@example.invalid', at: g.written_at, never: ['SG_FAKE_DEVICE_CODE_', 'SG_FAKE_SIGNATURE_'] }),
    usage: usageObserver([{ provider: 'supergrok', outcome: 'completed', usage: { input: 11, output: 7, cached: null, reasoning: null } }, { provider: 'supergrok', outcome: 'failed', usage: { input: null, output: null, cached: null, reasoning: null } }], 'supergrok', true),
    secrets: secretsObserver({ scanned: 3, detects_credential: true, hits: [] }),
    independent: independentObserver(g.workflow_control.log, { opaque: OPAQUE }),
    image: typedImageObserver(g.workflow_control.log, g.workflow_control.image),
    owner_replay: ['build', 'review'].every(owner => replayObserver(g.workflow_control.log, owner)),
    efforts: supergrokForm(g.workflow_control.log).every(r => wireObserver(r, { version_id: '007087b9', efforts: WORKFLOW_EFFORTS })),
  };
  return good;
}

function badCases(g) {
  const native = ofKind(g.native, 'responses');
  const sg = supergrokForm(native);
  const cases = [];
  const wire = (label, mutate) => { const r = structuredClone(sg[1]); mutate(r); cases.push([label, wireObserver(r, { version_id: '007087b9' })]); };
  cases.push(['pre-feature native grok-4.7 request uses ChatGPT token and no user-agent', native.some(r => wireObserver(r, { version_id: '007087b9' }))]);
  wire('chatgpt bearer', r => { r.provider = 'chatgpt'; r.headers.authorization = 'Bearer fake-integration-access-token'; });
  wire('missing user-agent', r => { delete r.headers['user-agent']; });
  wire('impersonated user-agent', r => { r.headers['user-agent'] = 'opencode/1.19.3'; });
  wire('grok cli header', r => { r.headers['x-xai-token-auth'] = 'xai-grok-cli'; });
  wire('conversation header', r => { r.headers['x-grok-conv-id'] = 'conversation'; });
  wire('cache options', r => { r.json.prompt_cache_options = { mode: 'implicit', ttl: '30m' }; });
  wire('cache breakpoint', r => { r.json.input[0].content = [{ type: 'input_text', text: 'contract', prompt_cache_breakpoint: { mode: 'explicit' } }]; });
  wire('developer policy', r => { r.json.input.unshift({ role: 'developer', content: [{ type: 'input_text', text: 'policy' }] }); });
  wire('stored', r => { r.json.store = true; });
  wire('unsupported effort', r => { r.json.reasoning.effort = 'max'; });
  wire('dropped effort', r => { delete r.json.reasoning; });
  wire('previous response', r => { r.json.previous_response_id = 'resp_1'; });
  wire('missing encrypted include', r => { r.json.include = []; });
  wire('other model', r => { r.json.model = 'grok-4.20-0309-reasoning'; });
  wire('oversized', r => { r.bytes = 524289; });
  const nativeReplay = native.map(r => ({ ...r, owner: 'control' }));
  const replay = (label, mutate) => { const l = structuredClone(nativeReplay); mutate(l); cases.push([label, replayObserver(l, 'control')]); };
  const find = (l, type) => l[1].json.input.find(i => i.type === type);
  replay('changed encrypted reasoning', l => { find(l, 'reasoning').encrypted_content += 'x'; });
  replay('dropped phase', l => { delete l[1].json.input.find(i => i.role === 'assistant').phase; });
  replay('dropped reasoning', l => { l[1].json.input = l[1].json.input.filter(i => i.type !== 'reasoning'); });
  replay('reordered replay', l => { const i = l[1].json.input; const a = i.findIndex(x => x.type === 'reasoning'); [i[a], i[a + 1]] = [i[a + 1], i[a]]; });
  replay('missing tool output', l => { l[1].json.input = l[1].json.input.filter(i => i.type !== 'function_call_output'); });
  replay('duplicated tool output', l => { l[1].json.input.push(structuredClone(find(l, 'function_call_output'))); });
  const device = (label, mutate) => { const d = structuredClone(g.device); mutate(d); cases.push([label, deviceObserver(d, 3)]); };
  const polls = d => ofKind(d.log, 'poll');
  device('other referrer', d => { ofKind(d.log, 'device')[0].form.referrer = 'opencode'; });
  device('extra scope', d => { ofKind(d.log, 'device')[0].form.scope += ' conversations:read'; });
  device('grok cli header', d => { d.log[0].headers['x-xai-token-auth'] = 'xai-grok-cli'; });
  device('first poll too early', d => { polls(d)[0].at = d.issued_at + 500; });
  device('slow_down ignored', d => { polls(d)[2].at = polls(d)[1].at + 1100; });
  device('poll after lifetime', d => { d.device.expires_in = 2; });
  device('extra poll field', d => { polls(d)[0].form.scope = SCOPE; });
  device('wrong device code', d => { polls(d)[1].form.device_code = 'other'; });
  device('hardcoded default interval mismatch', d => { d.device.interval = 3; });
  const cred = (label, mutate, expected = {}) => { const c = structuredClone(g.credential); mutate(c); cases.push([label, credentialObserver(c, { access: 'SG_FAKE_ACCESS_0_DO_NOT_LEAK', refresh: 'SG_FAKE_REFRESH_DO_NOT_LEAK', scope: SCOPE, email: 'sg-user@example.invalid', at: g.written_at, never: ['SG_FAKE_DEVICE_CODE_', 'SG_FAKE_SIGNATURE_'], ...expected })]); };
  const edit = (c, f) => { const v = JSON.parse(c.text); f(v); c.text = JSON.stringify(v); };
  cred('world-readable file', c => { c.file_mode = 0o644; });
  cred('open directory', c => { c.dir_mode = 0o755; });
  cred('lock left behind', c => { c.lock_exists = true; });
  cred('stored device code', c => edit(c, v => { v.device_code = 'SG_FAKE_DEVICE_CODE_DO_NOT_LEAK'; }));
  cred('stored id token', c => edit(c, v => { v.id_token = 'x.y.SG_FAKE_SIGNATURE_0'; }));
  cred('borrowed referrer', c => edit(c, v => { v.referrer = 'opencode'; }));
  cred('lost refresh on omitted rotation', c => edit(c, v => { delete v.refresh_token; }));
  cred('scope without api access', c => edit(c, v => { v.scope = 'openid profile email offline_access grok-cli:access'; }));
  cases.push(['legacy body byte changed', ('x' + LEGACY_BODY).slice(1).replace('"high"', '"medium"') === LEGACY_BODY]);
  cases.push(['legacy role gains provider key', same({ ...g.legacy_keys, shape: ['effort', 'model', 'provider'] }, { build: ['effort', 'model'], review: ['effort', 'model'], shape: ['effort', 'model'] })]);
  cases.push(['chatgpt route gains user-agent', chatgptHeadersSame({ ...native[0], headers: { ...native[0].headers, 'user-agent': 'kogen/007087b9' } })]);
  cases.push(['usage inferred chatgpt for supergrok', usageObserver([{ provider: 'chatgpt', outcome: 'completed', usage: { input: 11, output: 7, cached: null, reasoning: null } }], 'supergrok', true)]);
  cases.push(['usage zero for absent count', usageObserver([{ provider: 'supergrok', outcome: 'completed', usage: { input: 11, output: 7, cached: 0, reasoning: null } }], 'supergrok', true)]);
  cases.push(['vacuous secret scan', secretsObserver({ scanned: 3, detects_credential: false, hits: [] })]);
  cases.push(['secret found in log', secretsObserver({ scanned: 3, detects_credential: true, hits: ['repo/.kogen/local/runs/x/log.jsonl'] })]);
  const independent = (label, mutate) => { const l = structuredClone(g.workflow_control.log); mutate(l); cases.push([label, independentObserver(l, { opaque: OPAQUE })]); };
  independent('builder reasoning leaked into reviewer', l => { const item = l.find(r => r.owner === 'build').sent.find(i => i.type === 'reasoning'); l.find(r => r.owner === 'review').json.input.push(item); });
  independent('missing reviewer activity', l => { l.splice(0, l.length, ...l.filter(r => r.owner !== 'review')); });
  independent('reviewer never replays own reasoning', l => { for (const r of l.filter(r => r.owner === 'review')) r.json.input = r.json.input.filter(i => i.type !== 'reasoning'); });
  const image = (label, mutate) => { const l = structuredClone(g.workflow_control.log); mutate(l); cases.push([label, typedImageObserver(l, g.workflow_control.image)]); };
  const imageOutput = l => l.filter(r => r.owner === 'build').flatMap(r => r.json.input).find(i => i.call_id === 'call_sg_build_image' && i.type === 'function_call_output');
  image('image turned into text', l => { const o = imageOutput(l); o.output = JSON.stringify(o.output); });
  image('image URL bytes changed', l => { imageOutput(l).output[1].image_url += 'x'; });
  image('image metadata hash changed', l => { const b = imageOutput(l).output[0]; const m = JSON.parse(b.text); m.sha256 = 'wrong'; b.text = JSON.stringify(m); });
  image('typed blocks reordered', l => { imageOutput(l).output.reverse(); });
  image('typed output dropped', l => { for (const r of l) r.json.input = r.json.input.filter(i => i.call_id !== 'call_sg_build_image'); });
  const wrongEffort = supergrokForm(g.workflow_control.log).find(r => r.owner === 'build');
  wrongEffort.json.reasoning.effort = 'high';
  cases.push(['valid effort but wrong build role', wireObserver(wrongEffort, { version_id: '007087b9', efforts: WORKFLOW_EFFORTS })]);
  return cases;
}

if (require.main === module) {
  try {
    if (process.argv[2] === '--retained-evidence') retainedEvidence();
    else if (process.argv[2] === '--control' && ['good', 'bad'].includes(process.argv[3])) {
      const g = control();
      const good = controlChecks(g);
      const failed = Object.entries(good).filter(([, v]) => v !== true).map(([k]) => k);
      if (failed.length) throw new Error('known-good native/contract controls rejected: ' + failed.join(', ') + '; native header names ' + JSON.stringify(ofKind(g.native, 'responses').map(r => keys(r.headers))));
      if (process.argv[3] === 'good') process.stdout.write('accepted\n');
      else {
        const accepted = badCases(g).filter(([, v]) => v !== false).map(([k]) => k);
        if (accepted.length) throw new Error('counterexamples accepted: ' + accepted.join(', '));
        process.stdout.write('rejected\n'); process.exitCode = 1;
      }
    } else throw new Error('unknown control mode');
  } catch (e) { process.stderr.write(String(e && e.stack || e) + '\n'); process.exitCode = 2; }
} else {
  const { Given, When, Then, AfterAll } = require('@cucumber/cucumber');
  let work, archive;
  function execute(file, args, options = {}) {
    const r = spawnSync(file, args, { cwd: ROOT, env: process.env, encoding: 'utf8', timeout: 1200000, maxBuffer: 64 * 1024 * 1024, ...options });
    assert.equal(r.status, 0, (r.stdout || '') + (r.stderr || '') + (r.error || '')); return r.stdout;
  }
  function toolPath() {
    const dirs = [];
    for (const name of ['mix', 'erl', 'go', 'node', 'npm', 'python3']) {
      const r = spawnSync('mise', ['which', name], { cwd: ROOT, encoding: 'utf8' });
      if (r.status === 0 && r.stdout.trim()) dirs.push(path.dirname(r.stdout.trim()));
    }
    return [...new Set(dirs), process.env.PATH].join(path.delimiter);
  }
  Given('the SuperGrok qualification inputs:', function (json) { this.superGrokInputs = JSON.parse(json); });
  When('I exercise the SuperGrok provider {string}', { timeout: 1500000 }, function (mode) {
    if (!work) work = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-supergrok-'));
    if (!archive) archive = process.env.KOGEN_ARCHIVE;
    if (!archive) {
      const out = execute('/bin/sh', ['packaging/package.sh']);
      archive = out.split('\n').find(x => x.startsWith('/') && x.endsWith('.tar.gz')); assert.ok(archive && fs.existsSync(archive), out);
    }
    const dir = fs.mkdtempSync(path.join(work, 'case-'));
    try {
      const script = path.join(dir, 'supergrok_test.exs'), input = path.join(dir, 'input.json'), receipt = path.join(dir, 'receipt.json');
      fs.writeFileSync(script, DRIVER); fs.writeFileSync(input, JSON.stringify(this.superGrokInputs));
      execute('mix', ['test', script], { env: { ...process.env, PATH: toolPath(), KOGEN_ARCHIVE: archive, SG_INPUT: input, SG_MODE: mode, SG_RECEIPT: receipt } });
      assert.ok(fs.existsSync(receipt), 'the SuperGrok driver wrote no receipt');
      // Optional private diagnosis copy; receipts hold fake tokens only, never real credentials.
      if (process.env.KOGEN_SUPERGROK_EVIDENCE) fs.copyFileSync(receipt, path.join(process.env.KOGEN_SUPERGROK_EVIDENCE, mode + '.json'));
      this.superGrokObservations = qualify(JSON.parse(fs.readFileSync(receipt, 'utf8')), this.superGrokInputs);
      this.attach(JSON.stringify(this.superGrokObservations), 'application/json');
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  });
  Then('the SuperGrok observations include:', function (json) {
    for (const [key, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.superGrokObservations[key], expected, key + ': ' + JSON.stringify(this.superGrokObservations));
  });
  AfterAll(function () { if (work) fs.rmSync(work, { recursive: true, force: true }); });
}

module.exports = { qualify, deviceObserver, credentialObserver, wireObserver, replayObserver, independentObserver, typedImageObserver, usageObserver, secretsObserver };
