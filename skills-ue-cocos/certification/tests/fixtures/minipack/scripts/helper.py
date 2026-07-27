"""Minipack helper — reached only through the transitive import walk."""
from pkg import util


def derive(lut, mode):
    scale = lut.get("scale", 1) if mode != "raw" else 1
    return util.clamp(scale * lut.get("bias", 0))
