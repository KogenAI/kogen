package claudecode

import (
	"os"
	"path/filepath"
	"regexp"
	"time"
)

// transcriptEntryBound caps the directory entries one Start reads while pruning transcripts.
const transcriptEntryBound = 10000

// transcriptBatch is the most entries one ReadDir call asks for.
const transcriptBatch = 256

var transcriptName = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$`)

// transcriptReport is what one pruning pass did.
type transcriptReport struct {
	removed, removedBytes, kept, removeFailed int64
	boundReached                              bool
}

// event is the start event's transcripts object, or nil when there is nothing to report.
func (r transcriptReport) event() map[string]any {
	if r.removed == 0 && r.kept == 0 && r.removeFailed == 0 && !r.boundReached {
		return nil
	}
	return map[string]any{
		"removed":       r.removed,
		"removed_bytes": r.removedBytes,
		"kept":          r.kept,
		"remove_failed": r.removeFailed,
		"bound_reached": r.boundReached,
	}
}

// pruneTranscripts removes the session transcripts under <config>/projects that were last
// modified more than retention before now, except the one of sessionID. Only regular
// <uuid>.jsonl files directly inside real working-directory folders are candidates; symlinks are
// never followed and every removal goes through an os.Root of the transcript area. At most
// transcriptEntryBound directory entries are read.
func pruneTranscripts(configDir string, now time.Time, retention time.Duration, sessionID string) transcriptReport {
	var rep transcriptReport
	area := filepath.Join(configDir, "projects")
	if fi, err := os.Lstat(area); err != nil || !fi.IsDir() {
		return rep
	}
	root, err := os.OpenRoot(area)
	if err != nil {
		return rep
	}
	defer root.Close()
	dir, err := root.Open(".")
	if err != nil {
		return rep
	}
	defer dir.Close()

	read := 0
	own := sessionID + ".jsonl"
	for read < transcriptEntryBound {
		entries, err := dir.ReadDir(min(transcriptBatch, transcriptEntryBound-read))
		read += len(entries)
		for _, e := range entries {
			if !e.Type().IsDir() {
				continue
			}
			read += pruneFolder(root, e.Name(), now, retention, own, transcriptEntryBound-read, &rep)
		}
		if err != nil {
			break
		}
	}
	rep.boundReached = read >= transcriptEntryBound
	return rep
}

// pruneFolder examines one working-directory folder, reading at most budget entries, and returns
// how many it read.
func pruneFolder(area *os.Root, name string, now time.Time, retention time.Duration, own string, budget int, rep *transcriptReport) int {
	if budget <= 0 {
		return 0
	}
	folder, err := area.OpenRoot(name)
	if err != nil {
		return 0
	}
	defer folder.Close()
	dir, err := folder.Open(".")
	if err != nil {
		return 0
	}
	defer dir.Close()

	read := 0
	for read < budget {
		entries, err := dir.ReadDir(min(transcriptBatch, budget-read))
		read += len(entries)
		for _, e := range entries {
			n := e.Name()
			if n == own || !transcriptName.MatchString(n) {
				continue
			}
			fi, err := folder.Lstat(n)
			if err != nil || !fi.Mode().IsRegular() {
				continue
			}
			if now.Sub(fi.ModTime()) <= retention {
				rep.kept++
				continue
			}
			if err := folder.Remove(n); err != nil {
				rep.removeFailed++
				continue
			}
			rep.removed++
			rep.removedBytes += fi.Size()
		}
		if err != nil {
			break
		}
	}
	return read
}
