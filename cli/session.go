package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"
)

// session is one invocation of the core.
type session struct {
	root   string
	core   *exec.Cmd
	in     io.WriteCloser
	out    *bufio.Reader
	sendMu sync.Mutex

	mu        sync.Mutex
	groups    map[int]bool // process groups of the commands this invocation started
	cancelled string       // "SIGINT" or "SIGTERM" once the caller interrupted

	build map[string]any // run record facts of a running Build, for CLI-8
}

func newSession(root string) *session {
	return &session{root: root, groups: map[int]bool{}}
}

func (s *session) send(m map[string]any) {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	s.in.Write(encode(m))
}

// run starts the core, says hello, sends the request and serves the core until it exits.
func (s *session) run(req map[string]any) int {
	restoreInput := func() {}
	defer func() { restoreInput() }()
	sigs := make(chan os.Signal, 2)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer signal.Stop(sigs)
	s.core, s.in, s.out = coreCommand(s.root)

	msgs := make(chan map[string]any)
	readErr := make(chan error, 1)
	go func() {
		for {
			m, err := s.readMsg()
			if err != nil {
				readErr <- err
				return
			}
			msgs <- m
		}
	}()

	// The hello exchange takes part in the interrupt handling too (CLI-7): a core that never
	// answers must not keep Ctrl-C from working. Nothing has started yet to clean up.
	s.send(map[string]any{"type": "hello"})
	select {
	case hello := <-msgs:
		if hello["type"] != "hello" {
			s.killCore()
			fail(3, fmt.Sprintf("environment/core_unavailable: the core did not answer hello (it answered %v); reinstall Kogen", hello["type"]))
		}
	case err := <-readErr:
		s.killCore()
		fail(3, "environment/core_unavailable: the core did not answer hello ("+err.Error()+"); reinstall Kogen")
	case sig := <-sigs:
		s.killCore()
		return signalCode(signalName(sig))
	}
	s.send(req)

	var deadline <-chan time.Time
	for {
		select {
		case m := <-msgs:
			if m["type"] == "secret_input" {
				if info, err := os.Stdin.Stat(); err == nil && info.Mode()&os.ModeCharDevice != 0 {
					cmd := exec.Command("stty", "-g")
					cmd.Stdin = os.Stdin
					state, err := cmd.Output()
					if err != nil {
						s.send(map[string]any{"type": "secret_input", "ok": false})
						continue
					}
					restoreInput = func() {
						cmd := exec.Command("stty", strings.TrimSpace(string(state)))
						cmd.Stdin = os.Stdin
						_ = cmd.Run()
					}
					off := exec.Command("stty", "-echo")
					off.Stdin = os.Stdin
					if off.Run() != nil {
						s.send(map[string]any{"type": "secret_input", "ok": false})
						continue
					}

				}
			}
			if code, done := s.handle(m); done {
				s.endCore()
				s.stopGroups()
				return code
			}
		case err := <-readErr:
			return s.coreStopped(err)
		case sig := <-sigs:
			if s.cancel(sig) {
				deadline = time.After(15 * time.Second)
			}
		case <-deadline:
			// CLI-7: the core did not finish in time; kill it and every command group.
			s.killCore()
			s.killGroups()
			return signalCode(s.cancelled)
		}
	}
}

func (s *session) readMsg() (map[string]any, error) {
	line, err := s.out.ReadBytes('\n')
	if err != nil {
		if errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("the core exited")
		}
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		return nil, fmt.Errorf("the core wrote a line that is not protocol: %q", strings.TrimSpace(string(line)))
	}
	return m, nil
}

// handle serves one core message; it returns the exit code when the core is done.
func (s *session) handle(m map[string]any) (int, bool) {
	switch m["type"] {
	case "out":
		os.Stdout.WriteString(m["text"].(string))
	case "exec":
		go s.exec(m)
	case "secret_input":
		go func() {
			var value []byte
			var err error
			if info, e := os.Stdin.Stat(); e == nil && info.Mode()&os.ModeCharDevice != 0 {
				var line string
				line, err = bufio.NewReader(os.Stdin).ReadString('\n')
				value = []byte(line)
			} else {
				value, err = io.ReadAll(os.Stdin)
			}
			s.send(map[string]any{"type": "secret_input", "value": string(value), "ok": (err == nil || err == io.EOF) && utf8.Valid(value)})
		}()
	case "listen":
		s.listen()
		openBrowser(m["url"].(string))
	case "build_started":
		s.build = m
	case "exit":
		return int(m["code"].(float64)), true
	}
	return 0, false
}

// cancel forwards the caller's interrupt to the core and stops every command group (CLI-7).
func (s *session) cancel(sig os.Signal) bool {
	s.mu.Lock()
	if s.cancelled != "" {
		s.mu.Unlock()
		return false
	}
	name := signalName(sig)
	s.cancelled = name
	s.mu.Unlock()
	s.send(map[string]any{"type": "cancel", "signal": name})
	go s.stopGroups()
	return true
}

func signalName(sig os.Signal) string {
	return map[os.Signal]string{syscall.SIGINT: "SIGINT", syscall.SIGTERM: "SIGTERM", syscall.SIGHUP: "SIGHUP"}[sig]
}

func signalCode(name string) int {
	return map[string]int{"SIGINT": 130, "SIGTERM": 143, "SIGHUP": 129}[name]
}

// coreStopped reports a core that exited without a result (CLI-8).
func (s *session) coreStopped(cause error) int {
	s.killCore()
	s.killGroups()
	status := exitStatus(s.core.ProcessState)
	if !strings.HasPrefix(cause.Error(), "the core exited") {
		fmt.Printf("controller/internal_error: %s\n", cause)
		return 70
	}
	if s.build == nil {
		fmt.Printf("controller/internal_error: the Kogen core stopped unexpectedly (status %d); nothing was committed\n", status)
		return 70
	}
	root, _ := s.build["root"].(string)
	start, _ := s.build["start_head"].(string)
	runLog, _ := s.build["run_log"].(string)
	id := filepath.Base(filepath.Dir(runLog))
	if runID.MatchString(id) {
		fmt.Printf("  kogen intent inspect %s --project %s\n", id, shellQuote(root))
	}
	out, err := exec.Command("git", "-C", root, "rev-parse", "HEAD").Output()
	head := strings.TrimSpace(string(out))
	if err != nil {
		fmt.Printf("controller/internal_error: the Kogen core stopped unexpectedly (status %d); HEAD could not be observed; inspect the checkout; run log: %s\n", status, runLog)
		return 70
	}
	if head == start {
		fmt.Printf("controller/internal_error: the Kogen core stopped unexpectedly (status %d); nothing was committed; run log: %s\n", status, runLog)
		return 70
	}
	sha8 := head[:8]
	fmt.Printf("controller/internal_error: the Kogen core stopped unexpectedly (status %d) after creating commit %s, before checking it; inspect it with git show %s; run log: %s\n", status, sha8, sha8, runLog)
	return 70
}

func exitStatus(ps *os.ProcessState) int {
	if ps == nil {
		return -1
	}
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ps.ExitCode()
}

// endCore lets the core halt on the closed stdin, then makes sure its group is gone.
func (s *session) endCore() {
	s.in.Close()
	done := make(chan struct{})
	go func() { s.core.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		syscall.Kill(-s.core.Process.Pid, syscall.SIGKILL)
		<-done
	}
}

func (s *session) killCore() {
	syscall.Kill(-s.core.Process.Pid, syscall.SIGKILL)
	s.core.Wait()
}

// exec runs one project command for the core: /bin/sh -c in a new process group, stdin
// closed, the caller's environment plus the core's additions, combined output (LOOP-5).
func (s *session) exec(m map[string]any) {
	id := m["id"]
	cmd := exec.Command("/bin/sh", "-c", m["command"].(string))
	cmd.Dir = m["cwd"].(string)
	cmd.Env = os.Environ()
	for k, v := range m["env"].(map[string]any) {
		cmd.Env = append(cmd.Env, k+"="+v.(string))
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	buf := &capBuffer{}
	cmd.Stdout, cmd.Stderr = buf, buf
	// The call returns when sh exits, even if a background child keeps the output open.
	cmd.WaitDelay = time.Second
	// Deciding to start and registering the group happen under the lock that cancel takes, so
	// nothing starts after an interrupt and every started group is stopped (CLI-7).
	s.mu.Lock()
	if s.cancelled != "" {
		code := signalCode(s.cancelled)
		s.mu.Unlock()
		s.send(map[string]any{"type": "exec_done", "id": id, "status": code, "output": "", "timed_out": false})
		return
	}
	if err := cmd.Start(); err != nil {
		s.mu.Unlock()
		s.send(map[string]any{"type": "exec_done", "id": id, "status": 127, "output": err.Error(), "timed_out": false})
		return
	}
	pgid := cmd.Process.Pid
	s.groups[pgid] = true
	s.mu.Unlock()
	s.send(map[string]any{"type": "exec_started", "id": id, "pgid": pgid})

	var timedOut atomic.Bool
	if t, ok := m["timeout_ms"].(float64); ok {
		timer := time.AfterFunc(time.Duration(t)*time.Millisecond, func() {
			timedOut.Store(true)
			terminate([]int{pgid})
		})
		defer timer.Stop()
	}
	cmd.Wait()
	s.send(map[string]any{"type": "exec_done", "id": id, "status": exitStatus(cmd.ProcessState), "output": buf.String(), "timed_out": timedOut.Load()})
}

// stopGroups terminates every process group this invocation started: SIGTERM, then SIGKILL
// after 5 seconds for groups still alive (LOOP-5, CLI-7).
func (s *session) stopGroups() {
	terminate(s.groupList())
}

func (s *session) killGroups() {
	for _, g := range s.groupList() {
		syscall.Kill(-g, syscall.SIGKILL)
	}
}

func (s *session) groupList() []int {
	s.mu.Lock()
	defer s.mu.Unlock()
	var list []int
	for g := range s.groups {
		list = append(list, g)
	}
	return list
}

func terminate(groups []int) {
	var alive []int
	for _, g := range groups {
		if syscall.Kill(-g, syscall.SIGTERM) == nil {
			alive = append(alive, g)
		}
	}
	for i := 0; i < 50 && len(alive) > 0; i++ {
		time.Sleep(100 * time.Millisecond)
		var still []int
		for _, g := range alive {
			if syscall.Kill(-g, 0) == nil {
				still = append(still, g)
			}
		}
		alive = still
	}
	for _, g := range alive {
		syscall.Kill(-g, syscall.SIGKILL)
	}
}

// capBuffer keeps the first and last 512 KiB of a command's output.
type capBuffer struct {
	mu      sync.Mutex
	head    []byte
	tail    []byte
	dropped int
}

const capHalf = 512 << 10

func (b *capBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n := len(p)
	if room := capHalf - len(b.head); room > 0 {
		k := min(room, len(p))
		b.head = append(b.head, p[:k]...)
		p = p[k:]
	}
	b.tail = append(b.tail, p...)
	if over := len(b.tail) - capHalf; over > 0 {
		b.dropped += over
		b.tail = append(b.tail[:0], b.tail[over:]...)
	}
	return n, nil
}

func (b *capBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.dropped == 0 {
		return string(b.head) + string(b.tail)
	}
	return fmt.Sprintf("%s\n[... %d bytes omitted ...]\n%s", b.head, b.dropped, b.tail)
}

// listen waits for the sign-in redirect on the loopback listener, or pasted on stdin, and
// forwards each one to the core, which checks its state (GPT-2).
func (s *session) listen() {
	forward := func(u string) { s.send(map[string]any{"type": "redirect", "url": u}) }
	ln, err := net.Listen("tcp", "127.0.0.1:1455")
	if err != nil {
		fmt.Fprintf(os.Stderr, "kogen: cannot listen on 127.0.0.1:1455 (%v); paste the redirect URL here instead\n", err)
	} else {
		mux := http.NewServeMux()
		mux.HandleFunc("/auth/callback", func(w http.ResponseWriter, r *http.Request) {
			io.WriteString(w, "Kogen received the sign-in. You can close this tab and return to the terminal.\n")
			forward("http://127.0.0.1:1455" + r.URL.RequestURI())
		})
		go http.Serve(ln, mux)
	}
	go func() {
		sc := bufio.NewScanner(os.Stdin)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		for sc.Scan() {
			if line := strings.TrimSpace(sc.Text()); line != "" {
				forward(line)
			}
		}
	}()
}

// openBrowser opens the authorization URL unless KOGEN_NO_BROWSER=1 (GPT-2).
func openBrowser(url string) {
	if os.Getenv("KOGEN_NO_BROWSER") == "1" {
		return
	}
	opener := "xdg-open"
	if runtime.GOOS == "darwin" {
		opener = "open"
	}
	cmd := exec.Command(opener, url)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if cmd.Start() == nil {
		go cmd.Wait()
	}
}
