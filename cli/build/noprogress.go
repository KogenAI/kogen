package build

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"kogen-loop/tools"
	"strings"

	"kogen-loop/sys"
	"kogen/executor"
	"kogen/verify"
)

// progressWatch is the native builder's evidence that a round answered the failure feedback
// it was given. It is not part of the State: a resumed Build starts without a prior red pass,
// so its first pass can never be taken for a repeat.
type progressWatch struct {
	// tools counts the tool calls (including finish) of the native round in progress.
	tools int
	// red identifies the last red pass whose feedback the builder holds: the stage, the
	// exact candidate tree and the failing items. Empty after a green pass.
	red string
	// streak counts the consecutive identical red passes of an external Build, identified by
	// streakSig (stage, candidate tree and failing-set fingerprint).
	streak    int
	streakSig string
}

// externalNoProgressPasses is the number of consecutive identical red passes that stops an
// external Build.
const externalNoProgressPasses = 3

// externalStalled is the external executor's no-progress rule: the third consecutive clean red
// pass with the same failing-set fingerprint over the same candidate tree records
// executor_no_progress and stops like the round cap.
func (b *Attempt) externalStalled(stage string, pass verify.Pass) error {
	if pass.Green || !pass.Clean || len(pass.Moved) != 0 || len(pass.Failing) == 0 {
		b.watch.streak, b.watch.streakSig = 0, ""
		return nil
	}
	anon := pass
	anon.N = 0
	sum := sha256.Sum256([]byte(strings.Join([]string{
		stage, strings.Join(pass.Failing, "\x00"), b.PassFeedback(anon, "finish"),
	}, "\x1f")))
	fingerprint := hex.EncodeToString(sum[:])
	sig := fingerprint + "\x1f" + pass.Tree
	if b.watch.streak > 0 && b.watch.streakSig == sig {
		b.watch.streak++
	} else {
		b.watch.streak, b.watch.streakSig = 1, sig
	}
	if b.watch.streak < externalNoProgressPasses {
		return nil
	}
	b.Run.Event(map[string]any{
		"event": "executor_no_progress", "rounds": b.Executor.Rounds,
		"fingerprint": fingerprint, "failing": nonNil(pass.Failing),
	})
	return executor.RoundLimit(b.Executor.Rounds)
}

// stalled decides what a red pass means for the native builder (LOOP-7): the round made no
// tool call (it cannot have changed anything, read anything or run anything), and its pass is
// the same red as the pass whose full feedback it answered: same stage, same candidate tree
// (verification materializes exactly that tree, so the checks saw identical input) and same
// failing items. Another round would send the same feedback to the same conversation. Any
// tool call, any change of tree, stage or failing items, and any pass that is not clean is
// progress or unknown, and the Build continues. An external executor's passes are watched by
// externalStalled instead.
func (b *Attempt) stalled(stage string, pass verify.Pass) error {
	if b.ext != nil {
		return b.externalStalled(stage, pass)
	}
	if pass.Green {
		b.watch.red = ""
		return nil
	}
	if !pass.Clean || len(pass.Moved) != 0 || pass.Tree == "" || len(pass.Failing) == 0 {
		b.watch.red = ""
		return nil
	}
	sig := strings.Join([]string{stage, pass.Tree, strings.Join(pass.Failing, "\x00")}, "\x1f")
	repeat := b.ext == nil && b.watch.tools == 0 && b.watch.red == sig
	b.watch.red = sig
	if !repeat {
		return nil
	}
	e := sys.Fail("candidate", "no_progress",
		"the builder answered the failure feedback without a tool call, and verification pass "+itoa(pass.N)+
			" is the same red as the pass before it; edits are left in place", 1)
	e.Lines = []string{
		"candidate tree: " + pass.Tree,
		"failing: " + strings.Join(pass.Failing, ", "),
		"No further verification or model request was made. Fix the named failure by hand, or `kogen intent resume " +
			b.Run.ID + "` to verify again and give the builder the feedback again.",
	}
	return e
}

// nativeFingerprint frames the ordered names and hashes of the exact argument strings.
func nativeFingerprint(calls []tools.Call) string {
	pairs := make([][2]string, 0, len(calls))
	for _, call := range calls {
		pairs = append(pairs, [2]string{call.Name, sha256Hex([]byte(call.Arguments))})
	}
	data, _ := json.Marshal(pairs)
	return sha256Hex(data)
}
