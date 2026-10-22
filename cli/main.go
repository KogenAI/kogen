// Command kogen is the command-line front of Kogen (spec chapter 09). It parses the command
// line, reads caller input, and starts the Elixir core for mutating invocations, exchanging one
// JSON object per line over the core's stdin and stdout (CLI-9). It runs the project commands
// the core asks for, each in its own process group, and owns the login loopback listener.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"unicode/utf8"
)

const topPage = `Commands:
  context    Read checkout-local facts (JSON)
  completion zsh  Print standalone Zsh completion
  init       Prepare this Git repository for Kogen
  intent     Shape, approve and build an Intent
  provider   Sign in to a provider and show logins
  uninstall  Remove the installed kogen
  version    Show the Kogen version
  help       List commands

Run kogen <command> to see its subcommands and options.
`

const intentPage = `Usage: kogen intent <command> <slug> [arguments] [options]

Commands:
  shape <slug> <file|->     Shape an Intent from a request file (- reads stdin)
  refine <slug> <sha256> <file|->  Correct existing files; require fresh approval
  approve <slug> [<hash>]   Show the review card, or approve the Intent
  build <slug>              Build, verify, review and commit the approved Intent
  resume <build-id>         Continue a stopped Build in this checkout
  list                     List packages and Build attempts
  usage [run-id]          Explain local retained provider usage
  inspect <run-id>         Inspect recorded Build evidence
  preflight <slug>         Observe read-only prerequisites

Options:
  --project <checkout>  Project checkout (default: current directory)
  --by <name>           Approver (default: your Git identity)
  --context <file>      Fresh Build diagnostic data only (not resume)
`

const providerPage = `Usage: kogen provider <command>

Commands:
  login chatgpt      Sign in with a ChatGPT account
  login supergrok    Sign in with a SuperGrok subscription
  login opencode-go  Save your OpenCode Go workspace key from stdin
  list               Show which providers Kogen is signed in to

Logins belong to this machine, never to a repo.
`

var pages = map[string]string{"top": topPage, "intent": intentPage, "provider": providerPage}

// invocation is a parsed command line.
type invocation struct {
	provider string
	command  string // init, shape, refine, approve, build, login, list, uninstall, version
	slug     string
	file     string
	hash     string
	by       string
	project  string
	context  *string
}

type usageError struct{ msg, page string }

// spec describes one leaf command: its path, options and positional names.
type spec struct {
	path       string
	command    string
	page       string
	options    []string
	positional []string // required names, e.g. "<slug>"
	optional   int      // number of trailing optional positionals
}

var leaves = map[string]spec{
	"init":           {path: "init", command: "init", page: "top"},
	"uninstall":      {path: "uninstall", command: "uninstall", page: "top"},
	"version":        {path: "version", command: "version", page: "top"},
	"intent shape":   {path: "intent shape", command: "shape", page: "intent", options: []string{"project"}, positional: []string{"<slug>", "<file|->"}},
	"intent refine":  {path: "intent refine", command: "refine", page: "intent", options: []string{"project"}, positional: []string{"<slug>", "<sha256>", "<file|->"}},
	"intent approve": {path: "intent approve", command: "approve", page: "intent", options: []string{"project", "by"}, positional: []string{"<slug>", "<hash>"}, optional: 1},
	"intent resume":  {path: "intent resume", command: "resume", page: "intent", options: []string{"project"}, positional: []string{"<build-id>"}},
	"intent build":   {path: "intent build", command: "build", page: "intent", options: []string{"project", "context"}, positional: []string{"<slug>"}},
	"provider login": {path: "provider login", command: "login", page: "provider", positional: []string{"<provider>"}},
	"provider list":  {path: "provider list", command: "list", page: "provider"},
}

var hashRe = regexp.MustCompile(`^[0-9a-f]{6,64}$`)
var slugRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// parse returns the invocation, or a help page to print (exit 0), or a usage error (CLI-2).
func parse(args []string) (*invocation, string, *usageError) {
	if len(args) == 0 {
		return nil, topPage, nil
	}
	if len(args) == 1 {
		switch args[0] {
		case "--help", "-h":
			return nil, topPage, nil
		case "--version":
			return &invocation{command: "version"}, "", nil
		}
	}
	var leaf spec
	var rest []string
	switch args[0] {
	case "help":
		if len(args) == 2 && isHelpFlag(args[1]) {
			return nil, topPage, nil
		}
		if len(args) > 1 {
			return nil, "", &usageError{fmt.Sprintf("kogen help: unexpected argument '%s'", args[1]), "top"}
		}
		return nil, topPage, nil
	case "intent", "provider":
		group := args[0]
		if len(args) == 1 {
			return nil, pages[group], nil
		}
		if len(args) == 2 && isHelpFlag(args[1]) {
			return nil, pages[group], nil
		}
		l, ok := leaves[group+" "+args[1]]
		if !ok {
			return nil, "", &usageError{fmt.Sprintf("kogen %s: unknown command '%s'", group, args[1]), group}
		}
		leaf, rest = l, args[2:]
	case "init", "uninstall", "version":
		leaf, rest = leaves[args[0]], args[1:]
	default:
		return nil, "", &usageError{fmt.Sprintf("kogen: unknown command '%s'", args[0]), "top"}
	}

	fail := func(format string, a ...any) (*invocation, string, *usageError) {
		return nil, "", &usageError{fmt.Sprintf("kogen "+leaf.path+": "+format, a...), leaf.page}
	}
	opts := map[string]string{}
	var pos []string
	endOpts := false
	for i := 0; i < len(rest); i++ {
		tok := rest[i]
		switch {
		case endOpts || tok == "-" || !strings.HasPrefix(tok, "-"):
			pos = append(pos, tok)
		case tok == "--":
			endOpts = true
		case isHelpFlag(tok) && i == len(rest)-1:
			return nil, pages[leaf.page], nil
		case !strings.HasPrefix(tok, "--"):
			return fail("unknown option '%s'", tok)
		default:
			name, value, hasValue := strings.Cut(tok[2:], "=")
			if !contains(leaf.options, name) {
				return fail("unknown option '--%s'", name)
			}
			if !hasValue {
				if i+1 >= len(rest) {
					return fail("--%s needs a value", name)
				}
				i++
				value = rest[i]
			}
			opts[name] = value
		}
	}
	if len(pos) < len(leaf.positional)-leaf.optional {
		return fail("missing %s", leaf.positional[len(pos)])
	}
	if len(pos) > len(leaf.positional) {
		return fail("unexpected argument '%s'", pos[len(leaf.positional)])
	}
	inv := &invocation{command: leaf.command, project: opts["project"], by: opts["by"]}
	if value, ok := opts["context"]; ok {
		inv.context = &value
	}
	switch leaf.command {
	case "login":
		inv.provider = pos[0]
		if pos[0] != "chatgpt" && pos[0] != "supergrok" && pos[0] != "opencode-go" {
			return fail("unknown provider '%s' (supported: chatgpt, supergrok, opencode-go)", pos[0])
		}
	case "shape":
		inv.slug, inv.file = pos[0], pos[1]
	case "refine":
		inv.slug, inv.hash, inv.file = pos[0], pos[1], pos[2]
		if len(inv.hash) != 64 || !hashRe.MatchString(inv.hash) {
			return fail("<sha256> must be 64 lowercase hex characters")
		}
	case "build", "resume":
		inv.slug = pos[0]
	case "approve":
		inv.slug = pos[0]
		if len(pos) == 2 {
			if !hashRe.MatchString(pos[1]) {
				return fail("<hash> must be 6 to 64 lowercase hex characters")
			}
			inv.hash = pos[1]
		}
	}
	return inv, "", nil
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func isHelpFlag(tok string) bool {
	return tok == "--help" || tok == "-h"
}

// fail prints an error line on stdout (CLI-6) and exits.
func fail(code int, line string) {
	fmt.Print(line + "\n")
	os.Exit(code)
}

func main() {
	if handled, code := localRead(os.Args[1:]); handled {
		os.Exit(code)
	}
	inv, page, uerr := parse(os.Args[1:])
	if uerr != nil {
		fmt.Print(uerr.msg + "\n\n" + pages[uerr.page])
		os.Exit(2)
	}
	if inv == nil {
		fmt.Print(page)
		return
	}
	root := installRoot()
	// LOOP-11: project commands get Kogen's own Node (INS-4) and its bundled Cucumber (SET-13).
	if node, err := os.ReadFile(filepath.Join(root, "node-path")); err == nil {
		os.Setenv("KOGEN_NODE", strings.TrimSpace(string(node)))
	}
	os.Setenv("KOGEN_CUCUMBER", filepath.Join(root, "lib", "cucumber", "node_modules"))
	os.Setenv("KOGEN_QUINT", filepath.Join(root, "lib", "quint", "node_modules", "@informalsystems", "quint", "dist", "src", "cli.js"))
	if inv.command == "uninstall" {
		uninstall(root)
		return
	}
	cwd, err := os.Getwd()
	if err != nil {
		fail(3, "environment/cwd_unavailable: "+err.Error())
	}
	var diagnostic map[string]string
	if inv.context != nil {
		var e error
		diagnostic, e = readDiagnostic(cwd, *inv.context)
		if e != nil {
			fail(2, "intent/context_unavailable: "+e.Error())
		}
	}
	run := map[string]any{"type": "run", "command": inv.command, "cwd": cwd, "install_root": root, "env": environ()}
	if inv.command == "login" {
		run["provider"] = inv.provider
	}
	if diagnostic != nil {
		run["context"] = diagnostic
	}
	switch inv.command {
	case "shape", "refine", "approve", "build", "resume":
		if inv.command != "resume" && (!slugRe.MatchString(inv.slug) || len(inv.slug) < 3 || len(inv.slug) > 48) {
			fail(2, "intent/invalid_slug: Slug must be 3 to 48 characters and use lowercase letters, digits and dashes.")
		}
		project := cwd
		if inv.project != "" {
			project = absFrom(cwd, inv.project)
			if st, err := os.Stat(project); err != nil || !st.IsDir() {
				fail(3, "environment/project_unavailable: "+project)
			}
		}
		run["project"], run["slug"] = project, inv.slug
		if inv.hash != "" {
			run["hash"] = inv.hash
		}
		if inv.by != "" {
			run["by"] = inv.by
		}
		if inv.command == "shape" || inv.command == "refine" {
			run["input"] = readRequest(cwd, inv.file)
			if inv.file != "-" {
				run["input_path"] = absFrom(cwd, inv.file)
			}
		}
	case "init":
		run["project"] = cwd
	case "login":
		if err := checkSeams(); err != "" {
			fail(3, err)
		}
	}
	if inv.command == "shape" || inv.command == "refine" || inv.command == "build" || inv.command == "resume" {
		if err := checkSeams(); err != "" {
			fail(3, err)
		}
	}
	os.Exit(newSession(root).run(run))
}

func absFrom(cwd, p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Join(cwd, p)
}

// readRequest reads the request (or the answers) from a file or stdin; it is sent to the
// core as protocol data, never in argv (SHP-1).
func readRequest(cwd, file string) string {
	name := "stdin"
	var data []byte
	var err error
	if file == "-" {
		data, err = io.ReadAll(os.Stdin)
	} else {
		name = absFrom(cwd, file)
		data, err = os.ReadFile(name)
		if os.IsNotExist(err) {
			fail(2, "intent/request_unavailable: "+name+": not found")
		}
	}
	if err != nil {
		fail(2, "intent/request_unavailable: "+name+": unreadable")
	}
	if strings.TrimSpace(string(data)) == "" {
		fail(2, "intent/request_unavailable: "+name+": empty")
	}
	return string(data)
}

var seamRe = regexp.MustCompile(`^http://(127\.0\.0\.1|localhost):[0-9]+$`)

// checkSeams accepts only loopback test URLs (GPT-11).
func checkSeams() string {
	for _, name := range []string{"KOGEN_PROVIDER_URL", "KOGEN_AUTH_URL"} {
		if v, ok := os.LookupEnv(name); ok && !seamRe.MatchString(v) {
			return "environment/invalid_test_seam: " + name + " must be http://127.0.0.1:<port> or http://localhost:<port>"
		}
	}
	return ""
}

func environ() map[string]string {
	env := map[string]string{}
	for _, kv := range os.Environ() {
		if k, v, ok := strings.Cut(kv, "="); ok {
			env[k] = v
		}
	}
	return env
}

// installRoot is <prefix>/lib/kogen: the folder holding bin/kogen, found through symlinks (INS-3).
func installRoot() string {
	self, err := os.Executable()
	if err == nil {
		self, err = filepath.EvalSymlinks(self)
	}
	if err != nil {
		fail(3, "environment/core_unavailable: cannot locate the kogen program: "+err.Error()+"; reinstall Kogen")
	}
	return filepath.Dir(filepath.Dir(self))
}

// uninstall removes <prefix>/lib/kogen and the <prefix>/bin/kogen link (INS-5).
func uninstall(root string) {
	prefix := filepath.Dir(filepath.Dir(root))
	link := filepath.Join(prefix, "bin", "kogen")
	target, err := filepath.EvalSymlinks(link)
	if filepath.Base(root) != "kogen" || filepath.Base(filepath.Dir(root)) != "lib" || err != nil || target != filepath.Join(root, "bin", "kogen") {
		fail(3, "environment/not_installed: this kogen runs from "+root+", not from an installation made by install.sh")
	}
	if err := os.Remove(link); err != nil {
		fail(3, "environment/uninstall_failed: "+err.Error())
	}
	if err := os.RemoveAll(root); err != nil {
		fail(3, "environment/uninstall_failed: "+err.Error())
	}
	fmt.Print("Uninstalled kogen from " + prefix + "\n")
	fmt.Print("Kept your ChatGPT, SuperGrok and OpenCode Go logins; remove it with: rm -f ~/.kogen/credentials/chatgpt.json ~/.kogen/credentials/chatgpt.lock ~/.kogen/host-id ~/.kogen/credentials/supergrok.json ~/.kogen/credentials/supergrok.lock ~/.kogen/credentials/opencode-go.json ~/.kogen/credentials/opencode-go.lock\n")
}

// coreCommand starts the Elixir release in its own process group, so terminal signals reach
// only kogen. +Bi makes the BEAM ignore SIGINT; +fnu keeps file names UTF-8 (CLI-9). The
// release's vm.args sends the kernel logger to stderr, so stdout carries only the protocol (CLI-4).
func coreCommand(root string) (*exec.Cmd, io.WriteCloser, *bufio.Reader) {
	core := filepath.Join(root, "lib", "release", "bin", "kogen")
	if _, err := os.Stat(core); err != nil {
		fail(3, "environment/core_unavailable: "+core+" is missing; reinstall Kogen")
	}
	cmd := exec.Command(core, "eval", "Kogen.Main.main()")
	env := []string{"ELIXIR_ERL_OPTIONS=+Bi +fnu"}
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "ELIXIR_ERL_OPTIONS=") {
			env = append(env, kv)
		}
	}
	cmd.Env = env
	cmd.Stderr = os.Stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	in, _ := cmd.StdinPipe()
	out, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		fail(3, "environment/core_unavailable: "+err.Error()+"; reinstall Kogen")
	}
	return cmd, in, bufio.NewReaderSize(out, 1<<20)
}

func encode(m map[string]any) []byte {
	b, _ := json.Marshal(m)
	return append(b, '\n')
}

// validateDiagnostic counts original bytes, before JSON encoding.
func validateDiagnostic(data []byte) bool {
	return len(data) <= 262144 && utf8.Valid(data) && strings.TrimSpace(string(data)) != ""
}

func readDiagnostic(cwd, file string) (map[string]string, error) {
	path := absFrom(cwd, file)
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return nil, fmt.Errorf("file must be readable and regular")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("file is unreadable")
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 262145))
	if err != nil || !validateDiagnostic(data) {
		return nil, fmt.Errorf("file must contain nonblank UTF-8 data of at most 262144 bytes")
	}
	return map[string]string{"text": string(data), "source_path": path, "sha256": fmt.Sprintf("%x", sha256.Sum256(data))}, nil
}
