package build

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"kogen-loop/sys"
	"kogen-loop/tools"
)

// A native `shell` call that has written no output for shellSilence is stopped with its
// process group, and its result names the command (LOOP-5). The vendored tool is unchanged:
// Kogen runs the same command itself, through the same Session.RunContext, with its output in
// a private file whose size it watches. These are fixed values; only tests shorten them.
var (
	// shellSilence is how long a running call may write no new output byte.
	shellSilence = 10 * time.Minute
	// shellAbandon is how long Kogen waits for the runner after asking for the stop.
	shellAbandon = time.Minute
)

// shellCapHalf is the runner's capture of one command's output: its first and last 512 KiB.
const shellCapHalf = 512 << 10

// watchedShell runs a native shell call of owner ("build" or "review") under the silence
// watch. It reports false, running nothing, for a call the vendored tool must answer itself:
// another tool, a non-string command, or a command the foreign-kill rule refuses.
func (b *Attempt) watchedShell(ctx context.Context, tl *tools.Tools, call tools.Call, owner string) (tools.Output, bool, error) {
	if call.Name != tools.ShellTool {
		return tools.Output{}, false, nil
	}
	command, ok := call.Args()["command"].(string)
	if !ok {
		return tools.Output{}, false, nil
	}
	if _, refused := sys.ForeignKill(command, b.s.Owned); refused {
		return tools.Output{}, false, nil
	}
	dir, err := os.MkdirTemp("", "kogen-shell-")
	if err != nil {
		return tools.Output{}, true, err
	}
	defer os.RemoveAll(dir)
	file := filepath.Join(dir, "output")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		return tools.Output{}, true, err
	}
	wrapper := "exec >>" + shellQuote(file) + " 2>&1 && exec /bin/sh -c " + shellQuote(command)

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	type outcome struct {
		res sys.Result
		err error
	}
	done := make(chan outcome, 1)
	go func() {
		res, err := tl.Session.RunContext(runCtx, wrapper, tl.Root, sys.Options{})
		done <- outcome{res, err}
	}()

	ordinary := func(o outcome) (tools.Output, bool, error) {
		if o.err != nil {
			return tools.Output{}, true, o.err
		}
		text := "exit status: " + strconv.Itoa(o.res.Status) + "\n" + o.res.Output + cappedFile(file)
		return tools.Output{Text: text}.Cut(), true, nil
	}

	poll := max(5*time.Millisecond, min(time.Second, shellSilence/4))
	tick := time.NewTicker(poll)
	defer tick.Stop()
	size, last := int64(0), time.Now()
	for {
		select {
		case o := <-done:
			return ordinary(o)
		case <-tick.C:
		}
		if st, err := os.Stat(file); err == nil && st.Size() > size {
			size, last = st.Size(), time.Now()
		}
		if time.Since(last) < shellSilence {
			continue
		}
		break
	}

	// Ask for the stop, then wait for the runner: an ordinary result that arrives first is
	// the result; one that does not arrive in time is abandoned, not joined.
	cancel()
	wait := time.NewTimer(shellAbandon)
	defer wait.Stop()
	select {
	case o := <-done:
		if !errors.Is(o.err, context.Canceled) || ctx.Err() != nil {
			return ordinary(o)
		}
	case <-wait.C:
	}
	b.Run.Event(map[string]any{"event": "command_no_progress", "owner": owner, "name": tools.ShellTool,
		"command": command, "rule": "no_output", "after_ms": shellSilence.Milliseconds()})
	notice := fmt.Sprintf("no output for %s; Kogen stopped the command and its process group: %s", shellSilence, command)
	b.s.Progress("kogen: " + notice)
	return tools.Output{Text: notice + "\n" + cappedFile(file)}.Cut(), true, nil
}

// cappedFile is the file's bytes under the runner's capture rule: all of them up to 1 MiB,
// else the first and last 512 KiB around the marker for the bytes between.
func cappedFile(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return ""
	}
	size := st.Size()
	read := func(off, n int64) string {
		buf := make([]byte, n)
		got, _ := io.ReadFull(io.NewSectionReader(f, off, n), buf)
		return string(buf[:got])
	}
	if size <= 2*shellCapHalf {
		return read(0, size)
	}
	return read(0, shellCapHalf) + fmt.Sprintf("\n[... %s bytes omitted ...]\n", strconv.FormatInt(size-2*shellCapHalf, 10)) + read(size-shellCapHalf, shellCapHalf)
}
