package tools

import (
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"
)

// SnapshotHeader opens the workspace snapshot message (see Snapshot).
const SnapshotHeader = "Workspace at the start of the task: the output of list_files, then read_file of every listed file of up to 4096 bytes (larger or binary files are listed only). Files you change later are not updated here."

const (
	snapshotMaxPaths = 64
	snapshotMaxFile  = 4096
	snapshotMaxBytes = 32768
)

// Snapshot is the workspace snapshot message of a small repository: SnapshotHeader, the
// list_files output with no arguments, then the read_file output of every listed file of at
// most 4096 bytes, in listing order, each as delivered to the model (after Cut). It is ""
// when list_files or read_file is not enabled, when list_files fails or lists nothing, when
// more than 64 paths are listed, or when the files shown total more than 32768 bytes. Larger,
// binary, invalid UTF-8, refused and non-regular files appear in the listing only.
func (t *Tools) Snapshot() string {
	if !slices.Contains(t.Enabled, ListFilesTool) || !slices.Contains(t.Enabled, ReadFileTool) {
		return ""
	}
	res, err := t.repo().Run("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate", "--")
	if err != nil || res.Status != 0 || res.Stdout == "" {
		return ""
	}
	names := strings.Split(strings.TrimSuffix(res.Stdout, "\x00"), "\x00")
	if len(names) > snapshotMaxPaths {
		return ""
	}
	listing := t.listFiles(map[string]any{})
	if len(strings.Split(listing, "\n")) != len(names) {
		return ""
	}
	var sections strings.Builder
	total := 0
	for _, name := range names {
		data, ok := t.snapshotFile(name)
		if !ok {
			continue
		}
		if total += len(data); total > snapshotMaxBytes {
			return ""
		}
		sections.WriteString("\n\nread_file " + strconv.Quote(name) + ":\n" + Cut(numbered(string(data), nil, nil)))
	}
	return SnapshotHeader + "\n\nlist_files:\n" + Cut(listing) + sections.String()
}

// snapshotFile is the content of a listed file that the snapshot shows: one read_file reads,
// that is a regular file of at most 4096 bytes, without NUL, in valid UTF-8.
func (t *Tools) snapshotFile(name string) ([]byte, bool) {
	root, rel, err := t.openRoot(name)
	if err != nil {
		return nil, false
	}
	defer root.Close()
	// O_NONBLOCK: an open of a FIFO does not wait for a writer. The opened file is still
	// checked to be regular.
	f, err := root.OpenFile(rel, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Size() > snapshotMaxFile {
		return nil, false
	}
	data, err := io.ReadAll(io.LimitReader(f, snapshotMaxFile+1))
	if err != nil || len(data) > snapshotMaxFile || slices.Contains(data, 0) || !utf8.Valid(data) {
		return nil, false
	}
	return data, true
}
