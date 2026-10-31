package tools

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"kogen-loop/internal/footprint"
)

func init() {
	footprint.Of = func(t any, name string, args map[string]any) footprint.Footprint {
		return t.(*Tools).footprint(name, args)
	}
}

// footprint is what a call reads and writes, for the engine's decision to run it beside
// other calls. Anything not understood exactly is a barrier: shell, probe, documentation,
// disabled or unknown names, malformed arguments, paths that cannot be resolved and writes
// to Git's own inputs (see gitInput). The
// answer describes the file system now; the engine asks again when the call can start.
func (t *Tools) footprint(name string, args map[string]any) footprint.Footprint {
	barrier := footprint.Footprint{Barrier: true}
	if !slices.Contains(t.Enabled, name) {
		return barrier
	}
	switch name {
	case ReadFileTool:
		path, ok := args["path"].(string)
		if !ok {
			return barrier
		}
		// read_file opens only existing folders: through a missing one and "..", whether it
		// opens at all depends on folders a write may create.
		if slices.Contains(splitPath(path), "..") {
			if _, err := t.contain(path, false); err != nil {
				return barrier
			}
		}
		phys, ok := t.readTarget(path)
		if !ok {
			return barrier
		}
		return footprint.Footprint{Reads: []string{phys}}
	case ViewImageTool:
		// The pixels come from one file, but the metadata names the candidate tree, which
		// Repo.Tree builds from the whole working tree.
		root, err := t.canonicalRoot()
		if err != nil {
			return barrier
		}
		return footprint.Footprint{Reads: []string{root}}
	case ListFilesTool, SearchTextTool:
		root, err := t.canonicalRoot()
		if err != nil {
			return barrier
		}
		path := cString(optionalPath(args))
		// Git reads a pathspec, not a path: wildcards and pathspec magic can select
		// anything below the root.
		if strings.ContainsAny(path, "*?[\\:") {
			return footprint.Footprint{Reads: []string{root}}
		}
		phys, ok := t.readTarget(path)
		if !ok {
			return barrier
		}
		// Git receives the pathspec as written when it stays inside the root, which a
		// symlink followed by ".." can make another place than the resolved path.
		spec, text := t.pathspec(args)
		if text != "" {
			return barrier
		}
		reads := []string{phys}
		if len(spec) > 0 {
			reads = append(reads, filepath.Join(root, spec[0]))
		}
		return footprint.Footprint{Reads: reads}
	case WriteFileTool:
		path, ok := args["path"].(string)
		if _, isString := args["content"].(string); !ok || !isString || strings.ContainsRune(path, 0) {
			return barrier
		}
		abs, err := filepath.Abs(expand(path, t.Root))
		if err != nil {
			return barrier
		}
		phys, ok := physical(abs)
		if !ok || gitInput(t, phys) {
			return barrier
		}
		return footprint.Footprint{Writes: []string{phys}}
	}
	return barrier
}

// gitInput reports a write that can change what Git shows list_files, search_text and
// view_image beyond the written path itself: Git's own folder, ignore and attribute files,
// and anything outside the root (ancestor ignore files, the Git folder of a worktree that
// contains the root, configuration).
func gitInput(t *Tools, phys string) bool {
	root, err := t.canonicalRoot()
	if err != nil {
		return true
	}
	rel, err := filepath.Rel(root, phys)
	if err != nil || rel == ".." || strings.HasPrefix(rel, "../") {
		return true
	}
	for _, c := range strings.Split(rel, "/") {
		if strings.EqualFold(c, ".git") || strings.EqualFold(c, ".gitignore") || strings.EqualFold(c, ".gitattributes") {
			return true
		}
	}
	return false
}

// readTarget is the absolute, symlink-free path a reading tool opens for path.
func (t *Tools) readTarget(path string) (string, bool) {
	if strings.ContainsRune(path, 0) {
		return "", false
	}
	rel, err := t.contain(path, true)
	if err != nil {
		return "", false
	}
	root, err := t.canonicalRoot()
	if err != nil {
		return "", false
	}
	if rel == "." {
		return root, true
	}
	return filepath.Join(root, rel), true
}

// physical is abs with every symlink resolved, as write_file will find it: the longest
// existing prefix is resolved and the missing rest, which the write will create as folders,
// is appended. A dangling link, an unreadable component or a missing rest with ".." is not
// resolved.
func physical(abs string) (string, bool) {
	rest := ""
	p := abs
	for {
		if _, err := os.Lstat(p); err == nil {
			resolved, err := filepath.EvalSymlinks(p)
			if err != nil {
				return "", false
			}
			if rest == "" {
				return resolved, true
			}
			return filepath.Join(resolved, rest), true
		} else if !isErrno(err, syscall.ENOENT) {
			return "", false
		}
		parent, base := filepath.Dir(p), filepath.Base(p)
		if base == ".." || base == "." || parent == p {
			return "", false
		}
		if rest == "" {
			rest = base
		} else {
			rest = base + string(os.PathSeparator) + rest
		}
		p = parent
	}
}
