#!/bin/bash
# Regenerate every shader from points/*.json, rebuild the native helpers, and
# record the digests of what ships.
#
# Needs gcc for the helpers and qt6-shadertools for qsb. The plugin ships both
# built, so installing it needs neither: the marker renderer runs the helpers as
# they came out of this repository rather than compiling its own from a
# directory anything running as the user can write to.
set -euo pipefail
cd "$(dirname "$0")/.."

QSB=/usr/lib/qt6/bin/qsb
[ -x "$QSB" ] || QSB=$(command -v qsb) || { echo "qsb not found" >&2; exit 1; }

# perturb is the CPU reference the catalogue gates points against and the marker
# renderer draws from; palette turns its escape counts into the picker image's
# scanlines; mis locates Misiurewicz points in a box. mis is a tool only and is
# never run by the plugin, so it is built here but not shipped.
gcc -O2 -fopenmp -o tools/perturb tools/perturb.c -lquadmath -lm
gcc -O2 -o tools/palette tools/palette.c -lm
gcc -O2 -o tools/mis tools/mis.c -lm

rm -f mandelbrot/shaders/*.frag mandelbrot/shaders/*.frag.qsb
for p in mandelbrot/points/*.json; do
  [ -e "$p" ] || continue
  case "$p" in *index.json) continue ;; esac
  name=$(basename "$p" .json)
  # Two shaders per point: the Mandelbrot set at it, and the Julia set of its
  # parameter. Same camera, same orbit, same loop -- only where the perturbation
  # comes from differs, so the two names differ by a suffix and nothing else.
  for mode in mandel julia; do
    if [ "$mode" = julia ]; then suffix="-julia"; else suffix=""; fi
    python3 tools/gen.py "$p" "mandelbrot/shaders/$name$suffix.frag" "$mode"
    "$QSB" --glsl 100es,120,150 --hlsl 50 --msl 12 \
          -o "mandelbrot/shaders/$name$suffix.frag.qsb" "mandelbrot/shaders/$name$suffix.frag"
  done
done

python3 - <<'PY'
import json, glob, os
names, octaves = [], {}
for p in sorted(glob.glob("mandelbrot/points/*.json")):
    if p.endswith("index.json"):
        continue
    pt = json.load(open(p))
    names.append(pt["name"])
    octaves[pt["name"]] = round(pt["oct_per_loop"], 4)
json.dump({"points": names, "octaves": octaves, "default": "snowflake"},
          open("mandelbrot/points/index.json", "w"), indent=2)
print("index: %d points" % len(names))
PY

# What ships, and the toolchain that produced it. A committed binary can only be
# trusted as far as it can be rebuilt, so record both: anyone can rerun this
# script and compare, and a mismatch is visible rather than invisible.
{
  echo "# Digests of the artifacts this plugin ships, and the toolchain that made"
  echo "# them. Rerun tools/build.sh and compare with 'sha256sum -c'."
  echo "#"
  echo "#   $(gcc --version | head -1)"
  echo "#   $(getconf GNU_LIBC_VERSION 2>/dev/null || echo 'glibc version unavailable')"
  echo "#   $("$QSB" --version 2>/dev/null | head -1 || echo 'qsb version unavailable')"
  echo "#"
  echo "#   gcc -O2 -fopenmp -o tools/perturb tools/perturb.c -lquadmath -lm"
  echo "#   gcc -O2 -o tools/palette tools/palette.c -lm"
  echo "#   qsb --glsl 100es,120,150 --hlsl 50 --msl 12 -o <name>.frag.qsb <name>.frag"
  sha256sum tools/perturb tools/palette mandelbrot/shaders/*.frag.qsb | LC_ALL=C sort
} > tools/SHA256SUMS
echo "recorded $(( $(wc -l < tools/SHA256SUMS) )) lines in tools/SHA256SUMS"
