import QtQuick
import Quickshell.Io

// The catalogue of Misiurewicz points this fractal can zoom into.
//
// Written by tools/build.sh, which also records how much zoom each point buys
// per loop so the loop length can be scaled to keep the apparent zoom speed the
// same whichever point is showing.
//
// Every point in it has been checked by tools/catalogue.py to settle at the
// depth the loop starts from. That is what lets the loop wrap without a seam,
// and it is not something a name can tell you.
//
// Each point renders two ways -- the Mandelbrot set at it, and the Julia set of
// its parameter -- and the *name* says which: `<point>` or `<point>-julia`. So
// a pick survives a mode change, `point list` can offer 12 names or 24, and one
// name is enough to choose both the shader and the data.
QtObject {
  id: catalogue

  property string path: ""

  // Which renderings to offer: "mandel", "julia", or "both".
  property string mode: "mandel"

  // Which family: z^2 + c, z^3 + c or z^4 + c. Each degree has Misiurewicz
  // points of its own, so this selects which of them are offered rather than
  // being a dial on any one of them.
  property int power: 2

  // Base names from the point file.
  property var names: ["snowflake"]
  property var octaves: ({})
  property var powers: ({})
  property string fallback: "snowflake"

  readonly property string juliaSuffix: "-julia"

  // Every name this mode offers. A plain property rather than a binding to an
  // array: a bound array read from another component's binding is what made QML
  // report a binding loop on `point` earlier, and there is no need to risk it.
  property var variants: ["snowflake"]

  // Degree 2 for a point file written before degrees existed, or one that did
  // not record it.
  function powerOf(name) {
    var v = Number(powers[String(name)])
    return isFinite(v) && v > 0 ? v : 2
  }

  // The degrees this catalogue actually has points for, ascending. The panel
  // offers these and nothing else: a family with no points would otherwise be
  // selectable and would silently show the fallback, which reads as the plugin
  // ignoring the choice.
  readonly property var availablePowers: {
    var seen = [], out = []
    for (var i = 0; i < names.length; i++) {
      var d = powerOf(names[i])
      if (seen.indexOf(d) < 0) { seen.push(d); out.push(d) }
    }
    out.sort(function(a, b) { return a - b })
    return out.length ? out : [2]
  }

  function rebuild() {
    var suffixes = mode === "julia" ? [juliaSuffix]
                 : (mode === "both" ? ["", juliaSuffix] : [""])
    // A stored degree the catalogue has no points for resolves to the lowest it
    // does have, so an old setting can never leave the plugin with nothing.
    var have = availablePowers || [2]
    var use = have.indexOf(power) >= 0 ? power : have[0]
    var out = []
    for (var s = 0; s < suffixes.length; s++)
      for (var i = 0; i < names.length; i++)
        if (powerOf(names[i]) === use)
          out.push(names[i] + suffixes[s])
    variants = out.length ? out : ["snowflake"]
    // The fallback has to be a point this degree offers, or a pick would
    // resolve to a name the catalogue cannot draw.
    if (names.indexOf(fallback) < 0 || powerOf(fallback) !== use)
      for (var j = 0; j < names.length; j++)
        if (powerOf(names[j]) === use) { fallback = names[j]; break }
  }

  onModeChanged: rebuild()
  onNamesChanged: rebuild()
  onPowerChanged: rebuild()

  // The name to fall back to when a pick is not offered in this mode.
  readonly property string defaultVariant:
    mode === "julia" ? fallback + juliaSuffix : fallback

  function isJulia(name) {
    var s = String(name)
    return s.length > juliaSuffix.length && s.slice(-juliaSuffix.length) === juliaSuffix
  }

  function base(name) {
    var s = String(name)
    return isJulia(s) ? s.slice(0, -juliaSuffix.length) : s
  }

  function has(name) {
    return variants.indexOf(String(name)) >= 0
  }

  // How far one loop zooms for this point. Used only for pacing; the renderer
  // has the real figure baked in. Both renderings of a point zoom alike.
  function octavesFor(name) {
    var v = Number(octaves[base(name)])
    return isFinite(v) && v > 0 ? v : 4.38
  }

  function next(name) {
    if (!variants.length)
      return ""
    var i = variants.indexOf(String(name))
    return variants[(i + 1) % variants.length]
  }

  // Any name but the one showing, so `point random` always changes the picture.
  function another(name) {
    if (variants.length < 2)
      return variants.length ? variants[0] : ""
    var pick = variants[Math.floor(Math.random() * variants.length)]
    return pick === String(name) ? next(name) : pick
  }

  property FileView file: FileView {
    path: catalogue.path
    watchChanges: false
    printErrors: false
    onLoaded: catalogue.parse(text())
    onLoadFailed: catalogue.parse("{}")
  }

  function parse(text) {
    var o
    try {
      o = JSON.parse(String(text || "{}"))
    } catch (e) {
      o = {}
    }
    var list = Array.isArray(o.points) && o.points.length ? o.points : ["snowflake"]
    names = list
    octaves = o.octaves || ({})
    powers = o.powers || ({})
    fallback = list.indexOf(o.default) >= 0 ? o.default : list[0]
    rebuild()
  }
}
