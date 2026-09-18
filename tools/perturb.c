// perturb - CPU reference renderer for the zoom plugin's catalogue gate.
//
// Renders the escape count of one frame of the loop with perturbation against a
// preperiodic reference orbit, at full precision, so the GPU shader has
// something independent to be checked against and so a candidate point can be
// judged before it is shipped.
//
// Build: gcc -O2 -fopenmp -o perturb perturb.c -lquadmath -lm
//
//   perturb <orbitfile> <q> <p> <halfwidth> <rotturns> <maxiter> <W> <H> <out.bin> [julia] [degree]
//
// orbitfile holds "k re im" per line at arbitrary precision, q+p of them.
// out.bin is W*H little endian float32 escape counts; negative means no escape.
//
// With `julia` the parameter is fixed and each pixel is its own starting z, so
// the perturbation seeds with the pixel's offset and nothing is added to it at
// any step. The reference orbit is the same critical orbit either way -- that is
// what makes one point worth rendering two ways.
//
// The family is z -> z^degree + c, degree defaulting to 2, so every existing
// point and caller is unchanged. The perturbation step is the binomial
// expansion of (Z + e)^degree about the reference Z, which is the same
// expression for every degree; only the escape count's normalisation names the
// degree, because the potential goes as log_degree.
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <quadmath.h>

#define MAXORB 4096

static double zr[MAXORB], zr2[MAXORB], zi[MAXORB], zi2[MAXORB];

// Binomial coefficients, small enough to compute rather than tabulate.
static double binom(int n, int k) {
  double r = 1;
  for (int i = 1; i <= k; i++)
    r = r * (n - k + i) / i;
  return r;
}

static void split(__float128 x, double *hi, double *lo) {
  *hi = (double)x;
  *lo = (double)(x - (__float128)*hi);
}

int main(int argc, char **argv) {
  if (argc < 10) {
    fprintf(stderr, "usage: perturb orbitfile q p halfwidth rotturns maxiter W H out.bin"
                    " [julia] [degree]\n");
    return 2;
  }
  int q = atoi(argv[2]), p = atoi(argv[3]);
  double hw = atof(argv[4]);
  double rot = atof(argv[5]) * 2 * M_PI;
  int maxiter = atoi(argv[6]);
  int W = atoi(argv[7]), H = atoi(argv[8]);
  const char *out = argv[9];
  int julia = argc > 10 && argv[10][0] == 'j';
  int degree = argc > 11 ? atoi(argv[11]) : 2;
  if (degree < 2) degree = 2;
  int np = q + p;

  FILE *g = fopen(argv[1], "r");
  if (!g) { perror(argv[1]); return 1; }
  char line[4096];
  int seen = 0;
  while (fgets(line, sizeof line, g)) {
    if (line[0] == '#' || !(line[0] >= '0' && line[0] <= '9')) continue;
    int k;
    char sre[2048], sim[2048];
    if (sscanf(line, "%d %2047s %2047s", &k, sre, sim) != 3) continue;
    if (k < 0 || k >= MAXORB) continue;
    split(strtoflt128(sre, NULL), &zr[k], &zr2[k]);
    split(strtoflt128(sim, NULL), &zi[k], &zi2[k]);
    if (k + 1 > seen) seen = k + 1;
  }
  fclose(g);
  if (seen < np) { fprintf(stderr, "orbit file has %d entries, need %d\n", seen, np); return 1; }

  float *field = malloc(sizeof(float) * (size_t)W * H);
  if (!field) return 1;

  double aspect = (double)H / (double)W;
  double cr = cos(rot), sr = sin(rot);
  long long escaped = 0, total = (long long)W * H;
  double worst = 0;

  // Rows are independent, and the only shared state is the two accumulators,
  // both of which reduce exactly: an integer count and a maximum. Compiled
  // without -fopenmp the pragma is ignored and this is the serial loop it was,
  // so the flag is an optimisation rather than a requirement.
#pragma omp parallel for reduction(+:escaped) reduction(max:worst) schedule(static)
  for (int j = 0; j < H; j++) {
    for (int i = 0; i < W; i++) {
      double u = ((i + 0.5) / W - 0.5) * 2 * hw;
      double v = ((j + 0.5) / H - 0.5) * 2 * hw * aspect;
      double dx = u * cr - v * sr, dy = u * sr + v * cr;

      double ex = julia ? dx : 0, ey = julia ? dy : 0, val = -1;
      for (int k = 0; k < maxiter; k++) {
        int idx = k < q ? k : q + (k - q) % p;
        double hiz = zr[idx], loz = zr2[idx];
        double hix = zi[idx], lox = zi2[idx];
        // e <- sum over j of C(d,j) Z^(d-j) e^j, plus dc. Horner in e, from the
        // highest power down: each pass multiplies the accumulator by e and adds
        // the next coefficient. Degree 2 gives 2Ze + e^2, which is what this
        // always did.
        //
        // Z is carried as hi + lo. Only the linear coefficient d*Z^(d-1) folds
        // in lo, and only to first order, for the same reason as before: e is
        // small, so lo against a higher power of e is below the noise. The
        // first-order change of d*Z^(d-1) under Z -> Z + lo is
        // d(d-1) Z^(d-2) lo, and the d is applied by the coefficient below, so
        // what is added to Z^(d-1) here is (d-1) Z^(d-2) lo.
        double ax = 0, ay = 0;
        for (int j = degree; j >= 1; j--) {
          double tx = ax * ex - ay * ey;
          double ty = ax * ey + ay * ex;
          double px = 1, py = 0;
          for (int t = 0; t < degree - j; t++) {
            double qx = px * hiz - py * hix;
            double qy = px * hix + py * hiz;
            px = qx; py = qy;
          }
          if (j == 1 && degree > 1) {
            double lx = 1, ly = 0;
            for (int t = 0; t < degree - 2; t++) {
              double qx = lx * hiz - ly * hix;
              double qy = lx * hix + ly * hiz;
              lx = qx; ly = qy;
            }
            double k2 = degree - 1;
            px += k2 * (lx * loz - ly * lox);
            py += k2 * (lx * lox + ly * loz);
          }
          double coef = binom(degree, j);
          ax = tx + coef * px;
          ay = ty + coef * py;
        }
        // Every coefficient carries a power of e, so the accumulator built above
        // is one factor short of the polynomial: (Z+e)^d - Z^d = e * Q(e).
        double fx = ax * ex - ay * ey;
        double fy = ax * ey + ay * ex;
        ex = fx + (julia ? 0 : dx);
        ey = fy + (julia ? 0 : dy);
        double zx = hiz + ex, zy = hix + ey;
        double m = zx * zx + zy * zy;
        if (m > 65536.0) {
          // log_degree, so the count means the same thing whatever the degree
          val = k + 1 - log2(log(m) / (2 * log(2))) / log2(degree);
          break;
        }
      }
      if (val >= 0) {
        escaped++;
        if (val > worst) worst = val;
      }
      field[(size_t)j * W + i] = (float)val;
    }
  }

  FILE *f = fopen(out, "wb");
  if (!f) { perror(out); return 1; }
  fwrite(field, sizeof(float), (size_t)W * H, f);
  fclose(f);
  free(field);

  fprintf(stderr, "escaped=%.2f%% worst=%.1f\n", 100.0 * escaped / total, worst);
  return 0;
}
