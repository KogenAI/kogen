package build

import (
	"crypto/sha256"
	"encoding/hex"
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
	// noticed holds the red identities that already got the missing-items notice. A green pass
	// clears it.
	noticed map[string]bool
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

// missingAcceptanceItems are the expected scenarios of the pass's acceptance that did not pass,
// in feature order, each as `<status>: <name> (line <line>)`. A pass whose acceptance did not
// run has none.
func missingAcceptanceItems(pass verify.Pass) []string {
	if pass.Acceptance == nil {
		return nil
	}
	var items []string
	for _, s := range pass.Acceptance.Scenarios {
		if s.Status != "passed" {
			items = append(items, s.Status+": "+s.Name+" (line "+itoa(s.Line)+")")
		}
	}
	return items
}

// missingItemsNotice is the user message that tells the builder which acceptance scenarios
// are still missing; the pass's ordinary feedback follows it.
func missingItemsNotice(pass verify.Pass, missing []string) string {
	var sb strings.Builder
	sb.WriteString("Required acceptance items are still missing: verification pass " + itoa(pass.N) +
		" is the same red as the pass before it, and your last round ended without a tool call. " +
		"The Build is not complete until each of these acceptance scenarios passes:\n")
	for _, m := range missing {
		sb.WriteString("- " + m + "\n")
	}
	sb.WriteString("Work on them now with your tools (write the missing tests and the implementation they need), " +
		"then call finish. Another round without a tool call into the same red stops the Build as no_progress.")
	return sb.String()
}

// stalled decides what a red pass means for the native builder (LOOP-7): the round made no
// tool call (it cannot have changed anything, read anything or run anything), and its pass is
// the same red as the pass whose full feedback it answered: same stage, same candidate tree
// (verification materializes exactly that tree, so the checks saw identical input) and same
// failing items. Another round would send the same feedback to the same conversation. Any
// tool call, any change of tree, stage or failing items, and any pass that is not clean is
// progress or unknown, and the Build continues. An external executor's passes are watched by
// externalStalled instead.
//
// When that stall holds while acceptance scenarios are not passing, the first time for a red
// identity it is not a stop: the returned notice names the missing scenarios and goes to the
// builder before the pass's ordinary feedback. The same identity stalling again stops the Build.
func (b *Attempt) stalled(stage string, pass verify.Pass) (notice string, err error) {
	if b.ext != nil {
		return "", b.externalStalled(stage, pass)
	}
	if pass.Green {
		b.watch.red, b.watch.noticed = "", nil
		return "", nil
	}
	if !pass.Clean || len(pass.Moved) != 0 || pass.Tree == "" || len(pass.Failing) == 0 {
		b.watch.red = ""
		return "", nil
	}
	sig := strings.Join([]string{stage, pass.Tree, strings.Join(pass.Failing, "\x00")}, "\x1f")
	repeat := b.watch.tools == 0 && b.watch.red == sig
	b.watch.red = sig
	if !repeat {
		return "", nil
	}
	missing := missingAcceptanceItems(pass)
	if len(missing) > 0 && !b.watch.noticed[sig] {
		if b.watch.noticed == nil {
			b.watch.noticed = map[string]bool{}
		}
		b.watch.noticed[sig] = true
		b.Run.Event(map[string]any{"event": "missing_items_notice", "pass": pass.N, "missing": missing})
		return missingItemsNotice(pass, missing), nil
	}
	reason := "the builder answered the failure feedback without a tool call, and verification pass " + itoa(pass.N) +
		" is the same red as the pass before it; edits are left in place"
	if len(missing) > 0 {
		reason = "the builder was told which required acceptance items are missing and answered again without a tool call; " +
			"verification pass " + itoa(pass.N) + " is the same red as the pass before it; edits are left in place"
	}
	e := sys.Fail("candidate", "no_progress", reason, 1)
	e.Lines = []string{
		"candidate tree: " + pass.Tree,
		"failing: " + strings.Join(pass.Failing, ", "),
	}
	for _, m := range missing {
		e.Lines = append(e.Lines, "missing: "+m)
	}
	e.Lines = append(e.Lines, "No further verification or model request was made. Fix the named failure by hand, or `kogen intent resume "+
		b.Run.ID+"` to verify again and give the builder the feedback again.")
	return "", e
}
