'use strict';
// Prompt-cache fake and observers for the Go migration harness (KOGEN-054, Prompt caching).
//
// A local HTTP server speaks one provider's real wire (ChatGPT/SuperGrok Responses SSE, OpenCode
// Go chat completions, Anthropic Messages SSE) and behaves like a real prefix cache: it reports
// cached tokens in the provider's own usage fields, computed from the bytes the request actually
// shares with an earlier request of the same routing key. It never grants reuse for anything the
// client did not keep byte-identical, so a client that moves its front, rewrites history or fails
// to send its routing key sees low or zero cached tokens and the observers name the violation.
//
// Cache model (documented here once, used by both the server and the control checks):
//   - Responses and chat wires: the cache key is ChatGPT body prompt_cache_key (with the header
//     session-id), SuperGrok body prompt_cache_key, OpenCode Go header x-opencode-session. The
//     previous request of that key is remembered by its received bytes. cached = floor(floor(common
//     prefix bytes / 4) / 128) * 128 tokens; input = floor(bytes / 4) tokens.
//   - Anthropic: there is no key. Entries are the stripped request prefixes (cache_control markers
//     removed, strings normalised to text blocks) ending at each marked block. A request reads the
//     longest remembered entry that is a byte prefix of it (cache_read) and writes from there up to
//     its newest marker (cache_creation); input_tokens is the rest, so total = input + creation +
//     read. Token counts use the same bytes/4 rounded down to 128 rule.
//   - OpenAI-compatible (KOGEN-057) is the same non-streaming Chat Completions wire at
//     /v1/chat/completions (the role's base_url is <fake>/v1; KOGEN_PROVIDER_URL is not used), with no
//     routing key at all: a strict host refuses unknown fields, so any vendor routing field or header
//     (prompt_cache_key, x-opencode-session, session-id, x-grok-conv-id) is a violation. Conversations are
//     told apart by their frozen front and first message, as Anthropic's are; the cached tokens are
//     computed from the bytes shared with the previous request of the conversation and reported as
//     usage.prompt_tokens_details.cached_tokens.
//   - ChatGPT answers HTTP 400 when a body carries prompt_cache_options or prompt_cache_breakpoint
//     (the old policy fields the caching contract removes); that is what a cache refusal looks like.
const http = require('node:http');
const crypto = require('node:crypto');
const { isDeepStrictEqual: same } = require('node:util');

const PATHS = { chatgpt: '/v1/responses', supergrok: '/v1/responses', 'opencode-go': '/inference/go/openai/v1/chat/completions', anthropic: '/v1/messages', 'openai-compatible': '/v1/chat/completions' };
// The chat wire (OpenCode Go and OpenAI-compatible) and the providers that have no routing key of their own.
const chatWire = p => p === 'opencode-go' || p === 'openai-compatible';
const keyless = p => p === 'anthropic' || p === 'openai-compatible';
// Where a request names a vendor routing key (never allowed for a generic host).
const VENDOR_HEADERS = ['x-opencode-session', 'session-id', 'x-grok-conv-id'];
function vendorRouting(headers, body) {
  return [...VENDOR_HEADERS.filter(h => headers[h] !== undefined).map(h => 'header ' + h), ...(body && typeof body === 'object' && body.prompt_cache_key !== undefined ? ['body prompt_cache_key'] : [])];
}
const BLOCK = 128;
const tokens = bytes => Math.floor(bytes / 4);
const cachedTokens = bytes => Math.floor(tokens(bytes) / BLOCK) * BLOCK;
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
const canon = v => JSON.stringify(sorted(v));
function sorted(v) {
  if (Array.isArray(v)) return v.map(sorted);
  if (v && typeof v === 'object') return Object.fromEntries(Object.keys(v).sort().map(k => [k, sorted(v[k])]));
  return v;
}
function strip(v) {
  if (Array.isArray(v)) return v.map(strip);
  if (v && typeof v === 'object') return Object.fromEntries(Object.entries(v).filter(([k]) => k !== 'cache_control').map(([k, x]) => [k, strip(x)]));
  return v;
}
// Object keys that are cache controls (never words in the text of a prompt): where they appear.
function cacheControlKeys(v, at = '', out = []) {
  if (Array.isArray(v)) v.forEach((x, i) => cacheControlKeys(x, at + '[' + i + ']', out));
  else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) {
    if (/^(prompt_cache_options|prompt_cache_breakpoint|cache_control)$/.test(k)) out.push(at + '.' + k);
    cacheControlKeys(x, at + '.' + k, out);
  }
  return out;
}
function blocks(content) { return typeof content === 'string' ? [{ type: 'text', text: content }] : content; }
function common(a, b) { const n = Math.min(a.length, b.length); let i = 0; while (i < n && a[i] === b[i]) i++; return i; }

// ---- What a request is, per wire ----

function view(provider, headers, raw) {
  const body = JSON.parse(raw.toString('utf8'));
  const v = { body, headers, cacheControls: cacheControlKeys(body) };
  v.hasCacheControls = v.cacheControls.length > 0;
  if (provider === 'anthropic') {
    const messages = strip(body.messages || []).map(m => ({ ...m, content: blocks(m.content) }));
    const front = canon([strip(body.system ?? null), strip(body.tools ?? null)]);
    v.conv = messages; v.first = canon(messages[0] ?? null); v.front = front;
    v.key = sha(front + v.first).slice(0, 16); v.headerKey = undefined;
    v.tools = (body.tools || []).map(t => !!t.cache_control);
    v.system = (Array.isArray(body.system) ? body.system : []).map(b => !!b.cache_control);
    v.messageMarks = (body.messages || []).map(m => Array.isArray(m.content) ? m.content.map(b => !!b.cache_control) : []);
  } else if (chatWire(provider)) {
    v.conv = body.messages || []; v.first = canon(v.conv.find(m => m.role !== 'system') ?? null);
    v.front = canon([v.conv[0] ?? null, body.tools ?? null]);
    v.key = headers['x-opencode-session']; v.bodyKey = body.prompt_cache_key;
    if (provider === 'openai-compatible') { v.key = sha(v.front + v.first).slice(0, 16); v.vendor = vendorRouting(headers, body); v.authorization = headers.authorization; }
  } else {
    v.conv = body.input || []; v.first = canon(v.conv[0] ?? null);
    v.front = canon([body.instructions ?? null, body.tools ?? null]);
    v.key = body.prompt_cache_key; v.headerKey = headers['session-id'];
  }
  return v;
}

// ---- The cache ----

class PrefixCache {
  constructor(provider) { this.provider = provider; this.last = new Map(); this.entries = new Map(); }
  // Reported usage for a request that is accepted (not refused), remembering it afterwards.
  usage(v, raw) {
    if (this.provider !== 'anthropic') {
      const prev = this.last.get(v.key);
      const cached = prev ? cachedTokens(common(prev, raw)) : 0;
      this.last.set(v.key, raw);
      return { input: Math.max(tokens(raw.length), cached), cached };
    }
    const pieces = [], marked = [];
    const add = (piece, mark) => { pieces.push(JSON.stringify(piece)); marked.push(!!mark); };
    (v.body.tools || []).forEach(t => add(['tool', strip(t)], t.cache_control));
    (Array.isArray(v.body.system) ? v.body.system : [{ type: 'text', text: v.body.system }]).forEach(b => add(['system', strip(b)], b.cache_control));
    (v.body.messages || []).forEach(m => blocks(m.content).forEach(b => add([m.role, strip(b)], b.cache_control)));
    const offsets = []; let at = 0; for (const p of pieces) { at += Buffer.byteLength(p); offsets.push(at); }
    const stream = Buffer.from(pieces.join(''));
    let read = 0;
    for (const [, e] of this.entries) if (e.length > read && stream.length >= e.length && stream.subarray(0, e.length).equals(e)) read = e.length;
    const newest = offsets.filter((o, i) => marked[i]).at(-1) ?? 0;
    const total = tokens(stream.length), readT = cachedTokens(read), upTo = Math.max(cachedTokens(newest), readT);
    for (const [i, o] of offsets.entries()) if (marked[i]) { const e = stream.subarray(0, o); this.entries.set(sha(e), Buffer.from(e)); }
    return { cached: readT, write: upTo - readT, input: total, uncached: Math.max(total - upTo, 0) };
  }
}

// ---- Scripted answers (what the provider says), per wire ----

function call(provider, name, args, label, i) {
  return { name, args, id: provider === 'anthropic' ? `toolu_${label}_${i}` : `call_${label}_${i}` };
}
// Output items in the form a conversation replays them (so the next request must start with them).
function output(provider, calls, label) {
  if (provider === 'anthropic') {
    return [{ role: 'assistant', content: [{ type: 'thinking', thinking: '', signature: 'SYNTHETIC_SIGNATURE_' + label }, ...calls.map(c => ({ type: 'tool_use', id: c.id, name: c.name, input: c.args }))] }];
  }
  if (provider === 'openai-compatible') {
    return [{ role: 'assistant', content: null, tool_calls: calls.map(c => ({ id: c.id, type: 'function', function: { name: c.name, arguments: JSON.stringify(c.args) } })) }];
  }
  if (provider === 'opencode-go') {
    return [{ role: 'assistant', content: null, reasoning: 'SYNTHETIC_REASONING_' + label, reasoning_details: [{ type: 'reasoning.text', index: 0, text: 'SYNTHETIC_REASONING_' + label }], tool_calls: calls.map(c => ({ id: c.id, type: 'function', function: { name: c.name, arguments: JSON.stringify(c.args) } })) }];
  }
  return [{ type: 'reasoning', id: 'rs_' + label, encrypted_content: 'SYNTHETIC_ENCRYPTED_' + label, summary: [] },
    ...calls.map((c, i) => ({ type: 'function_call', id: `fc_${label}_${i}`, call_id: c.id, name: c.name, arguments: JSON.stringify(c.args), status: 'completed' }))];
}
function sse(type, payload) { return `event: ${type}\ndata: ${JSON.stringify({ type, ...payload })}\n\n`; }
function answer(provider, model, id, items, usage) {
  if (chatWire(provider)) {
    return { type: 'application/json', body: JSON.stringify({ id, object: 'chat.completion', model, choices: [{ index: 0, message: items[0], finish_reason: 'tool_calls' }], usage: { prompt_tokens: usage.input, completion_tokens: 20, prompt_tokens_details: { cached_tokens: usage.cached } } }) };
  }
  if (provider === 'anthropic') {
    const u = { input_tokens: usage.uncached, cache_read_input_tokens: usage.cached, cache_creation_input_tokens: usage.write, output_tokens: 0 };
    let out = sse('message_start', { message: { id, type: 'message', role: 'assistant', model, content: [], stop_reason: null, stop_sequence: null, usage: u } });
    items[0].content.forEach((b, index) => {
      const start = structuredClone(b);
      if (b.type === 'tool_use') start.input = {};
      if (b.type === 'thinking') start.signature = '';
      out += sse('content_block_start', { index, content_block: start });
      if (b.type === 'thinking') out += sse('content_block_delta', { index, delta: { type: 'signature_delta', signature: b.signature } });
      if (b.type === 'tool_use') { const j = JSON.stringify(b.input); out += sse('content_block_delta', { index, delta: { type: 'input_json_delta', partial_json: j.slice(0, 3) } }) + sse('content_block_delta', { index, delta: { type: 'input_json_delta', partial_json: j.slice(3) } }); }
      out += sse('content_block_stop', { index });
    });
    out += sse('message_delta', { delta: { stop_reason: 'tool_use', stop_sequence: null }, usage: { output_tokens: 20 } }) + sse('message_stop', {});
    return { type: 'text/event-stream', body: out };
  }
  return { type: 'text/event-stream', body: sse('response.completed', { response: { id, status: 'completed', model, output: items, usage: { input_tokens: usage.input, input_tokens_details: { cached_tokens: usage.cached }, output_tokens: 20, output_tokens_details: { reasoning_tokens: 0 } } } }) };
}

// The journey: builder writes a file, then finishes; the reviewer reads the file, then approves.
const STEPS = {
  build: [[['write_file', { path: 'app.txt', content: 'candidate\n' }]], [['finish', { summary: 'done' }]]],
  review: [[['read_file', { path: 'app.txt' }]], [['submit_review', { verdict: 'approve', findings: [] }]]],
};
function toolNames(provider, body) { return (body.tools || []).map(t => t.name || t.function?.name); }
function phaseOf(provider, body) { return toolNames(provider, body).includes('submit_review') ? 'review' : 'build'; }

// ---- The server ----

// Options: refuse — { status, body } answers every request with that HTTP status and JSON body
// (a provider's model refusal), recording it as `rejected`, so a test can count requests and read
// exactly what was sent (headers and raw body) without any scripted conversation;
// hold — { phase: 'build', after: 1 } keeps the response of the first request that
// arrives once `after` answers of that phase exist (the builder's second request) open until the
// harness closes it; `reached` resolves when it is held.
async function startFake(provider, opts = {}) {
  const cache = new PrefixCache(provider), records = [], answered = { build: 0, review: 0 }, held = new Set();
  let release, reachedDone, holdUsed = false;
  const reached = new Promise(r => { reachedDone = r; });
  const server = http.createServer(async (req, res) => {
    const chunks = []; for await (const c of req) chunks.push(c);
    const raw = Buffer.concat(chunks);
    const rec = { i: records.length, provider, path: req.url, method: req.method, headers: req.headers, raw, refused: false, held: false, answered: false, output: [] };
    records.push(rec);
    try {
      if (req.url !== PATHS[provider] || req.method !== 'POST') { res.writeHead(404); res.end('{}'); return; }
      const v = view(provider, req.headers, raw); rec.view = v; rec.phase = phaseOf(provider, v.body);
      if (opts.refuse) {
        rec.rejected = true;
        res.writeHead(opts.refuse.status, { 'content-type': 'application/json' });
        res.end(JSON.stringify(opts.refuse.body));
        return;
      }
      if (provider === 'chatgpt' && v.cacheControls.some(k => /prompt_cache_(options|breakpoint)$/.test(k))) {
        rec.refused = true;
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'Unsupported parameter: prompt_cache_options', type: 'invalid_request_error', param: 'prompt_cache_options', code: 'unsupported_parameter' } }));
        return;
      }
      rec.usage = cache.usage(v, raw);
      const n = answered[rec.phase];
      if (opts.hold && !holdUsed && rec.phase === opts.hold.phase && n === opts.hold.after) {
        holdUsed = true; rec.held = true; held.add(res); res.on('close', () => held.delete(res)); reachedDone(rec); return;
      }
      const script = STEPS[rec.phase][Math.min(n, STEPS[rec.phase].length - 1)];
      const calls = script.map(([name, args], i) => call(provider, name, args, `${rec.phase}_${rec.i}`, i));
      rec.output = output(provider, calls, `${rec.phase}_${rec.i}`);
      rec.responseId = `cache_response_${rec.i}`;
      const a = answer(provider, v.body.model, rec.responseId, rec.output, rec.usage);
      answered[rec.phase]++; rec.answered = true;
      res.writeHead(200, { 'content-type': a.type }); res.end(a.body);
    } catch (e) {
      rec.error = e.message;
      if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
      if (!res.writableEnded) res.end(JSON.stringify({ error: { message: 'fake failure: ' + e.message } }));
    }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  release = () => { for (const r of held) r.destroy(); };
  return { url: `http://127.0.0.1:${server.address().port}`, records, reached, close: async () => { release(); await new Promise(r => { server.close(() => r()); server.closeAllConnections?.(); }); } };
}

// A local sink for KOGEN_AUTH_URL: counts requests and refuses them (no sign-in is needed).
async function startSink() {
  const hits = [];
  const server = http.createServer((req, res) => { hits.push(req.url); req.resume(); res.writeHead(500); res.end('{}'); });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return { url: `http://127.0.0.1:${server.address().port}`, hits, close: () => new Promise(r => { server.close(() => r()); server.closeAllConnections?.(); }) };
}

// ---- Observations ----

function routingText(provider, views) {
  const all = f => views.length > 0 && views.every(f);
  if (provider === 'anthropic') return 'none';
  if (provider === 'openai-compatible') {
    // "none" means no vendor routing field or header on any request.
    const found = [...new Set(views.flatMap(v => v.vendor ?? []))];
    return views.length > 0 && found.length === 0 ? 'none' : views.length === 0 ? 'no requests' : 'vendor routing sent: ' + found.join(', ');
  }
  if (provider === 'opencode-go') {
    const header = all(v => typeof v.key === 'string' && v.key !== '');
    return (header ? 'header x-opencode-session' : 'no header x-opencode-session') + (views.some(v => v.bodyKey !== undefined) ? ' and body prompt_cache_key' : '');
  }
  const body = all(v => typeof v.key === 'string' && v.key !== ''), header = all(v => typeof v.headerKey === 'string' && v.headerKey !== '');
  const long = views.some(v => typeof v.key === 'string' && v.key.length > 64) ? ' (key longer than 64 characters)' : '';
  if (provider === 'chatgpt') {
    if (body && header) return (all(v => v.key === v.headerKey) ? 'body prompt_cache_key equals header session-id' : 'body prompt_cache_key differs from header session-id') + long;
    return (body ? 'body prompt_cache_key only' : header ? 'header session-id only' : 'none') + long;
  }
  return (body ? 'body prompt_cache_key' : 'none') + long;
}

function breakpointText(provider, views) {
  if (provider !== 'anthropic') {
    const found = [...new Set(views.flatMap(v => v.cacheControls.map(k => k.replace(/\[\d+\]/g, '[]'))))];
    return found.length ? 'unexpected cache controls: ' + found.join(', ') : 'none';
  }
  const seen = new Set();
  for (const v of views) {
    const names = [];
    v.tools.forEach((m, i) => { if (m) names.push(i === v.tools.length - 1 ? 'last tool' : `tool ${i}`); });
    v.system.forEach((m, i) => { if (m) names.push(i === v.system.length - 1 ? 'last system block' : `system block ${i}`); });
    const last = v.messageMarks.length - 1;
    v.messageMarks.forEach((marks, mi) => marks.forEach((m, bi) => { if (m) names.push(mi === last && bi === marks.length - 1 ? 'newest message' : `message ${mi} block ${bi}`); }));
    if (names.length > 4) return `more than four breakpoints: ${names.length}`;
    seen.add(names.join(', ') || 'none');
  }
  return [...seen].join(' | ') || 'none';
}

// Judges the requests the fake received (in arrival order). The two keys that need Kogen's run
// log and report, recorded_cached_matches_fake and usage_reports_cached_share, are judged by
// recordedMatches and usageMatches. min_cached_share_after_first is a MINIMUM over every
// answered non-first request of each conversation, truncated (never rounded up) to two
// decimals; the table value is a lower bound for it (see compareCache).
function observe(provider, records) {
  const views = records.map(r => r.view ?? view(provider, r.headers, r.raw));
  const groups = new Map(); // first conversation item -> request indices
  views.forEach((v, i) => { if (!groups.has(v.first)) groups.set(v.first, []); groups.get(v.first).push(i); });
  const identities = new Set(views.map(v => keyless(provider) ? v.first : String(v.key)));
  const lastOfKey = new Map(), lastOfGroup = new Map(), appendOnly = [], frozen = [], refusalRetries = [], shares = [];
  const keysPerGroup = new Map();
  views.forEach((v, i) => {
    const prev = lastOfGroup.has(v.first) ? lastOfGroup.get(v.first) : lastOfKey.get(v.key);
    if (prev !== undefined) {
      const p = records[prev], pv = views[prev];
      const expected = [...pv.conv, ...(p.answered ? p.output : [])];
      const sent = v.conv;
      const want = provider === 'anthropic' ? expected.map(m => ({ ...m, content: blocks(m.content) })) : expected;
      if (!same(sent.slice(0, want.length), want)) appendOnly.push(i);
      if (p.refused) refusalRetries.push(i);
      if (records[i].answered && lastOfGroup.has(v.first)) shares.push(records[i].usage.cached / records[i].usage.input);
      if (lastOfGroup.has(v.first) && v.front !== views[groups.get(v.first)[0]].front) frozen.push(i);
    }
    lastOfGroup.set(v.first, i); lastOfKey.set(v.key, i);
    if (!keysPerGroup.has(v.first)) keysPerGroup.set(v.first, new Set());
    keysPerGroup.get(v.first).add(String(v.key));
  });
  const min = shares.length ? Math.floor(Math.min(...shares) * 100) / 100 : 0;
  return {
    conversations: identities.size,
    append_only_violations: appendOnly,
    frozen_front_violations: frozen,
    routing_keys_per_conversation: [...keysPerGroup.values()].map(s => s.size),
    distinct_routing_keys: new Set(views.map(v => String(v.key))).size,
    routing: routingText(provider, views),
    anthropic_breakpoints: breakpointText(provider, views),
    cache_refusal_retries: refusalRetries.length,
    min_cached_share_after_first: min,
  };
}

// Kogen's run-log usage records equal what the fake reported, request by request.
function recordedMatches(records, attempts) {
  const done = records.filter(r => r.answered);
  const byId = new Map(attempts.filter(a => a.outcome === 'completed' && a.provider_response_id).map(a => [a.provider_response_id, a]));
  if (done.length === 0 || byId.size !== done.length) return false;
  return done.every(r => { const a = byId.get(r.responseId); const u = a?.usage; return !!u && u.input === r.usage.input && u.cached === r.usage.cached && (r.provider !== 'anthropic' || u.write === r.usage.write); });
}
// `kogen intent usage --json` shows the cached tokens the fake reported.
function usageMatches(records, report) {
  const done = records.filter(r => r.answered), t = report?.data?.totals;
  if (!t || done.length === 0) return false;
  const input = done.reduce((s, r) => s + r.usage.input, 0), cached = done.reduce((s, r) => s + r.usage.cached, 0);
  return t.known_input === input && t.known_cached === cached && typeof t.cached_input_percent === 'number' && Math.abs(t.cached_input_percent - 100 * cached / input) < 0.01;
}

// The table value of min_cached_share_after_first is a lower bound; every other key is exact.
function compareCache(assert, actual, expected) {
  for (const [k, v] of Object.entries(expected)) {
    assert.ok(Object.hasOwn(actual, k), 'missing ' + k);
    if (k === 'min_cached_share_after_first') assert.ok(typeof actual[k] === 'number' && actual[k] >= v, `${k}: ${actual[k]} < ${v}: ${JSON.stringify(actual)}`);
    else assert.deepEqual(actual[k], v, k + ': ' + JSON.stringify(actual));
  }
}

// ---- Synthetic request sequences (control checks) ----

const EXPECTED = provider => ({
  conversations: 2, append_only_violations: [], frozen_front_violations: [], routing_keys_per_conversation: [1, 1], distinct_routing_keys: 2,
  routing: { chatgpt: 'body prompt_cache_key only', supergrok: 'body prompt_cache_key', 'opencode-go': 'header x-opencode-session', anthropic: 'none', 'openai-compatible': 'none' }[provider],
  anthropic_breakpoints: provider === 'anthropic' ? 'last tool, last system block, newest message' : 'none',
  cache_refusal_retries: 0, min_cached_share_after_first: 0.9,
});

// Requests as Kogen writes them for each wire: frozen front, then the append-only conversation
// last, with the same key placement. `flaw` selects one deliberate cache-breaking mistake.
function wireRequest(provider, c, flaw) {
  const instructions = c.instructions + (flaw === 'clock' && c.input.length > 1 ? ' now=' + c.input.length : '');
  const tools = c.tools;
  const key = flaw === 'rotate' && c.input.length > 1 ? c.key + '-2' : c.key;
  if (provider === 'anthropic') {
    const messages = structuredClone(c.input.map(m => ({ ...m, content: blocks(m.content) })));
    const mark = list => { const b = list.at(-1); b.cache_control = { type: 'ephemeral' }; };
    const ts = tools.map(t => structuredClone(t)); mark(ts);
    if (flaw === 'extra') { ts[0].cache_control = { type: 'ephemeral' }; if (messages.length > 1) mark(messages[0].content); }
    const system = [{ type: 'text', text: instructions }]; mark(system);
    const newest = messages.at(-1); if (flaw !== 'nomark') mark(newest.content);
    if (flaw === 'rewrite' && messages.length > 2) messages[0].content[0].text += '!';
    const body = { max_tokens: 131072, model: 'claude-sonnet-5-5', stream: true, system, tools: ts, messages };
    return { headers: {}, raw: Buffer.from(JSON.stringify(body)) };
  }
  if (chatWire(provider)) {
    const messages = [{ role: 'system', content: instructions }, ...structuredClone(c.input)];
    if (flaw === 'rewrite' && messages.length > 3) messages[1].content += '!';
    const body = { messages, model: 'kimi-k3', store: false, stream: false, tools: tools.map(t => ({ type: 'function', function: t })) };
    if (provider === 'openai-compatible' && flaw === 'vendorbody') body.prompt_cache_key = key;
    // OpenAI-compatible has no routing key; the 'vendor' flaw sends one anyway (a strict host would refuse it).
    const headers = provider === 'openai-compatible' ? (flaw === 'vendor' ? { 'x-opencode-session': key } : {}) : flaw === 'nokey' ? {} : { 'x-opencode-session': key };
    return { headers, raw: Buffer.from(JSON.stringify(body)) };
  }
  const input = structuredClone(c.input);
  if (flaw === 'rewrite' && input.length > 2) input[0].content += '!';
  const body = { include: ['reasoning.encrypted_content'], instructions, model: 'gpt-6.1-sol', ...(flaw === 'nokey' ? {} : { prompt_cache_key: key }), reasoning: { effort: 'high' }, store: false, stream: true, tool_choice: 'auto', tools, input };
  if (flaw === 'options' && provider === 'chatgpt') body.prompt_cache_options = { mode: 'implicit', ttl: '30m' };
  // conversation last, like the encoder: move input to the end
  const { input: i2, ...front } = body; const raw = Buffer.from(JSON.stringify({ ...front, input: i2 }));
  return { headers: {}, raw };
}

// Two conversations of two to four requests each against the model, as the real journey would.
// Returns fake records (as startFake keeps them) for the observers.
function synthetic(provider, flaw) {
  const cache = new PrefixCache(provider), records = [];
  const tool = name => ({ type: 'function', name, description: 'Synthetic tool ' + name + ' '.repeat(40), parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'], additionalProperties: false }, strict: false });
  const front = 'Synthetic policy text for a frozen front. '.repeat(900);
  const conversations = [
    { key: 'conversation_builder', instructions: 'builder ' + front, tools: [tool('read_file'), tool('write_file'), tool('finish')], first: 'The contract to build. '.repeat(10), phase: 'build', calls: ['write_file', 'finish'] },
    { key: 'conversation_reviewer', instructions: 'reviewer ' + front, tools: [tool('read_file'), tool('submit_review')], first: 'The change to review. '.repeat(10), phase: 'review', calls: ['read_file', 'submit_review'] },
  ];
  for (const conv of conversations) {
    conv.input = [{ role: 'user', content: provider === 'anthropic' ? [{ type: 'text', text: conv.first }] : conv.first }];
    for (let turn = 0; turn < conv.calls.length + 1; turn++) {
      if (flaw === 'options' && provider === 'chatgpt' && turn === 0) {
        // the old policy field: refused with HTTP 400, then retried without it
        const bad = wireRequest(provider, conv, 'options');
        records.push({ i: records.length, provider, headers: bad.headers, raw: bad.raw, refused: true, held: false, answered: false, output: [], view: view(provider, bad.headers, bad.raw) });
      }
      const { headers, raw } = wireRequest(provider, conv, flaw === 'options' ? undefined : flaw);
      const rec = { i: records.length, provider, headers, raw, refused: false, held: false, answered: false, output: [] };
      rec.view = view(provider, headers, raw); rec.usage = cache.usage(rec.view, raw); rec.responseId = 'synthetic_' + rec.i; rec.answered = true; records.push(rec);
      const label = `${conv.phase}_${turn}`, name = conv.calls[turn];
      if (!name) break;
      rec.output = output(provider, [call(provider, name, { path: 'app.txt' }, label, 0)], label);
      const results = rec.output.flatMap(o => provider === 'anthropic' ? [] : o.type === 'function_call' ? [{ type: 'function_call_output', call_id: o.call_id, output: 'result ' + turn }] : o.role === 'assistant' ? o.tool_calls.map(t => ({ role: 'tool', tool_call_id: t.id, content: 'result ' + turn })) : []);
      conv.input = [...conv.input, ...rec.output, ...(provider === 'anthropic' ? [{ role: 'user', content: [{ type: 'tool_result', tool_use_id: rec.output[0].content.at(-1).id, content: 'result ' + turn }] }] : results)];
    }
  }
  return records;
}

module.exports = { PATHS, startFake, startSink, observe, recordedMatches, usageMatches, compareCache, EXPECTED, synthetic, view, PrefixCache };
