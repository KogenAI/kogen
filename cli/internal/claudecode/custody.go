package claudecode

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

// startCustodied holds the round at a gate until an independent process has recorded
// its group. Only the owner holds the lifetime writer; the round never inherits it.
func startCustodied(cmd *exec.Cmd, token string) (func(), error) {
	lifeR, lifeW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer lifeR.Close()
	ackR, ackW, err := os.Pipe()
	if err != nil {
		lifeW.Close()
		return nil, err
	}
	defer ackR.Close()
	defer ackW.Close()
	gateR, gateW, err := os.Pipe()
	if err != nil {
		lifeW.Close()
		return nil, err
	}
	defer gateR.Close()
	defer gateW.Close()
	supervisor := exec.Command("/bin/sh", "-c", `IFS= read -r group <&3 || exit 0
printf 'ready\n' >&4
if ! IFS= read -r done <&3; then /bin/kill -KILL -- "-$group" 2>/dev/null; fi`)
	supervisor.ExtraFiles = []*os.File{lifeR, ackW}
	if err = supervisor.Start(); err != nil {
		lifeW.Close()
		return nil, err
	}
	ackW.Close()
	lifeR.Close()
	retire := func() { fmt.Fprintln(lifeW, "done"); lifeW.Close(); supervisor.Wait() }
	fail := func(err error) (func(), error) { lifeW.Close(); supervisor.Wait(); return nil, err }
	// The shell exits without executing the runtime if its gate closes before release.
	args := append([]string{"-c", `IFS= read -r go <&4 || exit 1; exec 4<&-; exec "$@"`, "custody", cmd.Path}, cmd.Args[1:]...)
	cmd.Path = "/bin/sh"
	cmd.Args = append([]string{"/bin/sh"}, args...)
	cmd.ExtraFiles = []*os.File{nil, gateR}
	if err = startWithToken(cmd, token, cmd.Start); err != nil {
		return fail(err)
	}
	gateR.Close()
	if _, err = fmt.Fprintln(lifeW, strconv.Itoa(cmd.Process.Pid)); err == nil {
		_, err = bufio.NewReader(ackR).ReadString('\n')
	}
	if err == nil {
		_, err = fmt.Fprintln(gateW, "go")
	}
	if err != nil {
		lifeW.Close()
		syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		cmd.Wait()
		supervisor.Wait()
		return nil, err
	}
	gateW.Close()
	return retire, nil
}
