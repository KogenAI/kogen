package shape

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/git"
	"kogen/project"
)

// Helpers shared by the commands of this package (shape, refine, approve, preflight, init).
// Exported names are meant for the other commands of the package; each file prefixes its own
// unexported helpers.

// ContentHash is the lowercase hex SHA-256 of bytes: the hash shaping records for the
// files it proposes, originals and source entries.
func ContentHash(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// ShellQuote quotes value for /bin/sh in single quotes.
func ShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

// ReadmeText is the root README.md, or `(no README.md)`.
func ReadmeText(root string) string {
	b, err := os.ReadFile(filepath.Join(root, "README.md"))
	if err != nil {
		return "(no README.md)"
	}
	return string(b)
}

// ProviderRole is a project role as the provider package takes it.
func ProviderRole(r project.Role) provider.Role {
	return provider.Role{Provider: r.Provider, Model: r.Model, Effort: r.Effort, BaseURL: r.BaseURL}
}

// ShapeRoles are the roles shaping may use: `models.shape`, and with shape workers enabled
// the read, probe and draft roles.
func ShapeRoles(cfg *project.Config) []provider.Role {
	roles := []provider.Role{ProviderRole(cfg.Models["shape"])}
	if cfg.ShapeWorkers.Enabled {
		for _, name := range []string{"read", "probe", "draft"} {
			roles = append(roles, ProviderRole(cfg.ShapeWorkers.Roles[name]))
		}
	}
	return roles
}

// ReplayItems is the replayed items of a response as a conversation's next input items.
func ReplayItems(items []map[string]any) []any { return tools.Replay(items) }

// InspectStrings renders a list of strings the way Elixir's inspect/1 does: `["a", "b"]`, on
// one line however long it is.
func InspectStrings(list []string) string {
	parts := make([]string, len(list))
	for i, s := range list {
		parts[i] = inspectString(s)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func inspectString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	rs := []rune(s)
	for i, r := range rs {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == 0x1b:
			b.WriteString(`\e`)
		case r == 7:
			b.WriteString(`\a`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r == '\v':
			b.WriteString(`\v`)
		case r == 0:
			b.WriteString(`\0`)
		case r == '#' && i+1 < len(rs) && rs[i+1] == '{':
			b.WriteString(`\#`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02X`, r)
		case !unicode.IsPrint(r):
			fmt.Fprintf(&b, `\u%04X`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// ExitCode is the process exit code of a command's error: the code of a *sys.Error, the
// signal's code of an interrupt, 70 for anything else (a Kogen bug, CLI-6).
func ExitCode(err error) int {
	var e *sys.Error
	var i *sys.Interrupted
	switch {
	case errors.As(err, &e):
		return e.Exit
	case errors.As(err, &i):
		return i.ExitCode()
	}
	return 70
}

// sortedKeys is the keys of a string-keyed map in byte order.
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Revision is the frozen identity of the checkout a shaping conversation sees: HEAD and the
// tree of every tracked and not-ignored file without `.kogen/local`.
type Revision struct {
	Head string `json:"head"`
	Tree string `json:"tree"`
}

// Map is the revision as a JSON object.
func (r Revision) Map() map[string]any { return map[string]any{"head": r.Head, "tree": r.Tree} }

// CurrentRevision computes the revision of the checkout of repo in a private index: the real
// index is not touched.
func CurrentRevision(repo *git.Repo) (Revision, error) {
	head := repo.Head()
	tree, err := repo.Tree(head, nil)
	if err != nil {
		return Revision{}, err
	}
	index := sys.TmpPath("kogen-context-index")
	defer os.Remove(index)
	env := []string{"GIT_INDEX_FILE=" + index}
	if _, err := repo.OKEnv(env, "read-tree", tree); err != nil {
		return Revision{}, err
	}
	if _, err := repo.OKEnv(env, "rm", "--cached", "-r", "--ignore-unmatch", "--", ".kogen/local"); err != nil {
		return Revision{}, err
	}
	out, err := repo.OKEnv(env, "write-tree")
	if err != nil {
		return Revision{}, err
	}
	return Revision{Head: head, Tree: strings.TrimSpace(out)}, nil
}

// interrupted reports the interrupt of the session or of ctx as the error a command returns,
// or nil.
func interrupted(ctx context.Context, s *sys.Session) error {
	if err := s.Err(); err != nil {
		return err
	}
	return ctx.Err()
}

// elapsedSeconds is the whole seconds since start, as the progress lines print them.
func elapsedSeconds(ms int64) int64 { return ms / 1000 }
