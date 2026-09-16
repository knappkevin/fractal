// palette - turn a frame's escape counts into the picker image's scanlines.
//
// Kept separate from perturb so the CPU reference renderer keeps its one job:
// perturb still emits raw float32 escape counts and the catalogue still gates
// candidate points on exactly that. This program is the thumbnail's pixel
// pipeline. It resolves each count through the palette, flips the frame
// vertically to match the shader's row order, and halves both axes with a 2x2
// box average, which is the exact filter for a factor of two.
//
// The ramp itself is not here. marker.py builds the 1024 entry lookup table --
// it owns the palette, the smoothstep and the theme colours -- and hands it
// over as bytes, so there is nothing here that can drift from what the shader
// draws.
//
// Build: gcc -O2 -o palette palette.c -lm
//
//   palette <field.bin> <lut.bin> <W> <H> <scale> <base> <out.rows>
//
// field.bin is W*H little endian float32 escape counts, negative meaning the
// point never escaped. lut.bin is LUT_N RGB triples. W and H must be even.
// out.rows is the raw PNG scanline stream: every row is one filter byte, zero,
// then W/2 RGB triples, so the caller only has to wrap it in PNG chunks.
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define LUT_N 1024
#define LUT_MASK (LUT_N - 1)

// The palette entry for one escape count, or black when it never escaped.
static const unsigned char *shade(float v, double scale, double base,
                                  const unsigned char *lut) {
  static const unsigned char black[3] = { 0, 0, 0 };
  // Negative means no escape. `!(v >= 0)` rather than `v < 0` so a NaN also
  // lands here instead of reaching the cast below, which would be undefined.
  if (!(v >= 0.0f)) return black;
  // Same expression the shader uses, and fmod adjusted the way Python's float
  // remainder does it: the palette is anchored to the frame's own floor, not to
  // zero, and the drift is the period.
  double t = fmod(scale * ((double)v - base), 1.0);
  if (t < 0) t += 1.0;
  return lut + 3 * (((int)(t * LUT_N)) & LUT_MASK);
}

int main(int argc, char **argv) {
  if (argc < 8) {
    fprintf(stderr, "usage: palette field.bin lut.bin W H scale base out.rows\n");
    return 2;
  }
  const char *fieldpath = argv[1], *lutpath = argv[2];
  int W = atoi(argv[3]), H = atoi(argv[4]);
  double scale = atof(argv[5]), base = atof(argv[6]);
  const char *out = argv[7];

  if (W <= 0 || H <= 0 || (W % 2) || (H % 2)) {
    fprintf(stderr, "palette: W and H must be positive and even\n");
    return 2;
  }

  float *field = malloc(sizeof(float) * (size_t)W * (size_t)H);
  unsigned char lut[LUT_N * 3];
  if (!field) return 1;

  FILE *f = fopen(fieldpath, "rb");
  if (!f) { perror(fieldpath); return 1; }
  size_t got = fread(field, sizeof(float), (size_t)W * (size_t)H, f);
  fclose(f);
  if (got != (size_t)W * (size_t)H) {
    fprintf(stderr, "palette: %s holds %zu of %d values\n", fieldpath, got, W * H);
    return 1;
  }

  f = fopen(lutpath, "rb");
  if (!f) { perror(lutpath); return 1; }
  got = fread(lut, 1, sizeof lut, f);
  fclose(f);
  if (got != sizeof lut) {
    fprintf(stderr, "palette: %s holds %zu of %zu bytes\n", lutpath, got, sizeof lut);
    return 1;
  }

  int out_w = W / 2, out_h = H / 2;
  unsigned char *rows = malloc((size_t)out_w * (size_t)out_h * 3 + (size_t)out_h);
  if (!rows) return 1;

  for (int oy = 0; oy < out_h; oy++) {
    // The renderer counts rows from the top and the shader counts them from the
    // bottom, so the output runs the other way. Output row oy is the average of
    // source rows H-1-2*oy and H-2-2*oy, which is also the pair the flip maps
    // onto it. Each source row is read exactly once.
    const float *up = field + (size_t)(H - 1 - 2 * oy) * (size_t)W;
    const float *dn = field + (size_t)(H - 2 - 2 * oy) * (size_t)W;
    unsigned char *row = rows + (size_t)oy * ((size_t)out_w * 3 + 1);
    row[0] = 0;                       // PNG filter type for this scanline: none
    for (int ox = 0; ox < out_w; ox++) {
      const unsigned char *a = shade(up[2 * ox], scale, base, lut);
      const unsigned char *b = shade(up[2 * ox + 1], scale, base, lut);
      const unsigned char *c = shade(dn[2 * ox], scale, base, lut);
      const unsigned char *d = shade(dn[2 * ox + 1], scale, base, lut);
      for (int ch = 0; ch < 3; ch++)
        row[1 + ox * 3 + ch] = (a[ch] + b[ch] + c[ch] + d[ch]) >> 2;
    }
  }

  f = fopen(out, "wb");
  if (!f) { perror(out); return 1; }
  size_t want = (size_t)out_w * (size_t)out_h * 3 + (size_t)out_h;
  if (fwrite(rows, 1, want, f) != want) { perror(out); fclose(f); return 1; }
  fclose(f);
  free(rows);
  free(field);
  return 0;
}
