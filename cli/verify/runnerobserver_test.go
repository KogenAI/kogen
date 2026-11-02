package verify

import "testing"

func TestRunnerObserver(t *testing.T) {
	const (
		pass    = "1 runs, 7 assertions, 0 failures, 0 errors, 0 skips"
		passTst = "1 tests, 7 assertions, 0 failures, 0 errors, 0 skips"
		zero    = "0 runs, 0 assertions, 0 failures, 0 errors, 0 skips"
		passed  = "the step failed although the test runner reported a passing run: "
		literal = "is a regular expression that the runner matched as a literal test name, so nothing ran: "
	)
	for _, c := range []struct{ name, msg, want string }{
		{"runs wording", "Required test; exit 0\nRun options: -n test_a --seed 1\n\nFinished in 0.01s.\n" + pass + "\n", passed + pass},
		{"tests wording", "exit 0\n" + passTst + "\n", passed + passTst},
		{"last summary wins", "exit 0\n3 runs, 1 assertions, 1 failures, 0 errors, 0 skips\n" + pass, passed + pass},
		{"last summary wins with a failure", pass + "\n2 runs, 1 assertions, 1 failures, 0 errors, 0 skips", ""},
		{"line-anchored summary", "x\n" + pass + "\n", passed + pass},
		{"failure", "1 runs, 7 assertions, 1 failures, 0 errors, 0 skips", ""},
		{"error", "1 runs, 7 assertions, 0 failures, 1 errors, 0 skips", ""},
		{"skip", "1 runs, 7 assertions, 0 failures, 0 errors, 1 skips", ""},
		{"no summary", "Error: command failed", ""},
		{"anchored -i, quoted", "Run options: -i \"^test_a$\" --seed 4242\n" + zero, "the name filter -i ^test_a$ " + literal + zero},
		{"anchored -n, quoted", "Run options: -n \"^test_a$\" --seed 4242\n" + zero, "the name filter -n ^test_a$ " + literal + zero},
		{"anchored -n, bare start", "Run options: -n ^test_a --seed 1\n" + zero, "the name filter -n ^test_a " + literal + zero},
		{"anchored --name=, bare end", "Run options: --name=test_a$ --seed 1\n" + zero, "the name filter --name test_a$ " + literal + zero},
		{"anchored --include", "Run options: --include \"^test_a$\"\n" + zero, "the name filter --include ^test_a$ " + literal + zero},
		{"first anchored filter wins", "Run options: -n test_plain -i \"^b$\" -n \"c$\"\n" + zero, "the name filter -i ^b$ " + literal + zero},
		{"plain name", "Run options: -n test_a --seed 1\n" + zero, ""},
		{"slash regular expression", "Run options: -n \"/^test_a$/\" --seed 1\n" + zero, ""},
		{"lone slash is a plain name", "Run options: -n / --seed 1\n" + zero, ""},
		{"filter outside the run options line", "bin/rails test -n ^test_a$\n" + zero, ""},
		{"option glued to another word", "Run options: --foo-n ^a$\n" + zero, ""},
	} {
		if got := runnerObserver(c.msg); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
