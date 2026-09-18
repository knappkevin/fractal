#!/usr/bin/env python3
"""Gate Misiurewicz points for the zoom plugin and record how deep they start.

A point only makes a usable wallpaper if the renormalisation has settled by the
time the loop starts. If it has not, the frame at phase 0 and the frame at phase
1 are different pictures, the loop wraps with a visible jump, and no amount of
shader polish hides it. That is a property of the point and the starting depth,
and it is cheap to measure on the CPU:

  render the escape count at phase 0 and at phase 1 (same iteration budget),
  subtract pixel for pixel, and look at the spread of the difference. The two
  frames are the same picture up to the period, so a settled point gives a
  difference that is a single constant -- an interquartile range of 0.

This also measures the worst escape count across the loop, which is what the
shader's iteration budget has to cover. The budget is not a cost dial for this
renderer (a pixel that escapes stops, so anything past the median is free), but
it does have to be big enough or the deep filaments go black.

usage: catalogue.py [--only name] [--keep] [candidates.txt]
       catalogue.py --julia      measure the Julia rendering of every point
"""
import atexit
import glob
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PREFIX = os.path.join(HERE, "refine.py")
MKPOINT = os.path.join(HERE, "mkpoint.py")
PERTURB = os.path.join(HERE, "perturb")
PYPY = sys.executable

# One private directory for the whole run -- created exclusively and 0700 --
# rather than predictable names in a shared one, where anything running as this
# user could pre-create a name as a symlink and have a write follow it.
WORK = tempfile.mkdtemp(prefix="catalogue-")
atexit.register(shutil.rmtree, WORK, True)

GRID_W, GRID_H = 240, 136
MEASURE_BUDGET = 4000      # generous; only used to observe the point
# Starting depth, as -log2(half width), shallowest first. Deep is what looks
# right for a Misiurewicz point: these sit on hairs, so a wide window is mostly
# empty space with one thin tree across it, while a deep one is inside the hair's
# own structure, which fills the frame. Shallow was tried and rendered worse.
DEPTHS = [22, 26, 30, 34]
FULL_HW = 2.5              # half width of the whole-set view
SEAM_MAX_IQR = 0.5         # escape steps; far below one palette band
BANDS = 5                  # palette cycles across the deepest escape count
PHASES = (0.0, 0.25, 0.5, 0.75, 1.0)
MIN_SEPARATION = 0.02      # in the plane; closer than this is the same place


def require_perturb():
    """The store of truth for a candidate point is a CPU renderer, and the
    plugin ships it built.

    Refuse to act without it rather than compiling one into the source tree: a
    tool that manufactures a missing artifact is also a tool that will happily
    run whatever it finds in its place. tools/build.sh makes it, and
    tools/SHA256SUMS records what it should have produced.
    """
    if not os.path.exists(PERTURB):
        raise SystemExit("tools/perturb is missing; run tools/build.sh first")


def read_field(path):
    raw = open(path, "rb").read()
    return struct.unpack("<%df" % (len(raw) // 4), raw)


def field_for(orbit, q, p, half_w, rot, budget, tag, mode="mandel", degree=2):
    out = os.path.join(WORK, "catalogue_%s.bin" % tag)
    cmd = [PERTURB, orbit, str(q), str(p), repr(half_w), repr(rot),
           str(budget), str(GRID_W), str(GRID_H), out, mode, str(degree)]
    r = subprocess.run(cmd, stderr=subprocess.PIPE)
    if r.returncode != 0:
        return None, 0
    worst = 0.0
    for tok in r.stderr.decode().split():
        if tok.startswith("worst="):
            worst = float(tok.split("=")[1])
    return read_field(out), worst


def spread(a, b):
    """Median and interquartile range of a-b over pixels that escaped in both.

    The two frames are the same picture one renormalisation period apart, so a
    settled point gives a *constant* difference: IQR 0. The constant has to be
    the period as well, because that is what the shader subtracts from the
    escape count to keep the palette aligned across the wrap. A point that
    agreed in shape but drifted by something else would still tear.
    """
    d = sorted(x - y for x, y in zip(a, b) if x >= 0 and y >= 0)
    n = len(d)
    if n < 500:
        return None
    return d[n // 2], d[(3 * n) // 4] - d[n // 4]


def score(pt, tag, mode="mandel"):
    """Return ((drift, spread), worst, half_w), or a reason string if unusable.

    The drift one loop must produce is the period for the Mandelbrot rendering
    and twice it for the Julia one -- measured on all twelve points, not
    assumed -- and the reported drift is what the shader subtracts, so the
    palette lines up across the wrap for whichever it is.
    """
    c_re, c_im = pt["c_re"], pt["c_im"]
    q, p = pt["q"], pt["p"]
    degree = int(pt.get("power", 2))
    # One loop renormalises the picture; the escape count it gains is the period,
    # or the degree times the period for the Julia rendering, whose counts run
    # faster because the potential goes as log_degree. Measured, not assumed: the
    # twelve quadratic points gave 1x and 2x, and the multibrot points give their
    # own degree.
    want_drift = (degree if mode == "julia" else 1) * p
    orbit = os.path.join(WORK, "catalogue_%s.orb" % tag)
    with open(orbit, "w") as fh:
        for k, (re, im) in enumerate(pt["orbit"]):
            fh.write("%d %.34e %.34e\n" % (k, re, im))

    oct_loop = pt["oct_per_loop"]
    rot_loop = pt["rot_per_loop"]

    for depth in DEPTHS:
        hw0 = FULL_HW * 2.0 ** -depth
        hw1 = hw0 * 2.0 ** -oct_loop
        a, wa = field_for(orbit, q, p, hw0, 0.0, MEASURE_BUDGET, tag + "a", mode, degree)
        b, wb = field_for(orbit, q, p, hw1, rot_loop, MEASURE_BUDGET, tag + "b", mode, degree)
        if a is None or b is None:
            return "the reference renderer failed"
        got = spread(a, b)
        if got is None:
            return "too few pixels escape in both frames to judge"
        median, wide = got
        if wide > SEAM_MAX_IQR:
            continue
        if abs(median + want_drift) > 0.5:
            return ("settled in shape but the escape count drifts by %.2f, not"
                    " %s (-%d)"
                    % (median, "the period" if mode == "mandel"
                       else "twice the period", want_drift))
        worst = max(wa, wb)
        for ph in PHASES[1:-1]:
            hw = hw0 * 2.0 ** (-oct_loop * ph)
            f, w = field_for(orbit, q, p, hw, rot_loop * ph, MEASURE_BUDGET,
                             tag + "p%d" % int(ph * 100), mode, degree)
            if f is not None:
                worst = max(worst, w)
        # Anchor the palette to the frame rather than to zero. A deep zoom never
        # contains a pixel with a small escape count -- this view runs 31 to 178
        # -- so a palette indexed from zero starts partway up its own cycle and
        # the far field comes out mid-ramp instead of on the background.
        floor = min(x for x in a if x >= 0)
        # Where the visible structure sits. The maximum can belong to a handful of
        # pixels far deeper than anything on screen, and scaling the palette to
        # that stretches it over counts nothing occupies.
        esc = sorted(x for x in a if x >= 0)
        scale_ref = esc[min(len(esc) - 1, int(0.95 * len(esc)))]
        return (median, wide), worst, hw0, floor, scale_ref
    return ("the renormalisation has not settled by 2^-%d" % DEPTHS[-1])


def calibrate_julia():
    """Measure the Julia rendering of every point already in the catalogue.

    The main pass measures the Mandelbrot rendering. These are separate because
    the two have different escape ranges -- the Julia counts run about twice as
    high -- so a palette anchored on one puts the other in the wrong part of the
    ramp. The far field then comes out mid-ramp, which reads as a flood of the
    wrong colour rather than as anything being wrong.

    Nothing outside the `julia` block is touched, so every point keeps exactly
    the Mandelbrot constants it already had.
    """
    outdir = os.path.join(ROOT, "mandelbrot", "points")
    for path in sorted(glob.glob(os.path.join(outdir, "*.json"))):
        if path.endswith("index.json"):
            continue
        name = os.path.basename(path)[:-5]
        pt = json.load(open(path))
        got = score(pt, name + "-julia", "julia")
        if isinstance(got, str):
            print("%-12s julia rejected: %s" % (name, got))
            continue
        (drift, spread_steps), worst, _hw0, floor, scale_ref = got
        cycles = max(1, int((worst * 1.15 + 8 - pt["q"]) // pt["p"]) + 1)
        pt["julia"] = {
            # Escape steps the loop *gains*, which is what the shader subtracts as
            # uPhase advances -- the positive form of the measured median, which
            # spread() reports as a loss because it subtracts the later frame.
            "drift": -drift,
            "seam_spread": spread_steps,
            "worst_escape": worst,
            "maxiter": pt["q"] + cycles * pt["p"],
            "pal_scale": round(BANDS / max(1.0, scale_ref), 6),
            "pal_offset": round(floor, 3),
        }
        json.dump(pt, open(path, "w"), indent=2)
        print("%-12s julia: gains %.2f a loop, escape to %.0f (palette anchored at"
              " %.0f), %d steps" % (name, -drift, worst, floor,
                                    pt["julia"]["maxiter"]))


def main():
    args = [a for a in sys.argv[1:]]
    if "--julia" in args:
        require_perturb()
        calibrate_julia()
        return
    only = None
    if "--only" in args:
        i = args.index("--only")
        only = args[i + 1]
        del args[i:i + 2]
    cand_path = args[0] if args else os.path.join(HERE, "candidates.txt")

    require_perturb()
    outdir = os.path.join(ROOT, "mandelbrot", "points")
    os.makedirs(outdir, exist_ok=True)

    kept, rejected, skipped = [], [], []
    kept_xy = []
    for line in open(cand_path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        name, re, im, q, p = parts[:5]
        degree = int(parts[5]) if len(parts) > 5 else 2
        q, p = int(q), int(p)
        if only and name != only:
            continue

        # Two points in the same neighbourhood render the same picture with a
        # different spin, which reads as a bug in the catalogue rather than as a
        # choice. A weighted score did not catch this; a hard radius does.
        x, y = float(re), float(im)
        near = [(n, math.hypot(x - kx, y - ky)) for n, kx, ky in kept_xy
                if math.hypot(x - kx, y - ky) < MIN_SEPARATION]
        if near:
            print("%-12s skipped: %.5f from %s, the same neighbourhood"
                  % (name, near[0][1], near[0][0]))
            skipped.append(name)
            continue

        tmp = os.path.join(WORK, "catalogue_%s.ref" % name)
        r = subprocess.run([PYPY, PREFIX, re, im, str(q), str(p), str(degree)],
                           stdout=open(tmp, "w"), stderr=subprocess.PIPE)
        if r.returncode != 0:
            print("%-12s refine failed" % name)
            rejected.append(name)
            continue

        dst = os.path.join(outdir, name + ".json")
        subprocess.run([PYPY, MKPOINT, tmp, name, dst], check=True)

        pt = json.load(open(dst))
        got = score(pt, name)
        if isinstance(got, str):
            print("%-12s rejected: %s" % (name, got))
            os.remove(dst)
            rejected.append(name)
            continue

        (drift, spread_steps), worst, hw0, floor, scale_ref = got
        cycles = max(1, int((worst * 1.15 + 8 - pt["q"]) // pt["p"]) + 1)
        pt["maxiter"] = pt["q"] + cycles * pt["p"]
        pt["half_w0"] = hw0
        pt["seam_spread"] = spread_steps
        pt["seam_drift"] = drift
        pt["worst_escape"] = worst
        # Band frequency has to come from the point: escape counts run to 49 on
        # one point and 254 on another, so a fixed scale renders one as a flat
        # wash and the other as noise. Measured from the frame's maximum, which is
        # the convention every shipped point was tuned under -- a quantile is
        # 2-6x busier and would move all twelve.
        pt["pal_scale"] = round(BANDS / max(1.0, worst), 6)
        pt["pal_offset"] = round(floor, 3)
        json.dump(pt, open(dst, "w"), indent=2)
        print("%-12s kept: drift %.2f (period %d, so the palette lines up),"
              " spread %.3f, escape %.0f-%.0f (palette anchored at %.0f),"
              " %d steps, starts at 2^-%.0f"
              % (name, drift, -pt["p"], spread_steps, floor, worst, floor,
                 pt["maxiter"], -__import__("math").log2(hw0 / FULL_HW)))
        kept.append(name)
        kept_xy.append((name, x, y))

    print("\n%d kept, %d rejected, %d skipped as duplicates" % (len(kept), len(rejected), len(skipped)))
    if rejected:
        print("rejected: " + " ".join(rejected))
    if skipped:
        print("skipped:  " + " ".join(skipped))


main()
