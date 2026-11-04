package consumes

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/KogenAI/kogen-coordinator/git"
)

// kogen cli/readiness/readiness.go opens the project read-only with the session's environment.
var _ func(string, []string) (*git.Repo, error) = git.OpenReadOnly

// kogen cli/readiness/readiness.go asks the repository whether it can commit.
var _ func(*git.Repo) bool = (*git.Repo).CanCommit

// TestOpenReadOnlyFindsTheWorkTreeRoot: the opened repository's Dir is the work tree root, also
// when opened from a folder inside it; readiness reports `repository <Dir>`.
func TestOpenReadOnlyFindsTheWorkTreeRoot(t *testing.T) {
	f := newRepoFx(t)
	for _, from := range []string{f.dir, filepath.Join(f.dir, "sub", "dir")} {
		var repo *git.Repo
		repo, err := git.OpenReadOnly(from, f.env)
		if err != nil {
			t.Fatalf("OpenReadOnly(%s): %v", from, err)
		}
		if repo.Dir != f.dir {
			t.Fatalf("OpenReadOnly(%s).Dir = %q, want %q", from, repo.Dir, f.dir)
		}
	}
}

// TestOpenReadOnlyRefusesADirectoryThatIsNoRepository: readiness reports "is not inside a Git
// repository" when the error is non-nil.
func TestOpenReadOnlyRefusesADirectoryThatIsNoRepository(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "plain")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	repo, err := git.OpenReadOnly(dir, envWith(os.Environ(), "GIT_CEILING_DIRECTORIES="+base))
	if err == nil {
		t.Fatalf("OpenReadOnly of a plain directory succeeded: %+v", repo)
	}
}

// TestCanCommitNeedsAUserNameAndEmail: true with both configured, false when either is missing;
// readiness then reports "no Git user.name and user.email".
func TestCanCommitNeedsAUserNameAndEmail(t *testing.T) {
	for _, missing := range []string{"", "user.name", "user.email"} {
		f := newRepoFx(t)
		if missing != "" {
			f.git("config", "--unset", missing)
		}
		repo, err := git.OpenReadOnly(f.dir, f.env)
		if err != nil {
			t.Fatal(err)
		}
		if got, want := repo.CanCommit(), missing == ""; got != want {
			t.Fatalf("CanCommit without %q = %v, want %v", missing, got, want)
		}
	}
}
