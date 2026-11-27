package claudecode

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func transcriptFixture(t *testing.T, path, content string, modified time.Time) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, modified, modified); err != nil {
		t.Fatal(err)
	}
}

func transcriptContent(t *testing.T, path, want string) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil {
		t.Errorf("read %s: %v", path, err)
	} else if string(got) != want {
		t.Errorf("content of %s = %q, want %q", path, got, want)
	}
}

func TestPruneTranscriptsExpiredReport(t *testing.T) {
	config := t.TempDir()
	now := time.Date(2026, 1, 10, 12, 0, 0, 0, time.UTC)
	retention := 24 * time.Hour
	paths := []string{
		filepath.Join(config, "projects", "first", "11111111-1111-1111-1111-111111111111.jsonl"),
		filepath.Join(config, "projects", "second", "22222222-2222-2222-2222-222222222222.jsonl"),
	}
	contents := []string{"short", "a longer transcript"}
	for i, path := range paths {
		transcriptFixture(t, path, contents[i], now.Add(-2*retention))
	}
	got := pruneTranscripts(config, now, retention, "")
	want := transcriptReport{removed: 2, removedBytes: int64(len(contents[0]) + len(contents[1]))}
	if got != want {
		t.Errorf("report = %+v, want %+v", got, want)
	}
	for _, path := range paths {
		if _, err := os.Lstat(path); !os.IsNotExist(err) {
			t.Errorf("expired transcript %s still exists or cannot be checked: %v", path, err)
		}
	}
}

func TestPruneTranscriptsKeepsExcludedAndFresh(t *testing.T) {
	config := t.TempDir()
	now := time.Date(2026, 1, 10, 12, 0, 0, 0, time.UTC)
	retention := 24 * time.Hour
	folder := filepath.Join(config, "projects", "work")
	current := "11111111-1111-1111-1111-111111111111"
	fixtures := []struct {
		name, content string
		age           time.Duration
	}{
		{current + ".jsonl", "current session", 2 * retention},
		{"22222222-2222-2222-2222-222222222222.jsonl", "fresh session", retention / 2},
		{"not-a-uuid.jsonl", "other file", 2 * retention},
	}
	for _, f := range fixtures {
		transcriptFixture(t, filepath.Join(folder, f.name), f.content, now.Add(-f.age))
	}
	got := pruneTranscripts(config, now, retention, current)
	if want := (transcriptReport{kept: 1}); got != want {
		t.Errorf("report = %+v, want %+v", got, want)
	}
	for _, f := range fixtures {
		transcriptContent(t, filepath.Join(folder, f.name), f.content)
	}
}

func TestPruneTranscriptsDoesNotFollowSymlink(t *testing.T) {
	config := t.TempDir()
	now := time.Date(2026, 1, 10, 12, 0, 0, 0, time.UTC)
	retention := 24 * time.Hour
	folder := filepath.Join(config, "projects", "work")
	target := filepath.Join(folder, "nested", "11111111-1111-1111-1111-111111111111.jsonl")
	link := filepath.Join(folder, "22222222-2222-2222-2222-222222222222.jsonl")
	transcriptFixture(t, target, "target content", now.Add(-2*retention))
	if err := os.Symlink(filepath.Join("nested", filepath.Base(target)), link); err != nil {
		t.Fatal(err)
	}
	got := pruneTranscripts(config, now, retention, "")
	if want := (transcriptReport{}); got != want {
		t.Errorf("report = %+v, want %+v", got, want)
	}
	fi, err := os.Lstat(link)
	if err != nil {
		t.Errorf("lstat link: %v", err)
	} else if fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("%s is not a symlink: %v", link, fi.Mode())
	}
	transcriptContent(t, target, "target content")
}
