#!/usr/bin/env python3
"""Render the background-switcher marker for one catalogue point.

The marker is what the switcher shows and what gets *set* as the wallpaper, so it
should look like the frame the shader draws for that point at the same phase.
It runs tools/perturb, the same CPU reference the catalogue gates points with,
so the two cannot drift apart, and tools/palette turns that renderer's escape
counts into this image's scanlines. Both ship built, by tools/build.sh.

usage: marker.py <points/name.json> <phase> <out.png> [colour ...]
env:   MBSIZE_W / MBSIZE_H   render size, default 1920x1080
"""
import json
import math
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PERTURB = os.path.join(HERE, "perturb")
PALETTE = os.path.join(HERE, "palette")

# The ramp is resolved to this many steps before the helper sees it.
LUT_N = 1 << 10

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


def sweep(keep):
    """Remove work directories left by runs that were killed outright.

    A reload takes the render down with SIGTERM, which the handler below turns
    into a clean exit; this covers the rest, a SIGKILL or a crash, where nothing
    gets to run at all. Only directories old enough that no render can still be
    using them.
    """
    tmpdir = tempfile.gettempdir()
    cutoff = time.time() - 6 * 3600
    try:
        names = os.listdir(tmpdir)
    except OSError:
        return
    for name in names:
        if not name.startswith("fractal-") or name == os.path.basename(keep):
            continue
        path = os.path.join(tmpdir, name)
        try:
            if os.path.isdir(path) and os.path.getmtime(path) < cutoff:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


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


def lut_bytes():
    """The same ramp, resolved to LUT_N entries of eight bit RGB.

    Resolved here rather than in the helper, so the palette, the smoothstep and
    the colours of the moment stay in one place and the table cannot drift from
    what the shader draws.
    """
    return b"".join(bytes((int(c[0] * 255), int(c[1] * 255), int(c[2] * 255)))
                    for c in (palette(i / LUT_N) for i in range(LUT_N)))


def main():
    global PAL
    point_path, phase, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    PAL = [rgb(c) for c in (sys.argv[4:8] or live_ramp())]
    pt = json.load(open(point_path))

    # The helpers are shipped built, by tools/build.sh, and recorded in
    # tools/SHA256SUMS. Nothing is compiled here: a binary built at render time
    # would be one the repository does not contain, executed from a directory
    # anything running as this user can write to.
    hw = pt["half_w0"] * 2.0 ** (-pt["oct_per_loop"] * phase)
    rot = pt["rot_per_loop"] * phase

    # Same expression as the shader: the palette is anchored to the frame's own
    # floor, not to zero, and the drift is the period.
    scale = pt["pal_scale"]
    base = pt["pal_offset"] + pt["p"] * phase

    # One private directory for the whole run, created exclusively and 0700. A
    # shared directory would let another user pre-create any of these names as a
    # symlink and have a write follow it, and one directory is a single thing to
    # sweep where four loose files were four.
    work = tempfile.mkdtemp(prefix="fractal-")
    sweep(work)
    orb = os.path.join(work, "orbit.txt")
    field = os.path.join(work, "field.bin")
    lutfile = os.path.join(work, "lut.bin")
    rowsfile = os.path.join(work, "rows.bin")

    # A plugin reload ends the render with SIGTERM, which by default stops the
    # interpreter without running the finally below, leaving the work directory
    # behind -- about 10MB for every interrupted render. Take the signal, clean
    # up, then die the way we would have anyway.
    #
    # Everything this run makes and has not yet cleaned up goes in here, because
    # this handler is the only code that runs when a reload kills the render,
    # and the output temp below is created long after the work directory is.
    scratch = [work]

    def on_terminate(signum, _frame):
        for path in scratch:
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                try:
                    os.remove(path)
                except OSError:
                    pass
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    signal.signal(signal.SIGTERM, on_terminate)
    signal.signal(signal.SIGINT, on_terminate)
    try:
        with open(orb, "w") as fh:
            for k, (re, im) in enumerate(pt["orbit"]):
                fh.write("%d %.34e %.34e\n" % (k, re, im))
        with open(lutfile, "wb") as fh:
            fh.write(lut_bytes())
        subprocess.run([PERTURB, orb, str(pt["q"]), str(pt["p"]), repr(hw), repr(rot),
                        str(pt["maxiter"]), str(W), str(H), field], check=True,
                       stderr=subprocess.DEVNULL)
        # Resolving the ramp, flipping the frame and averaging it down are a pass
        # over two million values, which is where the time went. The helper does
        # the whole pass in C and hands back finished PNG scanlines.
        subprocess.run([PALETTE, field, lutfile, str(W), str(H), repr(scale),
                        repr(base), rowsfile], check=True)
        with open(rowsfile, "rb") as fh:
            rows = fh.read()
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # Written to an unpredictable name in the destination's own directory, then
    # renamed into place -- the same idiom the other plugins use for their state
    # files. Writing the destination directly leaves a truncated image visible
    # for the length of the encode, and the background picker scans that
    # directory: it cached a half-written file and showed that instead of the
    # real one. A rename is atomic, so a reader sees either the previous image
    # or the new one, and rename replaces the destination entry itself rather
    # than following a symlink planted there.
    #
    # A fixed temporary name would let anything running as this user pre-create
    # it as a symlink and have the encode follow it; mkstemp creates the file
    # exclusively instead. The leading dot and the .tmp suffix keep the picker's
    # *.png scan from matching it.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out),
                               prefix="." + os.path.basename(out) + ".",
                               suffix=".tmp")
    scratch.append(tmp)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(png(rows, W // 2, H // 2))
        os.replace(tmp, out)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    print("wrote %s from %s at phase %.2f (%dx%d)" % (out, pt["name"], phase, W // 2, H // 2))


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
