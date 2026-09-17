import QtQuick
import Quickshell.Io

// This plugin's settings, and the only place that reads or writes them.
//
// The host keeps them on the plugin's entry in shell.json. It exposes no way to
// read that entry back -- the plugin-facing shell has only a mutator -- and it
// replaces shellConfig only *after* the file write completes. Reading straight
// through it therefore returns the previous value, and merging a patch over that
// stale copy silently drops whatever the write before it set.
//
// So this object keeps its own copy and treats the file purely as storage: seed
// from it once, notice edits made outside the plugin, and never read through the
// host for a value it is about to change.
QtObject {
  id: settings

  // Injected by the service.
  property var shell: null
  property string pluginId: ""
  property string configPath: ""

  // ----------------------------------------------------------------------
  // Defaults. Everything the plugin starts from lives here; a value set by an
  // ipc command is stored in shell.json and overrides it.
  //
  // `markers` and `poll` have no command of their own. markers=false stops the
  // plugin writing the background-picker image at all; poll=true forces the
  // wallpaper to be re-read every couple of seconds, for a host whose
  // background service cannot be reached.
  // ----------------------------------------------------------------------
  readonly property var defaults: ({
    fps: 20,                 // frames drawn per second
    speed: 0.03,             // octaves of zoom per second
    scale: 1,                // render at this fraction of the screen, then stretch up
    bands: 1.0,              // multiplier on the fractal's own colour band frequency
    randomPoint: true,       // start on a different point each launch
    paused: false,           // hold the animation still
    pauseWhenCovered: false, // ...while windows cover the whole screen
    markers: true,
    poll: false,
    screensaver: false       // show this fractal as the idle screensaver
  })

  function defaultsFor(key) {
    return defaults[key]
  }

  // The value in force, as stored or defaulted.
  function raw(key) {
    return state[key] === undefined ? defaults[key] : state[key]
  }

  property var state: ({})
  property string written: ""

  function body(src) {
    var out = {}
    for (var k in src)
      if (k !== "id") out[k] = src[k]
    return out
  }

  function stored() {
    var cfg = null
    try {
      cfg = JSON.parse(config.text() || "{}")
    } catch (e) {
      return ({})
    }
    var entries = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < entries.length; i++)
      if (entries[i] && String(entries[i].id) === pluginId)
        return body(entries[i])
    return ({})
  }

  // Our own write coming back looks like an outside edit; ignore that one.
  function adopt() {
    var s = JSON.stringify(stored())
    if (s === written || s === JSON.stringify(state))
      return
    state = JSON.parse(s)
  }

  function set(patch) {
    var next = body(state)
    for (var k in patch)
      next[k] = patch[k]
    state = next
    written = JSON.stringify(next)
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(pluginId, next)
  }

  // ----------------------------------------------------------------------
  // Typed accessors. Each clamps or falls back, so a hand-edited shell.json
  // cannot put the renderer into a state it has no way to show.
  // ----------------------------------------------------------------------

  // A frame rate is the duty cycle: at 20 fps a frame that costs 19 ms leaves
  // the GPU idle four fifths of the time.
  readonly property int fps: {
    var v = Math.round(Number(raw("fps")))
    return v > 0 ? v : defaults.fps
  }

  // Octaves of zoom per second. A loop is one renormalisation period, so this
  // decides how long that takes for whichever point is showing.
  readonly property real speed: {
    var v = Number(raw("speed"))
    return v > 0 ? v : defaults.speed
  }

  // Draw at a fraction of the screen and let the compositor stretch it back.
  readonly property real scale: Math.max(0.25, Math.min(1.0, number("scale")))

  readonly property real bands: {
    var v = number("bands")
    return v > 0 ? v : defaults.bands
  }

  readonly property bool randomPoint: flag("randomPoint")
  readonly property bool paused: flag("paused")
  readonly property bool pauseWhenCovered: flag("pauseWhenCovered")
  readonly property bool markers: flag("markers")
  readonly property bool poll: flag("poll")
  readonly property bool screensaver: flag("screensaver")

  // The point named by hand, if any. Whether it is usable, and what to show when
  // it is not, needs the catalogue and belongs to the service.
  readonly property string namedPoint: String(state.point === undefined ? "" : state.point)

  function number(key) {
    var v = Number(raw(key))
    return isFinite(v) ? v : 0
  }

  function flag(key) {
    return raw(key) === true
  }

  // The idle service's screensaver delay sits at the top level of the same file,
  // not on this plugin's entry, so it is read separately. A plain property
  // rather than a binding: text() is a method call, and a binding on it would
  // never re-evaluate when the file changes.
  property int idleScreensaverSeconds: 150

  function adoptIdle() {
    var cfg = null
    try {
      cfg = JSON.parse(config.text() || "{}")
    } catch (e) {
      cfg = null
    }
    var want = cfg && cfg.idle ? Math.round(Number(cfg.idle.screensaver)) : NaN
    idleScreensaverSeconds = want > 0 ? want : 150
  }

  // blockLoading makes text() a synchronous read, so the settings can be seeded
  // before anything asks for them.
  property FileView config: FileView {
    path: settings.configPath
    blockLoading: true
    watchChanges: true
    printErrors: false
    onLoaded: {
      settings.adopt()
      settings.adoptIdle()
    }
    onFileChanged: {
      reload()
      settings.adoptIdle()
    }
  }
}
