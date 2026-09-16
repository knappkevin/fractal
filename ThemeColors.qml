import QtQuick
import Quickshell.Io

// The active theme's colors.toml, reduced to the four colours the zoom paints
// with.
//
// Every colour here is a value copied straight out of colors.toml. Nothing is
// blended, re-lit or hue-rotated: a theme that has no green should not produce
// green, and `colorFromTheme` should not be able to report true while showing
// something the theme does not contain. The cost is that a theme whose accents
// sit close together gives a ramp whose bands are close together too, which is
// that theme's palette and not this plugin's business to improve on.
QtObject {
  id: palette

  // Set by the host.
  property string source: ""
  property var values: ({})

  // Emitted once the file has actually been read, successfully or not. A
  // reload() is asynchronous, so anything that wants colours has to wait for
  // this rather than reading `ramp` on the next line after calling reload.
  signal reloaded()

  function reload() {
    if (source) file.reload()
  }

  function parse(text) {
    var out = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6,8})/)
      if (m) out[m[1]] = m[2].substring(0, 7)
    }
    return out
  }

  // First key present wins, verbatim.
  function pick(names, fallback) {
    for (var i = 0; i < names.length; i++) {
      var v = values[names[i]]
      if (typeof v === "string" && v.length > 0) return v
    }
    return fallback
  }

  function relativeLuminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }

  readonly property color background: pick(["background", "color0"], "#101014")
  readonly property color foreground: pick(["foreground", "color15", "color7"], "#e0e0e0")
  readonly property bool light: relativeLuminance(background) > 0.5

  // The four roles the ramp is built from, verbatim. Two key schemas exist, named
  // and numbered, so every role names candidates in both.
  readonly property string srcAccent:
    pick(["accent", "blue", "color4", "color12"], "#7d82d9")
  readonly property string srcSelection:
    pick(["selection", "dark_background", "color8", "color0"], "#252e56")
  readonly property string srcBackground:
    pick(["background", "darker_background", "color0"], "#060b1e")
  readonly property string srcForeground:
    pick(["foreground", "bright_foreground", "color15", "color7"], "#ffcead")

  // Ordered by how far each colour sits from the theme's background, so the
  // ramp starts on the background and walks away from it.
  //
  // Sorting by luminance instead looked right on a dark theme and is wrong on a
  // light one: the palette is anchored so the frame's outermost pixels land on
  // the first stop, so on a light theme a luminance sort put the *foreground* in
  // the far field and the whole picture came out dark. Distance from the
  // background gives the background the far field on both.
  readonly property var ramp: {
    var v = [srcAccent, srcSelection, srcBackground, srcForeground]
    var b = relativeLuminance(background)
    v.sort(function(x, y) {
      return Math.abs(relativeLuminance(Qt.color(x)) - b)
           - Math.abs(relativeLuminance(Qt.color(y)) - b)
    })
    return v
  }

  readonly property color ramp0: Qt.color(ramp[0])
  readonly property color ramp1: Qt.color(ramp[1])
  readonly property color ramp2: Qt.color(ramp[2])
  readonly property color ramp3: Qt.color(ramp[3])

  property FileView file: FileView {
    path: palette.source
    // A theme switch does `rm -rf current/theme` and renames a new directory
    // over it, which drops a watch on anything inside for good. The host calls
    // reload() from the theme-name watcher in the service instead.
    watchChanges: false
    printErrors: false
    onLoaded: {
      palette.values = palette.parse(text())
      palette.reloaded()
    }
    onLoadFailed: {
      palette.values = ({})
      palette.reloaded()
    }
  }
}
