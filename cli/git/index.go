package git

import (
	"bytes"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/binary"
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

// ObjectFormat is the repository's object hash: sha1 or sha256.
func (r *Repo) ObjectFormat() (string, error) {
	return r.okTrim(nil, "rev-parse", "--show-object-format")
}

// StagedEquivalent reports whether two index files record exactly the same staging, so that a
// plain `git status` refreshing the index after a Build stopped is not mistaken for a change.
// Both must be complete version 2 or 3 indexes of the repository's object format whose trailing
// checksum holds. They must have the same version, the same entries in the same order (path,
// mode, object, stage, flags and extended flags, byte for byte) and the same extensions, byte
// for byte. Only each entry's stat cache (ctime, mtime, dev, ino, uid, gid and size, which Git
// rewrites when it re-examines the working tree) may differ. A version 4 or split index, a
// missing or damaged checksum or anything else unrecognised is equivalent only when the bytes
// are equal: custody fails closed.
func StagedEquivalent(a, b []byte, format string) bool {
	if bytes.Equal(a, b) {
		return true
	}
	x, ok1 := stagedForm(a, format)
	y, ok2 := stagedForm(b, format)
	return ok1 && ok2 && bytes.Equal(x, y)
}

// stagedForm is an index without the stat cache of its entries (zeroed) and without its
// checksum, or false when it is not a complete supported index.
func stagedForm(data []byte, format string) ([]byte, bool) {
	var size int
	var sum func([]byte) []byte
	switch format {
	case "sha1":
		size, sum = sha1.Size, func(b []byte) []byte { s := sha1.Sum(b); return s[:] }
	case "sha256":
		size, sum = sha256.Size, func(b []byte) []byte { s := sha256.Sum256(b); return s[:] }
	default:
		return nil, false
	}
	if len(data) < 12+size || string(data[:4]) != "DIRC" {
		return nil, false
	}
	body := data[:len(data)-size]
	if !bytes.Equal(sum(body), data[len(body):]) {
		return nil, false
	}
	version := binary.BigEndian.Uint32(data[4:8])
	if version != 2 && version != 3 {
		return nil, false
	}
	out := bytes.Clone(body)
	off := 12
	for n := binary.BigEndian.Uint32(data[8:12]); n > 0; n-- {
		// ctime, mtime, dev, ino (24 bytes), mode (4), uid, gid, size (12), object, flags.
		fixed := 40 + size + 2
		if off+fixed > len(body) {
			return nil, false
		}
		flags := binary.BigEndian.Uint16(body[off+40+size:])
		name := off + fixed
		if flags&0x4000 != 0 {
			if version < 3 {
				return nil, false
			}
			name += 2
		}
		end := bytes.IndexByte(body[min(name, len(body)):], 0)
		if end < 1 {
			return nil, false
		}
		if length := int(flags & 0xfff); length != min(end, 0xfff) {
			return nil, false
		}
		// The entry is padded with 1 to 8 NULs to a multiple of 8 bytes.
		next := off + (name-off+end+8)&^7
		if next > len(body) || !allZero(body[name+end:next]) {
			return nil, false
		}
		clear(out[off : off+24])
		clear(out[off+28 : off+40])
		off = next
	}
	for off < len(body) {
		if off+8 > len(body) {
			return nil, false
		}
		signature := string(body[off : off+4])
		length := int(binary.BigEndian.Uint32(body[off+4 : off+8]))
		if signature == "link" || off+8+length > len(body) {
			return nil, false
		}
		off += 8 + length
	}
	return out, true
}

func allZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}
