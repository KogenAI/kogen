package provider

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
)

// The two key providers differ only in names and in the reason their login failures carry.
var keyProviders = []struct{ name, label, reason string }{
	{"opencode-go", "OpenCode Go", "login_failed"},
	{"anthropic", "Anthropic", "login"},
}

const secretKey = "SYNTHETIC_PRIVATE_KEY"

func (e *env) loginWith(name string, in Input) error {
	e.t.Helper()
	e.c.Input = &in
	return e.c.Login(context.Background(), e.s, name, nil)
}

func piped(text string) Input { return Input{Reader: strings.NewReader(text)} }

// ExUnit open_code_go_login_test / anthropic: own input trims whitespace without requiring a
// vendor prefix; invalid and interrupted input preserve the exact old bytes.
func TestKeyLoginTrimsStoresPrivatelyAndPreservesBytesOnRejectedInput(t *testing.T) {
	for _, p := range keyProviders {
		t.Run(p.name, func(t *testing.T) {
			e := newEnv(t, nil)
			if err := e.loginWith(p.name, piped("  arbitrary-key\t\r\n")); err != nil {
				t.Fatal(err)
			}
			if got := e.out.String(); got != p.name+": key saved (not verified)\n" || strings.Contains(got+e.errs.String(), "arbitrary-key") {
				t.Fatalf("output = %q", got)
			}
			path := e.credPath(p.name)
			before, _ := os.ReadFile(path)
			if got := e.readCreds(p.name); !reflect.DeepEqual(got, map[string]any{"provider": p.name, "api_key": "arbitrary-key"}) {
				t.Fatalf("stored = %v", got)
			}
			for _, dir := range []string{filepath.Dir(path), filepath.Dir(filepath.Dir(path))} {
				if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
					t.Errorf("%s is %v", dir, st.Mode().Perm())
				}
			}
			if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
				t.Errorf("credential file is %v", st.Mode().Perm())
			}
			cases := map[string]string{
				"blank": "\n", "multiline": "a\nb\n", "double newline": "a\n\n", "nul": "a\x00b", "tab": "a\tb",
				"c1 control": "a\u0085b", "cr": "a\rb\n", "only spaces": "  \t \n",
			}
			wantDetail := map[string]string{
				"blank": "no " + p.label + " key supplied; saved login unchanged", "only spaces": "no " + p.label + " key supplied; saved login unchanged",
			}
			for name, input := range cases {
				e.out.Reset()
				err := e.loginWith(p.name, piped(input))
				se := mustErr(t, err)
				want := wantDetail[name]
				if want == "" {
					want = "invalid " + p.label + " key input; saved login unchanged"
				}
				if se.Class != "provider" || se.Reason != p.reason || se.Exit != 4 || se.Detail != want {
					t.Errorf("%s: %v", name, se)
				}
				if after, _ := os.ReadFile(path); !bytes.Equal(after, before) || e.out.Len() != 0 {
					t.Errorf("%s changed the saved login or printed %q", name, e.out.String())
				}
			}
			// Invalid UTF-8 never replaces the key; the input counts as unreadable.
			se := mustErr(t, e.loginWith(p.name, piped("SYNTHETIC_INVALID_\xff\n")))
			if se.Reason != p.reason || se.Detail != p.label+" input interrupted; saved login unchanged" || strings.Contains(se.Render(), "SYNTHETIC_INVALID_") {
				t.Fatalf("invalid UTF-8: %v", se)
			}
			if after, _ := os.ReadFile(path); !bytes.Equal(after, before) {
				t.Fatal("invalid UTF-8 changed the saved login")
			}
		})
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestKeyLoginInterruptedInputKeepsTheOldKey(t *testing.T) {
	for _, p := range keyProviders {
		for _, signal := range []string{"SIGINT", "SIGTERM", "SIGHUP"} {
			t.Run(p.name+"/"+signal, func(t *testing.T) {
				e := newEnv(t, nil)
				if err := e.loginWith(p.name, piped("old-key\n")); err != nil {
					t.Fatal(err)
				}
				before, _ := os.ReadFile(e.credPath(p.name))
				pr, pw := io.Pipe()
				defer pw.Close()
				done := make(chan error, 1)
				go func() { done <- e.loginWith(p.name, Input{Reader: pr}) }()
				time.Sleep(20 * time.Millisecond)
				e.s.Interrupt(signal)
				select {
				case err := <-done:
					in, ok := err.(*sys.Interrupted)
					if !ok || in.Signal != signal {
						t.Fatalf("err = %v", err)
					}
				case <-time.After(5 * time.Second):
					t.Fatal("login did not stop")
				}
				if after, _ := os.ReadFile(e.credPath(p.name)); !bytes.Equal(after, before) {
					t.Fatal("an interrupted login changed the key")
				}
			})
		}
		t.Run(p.name+"/read error", func(t *testing.T) {
			e := newEnv(t, nil)
			se := mustErr(t, e.loginWith(p.name, Input{Reader: failingReader{}}))
			if se.Detail != p.label+" input interrupted; saved login unchanged" {
				t.Fatal(se)
			}
		})
	}
}

// A held lock, a failing replacement and a stray directory all end in one message that never
// carries the key and leave the old bytes and no temporary file.
func TestKeyLoginSaveFailuresPreserveBytesAndCleanUp(t *testing.T) {
	for _, p := range keyProviders {
		t.Run(p.name, func(t *testing.T) {
			e := newEnv(t, nil)
			if err := e.loginWith(p.name, piped("old-key\n")); err != nil {
				t.Fatal(err)
			}
			path := e.credPath(p.name)
			before, _ := os.ReadFile(path)
			info, _ := Lookup(p.name)
			held, err := (Locker{}).Acquire(lockPath(e.home, info))
			if err != nil {
				t.Fatal(err)
			}
			se := mustErr(t, e.loginWith(p.name, piped("new-key\n")))
			if se.Detail != "could not save "+p.label+" key; saved login unchanged" || se.Reason != p.reason {
				t.Fatalf("held lock: %v", se)
			}
			held.Release()
			if after, _ := os.ReadFile(path); !bytes.Equal(after, before) {
				t.Fatal("a held lock replaced the key")
			}
			// A real rename failure: the credential path is a directory with content.
			os.Remove(path)
			os.Mkdir(path, 0o700)
			os.WriteFile(filepath.Join(path, "old"), before, 0o600)
			se = mustErr(t, e.loginWith(p.name, piped("new-key\n")))
			if se.Detail != "could not save "+p.label+" key; saved login unchanged" || strings.Contains(se.Render(), "new-key") {
				t.Fatalf("rename failure: %v", se)
			}
			if got, _ := os.ReadFile(filepath.Join(path, "old")); !bytes.Equal(got, before) {
				t.Fatal("old content changed")
			}
			entries, _ := os.ReadDir(filepath.Dir(path))
			if len(entries) != 1 || entries[0].Name() != p.name+".json" {
				t.Fatalf("leftovers: %v", entries)
			}
		})
	}
}

// ssty is a scripted stty: it records its calls and answers -g with a saved state.
type ssty struct {
	calls   []string
	failing string
}

func (s *ssty) run(args ...string) (string, error) {
	s.calls = append(s.calls, strings.Join(args, " "))
	if s.failing != "" && s.failing == args[0] {
		return "", io.ErrClosedPipe
	}
	if args[0] == "-g" {
		return "saved:state\n", nil
	}
	return "", nil
}

func TestKeyLoginTerminalEchoIsOffWhileTypingAndRestoredOnEveryPath(t *testing.T) {
	for _, p := range keyProviders {
		t.Run(p.name, func(t *testing.T) {
			restored := []string{"-g", "-echo", "saved:state"}
			// success: one line is read, the rest of the stream is not waited for
			e := newEnv(t, nil)
			st := &ssty{}
			in := Input{Reader: io.MultiReader(strings.NewReader("typed-key\n"), blockingReader{}), Terminal: true, Stty: st.run}
			if err := e.loginWith(p.name, in); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(st.calls, restored) || e.readCreds(p.name)["api_key"] != "typed-key" || strings.Contains(e.out.String(), "typed-key") {
				t.Fatalf("calls %v, stored %v, out %q", st.calls, e.readCreds(p.name), e.out.String())
			}
			// an empty line is an error and still restores the terminal
			st = &ssty{}
			se := mustErr(t, e.loginWith(p.name, Input{Reader: strings.NewReader("\n"), Terminal: true, Stty: st.run}))
			if se.Detail != "no "+p.label+" key supplied; saved login unchanged" || !reflect.DeepEqual(st.calls, restored) {
				t.Fatalf("empty: %v, calls %v", se, st.calls)
			}
			// a terminal that cannot be silenced is refused before anything is read
			for _, failing := range []string{"-g", "-echo"} {
				st = &ssty{failing: failing}
				se = mustErr(t, e.loginWith(p.name, Input{Reader: strings.NewReader("secret-key\n"), Terminal: true, Stty: st.run}))
				if se.Detail != p.label+" input interrupted; saved login unchanged" || e.readCreds(p.name)["api_key"] != "typed-key" {
					t.Fatalf("%s failing: %v", failing, se)
				}
			}
			// each signal restores the state
			for _, signal := range []string{"SIGINT", "SIGTERM", "SIGHUP"} {
				e2 := newEnv(t, nil)
				st = &ssty{}
				pr, pw := io.Pipe()
				done := make(chan error, 1)
				go func() { done <- e2.loginWith(p.name, Input{Reader: pr, Terminal: true, Stty: st.run}) }()
				time.Sleep(20 * time.Millisecond)
				e2.s.Interrupt(signal)
				if err := <-done; err == nil || err.(*sys.Interrupted).Signal != signal {
					t.Fatalf("%s: %v", signal, err)
				}
				pw.Close()
				if !reflect.DeepEqual(st.calls, restored) {
					t.Fatalf("%s calls %v", signal, st.calls)
				}
			}
		})
	}
}

type blockingReader struct{}

func (blockingReader) Read([]byte) (int, error) { select {} }

func TestKeyStatusAndRequiredLogin(t *testing.T) {
	e := newEnv(t, nil)
	line := func(name string) string {
		for _, l := range Status(e.home) {
			if strings.HasPrefix(l, name+":") {
				return l
			}
		}
		return ""
	}
	for _, p := range keyProviders {
		if line(p.name) != p.name+": not signed in" {
			t.Fatalf("%s", line(p.name))
		}
		hint := "no usable " + p.label + " key; run kogen provider login " + p.name
		err := RequireLogin(e.home, []Role{{Provider: p.name}})
		if se := mustErr(t, err); se.Class != "provider" || se.Reason != "login" || se.Exit != 4 || se.Detail != hint {
			t.Fatalf("%v", se)
		}
		e.saveCreds(p.name, map[string]any{"provider": p.name, "api_key": "k"})
		if line(p.name) != p.name+": key saved (not verified)" || RequireLogin(e.home, []Role{{Provider: p.name}}) != nil {
			t.Fatalf("%s", line(p.name))
		}
		unusable := map[string]map[string]any{
			"wrong provider": {"provider": "chatgpt", "api_key": "k"}, "no key": {"provider": p.name}, "empty key": {"provider": p.name, "api_key": ""},
			"control": {"provider": p.name, "api_key": "a\tb"}, "number": {"provider": p.name, "api_key": 3},
		}
		for name, creds := range unusable {
			e.saveCreds(p.name, creds)
			want := p.name + ": saved login cannot be used; run kogen provider login " + p.name
			if p.name == "anthropic" {
				want = "anthropic: not signed in"
			}
			if line(p.name) != want || mustErr(t, RequireLogin(e.home, []Role{{Provider: p.name}})).Detail != hint {
				t.Errorf("%s: %q", name, line(p.name))
			}
		}
		os.WriteFile(e.credPath(p.name), []byte("malformed"), 0o600)
		want := p.name + ": saved login cannot be used; run kogen provider login " + p.name
		if p.name == "anthropic" {
			want = "anthropic: not signed in"
		}
		if line(p.name) != want {
			t.Errorf("malformed: %q", line(p.name))
		}
	}
	// A blank Anthropic key is no key; OpenCode Go has no such rule beyond its character check.
	e.saveCreds("anthropic", map[string]any{"provider": "anthropic", "api_key": "   "})
	if line("anthropic") != "anthropic: not signed in" {
		t.Fatal(line("anthropic"))
	}
	e.saveCreds("opencode-go", map[string]any{"provider": "opencode-go", "api_key": "   "})
	if line("opencode-go") != "opencode-go: key saved (not verified)" {
		t.Fatal(line("opencode-go"))
	}
	// Only the providers the roles use are required.
	e2 := newEnv(t, nil)
	if err := RequireLogin(e2.home, []Role{{Provider: "opencode-go"}, {Provider: "anthropic"}}); mustErr(t, err).Detail != "no usable OpenCode Go key; run kogen provider login opencode-go" {
		t.Fatal(err)
	}
}

func TestStatusIsFourLinesInCatalogOrder(t *testing.T) {
	e := newEnv(t, nil)
	got := Status(e.home)
	want := []string{"chatgpt: not signed in", "supergrok: not signed in", "opencode-go: not signed in", "anthropic: not signed in"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%q", got)
	}
}

func TestLoginRefusesNonLoopbackSeamForKeyProvidersToo(t *testing.T) {
	for _, p := range keyProviders {
		e := newEnv(t, nil)
		e.s = sys.NewWith([]string{"HOME=" + e.home, "KOGEN_PROVIDER_URL=https://example.com"}, e.home)
		err := e.loginWith(p.name, piped("k\n"))
		if se := mustErr(t, err); se.Reason != "invalid_test_seam" {
			t.Fatalf("%v", se)
		}
	}
}
