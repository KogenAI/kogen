// SuperGrok subscription acceptance (externally drafted helper; see the Intent's authoring origin).
// Scenarios drive an installed `kogen` (the one Go program) against one local fake that
// serves xAI-shaped device/token/Responses paths plus the ChatGPT token path. The fake records
// headers, forms, bodies and receipt times; the predicates below judge those records. The same
// predicates are qualified by `--control good|bad` on current native producers and mutations.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const { spawnSync } = require('node:child_process');
const H = require('./go_driver_support.js');

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
// Public ChatGPT routing uses the body key; no private-backend session header.
const CHATGPT_HEADER_NAMES = [...LEGACY_HEADER_NAMES].sort();
const SUPERGROK_HEADER_NAMES = [...LEGACY_HEADER_NAMES, 'user-agent'].sort();
const BODY_KEYS = ['include', 'input', 'instructions', 'model', 'prompt_cache_key', 'reasoning', 'store', 'stream', 'tool_choice', 'tools'];
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
  unknown_grok: { exit: 2, lines: ["kogen provider login: unknown provider 'grok' (supported: chatgpt, supergrok, opencode-go, anthropic, claude-code, openai-compatible)"], device: 0, polls: 0 },
  unknown_xai: { exit: 2, lines: ["kogen provider login: unknown provider 'xai' (supported: chatgpt, supergrok, opencode-go, anthropic, claude-code, openai-compatible)"], device: 0, polls: 0 },
};
const LIMITS = {
  s401_twice: { exit: 4, lines: ['provider/login: the SuperGrok sign-in was rejected; run kogen provider login supergrok'], responses: 2, refreshes: 1 },
  s402: { exit: 4, lines: ['provider/refused: SuperGrok reported a billing or credit limit (402', 'never falls back to paid API usage'], responses: 1, refreshes: 0 },
  s403: { exit: 4, lines: ['provider/refused: SuperGrok denied API access for this sign-in (403', 'never falls back to an API key or another provider'], responses: 1, refreshes: 0 },
  s429: { exit: 4, lines: ['provider/unavailable: SuperGrok did not answer after 3 attempts'], responses: 3, refreshes: 0 },
  model: { exit: 4, lines: ['provider/model_unavailable: grok-4.7 is not available to this SuperGrok account'], responses: 1, refreshes: 0 },
  budget: { exit: 1, lines: ['candidate/context_budget_exceeded'], responses: 1, refreshes: 0 },
  bad_provider: { exit: 3, lines: ['environment/project_config_invalid', 'models.shape.provider must be chatgpt, supergrok, opencode-go, anthropic or openai-compatible'], responses: 0, refreshes: 0 },
  // KOGEN-057 (go-core-migration "Open model selection"): no model or effort allowlist. The model and effort
  // are sent unchanged; SuperGrok's own refusal is one clear error naming the fix, with exactly one request.
  bad_model: { exit: 4, lines: ['provider/model_unavailable: grok-4.20-0309-reasoning is not available to this SuperGrok account', 'model grok-4.20-0309-reasoning with effort high was sent to SuperGrok unchanged and not retried', '.kogen/project.yaml'], responses: 1, refreshes: 0, wire: { model: 'grok-4.20-0309-reasoning', effort: 'high' } },
  bad_effort: { exit: 4, lines: ['provider/refused: SuperGrok refused the request: 400 reasoning effort max is not supported', 'model grok-4.7 with effort max was sent to SuperGrok unchanged and not retried', '.kogen/project.yaml'], responses: 1, refreshes: 0, wire: { model: 'grok-4.7', effort: 'max' } },
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

// SuperGrok Responses request: exact identity/header set and a provider-specific routing key body.
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
    assert.equal(typeof b.prompt_cache_key, 'string'); assert.ok(b.prompt_cache_key.length > 0);
    assert.equal(b.model, d.model || 'grok-4.7');
    if (d.effort) assert.equal(b.reasoning.effort, d.effort); else assert.ok(['low', 'medium', 'high', 'xhigh'].includes(b.reasoning.effort));
    assert.deepEqual(keys(b.reasoning), ['effort']);
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
  return holds(() => { assert.equal(r.provider, 'chatgpt'); assert.deepEqual(keys(r.headers), CHATGPT_HEADER_NAMES); assert.equal(typeof r.json.prompt_cache_key, 'string'); assert.ok(r.json.prompt_cache_key.length > 0 && r.json.prompt_cache_key.length <= 64); });
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
    o.list_both = d.list.exit === 0 && d.list.stdout === 'chatgpt: not signed in\nsupergrok: signed in (sg-user@example.invalid)\nopencode-go: not signed in\nanthropic: not signed in\n';
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
        assert.ok(responses.every(r => wireObserver(r, e.wire ? { ...d, ...e.wire } : d)));
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
    o.body_bytes_same = typeof d.legacy_body === 'string' && d.legacy_body.includes('"model":"gpt-6.1-sol"') && d.legacy_body === d.explicit_body;
    o.chatgpt_headers_same = responses.length >= 4 && responses.every(chatgptHeadersSame);
    o.chatgpt_token_only = responses.every(r => r.provider === 'chatgpt') && ofKind(d.log, 'refresh').length === 0 && ofKind(d.log, 'device').length === 0;
    o.list_both = d.list.exit === 0 && d.list.stdout === 'chatgpt: signed in (integration@example.invalid)\nsupergrok: not signed in\nopencode-go: not signed in\nanthropic: not signed in\n';
    // (The Go program writes version 4 checkpoints; its state keeps the legacy role maps without a provider.)
    o.checkpoint_legacy = d.checkpoint.version === 4 && same(d.checkpoint.model_keys, { build: ['effort', 'model'], review: ['effort', 'model'], shape: ['effort', 'model'] }) && d.checkpoint.config_equal === true;
    o.provider_edit_refused = d.edited_resume.exit !== 0 && ['baseline changed: .kogen/project.yaml', 'baseline/configuration changed'].some(x => d.edited_resume.stdout.includes(x)) && d.edited_resume.requests === 0 && d.edited_resume.checkpoint_unchanged === true;
    o.changed_since_approval = d.edited_build.exit === 1 && d.edited_build.stdout.includes('intent/changed_since_approval') && d.edited_build.requests === 0;
    o.resume_lands = d.resume.exit === 0 && d.new_commits === 1;
    o.usage_chatgpt = usageObserver(d.usage_rows, 'chatgpt', false);
    o.older_usage_null = Array.isArray(d.older_rows) && d.older_rows.length > 0 && d.older_rows.every(r => r.provider === null);
    return o;
  }
  throw new Error('unknown mode ' + d.mode);
}

// ---- The local xAI-shaped fake: device, token and Responses paths plus the ChatGPT token path ----

const png = (w, h, target) => {
  const zlib = require('node:zlib');
  const crc = buf => { let c = 0xffffffff; for (const byte of buf) { c ^= byte; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ ((c & 1) ? 0xedb88320 : 0); } return (c ^ 0xffffffff) >>> 0; };
  const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
  const chunk = (type, data) => { const body = Buffer.concat([Buffer.from(type), data]); return Buffer.concat([u32(data.length), body, u32(crc(body))]); };
  const raw = Buffer.concat(Array.from({ length: h }, () => Buffer.concat([Buffer.from([0]), Buffer.concat(Array.from({ length: w }, () => Buffer.from([200, 30, 30])))])));
  const ihdr = Buffer.concat([u32(w), u32(h), Buffer.from([8, 2, 0, 0, 0])]);
  const parts = [Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))];
  if (target) { const size = parts.reduce((n, b) => n + b.length, 0); parts.splice(3, 0, chunk('tEXt', Buffer.concat([Buffer.from('padding\0'), Buffer.alloc(target - size - 20, 120)]))); }
  return Buffer.concat(parts);
};
const SgItems = {
  reasoning: (label, opaque) => ({ type: 'reasoning', id: `rs_${label}`, encrypted_content: `${opaque}-${label}`, summary: [] }),
  note: label => ({ type: 'message', id: `msg_${label}`, role: 'assistant', phase: 'commentary', status: 'completed', content: [{ type: 'output_text', text: `Working note ${label}.` }] }),
  call: (label, name, args) => ({ type: 'function_call', id: `fc_${label}`, call_id: `call_${label}`, name, arguments: JSON.stringify(args), status: 'completed' }),
  png,
};
class SgFake {
  static defaults() {
    return { log: [], device: null, device_status: 200, device_error: {}, answers: [], grant: {}, responses: [], sg_access: null, sg_refresh: null, issued: 0, refreshes: 0, rotate: false, issued_at: null, chatgpt_access: 'fake-integration-access-token', usage: { input_tokens: 11, output_tokens: 7 } };
  }
  static grant(extra = {}) {
    const payload = Buffer.from(JSON.stringify({ email: 'sg-user@example.invalid' })).toString('base64url');
    return { access_token: 'SG_FAKE_ACCESS_0_DO_NOT_LEAK', refresh_token: 'SG_FAKE_REFRESH_DO_NOT_LEAK', expires_in: 3600, token_type: 'Bearer', scope: SCOPE, id_token: `fakeheader.${payload}.SG_FAKE_SIGNATURE_0`, ...extra };
  }
  constructor(cfg = {}) { this.s = { ...SgFake.defaults(), ...cfg }; this.sockets = new Set(); }
  async start() {
    this.server = http.createServer((req, res) => { this.serve(req, res).catch(() => { try { res.destroy(); } catch {} }); });
    this.server.on('connection', x => { this.sockets.add(x); x.once('close', () => this.sockets.delete(x)); });
    await new Promise(resolve => this.server.listen(0, '127.0.0.1', resolve));
    this.port = this.server.address().port; this.url = `http://127.0.0.1:${this.port}`;
    return this;
  }
  async stop() { for (const x of this.sockets) x.destroy(); await new Promise(resolve => this.server.close(resolve)); }
  reset(cfg) { const keep = { sg_access: this.s.sg_access, sg_refresh: this.s.sg_refresh }; this.s = { ...SgFake.defaults(), ...keep, ...cfg }; }
  get(key) { return this.s[key]; }
  log() { return this.s.log.slice(); }
  async serve(req, res) {
    const chunks = []; for await (const b of req) chunks.push(b);
    const body = Buffer.concat(chunks);
    const type = req.headers['content-type'] || '';
    let json = null;
    if (type.includes('json')) { try { json = JSON.parse(body.toString('utf8')); } catch { json = null; } }
    const rec = { at: Date.now(), method: req.method, path: req.url, headers: { ...req.headers }, bytes: body.length, form: type.includes('x-www-form-urlencoded') ? Object.fromEntries(new URLSearchParams(body.toString('utf8'))) : null, json };
    const action = this.route(rec);
    this.s.log.push(rec);
    this.send(res, action);
  }
  route(rec) {
    const s = this.s;
    if (rec.path === '/oauth2/device/code') {
      rec.kind = 'device'; s.issued_at = rec.at;
      return s.device_status === 200 ? { json: [200, s.device] } : { json: [s.device_status, s.device_error] };
    }
    if (rec.path === '/oauth2/token' && rec.form && rec.form.grant_type === DEVICE_GRANT) {
      const exact = same(rec.form, { grant_type: DEVICE_GRANT, device_code: (s.device || {}).device_code, client_id: CLIENT_ID });
      const answer = s.answers.length ? s.answers.shift() : 'pending';
      rec.kind = 'poll'; rec.answer = exact ? (typeof answer === 'object' ? 'grant' : answer) : 'invalid_request';
      if (!exact) return { json: [400, { error: 'invalid_request' }] };
      if (typeof answer === 'object') { const g = SgFake.grant(answer); s.sg_access = g.access_token; s.sg_refresh = g.refresh_token; return { json: [200, g] }; }
      if (answer === 'denied') return { json: [400, { error: 'access_denied' }] };
      if (answer === 'expired') return { json: [400, { error: 'expired_token' }] };
      if (answer === 'slow_down') return { json: [400, { error: 'slow_down' }] };
      return { json: [400, { error: 'authorization_pending' }] };
    }
    if (rec.path === '/oauth2/token' && rec.form) {
      rec.kind = 'refresh';
      const exact = same(rec.form, { grant_type: 'refresh_token', refresh_token: s.sg_refresh, client_id: CLIENT_ID });
      if (exact && typeof s.sg_refresh === 'string') {
        const n = s.refreshes + 1, access = `SG_FAKE_ACCESS_${n}_DO_NOT_LEAK`;
        const body = { access_token: access, expires_in: 3600, token_type: 'Bearer', ...(s.rotate ? { refresh_token: `SG_FAKE_REFRESH_ROTATED_${n}` } : {}) };
        s.refreshes = n; s.sg_access = access; s.sg_refresh = body.refresh_token ?? s.sg_refresh;
        return { json: [200, body] };
      }
      return { json: [400, { error: 'invalid_grant' }] };
    }
    if (rec.path === '/api/accounts/oauth/token') { rec.kind = 'chatgpt_auth'; return { json: [400, { error: 'invalid_grant' }] }; }
    if (rec.path === '/v1/responses') {
      const bearer = rec.headers.authorization;
      const provider = typeof s.sg_access === 'string' && bearer === `Bearer ${s.sg_access}` ? 'supergrok' : bearer === `Bearer ${s.chatgpt_access}` ? 'chatgpt' : 'unknown';
      const tools = ((rec.json || {}).tools || []).map(t => t.name);
      const owner = tools.includes('submit_review') ? 'review' : tools.includes('submit_refinement') ? 'refine' : tools.includes('submit') ? 'shape' : tools.includes('finish') ? 'build' : 'other';
      Object.assign(rec, { kind: 'responses', provider, owner, sent: [] });
      if (provider === 'unknown') { rec.status = 401; return { json: [401, { error: { code: 'unauthorized', message: 'unknown bearer' } }] }; }
      const action = s.responses.length ? s.responses.shift() : { http: [400, { error: { code: 'invalid_request', message: 'script exhausted' } }] };
      s.issued += 1;
      if (action.items) { rec.status = 200; rec.sent = action.items; return { sse: [action.items, s.issued, s.usage] }; }
      rec.status = action.http[0]; return { json: action.http };
    }
    rec.kind = 'other'; return { json: [404, { error: 'not found' }] };
  }
  send(res, action) {
    const write = (status, type, body) => { res.writeHead(status, { 'content-type': type, 'x-request-id': 'req-sg', 'content-length': Buffer.byteLength(body), connection: 'close' }); res.end(body); };
    if (action.json) return write(action.json[0], 'application/json', JSON.stringify(action.json[1]));
    const [items, n, usage] = action.sse;
    const events = items.flatMap((item, i) => [{ type: 'response.output_item.added', output_index: i, item: item.type === 'function_call' ? { ...item, arguments: '' } : item }, { type: 'response.output_item.done', output_index: i, item }]);
    events.push({ type: 'response.completed', response: { id: `resp_sg_${n}`, model: 'grok-4.7', usage } });
    write(200, 'text/event-stream', events.map(e => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(''));
  }
}
// The control's native producers: Kogen's own request builder, provider client, image tool and configuration parser,
// called from a tiny Go program against the fake (the observers below judge what the fake recorded).
const controlSource = String.raw`package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/project"
)

type m = map[string]any

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

// roleKeys is the set of fields a role actually sets (a role without a provider has no provider key).
func roleKeys(r project.Role) []string {
	keys := []string{}
	if r.Provider != "" {
		keys = append(keys, "provider")
	}
	if r.Model != "" {
		keys = append(keys, "model")
	}
	if r.Effort != "" {
		keys = append(keys, "effort")
	}
	sort.Strings(keys)
	return keys
}

func yaml(models string) string {
	return "version: 1\ncommands:\n  setup: []\n  fix: []\n  checks: []\n  acceptance:\n    run: 'true'\n    steps_dir: features/steps\nprotect: []\n" + models
}

func tool(name string) m {
	return m{"type": "function", "name": name, "description": "Read", "parameters": m{"type": "object", "properties": m{"path": m{"type": "string"}}, "required": []any{"path"}, "additionalProperties": false}, "strict": true}
}

func main() {
	mode, home, url, opaque := os.Args[1], os.Args[2], os.Args[3], os.Args[4]
	_ = opaque
	s := sys.NewWith([]string{"HOME=" + home, "KOGEN_PROVIDER_URL=" + url, "KOGEN_AUTH_URL=" + url}, home)
	client := provider.NewClient("kogen test (driver)")
	input := []any{m{"role": "user", "content": "contract"}}
	respond := func(role provider.Role, scope string, in, tools []any) *provider.Response {
		resp, err := client.Respond(s.Context(), s, provider.Request{Role: role, Instructions: "policy", Input: in, Tools: tools, Scope: scope}, nil)
		must(err)
		return resp
	}
	replay := func(items []map[string]any) []any {
		var out []any
		for _, it := range items {
			if r := tools.ReplayItem(it); r != nil {
				out = append(out, r)
			}
		}
		return out
	}
	callOf := func(items []map[string]any) map[string]any {
		for _, it := range items {
			if it["type"] == "function_call" {
				return it
			}
		}
		must(fmt.Errorf("no function call in the response"))
		return nil
	}
	switch mode {
	case "native":
		legacy, err := project.ParseConfig(yaml("models:\n  shape: {model: gpt-6.1-sol, effort: high}\n  build: {model: gpt-6.1-sol, effort: medium}\n  review: {model: gpt-6.1-sol, effort: high}\n"), "project.yaml")
		must(err)
		legacyKeys := m{}
		for role, r := range legacy.Models {
			legacyKeys[role] = roleKeys(r)
		}
		// The requirement: a role without a provider gives exactly the request of an explicit chatgpt role.
		omitted := legacy.Models["shape"]
		legacyBody := encode(client.Body(provider.Request{Role: provider.Role{Provider: omitted.Provider, Model: omitted.Model, Effort: omitted.Effort}, Instructions: "policy", Input: input, Tools: []any{tool("read_file")}, Scope: "legacy-body"}))
		explicitBody := encode(client.Body(provider.Request{Role: provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "policy", Input: input, Tools: []any{tool("read_file")}, Scope: "legacy-body"}))
		workers := m{"enabled": legacy.ShapeWorkers.Enabled}
		role := provider.Role{Provider: "chatgpt", Model: "grok-4.7", Effort: "high"}
		r1 := respond(role, "control-native", input, []any{tool("read_file")})
		call := callOf(r1.Items)
		input2 := append(append(append([]any{}, input...), replay(r1.Items)...), tools.OutputItem(call["call_id"], "# Fixture project\n"))
		respond(role, "control-native", input2, []any{tool("read_file")})
		fmt.Println(encode(m{"legacy_keys": legacyKeys, "workers": workers, "legacy_body": legacyBody, "explicit_body": explicitBody}))
	case "workflow":
		pixel := filepath.Join(home, "pixel.png")
		_ = pixel
		finish, reviewTool, imageTool := tool("finish"), tool("submit_review"), tool("view_image")
		buildTools := []any{tool("read_file"), imageTool, finish}
		reviewTools := []any{tool("read_file"), reviewTool}
		buildRole := provider.Role{Provider: "chatgpt", Model: "grok-4.7", Effort: "medium"}
		role := provider.Role{Provider: "chatgpt", Model: "grok-4.7", Effort: "high"}
		b1 := respond(buildRole, "control-build", input, buildTools)
		imageCall := callOf(b1.Items)
		tl := &tools.Tools{Root: home, Enabled: []string{"view_image"}}
		out, err := tl.Run("view_image", m{"path": "pixel.png"})
		must(err)
		if !out.Typed() {
			must(fmt.Errorf("view_image did not return typed pixels: %s", out.Text))
		}
		buildInput := append(append(append([]any{}, input...), replay(b1.Items)...), tools.OutputItem(imageCall["call_id"], out.Value()))
		respond(buildRole, "control-build", buildInput, buildTools)
		r1 := respond(role, "control-review", input, reviewTools)
		reviewCall := callOf(r1.Items)
		reviewInput := append(append(append([]any{}, input...), replay(r1.Items)...), tools.OutputItem(reviewCall["call_id"], "# Fixture project\n"))
		respond(role, "control-review", reviewInput, reviewTools)
		fmt.Println("{}")
	case "legacy-config":
		// The configuration facts of the legacy scenario: role keys, worker keys, an explicit chatgpt role, the saved shape.
		base := yaml("models:\n  shape: {model: gpt-6.1-sol, effort: high}\n  build: {model: gpt-6.1-sol, effort: medium}\n  review: {model: gpt-6.1-sol, effort: high}\n")
		legacy, err := project.ParseConfig(base, "project.yaml")
		must(err)
		withWorkers, err := project.ParseConfig(base+"shape_workers:\n  enabled: true\n  read: {model: gpt-6.1-sol, effort: low}\n  probe: {model: gpt-6.1-sol, effort: low}\n  draft: {model: gpt-6.1-sol, effort: medium}\n", "project.yaml")
		must(err)
		explicit := m{}
		if c, err := project.ParseConfig(yaml("models:\n  shape: {provider: chatgpt, model: gpt-6.1-sol, effort: high}\n"), "project.yaml"); err != nil {
			explicit["error"] = err.Error()
		} else {
			r := c.Models["shape"]
			explicit = m{"model": r.Model, "effort": r.Effort, "provider": r.Provider}
		}
		keys := func(roles map[string]project.Role) m {
			out := m{}
			for name, r := range roles {
				out[name] = roleKeys(r)
			}
			return out
		}
		workerKeys := m{}
		for name, r := range withWorkers.ShapeWorkers.Roles {
			if strings.Contains("read probe draft", name) {
				workerKeys[name] = roleKeys(r)
			}
		}
		// The requirement: a role without a provider gives exactly the request of an explicit chatgpt role.
		omitted := legacy.Models["shape"]
		legacyBody := encode(client.Body(provider.Request{Role: provider.Role{Provider: omitted.Provider, Model: omitted.Model, Effort: omitted.Effort}, Instructions: "policy", Input: input, Tools: []any{tool("read_file")}, Scope: "legacy-body"}))
		explicitBody := encode(client.Body(provider.Request{Role: provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "policy", Input: input, Tools: []any{tool("read_file")}, Scope: "legacy-body"}))
		fmt.Println(encode(m{"legacy_keys": keys(legacy.Models), "worker_keys": workerKeys, "explicit_chatgpt": explicit, "legacy_body": legacyBody, "explicit_body": explicitBody}))
	case "load-config":
		c, err := project.LoadConfig(home)
		must(err)
		models := m{}
		for name, r := range c.Models {
			models[name] = roleKeys(r)
		}
		raw, err := json.Marshal(c)
		must(err)
		fmt.Println(encode(m{"model_keys": models, "config": json.RawMessage(raw)}))
	}
}
`;
// ---- The control: native producers plus one reference device client ----

const DEVICE = { device_code: 'SG_FAKE_DEVICE_CODE_DO_NOT_LEAK', user_code: 'SGK-2210', verification_uri: 'https://accounts.x.ai/device', verification_uri_complete: 'https://accounts.x.ai/device?user_code=SGK-2210', expires_in: 1800, interval: 1 };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function postForm(url, pathName, form) {
  return new Promise((resolve, reject) => {
    const body = new URLSearchParams(form).toString();
    const req = http.request(url + pathName, { method: 'POST', headers: { accept: 'application/json', 'user-agent': 'kogen/007087b9', 'content-type': 'application/x-www-form-urlencoded', 'content-length': Buffer.byteLength(body) } }, res => {
      const chunks = []; res.on('data', b => chunks.push(b)); res.on('end', () => resolve([res.statusCode, JSON.parse(Buffer.concat(chunks).toString('utf8'))]));
    });
    req.on('error', reject); req.end(body);
  });
}
async function controlAsync() {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'sg-control-home-')));
  const fake = await new SgFake().start();
  try {
    const creds = path.join(home, '.kogen/credentials');
    fs.mkdirSync(creds, { recursive: true }); fs.chmodSync(path.join(home, '.kogen'), 0o700); fs.chmodSync(creds, 0o700);
    fs.writeFileSync(path.join(creds, 'chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_fake-integration-client', access_token: 'fake-integration-access-token', refresh_token: 'fake-integration-refresh-token', expires_at: Math.floor(Date.now() / 1000) + 86400, scope: 'openid', email: 'integration@example.invalid' }));
    fs.writeFileSync(path.join(home, 'pixel.png'), SgItems.png(1, 1));
    const driver = await H.goDriver('supergrok-control', controlSource);
    const call = async mode => { const r = await driver([mode, home, fake.url, OPAQUE]); assert.equal(r.code, 0, r.out); return JSON.parse(r.out.trim().split('\n').at(-1)); };
    fake.reset({ responses: [{ items: [SgItems.reasoning('control1', OPAQUE), SgItems.note('control1'), SgItems.call('control1', 'read_file', { path: 'README.md' })] }, { items: [SgItems.note('control2')] }] });
    const native = await call('native');
    const nativeLog = fake.log();
    // Actual native image output and separately rendered builder/reviewer inputs qualify the observers even while SuperGrok
    // config/login is missing. Identity overlays remain synthetic.
    const image = SgItems.png(1, 1);
    fake.reset({ responses: [
      { items: [SgItems.reasoning('build1', OPAQUE), SgItems.note('build1'), SgItems.call('sg_build_image', 'view_image', { path: 'pixel.png' })] },
      { items: [SgItems.note('build2')] },
      { items: [SgItems.reasoning('review1', OPAQUE), SgItems.note('review1'), SgItems.call('sg_review_read', 'read_file', { path: 'README.md' })] },
      { items: [SgItems.note('review2')] },
    ] });
    await call('workflow');
    const workflowControl = { log: fake.log(), image: image.toString('base64') };
    fake.reset({ device: DEVICE, answers: ['pending', 'slow_down', {}] });
    const poll = async interval => {
      await sleep(interval * 1000);
      const [status, tok] = await postForm(fake.url, '/oauth2/token', { grant_type: DEVICE_GRANT, device_code: dev.device_code, client_id: CLIENT_ID });
      if (status === 200) return tok;
      if (status === 400 && tok.error === 'slow_down') return poll(interval + 5);
      if (status === 400 && tok.error === 'authorization_pending') return poll(interval);
      throw new Error(`unexpected device answer ${status} ${JSON.stringify(tok)}`);
    };
    const [dstatus, dev] = await postForm(fake.url, '/oauth2/device/code', { client_id: CLIENT_ID, scope: SCOPE, referrer: 'kogen' });
    assert.equal(dstatus, 200);
    const tok = await poll(dev.interval);
    const deviceLog = fake.log(), issuedAt = fake.get('issued_at');
    const stored = path.join(creds, 'supergrok.json');
    fs.writeFileSync(stored, ''); fs.chmodSync(stored, 0o600);
    fs.writeFileSync(stored, JSON.stringify({ client_id: CLIENT_ID, referrer: 'kogen', access_token: tok.access_token, refresh_token: tok.refresh_token, expires_at: Math.floor(Date.now() / 1000) + tok.expires_in, scope: tok.scope, email: 'sg-user@example.invalid' }));
    const mode = p => fs.statSync(p).mode & 0o777;
    return { legacy_keys: native.legacy_keys, workers: native.workers, legacy_body: native.legacy_body, explicit_body: native.explicit_body, native: nativeLog, workflow_control: workflowControl, device: { log: deviceLog, issued_at: issuedAt, device: DEVICE, version_id: '007087b9' },
      credential: { text: fs.readFileSync(stored, 'utf8'), file_mode: mode(stored), dir_mode: mode(creds), parent_mode: mode(path.join(home, '.kogen')), lock_exists: fs.existsSync(path.join(creds, 'supergrok.lock')) }, written_at: Math.floor(Date.now() / 1000) };
  } finally { await fake.stop(); fs.rmSync(home, { recursive: true, force: true }); }
}

// ---- The scenario driver: the installed `kogen` against the fake ----

const SUPERGROK_MODELS = '  shape: {provider: supergrok, model: grok-4.7, effort: high}\n  build: {provider: supergrok, model: grok-4.7, effort: medium}\n  review: {provider: supergrok, model: grok-4.7, effort: high}\n';
const LEGACY_MODELS = '  shape: {model: gpt-6.1-sol, effort: high}\n  build: {model: gpt-6.1-sol, effort: medium}\n  review: {model: gpt-6.1-sol, effort: high}\n';
let caseSerial = 0;
function context(x, name) {
  const root = path.join(x.suite.root, `case-${name}-${++caseSerial}`);
  const [repo, home, tmp] = ['repo', 'home', 'tmp'].map(d => path.join(root, d));
  for (const d of [repo, home, tmp]) fs.mkdirSync(d, { recursive: true });
  const global = path.join(home, '.gitconfig'); fs.writeFileSync(global, '');
  const env = { HOME: home, PATH: x.suite.path, GIT_CONFIG_GLOBAL: global, GIT_CONFIG_NOSYSTEM: '1', KOGEN_PROVIDER_URL: x.fake.url, KOGEN_AUTH_URL: x.fake.url, KOGEN_NO_BROWSER: '1', TMPDIR: tmp };
  return { suite: x.suite, root, repo, home, tmp, env, started: new Set(), server: { providerRequests: () => [], stop: async () => {} } };
}
// One kogen command with its stdout and stderr kept apart.
async function kogen(c, args, extra = {}) {
  const started = Date.now();
  const r = await new Promise((resolve, reject) => {
    const child = require('node:child_process').spawn(c.suite.release, args, { cwd: c.repo, env: H.envFor(c, extra), stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    const out = [], err = [];
    const timer = setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 5 * H.MIN);
    child.stdout.on('data', b => out.push(b)); child.stderr.on('data', b => err.push(b));
    child.on('error', reject);
    child.on('close', code => { clearTimeout(timer); try { process.kill(-child.pid, 'SIGKILL'); } catch {} resolve({ code, stdout: Buffer.concat(out).toString('utf8'), stderr: Buffer.concat(err).toString('utf8') }); });
  });
  return { args, exit: r.code, stdout: r.stdout, stderr: r.stderr, started, ended: Date.now() };
}
const configYaml = models => `version: 1\ncommands:\n  setup: []\n  fix: []\n  checks:\n    - name: present\n      run: 'test -f app.txt'\n  acceptance:\n    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require ''features/steps/*.js'' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'\n    steps_dir: 'features/steps'\nprotect: []\nmodels:\n${models}`;
async function project(c, models, files) {
  const put = (p, text) => { const f = path.join(c.repo, p); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };
  put('README.md', '# Fixture project\n'); put('app.txt', 'baseline\n'); put('.gitignore', '.kogen/local/\n');
  put('features/steps/README.md', 'Cucumber step definitions.\n'); put('.kogen/project.yaml', configYaml(models));
  for (const [p, b] of Object.entries(files)) { fs.mkdirSync(path.dirname(path.join(c.repo, p)), { recursive: true }); fs.writeFileSync(path.join(c.repo, p), b); }
  for (const a of [['init', '-q', '--initial-branch=main'], ['config', 'user.name', 'Kogen Integration'], ['config', 'user.email', 'kogen-integration@example.invalid'], ['add', '-A'], ['commit', '-q', '-m', 'fixture baseline']]) await H.gitBang(c, a);
}
const pack = () => [
  { path: '.kogen/intents/fixture/intent.md', content: '# Preserve the fixture\n\nSlug: fixture\nModel: not applicable — no state for this fixture\nAcceptance:\n- .kogen/intents/fixture/acceptance.feature\n- features/steps/fixture_steps.js\n\napp.txt stays readable.\n\n## Tests\n- the fixture stays readable: the acceptance scenario (existing)\n\n## Source comparison\n- addressed: source request keeps app.txt readable; contract Tests and acceptance.feature.\n\n## Feasibility\n- none\n' },
  { path: '.kogen/intents/fixture/acceptance.feature', content: 'Feature: Fixture\n  Scenario: The fixture is readable\n    Given the fixture is available\n    Then the fixture check passes\n' },
  { path: 'features/steps/fixture_steps.js', content: "const { Given, Then } = require('@cucumber/cucumber');\nconst fs = require('node:fs');\nGiven('the fixture is available', function () { this.text = fs.readFileSync('app.txt', 'utf8'); });\nThen('the fixture check passes', function () { if (!this.text) throw new Error('app.txt is empty'); });\n" },
];
const requestFile = c => { const p = path.join(c.root, 'request.md'); fs.writeFileSync(p, 'Keep app.txt readable.\n'); return p; };
async function refine(c, env) {
  const card = await kogen(c, ['intent', 'approve', 'fixture'], env);
  const m = /SHA-256: ([0-9a-f]{64})/.exec(card.stdout);
  if (!m) return { ...card, exit: -1 };
  const correction = path.join(c.root, 'correction.md');
  fs.writeFileSync(correction, 'Validate this exact readable-fixture package without changing its scope.\n');
  return kogen(c, ['intent', 'refine', 'fixture', m[1], correction], env);
}
async function approveAll(c, env) {
  const card = await kogen(c, ['intent', 'approve', 'fixture'], env);
  const m = /SHA-256: ([0-9a-f]{64})/.exec(card.stdout);
  return m ? [await kogen(c, ['intent', 'approve', 'fixture', m[1]], env), card] : [{ ...card, exit: -1 }, card];
}
function seedSupergrok(c, opts = {}) {
  const dir = path.join(c.home, '.kogen/credentials');
  fs.mkdirSync(dir, { recursive: true }); fs.chmodSync(path.dirname(dir), 0o700); fs.chmodSync(dir, 0o700);
  const expires = Math.floor(Date.now() / 1000) + (opts.expired ? -120 : 86400);
  const text = JSON.stringify({ client_id: CLIENT_ID, referrer: opts.referrer || 'kogen', access_token: opts.access || 'SG_FAKE_ACCESS_0_DO_NOT_LEAK', refresh_token: 'SG_FAKE_REFRESH_DO_NOT_LEAK', expires_at: expires, scope: SCOPE, email: 'sg-user@example.invalid' });
  const file = path.join(dir, 'supergrok.json');
  fs.writeFileSync(file, text); fs.chmodSync(file, 0o600);
  return text;
}
// Other harnesses' stores and the API-key variable hold a marker no request may carry.
function borrowed(c, marker) {
  for (const [p, v] of [['.grok/auth.json', { access_token: marker }], ['.local/share/opencode/auth.json', { xai: { type: 'oauth', access: marker, refresh: marker } }], ['.pi/agent/auth.json', { xai: { access: marker, refresh: marker } }]]) {
    const file = path.join(c.home, p); fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(v));
  }
}
function credential(c) {
  const dir = path.join(c.home, '.kogen/credentials'), file = path.join(dir, 'supergrok.json');
  const mode = p => fs.statSync(p).mode & 0o777;
  if (fs.existsSync(file) && fs.statSync(file).isFile()) return { text: fs.readFileSync(file, 'utf8'), file_mode: mode(file), dir_mode: mode(dir), parent_mode: mode(path.dirname(dir)), lock_exists: fs.existsSync(path.join(dir, 'supergrok.lock')) };
  return null;
}
const headOf = c => H.git(c, ['rev-parse', 'HEAD']);
const commitsSince = async (c, head) => Number(await H.git(c, ['rev-list', '--count', `${head}..HEAD`]));
const trailer = async c => (await H.git(c, ['log', '-1', '--format=%B'])).includes('Kogen-Intent: fixture');
const runId = file => file ? path.basename(path.dirname(file)) : 'missing';
function usageRows(r) {
  if (r.exit !== 0) return null;
  try { const rows = JSON.parse(r.stdout).data.requests; return rows.map(x => Object.fromEntries(['provider', 'outcome', 'usage', 'role', 'phase'].filter(k => k in x).map(k => [k, x[k]]))); } catch { return null; }
}
// Secrets may live only in the credential file. Scanning that file itself must detect them.
function scan(c, results) {
  const secret = /SG_FAKE_(?:ACCESS|REFRESH|DEVICE_CODE|SIGNATURE)_/;
  const cred = path.join(c.home, '.kogen/credentials/supergrok.json');
  const files = H.listFiles(c.root).filter(p => p !== cred);
  const hits = files.filter(p => secret.test(fs.readFileSync(p).toString('latin1'))).map(p => path.relative(c.root, p));
  const outs = results.filter(r => secret.test((r.stdout || '') + (r.stderr || ''))).map(r => (r.args || []).join(' '));
  const has = fs.existsSync(cred);
  return { scanned: files.length, has_credential: has, detects_credential: has && secret.test(fs.readFileSync(cred, 'utf8')), hits: [...hits, ...outs] };
}
async function waitUntil(test, ms) { const end = Date.now() + ms; while (!test()) { if (Date.now() > end) throw new Error('condition not reached'); await sleep(20); } }
async function cancelLogin(c, fake) {
  const started = Date.now();
  const proc = H.startKogen(c, ['provider', 'login', 'supergrok']);
  try {
    const first = await proc.awaitOutput('Code:', 15000);
    await waitUntil(() => fake.log().some(r => r.kind === 'poll'), 15000);
    const signalAt = Date.now();
    proc.signal('SIGINT');
    const { out, code } = await proc.awaitExit(20000);
    await sleep(1500);
    return { exit: code, stdout: out, stderr: '', started, ended: Date.now(), signal_at: signalAt, _first: first };
  } catch (e) { return { exit: -1, stdout: String(e.message), stderr: '', started, ended: Date.now(), signal_at: 0 }; }
}
async function refusal(x, name, cfg) {
  const c = context(x, name);
  const earlier = seedSupergrok(c, { access: 'SG_FAKE_ACCESS_EARLIER_DO_NOT_LEAK' });
  x.fake.reset(cfg);
  const provider = { unknown_grok: 'grok', unknown_xai: 'xai' }[name] || 'supergrok';
  const r = name === 'cancel' ? await cancelLogin(c, x.fake) : await kogen(c, ['provider', 'login', provider]);
  const file = path.join(c.home, '.kogen/credentials/supergrok.json');
  return { ...r, name, log: x.fake.log(), issued_at: x.fake.get('issued_at'), device: cfg.device, earlier_before: earlier, earlier_after: fs.readFileSync(file, 'utf8') };
}
const without = (o, k) => { const c = { ...o }; delete c[k]; return c; };
const modes = {
  async login(x) {
    const c = context(x, 'login');
    borrowed(c, x.s.borrowed);
    x.fake.reset({ device: DEVICE, answers: ['pending', 'slow_down', {}] });
    const login = await kogen(c, ['provider', 'login', 'supergrok'], { XAI_API_KEY: x.s.borrowed });
    const writtenAt = Math.floor(Date.now() / 1000);
    const before = x.fake.log().length;
    const list = await kogen(c, ['provider', 'list']);
    const log = x.fake.log();
    return { login, list, list_requests: log.length - before, log: log.slice(0, before), device: DEVICE, issued_at: x.fake.get('issued_at'), credential: credential(c), written_at: writtenAt, scan: scan(c, [login, list]) };
  },
  async 'login-refusals'(x) {
    const cases = [
      ['missing_scope', { device: DEVICE, answers: [{ scope: 'openid profile email offline_access grok-cli:access' }] }],
      ['no_tokens', { device: DEVICE, answers: [{ refresh_token: null }] }],
      ['denied', { device: DEVICE, answers: ['pending', 'denied'] }],
      ['expired_token', { device: DEVICE, answers: ['expired'] }],
      ['deadline', { device: { ...DEVICE, expires_in: 3 }, answers: [] }],
      ['not_https', { device: without({ ...DEVICE, verification_uri: 'http://accounts.x.ai/device' }, 'verification_uri_complete'), answers: [] }],
      ['incomplete', { device: without(DEVICE, 'expires_in'), answers: [] }],
      ['rejected', { device: DEVICE, device_status: 403, device_error: { error: 'invalid_client' }, answers: [] }],
      ['cancel', { device: DEVICE, answers: [] }],
      ['unknown_grok', { device: DEVICE, answers: [] }],
      ['unknown_xai', { device: DEVICE, answers: [] }],
    ];
    const out = [];
    for (const [name, cfg] of cases) out.push(await refusal(x, name, cfg));
    return { cases: out };
  },
  async workflow(x) {
    const c = context(x, 'workflow');
    const image = SgItems.png(1, 1);
    await project(c, SUPERGROK_MODELS, { 'pixel.png': image });
    seedSupergrok(c, { expired: true });
    borrowed(c, x.s.borrowed);
    const o = x.s.opaque;
    x.fake.reset({ sg_access: 'SG_FAKE_ACCESS_0_DO_NOT_LEAK', sg_refresh: 'SG_FAKE_REFRESH_DO_NOT_LEAK', responses: [
      { items: [SgItems.reasoning('shape1', o), SgItems.note('shape1'), SgItems.call('sg_shape_read', 'read_file', { path: 'README.md' })] },
      { items: [SgItems.call('sg_shape_submit', 'submit', { files: pack() })] },
      { items: [SgItems.reasoning('refine1', o), SgItems.note('refine1'), SgItems.call('sg_refine_read', 'read_file', { path: 'README.md' })] },
      { items: [SgItems.call('sg_refine_submit', 'submit_refinement', { files: [pack()[0]] })] },
      { items: [SgItems.reasoning('build1', o), SgItems.note('build1'), SgItems.call('sg_build_image', 'view_image', { path: 'pixel.png' })] },
      { http: [401, { error: { code: 'unauthorized', message: 'token expired' } }] },
      { items: [SgItems.reasoning('build2', o), SgItems.call('sg_build_write', 'write_file', { path: 'app.txt', content: 'supergrok build\n' }), SgItems.call('sg_build_finish', 'finish', { summary: 'done' })] },
      { items: [SgItems.reasoning('review1', o), SgItems.note('review1'), SgItems.call('sg_review_read', 'read_file', { path: 'app.txt' })] },
      { items: [SgItems.call('sg_review_submit', 'submit_review', { verdict: 'approve', findings: [] })] },
    ] });
    const env = { XAI_API_KEY: x.s.borrowed };
    const head = await headOf(c);
    const shape = await kogen(c, ['intent', 'shape', 'fixture', requestFile(c)], env);
    const refined = await refine(c, env);
    const [approve] = await approveAll(c, env);
    const build = await kogen(c, ['intent', 'build', 'fixture'], env);
    const refreshedAt = Math.floor(Date.now() / 1000);
    const usage = await kogen(c, ['intent', 'usage', '--json']);
    return { shape, refine: refined, approve, build, log: x.fake.log(), image: image.toString('base64'), credential: credential(c), refreshed_at: refreshedAt, new_commits: await commitsSince(c, head), trailer: await trailer(c), usage_rows: usageRows(usage), scan: scan(c, [shape, refined, approve, build, usage]) };
  },
  async limits(x) {
    const big = SgItems.png(1, 1, 131072);
    const err = (code, message) => ({ error: { code, message } });
    const cases = [
      ['s401_twice', SUPERGROK_MODELS, [{ http: [401, err('unauthorized', 'rejected')] }, { http: [401, err('unauthorized', 'rejected')] }], 'valid'],
      ['s402', SUPERGROK_MODELS, [{ http: [402, err('insufficient_credits', 'credits exhausted')] }], 'valid'],
      ['s403', SUPERGROK_MODELS, [{ http: [403, err('permission_denied', 'oauth api access unavailable')] }], 'valid'],
      ['s429', SUPERGROK_MODELS, Array(3).fill({ http: [429, err('rate_limit_exceeded', 'slow down')] }), 'valid'],
      ['model', SUPERGROK_MODELS, [{ http: [400, err('model_not_found', 'no such model')] }], 'valid'],
      ['budget', SUPERGROK_MODELS, [{ items: [1, 2, 3].map(n => SgItems.call(`sg_budget_${n}`, 'view_image', { path: `big${n}.png` })) }], 'valid'],
      ['bad_provider', '  shape: {provider: xai, model: grok-4.7, effort: high}\n', [], 'valid'],
      ['bad_model', '  shape: {provider: supergrok, model: grok-4.20-0309-reasoning, effort: high}\n', [{ http: [400, err('model_not_found', 'no such model')] }], 'valid'],
      ['bad_effort', '  shape: {provider: supergrok, model: grok-4.7, effort: max}\n', [{ http: [400, err('invalid_argument', 'reasoning effort max is not supported')] }], 'valid'],
      ['not_signed_in', SUPERGROK_MODELS, [], 'absent'],
      ['borrowed_file', SUPERGROK_MODELS, [], 'borrowed'],
    ];
    const results = [];
    for (const [name, models, script, login] of cases) {
      const c = context(x, name);
      await project(c, models, name === 'budget' ? { 'big1.png': big, 'big2.png': big, 'big3.png': big } : {});
      H.seedCredentials(c);
      if (login === 'valid') seedSupergrok(c); else if (login === 'borrowed') seedSupergrok(c, { referrer: 'opencode' });
      borrowed(c, x.s.borrowed);
      x.fake.reset({ sg_access: 'SG_FAKE_ACCESS_0_DO_NOT_LEAK', sg_refresh: 'SG_FAKE_REFRESH_DO_NOT_LEAK', responses: script });
      const r = await kogen(c, ['intent', 'shape', 'fixture', requestFile(c)], { XAI_API_KEY: x.s.borrowed });
      results.push({ ...r, name, log: x.fake.log(), ctx: c });
    }
    const scans = results.map(r => scan(r.ctx, [r]));
    return { cases: results.map(r => without(r, 'ctx')), scan: { scanned: scans.reduce((n, s) => n + s.scanned, 0), detects_credential: scans.filter(s => s.has_credential).every(s => s.detects_credential), hits: scans.flatMap(s => s.hits) } };
  },
  async legacy(x) {
    const configDriver = await H.goDriver('supergrok-control', controlSource);
    const facts = async (mode, dir) => { const r = await configDriver([mode, dir, x.fake.url, OPAQUE]); assert.equal(r.code, 0, r.out); return JSON.parse(r.out.trim().split('\n').at(-1)); };
    const parsed = await facts('legacy-config', x.suite.root);
    const c = context(x, 'legacy');
    await project(c, LEGACY_MODELS, {});
    H.seedCredentials(c);
    const call = (label, name, args) => SgItems.call(label, name, args);
    x.fake.reset({ responses: [
      { items: [call('legacy_shape_read', 'read_file', { path: 'README.md' })] },
      { items: [call('legacy_shape_submit', 'submit', { files: pack() })] },
      { items: [call('legacy_build_write', 'write_file', { path: 'app.txt', content: 'legacy build\n' })] },
      ...Array(3).fill({ http: [500, { error: { code: 'server_error', message: 'outage' } }] }),
      { items: [call('legacy_build_write2', 'write_file', { path: 'app.txt', content: 'legacy build\n' }), call('legacy_build_finish', 'finish', { summary: 'done' })] },
      { items: [call('legacy_review_submit', 'submit_review', { verdict: 'approve', findings: [] })] },
    ] });
    const list = await kogen(c, ['provider', 'list']);
    const head = await headOf(c);
    const shape = await kogen(c, ['intent', 'shape', 'fixture', requestFile(c)]);
    await approveAll(c, {});
    const first = await kogen(c, ['intent', 'build', 'fixture']);
    const runFile = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/checkpoint.json'))[0];
    const normKeys = role => Object.entries(role).filter(([, v]) => v !== '').map(([k]) => k.toLowerCase()).sort();
    let checkpoint = { version: null };
    if (runFile) {
      const doc = JSON.parse(fs.readFileSync(runFile, 'utf8'));
      const fresh = await facts('load-config', c.repo);
      checkpoint = { version: doc.version, model_keys: Object.fromEntries(Object.entries(doc.state.config.Models).map(([k, v]) => [k, normKeys(v)])), config_equal: JSON.stringify(sortKeys(doc.state.config)) === JSON.stringify(sortKeys(fresh.config)) };
    }
    const configFile = path.join(c.repo, '.kogen/project.yaml');
    const original = fs.readFileSync(configFile, 'utf8');
    fs.writeFileSync(configFile, original.replace('  build: {model: gpt-6.1-sol, effort: medium}', '  build: {provider: supergrok, model: grok-4.7, effort: medium}'));
    const saved = runFile && fs.readFileSync(runFile, 'utf8');
    let n = x.fake.log().length;
    let edited = await kogen(c, ['intent', 'resume', runId(runFile)]);
    edited = { ...edited, requests: x.fake.log().length - n, checkpoint_unchanged: !!runFile && fs.readFileSync(runFile, 'utf8') === saved };
    n = x.fake.log().length;
    let editedBuild = await kogen(c, ['intent', 'build', 'fixture']);
    editedBuild = { ...editedBuild, requests: x.fake.log().length - n };
    fs.writeFileSync(configFile, original);
    const resume = await kogen(c, ['intent', 'resume', runId(runFile)]);
    const usage = await kogen(c, ['intent', 'usage', '--json']);
    return { legacy_keys: parsed.legacy_keys, worker_keys: parsed.worker_keys, explicit_chatgpt: parsed.explicit_chatgpt, legacy_body: parsed.legacy_body, explicit_body: parsed.explicit_body, list, shape, first_build: first, checkpoint, edited_resume: edited, edited_build: editedBuild, resume, new_commits: await commitsSince(c, head), log: x.fake.log(), usage_rows: usageRows(usage), older_rows: await olderRows(c, runFile) };
  },
};
const sortKeys = x => Array.isArray(x) ? x.map(sortKeys) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sortKeys(x[k])])) : x;
// A copy of actual retained run evidence without the new provider field stands for older records.
async function olderRows(c, checkpoint) {
  if (!checkpoint) return null;
  const run = path.dirname(checkpoint), other = path.join(c.root, 'older');
  const target = path.join(other, '.kogen/local/runs', path.basename(run));
  fs.mkdirSync(target, { recursive: true });
  fs.writeFileSync(path.join(other, '.kogen/project.yaml'), 'version: 1\n');
  fs.writeFileSync(path.join(other, '.gitignore'), '.kogen/local/\n');
  if (fs.existsSync(path.join(run, 'result.json'))) fs.copyFileSync(path.join(run, 'result.json'), path.join(target, 'result.json'));
  const stripped = fs.readFileSync(path.join(run, 'log.jsonl'), 'utf8').split('\n').filter(Boolean).map(line => {
    const e = JSON.parse(line);
    if (e.provider && typeof e.provider === 'object') { const p = { ...e.provider }; delete p.provider; return JSON.stringify({ ...e, provider: p }) + '\n'; }
    return JSON.stringify(e) + '\n';
  }).join('');
  fs.writeFileSync(path.join(target, 'log.jsonl'), stripped);
  const o = { ...c, repo: other };
  await H.gitBang(o, ['init', '-q', '--initial-branch=main']);
  return usageRows(await kogen(o, ['intent', 'usage', '--json']));
}
async function exerciseMode(mode, s) {
  const suite = await H.setupSuite();
  const fake = await new SgFake().start();
  try {
    const versionId = fs.readFileSync(path.join(suite.install, 'lib/VERSION'), 'utf8').split(/\s+/)[1];
    const d = await modes[mode]({ suite, fake, s });
    return { ...d, mode, version_id: versionId };
  } finally { await fake.stop(); H.cleanupSuite(suite); }
}
const PRECHECK = '/Users/almirsarajcic/Areas/Kogen/studio-work/provider-subscriptions-20261022/account-precheck';
function retainedEvidence() {
  const receipt = JSON.parse(fs.readFileSync(path.join(PRECHECK, 'receipt.json'), 'utf8'));
  const referrer = JSON.parse(fs.readFileSync(path.join(PRECHECK, 'kogen-referrer-preflight.json'), 'utf8'));
  assert.equal(receipt.run.exit, 0); assert.equal(receipt.run.model, 'xai/grok-4.7'); assert.equal(receipt.run.variant, 'low');
  assert.match(receipt.run.auth_route, /no API key/); assert.equal(receipt.tool_read_completed, true); assert.equal(receipt.final_contains_withheld_file_value, true);
  assert.deepEqual(referrer, { http_status: 200, own_referrer: 'kogen', device_code_returned: true, verification_uri_https: true, expires_in: 1800, no_token_polling_or_consent: true, code_not_retained: true });
  process.stdout.write('verified retained SuperGrok OpenCode read/replay and Kogen-referrer device answer; no account call\n');
}

// Pre-feature native requests turned into the contract's SuperGrok form (synthetic identity only).
function supergrokForm(native) {
  return native.map(r => ({ ...structuredClone(r), provider: 'supergrok', json: {...r.json, prompt_cache_key: 'synthetic-control-session'}, headers: Object.fromEntries(Object.entries({ ...r.headers, authorization: 'Bearer SG_FAKE_ACCESS_0_DO_NOT_LEAK', 'user-agent': 'kogen/007087b9' }).filter(([k]) => k !== 'session-id')) }));
}

function controlChecks(g) {
  const native = ofKind(g.native, 'responses');
  const good = {
    legacy_maps: same(g.legacy_keys, { build: ['effort', 'model'], review: ['effort', 'model'], shape: ['effort', 'model'] }) && same(g.workers, { enabled: false }),
    legacy_body: typeof g.legacy_body === 'string' && g.legacy_body.includes('"model":"gpt-6.1-sol"') && g.legacy_body === g.explicit_body,
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
  cases.push(['chatgpt route gains private session header', chatgptHeadersSame({ ...native[0], headers: { ...native[0].headers, 'session-id': native[0].json.prompt_cache_key } })]);
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


function control() { return controlAsync(); }
if (require.main === module) {
  (async () => {
    try {
      if (process.argv[2] === '--retained-evidence') retainedEvidence();
      else if (process.argv[2] === '--control' && ['good', 'bad'].includes(process.argv[3])) {
        const g = await control();
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
  })();
} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  Given('the SuperGrok qualification inputs:', function (json) { this.superGrokInputs = JSON.parse(json); });
  When('I exercise the SuperGrok provider {string}', { timeout: 1500000 }, async function (mode) {
    const receipt = await exerciseMode(mode, this.superGrokInputs);
    this.superGrokObservations = qualify(JSON.parse(JSON.stringify(receipt)), this.superGrokInputs);
    await this.attach(JSON.stringify(this.superGrokObservations), 'application/json');
  });
  Then('the SuperGrok observations include:', function (json) {
    for (const [key, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.superGrokObservations[key], expected, key + ': ' + JSON.stringify(this.superGrokObservations));
  });
}

module.exports = { qualify, deviceObserver, credentialObserver, wireObserver, replayObserver, independentObserver, typedImageObserver, usageObserver, secretsObserver };
