#!/bin/bash
# Regenerate every shader from points/*.json and write the catalogue index.
# Needs gcc for the CPU reference renderer and qt6-shadertools for qsb; both are
# build-time only, the plugin ships the compiled .qsb files.
set -euo pipefail
cd "$(dirname "$0")/.."

QSB=/usr/lib/qt6/bin/qsb
[ -x "$QSB" ] || QSB=$(command -v qsb) || { echo "qsb not found" >&2; exit 1; }

# Native tools are rebuilt from the source in this directory every time, never
# shipped prebuilt: a committed binary cannot be shown to come from the source a
# reviewer read. perturb is the CPU reference the catalogue gates points against
# and the marker renderer draws from; mis locates Misiurewicz points in a box.
gcc -O2 -o tools/perturb tools/perturb.c -lquadmath -lm
gcc -O2 -o tools/mis tools/mis.c -lm

rm -f mandelbrot/shaders/*.frag mandelbrot/shaders/*.frag.qsb
for p in mandelbrot/points/*.json; do
  [ -e "$p" ] || continue
  case "$p" in *index.json) continue ;; esac
  name=$(basename "$p" .json)
  python3 tools/gen.py "$p" "mandelbrot/shaders/$name.frag"
  "$QSB" --glsl 100es,120,150 --hlsl 50 --msl 12 \
        -o "mandelbrot/shaders/$name.frag.qsb" "mandelbrot/shaders/$name.frag"
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
