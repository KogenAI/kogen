#!/usr/bin/env python3
"""Positive and missing-value/evidence controls for the offline evidence consumer."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("value_evidence", HERE / "value_evidence.py")
consumer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(consumer)


class ValueEvidenceTest(unittest.TestCase):
    def test_real_offline_fixture_output_resumes_only_from_materialized_source_citation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "evidence").mkdir()
            makefile = ("check:\n"
                        "\t@test -f dummy.txt || (echo \"dummy.txt is missing. Required exact content: shape2build-k4q9z\" && exit 1)\n"
                        "\t@grep -qx shape2build-k4q9z dummy.txt || (echo \"dummy.txt content is wrong. Required exact content: shape2build-k4q9z\" && exit 1)\n")
            (root / "Makefile").write_text(makefile)
            check = subprocess.run(["make", "check"], cwd=root, capture_output=True, text=True)
            self.assertNotEqual(0, check.returncode)
            output = check.stdout + check.stderr
            citation = {"path": "Makefile", "line": 2,
                        "excerpt": (root / "Makefile").read_text().splitlines()[1]}
            resume = "The verification failed: " + output
            value = consumer.consume_check_value(output, resume, [citation], root)
            self.assertEqual("shape2build-k4q9z", value)

            with self.assertRaisesRegex(ValueError, "does not carry"):
                consumer.consume_check_value("dummy.txt is missing", resume, [citation], root)
            with self.assertRaisesRegex(ValueError, "resume text"):
                consumer.consume_check_value(output, "The verification failed", [citation], root)
            with self.assertRaisesRegex(ValueError, "materialized source"):
                consumer.consume_check_value(output, resume, [{**citation, "path": "evidence/absent.md"}], root)
            with self.assertRaisesRegex(ValueError, "do not prove"):
                consumer.consume_check_value(output, resume, [
                    {"path": "Makefile", "line": 1, "excerpt": "check:"}], root)


if __name__ == "__main__":
    unittest.main()
