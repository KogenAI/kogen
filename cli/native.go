package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// runNative runs the commands implemented in Go. ok is false for commands that are not.
func runNative(inv *invocation, root string) (code int, ok bool) {
	switch inv.command {
	case "version":
		line := versionLine(root)
		if line == "" {
			fmt.Print("environment/installation_damaged: " + filepath.Join(root, "lib", "VERSION") + " is missing; reinstall Kogen\n")
			return 3, true
		}
		fmt.Println(line)
		return 0, true
	case "list":
		if inv.json {
			json.NewEncoder(os.Stdout).Encode(provider.Profiles())
			return 0, true
		}
		home, _ := os.UserHomeDir()
		for _, line := range provider.Status(home) {
			fmt.Println(line)
		}
		fmt.Print(provider.OfficialText())
		return 0, true
	case "login":
		s := sys.New()
		if err := provider.CheckSeams(s); err != nil {
			return exitFor(err), true
		}
		stop := s.WatchSignals()
		defer stop()
		client := provider.NewClient(versionLine(root))
		return exitFor(client.Login(s.Context(), s, inv.provider, browserRedirect(s))), true
	}
	return 0, false
}

// exitFor prints a Kogen error line (CLI-6) and returns the exit code: 0, the error's exit,
// the signal exit after an interrupt, or 70 for an internal failure.
func exitFor(err error) int {
	if err == nil {
		return 0
	}
	var in *sys.Interrupted
	if errors.As(err, &in) {
		return in.ExitCode()
	}
	if e, ok := sys.AsError(err); ok {
		fmt.Print(e.Render())
		return e.Exit
	}
	fmt.Printf("controller/internal_error: %s\n", strings.SplitN(err.Error(), "\n", 2)[0])
	return 70
}

// versionLine is the installed VERSION line, `kogen <id> (<date>[, uncommitted source])`.
func versionLine(root string) string {
	if b, err := os.ReadFile(filepath.Join(root, "lib", "VERSION")); err == nil {
		return strings.TrimSpace(string(b))
	}
	return ""
}

// versionID is the second word of the VERSION line (8 hex, or dev+<hash8>).
func versionID(line string) string {
	if f := strings.Fields(line); len(f) > 1 {
		return f[1]
	}
	return ""
}

// browserRedirect opens the authorization address once and returns each sign-in redirect
// received on the loopback listener or pasted on stdin (GPT-2).
func browserRedirect(s *sys.Session) provider.RedirectFunc {
	var once sync.Once
	redirects := make(chan string, 8)
	return func(authURL string) (url.Values, error) {
		once.Do(func() {
			listen(s, redirects)
			openBrowser(s, authURL)
		})
		select {
		case raw := <-redirects:
			u, err := url.Parse(raw)
			if err != nil {
				return url.Values{}, nil
			}
			return u.Query(), nil
		case <-s.Context().Done():
			return nil, s.Err()
		}
	}
}

func listen(s *sys.Session, redirects chan<- string) {
	ln, err := net.Listen("tcp", "127.0.0.1:1455")
	if err != nil {
		fmt.Fprintf(s.Stderr, "kogen: cannot listen on 127.0.0.1:1455 (%v); paste the redirect URL here instead\n", err)
	} else {
		mux := http.NewServeMux()
		mux.HandleFunc("/auth/callback", func(w http.ResponseWriter, r *http.Request) {
			io.WriteString(w, "Kogen received the sign-in. You can close this tab and return to the terminal.\n")
			redirects <- "http://127.0.0.1:1455" + r.URL.RequestURI()
		})
		go http.Serve(ln, mux)
	}
	go func() {
		sc := bufio.NewScanner(os.Stdin)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		for sc.Scan() {
			if line := strings.TrimSpace(sc.Text()); line != "" {
				redirects <- line
			}
		}
	}()
}

// openBrowser opens the address unless KOGEN_NO_BROWSER=1 (GPT-2).
func openBrowser(s *sys.Session, u string) {
	if s.Getenv("KOGEN_NO_BROWSER") == "1" {
		return
	}
	opener := "xdg-open"
	if runtime.GOOS == "darwin" {
		opener = "open"
	}
	cmd := exec.Command(opener, u)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if cmd.Start() == nil {
		go cmd.Wait()
	}
}
