"""Tests for the shared repo-counter window predicate."""
import datetime
import unittest

from analysis.window import in_window


class TestInWindow(unittest.TestCase):
    def test_in_window_true(self) -> None:
        self.assertTrue(in_window("2026-06-19T10:00:00Z", datetime.date(2026, 1, 1)))

    def test_out_of_window_false(self) -> None:
        self.assertFalse(in_window("2020-01-01T00:00:00Z", datetime.date(2026, 1, 1)))

    def test_none_is_false(self) -> None:
        self.assertFalse(in_window(None, datetime.date(2026, 1, 1)))

    def test_empty_string_is_false(self) -> None:
        self.assertFalse(in_window("", datetime.date(2026, 1, 1)))

    def test_unparseable_string_is_false(self) -> None:
        self.assertFalse(in_window("not-a-date", datetime.date(2026, 1, 1)))

    def test_boundary_date_equal_since_is_true(self) -> None:
        self.assertTrue(in_window("2026-01-01T00:00:00Z", datetime.date(2026, 1, 1)))

    def test_date_before_since_is_false(self) -> None:
        self.assertFalse(in_window("2025-12-31T23:59:59Z", datetime.date(2026, 1, 1)))


if __name__ == "__main__":
    unittest.main()
