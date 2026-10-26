def add(a, b):
    return a + b

def is_even(n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("n must be an integer")
    return n % 2 == 0
