"""Minipack submodule — reached via both `import pkg.util` and `from pkg import util`."""


def clamp(x):
    return max(0.0, min(1.0, x))
