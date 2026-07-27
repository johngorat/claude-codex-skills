"""Minipack entrypoint: local + package imports, declared env and file read."""
import json
import os

import helper
import pkg.util


def main():
    lut = json.load(open(os.path.join(os.path.dirname(__file__), "..", "data", "lut.json"),
                         encoding="utf-8"))
    mode = os.environ.get("MINI_ENV")
    return pkg.util.clamp(helper.derive(lut, mode))


if __name__ == "__main__":
    main()
