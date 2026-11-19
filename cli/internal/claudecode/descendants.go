package claudecode

import (
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// descendantRefresh is how often the descendants of a running child are recorded again: once the
// child has exited, a descendant that left its group is reparented and can no longer be found.
const descendantRefresh = 500 * time.Millisecond

// descendantWait bounds the wait for killed descendants to be gone.
const descendantWait = 3 * time.Second

// processTable returns the text of `ps -A -o pid=,ppid=,lstart=`: one process per line. Tests
// replace it.
var processTable = func() (string, error) {
	out, err := exec.Command("ps", "-A", "-o", "pid=,ppid=,lstart=").Output()
	return string(out), err
}

// procID identifies one process: a pid alone can be reused, its start time cannot.
type procID struct {
	pid   int
	start string
}

type procRow struct {
	procID
	ppid int
}

// readProcesses parses the process table; a listing error yields no rows.
func readProcesses() ([]procRow, bool) {
	text, err := processTable()
	if err != nil {
		return nil, false
	}
	var rows []procRow
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		rows = append(rows, procRow{procID{pid, strings.Join(f[2:], " ")}, ppid})
	}
	return rows, true
}

// descendants records the processes below one child, found by following parent pids from the
// child's pid, and stops them when the child's round or preflight ends.
type descendants struct {
	mu        sync.Mutex
	root      int
	rootStart string
	seen      map[procID]bool
	order     []procID
}

// begin sets the child's pid.
func (d *descendants) begin(root int) {
	d.mu.Lock()
	d.root = root
	d.mu.Unlock()
}

// refresh adds the current descendants of the child to the record. A listing error adds nothing.
func (d *descendants) refresh() {
	if d == nil {
		return
	}
	d.mu.Lock()
	root := d.root
	d.mu.Unlock()
	if root <= 0 {
		return
	}
	rows, ok := readProcesses()
	if !ok {
		return
	}
	children := map[int][]procRow{}
	var rootRow *procRow
	for i, r := range rows {
		children[r.ppid] = append(children[r.ppid], r)
		if r.pid == root {
			rootRow = &rows[i]
		}
	}
	if rootRow == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.rootStart == "" {
		d.rootStart = rootRow.start
	} else if d.rootStart != rootRow.start {
		return // the pid belongs to another process now
	}
	if d.seen == nil {
		d.seen = map[procID]bool{}
	}
	visited := map[int]bool{root: true}
	queue := []int{root}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for _, c := range children[p] {
			if visited[c.pid] {
				continue
			}
			visited[c.pid] = true
			if !d.seen[c.procID] {
				d.seen[c.procID] = true
				d.order = append(d.order, c.procID)
			}
			queue = append(queue, c.pid)
		}
	}
}

// track refreshes the record every descendantRefresh until the returned function is called.
func (d *descendants) track() (end func()) {
	done := make(chan struct{})
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		t := time.NewTicker(descendantRefresh)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				d.refresh()
			}
		}
	}()
	var once sync.Once
	return func() {
		once.Do(func() {
			close(done)
			<-finished
		})
	}
}

// running reports whether the recorded process is still alive and still the same process; a
// zombie awaiting its reaper counts as gone.
func (id procID) running(rows []procRow) bool {
	for _, r := range rows {
		if r.procID != id {
			continue
		}
		if err := syscall.Kill(id.pid, 0); err != nil && err != syscall.EPERM {
			return false
		}
		out, _ := exec.Command("ps", "-o", "stat=", "-p", strconv.Itoa(id.pid)).Output()
		stat := strings.TrimSpace(string(out))
		return stat == "" || !strings.HasPrefix(stat, "Z")
	}
	return false
}

// stop sends SIGKILL to each recorded descendant that is still the same live process, then
// waits a bounded time for them to be gone. It records the current descendants first. Without a
// process listing nothing is signalled.
func (d *descendants) stop() {
	if d == nil {
		return
	}
	d.refresh()
	d.mu.Lock()
	list := append([]procID(nil), d.order...)
	d.mu.Unlock()
	if len(list) == 0 {
		return
	}
	rows, ok := readProcesses()
	if !ok {
		return
	}
	for _, id := range list {
		if id.running(rows) {
			syscall.Kill(id.pid, syscall.SIGKILL)
		}
	}
	end := time.Now().Add(descendantWait)
	for time.Now().Before(end) {
		rows, ok := readProcesses()
		if !ok {
			return
		}
		pending := false
		for _, id := range list {
			if id.running(rows) {
				pending = true
				break
			}
		}
		if !pending {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
}
