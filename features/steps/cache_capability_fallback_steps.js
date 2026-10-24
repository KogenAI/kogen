const assert = require('node:assert/strict');
const { isDeepStrictEqual } = require('node:util');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { When, Then } = require('@cucumber/cucumber');
const { FakeServers } = require('../../test/acceptance/support/fake-servers');
const H = require('./go_driver_support.js');
// The driver is a tiny Go program calling Kogen's provider and shaping-evidence packages the way a logical request does:
// one conversation, a fake provider, the run's evidence file and the checkpoint serialization of the cache state.
const driver = String.raw`package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"kogen/project"
	"kogen/provider"
	"kogen/shape"
	"kogen/sys"
)

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func main() {
	home, url, configPath := os.Args[1], os.Args[2], os.Args[3]
	raw, err := os.ReadFile(configPath)
	must(err)
	var c map[string]string
	must(json.Unmarshal(raw, &c))
	s := sys.NewWith([]string{"HOME=" + home, "KOGEN_PROVIDER_URL=" + url}, home)
	ev, err := shape.NewEvidence(filepath.Join(home, "evidence"), "fixture")
	must(err)
	role := provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}
	policy := "DEVELOPER_AUTHORITY: preserve policy exactly"
	base := []any{
		map[string]any{"role": "user", "content": provider.ContractBlocks("CONTRACT_AUTHORITY", "dynamic suffix")},
		map[string]any{"type": "reasoning", "id": "r_old", "summary": []any{}, "encrypted_content": "OPAQUE_REASONING"},
		map[string]any{"type": "message", "id": "m_old", "role": "assistant", "phase": "commentary", "content": []any{map[string]any{"type": "output_text", "text": "prior text", "annotations": []any{}}}},
		map[string]any{"type": "function_call", "id": "f_old", "call_id": "call_old", "name": "read_file", "arguments": "{\"path\":\"app.txt\"}"},
		map[string]any{"type": "function_call_output", "call_id": "call_old", "output": "TOOL_RESULT"},
	}
	tools := []any{map[string]any{"type": "function", "name": "read_file", "description": "Read", "parameters": map[string]any{"type": "object", "properties": map[string]any{"path": map[string]any{"type": "string"}}, "required": []any{"path"}, "additionalProperties": false}, "strict": true}}
	budget := 15000
	if b, ok := c["budget"]; ok {
		budget, err = strconv.Atoi(b)
		must(err)
	}
	client := provider.NewClient("kogen test (driver)")
	if c["mode"] == "cancel" {
		time.AfterFunc(400*time.Millisecond, func() { s.Interrupt("SIGINT") })
	}
	call := func(input []any) map[string]any {
		started := time.Now()
		elapsed := func() int64 { return time.Since(started).Milliseconds() }
		cc := ev.BeginCall("shape", "", "fixture", "", project.Role{Provider: role.Provider, Model: role.Model, Effort: role.Effort})
		resp, err := client.Respond(s.Context(), s, provider.Request{Role: role, Instructions: policy, Input: input, Tools: tools, Budget: time.Duration(budget) * time.Millisecond, Single: c["single"] == "true", Scope: "builder-fixture"}, cc)
		cc.End(resp, err)
		if err != nil {
			var i *sys.Interrupted
			var e *sys.Error
			switch {
			case errors.As(err, &i):
				return map[string]any{"outcome": "cancel/" + i.Signal, "items": nil, "elapsed": elapsed()}
			case errors.As(err, &e):
				return map[string]any{"outcome": e.Class + "/" + e.Reason, "items": nil, "elapsed": elapsed()}
			}
			must(err)
		}
		return map[string]any{"outcome": "completed", "items": resp.Items, "elapsed": elapsed()}
	}
	first := call(base)
	results := []any{first}
	if c["mode"] == "success" && first["outcome"] == "completed" {
		// The checkpoint boundary: the cache state is saved as JSON and restored before the next turn.
		saved, err := json.Marshal(client.Cache.States())
		must(err)
		var states map[string]provider.CacheState
		must(json.Unmarshal(saved, &states))
		client.Cache = provider.NewCache(states)
		results = append(results, call(append(append([]any{}, base...), map[string]any{"role": "user", "content": "next turn"})))
	}
	rowsRaw, err := os.ReadFile(filepath.Join(home, "evidence", "events.ndjson"))
	must(err)
	var rows []any
	for _, line := range splitLines(rowsRaw) {
		var row any
		must(json.Unmarshal(line, &row))
		rows = append(rows, row)
	}
	fresh := client.Body(provider.Request{Role: role, Instructions: policy, Input: base, Tools: tools, Scope: "independent-reviewer-fixture"})
	out, err := json.Marshal(map[string]any{"results": results, "rows": rows, "fresh": fresh})
	must(err)
	must(os.WriteFile(filepath.Join(home, "receipt.json"), out, 0o644))
}

func splitLines(b []byte) [][]byte {
	var out [][]byte
	start := 0
	for i, c := range b {
		if c == '\n' {
			if i > start {
				out = append(out, b[start:i])
			}
			start = i + 1
		}
	}
	if start < len(b) {
		out = append(out, b[start:])
	}
	return out
}
`;
function frame(type, data) { return `data: ${JSON.stringify({ type, ...data })}\n\n`; }
function strip(p) {
  const b = structuredClone(p); delete b.prompt_cache_options;
  for (const m of b.input || []) if (Array.isArray(m.content)) for (const x of m.content) delete x.prompt_cache_breakpoint;
  return b;
}
function controlled(p) {
  const marks = (p.input || []).flatMap(m => Array.isArray(m.content) ? m.content : []).filter(b => b.prompt_cache_breakpoint);
  return p.prompt_cache_options?.mode === 'implicit' && p.prompt_cache_options?.ttl === '30m' && marks.length === 2;
}
function clean(p) { return !p.prompt_cache_options && !(p.input || []).some(m => Array.isArray(m.content) && m.content.some(b => b.prompt_cache_breakpoint)); }
When('I send a cache capability conversation with:', { timeout: 45000 }, async function(table) {
  const c = Object.fromEntries(table.raw());
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-capability-repair-'));
  const fake = new FakeServers();
  const bodies = [], timers = new Set(), held = new Set();
  const item = { type: 'message', id: 'm_complete', role: 'assistant', content: [{ type: 'output_text', text: 'compatible completion', annotations: [] }] };
  const error = { type: c.type, code: c.code, message: c.message };
  if (c.param !== 'absent') error.param = c.param === 'null' ? null : c.param;
  const later = (f, ms) => { const t = setTimeout(f, ms); timers.add(t); };
  fake.handleProvider = async (req, res) => {
    assert.equal(req.method, 'POST'); assert.equal(req.url, '/v1/responses');
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    bodies.push(JSON.parse(Buffer.concat(chunks).toString()));
    const n = bodies.length;
    if (c.mode === 'network') { req.socket.destroy(); return; }
    if (['failed-stream', 'cut-stream'].includes(c.mode)) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.write(frame('response.output_item.done', { output_index: 0, item: { type: 'function_call', call_id: 'uncertain', name: 'read_file', arguments: '{}' } }));
      if (c.mode === 'failed-stream') res.write(frame('response.failed', { response: { error } }));
      res.end(); return;
    }
    if (['deadline', 'cancel'].includes(c.mode) && n > 1) {
      res.writeHead(200, { 'content-type': 'text/event-stream' }); res.flushHeaders();
      held.add(res); res.on('close', () => held.delete(res)); return;
    }
    if (n === 1 || c.mode === 'negative') {
      const refuse = () => { if (!res.destroyed) { res.writeHead(Number(c.status), { 'content-type': 'application/json', 'x-request-id': `req-local-${n}` }); res.end(JSON.stringify({ error })); } };
      if (['deadline', 'cancel'].includes(c.mode)) later(refuse, 200); else refuse();
      return;
    }
    res.writeHead(200, { 'content-type': 'text/event-stream', 'x-request-id': `req-local-${n}` });
    res.end(frame('response.completed', { response: { id: `resp-local-${n}`, status: 'completed', output: [item], usage: { input_tokens: 100, input_tokens_details: { cached_tokens: 0 }, output_tokens: 2, output_tokens_details: { reasoning_tokens: 0 } } } }));
  };
  try {
    await fake.start();
    fs.mkdirSync(path.join(dir, '.kogen/credentials'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.kogen/credentials/chatgpt.json'), JSON.stringify({ client_id: 'oaiapp_local_fixture', access_token: 'fake-access', refresh_token: 'fake-refresh', expires_at: Math.floor(Date.now() / 1000) + 3600 }));
    const config = path.join(dir, 'config.json');
    fs.writeFileSync(config, JSON.stringify(c));
    const run = await H.goDriver('cache-capability', driver);
    const done = await run([dir, fake.providerUrl, config]);
    const code = done.code, output = done.out;
    assert.equal(code, 0, output); assert.deepEqual(fake.serverErrors, [], String(fake.serverErrors));
    const r = JSON.parse(fs.readFileSync(path.join(dir, 'receipt.json'), 'utf8'));
    await new Promise(resolve => setTimeout(resolve, 100));
    const ps = r.rows.filter(x => x.provider).map(x => x.provider);
    const failed = ps.filter(x => x.outcome !== 'completed');
    const unknown = p => p.usage_state === 'unknown' && Object.values(p.usage).every(v => v === null);
    const expectedLater = bodies[1] && structuredClone(bodies[1]);
    if (expectedLater) expectedLater.input.push({ role: 'user', content: 'next turn' });
    const honest = ps.length === 3 && ps[0].outcome === 'failed' && unknown(ps[0]) && ps[0].cache.status === 'unsupported' && ps[0].cache.boundaries.length === 2 && ps[0].provider_request_id === 'req-local-1' && ps[0].provider_response_id === null && ps[0].effective_model === null && ps[0].effective_effort === null && ps.every(p => p.cache.applied_mode === null && p.cache.applied_ttl === null) && ps.slice(1).every((p,i) => p.outcome === 'completed' && p.cache.status === 'unsupported' && p.cache.boundaries.length === 0 && p.provider_request_id === `req-local-${i+2}` && p.provider_response_id === `resp-local-${i+2}`) && new Set(ps.map(p => p.attempt_id)).size === 3 && new Set(ps.map(p => p.conversation_id)).size === 1 && ps[0].operation_id === ps[1].operation_id && ps[1].operation_id !== ps[2].operation_id;
    this.cacheCapability = {
      outcomes: r.results.map(x => x.outcome), requests: bodies.length,
      controls: bodies.map(p => controlled(p) ? true : clean(p) ? false : 'partial'),
      fallback_preserves_body: !!bodies[1] && JSON.stringify(strip(bodies[0])) === JSON.stringify(bodies[1]),
      later_preserves_replay: !!bodies[2] && isDeepStrictEqual(expectedLater, bodies[2]),
      exact_completed_items: r.results.length === 2 && r.results.every(x => isDeepStrictEqual(x.items, [item])),
      honest_attempts: honest,
      independent_fresh: !!r.fresh.prompt_cache_options && !r.fresh.prompt_cache_options.comparison_response_id,
      no_unsupported: ps.length === bodies.length && ps.every(p => p.cache.status !== 'unsupported'),
      failed_unknown: failed.length > 0 && failed.every(unknown),
      no_completed_items: r.results.every(x => x.items === null),
      bounded: r.results[0].elapsed >= 300 && r.results[0].elapsed < 1300,
      sockets_closed: held.size === 0,
    };
    // Common protocol requirements are checked independently of fallback outcomes.
    for (const p of bodies) {
      assert.equal(p.model, 'gpt-6.1-sol'); assert.deepEqual(p.reasoning, { effort: 'high' });
      assert.equal(p.stream, true); assert.equal(p.store, false); assert.deepEqual(p.include, ['reasoning.encrypted_content']);
      assert.ok(!('previous_response_id' in p) && !('conversation' in p));
    }
  } finally {
    for (const t of timers) clearTimeout(t);
    for (const res of held) res.destroy();
    await fake.close(); fs.rmSync(dir, { recursive: true, force: true });
  }
});
Then('the cache capability observations are:', function(table) {
  const errors = [];
  for (const [key, value] of table.raw()) {
    try { assert.deepEqual(this.cacheCapability[key], JSON.parse(value), key); }
    catch (e) { errors.push(e.message); }
  }
  assert.deepEqual(errors, [], JSON.stringify(this.cacheCapability));
});
