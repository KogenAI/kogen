// The fake ChatGPT script "build-runs-command-twice": the Build issues the same shell command twice in one
// attempt (a second edit of the same protected file), then finishes with the correct implementation.
// Each call is made only after the paired result of the earlier one has come back.
function buildRunsCommandTwice({ server, record, args, ordinal, functionCall, finishCalls }) {
  const command = args.command || 'true';
  const done = (record.body.input || []).filter(item => {
    if (item.type !== 'function_call_output') return false;
    const call = server.responseItems.find(value => value.callId === item.call_id);
    return call?.name === 'shell' && call.args?.command === command;
  }).length;
  if (done >= 2) return finishCalls();
  return { items: [functionCall('shell', { command }, `build_shell_twice_${done + 1}_${ordinal}`)] };
}

module.exports = { buildRunsCommandTwice };
