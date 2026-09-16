#!/usr/bin/env python3
"""Build the shader-side description of one Misiurewicz zoom.

Everything the loop needs is derived from the point itself, so nothing here can
drift from what the shader assumes:

  orbit        preperiod then cycle, q+p values, at full precision
  oct_per_loop log2 |lambda|, the zoom the renormalisation buys per loop
  rot_per_loop 1 - arg(lambda)/2pi, the turn that goes with it

`maxiter` is a placeholder here; tools/catalogue.py measures the point and sets
it. See that file for why.

usage: mkpoint.py <refine-output.txt> <name> <out.json>
"""
import json
import math
import sys
from decimal import Decimal, getcontext

getcontext().prec = 260


def main():
    ref, name, out = sys.argv[1:4]
    cre = cim = None
    q = p = None
    orbit = []
    for line in open(ref):
        if line.startswith("# c ="):
            re_s, im_s = line.split("=", 1)[1].strip().split(" + ")
            cre, cim = re_s.strip(), im_s.strip().rstrip("i")
        elif line.startswith("# q="):
            f = line.split()
            q = int(f[1].split("=")[1])
            p = int(f[2].split("=")[1])
        elif line and line[0].isdigit():
            _, a, b = line.split()
            orbit.append((a, b))
    if q is None or cre is None:
        raise SystemExit("could not parse %s" % ref)

    # lambda = product of 2 z_j around the cycle
    lre, lim = Decimal(1), Decimal(0)
    for a, b in orbit[q:q + p]:
        zr, zi = Decimal(2) * Decimal(a), Decimal(2) * Decimal(b)
        lre, lim = lre * zr - lim * zi, lre * zi + lim * zr
    abslam = float((lre * lre + lim * lim).sqrt())
    arglam = math.atan2(float(lim), float(lre)) / (2 * math.pi)

    pt = {
        "name": name,
        "c_re": cre,
        "c_im": cim,
        "q": q,
        "p": p,
        "abs_lambda": abslam,
        "arg_lambda_turns": arglam,
        "oct_per_loop": math.log2(abslam),
        "rot_per_loop": (1.0 - arglam) % 1.0,
        "maxiter": q + p * 49,
        "orbit": [[float(a), float(b)] for a, b in orbit[:q + p]],
    }
    with open(out, "w") as fh:
        json.dump(pt, fh, indent=2)
    print("%s: q=%d p=%d  |lambda|=%.6f  %.4f octaves/loop  %.6f turns/loop"
          % (name, q, p, abslam, pt["oct_per_loop"], pt["rot_per_loop"]))


main()
