const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const H = require('./go_driver_support.js');
const ROOT = path.resolve(__dirname, '../..');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const same = (a, b) => { try { assert.deepEqual(a, b); return true; } catch { return false; } };
// Synthetic fixture construction, not production image validation or a visual assessment.
function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]);
  let crc = 0xffffffff;
  for (const byte of body) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  const head = Buffer.alloc(4), tail = Buffer.alloc(4);
  head.writeUInt32BE(data.length); tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([head, body, tail]);
}
function png(width, height, target, color = 2) {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(width); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = color;
  const raw = Buffer.alloc((width * (color === 6 ? 4 : 3) + 1) * height);
  const parts = [Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))];
  const size = parts.reduce((n, b) => n + b.length, 0);
  if (target) { assert.ok(target >= size + 20); parts.splice(3, 0, chunk('tEXt', Buffer.concat([Buffer.from('padding\0'), Buffer.alloc(target - size - 20, 120)]))); }
  const out = Buffer.concat(parts); if (target) assert.equal(out.length, target); return out;
}
function imageOutput(output, g) {
  try {
    assert.ok(Array.isArray(output)); assert.deepEqual(output.map(x => x.type), ['input_text', 'input_image']);
    const meta = JSON.parse(output[0].text), bytes = Buffer.from(g.base64, 'base64');
    assert.equal(output[1].image_url, 'data:image/png;base64,' + g.base64);
    assert.equal(meta.version, 1); assert.equal(meta.path, g.path); assert.equal(meta.sha256, sha(bytes));
    assert.equal(meta.bytes, bytes.length); assert.equal(meta.format, 'png'); assert.equal(meta.width, g.width); assert.equal(meta.height, g.height);
    for (const key of ['capture_candidate', 'route', 'viewport', 'fixture_state']) assert.equal(meta[key], 'UNKNOWN');
    assert.ok(meta.read_candidate === 'UNKNOWN' || /^[a-f0-9]{40,64}$/.test(meta.read_candidate));
    return true;
  } catch { return false; }
}
// Judge captured JSON objects semantically. Array order, exact strings and opaque/image bytes matter.
function replayObserver(d) {
  try {
    assert.ok(d.windows.length && d.groups.length);
    for (const window of d.windows) {
      const pending = new Set();
      for (const item of window) {
        if (item.type === 'function_call') { assert.ok(!pending.has(item.call_id)); pending.add(item.call_id); }
        if (item.type === 'function_call_output') assert.ok(pending.delete(item.call_id));
      }
      assert.equal(pending.size, 0);
    }
    for (const g of d.groups) {
      const found = [];
      for (const w of d.windows) for (let i = 0; i <= w.length - g.prefix.length - 1; i++) {
        if (same(w.slice(i, i + g.prefix.length), g.prefix)) {
          const o = w[i + g.prefix.length];
          if (o.type === 'function_call_output' && o.call_id === g.call_id) found.push(o.output);
        }
      }
      assert.ok(found.length); assert.ok(found.every(o => imageOutput(o, g)));
      const all = d.windows.flat().filter(i => i.type === 'function_call_output' && i.call_id === g.call_id);
      assert.ok(all.every(o => same(o.output, found[0])));
    }
    return true;
  } catch { return false; }
}
// Match ChatGPT.strip_cache's two shallow locations, never recursively erase payload data.
function fallbackObserver(enabled, compatible) {
  try {
    assert.ok(Object.hasOwn(enabled, 'prompt_cache_options'));
    assert.ok(!Object.hasOwn(compatible, 'prompt_cache_options'));
    const a = structuredClone(enabled), b = structuredClone(compatible);
    delete a.prompt_cache_options;
    let markers = 0;
    for (const item of a.input) if (Array.isArray(item.content)) {
      for (const block of item.content) if (Object.hasOwn(block, 'prompt_cache_breakpoint')) {
        markers++; delete block.prompt_cache_breakpoint;
      }
    }
    assert.ok(markers > 0, 'cache-enabled request must contain block markers');
    assert.ok(b.input.every(item => !Array.isArray(item.content) || item.content.every(block => !Object.hasOwn(block, 'prompt_cache_breakpoint'))));
    return same(a, b);
  } catch { return false; }
}
// Inspect original decoded strings and JSON string tokens in native diagnostic text.
// Never rewrite, redact or normalize the evidence under observation.
function containsOpaque(value, opaque) {
  if (typeof value === 'string') {
    if (value.includes(opaque)) return true;
    for (const token of value.matchAll(/"(?:[^"\\]|\\.)*"/g)) {
      try { if (JSON.parse(token[0]).includes(opaque)) return true; } catch { /* Not a JSON string token. */ }
    }
    return false;
  }
  if (Array.isArray(value)) return value.some(x => containsOpaque(x, opaque));
  return value !== null && typeof value === 'object' && Object.entries(value).some(([k, v]) => containsOpaque(k, opaque) || containsOpaque(v, opaque));
}
function logSafetyObserver(d, s) {
  const imageEvents = d.events.filter(e => ['image_read', 'image_delivery'].includes(e.event));
  const safeText = t => !t.includes('data:image/') && !t.includes('fake-integration-access-token') && !t.includes('fake-integration-refresh-token') && !t.includes(s.selected);
  return imageEvents.length > 0 && d.events.every(e => safeText(JSON.stringify(e)) && !containsOpaque(e, s.opaque)) && safeText(d.diagnostic || '') && !containsOpaque(d.diagnostic || '', s.opaque) && imageEvents.every(e => Buffer.byteLength(JSON.stringify(e)) <= 8192);
}
function reviewIndependentObserver(windows, s) {
  return windows.length > 0 && windows.every(w => !containsOpaque(w, s.opaque + '-build') && !w.some(i => i.type === 'function_call' && i.call_id === 'image-build'));
}
// Each checkpoint binds its captured owner to frozen groups, not final request groups.
function checkpointObserver(records) {
  try {
    assert.ok(Array.isArray(records) && records.length > 0);
    for (const c of records) {
      assert.ok(['build', 'review'].includes(c.owner));
      assert.equal(c.owner, c.expected_owner);
      assert.ok(Array.isArray(c.input) && Array.isArray(c.archives));
      assert.ok(c.groups.length > 0 && c.groups.some(g => g.owner === c.owner));
      for (const g of c.groups) {
        assert.ok(['build', 'review'].includes(g.owner));
        assert.equal(g.call_id, 'image-' + g.owner);
        const windows = [...(g.owner === c.owner ? [c.input] : []), ...c.archives.filter(a => a.owner === g.owner).map(a => a.input)];
        const found = [];
        for (const w of windows) for (let i = 0; i < w.length; i++) {
          const item = w[i];
          if (item.type === 'function_call_output' && item.call_id === g.call_id) {
            assert.ok(i >= g.prefix.length && same(w.slice(i - g.prefix.length, i), g.prefix));
            assert.ok(imageOutput(item.output, g)); found.push(item.output);
          }
        }
        assert.ok(found.length > 0 && found.every(o => same(o, found[0])));
      }
    }
    return true;
  } catch { return false; }
}
// The Go program that observes what has no user-visible form: the view_image tool, the request body as sent, the request
// measure, the cache-control fallback on the wire and checkpoints of a synthetic Build (all production code of Kogen's packages).
const imageDriverSource = String.raw`package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"

	"kogen/agent"
	"kogen/build"
	"kogen/project"
	"kogen/provider"
	"kogen/sys"
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

type m = map[string]any

func hash(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func clone(x m) m {
	out := m{}
	for k, v := range x {
		out[k] = v
	}
	return out
}

func main() {
	var in struct {
		Mode   string
		Bytes  string
		Images []struct{ Name, Base64 string }
		Bodies []m
	}
	must(json.NewDecoder(os.Stdin).Decode(&in))
	switch in.Mode {
	case "validation":
		validation(in.Images)
	case "body":
		client := provider.NewClient("kogen test (driver)")
		body := client.Body(provider.Request{Role: provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "synthetic Δ\U0001F642 policy", Input: []any{}, Tools: []any{}, Scope: "image-validation"})
		fmt.Println(encode(body))
	case "measure":
		var rows []any
		for _, body := range in.Bodies {
			r, err := agent.Measure(body)
			must(err)
			rows = append(rows, m{"rendered_bytes": r.RenderedBytes, "fits": r.Fits, "input_budget_bytes": r.InputBudgetBytes, "output_reserve_tokens": r.OutputReserveTokens})
		}
		fmt.Println(encode(rows))
	case "control":
		b, err := base64.StdEncoding.DecodeString(in.Bytes)
		must(err)
		control(b)
	}
}

func validation(images []struct{ Name, Base64 string }) {
	tmp, err := os.MkdirTemp("", "image-validation-")
	must(err)
	defer os.RemoveAll(tmp)
	tools := &agent.Tools{Root: tmp, Enabled: []string{"view_image"}}
	advertised := false
	for _, d := range agent.Defs("view_image") {
		if d["name"] == "view_image" {
			advertised = true
		}
	}
	var rows []any
	for _, img := range images {
		p := filepath.Join(tmp, img.Name)
		switch img.Name {
		case "missing":
		case "folder":
			must(os.MkdirAll(p, 0o755))
		default:
			raw, err := base64.StdEncoding.DecodeString(img.Base64)
			must(err)
			must(os.WriteFile(p, raw, 0o644))
		}
		var out agent.Output
		if advertised {
			out, err = tools.Run("view_image", m{"path": img.Name})
			must(err)
		} else {
			out = agent.Output{Text: "native view_image not implemented"}
		}
		cut := out.Cut()
		uncut := out.Typed() && encode(cut.Value()) == encode(out.Value())
		rows = append(rows, m{"name": img.Name, "output": out.Value(), "uncut": uncut, "framed": agent.OutputItem(img.Name, out.Value())})
	}
	fmt.Println(encode(m{"rows": rows, "advertised": advertised}))
}

func control(b []byte) {
	p := "synthetic.png"
	opaque := "synthetic opaque+/==\nΔ\U0001F642"
	call := m{"type": "function_call", "id": "control-item", "call_id": "control-call", "name": "view_image", "arguments": encode(m{"path": p})}
	r := m{"type": "reasoning", "id": "opaque-item", "encrypted_content": "opaque+/==\nΔ\U0001F642", "summary": []any{}}
	msg := m{"type": "message", "id": "message-item", "role": "assistant", "phase": "commentary", "content": []any{m{"type": "output_text", "text": "UNFINISHED synthetic observation"}}}
	prefix := []any{agent.ReplayItem(r), agent.ReplayItem(msg), agent.ReplayItem(call)}
	meta := m{"version": 1, "path": p, "sha256": hash(b), "bytes": len(b), "format": "png", "width": 1, "height": 1, "read_candidate": "UNKNOWN", "capture_candidate": "UNKNOWN", "route": "UNKNOWN", "viewport": "UNKNOWN", "fixture_state": "UNKNOWN"}
	imageURL := "data:image/png;base64," + base64.StdEncoding.EncodeToString(b)
	output := []any{m{"type": "input_text", "text": encode(meta)}, m{"type": "input_image", "image_url": imageURL}}
	authority := m{"role": "user", "content": provider.ContractBlocks("synthetic stable authority", "synthetic current progress")}
	items := append(append([]any{authority}, prefix...), agent.OutputItem("control-call", output))
	tools := []any{
		m{"type": "function", "name": "view_image", "description": "Synthetic read-only image control", "parameters": m{"type": "object", "properties": m{"path": m{"type": "string"}}, "required": []any{"path"}, "additionalProperties": false}},
		m{"type": "function", "name": "cache_data", "description": "Synthetic opaque-data schema, not cache controls", "parameters": m{"type": "object", "properties": m{"prompt_cache_options": m{"type": "string"}, "prompt_cache_breakpoint": m{"type": "string"}}, "required": []any{"prompt_cache_options", "prompt_cache_breakpoint"}, "additionalProperties": false}},
	}
	// The request as sent with cache controls, and as sent again after the provider refuses them: both read off the wire
	// of one logical request answered by a local provider.
	body, compatible := fallback(items, tools)

	s := m{"opaque": opaque, "selected": base64.StdEncoding.EncodeToString(b)}
	safeEvent := clone(meta)
	safeEvent["event"], safeEvent["owner"], safeEvent["call_id"], safeEvent["status"] = "image_read", "review", "image-review", "read"
	with := func(k string, v any) m { e := clone(safeEvent); e[k] = v; return e }
	safeLogs := m{"events": []any{safeEvent}, "diagnostic": "native diagnostic " + encode(safeEvent)}
	logsWith := func(events []any, diagnostic string) m { return m{"events": events, "diagnostic": diagnostic} }
	leaks := []string{opaque, imageURL, s["selected"].(string), "fake-integration-access-token", "fake-integration-refresh-token"}
	var bad []any
	for _, leak := range leaks {
		bad = append(bad, logsWith([]any{with("payload", leak)}, safeLogs["diagnostic"].(string)),
			logsWith(safeLogs["events"].([]any), "native diagnostic "+leak),
			logsWith(safeLogs["events"].([]any), "native diagnostic "+encode(m{"payload": leak})))
	}
	pad := ""
	for i := 0; i < 4096; i++ {
		pad += "Δ"
	}
	bad = append(bad, logsWith([]any{with("padding", pad)}, safeLogs["diagnostic"].(string)))
	withReasoning := func(suffix string) any { x := clone(r); x["encrypted_content"] = opaque + suffix; return agent.ReplayItem(x) }
	reviewCall := func(id string) m { x := clone(call); x["call_id"] = id; return agent.ReplayItem(x) }
	reviewWindow := []any{withReasoning("-review"), reviewCall("image-review"), agent.OutputItem("image-review", output)}
	buildCallOnly := clone(call)
	buildCallOnly["call_id"] = "image-build"
	safety := m{
		"inputs": s, "good_logs": safeLogs, "bad_logs": bad, "good_review": []any{reviewWindow},
		"bad_review":       []any{[]any{[]any{withReasoning("-build")}}, []any{[]any{buildCallOnly}}, []any{[]any{m{"role": "assistant", "content": encode(withReasoning("-build"))}}}},
		"serialized_event": encode(with("payload", opaque)),
	}

	// Synthetic custody only: no real Build checkpoint or provider is read.
	root, err := os.MkdirTemp("", "image-custody-")
	must(err)
	defer os.RemoveAll(root)
	run, err := build.StartRun(root)
	must(err)
	group := func(owner string) ([]any, m) {
		c := clone(call)
		c["call_id"], c["id"] = "image-"+owner, "item-"+owner
		rr := clone(r)
		rr["encrypted_content"] = opaque + "-" + owner
		pre := []any{agent.ReplayItem(rr), agent.ReplayItem(msg), agent.ReplayItem(c)}
		return append(append([]any{}, pre...), agent.OutputItem(c["call_id"], output)), m{"owner": owner, "prefix": pre, "call_id": c["call_id"], "path": p, "width": 1, "height": 1, "base64": base64.StdEncoding.EncodeToString(b)}
	}
	buildInput, bg := group("build")
	reviewInput, rg := group("review")
	reviewSession := func(input []any) json.RawMessage {
		return json.RawMessage(encode(m{"role": m{"Provider": "chatgpt", "Model": "fixture", "Effort": "high"}, "input": input, "usage": m{}, "attempts": []any{}}))
	}
	base := build.State{Root: root, Slug: "synthetic", Config: &project.Config{}, IntentText: "Synthetic", Start: "head", Baseline: []string{".kogen/project.yaml"}, BaselineDigests: map[string]string{".kogen/project.yaml": "digest"},
		Excluded: []string{}, Run: run, GitIndex: "index", StartTree: "tree", Phase: "building", Round: 1, Pass: 1, Review: 1, ApprovalBytes: base64.StdEncoding.EncodeToString([]byte("approval"))}
	withContinuation := func(c build.Continuation, wc map[string]*build.OwnerContext) build.State {
		s := base
		s.Continuation, s.WorkingContext = c, wc
		return s
	}
	archive := func(owner string, input []any) *build.OwnerContext {
		dir := filepath.Join(run.Dir, "working-context", owner)
		must(os.MkdirAll(dir, 0o700))
		must(os.Chmod(filepath.Dir(dir), 0o700))
		must(os.Chmod(dir, 0o700))
		file := filepath.Join(dir, "1.json")
		raw := []byte(encode(m{"input": input}) + "\n")
		must(os.WriteFile(file, raw, 0o600))
		must(os.Chmod(file, 0o600))
		return &build.OwnerContext{Mandatory: []any{}, Observations: []any{}, History: []build.HistoryRef{{Path: file, SHA256: hash(raw)}}}
	}
	ba, ra := archive("build", buildInput), archive("review", reviewInput)
	capture := func(state build.State, owner string, groups ...m) m {
		raw, err := json.Marshal(state)
		must(err)
		must(run.PublishCheckpoint(build.Checkpoint{Version: 4, Identity: "synthetic", Candidate: "tree", Index: base64.StdEncoding.EncodeToString([]byte("index")), Approval: state.ApprovalBytes, State: raw}))
		saved, err := os.ReadFile(filepath.Join(run.Dir, "checkpoint.json"))
		must(err)
		var doc struct{ State map[string]any }
		must(json.Unmarshal(saved, &doc))
		c, _ := doc.State["continuation"].(map[string]any)
		stage, _ := c["stage"].(string)
		var captureOwner string
		var input any = []any{}
		switch {
		case stage == "review" || stage == "review_verify" || stage == "review_retry_verify":
			captureOwner = "review"
			if rv, ok := c["review"].(map[string]any); ok {
				input = rv["input"]
			}
		case stage == "builder" || stage == "builder_verify":
			captureOwner, input = "build", c["input"]
		case stage == "tool" && c["owner"] == "build":
			captureOwner, input = "build", c["input"]
		default:
			captureOwner = "UNKNOWN"
		}
		if input == nil {
			input = []any{}
		}
		archives := []any{}
		wc, _ := doc.State["working_context"].(map[string]any)
		for _, ownerName := range []string{"build", "review"} {
			st, _ := wc[ownerName].(map[string]any)
			hist, _ := st["history"].([]any)
			for _, h := range hist {
				ref := h.(map[string]any)
				raw, err := os.ReadFile(ref["path"].(string))
				must(err)
				var a map[string]any
				must(json.Unmarshal(raw, &a))
				archives = append(archives, m{"owner": ownerName, "input": a["input"]})
			}
		}
		gs := []any{}
		for _, g := range groups {
			gs = append(gs, g)
		}
		return m{"owner": captureOwner, "expected_owner": owner, "input": input, "groups": gs, "archives": archives}
	}
	builderState := withContinuation(build.Continuation{Stage: build.StageBuilder, Input: buildInput}, nil)
	reviewState := withContinuation(build.Continuation{Stage: build.StageReview, Review: reviewSession(reviewInput)}, nil)
	growing := withContinuation(build.Continuation{Stage: build.StageReview, Review: reviewSession([]any{})}, map[string]*build.OwnerContext{"build": ba, "review": ra})
	toolState := withContinuation(build.Continuation{Stage: build.StageTool, Owner: "build", Input: buildInput}, nil)
	alteredBuild := func(mutate func(m)) []any {
		last := clone(buildInput[len(buildInput)-1].(m))
		out := append([]any{}, last["output"].([]any)...)
		mutate(m{"out": out})
		last["output"] = out
		return append(append([]any{}, buildInput[:len(buildInput)-1]...), last)
	}
	altered := alteredBuild(func(x m) {
		out := x["out"].([]any)
		img := clone(out[1].(m))
		img["image_url"] = img["image_url"].(string) + "changed"
		out[1] = img
	})
	wrongHash := alteredBuild(func(x m) {
		out := x["out"].([]any)
		first := clone(out[0].(m))
		var md map[string]any
		must(json.Unmarshal([]byte(first["text"].(string)), &md))
		md["sha256"] = "0000000000000000000000000000000000000000000000000000000000000000"
		first["text"] = encode(md)
		out[0] = first
	})
	_ = wrongHash
	asBuild := func(input []any) build.State { return withContinuation(build.Continuation{Stage: build.StageBuilder, Input: input}, nil) }
	checkpoints := m{
		"good": []any{
			[]any{capture(builderState, "build", bg), capture(reviewState, "review", rg)},
			[]any{capture(growing, "review", bg, rg)},
			[]any{capture(toolState, "build", bg)},
		},
		"bad": []any{
			[]any{capture(reviewState, "build", bg)},
			[]any{capture(asBuild(reviewInput), "build", bg)},
			[]any{capture(asBuild(buildInput[:len(buildInput)-1]), "build", bg)},
			[]any{capture(asBuild(altered), "build", bg)},
			[]any{capture(asBuild(wrongHash), "build", bg)},
			[]any{capture(withContinuation(build.Continuation{Stage: build.StageBuilder, Input: []any{}}, map[string]*build.OwnerContext{"review": ba}), "build", bg)},
			[]any{capture(withContinuation(growing.Continuation, map[string]*build.OwnerContext{"build": ba}), "review", bg, rg)},
			[]any{capture(withContinuation(growing.Continuation, map[string]*build.OwnerContext{"review": ra}), "review", bg, rg)},
			[]any{},
		},
	}
	groupsOut := []any{m{"prefix": prefix, "call_id": call["call_id"], "path": p, "width": 1, "height": 1, "base64": base64.StdEncoding.EncodeToString(b)}}
	fmt.Println(encode(m{"checkpoints": checkpoints, "safety": safety, "fallback": []any{body, compatible}, "windows": []any{body["input"]}, "groups": groupsOut}))
}

// fallback sends the conversation to a local provider that refuses the cache controls once and then answers: the first
// and the second request body as received.
func fallback(items, tools []any) (m, m) {
	var mu sync.Mutex
	var bodies []m
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body m
		must(json.Unmarshal(raw, &body))
		mu.Lock()
		bodies = append(bodies, body)
		n := len(bodies)
		mu.Unlock()
		if n == 1 {
			w.Header().Set("content-type", "application/json")
			w.WriteHeader(400)
			fmt.Fprint(w, encode(m{"error": m{"type": "invalid_request_error", "code": "invalid_parameter", "message": "prompt_cache_options is not supported on this model", "param": "prompt_cache_options"}}))
			return
		}
		w.Header().Set("content-type", "text/event-stream")
		item := m{"type": "message", "id": "m_done", "role": "assistant", "content": []any{m{"type": "output_text", "text": "done", "annotations": []any{}}}}
		fmt.Fprintf(w, "data: %s\n\n", encode(m{"type": "response.output_item.done", "output_index": 0, "item": item}))
		fmt.Fprintf(w, "data: %s\n\n", encode(m{"type": "response.completed", "response": m{"usage": m{"input_tokens": 1, "input_tokens_details": m{"cached_tokens": 0}, "output_tokens": 1, "output_tokens_details": m{"reasoning_tokens": 0}}}}))
	}))
	defer srv.Close()
	home, err := os.MkdirTemp("", "image-control-home-")
	must(err)
	defer os.RemoveAll(home)
	cred := filepath.Join(home, ".kogen/credentials")
	must(os.MkdirAll(cred, 0o700))
	must(os.WriteFile(filepath.Join(cred, "chatgpt.json"), []byte("{\"client_id\":\"oaiapp_local_fixture\",\"access_token\":\"fake-access\",\"refresh_token\":\"fake-refresh\",\"expires_at\":4102444800}"), 0o600))
	s := sys.NewWith([]string{"HOME=" + home, "KOGEN_PROVIDER_URL=" + srv.URL}, home)
	client := provider.NewClient("kogen test (driver)")
	_, err = client.Respond(s.Context(), s, provider.Request{Role: provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}, Instructions: "synthetic policy", Input: items, Tools: tools, Single: true, Scope: "image-control"}, nil)
	must(err)
	mu.Lock()
	defer mu.Unlock()
	if len(bodies) < 2 {
		must(fmt.Errorf("expected the refused and the compatible request, got %d", len(bodies)))
	}
	return bodies[0], bodies[1]
}
`;
function retainedEvidence() {
  const dir = '/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-repairs/native-image-evidence-20261021';
  const bytes = fs.readFileSync(path.join(dir, 'attempt-01/result.json'));
  assert.equal(sha(bytes), '3d1df30ef18bf31afa23024e75e36909a9ee3f2f53bf165ab2a5c73977ec8f55');
  const d = JSON.parse(bytes); assert.equal(d.status, 'content_discrimination_passed');
  assert.equal(d.endpoint, 'https://api.openai.com/v1/responses'); assert.equal(d.model, 'gpt-6.1-sol'); assert.equal(d.effort, 'high');
  assert.equal(d.requests.length, 2); assert.ok(d.requests.every(x => x.http_status === 200 && x.status === 'completed' && x.curl_exit === -15 && x.stopped_after_terminal_event));
  assert.equal(d.ground_truth_sent, false); assert.deepEqual(d.observations.map(x => [x.color, x.count]), [['red', 3], ['blue', 6]]);
  assert.ok(d.requests.every(x => x.usage.output_tokens_details.reasoning_tokens === 0));
  const provenance = JSON.parse(fs.readFileSync(path.join(dir, 'provenance.json')));
  for (const name of ['function-calling.md', 'images-vision.md']) {
    const ref = provenance.docs.find(x => x.path === 'docs/' + name); assert.ok(ref);
    const raw = fs.readFileSync(path.join(dir, ref.path)); assert.equal(sha(raw), ref.sha256); assert.equal(raw.length, ref.bytes);
  }
  assert.ok(fs.readFileSync(path.join(dir, 'docs/function-calling.md'), 'utf8').includes('array of image or file objects'));
  const redacted = JSON.parse(fs.readFileSync(path.join(dir, 'attempt-01/request-2-redacted.json')));
  const images = redacted.input.filter(x => x.type === 'function_call_output').flatMap(x => x.output);
  assert.equal(images.length, 2); assert.ok(images.every(x => x.type === 'input_image' && /^[a-f0-9]{64}$/.test(x.image_bytes_sha256)));
  process.stdout.write('verified retained two-request PNG capability; no inference\n');
}
if (require.main === module) {
  (async () => {
  try {
    if (process.argv[2] === '--retained-evidence') retainedEvidence();
    else if (process.argv[2] === '--control') {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kogen-image-control-'));
      try {
        const driver = await H.goDriver('image', imageDriverSource);
        const r = await driver([], { input: JSON.stringify({ Mode: 'control', Bytes: png(1, 1).toString('base64') }) });
        assert.equal(r.code, 0, r.out); const good = JSON.parse(r.out);
        assert.equal(replayObserver(good), true, 'native serialized control must be accepted');
        const [enabled, compatible] = good.fallback;
        assert.deepEqual(enabled.prompt_cache_options, { mode: 'implicit', ttl: '30m' });
        assert.deepEqual([enabled.input[0].content[0].prompt_cache_breakpoint, enabled.input[1].content[0].prompt_cache_breakpoint], [{ mode: 'explicit' }, { mode: 'explicit' }]);
        assert.equal(fallbackObserver(enabled, compatible), true, 'native cache removal must be accepted');
        const reordered = Object.fromEntries(Object.entries(compatible).reverse());
        reordered.input = compatible.input.map(item => Object.fromEntries(Object.entries(item).reverse()));
        assert.equal(fallbackObserver(enabled, reordered), true, 'JSON key order is immaterial');
        const safety = good.safety;
        assert.ok(safety.inputs.opaque.includes('\n') && safety.inputs.opaque.includes('Δ🙂'));
        assert.ok(safety.serialized_event.includes('\\n') && !safety.serialized_event.includes(safety.inputs.opaque));
        assert.equal(logSafetyObserver(safety.good_logs, safety.inputs), true, 'safe native metadata must be accepted');
        assert.equal(reviewIndependentObserver(safety.good_review, safety.inputs), true, 'fresh reviewer pixels/reasoning must be accepted');
        for (const records of good.checkpoints.good) assert.equal(checkpointObserver(records), true, 'owner-bound native checkpoint rejected');
        if (process.argv[3] === 'good') process.stdout.write('accepted\n');
        else {
          assert.equal(process.argv[3], 'bad');
          const mutations = [
            d => d.windows[0].pop(),
            d => { const w = d.windows[0]; w[w.length - 1].output = JSON.stringify(w[w.length - 1].output); },
            d => { const w = d.windows[0]; w[w.length - 1].output[1].image_url += 'changed'; },
            d => { const w = d.windows[0]; w[w.length - 1].call_id = 'wrong-call'; },
            d => { d.windows[0].find(x => x.type === 'reasoning').encrypted_content += 'changed'; },
            d => { d.windows[0].find(x => x.type === 'message').phase = 'final'; },
            d => d.windows[0].reverse(),
            d => { const w = d.windows[0]; const meta = JSON.parse(w[w.length - 1].output[0].text); meta.route = '/guessed-from-name'; w[w.length - 1].output[0].text = JSON.stringify(meta); },
          ];
          for (const mutate of mutations) { const bad = structuredClone(good); mutate(bad); assert.equal(replayObserver(bad), false, 'counterexample accepted'); }
          const fallbackMutations = [
            (a, b) => { b.prompt_cache_options = a.prompt_cache_options; },
            (a, b) => { b.input[0].content[0].prompt_cache_breakpoint = a.input[0].content[0].prompt_cache_breakpoint; },
            (a, b) => { b.input[1].content[0].prompt_cache_breakpoint = a.input[1].content[0].prompt_cache_breakpoint; },
            (a, b) => { delete a.prompt_cache_options; },
            (a, b) => { for (const item of a.input) for (const block of item.content || []) delete block.prompt_cache_breakpoint; },
            (a, b) => { b.input.at(-1).output[1].image_url += 'changed'; },
            (a, b) => { b.input.at(-1).output = JSON.stringify(b.input.at(-1).output); },
            (a, b) => { b.input.at(-1).output.reverse(); },
            (a, b) => { b.input.at(-1).output[0].text += ' '; },
            (a, b) => { b.input.at(-1).call_id = 'wrong-call'; },
            (a, b) => { b.input.find(x => x.type === 'function_call').call_id = 'wrong-call'; },
            (a, b) => { b.input.find(x => x.type === 'function_call').arguments += ' '; },
            (a, b) => { b.input.find(x => x.type === 'reasoning').encrypted_content += 'changed'; },
            (a, b) => { b.input.find(x => x.type === 'message').phase = 'final'; },
            (a, b) => { b.input.reverse(); },
            (a, b) => { b.input[0].content[0].text += 'changed'; },
            (a, b) => { b.input[1].content[0].text += 'changed'; },
            (a, b) => { b.input[1].content[1].text += 'changed'; },
            (a, b) => { b.model = 'different-model'; },
            (a, b) => { b.reasoning.effort = 'medium'; },
            (a, b) => { b.include = []; },
            (a, b) => { b.stream = false; },
            (a, b) => { b.store = true; },
            (a, b) => { b.tool_choice = 'none'; },
            (a, b) => { b.tools.reverse(); },
            (a, b) => { b.tools[0].parameters.required = []; },
            (a, b) => { delete b.tools[1].parameters.properties.prompt_cache_options; },
            (a, b) => { delete b.tools[1].parameters.properties.prompt_cache_breakpoint; },
            (a, b) => { b.prompt_cache_breakpoint = { user: 'not a top-level cache control' }; },
            (a, b) => { b.input.at(-1).output[0].prompt_cache_breakpoint = { user: 'not input content' }; },
          ];
          for (const mutate of fallbackMutations) {
            const [a, b] = structuredClone(good.fallback); mutate(a, b);
            assert.equal(fallbackObserver(a, b), false, 'fallback counterexample accepted');
          }
          for (const bad of safety.bad_logs) assert.equal(logSafetyObserver(bad, safety.inputs), false, 'log disclosure or oversized event accepted');
          for (const bad of safety.bad_review) assert.equal(reviewIndependentObserver(bad, safety.inputs), false, 'builder-only review import accepted');
          for (const records of good.checkpoints.bad) assert.equal(checkpointObserver(records), false, 'wrong-owner or missing/altered checkpoint pixels accepted');
          process.stdout.write('rejected\n'); process.exitCode = 1;
        }
      } finally { fs.rmSync(dir, { recursive: true, force: true }); }
    } else throw new Error('unknown control mode');
  } catch (e) { process.stderr.write(String(e) + '\n'); process.exitCode = 2; }
  })();

} else {
  const { Given, When, Then } = require('@cucumber/cucumber');
  const f = H.fn;
  const sortKeys = x => Array.isArray(x) ? x.map(sortKeys) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sortKeys(x[k])])) : x;
  const read = p => fs.readFileSync(p, 'utf8');
  const modeFacts = p => ({ file_mode: fs.statSync(p).mode & 0o777, dir_mode: fs.statSync(path.dirname(p)).mode & 0o777 });
  const isPrivate = paths => paths.length > 0 && paths.every(p => { const x = modeFacts(p); return x.file_mode === 0o600 && x.dir_mode === 0o700; });
  const count = c => c.server.providerRequests().length;
  // What the checkpoint says about who owned the conversation and which windows are archived (the saved state of a checkpoint).
  function captureSaved(saved, expectedOwner, groups) {
    const c = saved.continuation;
    let owner = 'UNKNOWN', input = [];
    if (['review', 'review_verify', 'review_retry_verify'].includes(c.stage)) { owner = 'review'; input = (c.review || {}).input || []; }
    else if (['builder', 'builder_verify'].includes(c.stage)) { owner = 'build'; input = c.input || []; }
    else if (c.stage === 'tool' && c.owner === 'build') { owner = 'build'; input = c.input || []; }
    const archives = [];
    for (const [name, state] of Object.entries(saved.working_context || {})) for (const ref of state.history || []) archives.push({ owner: name, input: JSON.parse(read(ref.path)).input });
    return { owner, expected_owner: expectedOwner, input, groups, archives };
  }
  const savedState = file => JSON.parse(read(file)).state;

  async function validation(s) {
    const driver = await H.goDriver('image', imageDriverSource);
    const call = async input => { const r = await driver([], { input: JSON.stringify(input) }); assert.equal(r.code, 0, r.out); return JSON.parse(r.out); };
    const { rows, advertised } = await call({ Mode: 'validation', Images: s.images.map(i => ({ Name: i.name, Base64: i.base64 })) });
    const body = await call({ Mode: 'body' });
    const base = { ...body, padding: '' };
    const sized = [s.budget - 1, s.budget, s.budget + 1].map(n => ({ ...base, padding: 'x'.repeat(n - Buffer.byteLength(JSON.stringify(base))) }));
    const measured = await call({ Mode: 'measure', Bodies: sized });
    return { rows, advertised, measured };
  }
  function group(owner, p, s, serial = '') {
    const id = owner + serial;
    const call = { type: 'function_call', id: `item-${id}`, call_id: `image-${id}`, name: 'view_image', arguments: JSON.stringify({ path: p }) };
    const r = { type: 'reasoning', id: `reasoning-${id}`, encrypted_content: `${s.opaque}-${id}`, summary: [] };
    const m = { type: 'message', id: `message-${id}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: `${s.unfinished} ${id}` }] };
    const prefix = [r, m, call].map(H.replayItem);
    return [prefix, { owner, prefix, call_id: call.call_id, path: p, base64: s.selected, width: 1, height: 1 }];
  }
  const observation = (owner, s, tool, args) => ({ items: [{ type: 'message', id: `observed-${owner}`, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: s.observation }] }, { type: 'function_call', id: `after-${owner}`, call_id: `after-${owner}`, name: tool, arguments: JSON.stringify(args) }] });
  const custody = async c => ({ head: await H.git(c, ['rev-parse', 'HEAD']), index: read0(path.join(c.repo, '.git/index')), approval: read0(H.approvalPath(c.repo, 'fixture')), app: read0(path.join(c.repo, 'app.txt')) });
  const read0 = p => fs.readFileSync(p).toString('latin1');
  const protectedFiles = c => Object.fromEntries(['.kogen/project.yaml', H.intentMd('fixture'), H.featurePath('fixture'), 'features/steps/integration_steps.js'].map(p => [p, read0(path.join(c.repo, p))]));
  function common(c, s, reqs, groups, protection) {
    const ap = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/working-context/*/*.json'));
    const aw = ap.map(p => JSON.parse(read(p)).input);
    const logs = H.listFiles(path.join(c.repo, '.kogen/local')).filter(p => ['log.jsonl', 'events.ndjson'].includes(path.basename(p))).flatMap(p => read(p).split('\n').filter(Boolean).map(l => JSON.parse(l)));
    const reviewRequests = c.server.reviewRequests();
    const reviews = reqs.filter(r => reviewRequests.includes(r));
    const advertised = reqs.length > 0 && reqs.every(r => (r.json.tools || []).some(t => t.name === 'view_image'));
    return { advertised, windows: [...reqs.map(r => r.json.input), ...aw], groups, bounded: reqs.length > 0 && reqs.every(r => Buffer.byteLength(r.body) <= s.budget), events: logs, review_windows: reviews.map(r => r.json.input), protection_same: same(protectedFiles(c), protection) };
  }
  async function installed(s, mode) {
    const suite = await H.setupSuite(); let c;
    try {
      c = await H.project(suite, [], { stagedIntent: false });
      // Cheap clean unrelated baseline BEFORE targeted second-slug Shape or renewed approval.
      await H.gitBang(c, ['add', '.kogen/intents/fixture', 'features/steps/integration_steps.js']);
      await H.gitBang(c, ['commit', '-qm', 'Commit unrelated native fixture baseline']);
      assert.equal(await H.git(c, ['status', '--porcelain']), '');
      await H.approve(c, 'fixture');
      const before = await custody(c);
      const protection = protectedFiles(c);
      const p = path.join(c.root, 'selected.png'); fs.writeFileSync(p, Buffer.from(s.selected, 'base64'));
      const q = path.join(c.root, 'review.png'); fs.writeFileSync(q, Buffer.from(s.selected, 'base64'));
      const n = count(c);
      const [items, g] = group(['shape', 'budget-shape'].includes(mode) ? 'shape' : 'build', p, s);
      const [reviewItems, rg] = group('review', q, s);
      const requestsFrom = k => c.server.providerRequests().slice(k);
      if (['shape', 'budget-shape', 'budget-build'].includes(mode)) {
        const input = path.join(c.root, 'request.txt'); fs.writeFileSync(input, `Synthetic selected PNG evidence only: ${p}`);
        let actions;
        if (mode === 'shape') actions = [{ items }, { pause: observation('shape', s, 'read_file', { path: 'app.txt' }) }, f('submit', { questions: [{ question: 'Synthetic fixture stop', options: [{ label: 'Keep', recommended: true }, { label: 'Stop' }] }] })];
        else {
          const calls = [1, 2, 3].map(i => group('budget', p, s, String(i))[0].at(-1));
          actions = [{ items: calls }];
        }
        c.server.setScript(actions);
        const args = mode === 'budget-build' ? ['intent', 'build', 'fixture'] : ['intent', 'shape', 'image-shape', input];
        let out, code;
        if (mode === 'shape') {
          const proc = H.startKogen(c, args);
          const peer = await c.server.waitPaused(15000);
          fs.rmSync(p); peer.continue();
          ({ out, code } = await proc.awaitExit(30000));
        } else ({ out, code } = await H.runKogen(c, args));
        const reqs = requestsFrom(n);
        return { ...common(c, s, reqs, [g], protection), shape_completed: code === 5, path_deleted: !fs.existsSync(p), budget_refusal: code !== 0 && out.includes('candidate/context_budget_exceeded'), requests_after_init: reqs.length, no_oversized_request: reqs.every(r => Buffer.byteLength(r.body) <= s.budget), custody_unchanged: same(await custody(c), before), actionable: out.includes('524288') && out.includes('131072') && /prepar|Refine|approval/i.test(out), diagnostic: out };
      }
      const grows = ['windows', 'archive-drift'].includes(mode);
      const growth = owner => Array.from({ length: s.turns }, (_, i) => f('write_file', { path: 'app.txt', content: owner + (i + 1) + 'x'.repeat(s.payload_bytes) }));
      const finish = f('finish', { summary: 'Synthetic implementation finished, visual observations are not check approval' });
      const cacheError = { http: [400, { error: { type: 'invalid_request_error', code: 'invalid_parameter', message: 'prompt_cache_options is not supported on this model' } }] };
      const obs = observation('build', s, 'write_file', { path: 'app.txt', content: 'image journey\n' });
      let actions;
      if (grows) actions = [{ items }, obs, ...growth('build'), finish, { items: reviewItems }, observation('review', s, 'read_file', { path: 'app.txt' }), ...growth('review')];
      else if (mode === 'uncertain') actions = [{ items }, f('shell', { command: "printf 'once\\n' >> .kogen/local/image-effects; touch .kogen/local/image-entered; sleep 60" })];
      else if (mode === 'delivery-failure') actions = [{ items }];
      else if (mode === 'fallback') actions = [{ items }, cacheError, obs];
      else actions = [{ items }, obs];
      c.server.setScript(actions);
      let out, code;
      if (mode === 'uncertain') {
        const proc = H.startKogen(c, ['intent', 'build', 'fixture']);
        await H.waitForFile(path.join(c.repo, '.kogen/local/image-entered'), 20000);
        proc.signal('SIGTERM');
        ({ out, code } = await proc.awaitExit(20000));
      } else ({ out, code } = await H.runKogen(c, ['intent', 'build', 'fixture']));
      const first = requestsFrom(n);
      const [cp] = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/checkpoint.json'));
      const saved = savedState(cp);
      const id = path.basename(path.dirname(cp));
      const oldResult = read0(path.join(path.dirname(cp), 'result.json'));
      const old = await custody(c);
      fs.writeFileSync(p, 'changed or expired original artifact');
      if (mode === 'resume-delete') fs.rmSync(p);
      const ap = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/working-context/*/*.json'));
      const archiveWindows = ap.map(a => JSON.parse(read(a)).input);
      const groups = grows ? [g, rg] : [g];
      let base = common(c, s, first, groups, protection);
      base = { ...base, no_commit_on_failure: code !== 0 && old.head === before.head, checkpoints: [captureSaved(saved, grows ? 'review' : 'build', groups)], archive_windows: archiveWindows, build_archive: ap.some(a => a.includes('/build/')), review_archive: ap.some(a => a.includes('/review/')), archive_files: ap.map(modeFacts), private: isPrivate([cp, ...ap]), diagnostic: out, fallback_requests: first.map(r => r.json) };
      if (mode === 'delivery-failure') return base;
      if (['archive-drift', 'uncertain'].includes(mode)) {
        if (mode === 'archive-drift') { assert.ok(ap.length > 0, 'fixture did not reach a working-window reset'); fs.writeFileSync(ap[0], '{"input":[]}\n'); }
        const n2 = count(c);
        const refusal = await H.runKogen(c, ['intent', 'resume', id]);
        const effects = path.join(c.repo, '.kogen/local/image-effects');
        return { ...base, refused: refusal.code !== 0, no_inference_on_refusal: count(c) === n2, custody_unchanged: same(await custody(c), old), actionable: /history|archive|uncertain|custody/i.test(refusal.out), effect_once: fs.existsSync(effects) && fs.readFileSync(effects, 'utf8') === 'once\n', diagnostic: out + refusal.out };
      }
      // First continuation is the exact saved owner. Ordinary modes then stop the fresh reviewer too.
      // Since 7e15bf2 an approval needs every pinned review-source part read first (as main's own release requires).
      c.server.setScript(grows ? [...H.wildcard(path.join(c.repo, '.kogen/local/runs/*/review-source/*/*.json')).map(p => f('read_file', { path: p })), f('submit_review', { verdict: 'approve', findings: [] })] : [finish, { items: reviewItems }, observation('review', s, 'read_file', { path: 'app.txt' })]);
      const n2 = count(c);
      const resume = await H.runKogen(c, ['intent', 'resume', id]);
      const second = requestsFrom(n2);
      const sameInput = second.length > 0 && same(second[0].json.input, first.at(-1).json.input);
      let finalCode, reviewSame, finalOutput, checkpoints;
      if (grows) { finalCode = resume.code; reviewSame = true; finalOutput = resume.out; checkpoints = base.checkpoints; }
      else {
        assert.notEqual(resume.code, 0, resume.out);
        const newer = H.wildcard(path.join(c.repo, '.kogen/local/runs/*/checkpoint.json')).filter(x => x !== cp);
        assert.equal(newer.length, 1, `${newer}`);
        const [reviewCp] = newer;
        checkpoints = [...base.checkpoints, captureSaved(savedState(reviewCp), 'review', [rg])];
        fs.rmSync(q);
        c.server.setScript([f('submit_review', { verdict: 'approve', findings: [] })]);
        const nn = count(c);
        const o = await H.runKogen(c, ['intent', 'resume', path.basename(path.dirname(reviewCp))]);
        const last = requestsFrom(nn);
        finalCode = o.code; reviewSame = last.length > 0 && same(last[0].json.input, second.at(-1).json.input); finalOutput = resume.out + o.out;
      }
      const all = requestsFrom(n);
      const final = common(c, s, all, [g, rg], protection);
      return { ...base, ...final, checkpoints, resume_same_input: sameInput && reviewSame, one_commit: finalCode === 0 && (await H.git(c, ['rev-list', '--count', `${before.head}..HEAD`])) === '1', old_result_unchanged: read0(path.join(path.dirname(cp), 'result.json')) === oldResult, diagnostic: out + finalOutput };
    } finally { await H.cleanupCase(c); H.cleanupSuite(suite); }
  }
  function qualify(d, s) {
    if (d.rows) {
      d.accepted = d.rows.filter(x => Array.isArray(x.output)).map(x => x.name);
      d.rejected = d.rows.filter(x => typeof x.output === 'string' && x.output.startsWith('error:')).map(x => x.name);
      const good = d.rows.filter(x => Array.isArray(x.output));
      d.metadata_exact = good.length > 0 && good.every(x => { const image = s.images.find(i => i.name === x.name); return imageOutput(x.output, { ...image, path: image.name }); });
      d.typed_uncut = good.length > 0 && good.every(x => x.uncut && same(x.framed.output, x.output));
      d.boundary_bytes = d.measured.map(x => x.rendered_bytes); d.boundary_fits = d.measured.map(x => x.fits); d.reserve = d.measured[0].output_reserve_tokens;
      delete d.rows; return d;
    }
    d.typed_replay = replayObserver(d);
    const bytes = Buffer.from(s.selected, 'base64'), hash = sha(bytes);
    const imageEvents = d.events.filter(e => ['image_read', 'image_delivery'].includes(e.event));
    d.logs_safe = logSafetyObserver(d, s);
    const delivered = imageEvents.filter(e => e.event === 'image_delivery' && e.sha256 === hash);
    d.read_distinct_from_delivery = imageEvents.some(e => e.event === 'image_read' && e.status === 'read' && e.sha256 === hash) && delivered.some(e => e.status === 'completed') && imageEvents.every(e => e.event !== 'image_read' || e.status !== 'completed');
    d.delivery_failed = delivered.some(e => e.status === 'failed'); d.no_completed_delivery = !delivered.some(e => e.status === 'completed');
    const has = (windows, group) => windows.some(w => w.some(i => i.type === 'function_call_output' && i.call_id === group.call_id && imageOutput(i.output, group)));
    d.saved_pixels = checkpointObserver(d.checkpoints);
    d.archive_pixels = !!d.archive_windows && d.groups.every(g => has(d.archive_windows, g));
    d.review_own_pixels = d.groups.some(g => g.call_id === 'image-review' && has(d.review_windows, g));
    d.review_independent = reviewIndependentObserver(d.review_windows, s);
    d.explicit_observation = d.windows.some(w => w.some(i => i.role === 'assistant' && (i.content || []).some(x => x.text === s.observation)));
    d.fallback_exact = false;
    if (d.fallback_requests && d.fallback_requests.length >= 3) {
      d.fallback_exact = fallbackObserver(d.fallback_requests[1], d.fallback_requests[2]);
    }
    for (const k of ['windows','groups','events','review_windows','checkpoints','archive_windows','fallback_requests']) delete d[k];
    return d;
  }
  Given('the native image qualification inputs:', function (json) {
    const s = JSON.parse(json);
    const fixtures = [
      ['small', png(1, 1), 1, 1], ['bytes_minus', png(1, 1, s.max_bytes - 1), 1, 1], ['bytes_equal', png(1, 1, s.max_bytes), 1, 1],
      ['dimension_minus', png(s.max_dimension - 1, 1), s.max_dimension - 1, 1], ['dimension_equal', png(s.max_dimension, 1), s.max_dimension, 1],
      ['missing', Buffer.alloc(0), 0, 0], ['folder', Buffer.alloc(0), 0, 0], ['bad_crc', Buffer.from(png(1, 1)), 1, 1], ['truncated', png(1, 1).subarray(0, 45), 1, 1],
      ['unsupported', png(1, 1, undefined, 6), 1, 1], ['bytes_plus', png(1, 1, s.max_bytes + 1), 1, 1], ['dimension_zero', png(0, 1), 0, 1], ['dimension_plus', png(s.max_dimension + 1, 1), s.max_dimension + 1, 1],
    ];
    fixtures.find(x => x[0] === 'bad_crc')[1][29] ^= 1;
    s.images = fixtures.map(([name, b, width, height]) => ({ name, base64: b.toString('base64'), width, height }));
    s.selected = png(1, 1, s.max_bytes).toString('base64'); this.imageInputs = s;
  });
  When('I exercise native image evidence {string}', { timeout: 300000 }, async function (mode) {
    const result = mode === 'validation' ? await validation(this.imageInputs) : await installed(this.imageInputs, mode);
    this.imageObservations = qualify(result, this.imageInputs);
    await this.attach(JSON.stringify(this.imageObservations), 'application/json');
  });
  Then('the native image observations include:', function (json) {
    for (const [key, expected] of Object.entries(JSON.parse(json))) assert.deepEqual(this.imageObservations[key], expected, key + ': ' + JSON.stringify(this.imageObservations));
  });
}
