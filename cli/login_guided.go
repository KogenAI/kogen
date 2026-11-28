package main

import (
	"bufio"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
)

// The guided login: `kogen provider login` with no provider on an interactive terminal. It
// asks which account to use and then runs an existing login, or, for QwenCloud, collects the
// key and shows the lineup it would write before anything is saved. No network call is made.

const (
	accountQuestion  = "Which account do you want to use?"
	qwenExperimental = "experimental: Build verified with Claude Review; Shape and Review not qualified"
	qwenModel        = "qwen4-max"
	qwenEffort       = "high"
	qwenWarning      = "Warning: the Token Plan's terms restrict automation and non-interactive batch use; pay-as-you-go suits unattended loops."
	confirmPrompt    = "Save this login and lineup? [y/N]"
	connectionOffer  = "Run a connection test now? [y/N]"
)

// accountChoices are the answers to the account question, in the order they are listed.
var accountChoices = []string{"ChatGPT", "Claude subscription", "Anthropic API key", "SuperGrok", "OpenCode Go", "QwenCloud", "Advanced setup"}

// accountProviders maps the choices that run an existing login to the provider it signs in.
var accountProviders = map[string]string{
	"ChatGPT":             "chatgpt",
	"Claude subscription": "claude-code",
	"Anthropic API key":   "anthropic",
	"SuperGrok":           "supergrok",
	"OpenCode Go":         "opencode-go",
}

// qwenPlans are the QwenCloud plan choices and the base URL each one uses.
var qwenPlans = []struct{ label, baseURL string }{
	{"Token Plan", "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1"},
	{"Pay-as-you-go (Singapore)", "https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1"},
}

const chatCompletions = "Chat Completions (openai-compatible)"

// endpointChoices are the custom endpoint kinds Advanced setup offers: Messages is offered only
// once `kogen provider login messages-compatible` exists.
func endpointChoices() []string {
	choices := []string{chatCompletions}
	if contains(loginProviders, "messages-compatible") {
		choices = append(choices, "Messages (messages-compatible)")
	}
	return choices
}

// loginGuided asks the account question and runs the chosen login. in is the terminal input.
func loginGuided(s *sys.Session, client *provider.Client, in provider.Input) error {
	lines := bufio.NewReader(in.Reader)
	in.Reader = lines
	choice, err := ask(s, lines, accountQuestion, accountChoices)
	if err != nil {
		return err
	}
	switch choice {
	case "QwenCloud":
		return loginQwenCloud(s, client, in, lines)
	case "Advanced setup":
		return loginAdvanced(s, client, in, lines)
	case "Anthropic API key", "OpenCode Go":
		// Their existing login reads the key from the terminal with echo off.
		s.Puts("API key:")
		client.Input = &in
	}
	return login(s, client, accountProviders[choice])
}

// ask lists the choices as `<number>) <label>` and returns the label of the one the user types
// by number or label. Anything else refuses; the question is asked once.
func ask(s *sys.Session, lines *bufio.Reader, question string, choices []string) (string, error) {
	s.Puts(question)
	for i, c := range choices {
		s.Puts(strconv.Itoa(i+1) + ") " + c)
	}
	s.Out("Choose a number or a name: ")
	answer, err := readLine(s, lines, "Choice input")
	if err != nil {
		return "", err
	}
	answer = strings.TrimSpace(answer)
	if n, err := strconv.Atoi(answer); err == nil && n >= 1 && n <= len(choices) {
		return choices[n-1], nil
	}
	for _, c := range choices {
		if answer != "" && strings.EqualFold(answer, c) {
			return c, nil
		}
	}
	return "", sys.Fail("provider", "login_failed", "'"+answer+"' is not one of the choices; nothing saved", 2)
}

func loginAdvanced(s *sys.Session, client *provider.Client, in provider.Input, lines *bufio.Reader) error {
	if _, err := ask(s, lines, "Which kind of custom endpoint?", endpointChoices()); err != nil {
		return err
	}
	client.Input = &in
	return loginCompatible(s, client)
}

// loginQwenCloud asks for the plan and the key, shows the lineup it would write and saves the
// login and the build role only after `y`. The key stays in memory until then.
func loginQwenCloud(s *sys.Session, client *provider.Client, in provider.Input, lines *bufio.Reader) error {
	s.Puts("QwenCloud (" + qwenExperimental + ")")
	plan, err := ask(s, lines, "Token Plan or pay-as-you-go?", []string{qwenPlans[0].label, qwenPlans[1].label})
	if err != nil {
		return err
	}
	baseURL := qwenPlans[1].baseURL
	if plan == qwenPlans[0].label {
		baseURL = qwenPlans[0].baseURL
		s.Puts(qwenWarning)
	}
	// Read the lineup file before asking for the key, so a file that cannot be updated stops here.
	modelsPath := filepath.Join(".kogen", "models.yaml")
	current, err := os.ReadFile(modelsPath)
	if err != nil && !os.IsNotExist(err) {
		return sys.Fail("environment", "login_failed", modelsPath+": unreadable; nothing saved", 3)
	}
	updated, err := withBuildRole(string(current), baseURL)
	if err != nil {
		return sys.Fail("environment", "login_failed", modelsPath+": "+err.Error()+"; nothing saved", 3)
	}
	key, err := readSecretLine(s, in, lines)
	if err != nil {
		return err
	}
	if key == "" {
		return sys.Fail("provider", "login_failed", "no API key supplied; nothing saved", 4)
	}
	s.Puts("Lineup this would write to " + filepath.ToSlash(modelsPath) + ":")
	s.Puts("  build: provider openai-compatible, model " + qwenModel + ", effort " + qwenEffort + ", base URL " + baseURL)
	s.Puts("  shape and review: unchanged")
	s.Out(confirmPrompt + " ")
	answer, err := readLine(s, lines, "Confirmation input")
	if err != nil {
		return err
	}
	if strings.TrimSpace(answer) != "y" {
		s.Puts("Nothing saved.")
		return nil
	}
	client.Input = &provider.Input{Reader: strings.NewReader(key)}
	if err := client.LoginWithBaseURL(s.Context(), s, "openai-compatible", baseURL, nil); err != nil {
		return err
	}
	if err := writeFileAtomic(modelsPath, updated); err != nil {
		return sys.Fail("environment", "login_failed", modelsPath+": cannot write ("+err.Error()+"); the login was saved, the lineup was not", 3)
	}
	s.Puts("Saved the build role in " + filepath.ToSlash(modelsPath))
	return offerConnectionTest(s, lines, baseURL)
}

// offerConnectionTest asks whether to run the connection test now (default no; only `y` runs
// it, so end of input means no), then prints the three states of the build role. The test is the
// opt-in `kogen provider test` request and nothing else ever starts it from a login.
func offerConnectionTest(s *sys.Session, lines *bufio.Reader, baseURL string) error {
	role := project.Role{Provider: testableProvider, Model: qwenModel, Effort: qwenEffort, BaseURL: baseURL}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	s.Out(connectionOffer + " ")
	answer, err := readLine(s, lines, "Connection test input")
	if err != nil {
		return err
	}
	if strings.TrimSpace(answer) == "y" {
		res, err := connectionTester(s.Context(), home, role)
		switch {
		case err != nil && s.Err() != nil:
			return s.Err()
		case err != nil:
			if e, ok := sys.AsError(err); ok {
				s.Out(e.Render())
			} else {
				s.Puts(testableProvider + ": connection test failed, class: " + classEndpoint + " (" + strings.SplitN(err.Error(), "\n", 2)[0] + ")")
			}
		default:
			s.Puts(res.line(testableProvider))
		}
	}
	status := provider.Status(home)
	root, _ := installRoot()
	s.Puts(roleStatesLine(home, shippedDocs(root), "build", role, loginSaved(status, testableProvider)))
	return nil
}

// readSecretLine prompts `API key:` and reads one line with the terminal echo off, restoring
// the terminal on every path out. The key is returned trimmed and is never printed.
func readSecretLine(s *sys.Session, in provider.Input, lines *bufio.Reader) (string, error) {
	if in.Terminal {
		stty := in.Stty
		if stty == nil {
			stty = provider.StdinInput().Stty
		}
		state, err := stty("-g")
		if err != nil {
			return "", sys.Fail("provider", "login_failed", "cannot turn off the terminal echo for the key; nothing saved", 4)
		}
		defer stty(strings.TrimSpace(state))
		if _, err := stty("-echo"); err != nil {
			return "", sys.Fail("provider", "login_failed", "cannot turn off the terminal echo for the key; nothing saved", 4)
		}
	}
	s.Puts("API key:")
	line, err := readLine(s, lines, "API key input")
	return strings.TrimSpace(line), err
}

// withBuildRole returns the lineup file text with its build role set to the QwenCloud role at
// baseURL; every other line, the shape and review roles included, stays as it is.
func withBuildRole(text, baseURL string) (string, error) {
	lines := strings.Split(text, "\n")
	if text == "" {
		lines = nil
	} else if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	indentOf := func(l string) int { return len(l) - len(strings.TrimLeft(l, " ")) }
	blank := func(l string) bool {
		t := strings.TrimSpace(l)
		return t == "" || strings.HasPrefix(t, "#")
	}
	models := -1
	for i, l := range lines {
		if indentOf(l) == 0 && strings.HasPrefix(l, "models:") {
			if rest := strings.TrimSpace(strings.TrimPrefix(l, "models:")); rest != "" && !strings.HasPrefix(rest, "#") {
				return "", errUnsupportedLineup
			}
			models = i
			break
		}
	}
	if models < 0 {
		if strings.TrimSpace(text) != "" {
			return "", errUnsupportedLineup
		}
		lines = append(lines, "models:")
		models = len(lines) - 1
	}
	// The models block ends at the next line with no indentation.
	end := len(lines)
	for i := models + 1; i < len(lines); i++ {
		if !blank(lines[i]) && indentOf(lines[i]) == 0 {
			end = i
			break
		}
	}
	child := 2
	for i := models + 1; i < end; i++ {
		if !blank(lines[i]) {
			child = indentOf(lines[i])
			break
		}
	}
	pad := strings.Repeat(" ", child)
	block := []string{
		pad + "build:",
		pad + "  provider: openai-compatible",
		pad + "  model: " + qwenModel,
		pad + "  effort: " + qwenEffort,
		pad + "  base_url: " + baseURL,
	}
	from, to := -1, -1
	for i := models + 1; i < end; i++ {
		if indentOf(lines[i]) == child && strings.HasPrefix(strings.TrimSpace(lines[i]), "build:") {
			from, to = i, i+1
			for to < end && (blank(lines[to]) || indentOf(lines[to]) > child) {
				to++
			}
			// Blank and comment lines after the role belong to what follows it.
			for to > from+1 && blank(lines[to-1]) {
				to--
			}
			break
		}
	}
	if from < 0 {
		from, to = end, end
		for from > models+1 && blank(lines[from-1]) {
			from--
		}
		to = from
	}
	out := append(append(append([]string{}, lines[:from]...), block...), lines[to:]...)
	return strings.Join(out, "\n") + "\n", nil
}

var errUnsupportedLineup = errors.New("is not a models: block of roles; update the build role by hand")

// writeFileAtomic replaces the file in one rename, keeping its mode when it exists.
func writeFileAtomic(path, text string) error {
	mode := os.FileMode(0o644)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".models-*.yaml")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
