package git

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// IndexPath is the user's index file.
func (r *Repo) IndexPath() (string, error) {
	dir, err := r.GitDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "index"), nil
}

// IndexBytes is the user's index as stored.
func (r *Repo) IndexBytes() ([]byte, error) {
	path, err := r.IndexPath()
	if err != nil {
		return nil, err
	}
	return os.ReadFile(path)
}

// SaveIndex copies the user's index to backup, the custody copy a Build that does not
// commit puts back (GIT-8).
func (r *Repo) SaveIndex(backup string) error {
	data, err := r.IndexBytes()
	if err != nil {
		return err
	}
	return os.WriteFile(backup, data, 0o644)
}

// RestoreIndex puts the custody copy back as the user's index. The index is replaced
// atomically, the way Git replaces it.
func (r *Repo) RestoreIndex(backup string) error {
	data, err := os.ReadFile(backup)
	if err != nil {
		return err
	}
	path, err := r.IndexPath()
	if err != nil {
		return err
	}
	mode := fs.FileMode(0o644)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	tmp := filepath.Join(filepath.Dir(path), "index.kogen-restore-"+randomHex(8))
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("restore index: %w", err)
	}
	return nil
}

// ReadTree makes the user's index equal to tree (the staged candidate, GIT-4).
func (r *Repo) ReadTree(tree string) error {
	if err := checkRev(tree); err != nil {
		return err
	}
	_, err := r.ok(nil, "read-tree", tree)
	return err
}

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
