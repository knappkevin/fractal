#!/usr/bin/env python3
"""Refine a Misiurewicz point of preperiod q / period p to arbitrary precision and
emit its preperiodic orbit.  Pure decimal complex arithmetic, no third-party deps.

The family is z -> z^degree + c.  Degree 2 is the Mandelbrot set and is the
default, so every existing caller and point is unchanged; 3 and 4 are the
multibrot sets, which have Misiurewicz points of their own and renormalise the
same way.

usage: refine.py <re> <im> <q> <p> [degree]"""
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


def power_map(z, c, degree):
    """z^degree + c, by repeated multiplication: exact for any small integer."""
    out = (Decimal(1), Decimal(0))
    for _ in range(degree):
        out = mul(out, z)
    return add(out, c)


def power_deriv(z, degree):
    """d/dz of z^degree, that is degree * z^(degree-1)."""
    out = (Decimal(degree), Decimal(0))
    for _ in range(degree - 1):
        out = mul(out, z)
    return out


def orbit_and_deriv(c, n, degree=2):
    """Return (z_n, dz_n) where z_0 = 0, z_{k+1} = z_k^degree + c."""
    z = (Decimal(0), Decimal(0))
    dz = (Decimal(0), Decimal(0))
    for _ in range(n):
        dz = add(mul(power_deriv(z, degree), dz), (Decimal(1), Decimal(0)))
        z = power_map(z, c, degree)
    return z, dz


def refine(cre, cim, q, p, iters=60, degree=2):
    c = (Decimal(cre), Decimal(cim))
    n = q + p
    for _ in range(iters):
        zn, dzn = orbit_and_deriv(c, n, degree)
        zq, dzq = orbit_and_deriv(c, q, degree)
        g = sub(zn, zq)
        dg = sub(dzn, dzq)
        c = sub(c, div(g, dg))
    return c


def orbit(c, n, degree=2):
    z = (Decimal(0), Decimal(0))
    out = [z]
    for _ in range(n):
        z = power_map(z, c, degree)
        out.append(z)
    return out


def main():
    cre, cim = sys.argv[1], sys.argv[2]
    q, p = int(sys.argv[3]), int(sys.argv[4])
    degree = int(sys.argv[5]) if len(sys.argv) > 5 else 2
    c = refine(cre, cim, q, p, degree=degree)
    print("# c = %s + %si" % (c[0], c[1]))
    print("# q=%d p=%d degree=%d" % (q, p, degree))
    zs = orbit(c, q + p, degree)
    # verify preperiodicity to the working precision
    d = abs(zs[q + p][0] - zs[q][0]) + abs(zs[q + p][1] - zs[q][1])
    print("# |z_{q+p} - z_q| = %s" % d)
    for i, z in enumerate(zs):
        print("%d %s %s" % (i, z[0], z[1]))


main()
