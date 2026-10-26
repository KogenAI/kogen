import unittest

from calc import add, is_even

class TestCalc(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)

    def test_is_even(self):
        self.assertTrue(is_even(4))

if __name__ == "__main__":
    unittest.main()
