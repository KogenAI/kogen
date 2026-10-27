# Re-pin of the vendored kogen-loop to 33e7f4ec

`cli/third_party/kogen-loop` is now the clean kogen-loop commit
`33e7f4ec8ba899fc4aa621127379e5cb26b77648`, replacing
`bbf3fdd6d2e79b96eab6af23bcd6d66212893388`. It was written only by
`sh packaging/sync-kogen-loop.sh`; `cli/loop-pin.json` records 107 files and
digest `3f99ae913cfe08c356bc0543746ae0ebf581880531081633e8d23559d0a74c2c`
(previously 88 files, `4e1332b9…946638`).

## Linux timeout repair

On Linux an `ESRCH` from the process-group probe used to be read as "group
gone" too early. `sys.Session.Run` now proves whole-process-group absence before
it reports a timeout; when it cannot, it returns `sys.ErrTimeoutObservation`
instead of timeout feedback. Kogen's probe passes its context as
`sys.Options.Context`, keeps its 5-minute deadline, and reports that error as a
failed probe (Shape, Refine and the verification probe), never as
`timed_out: true`. No timeout default was added elsewhere and `ShellTimeout` is
not adopted.

## Testing the nested module

`cli`'s `./...` does not cover `cli/third_party/kogen-loop`, a nested module.
Test it with `(cd cli/third_party/kogen-loop && go test -race -count=1 ./...)`.

The earlier history stays in `docs/evidence/extract-loop-executors/`.
