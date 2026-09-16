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
QtObject {
  id: catalogue

  property string path: ""

  property var names: ["snowflake"]
  property var octaves: ({})
  property string fallback: "snowflake"

  function has(name) {
    return names.indexOf(String(name)) >= 0
  }

  // How far one loop zooms for this point. Used only for pacing; the renderer
  // has the real figure baked in.
  function octavesFor(name) {
    var v = Number(octaves[name])
    return isFinite(v) && v > 0 ? v : 4.38
  }

  function next(name) {
    if (!names.length)
      return ""
    var i = names.indexOf(name)
    return names[(i + 1) % names.length]
  }

  // Any name but the one showing, so `point random` always changes the picture.
  function another(name) {
    if (names.length < 2)
      return names.length ? names[0] : ""
    var pick = names[Math.floor(Math.random() * names.length)]
    return pick === name ? next(name) : pick
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
    fallback = list.indexOf(o.default) >= 0 ? o.default : list[0]
  }
}
