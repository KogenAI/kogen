package sys

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"testing"
)

// TestPsGroupOthersIgnoresItsOwnListing re-runs the test binary as a helper that leads a
// new process group, so the ps listing psGroupOthers starts is born into the group it lists.
func TestPsGroupOthersIgnoresItsOwnListing(t *testing.T) {
	if os.Getenv("PSGO_HELPER") != "" {
		alone, err := psGroupOthers(syscall.Getpgrp(), os.Getpid())
		fmt.Printf("PSGO alone %v %v\n", alone, err)
		member := exec.Command("sleep", "600")
		if err := member.Start(); err != nil {
			fmt.Printf("PSGO start %v\n", err)
			return
		}
		others, err := psGroupOthers(syscall.Getpgrp(), os.Getpid())
		member.Process.Kill()
		member.Wait()
		fmt.Printf("PSGO member %v %v\n", others, err)
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestPsGroupOthersIgnoresItsOwnListing$", "-test.count=1")
	cmd.Env = append(os.Environ(), "PSGO_HELPER=1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("helper: %v\n%s", err, out)
	}
	got := ""
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "PSGO ") {
			got += line + "\n"
		}
	}
	if want := "PSGO alone false <nil>\nPSGO member true <nil>\n"; got != want {
		t.Fatalf("observations %q, want %q\n%s", got, want, out)
	}
}
