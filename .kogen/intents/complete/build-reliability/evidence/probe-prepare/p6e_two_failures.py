#!/usr/bin/env python3
import sys, json
from sys import stderr
sys.path.insert(0, "/private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/4b512dac-a2b0-40ed-9bd1-89b099e1f0c6/scratchpad/probe/prepare/kogen/test/support/shaping_evaluation")
import importlib.util
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("driver_rehearsal_test",
    "/private/tmp/claude-501/-Users-almirsarajcic-Areas-Kogen-kogen/4b512dac-a2b0-40ed-9bd1-89b099e1f0c6/scratchpad/probe/prepare/kogen/test/support/shaping_evaluation/driver_rehearsal_test.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

class TwoFailureTest(base.DriverRehearsalTest):
    def test_two_failing_cases_run_to_completion_and_manifest_is_attempted(self):
        launches, polls, reaped, signals = [], [], [], []
        cases = self.driver.CASES
        FAILING = {"booking-flawed", "stateful-complete"}

        def parser(argv, **kwargs):
            class Result:
                returncode = 0
                stdout = base.fake_parser_stdout(kwargs["input"])
                stderr = ""
            return Result()

        def popen(argv, **kwargs):
            case = argv[-1]
            launches.append((case, kwargs))
            class SuiteChild(base.Child):
                def poll(self):
                    if self.returncode is not None:
                        return self.returncode
                    polls.append(case)
                    if case in FAILING:
                        kwargs["stdout"].write(f"fixture child failed after native startup ({case})\n")
                        kwargs["stdout"].flush()
                        self.returncode = 7
                    else:
                        self.returncode = 0
                    return self.returncode
            return SuiteChild()

        def reap(fixture, _before):
            reaped.append(fixture.name)
            return {"roots": [], "before": [], "actions": [], "remaining_pids": [], "all_reaped": True}

        manifest_calls = []
        def fake_write_manifest():
            manifest_calls.append(True)
            return {"offline": True}

        with patch.object(self.driver.subprocess, "run", parser), \
             patch.object(self.driver.subprocess, "Popen", popen), \
             patch.object(self.driver, "setup_continuation_seed", lambda: self.runtime / "continuation-seed"), \
             patch.object(self.driver, "write_semantic_counterexamples", lambda: (self.runtime / "semantic-counterexamples.json").write_text("{}\n")), \
             patch.object(self.driver, "required_case_capture", lambda _case: None), \
             patch.object(self.driver, "owned_process_tree", lambda _fixture: []), \
             patch.object(self.driver, "reap_owned_cli", reap), \
             patch.object(self.driver, "write_manifest", fake_write_manifest), \
             patch.object(self.driver.os, "killpg", lambda pid, sig: signals.append((pid, sig))):
            result = self.driver.run_suite()

        print("run_suite exit code:", result, file=stderr)
        print("all cases launched:", set(cases) == {c for c, _ in launches}, file=stderr)
        print("all cases polled to completion (no early stop):", set(cases) == set(polls), file=stderr)
        print("no cancellation signals sent (nothing timed out):", signals == [], file=stderr)
        print("write_manifest was attempted on failure:", manifest_calls == [True], file=stderr)
        failure = json.loads((self.runtime / "suite-failure.json").read_text())
        print("failure record:", json.dumps(failure, indent=2), file=stderr)
        self.assertEqual(1, result)
        self.assertEqual(set(cases), {c for c, _ in launches})
        self.assertEqual(set(cases), set(polls))
        self.assertEqual(FAILING, set(failure["failed_cases"].keys()))
        self.assertEqual([], signals)
        self.assertEqual([True], manifest_calls)
        stdout_text = self.output.getvalue()
        for case in FAILING:
            self.assertIn(f"FAILED: {case}", stdout_text)
        print("stdout FAILED lines:", file=stderr)
        for line in stdout_text.splitlines():
            if line.startswith("FAILED"):
                print(" ", line, file=stderr)

if __name__ == "__main__":
    unittest.main()
