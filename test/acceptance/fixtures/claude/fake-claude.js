'use strict';
// A fake `claude` for the acceptance suite. It is not a model: it replays a JSON script
// (fixtures/claude/<name>.json) in the stream-json shape Claude Code printed in the recorded
// receipts, and for every Write/Edit/MultiEdit/NotebookEdit tool call it first runs the
// PreToolUse hook command from the --settings file that Kogen wrote, exactly as Claude Code
// does, so the adapter's hook-liveness rule is satisfied only when Kogen's hook really ran.
//
// Environment: KOGEN_FAKE_CLAUDE_SCRIPT (script path), KOGEN_FAKE_CLAUDE_STATE (a folder
// outside the project where the fake records what it received). Script shape:
//   { version?, auth?, rounds: [ { api_key_source?, end?, claim?, usage?, actions: [
//       { write: {path, content | content_from} }, { edit: {path, old, new} },
//       { bash: "command" }, { sleep: seconds } ] } ] }
// The last round repeats when more `-p` invocations arrive than rounds are scripted.
// The prompt arrives on stdin (Kogen's contract); a positional prompt after -p is still accepted.

const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');

const scriptPath = process.env.KOGEN_FAKE_CLAUDE_SCRIPT;
const state = process.env.KOGEN_FAKE_CLAUDE_STATE;
if (!scriptPath || !state) {
  process.stderr.write('fake claude: not configured\n');
  process.exitCode = 70;
  return;
}
const script = JSON.parse(fs.readFileSync(scriptPath, 'utf8'));
const args = process.argv.slice(2);
const out = value => process.stdout.write(`${JSON.stringify(value)}\n`);
const flag = name => {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : '';
};

if (args.length === 1 && args[0] === '--version') {
  process.stdout.write(`${script.version || '2.1.306 (Claude Code)'}\n`);
  return;
}
if (args[0] === 'auth' && args[1] === 'status') {
  process.stdout.write(`${JSON.stringify(script.auth || { loggedIn: true, authMethod: 'claude.ai', apiProvider: 'firstParty', subscriptionType: 'max' })}\n`);
  return;
}
if (args[0] !== '-p') {
  process.stderr.write('fake claude: unexpected argv\n');
  process.exitCode = 64;
  return;
}

// Claude Code's `-p` reads the prompt from stdin when no positional prompt follows it, which is
// how Kogen sends it. A positional prompt (the first word after -p that is not a flag) is still
// accepted. An empty or closed stdin gives an empty prompt; the read is bounded and never hangs.
const positional = args.length > 1 && !args[1].startsWith('-') ? args[1] : null;

function readPrompt() {
  return new Promise(resolve => {
    if (positional !== null) { resolve(positional); return; }
    if (require('node:tty').isatty(0)) { resolve(''); return; }
    const chunks = [];
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      process.stdin.destroy();
      resolve(Buffer.concat(chunks).toString('utf8'));
    };
    const timer = setTimeout(finish, 10000);
    process.stdin.on('data', chunk => chunks.push(chunk));
    process.stdin.on('end', finish);
    process.stdin.on('close', finish);
    process.stdin.on('error', finish);
  });
}

let n, recordToolCall, sessionId, round, cwd, settings, role, roleN;

// The role this invocation serves: Shape and Review ask for schema-constrained output
// (--json-schema); the schema's properties tell them apart. Build has no schema.
function roleOf() {
  const schema = flag('--json-schema');
  if (!schema) return 'build';
  try {
    return JSON.parse(schema).properties && JSON.parse(schema).properties.verdict ? 'review' : 'shape';
  } catch { return 'shape'; }
}

// Records what the round received and answers with the init event, from the prompt on.
function begin(prompt) {
  fs.mkdirSync(state, { recursive: true });
  const callsFile = path.join(state, 'calls');
  n = fs.existsSync(callsFile) ? Number(fs.readFileSync(callsFile, 'utf8').trim()) + 1 : 1;
  fs.writeFileSync(callsFile, String(n));
  // The prompt is task text (never a credential); it is kept apart from the argv record.
  fs.writeFileSync(path.join(state, `prompt-${n}.txt`), prompt);
  fs.writeFileSync(path.join(state, `argv-${n}.json`), JSON.stringify(positional === null ? args : ['-p', '<prompt>', ...args.slice(2)]));
  fs.writeFileSync(path.join(state, `env-${n}.json`), JSON.stringify(Object.keys(process.env).filter(name => /^(ANTHROPIC_|CLAUDE_)/.test(name)).sort()));
  recordToolCall = (id, name, input) => fs.appendFileSync(path.join(state, 'tool-calls.jsonl'), `${JSON.stringify({ round: n, id, name, file_path: input.file_path || null })}\n`);

  sessionId = flag('--session-id') || flag('--resume');
  // Per-role records (a script with `roles` scripts each role's invocations separately; a script
  // with plain `rounds` is the Build-only script it always was).
  role = roleOf();
  const roleCalls = path.join(state, `calls-${role}`);
  roleN = fs.existsSync(roleCalls) ? Number(fs.readFileSync(roleCalls, 'utf8').trim()) + 1 : 1;
  fs.writeFileSync(roleCalls, String(roleN));
  fs.writeFileSync(path.join(state, `prompt-${role}-${roleN}.txt`), prompt);
  fs.writeFileSync(path.join(state, `argv-${role}-${roleN}.json`), JSON.stringify(positional === null ? args : ['-p', '<prompt>', ...args.slice(2)]));
  fs.appendFileSync(path.join(state, 'sessions.jsonl'), `${JSON.stringify({ role, n: roleN, start: flag('--session-id') || null, resume: flag('--resume') || null })}\n`);
  const scripted = script.roles ? ((script.roles[role] || {}).rounds || []) : (role === 'build' ? script.rounds : []);
  const rounds = scripted && scripted.length ? scripted : [{ actions: [] }];
  round = rounds[Math.min((script.roles ? roleN : n) - 1, rounds.length - 1)];
  cwd = fs.realpathSync(process.cwd());

  out({
    type: 'system', subtype: 'init', cwd, session_id: sessionId, tools: ['Bash', 'Edit', 'MultiEdit', 'NotebookEdit', 'Read', 'Write'],
    mcp_servers: [], model: flag('--model') || 'claude-sonnet-5-5', permissionMode: 'acceptEdits',
    apiKeySource: round.api_key_source || 'none', claude_code_version: String(script.version || '2.1.306').split(' ')[0],
    uuid: `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`,
  });

  settings = (() => {
    try { return JSON.parse(fs.readFileSync(flag('--settings'), 'utf8')); } catch { return {}; }
  })();
}

// Runs the configured hooks of one event for a tool call; returns {denied, outputs}.
function runHooks(event, toolName, payload) {
  let denied = false;
  for (const entry of (settings.hooks && settings.hooks[event]) || []) {
    if (!new RegExp(`^(?:${entry.matcher || '.*'})$`).test(toolName)) continue;
    for (const hook of entry.hooks || []) {
      out({ type: 'system', subtype: 'hook_started', hook_event: event, hook_name: `${event}:${toolName}`, session_id: sessionId });
      const input = JSON.stringify({ session_id: sessionId, cwd, hook_event_name: event, permission_mode: 'acceptEdits', tool_name: toolName, ...payload });
      const result = cp.spawnSync(hook.command, hook.args || [], { input, cwd, env: process.env, encoding: 'utf8' });
      const code = result.error ? 127 : result.status;
      out({ type: 'system', subtype: 'hook_response', hook_event: event, hook_name: `${event}:${toolName}`, stdout: result.stdout || '', stderr: result.stderr || '', exit_code: code, outcome: code === 0 ? 'success' : 'error', session_id: sessionId });
      if (event === 'PreToolUse' && (code === 2 || (code !== 0 && hook.onFailure === 'block') || /"permissionDecision"\s*:\s*"deny"/.test(result.stdout || ''))) denied = true;
    }
  }
  return denied;
}

const denials = [];
function toolUse(id, name, input) {
  recordToolCall(id, name, input);
  out({ type: 'assistant', session_id: sessionId, message: { model: 'claude-sonnet-5-5', role: 'assistant', content: [{ type: 'tool_use', id, name, input }] } });
}
function toolResult(id, content, isError, decision) {
  out({
    type: 'user', session_id: sessionId,
    message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content, is_error: isError }] },
    tool_result_meta: [{ id, permission_decision: { decision } }],
  });
}

// A file tool call: hook first; a denial fails the call without touching the file.
function fileTool(id, name, input, apply) {
  toolUse(id, name, input);
  if (runHooks('PreToolUse', name, { tool_input: input, tool_use_id: id })) {
    denials.push({ tool_name: name, tool_use_id: id, tool_input: input });
    toolResult(id, `PreToolUse:${name} hook error: denied`, true, 'reject');
    return;
  }
  try {
    toolResult(id, apply(), false, 'accept');
  } catch (error) {
    toolResult(id, String(error.message), true, 'accept');
  }
}

function contentOf(write) {
  if (write.content_from) return fs.readFileSync(path.join(path.dirname(scriptPath), 'files', write.content_from), 'utf8');
  return write.content || '';
}

async function main() {
  if (round.api_key_source && round.api_key_source !== 'none') {
    // The adapter must have stopped this process before it acts.
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
  (round.actions || []).forEach((action, index) => {
    const id = `toolu_${n}_${index}`;
    if (action.read) {
      const target = path.join(cwd, action.read);
      toolUse(id, 'Read', { file_path: target });
      let text = '';
      try { text = fs.readFileSync(target, 'utf8'); } catch (error) { text = String(error.message); }
      toolResult(id, text, false, 'accept');
    } else if (action.fetch) {
      // The harness's own research: observed by the harness only.
      toolUse(id, 'WebFetch', { url: action.fetch });
      toolResult(id, `fetched ${action.fetch}`, false, 'accept');
    } else if (action.write) {
      const target = path.join(cwd, action.write.path);
      fileTool(id, 'Write', { file_path: target, content: contentOf(action.write) }, () => {
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, contentOf(action.write));
        return `File created successfully at: ${target}`;
      });
    } else if (action.edit) {
      const target = path.join(cwd, action.edit.path);
      fileTool(id, 'Edit', { file_path: target, old_string: action.edit.old, new_string: action.edit.new }, () => {
        const before = fs.readFileSync(target, 'utf8');
        if (!before.includes(action.edit.old)) throw new Error('String to replace not found in file.');
        fs.writeFileSync(target, before.replace(action.edit.old, () => action.edit.new));
        return `The file ${target} has been updated successfully.`;
      });
    } else if (typeof action.bash === 'string') {
      toolUse(id, 'Bash', { command: action.bash });
      const result = cp.spawnSync('/bin/sh', ['-c', action.bash], { cwd, encoding: 'utf8' });
      const text = `${result.stdout || ''}${result.stderr || ''}`;
      runHooks('PostToolUse', 'Bash', { tool_input: { command: action.bash }, tool_response: { stdout: text }, tool_use_id: id });
      toolResult(id, text, false, 'accept');
    } else if (action.sleep) {
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, action.sleep * 1000);
    }
  });

  const costFile = path.join(state, 'cost');
  const usage = { input_tokens: 10, cache_creation_input_tokens: 200, cache_read_input_tokens: 1000, output_tokens: 50, ...(round.usage || {}) };
  const cost = (fs.existsSync(costFile) ? Number(fs.readFileSync(costFile, 'utf8')) : 0) + 0.01;
  fs.writeFileSync(costFile, String(cost));
  const result = {
    type: 'result', subtype: 'success', is_error: false, duration_ms: 1000, duration_api_ms: 900, num_turns: 3,
    result: round.claim || 'Done.', stop_reason: 'end_turn', terminal_reason: 'completed', session_id: sessionId,
    total_cost_usd: Number(cost.toFixed(6)), usage, permission_denials: denials,
  };
  // Schema-constrained roles report their submission as the final result's structured_output.
  if (role !== 'build') {
    if (round.structured_intent) {
      const { intentFiles } = require('../../support/fake-servers');
      const spec = round.structured_intent;
      let files = intentFiles(spec.name || 'is-even', spec.options || {});
      if (spec.only) files = files.filter(file => spec.only.some(suffix => file.path.endsWith(suffix)));
      if (spec.replace) files = files.map(file => (file.path.endsWith(spec.replace.path) ? { ...file, content: file.content.replace(spec.replace.old, spec.replace.new) } : file));
      result.structured_output = spec.key ? { [spec.key]: files } : { files };
    } else if (Object.prototype.hasOwnProperty.call(round, 'structured')) {
      result.structured_output = round.structured;
    }
  }
  let exit = 0;
  if (round.end === 'max_turns') {
    Object.assign(result, { subtype: 'error_max_turns', is_error: true, terminal_reason: 'max_turns' });
    exit = 1;
  } else if (round.end === 'error') {
    Object.assign(result, { subtype: 'error_during_execution', is_error: true, terminal_reason: 'model_error', errors: ['fake claude error'] });
    exit = 1;
  }
  out(result);
  process.exitCode = exit;
}

readPrompt().then(prompt => { begin(prompt); return main(); }).catch(error => {
  process.stderr.write(`fake claude: ${error && error.stack || error}\n`);
  process.exitCode = 70;
});
