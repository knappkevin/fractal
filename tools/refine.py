#!/usr/bin/env python3
"""Refine a Misiurewicz point of preperiod q / period p to arbitrary precision and
emit its preperiodic orbit.  Pure decimal complex arithmetic, no third-party deps."""
import sys
from decimal import Decimal, getcontext, localcontext

getcontext().prec = 260


def add(a, b):
    return (a[0] + b[0], a[1] + b[1])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1])


def mul(a, b):
    return (a[0] * b[0] - a[1] * b[1], a[0] * b[1] + a[1] * b[0])


def div(a, b):
    d = b[0] * b[0] + b[1] * b[1]
    return ((a[0] * b[0] + a[1] * b[1]) / d, (a[1] * b[0] - a[0] * b[1]) / d)


def orbit_and_deriv(c, n):
    """Return (z_n, dz_n) where z_0 = 0, z_{k+1} = z_k^2 + c."""
    z = (Decimal(0), Decimal(0))
    dz = (Decimal(0), Decimal(0))
    for _ in range(n):
        dz = add(mul((Decimal(2) * z[0], Decimal(2) * z[1]), dz), (Decimal(1), Decimal(0)))
        z = add(mul(z, z), c)
    return z, dz


def refine(cre, cim, q, p, iters=60):
    c = (Decimal(cre), Decimal(cim))
    n = q + p
    for _ in range(iters):
        zn, dzn = orbit_and_deriv(c, n)
        zq, dzq = orbit_and_deriv(c, q)
        g = sub(zn, zq)
        dg = sub(dzn, dzq)
        c = sub(c, div(g, dg))
    return c


def orbit(c, n):
    z = (Decimal(0), Decimal(0))
    out = [z]
    for _ in range(n):
        z = add(mul(z, z), c)
        out.append(z)
    return out


def main():
    cre, cim = sys.argv[1], sys.argv[2]
    q, p = int(sys.argv[3]), int(sys.argv[4])
    c = refine(cre, cim, q, p)
    print("# c = %s + %si" % (c[0], c[1]))
    print("# q=%d p=%d" % (q, p))
    zs = orbit(c, q + p)
    # verify preperiodicity to the working precision
    d = abs(zs[q + p][0] - zs[q][0]) + abs(zs[q + p][1] - zs[q][1])
    print("# |z_{q+p} - z_q| = %s" % d)
    for i, z in enumerate(zs):
        print("%d %s %s" % (i, z[0], z[1]))


main()
