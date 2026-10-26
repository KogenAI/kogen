package tools

import (
	"strings"
	"testing"
)

func TestRunnerHeadAndTreeFollowTheCandidate(t *testing.T) {
	_, root := newRepo(t)
	r := newRunner(root, hermeticEnv())
	if got := r.Head(); got != "" {
		t.Errorf("Head without commits = %q", got)
	}
	if tree, err := r.Tree(r.Head(), nil); err == nil || tree != "" {
		t.Errorf("Tree without HEAD = %q, %v", tree, err)
	}
	write(t, root, "a.txt", "a\n")
	commitAll(t, root)
	head := r.Head()
	if len(head) != 40 {
		t.Fatalf("Head = %q", head)
	}
	write(t, root, "new.txt", "n\n")
	write(t, root, "other/x.txt", "x\n")
	gitIn(t, root, "add", "new.txt") // staged before: the private index must not depend on it
	withAll, err := r.Tree(head, nil)
	if err != nil || len(withAll) != 40 {
		t.Fatalf("Tree = %q, %v", withAll, err)
	}
	without, err := r.Tree(head, []string{"other"})
	if err != nil || without == withAll {
		t.Errorf("excluded Tree = %q (all %q), %v", without, withAll, err)
	}
	listing := gitIn(t, root, "ls-tree", "-r", "--name-only", withAll)
	if !strings.Contains(listing, "other/x.txt") || !strings.Contains(listing, "new.txt") {
		t.Errorf("tree listing %q", listing)
	}
	if listing := gitIn(t, root, "ls-tree", "-r", "--name-only", without); strings.Contains(listing, "other/") {
		t.Errorf("excluded listing %q", listing)
	}
	if staged := gitIn(t, root, "diff", "--cached", "--name-only"); strings.TrimSpace(staged) != "new.txt" {
		t.Errorf("the user's index changed: %q", staged)
	}
	for _, bad := range []string{"", "-x", "a\x00b"} {
		if _, err := r.Tree(bad, nil); err == nil {
			t.Errorf("Tree(%q) did not fail", bad)
		}
	}
}

func TestRunnerDropsLocationVariablesAndMapsFailures(t *testing.T) {
	_, root := newRepo(t)
	env := append(hermeticEnv(), "GIT_DIR=/nonexistent", "GIT_INDEX_FILE=/nonexistent/index")
	r := newRunner(root, env)
	res, err := r.Run("rev-parse", "--is-inside-work-tree")
	if err != nil || res.Status != 0 || strings.TrimSpace(res.Stdout) != "true" {
		t.Errorf("location variables leaked: %+v %v", res, err)
	}
	res, err = r.Run("rev-parse", "--verify", "-q", "nothing-here")
	if err != nil || res.Status == 0 {
		t.Errorf("failing command: %+v %v", res, err)
	}
	res, err = newRunner("/nonexistent-dir-for-git", hermeticEnv()).Run("status")
	if err == nil || res.Status != -1 || !strings.HasPrefix(err.Error(), "git: ") {
		t.Errorf("non-exit failure: %+v %v", res, err)
	}
}
