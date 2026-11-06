# Say which runs exist for an unknown inspect id

Slug: k-cli-inspect-unknown-run-names-next-command
Model: not applicable — the change words one stateless error answer of a read-only command; it has no state or interacting rules
Acceptance:
- .kogen/intents/k-cli-inspect-unknown-run-names-next-command/acceptance.feature
- features/steps/k-cli-inspect-unknown-run-names-next-command__steps.js

`kogen intent inspect <run-id>` for an id with no record currently prints one line of JSON whose `error` is `{"class":"intent","detail":"run_not_found","paths":[],"reason":"run_not_found"}` and exits 1. A person reading a terminal gets raw JSON without a sentence, nothing says how to find a valid run id, and a malformed id and a well-formed id with no record get the same answer. This Intent makes that answer say which of the two it is and name the command that lists run ids.

The change is in `localRead` in `cli/facts.go`, in the `kind == "run"` branch, which has two exits that return `run_not_found` today (an id that does not match `runID`, `^[a-f0-9]{8}$`, and a well-formed id with no `.kogen/local/facts/<id>.json`). The existing `runID` pattern decides what is malformed.

**JSON (every invocation, terminal or not).** The object stays `{schema_version, kind: "run", checkout, data: null, error}`; `checkout`, `data`, `kind`, `schema_version`, the exit code (1), `error.class` (`intent`), `error.reason` (`run_not_found`) and `error.paths` (`[]`) are unchanged. `error.detail` changes from the repeated reason to the text below, and `error` gains one string field `next`:

| Case | `error.detail` | `error.next` |
| --- | --- | --- |
| id does not match the existing `runID` pattern (for example `run-1`) | the not-a-run-id text fixed in the Decisions | `kogen intent list` |
| id matches but no record exists in this checkout | `no run with this id in this checkout` | `kogen intent list` |

The line is still produced by the existing JSON encoder (one object, keys sorted, newline), so the only byte differences from today are the new `detail` text and the `next` key. `next` appears only on these two `run_not_found` answers: every other error object keeps exactly its four fields, and a recorded run still prints exactly as before (human text and `--json`).

**Terminal.** When standard output is a terminal, one sentence line with the same content as `detail` and `next` (wording fixed in the Decisions) is printed after the JSON line on every `run_not_found` answer. The JSON line stays first on standard output; the sentence goes to standard error, so standard output stays exactly one JSON object. Only standard output decides: if standard output is a pipe, a file or `/dev/null`, nothing is added to standard error (even when standard error itself is a terminal). `/dev/null` is a character device but not a terminal and must not be treated as one. The exit code is 1 either way. Detect the terminal without changing `cli/go.mod` or `cli/go.sum` (they are protected).

Nothing else changes: no new command, flag or setting, no change to `intent list`, `usage` or the other read commands, and no change to the exit-code categories. Update `docs/checkout-facts.md` (the maintained read contract) where it says unknown runs are exit 1 `intent/run_not_found`: state the two detail texts, the `next` field and the terminal sentence.

## Decisions
- `error.reason` stays `run_not_found` for both a malformed and a well-formed absent id; `detail` and the new `next` field tell them apart. (source: request)
- `next` is the string `kogen intent list` for both cases, because it names the command that lists run ids. (source: request)
- The well-formed absent detail is exactly `no run with this id in this checkout`. (source: request)
- The malformed detail says the id is not a run id and what a run id looks like; its exact text is `not a run id: a run id is 8 lowercase hexadecimal characters, for example 0a1b2c3d`, and ids such as `0A1B2C3D` or ones of 7 or 9 characters are malformed because the existing `runID` pattern `^[a-f0-9]{8}$` rejects them. (assumption: the user must confirm this exact wording; the request fixes only that the malformed case says the id is not a run id) (source: request)
- The terminal sentence is one line, added after the JSON and not as a pretty-printed replacement, worded `<detail>. Next: <next>` (for example `no run with this id in this checkout. Next: kogen intent list`) and written to standard error. (assumption: the user must confirm the `<detail>. Next: <next>` wording and the use of standard error; the request fixes only that a one-line sentence with the same content follows the JSON when standard output is a terminal) (source: request)
- The sentence is added when standard output is a terminal. (source: request)
- When standard output is not a terminal, including `/dev/null`, a pipe or a file, nothing is added to the bare JSON, even if standard error is a terminal. (assumption: the user must confirm that the decision rests on standard output alone, so a terminal on standard error with piped standard output gets no sentence; the request names only standard output) (source: request)
- The exit code is unchanged (1). (source: request)

## Source comparison
- addressed: JSON byte-compatible for existing fields, with `detail` and a new one-string `next` field; the acceptance scenarios compare the whole JSON line byte for byte, so only `detail` and `next` may differ from today. Source request; contract in the table above.
- addressed: malformed id says it is not a run id and what a run id looks like; source request; acceptance scenarios for `run-1`, `0a1b2c3`, `0a1b2c3d4` and `0A1B2C3D`; the exact wording is a marked assumption.
- addressed: well-formed id without a record keeps reason `run_not_found`, detail `no run with this id in this checkout`, `next` names `kogen intent list`; source request; acceptance scenarios for `0a1b2c3d`.
- addressed: one human sentence with the same content when standard output is a terminal, exit code unchanged; source request; terminal scenarios run through a pseudo-terminal (`script`); the sentence format is a marked assumption.
- addressed: a recorded run prints as before; source request; acceptance scenario with a recorded run in `.kogen/local/facts/0a1b2c3d.json` for `--json`, piped human output and terminal human output.
- chosen among the request's alternatives: the sentence comes after the JSON (the request also allowed the reverse with pretty-printed JSON); source request, decision above.
- omitted: changing `kogen intent list`, `usage` or other commands, and changing other error answers; the request concerns only `inspect` of an unknown run.

## Tests
- Malformed id answers `run_not_found` with the not-a-run-id detail and `next` naming `kogen intent list`, JSON otherwise byte-identical: a scenario outline over `run-1`, `0a1b2c3`, `0a1b2c3d4` and `0A1B2C3D` through the built CLI (scenario)
- Well-formed id with no record answers `run_not_found`, detail `no run with this id in this checkout`, `next` naming `kogen intent list`: a scenario through the built CLI with `--json` (scenario)
- On a terminal the sentence `<detail>. Next: <next>` follows the JSON line for both cases and the exit code stays 1: two scenarios through a pseudo-terminal (scenario)
- Standard output that is not a terminal (`/dev/null`, or a pipe while standard error is a terminal) gets no added sentence: two scenarios through the built CLI (scenario)
- A recorded run prints as before, in `--json`, piped human and terminal human form: a scenario with a recorded run fixture (scenario)
- The error object for these two cases carries `detail` and `next` while every other error object keeps its four fields: a focused Go test in `cli/facts_test.go` through `localRead` in a temporary project, using the existing `factProject` helper (unit)
- Existing unknown-run assertions in `features/steps/checkout_cli_dx_steps.js` (`unknownRun`, exit 1 and `run_not_found`) keep passing unchanged: the existing checkout CLI scenarios (existing)

## Feasibility
- The CLI builds in about 1.2 s from `cli` with `GOFLAGS=-buildvcs=false GOPROXY=off GOTOOLCHAIN=local GOWORK=off go build -o <dir>/kogen .`, and `kogen intent inspect run-1` and `kogen intent inspect 0a1b2c3d` in a repository that holds only `.kogen/project.yaml` print today's `run_not_found` line with `detail` equal to the reason, exit 1; so no `kogen init`, provider or installed release is needed. (probe 1: exit 0)
- macOS `script -q /dev/null /bin/sh -c <line>` with stdin on `/dev/null` gives the command a pseudo-terminal for standard output and standard error, returns CRLF line endings and a leading `^D` plus two backspaces, and `sh` can append `exit=$?`; a Node pipe as stdin is refused (`tcgetattr/ioctl: Operation not supported on socket`), so the harness gives it `/dev/null`. The harness strips the leading echo and the CRLFs; Linux uses `script -qec <line> /dev/null`. (probe 2: exit 0)
- The proposed feature and step file ran against the unchanged tree in a scratch copy: the recorded-run and discarded-output scenarios pass, and the other eight fail only on the new `detail` and `next` text (the checkout part of each JSON line and the terminal capture already match byte for byte), so the red is the missing feature, not a broken fixture. (probe 3: exit 1)
- evidence: {"id":"terminal-observer","kind":"observer","inputs":["features/steps/k-cli-inspect-unknown-run-names-next-command__steps.js"],"observers":["features/steps/k-cli-inspect-unknown-run-names-next-command__steps.js"],"checks":[{"name":"good","command":"node features/steps/k-cli-inspect-unknown-run-names-next-command__steps.js --control good","exit":0,"output":"k-cli-inspect-unknown-run-names-next-command observer good\n"},{"name":"bad","command":"node features/steps/k-cli-inspect-unknown-run-names-next-command__steps.js --control bad","exit":1,"output":"k-cli-inspect-unknown-run-names-next-command observer rejected 6 bad transcripts\n"}]}
