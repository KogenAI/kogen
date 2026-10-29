package tools

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
)

// Reading tools (read_file, view_image, and the optional path of list_files and
// search_text) are confined to Tools.Root. The path is resolved component by component
// against the real file system, so a symlink is followed before any `..` after it is
// applied, and the file is then opened through os.Root on the canonical root. This is
// source-path containment, not a shell sandbox.

// containError is a refused path: the tool text says why, and no outside byte is read.
type containError string

func (e containError) Error() string { return string(e) }

const (
	errHome    = containError("home paths (~) are not allowed; reads are confined to the repository root")
	errOutside = containError("path is outside the repository root; reads are confined to the repository root")
)

// maxLinks bounds the symlinks one path may traverse.
const maxLinks = 255

// splitPath is the path's components without empty and "." ones.
func splitPath(p string) []string {
	var parts []string
	for _, c := range strings.Split(p, "/") {
		if c != "" && c != "." {
			parts = append(parts, c)
		}
	}
	return parts
}

func hasPrefix(parts, prefix []string) bool {
	return len(parts) >= len(prefix) && slices.Equal(parts[:len(prefix)], prefix)
}

// canonicalRoot is Root as an absolute path without symlinks.
func (t *Tools) canonicalRoot() (string, error) {
	abs, err := filepath.Abs(t.Root)
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(abs)
}

// contain resolves path to a root-relative form ("." for the root) without symlinks, or a
// containError. A path that does not exist is the file error (ENOENT), except with missing
// true, where the components after the first absent one are taken as written.
func (t *Tools) contain(path string, missing bool) (string, error) {
	if strings.ContainsRune(path, 0) {
		return "", errBadArg
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		return "", errHome
	}
	rootPath, err := t.canonicalRoot()
	if err != nil {
		return "", err
	}
	root := splitPath(rootPath)

	var stack []string
	entered := true
	if filepath.IsAbs(path) {
		entered = false
	} else {
		stack = slices.Clone(root)
	}
	pending := splitPath(path)
	absent, links := false, 0
	for ; len(pending) > 0; pending = pending[1:] {
		c := pending[0]
		switch {
		case c == "..":
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
		case absent:
			stack = append(stack, c)
		default:
			cand := "/" + strings.Join(append(slices.Clone(stack), c), "/")
			fi, err := os.Lstat(cand)
			switch {
			case err != nil && !entered:
				return "", errOutside // no answer about files outside the root
			case isErrno(err, syscall.ENOENT) && missing:
				absent = true
				stack = append(stack, c)
			case err != nil:
				return "", err
			case fi.Mode()&os.ModeSymlink != 0:
				if links++; links > maxLinks {
					return "", syscall.ELOOP
				}
				target, err := os.Readlink(cand)
				if err != nil {
					return "", err
				}
				if filepath.IsAbs(target) {
					stack, entered = nil, false
				}
				pending = slices.Concat([]string{""}, splitPath(target), pending[1:])
			default:
				if len(pending) > 1 && !fi.IsDir() {
					return "", syscall.ENOTDIR
				}
				stack = append(stack, c)
			}
		}
		if hasPrefix(stack, root) {
			entered = true
		} else if entered {
			return "", errOutside
		}
	}
	if !hasPrefix(stack, root) {
		return "", errOutside
	}
	if rel := strings.Join(stack[len(root):], "/"); rel != "" {
		return rel, nil
	}
	return ".", nil
}

// openRoot is Root opened as an os.Root and the root-relative form of path inside it; the
// caller closes the root. Opens through it cannot leave the root.
func (t *Tools) openRoot(path string) (*os.Root, string, error) {
	rel, err := t.contain(path, false)
	if err != nil {
		return nil, "", err
	}
	rootPath, err := t.canonicalRoot()
	if err != nil {
		return nil, "", err
	}
	root, err := os.OpenRoot(rootPath)
	if err != nil {
		return nil, "", err
	}
	return root, rel, nil
}

// readContained is the whole content of the file path names inside Root.
func (t *Tools) readContained(path string) ([]byte, error) {
	root, rel, err := t.openRoot(path)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	f, err := root.Open(rel)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

// refusal is the tool text of a refused path, "" when err is not a refusal.
func refusal(path string, err error) string {
	var ce containError
	if errors.As(err, &ce) {
		return "error: " + firstRunes(path, 512) + ": " + ce.Error()
	}
	return ""
}
