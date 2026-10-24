'use strict';
// A scripted local provider for the replay journeys: the Responses endpoint of ChatGPT on loopback, fake tokens
// only. The script decides each answer: script(record, nthOfKind) -> {items} | {hold: true} | {status}. A request
// nobody scripted is answered with a 500 and recorded.
const http = require('node:http');

const TOKEN = 'REPLAY_FAKE_CHATGPT_ACCESS';
const REFRESH = 'REPLAY_FAKE_CHATGPT_REFRESH';

const call = (name, args, id) => ({ type: 'function_call', id: `item_${id}`, call_id: `call_${id}`, name, arguments: JSON.stringify(args) });

async function startFake() {
  // A mutant may loop for ever; past `limit` requests the provider refuses (400, not retried) and the Build ends.
  const fake = { requests: [], script: () => ({ status: 500 }), held: [], waiters: [], sockets: new Set(), limit: 16 };
  let serial = 0;
  fake.next = (predicate, ms = 180000) => new Promise((resolve, reject) => {
    const hit = fake.requests.find(predicate);
    if (hit) return resolve(hit);
    const w = { predicate, resolve };
    w.timer = setTimeout(() => reject(new Error(`the scripted provider never saw the request the journey waits for (${fake.requests.length} request(s) so far)`)), ms);
    fake.waiters.push(w);
  });
  const notify = record => {
    for (const w of fake.waiters.filter(w => w.predicate(record))) { clearTimeout(w.timer); w.resolve(record); }
    fake.waiters = fake.waiters.filter(w => !w.predicate(record));
  };
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const b of req) chunks.push(b);
    let body = null;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch {}
    const names = ((body && body.tools) || []).map(t => t.name);
    const kind = names.includes('submit_review') ? 'review' : names.includes('submit_configuration') ? 'init' : names.includes('submit_refinement') ? 'refine' : names.includes('submit') ? 'shape' : 'build';
    const record = { url: req.url, kind, headers: req.headers, body, held: false };
    fake.requests.push(record);
    if (req.method !== 'POST' || req.url !== '/v1/responses' || req.headers.authorization !== `Bearer ${TOKEN}`) {
      res.writeHead(401, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: { code: 'invalid_api_key', message: 'replay fixture: wrong credential' } }));
    }
    if (fake.requests.length > fake.limit) {
      res.writeHead(400, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: { code: 'invalid_request_error', message: 'replay fixture: request limit reached' } }));
    }
    const outcome = await fake.script(record,fake.requests.filter(r => r.kind === kind).length);
    if (outcome.status) {
      notify(record);
      res.writeHead(outcome.status, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: { code: 'invalid_request_error', message: 'replay fixture: no scripted answer' } }));
    }
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    const event = (type, more) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...more })}\n\n`);
    event('response.created', { response: { id: `response_${++serial}` } });
    if (outcome.hold) { // the answer never comes; the request ends when kogen goes away
      record.held = true; fake.held.push(record); notify(record);
      return new Promise(resolve => res.once('close', resolve));
    }
    notify(record);
    outcome.items.forEach((item, i) => event('response.output_item.done', { output_index: i, item }));
    event('response.completed', { response: { id: `response_${serial}`, output: outcome.items, usage: { input_tokens: 100, input_tokens_details: { cached_tokens: 5 }, output_tokens: 20, output_tokens_details: { reasoning_tokens: 10 } } } });
    res.end();
  });
  server.on('connection', s => { fake.sockets.add(s); s.once('close', () => fake.sockets.delete(s)); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  fake.url = `http://127.0.0.1:${server.address().port}`;
  fake.close = async () => { for (const s of fake.sockets) s.destroy(); await new Promise(resolve => server.close(resolve)); };
  return fake;
}

module.exports = { startFake, call, TOKEN, REFRESH };
