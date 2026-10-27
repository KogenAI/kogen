package sys

import (
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"syscall"
)

// Rule identifiers returned by ForeignKill.
const (
	RulePkillKillall   = "pkill-killall"
	RuleKillForeignPid = "kill-foreign-pid"
)

// RefusalText is the tool text for a command refused by ForeignKill.
func RefusalText(rule string) string {
	text := "kill only pids this run created"
	if rule == RulePkillKillall {
		text = "no pkill or killall; " + text
	}
	return "refused: this command would stop processes this run did not start (rule: " + text + "). Stop what you started with its own pid, for example kill $!, or its process group."
}

// Owned reports whether pid, or its process group, is one of the session's groups, or
// pid descends from a process in one. It is judged live at the moment of the call. For
// a negative argument -N the check is on group N.
func (s *Session) Owned(pid int) bool {
	groups := map[int]bool{}
	for _, g := range s.Groups() {
		groups[g] = true
	}
	if len(groups) == 0 || pid == 0 {
		return false
	}
	if pid < 0 {
		pid = -pid
		if groups[pid] {
			return true
		}
	} else if groups[pid] {
		return true
	}
	if pg, err := syscall.Getpgid(pid); err == nil && groups[pg] {
		return true
	}
	type proc struct{ ppid, pgid int }
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=,pgid=").Output()
	if err != nil {
		return false
	}
	table := map[int]proc{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		a, e1 := strconv.Atoi(f[0])
		b, e2 := strconv.Atoi(f[1])
		c, e3 := strconv.Atoi(f[2])
		if e1 == nil && e2 == nil && e3 == nil {
			table[a] = proc{b, c}
		}
	}
	for cur, i := pid, 0; i < 1024; i++ {
		p, ok := table[cur]
		if !ok {
			return false
		}
		if groups[cur] || groups[p.pgid] {
			return true
		}
		if p.ppid <= 1 {
			return false
		}
		cur = p.ppid
	}
	return false
}

// ForeignKill is the only implementation of the refusal rule. It is a text filter, not
// a security boundary: it stops the model's habit of cleaning up by name, not a bypass.
// It does not see `eval "$(echo ... | base64 -d)"`, `sh -c "$VAR"`, `python -c
// 'os.kill'`, `find -exec kill`, a script file containing pkill, `busybox killall` or
// computed ids. A group kill is not a sandbox either, and the exit sweep
// (Options.KillGroupOnExit) does not reach a process that left the group (setsid,
// own-session nohup, double-fork daemons, Gradle-style daemons).
//
// Rule pkill-killall: whole-word pkill or killall in command position. Rule
// kill-foreign-pid: kill of a number that owned does not accept, of 0 or -1, or of
// the result of pgrep, pidof, lsof or ps. Undecidable text (unterminated quote, eval,
// $(...), backticks) is refused only when it holds whole-word pkill or killall.
func ForeignKill(command string, owned func(pid int) bool) (rule string, refused bool) {
	cmds, undecidable := splitCommands(command)
	assigned := pidAssignments(command)
	for _, c := range cmds {
		for _, w := range c.words {
			if w.quot && wholeWord.MatchString(w.text) {
				return RulePkillKillall, true // prefer a false refusal: echo "do not pkill"
			}
		}
		name, args, xargs := commandWord(c.words)
		if name == "eval" {
			undecidable = true
		}
		switch name {
		case "pkill", "killall":
			return RulePkillKillall, true
		case "kill":
			if killsForeign(c, args, xargs, cmds, assigned, command, owned) {
				return RuleKillForeignPid, true
			}
		}
	}
	if undecidable && wholeWord.MatchString(command) {
		return RulePkillKillall, true
	}
	return "", false
}

var (
	wholeWord  = regexp.MustCompile(`(^|[^A-Za-z0-9_.-])(pkill|killall)($|[^A-Za-z0-9_.-])`)
	lookupWord = regexp.MustCompile(`(^|[^A-Za-z0-9_.-])(pgrep|pidof|lsof)($|[^A-Za-z0-9_.-])`)
	assignRe   = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
	numberRe   = regexp.MustCompile(`^-?[0-9]+$`)
	dollarBang = regexp.MustCompile(`([A-Za-z_][A-Za-z0-9_]*)=\$!`)
)

type word struct {
	text string
	sub  bool // holds $( or a backtick
	quot bool // holds quoted text
}

type simpleCmd struct {
	words []word
	pipe  int // commands of one pipeline share it
}

func pidAssignments(command string) map[string]bool {
	out := map[string]bool{}
	for _, m := range dollarBang.FindAllStringSubmatch(command, -1) {
		out[m[1]] = true
	}
	return out
}

// splitCommands splits on ; & | ( ) and newline, honoring quotes and backslash.
func splitCommands(s string) (cmds []simpleCmd, undecidable bool) {
	var cur []word
	var w strings.Builder
	inWord, sub, quoted := false, false, false
	pipe := 0
	flushWord := func() {
		if inWord {
			cur = append(cur, word{w.String(), sub, quoted})
		}
		w.Reset()
		inWord, sub, quoted = false, false, false
	}
	flushCmd := func(keepPipe bool) {
		flushWord()
		if len(cur) > 0 {
			cmds = append(cmds, simpleCmd{cur, pipe})
		}
		cur = nil
		if !keepPipe {
			pipe++
		}
	}
	r := []rune(s)
	for i := 0; i < len(r); i++ {
		ch := r[i]
		switch {
		case ch == '\\':
			if i+1 < len(r) {
				i++
				if r[i] != '\n' {
					w.WriteRune(r[i])
					inWord = true
				}
			}
		case ch == '\'':
			quoted = true
			j := i + 1
			for j < len(r) && r[j] != '\'' {
				j++
			}
			if j >= len(r) {
				undecidable = true
				w.WriteString(string(r[i+1:]))
				i = len(r)
			} else {
				w.WriteString(string(r[i+1 : j]))
				i = j
			}
			inWord = true
		case ch == '"':
			quoted = true
			j := i + 1
			closed := false
			for ; j < len(r); j++ {
				if r[j] == '\\' && j+1 < len(r) {
					j++
					w.WriteRune(r[j])
					continue
				}
				if r[j] == '"' {
					closed = true
					break
				}
				if r[j] == '`' || (r[j] == '$' && j+1 < len(r) && r[j+1] == '(') {
					sub, undecidable = true, true
				}
				w.WriteRune(r[j])
			}
			inWord = true
			if !closed {
				undecidable = true
			}
			i = j
		case ch == '`':
			sub, undecidable, inWord = true, true, true
			w.WriteRune(ch)
			flushWord()
		case ch == '$' && i+1 < len(r) && r[i+1] == '(':
			sub, undecidable, inWord = true, true, true
			w.WriteString("$")
			flushWord()
			// the substitution's own commands follow after the "(" separator
		case ch == '#' && !inWord:
			for i+1 < len(r) && r[i+1] != '\n' {
				i++
			}
		case ch == '|':
			if i+1 < len(r) && r[i+1] == '|' {
				i++
				flushCmd(false)
			} else {
				flushCmd(true)
			}
		case ch == ';' || ch == '&' || ch == '(' || ch == ')' || ch == '\n':
			flushCmd(false)
		case ch == ' ' || ch == '\t':
			flushWord()
		default:
			w.WriteRune(ch)
			inWord = true
		}
	}
	flushCmd(false)
	return cmds, undecidable
}

func base(s string) string {
	if i := strings.LastIndexByte(s, '/'); i >= 0 {
		return s[i+1:]
	}
	return s
}

// commandWord skips assignments and wrappers and returns the command word (by
// basename), its arguments and whether xargs was among the wrappers.
func commandWord(ws []word) (name string, args []word, xargs bool) {
	i := 0
	for i < len(ws) && assignRe.MatchString(ws[i].text) {
		i++
	}
	skipOpts := func(withArg ...string) {
		for i < len(ws) && strings.HasPrefix(ws[i].text, "-") && ws[i].text != "-" {
			opt := ws[i].text
			i++
			for _, a := range withArg {
				if opt == a && i < len(ws) {
					i++
					break
				}
			}
		}
	}
	for i < len(ws) {
		name = base(ws[i].text)
		i++
		switch name {
		case "sudo":
			skipOpts("-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U")
		case "xargs":
			xargs = true
			skipOpts("-n", "-I", "-P", "-L", "-s", "-d", "-E", "-a")
		case "exec", "command", "nohup", "time":
			skipOpts()
		case "env":
			skipOpts("-u", "-C", "-S")
			for i < len(ws) && assignRe.MatchString(ws[i].text) {
				i++
			}
		case "timeout":
			skipOpts("-s", "-k", "--signal", "--kill-after")
			if i < len(ws) {
				i++ // the duration
			}
		default:
			return name, ws[i:], xargs
		}
	}
	return "", nil, xargs
}

func killsForeign(c simpleCmd, args []word, xargs bool, all []simpleCmd, assigned map[string]bool, command string, owned func(int) bool) bool {
	if xargs {
		for _, o := range all {
			if o.pipe != c.pipe {
				continue
			}
			switch n, _, _ := commandWord(o.words); n {
			case "pgrep", "pidof", "lsof", "ps":
				return true
			}
		}
	}
	lookups := lookupWord.MatchString(command)
	signalOK := true // a signal flag is only the first argument
	for i := 0; i < len(args); i++ {
		a := args[i]
		t := a.text
		if a.sub {
			if lookups {
				return true
			}
			signalOK = false
			continue
		}
		if signalOK && strings.HasPrefix(t, "-") && t != "--" {
			signalOK = false
			if (t == "-s" || t == "-n") && i+1 < len(args) {
				i++
			}
			continue
		}
		signalOK = false
		if t == "--" {
			continue
		}
		if !numberRe.MatchString(t) {
			continue // $!, %N, $VAR, names: not a number
		}
		n, err := strconv.Atoi(t)
		if err != nil {
			continue
		}
		if n == 0 || n == -1 || owned == nil || !owned(n) {
			return true
		}
	}
	return false
}
