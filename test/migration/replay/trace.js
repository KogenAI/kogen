'use strict';
// Observations -> a Quint file. The generator only translates: each observed production event becomes the model
// action it names (table in docs/evidence/go-core-migration/replay.md) and each observed state becomes an
// `.expect(...)` on that step. It never decides what the model should answer; the model decides whether the
// expectations hold. Candidate versions are numbered in the order the trees were first observed (the start
// candidate is 0, as in `init`).

const camel = (...parts) => parts.join('-').split(/[^A-Za-z0-9]+/).filter(Boolean).map((w, i) => (i ? w[0].toUpperCase() + w.slice(1) : w)).join('');
const q = s => JSON.stringify(s);
const MAX_STEPS = 24;

// What the model's phase is after an event, read from the next thing the Build was observed doing.
function phaseFromNext(events, i, fallback) {
  for (let j = i + 1; j < events.length; j++) {
    const e = events[j], before = events[j - 1];
    switch (e.k) {
      case 'request': return e.role === 'review' ? 'Reviewing' : 'Loop';
      case 'pass': return before.k === 'review' ? 'FinalVerifying' : before.k === 'resume' && before.reopen ? 'RetryVerifying' : 'Verifying';
      case 'review': return 'Reviewing';
      case 'commit': return 'Committing';
      case 'blocker': return e.valid ? 'Failed' : 'Loop';
      case 'outcome': return e.outcome === 'landed' ? 'Done' : e.outcome === 'interrupted' ? 'Interrupted' : 'Failed';
      default: break;
    }
  }
  return fallback;
}

// The model phase an observed state shows: the Build's own stage, or Done when the commit is on the branch.
function phaseOf(snap) {
  if (snap.commits.length > 0) return 'Done';
  if (snap.outcome) return snap.outcome === 'landed' ? 'Done' : snap.outcome === 'interrupted' ? 'Interrupted' : 'Failed';
  switch (snap.stage) {
    case 'builder_verify': return 'Verifying';
    case 'review': return 'Reviewing';
    case 'tool': return snap.owner === 'review' ? 'Reviewing' : 'Loop';
    case 'review_retry_verify': return 'RetryVerifying';
    case 'review_verify': return 'Reviewing';
    case 'commit': return 'Committing';
    case 'landed': return 'Done';
    default: return 'Loop';
  }
}

function reasonOf(snap) {
  if (snap.commits.length > 0 || snap.outcome === 'landed') return 'commit';
  return snap.outcome || '';
}

function chainTest(journey, chain) {
  const modelVersions = new Map();
  const ver = tree => {
    if (!modelVersions.has(tree)) modelVersions.set(tree, modelVersions.size);
    return modelVersions.get(tree);
  };
  // Number the trees in order of observation.
  for (const s of chain.snapshots) { ver(s.candidate); for (const e of s.events) if (e.tree) ver(e.tree); }
  for (const s of chain.snapshots) ver(s.headTree);

  const steps = []; // {action, expect, comment}
  let clean = -1, reviewed = -1, cand = ver(chain.snapshots[0].candidate), reopened = false;
  const outcomes = new Map(); // run id -> outcome, for what a resume continues
  for (const s of chain.snapshots) if (s.outcome) outcomes.set(s.run, s.outcome);
  const inv = 'Safety';

  const state = snap => {
    const parts = [`phase == ${phaseOf(snap)}`, `cand == ${ver(snap.candidate)}`, `cleanPassVersion == ${clean}`, `reviewedVersion == ${reviewed}`,
      `commits == ${snap.commits.length}`, `baselineIntact == ${snap.baselineIntact}`, `headMoved == ${snap.foreignCommits > 0}`, `reason == ${q(reasonOf(snap))}`];
    if (snap.commits.length > 0) parts.push(`committedVersion == ${ver(snap.commits[snap.commits.length - 1].tree)}`);
    return `${parts.join(' and ')} and ${inv}`;
  };
  const partial = (phase, c = cand) => `phase == ${phase} and cand == ${c} and cleanPassVersion == ${clean} and reviewedVersion == ${reviewed} and ${inv}`;

  chain.snapshots.forEach((snap, si) => {
    const first = si === 0, before = steps.length, prev = chain.snapshots[si - 1];
    const fallback = phaseOf(snap);
    const evs = snap.events.map(e => ({ ...e, ...(e.k === 'resume' ? { reopen: outcomes.get(e.parent) === 'review_blocked' } : {}) }));
    // After a commit exists on the branch the model has no transition: a resume (or anything else) can only leave
    // the observed state as it was.
    if (prev && prev.commits.length > 0) {
      steps.push({ action: `move(Done, ${ver(snap.candidate)}, ${clean}, "commit")`, expect: state(snap), comment: `${snap.label}: a commit is on the branch; resume and any later run can only leave it` });
      return;
    }
    evs.forEach((e, i) => {
      const next = phase => phaseFromNext(evs, i, phase);
      switch (e.k) {
        case 'start':
          if (first) steps.push({ action: 'init', expect: null, comment: `${snap.label}: Build ${snap.run} started` });
          break;
        case 'resume': {
          const parentOutcome = outcomes.get(e.parent) || null;
          if (parentOutcome === 'review_blocked') {
            clean = -1; reviewed = -1; reopened = true;
            steps.push({ action: 'reopenBlocked', expect: partial(next('RetryVerifying')), comment: `${snap.label}: resume of Build ${e.parent} (review_blocked) as ${snap.run}` });
          } else {
            steps.push({ action: 'resume', expect: partial(next('Loop')), comment: `${snap.label}: resume of Build ${e.parent} (${parentOutcome || 'no outcome'}) as ${snap.run}` });
          }
          break;
        }
        case 'pass': {
          const c = ver(e.tree);
          cand = c;
          if (reopened) {
            reopened = false;
            if (e.green) clean = c;
            steps.push({ action: `retryVerifyWith(${q(e.green ? 'green' : 'red')})`, expect: partial(e.green ? next('Reviewing') : 'RepairingReview', c), comment: `${snap.label}: fresh verification pass ${e.n} (${e.green ? 'green' : 'red'}) after the reopened blocker` });
            return;
          }
          if (e.green) clean = c;
          steps.push({ action: `move(${e.green ? 'Reviewing' : 'Loop'}, ${c}, ${clean}, "")`, expect: partial(next(e.green ? 'Reviewing' : 'Loop'), c), comment: `${snap.label}: verification pass ${e.n} ${e.green ? 'green' : 'red'}` });
          break;
        }
        case 'review': {
          const c = ver(e.tree);
          if (e.verdict === 'approve') reviewed = c;
          steps.push({ action: `reviewWith(${q(e.verdict)})`, expect: partial(next('Reviewing'), c), comment: `${snap.label}: review ${e.n} verdict ${e.verdict}` });
          break;
        }
        case 'commit': {
          const landed = snap.commits.length > (prev ? prev.commits.length : 0);
          steps.push({ action: `commitWith(${q(landed ? 'ok' : 'commit_failed')})`, expect: partial(next(landed ? 'Done' : 'Failed'), ver(e.tree)), comment: `${snap.label}: commit of the reviewed tree (${landed ? 'a commit is on the branch' : 'no commit on the branch'})` });
          break;
        }
        case 'blocker':
          steps.push({ action: `blockerWith(${e.valid})`, expect: partial(next(e.valid ? 'Failed' : 'Loop')), comment: `${snap.label}: builder blocker (${e.valid ? 'valid' : 'invalid'})` });
          break;
        case 'outcome':
          // landed, review_blocked and build_blocked are what the steps above already did.
          if (['landed', 'review_blocked', 'build_blocked'].includes(e.outcome)) break;
          steps.push({ action: `move(${e.outcome === 'interrupted' ? 'Interrupted' : 'Failed'}, ${cand}, ${clean}, ${q(e.outcome)})`, expect: partial(e.outcome === 'interrupted' ? 'Interrupted' : 'Failed'), comment: `${snap.label}: the Build ended: ${e.outcome}` });
          break;
        default: break;
      }
    });
    if (first && steps.length === 0) steps.push({ action: 'init', expect: null, comment: `${snap.label}: Build ${snap.run}` });
    // The candidate changed without a verification pass (the builder edited files), or nothing happened at all.
    const observed = ver(snap.candidate);
    if (!first && (observed !== cand || steps.length === before)) {
      cand = observed;
      steps.push({ action: `move(${phaseOf(snap)}, ${observed}, ${clean}, ${q(reasonOf(snap))})`, expect: null, comment: `${snap.label}: observed state with no event of its own` });
    }
    // What the harness observed at the end of the window, as the expectation of its last step.
    steps[steps.length - 1].expect = state(snap);
    steps[steps.length - 1].comment += ` | observed at ${snap.label}`;
  });

  // A Build that loops (a mutant can) would give a trace the Quint evaluator cannot nest; the first failing
  // expectation is far earlier, so the rest is cut and said so.
  const cut = steps.length > MAX_STEPS ? steps.length - MAX_STEPS : 0;
  if (cut) steps.length = MAX_STEPS;
  const name = camel(journey, chain.name, 'test');
  const render = (k = steps.length) => {
    const lines = [`  run ${name} =`];
    steps.slice(0, k).forEach((s, i) => {
      lines.push(`    // ${s.comment}`);
      lines.push(i === 0 ? `    ${s.action}` : `    .then(${s.action})`);
      if (s.expect) lines.push(`    .expect(${s.expect})`);
    });
    if (cut && k >= steps.length) lines.push(`    // ${cut} further observed step(s) are not replayed`);
    return lines.join('\n');
  };
  return { name, steps, cut, render };
}

const header = (journey, modelImport) => [
  `// Generated from observations of real kogen runs (journey "${journey}"); see replay.md.`,
  '// Each step is an observed production transition; each .expect is the state that was observed after it.',
  `module ${camel(journey, 'replay')} {`,
  `  import build.* from ${q(modelImport)}`,
  '',
];

// The trace file, and `only(name, k)`: a file holding the first k steps of one test (to find the first failing step).
function generate(journey, chains, modelImport) {
  const tests = chains.map(c => chainTest(journey, c));
  const text = [...header(journey, modelImport), tests.map(t => t.render()).join('\n\n'), '}', ''].join('\n');
  const only = (name, k) => [...header(journey, modelImport), tests.find(t => t.name === name).render(k), '}', ''].join('\n');
  return { text, only, tests: tests.map(t => t.name), steps: tests.map(t => ({ name: t.name, count: t.steps.length, comments: t.steps.map(s => s.comment), actions: t.steps.map(s => s.action) })), cut: tests.map(t => t.cut) };
}

module.exports = { generate };
