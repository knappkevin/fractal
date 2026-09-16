#!/usr/bin/env python3
"""Render the background-switcher marker for one catalogue point.

The marker is what the switcher shows and what gets *set* as the wallpaper, so it
should look like the frame the shader draws for that point at the same phase.
It reuses tools/perturb.c, the same CPU reference the catalogue gates points
with, so the two cannot drift apart.

usage: marker.py <points/name.json> <phase> <out.png> [colour ...]
env:   MBSIZE_W / MBSIZE_H   render size, default 1920x1080
"""
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PERTURB = os.path.join(HERE, "perturb")

THEME_COLORS = os.path.expanduser("~/.local/state/omarchy/current/theme/colors.toml")


def luminance(spec):
    r, g, b = rgb(spec)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def live_ramp():
    """The four roles ThemeColors picks, in the order it puts them in.

    Read from the theme rather than baked in: a baked copy goes stale on the
    next theme switch, and the thumbnail then shows colours the wallpaper does
    not have. Callers may still pass colours explicitly to override.
    """
    vals = {}
    try:
        for line in open(THEME_COLORS):
            m = re.match(r"\s*([A-Za-z0-9_]+)\s*=\s*[\"']?(#[0-9A-Fa-f]{6,8})", line)
            if m:
                vals[m.group(1)] = m.group(2)[:7]
    except OSError:
        pass

    def pick(names, fallback):
        for n in names:
            if n in vals:
                return vals[n]
        return fallback

    background = pick(["background", "color0"], "#060b1e")
    roles = [pick(["accent", "blue", "color4", "color12"], "#7d82d9"),
             pick(["selection", "dark_background", "color8", "color0"], "#252e56"),
             background,
             pick(["foreground", "bright_foreground", "color15", "color7"], "#ffcead")]
    # Same order as ThemeColors: nearest the background first, so the far field
    # lands on the background on a light theme as well as a dark one.
    base = luminance(background)
    return sorted(roles, key=lambda h: abs(luminance(h) - base))

W = int(os.environ.get("MBSIZE_W", 1920))
H = int(os.environ.get("MBSIZE_H", 1080))
FULL_HW = 2.5

PAL = []


def rgb(spec):
    spec = spec.strip()
    return tuple(int(spec[i:i + 2], 16) / 255 for i in (1, 3, 5))


def smoothstep(x):
    return x * x * (3 - 2 * x)


def palette(t):
    """The shader's palette(): a cyclic four stop ramp over fract(t)."""
    x = (t - math.floor(t)) * 4.0
    if x >= 3.0:
        a, b, x = PAL[3], PAL[0], x - 3.0
    elif x >= 2.0:
        a, b, x = PAL[2], PAL[3], x - 2.0
    elif x >= 1.0:
        a, b, x = PAL[1], PAL[2], x - 1.0
    else:
        a, b = PAL[0], PAL[1]
    m = smoothstep(x)
    return tuple(a[i] + (b[i] - a[i]) * m for i in range(3))


def main():
    global PAL
    point_path, phase, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    PAL = [rgb(c) for c in (sys.argv[4:8] or live_ramp())]
    pt = json.load(open(point_path))

    if not os.path.exists(PERTURB):
        # gcc locates cc1, as and ld by searching PATH. The shell hands this
        # script a cleared environment with HOME and nothing else, so without
        # this it dies with "cannot execute 'cc1'" and the render falls back to
        # the shipped still -- a picture of another theme.
        env = dict(os.environ)
        env["PATH"] = env.get("PATH") or "/usr/bin:/bin"
        subprocess.run(["gcc", "-O2", "-fopenmp", "-o", PERTURB,
                        os.path.join(HERE, "perturb.c"),
                        "-lquadmath", "-lm"], check=True, env=env)

    # Unique names created O_EXCL, not fixed names under /tmp: a predictable path
    # in a shared directory is one another user can pre-create as a symlink and
    # have this write follow.
    fd, orb = tempfile.mkstemp(prefix="fractal-orbit.")
    with os.fdopen(fd, "w") as fh:
        for k, (re, im) in enumerate(pt["orbit"]):
            fh.write("%d %.34e %.34e\n" % (k, re, im))

    hw = pt["half_w0"] * 2.0 ** (-pt["oct_per_loop"] * phase)
    rot = pt["rot_per_loop"] * phase
    fd, field = tempfile.mkstemp(prefix="fractal-field.")
    os.close(fd)
    try:
        subprocess.run([PERTURB, orb, str(pt["q"]), str(pt["p"]), repr(hw), repr(rot),
                        str(pt["maxiter"]), str(W), str(H), field], check=True,
                       stderr=subprocess.DEVNULL)
        with open(field, "rb") as fh:
            raw = fh.read()
    finally:
        os.remove(field)
        os.remove(orb)

    vals = struct.unpack("<%df" % (len(raw) // 4), raw)

    # The palette runs through a lookup table rather than a function call per
    # pixel. Evaluating the ramp two million times cost about five seconds, which
    # was the entire reason the thumbnail took seconds to appear; the table
    # resolves the same ramp to a thousandth of a cycle, well under one step of
    # the eight bit output.
    lut_bits = 10
    lut_n = 1 << lut_bits
    lut = [bytes((int(c[0] * 255), int(c[1] * 255), int(c[2] * 255)))
           for c in (palette(i / lut_n) for i in range(lut_n))]

    # Same expression as the shader: the palette is anchored to the frame's own
    # floor, not to zero, and the drift is the period.
    scale = pt["pal_scale"]
    base = pt["pal_offset"] + pt["p"] * phase
    mask = lut_n - 1

    px = bytearray()
    for v in vals:
        if v < 0:
            px += b"\x00\x00\x00"
        else:
            px += lut[int(((scale * (v - base)) % 1.0) * lut_n) & mask]

    # Written beside the destination and renamed into place. Writing the
    # destination directly leaves a truncated image visible for the length of the
    # encode, and the background picker scans that directory: it cached a
    # half-written file and showed that instead of the real one. A rename is
    # atomic, so a reader sees either the previous image or the new one.
    #
    # The temporary keeps the .part suffix so the picker's *.png scan cannot
    # match it.
    tmp = out + ".part"
    try:
        with open(tmp, "wb") as fh:
            fh.write(png(halve(px, W, H), W // 2, H // 2))
        os.replace(tmp, out)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    print("wrote %s from %s at phase %.2f (%dx%d)" % (out, pt["name"], phase, W // 2, H // 2))


def halve(px, w, h):
    """Flip vertically and halve both axes.

    The renderer counts rows from the top and the shader counts them from the
    bottom, so matching the shader means reversing the rows. Halving is a 2x2
    box average, the exact filter for a factor of two: every input pixel is read
    once and it cannot ring.

    Worked a channel at a time over the whole frame rather than per pixel. The
    arithmetic is the same, but a plain per-pixel loop over half a million
    pixels costs about two seconds in Python, which is most of the time this
    script spends.
    """
    out_w, out_h = w // 2, h // 2
    stride = w * 3

    row = lambda i: i * stride
    flipped = b"".join(px[row(i):row(i + 1)] for i in range(h - 1, -1, -1))
    top = b"".join(flipped[row(i):row(i + 1)] for i in range(0, h, 2))
    bottom = b"".join(flipped[row(i):row(i + 1)] for i in range(1, h, 2))

    image = bytearray(out_w * out_h * 3)
    for channel in range(3):
        plane = top[channel::3]
        under = bottom[channel::3]
        image[channel::3] = bytes(
            (a + b + c + d) >> 2
            for a, b, c, d in zip(plane[0::2], plane[1::2], under[0::2], under[1::2]))

    rows = bytearray()
    for y in range(out_h):
        rows.append(0)  # PNG filter type for this scanline: none
        rows += image[y * out_w * 3:(y + 1) * out_w * 3]
    return rows


def png(rows, width, height):
    """An 8 bit RGB PNG.

    A PNG is a signature, three chunks, and zlib; all of that is in the standard
    library, so the plugin needs no image tool installed to write its own
    background-picker image. `rows` is the raw scanline stream, each line
    prefixed with its filter type.
    """
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
            + chunk(b"IEND", b""))


main()
