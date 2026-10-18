const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const FAKE_ACCESS_TOKEN = 'KOGEN_ACCEPTANCE_FAKE_ACCESS_TOKEN_DO_NOT_LEAK_20261016';
const FAKE_REFRESH_TOKEN = 'KOGEN_ACCEPTANCE_FAKE_REFRESH_TOKEN_20261016';
const ROTATED_REFRESH_TOKEN = 'KOGEN_ACCEPTANCE_ROTATED_REFRESH_TOKEN_20261016';
const DEFAULT_SCOPE = 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct';

function flatten(value, out = []) {
  if (typeof value === 'string') out.push(value);
  else if (Array.isArray(value)) for (const item of value) flatten(item, out);
  else if (value && typeof value === 'object') for (const item of Object.values(value)) flatten(item, out);
  return out;
}

function functionCall(name, args, id) {
  return {
    type: 'function_call',
    id: `item_${id}`,
    call_id: `call_${id}`,
    name,
    arguments: JSON.stringify(args),
  };
}

function message(text, id = 'text') {
  return { type: 'message', id: `item_${id}`, role: 'assistant', content: [{ type: 'output_text', text }] };
}

function responseEvent(type, payload) {
  return `event: ${type}\ndata: ${JSON.stringify({ type, ...payload })}\n\n`;
}

function decodeRequest(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch (error) { reject(error); }
    });
    req.on('error', reject);
  });
}

function getWithoutRedirect(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, res => {
      res.resume();
      res.on('end', () => resolve({ status: res.statusCode, location: res.headers.location }));
    });
    req.on('error', reject);
  });
}

class FakeServers {
  constructor() {
    this.provider = null;
    this.auth = null;
    this.providerUrl = null;
    this.authUrl = null;
    this.script = null;
    this.requests = [];
    this.responseItems = [];
    this.toolResults = [];
    this.seenToolResults = new Set();
    this.responses = [];
    this.authRequests = [];
    this.authorizeRequests = [];
    this.authorizationCodes = new Map();
    this.usedAuthorizationCodes = new Set();
    this.refreshRequests = 0;
    this.rejectRefresh = false;
    this.grantedScope = DEFAULT_SCOPE;
    this.currentAccessToken = FAKE_ACCESS_TOKEN;
    this.currentRefreshToken = FAKE_REFRESH_TOKEN;
    this.pauseAt = null;
    this.pauseGates = new Map();
    this.reached = new Map();
    this.kindCounts = new Map();
    this.serverErrors = [];
    this.commandObserver = null;
  }

  async start() {
    this.provider = http.createServer((req, res) => {
      this.handleProvider(req, res).catch(error => {
        this.serverErrors.push(error);
        if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
        if (!res.writableEnded) res.end(JSON.stringify({ error: { code: 'server_error', message: `fake provider failure: ${error.message}` } }));
      });
    });
    this.auth = http.createServer((req, res) => {
      this.handleAuth(req, res).catch(error => {
        this.serverErrors.push(error);
        if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
        if (!res.writableEnded) res.end(JSON.stringify({ error: 'fake authorization server failure' }));
      });
    });
    await Promise.all([this.listen(this.provider), this.listen(this.auth)]);
    this.providerUrl = `http://127.0.0.1:${this.provider.address().port}`;
    this.authUrl = `http://127.0.0.1:${this.auth.address().port}`;
  }

  listen(server) {
    return new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
  }

  async close() {
    for (const gate of this.pauseGates.values()) gate.resolve();
    const servers = [this.provider, this.auth].filter(Boolean);
    const closing = servers.map(server => new Promise(resolve => {
      if (!server.listening) return resolve();
      server.close(() => resolve());
      server.closeAllConnections?.();
    }));
    await Promise.all(closing);
  }

  dispose() {
    this.commandObserver = null;
    this.script = null;
    this.requests = [];
    this.responseItems = [];
    this.toolResults = [];
    this.seenToolResults = new Set();
    this.responses = [];
    this.authRequests = [];
    this.authorizeRequests = [];
    this.serverErrors = [];
    this.pauseGates.clear();
    this.reached.clear();
    this.kindCounts.clear();
    this.authorizationCodes.clear();
    this.usedAuthorizationCodes.clear();
    this.provider = null;
    this.auth = null;
  }

  configure(name, pauseAt = null, args = {}) {
    this.script = { name, args };
    this.pauseAt = pauseAt;
    this.kindCounts.clear();
    this.requests = [];
    this.responseItems = [];
    this.toolResults = [];
    this.seenToolResults = new Set();
    this.responses = [];
    this.reached.clear();
    this.pauseGates.clear();
  }

  setGrant(scope) { this.grantedScope = scope; }
  rejectNextRefresh() { this.rejectRefresh = true; }

  async handleAuth(req, res) {
    const url = new URL(req.url, this.authUrl || 'http://127.0.0.1');
    if (req.method === 'GET' && url.pathname === '/api/accounts/authorize') {
      const params = Object.fromEntries(url.searchParams.entries());
      this.authorizeRequests.push(params);
      const callback = new URL(params.redirect_uri);
      const code = `fake-code-${this.authorizeRequests.length}`;
      this.authorizationCodes.set(code, params);
      callback.searchParams.set('code', code);
      callback.searchParams.set('state', params.state);
      callback.searchParams.set('client_id', 'oaiapp_test');
      callback.searchParams.set('scope', this.grantedScope);
      res.writeHead(302, { location: callback.toString() });
      res.end();
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/accounts/oauth/token') {
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const params = Object.fromEntries(new URLSearchParams(Buffer.concat(chunks).toString('utf8')));
      this.authRequests.push(params);
      if (params.grant_type === 'authorization_code') {
        const auth = this.authorizationCodes.get(params.code);
        const challenge = typeof params.code_verifier === 'string'
          ? crypto.createHash('sha256').update(params.code_verifier).digest('base64url')
          : '';
        const valid = auth
          && !this.usedAuthorizationCodes.has(params.code)
          && params.client_id === 'oaiapp_test'
          && params.redirect_uri === auth.redirect_uri
          && auth.code_challenge_method === 'S256'
          && challenge === auth.code_challenge;
        if (!valid) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid_grant' }));
          return;
        }
        this.usedAuthorizationCodes.add(params.code);
        this.currentAccessToken = FAKE_ACCESS_TOKEN;
        this.currentRefreshToken = FAKE_REFRESH_TOKEN;
        const payload = Buffer.from(JSON.stringify({ email: 'user@example.com', nonce: auth.nonce })).toString('base64url');
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          access_token: this.currentAccessToken,
          refresh_token: this.currentRefreshToken,
          id_token: `fake.${payload}.signature`,
          expires_in: 3600,
          scope: this.grantedScope,
        }));
        return;
      }
      if (params.grant_type === 'refresh_token') {
        this.refreshRequests++;
        if (this.rejectRefresh) {
          this.rejectRefresh = false;
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid_grant' }));
          return;
        }
        if (params.refresh_token !== this.currentRefreshToken) {
          res.writeHead(400, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid_grant' }));
          return;
        }
        this.currentAccessToken = `KOGEN_ACCEPTANCE_REFRESHED_ACCESS_TOKEN_${this.refreshRequests}`;
        this.currentRefreshToken = this.refreshRequests === 1 ? ROTATED_REFRESH_TOKEN : `${ROTATED_REFRESH_TOKEN}_${this.refreshRequests}`;
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          access_token: this.currentAccessToken,
          refresh_token: this.currentRefreshToken,
          expires_in: 3600,
        }));
        return;
      }
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
  }

  async handleProvider(req, res) {
    if (req.method !== 'POST' || req.url !== '/v1/responses') {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { code: 'not_found', message: 'not found' } }));
      return;
    }
    if (req.headers.authorization !== `Bearer ${this.currentAccessToken}`) {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { code: 'unauthorized', message: 'unauthorized' } }));
      return;
    }
    const body = await decodeRequest(req);
    const tools = (body.tools || []).map(tool => tool.name);
    const kind = !Array.isArray(body.tools) ? 'unknown' : tools.includes('submit_configuration') ? 'init' : tools.includes('submit_review') ? 'review' : tools.includes('submit') ? 'shape' : 'build';
    const record = { order: this.requests.length + 1, kind, body, tools, text: flatten(body).join('\n'), receivedAt: Date.now() };
    this.requests.push(record);
    for (const item of body.input || []) {
      if (item.type === 'function_call_output' && !this.seenToolResults.has(item.call_id)) {
        const call = this.responseItems.find(value => value.callId === item.call_id);
        this.toolResults.push({ ...(call || {}), callId: item.call_id, output: item.output, requestOrder: record.order });
        this.seenToolResults.add(item.call_id);
      }
    }
    const ordinal = (this.kindCounts.get(kind) || 0) + 1;
    this.kindCounts.set(kind, ordinal);

    const outcome = this.script ? this.scriptResponse(record, ordinal) : { items: [message('') ] };
    if (this.pauseAt === 'tool command running' && kind === 'build' && !outcome.items.some(item => item.type === 'function_call' && item.name === 'shell')) {
      outcome.items.unshift(functionCall('shell', { command: 'sleep 600' }, `pause_tool_${record.order}`));
    }
    if (outcome.status) {
      res.writeHead(outcome.status, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: outcome.error }));
      return;
    }
    if (outcome.cut) {
      res.writeHead(200, { 'content-type': 'text/event-stream', connection: 'close' });
      res.write(responseEvent('response.created', { response: { id: `resp_${record.order}` } }));
      res.end();
      return;
    }
    if (outcome.hang) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      res.flushHeaders();
      res.write(responseEvent('response.created', { response: { id: `resp_${record.order}` } }));
      this.mark(outcome.hang, record);
      return;
    }

    const calls = outcome.items.filter(item => item.type === 'function_call');
    this.responses.push({ order: record.order, kind, items: outcome.items, body });
    this.responseItems.push(...calls.map(call => ({ requestOrder: record.order, kind, name: call.name, args: safeJson(call.arguments), callId: call.call_id })));
    if (calls.some(call => call.name === 'shell')) {
      const shell = calls.find(call => call.name === 'shell');
      const command = safeJson(shell.arguments).command;
      this.mark('tool command running', { ...record, command });
      if (this.commandObserver) this.commandObserver(command, record);
    }


    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    res.flushHeaders();
    res.write(responseEvent('response.created', { response: { id: `resp_${record.order}` } }));
    for (let i = 0; i < outcome.items.length; i++) {
      const item = outcome.items[i];
      res.write(responseEvent('response.output_item.added', { output_index: i, item: { ...item, arguments: item.type === 'function_call' ? '' : undefined } }));
      if (item.type === 'function_call') {
        const argText = item.arguments;
        const chunks = outcome.fragmented ? fragments(argText) : [argText];
        for (const delta of chunks) {
          res.write(responseEvent('response.function_call_arguments.delta', { output_index: i, item_id: item.id, delta }));
        }
      }
      res.write(responseEvent('response.output_item.done', { output_index: i, item }));
    }

    const pause = outcome.pause || (this.pauseAt && this.pauseMatches(this.pauseAt, kind, outcome.items) ? this.pauseAt : null);
    if (outcome.hang) {
      this.mark(outcome.hang, record);
      return;
    }
    if (pause) await this.pause(pause, record);
    res.end(responseEvent('response.completed', {
      response: { usage: { input_tokens: 100, input_tokens_details: { cached_tokens: 5 }, output_tokens: 20, output_tokens_details: { reasoning_tokens: 10 } } },
    }));
  }

  pauseMatches(point, kind, items) {
    if (point === 'builder request in flight') return kind === 'build';
    if (point === 'finish') return kind === 'build' && items.some(item => item.name === 'finish');
    if (point === 'review approved') return kind === 'review' && items.some(item => item.name === 'submit_review' && safeJson(item.arguments).verdict === 'approve');
    return false;
  }

  mark(point, record) {
    if (!this.reached.has(point)) {
      let resolve;
      const promise = new Promise(done => { resolve = done; });
      this.reached.set(point, { promise, resolve, record });
    }
  }

  async pause(point, record) {
    this.mark(point, record);
    if (!this.pauseGates.has(point)) {
      let resolve;
      const promise = new Promise(done => { resolve = done; });
      this.pauseGates.set(point, { promise, resolve });
    }
    await this.pauseGates.get(point).promise;
  }

  continue() {
    for (const gate of this.pauseGates.values()) gate.resolve();
    this.pauseGates.clear();
  }

  async waitReached(point, timeoutMs = 30000) {
    const start = Date.now();
    while (!this.reached.has(point)) {
      if (Date.now() - start > timeoutMs) throw new Error(`fake server did not reach ${point}`);
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    return this.reached.get(point).record;
  }

  toolOutput(record, name, matches = () => true) {
    for (const item of record.body.input || []) {
      if (item.type !== 'function_call_output') continue;
      const call = this.responseItems.find(value => value.callId === item.call_id);
      if (call?.name === name && matches(call.args)) return { call, output: String(item.output ?? '') };
    }
    return null;
  }

  hasToolOutput(record, name, matches = () => true) {
    return this.toolOutput(record, name, matches) !== null;
  }

  builderCarried(marker) {
    return this.requests.some(request => request.kind === 'build' && request.text.includes(marker));
  }



  scriptResponse(record, ordinal) {
    const name = this.script.name;
    const args = this.script.args || {};
    if (name === 'usage-limit') return { status: 429, error: { code: 'subscription_sharing_usage_limit_exceeded', message: 'usage limit', resets_at: '2030-01-01T00:00:00Z' } };
    if (name === 'model-unavailable') return { status: 400, error: { code: 'subscription_sharing_unsupported_capability', message: 'model unavailable', param: 'model' } };
    if (name === '400-bad-request') return { status: 400, error: { code: 'invalid_request', message: 'bad request' } };
    if (name === '500-always' || (name === 'build-then-500-always' && record.kind === 'build' && this.hasToolOutput(record, 'write_file', args => args.path === 'calc.py'))) return { status: 500, error: { code: 'server_error', message: 'server error' } };
    if (name === '401-then-ok' && this.requests.length === 1) return { status: 401, error: { code: 'unauthorized', message: 'unauthorized' } };
    if (name === 'stream-cut-then-ok' && this.requests.length === 1) return { cut: true };

    if (record.kind === 'init') return this.initResponse(name, ordinal);
    if (record.kind === 'shape') return this.shapeResponse(name, ordinal, record);
    if (record.kind === 'review') return this.reviewResponse(name, ordinal, record);
    if (record.kind === 'build') return this.buildResponse(name, ordinal, record, args);
    return { items: [message('')] };
  }

  // The init request (SET-11): one submit_configuration call.
  initResponse(name, ordinal) {
    const config = { setup: [], fix: [], checks: [], protect: [] };
    if (name === 'init-proposes-docs-check') config.checks = [{ name: 'docs', run: 'node docs-check.js' }];
    if (name === 'init-invalid-twice') config.checks = [{ name: 'Docs Check', run: 'node docs-check.js' }];
    if (name === 'init-corrects-dependency-protect' && ordinal === 1) config.protect = ['.formatter.exs', 'mix.exs'];
    if (name === 'init-corrects-dependency-protect' && ordinal === 2) config.protect = ['.formatter.exs'];
    if (name === 'init-proposes-setup') config.setup = ['mkdir seeded', 'echo run >> runs.txt', 'true'];
    return { items: [functionCall('submit_configuration', config, `init_submit_${ordinal}`)] };
  }

  shapeResponse(name, ordinal, record) {
    const files = intentFiles('is-even');
    switch (name) {
      case 'shape-asks-one':
        return { items: [functionCall('submit', { questions: [{ question: 'What should is_even do with a non-integer?', options: [{ label: 'raise TypeError', recommended: true }, { label: 'return False' }] }] }, `shape_q_${ordinal}`)] };
      case 'shape-asks-two':
        return { items: [functionCall('submit', { questions: [
          { question: 'What should is_even do with a non-integer?', options: [{ label: 'raise TypeError', recommended: true }, { label: 'return False' }] },
          { question: 'Should the helper accept booleans?', options: [{ label: 'follow Python integer behavior', recommended: true }, { label: 'raise TypeError' }] },
        ] }, `shape_q2_${ordinal}`)] };
      case 'shape-asks-one-then-writes':
        return record.text.includes('1: a')
          ? { items: [functionCall('submit', { files: intentFiles('is-even', { decision: '(source: answer 1)' }) }, `shape_answer_${ordinal}`)] }
          : this.shapeResponse('shape-asks-one', ordinal, record);
      case 'shape-asks-two-then-writes':
        return record.text.includes('1: a') && record.text.includes('2: a')
          ? { items: [functionCall('submit', { files: intentFiles('is-even', { decision: '(source: answer 1)\n- Booleans follow Python integer behavior. (source: answer 2)' }) }, `shape_answers_${ordinal}`)] }
          : this.shapeResponse('shape-asks-two', ordinal, record);
      case 'shape-not-ready-then-asks':
        return record.text.includes('undefined step: When the caller doubles 4')
          ? { items: [functionCall('submit', { questions: [{ question: 'What should is_even do with a non-integer?', options: [{ label: 'raise TypeError', recommended: true }, { label: 'return False' }] }] }, `shape_after_not_ready_${ordinal}`)] }
          : { items: [functionCall('submit', { files: intentFiles('is-even', { undefinedStep: true }) }, `shape_not_ready_${ordinal}`)] };
      case 'shape-invalid-three-times':
        return { items: [functionCall('submit', { files: [{ path: '../forbidden.txt', content: 'no' }] }, `shape_invalid_${ordinal}`)] };
      case 'shape-protected-conflict':
        return { items: [functionCall('submit', { blocked: { paths: ['.style.cfg'], reason: 'the requested check definition must change' } }, `shape_blocked_${ordinal}`)] };
      case 'shape-failed-and-undefined-step':
        return { items: [functionCall('submit', { files: intentFiles('is-even', { undefinedStep: true, failedFirst: true }) }, `shape_mixed_${ordinal}`)] };
      case 'shape-undefined-step':
        return { items: [functionCall('submit', { files: intentFiles('is-even', { undefinedStep: true }) }, `shape_undefined_${ordinal}`)] };
      case 'shape-failing-invariant':
        return { items: [functionCall('submit', { files: counterFiles(true) }, `shape_model_${ordinal}`)] };
      case 'shape-probes-then-writes':
        {
          const result = this.toolOutput(record, 'probe');
          if (!result) return { items: [functionCall('probe', { command: "python3 -c 'print(1.5 % 2)'" }, `shape_probe_${ordinal}`)] };
          return { items: [functionCall('submit', { files: intentFiles('is-even', { feasibility: probeFeasibility(result.output, 'Python returns a remainder of 1.5.') }) }, `shape_probe_submit_${ordinal}`)] };
        }
      case 'shape-probe-hangs-then-writes':
        {
          const result = this.toolOutput(record, 'probe');
          if (!result) return { items: [functionCall('probe', { command: 'sleep 600' }, `shape_hang_${ordinal}`)] };
          return { items: [functionCall('submit', { files: intentFiles('is-even', { feasibility: probeFeasibility(result.output, 'The probe exceeded its execution deadline.') }) }, `shape_hang_submit_${ordinal}`)] };
        }
      case 'shape-edits-existing-step-file':
        return { items: [functionCall('submit', { files: intentFiles('is-even', { extraStep: true }) }, `shape_edit_${ordinal}`)] };
      case '401-then-ok':
      case 'stream-cut-then-ok':
      case 'shape-ready-is-even':
      default:
        return { items: [
          functionCall('list_files', { path: '.' }, `shape_list_${ordinal}`),
          functionCall('read_file', { path: 'README.md' }, `shape_readme_${ordinal}`),
          functionCall('read_file', { path: 'features/steps/calc_steps.js' }, `shape_steps_${ordinal}`),
          functionCall('submit', { files }, `shape_submit_${ordinal}`),
        ] };
    }
  }

  buildResponse(name, ordinal, record, args) {
    const correct = correctFiles();
    const wrong = wrongFiles();
    const writeFiles = list => list.map((file, i) => functionCall('write_file', file, `build_${name}_${ordinal}_${i}`));
    const finish = () => functionCall('finish', { summary: 'Implementation complete.' }, `finish_${name}_${ordinal}`);
    const calls = list => ({ items: [...writeFiles(list), finish()] });
    if (name === 'build-runs-command') {
      const command = args.command || 'true';
      if (!this.hasToolOutput(record, 'shell', value => value.command === command)) {
        return { items: [functionCall('shell', { command }, `build_shell_${ordinal}`)] };
      }
      return calls(correct);
    }
    if (name === 'build-with-background-server') {
      const start = 'python3 -m http.server 8765 > server.log 2>&1 &';
      const wait = 'for i in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8765/ && break; sleep 0.1; done';
      const curl = 'curl -s -o /dev/null -w %{http_code} http://127.0.0.1:8765/';
      if (!this.hasToolOutput(record, 'shell', value => value.command === start)) return { items: [functionCall('shell', { command: start }, `server_${ordinal}`)] };
      if (!this.hasToolOutput(record, 'shell', value => value.command === wait)) return { items: [functionCall('shell', { command: wait }, `wait_server_${ordinal}`)] };
      if (!this.hasToolOutput(record, 'shell', value => value.command === curl)) return { items: [functionCall('shell', { command: curl }, `curl_${ordinal}`)] };
      return calls(correct);
    }
    if (name === 'build-three-calls-fragmented') {
      const complete = ['call_fragment_write', 'call_fragment_shell', 'call_fragment_unknown']
        .every(callId => (record.body.input || []).some(item => item.type === 'function_call_output' && item.call_id === callId));
      if (!complete) {
        return { items: [
          functionCall('write_file', { path: 'a.txt', content: 'hello' }, 'fragment_write'),
          functionCall('shell', { command: 'cat a.txt missing.txt' }, 'fragment_shell'),
          functionCall('bogus_tool', { name: 'bogus_tool' }, 'fragment_unknown'),
        ], fragmented: true };
      }
      return calls(correct);
    }
    if (name === 'build-context-overflow') {
      if (!this.hasToolOutput(record, 'write_file', value => value.path === wrong[0].path)) return { items: [functionCall('write_file', wrong[0], 'context_edit')] };
      return { status: 400, error: { code: 'context_length_exceeded', message: 'context too long' } };
    }
    if (name === 'build-tries-path') {
      if (!this.hasToolOutput(record, 'write_file', value => value.path === args.path)) {
        return { items: [functionCall('write_file', { path: args.path, content: 'attempted protected edit\n' }, `protected_write_${ordinal}`)] };
      }
      return calls(correct);
    }
    if (name === 'build-then-500-always' && !this.hasToolOutput(record, 'write_file', value => value.path === 'calc.py')) return { items: [functionCall('write_file', wrong[0], 'provider_edit')] };
    if (name === 'build-review-changes-then-fixed') {
      const unchecked = correct.map(file => file.path === 'calc.py'
        ? { ...file, content: file.content.replace('not isinstance(n, int) or isinstance(n, bool)', 'n == 1.5') } : file);
      return calls(unchecked);
    }
    if (name === 'build-adds-unrequested-option-then-removes-it') {
      return { items: [...writeFiles(correct), functionCall('write_file', { path: 'calc_config.py', content: 'OPTION = True\n' }, `add_option_${ordinal}`), finish()] };
    }
    if (name === 'build-unformatted-then-formatted' && !record.text.includes('files changed while checks ran: calc.py')) {
      const list = correct.map(file => file.path === 'calc.py' ? { ...file, content: '# unformatted\n' + file.content } : file);
      return calls(list);
    }
    if (name === 'build-wrong-then-repair' && !/Verification pass \d+ is not green\./.test(record.text)) return calls(wrong);
    if (name === 'build-wrong-forever') return calls(wrong);
    return calls(correct);
  }

  reviewResponse(name, ordinal, record) {
    const submit = (verdict, findings, id) => functionCall('submit_review', { verdict, findings }, id);
    const approve = (id = `review_approve_${ordinal}`) => submit('approve', [{ path: 'calc.py', line: 12, severity: 'note', message: 'the docstring could name TypeError' }], id);
    const output = id => (record.body.input || []).some(item => item.type === 'function_call_output' && item.call_id === `call_${id}`);
    if (name === 'build-review-invalid-twice') return { items: [submit('invalid', [], `review_invalid_${ordinal}`)] };
    if (name === 'build-review-unresolved') {
      return { items: [submit('changes', [{ path: 'calc.py', line: 1, severity: 'blocking', message: 'Required behavior cannot be repaired within the approved Intent.' }], 'review_blocked')] };
    }
    if (name === 'build-review-changes-then-fixed') {
      if (output('review_direct_fix')) return { items: [approve()] };
      return { items: [functionCall('write_file', correctFiles()[0], 'review_direct_fix')] };
    }
    if (name === 'build-review-repair-fails-once') {
      if (record.text.includes('Final verification of your repairs failed.')) {
        if (output('review_failed_fix_correct')) return { items: [approve()] };
        return { items: [functionCall('write_file', correctFiles()[0], 'review_failed_fix_correct')] };
      }
      if (output('review_failed_fix_broken')) return { items: [approve()] };
      return { items: [functionCall('write_file', wrongFiles()[0], 'review_failed_fix_broken')] };
    }
    if (name === 'build-adds-unrequested-option-then-removes-it') {
      if (output('review_remove_option')) return { items: [approve()] };
      return { items: [functionCall('shell', { command: 'rm -f calc_config.py' }, 'review_remove_option')] };
    }
    if (name === 'build-leaves-old-helper-then-removes-it') {
      if (output('review_remove_helper')) return { items: [approve()] };
      if (this.toolOutput(record, 'read_file', value => value.path === 'legacy_parity.py')) {
        return { items: [functionCall('shell', { command: 'rm -f legacy_parity.py' }, 'review_remove_helper')] };
      }
      return { items: [functionCall('read_file', { path: 'legacy_parity.py' }, 'read_legacy')] };
    }
    if (name === 'build-review-demands-baseline-change') {
      if (output('review_baseline_write')) return { items: [approve()] };
      return { items: [functionCall('write_file', { path: '.kogen/intents/is-even/acceptance.feature', content: 'changed' }, 'review_baseline_write')] };
    }
    return { items: [approve()] };
  }


}

function safeJson(value) {
  try { return typeof value === 'string' ? JSON.parse(value) : value; } catch { return {}; }
}

function probeFeasibility(output, summary) {
  const status = output.match(/(?:^|\n)exit status:\s*(-?\d+)/)?.[1];
  const timedOut = output.match(/(?:^|\n)timed_out:\s*(true|false)/)?.[1];
  const wall = output.match(/(?:^|\n)wall:\s*([0-9]+(?:\.[0-9]+)?)\s*s/)?.[1];
  if (status === undefined || timedOut === undefined || wall === undefined) {
    throw new Error(`probe result did not contain exit status, timeout and wall time: ${output}`);
  }
  return `- ${summary} (probe 1: exit ${status}, timed_out: ${timedOut}, ${Number(wall).toFixed(1)} s)`;
}

function fragments(text) {
  const result = [];
  for (let i = 0; i < text.length; i += 7) result.push(text.slice(i, i + 7));
  return result;
}

function waitForAuthorizationUrl(record, timeoutMs = 10000) {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const poll = () => {
      const lines = record.stdout.split(/\r?\n/);
      const url = lines.find(line => line.startsWith('http://127.0.0.1:') && line.includes('/api/accounts/authorize?'));
      if (url) return resolve(url);
      if (record.code !== null) return reject(new Error('login exited before printing an authorization URL'));
      if (Date.now() - start > timeoutMs) return reject(new Error('login did not print an authorization URL'));
      setTimeout(poll, 20);
    };
    poll();
  });
}

function intentFiles(slug, options = {}) {
  let feature = options.undefinedStep ? undefinedFeature() : isEvenFeature(options.skipTag);
  if (options.failedFirst) feature = feature.replace('    When the caller doubles 4', '    When I check is_even\n    Then result is True\n    When the caller doubles 4');
  const acceptance = [`.kogen/intents/${slug}/acceptance.feature`, 'features/steps/is_even_steps.js'];
  if (options.extraStep) acceptance.push('features/steps/calc_steps.js');
  const decision = options.decision || '(source: request)';
  const feasibility = options.feasibility || '- none';
  const title = options.period ? 'Add an is-even helper.' : 'Add an is-even helper';
  const intent = `# ${title}\n\nSlug: ${slug}\nModel: not applicable — a pure function without state\nAcceptance:\n${acceptance.map(file => `- ${file}`).join('\n')}\n\ncalc.is_even(n) returns True for even integers and False for odd ones; non-integers raise TypeError.\n\n## Decisions\n- Non-integers raise TypeError instead of returning False. ${decision}\n\n## Tests\n- calc.is_even returns True for even and False for odd integers: add test_is_even in tests/test_calc.py (unit)\n- calc.is_even raises TypeError for a non-integer: add test_is_even_rejects_floats in tests/test_calc.py (unit)\n\n## Feasibility\n${feasibility}\n`;
  const files = [
    { path: `.kogen/intents/${slug}/intent.md`, content: intent },
    { path: `.kogen/intents/${slug}/acceptance.feature`, content: feature },
    { path: 'features/steps/is_even_steps.js', content: isEvenSteps() },
  ];
  if (options.extraStep) {
    files.push({ path: 'features/steps/calc_steps.js', content: `${fs.readFileSync(path.join(__dirname, '../fixtures/projects/py-calc/features/steps/calc_steps.js'), 'utf8')}\n// Shaping added a harmless helper registration.\n` });
  }
  return files;
}

function isEvenFeature(skipTag = false) {
  return `Feature: calc.is_even\n\n  Scenario: Even numbers\n    Given the input is 4\n    When I check is_even\n    Then result is True\n\n  Scenario: Odd numbers\n    Given the input is 3\n    When I check is_even\n    Then result is False\n\n${skipTag ? '  @skip\n' : ''}  Scenario: Non-integers\n    Given the input is 1.5\n    When I check is_even\n    Then a TypeError is raised\n`;
}

function undefinedFeature() {
  return `Feature: calc.is_even\n  Scenario: Even numbers\n    Given the input is 4\n    When I check is_even\n    Then result is True\n  Scenario: Odd numbers\n    Given the input is 3\n    When I check is_even\n    Then result is False\n  Scenario: Undefined caller step\n    Given the input is 4\n    When the caller doubles 4\n    Then result is True\n`;
}

function isEvenSteps() {
  return `const { Given, When, Then } = require('@cucumber/cucumber');\nconst assert = require('node:assert/strict');\nconst { spawnSync } = require('node:child_process');\n\nGiven('the input is {word}', function (value) { this.inputValue = value; });\nWhen('I check is_even', function () {\n  const literal = this.inputValue;\n  this.python = spawnSync('python3', ['-c', \`from calc import is_even; print(is_even(\${literal}))\`], { encoding: 'utf8' });\n});\nThen('result is {word}', function (expected) {\n  if (this.python.status !== 0) throw new Error(this.python.stderr || 'python failed');\n  assert.strictEqual(this.python.stdout.trim(), expected);\n});\nThen('a TypeError is raised', function () {\n  assert.ok(this.python.status !== 0 && this.python.stderr.includes('TypeError'), 'expected TypeError');\n});\n`;
}

function correctFiles() {
  return [
    { path: 'calc.py', content: 'def add(a, b):\n    return a + b\n\ndef is_even(n):\n    if not isinstance(n, int) or isinstance(n, bool):\n        raise TypeError("n must be an integer")\n    return n % 2 == 0\n' },
    { path: 'tests/test_calc.py', content: 'import unittest\n\nfrom calc import add, is_even\n\nclass TestCalc(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n\n    def test_is_even(self):\n        self.assertTrue(is_even(4))\n        self.assertFalse(is_even(3))\n\n    def test_is_even_rejects_float(self):\n        with self.assertRaises(TypeError):\n            is_even(1.5)\n\nif __name__ == "__main__":\n    unittest.main()\n' },
  ];
}

function wrongFiles() {
  return [
    { path: 'calc.py', content: 'def add(a, b):\n    return a + b\n\ndef is_even(n):\n    return True\n' },
    { path: 'tests/test_calc.py', content: 'import unittest\n\nfrom calc import add, is_even\n\nclass TestCalc(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 3), 5)\n\n    def test_is_even(self):\n        self.assertTrue(is_even(4))\n\nif __name__ == "__main__":\n    unittest.main()\n' },
  ];
}

function counterFiles(failing) {
  const feature = `Feature: counter\n\n  Scenario: Counter starts at zero\n    Given the counter is initialized\n    Then its value is non-negative\n`;
  const model = `module counter {\n  var count: int\n  action init = all { count' = 0 }\n  action step = any { init, all { count' = count + 1 } }\n  val NeverNegative = ${failing ? 'false' : 'count >= 0'}\n}\n`;
  const intent = `# Add a bounded counter\n\nSlug: counter\nModel: .kogen/intents/counter/model.qnt invariants=NeverNegative seed=7 samples=500 steps=30\nAcceptance:\n- .kogen/intents/counter/acceptance.feature\n- features/steps/counter_steps.js\n\nA counter starts at zero and stays non-negative.\n\n## Decisions\n- The counter begins at zero. (source: request)\n\n## Tests\n- Counter state initializes at zero and remains non-negative through increments: add test_counter_state in tests/test_counter.py (unit)\n\n## Feasibility\n- none\n`;
  const steps = `const { Given, Then } = require('@cucumber/cucumber');\nGiven('the counter is initialized', function () {});\nThen('its value is non-negative', function () {});\n`;
  return [
    { path: '.kogen/intents/counter/intent.md', content: intent },
    { path: '.kogen/intents/counter/acceptance.feature', content: feature },
    { path: '.kogen/intents/counter/model.qnt', content: model },
    { path: 'features/steps/counter_steps.js', content: steps },
  ];
}

module.exports = {
  FakeServers,
  FAKE_ACCESS_TOKEN,
  FAKE_REFRESH_TOKEN,
  ROTATED_REFRESH_TOKEN,
  DEFAULT_SCOPE,
  flatten,
  functionCall,
  message,
  getWithoutRedirect,
  waitForAuthorizationUrl,
  intentFiles,
  isEvenFeature,
  isEvenSteps,
  correctFiles,
  wrongFiles,
  counterFiles,
};
