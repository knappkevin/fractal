// mis - locate Misiurewicz points inside a box of the plane.
//
// Solves f^(q+p)(0) = f^q(0) by Newton from a grid of starts and keeps only the
// roots that land inside the box. Newton converges globally, so the grid only
// supplies starting points; the box test is on the result, not on the start.
// Values are printed at double precision - tools/refine.py polishes whichever
// ones are worth keeping.
//
// Build: gcc -O2 -o mis mis.c -lm
//   mis <x0> <x1> <y0> <y1> <step> <maxqp>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <complex.h>

int main(int argc, char **argv) {
  if (argc < 7) { fprintf(stderr, "usage: mis x0 x1 y0 y1 step maxqp\n"); return 2; }
  double x0 = atof(argv[1]), x1 = atof(argv[2]);
  double y0 = atof(argv[3]), y1 = atof(argv[4]);
  double step = atof(argv[5]);
  int maxqp = atoi(argv[6]);

  // Roots already reported, so the many starts in one basin print once.
  double complex *seen = malloc(sizeof(double complex) * 400000);
  int nseen = 0;

  for (int q = 0; q <= maxqp; q++) {
    for (int p = 1; q + p <= maxqp; p++) {
      int n = q + p;
      for (double x = x0; x <= x1 + 1e-12; x += step) {
        for (double y = y0; y <= y1 + 1e-12; y += step) {
          double complex c = x + y * I;
          if (cabs(c) > 2.2) continue;
          int ok = 0;
          for (int it = 0; it < 60; it++) {
            double complex z = 0, dz = 0, zq = 0, dzq = 0;
            for (int k = 0; k < n; k++) {
              if (k == q) { zq = z; dzq = dz; }
              dz = 2.0 * z * dz + 1.0;
              z = z * z + c;
            }
            double complex g = z - zq, dg = dz - dzq;
            if (cabs(dg) < 1e-14) break;
            double complex st = g / dg;
            c -= st;
            if (cabs(st) < 1e-14) { ok = 1; break; }
          }
          if (!ok) continue;

          // Confirm the root, and require a repelling cycle: |lambda| > 1.
          double complex z = 0, w = 0;
          for (int k = 0; k < n; k++) {
            if (k == q) w = z;
            z = z * z + c;
          }
          if (cabs(z - w) > 1e-9) continue;
          double complex lam = 1;
          for (int k = 0; k < p; k++) { lam *= 2.0 * w; w = w * w + c; }
          if (cabs(lam) <= 1.05) continue;

          int dup = 0;
          for (int i = 0; i < nseen; i++) if (cabs(seen[i] - c) < 1e-9) { dup = 1; break; }
          if (dup) continue;
          if (nseen < 400000) seen[nseen++] = c;

          printf("%d %d %.17g %.17g %.6f\n", q, p, creal(c), cimag(c), cabs(lam));
        }
      }
    }
  }
  fprintf(stderr, "%d distinct points\n", nseen);
  return 0;
}
