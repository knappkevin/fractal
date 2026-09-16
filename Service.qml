pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick

import "mandelbrot"

// Draws an endless fractal zoom above the wallpaper and below every window.
//
// Picking the plugin's image in the background switcher turns it on; any other
// wallpaper turns it off. The wallpaper renderer is untouched: this owns a
// click-through surface on the Bottom layer directly above it.
//
// Layout: the settings store is Settings.qml, the picker image Thumbnail.qml,
// the theme palette ThemeColors.qml, the layer surface SceneWindow.qml, and the
// fractal itself under mandelbrot/. This file wires them together and holds the
// command surface, which cannot live elsewhere -- see the note above IpcHandler.
Item {
  id: root

  // Injected by the host, after Component.onCompleted. Not safe during construction.
  property var shell
  property var manifest

  readonly property string pluginId:
    manifest && manifest.id ? String(manifest.id) : "knappkevin.fractal"

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/omarchy/current"
  readonly property string pluginDir:
    decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")

  readonly property string configPath: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    return (xdg && xdg.length ? xdg : home + "/.config") + "/omarchy/shell.json"
  }

  // The image the background picker offers, and the name that selects it. Both
  // are the plugin's identity rather than any one fractal's.
  readonly property string markerFile: "fractal-zoom.png"
  readonly property string markerPattern: "^fractal-zoom\\."

  // ----------------------------------------------------------------------
  // Which wallpaper is showing, and therefore whether to draw at all.
  //
  // Not read through the background service's own binding: the renderer owns the
  // "background" IpcHandler, and following the symlink here would read the whole
  // image. Duck-typed, because forks differ.
  // ----------------------------------------------------------------------
  readonly property var backgroundService: {
    if (!shell)
      return null
    if (typeof shell.serviceFor === "function") {
      var direct = shell.serviceFor("omarchy.background")
      if (direct && typeof direct.currentBackground === "string")
        return direct
    }
    if (!shell._services)
      return null
    for (var id in shell._services) {
      var svc = shell._services[id]
      if (svc && typeof svc.currentBackground === "string")
        return svc
    }
    return null
  }

  readonly property bool bound: backgroundService !== null
  property string polledWallpaper: ""
  readonly property string wallpaper: bound ? backgroundService.currentBackground : polledWallpaper

  readonly property bool active:
    String(wallpaper).split("/").pop().toLowerCase().match(markerPattern) !== null

  // The picker image follows the palette, not the wallpaper: see onReloaded.
  onWallpaperChanged: palette.reload()

  // ----------------------------------------------------------------------
  // Children
  // ----------------------------------------------------------------------
  Settings {
    id: settings
    shell: root.shell
    pluginId: root.pluginId
    configPath: root.configPath
  }

  Catalogue {
    id: catalogue
    path: root.pluginDir + "/mandelbrot/points/index.json"
    onNamesChanged: root.onCatalogueReady()
  }

  ThemeColors {
    id: palette
    source: root.stateDir + "/theme/colors.toml"

    // Reloading the palette is asynchronous, so the renderer must be kicked off
    // from here rather than from whatever asked for the reload. Doing it the
    // other way round rendered every thumbnail in the colours of the theme that
    // had just been replaced -- the picker image was always one theme behind.
    onReloaded: root.wantThumbnail()
  }

  Thumbnail {
    id: thumbnail
    home: root.home
    pluginDir: root.pluginDir
    stateDir: root.stateDir
    fileName: root.markerFile
    seedScript: root.pluginDir + "/install-marker.sh"
  }

  Component.onCompleted: {
    // After the children exist, so the settings can read shell.json. The first
    // render waits for onReloaded above, which covers the initial palette read.
    settings.adopt()
    onCatalogueReady()
  }

  // ----------------------------------------------------------------------
  // Which point is showing
  //
  // The session pick is deliberately not persisted: shell.json keeps whichever
  // point was last named by hand, so turning `randompoint` off returns you to
  // that rather than to a dice roll.
  // ----------------------------------------------------------------------
  property string sessionPoint: ""

  readonly property string point: {
    var want = String(sessionPoint || settings.namedPoint || "")
    return catalogue.has(want) ? want : catalogue.fallback
  }

  readonly property real loopMs:
    Math.max(4000, 1000 * catalogue.octavesFor(point) / settings.speed)

  // The catalogue loads asynchronously, so the random pick and the picker image
  // both wait for it rather than rendering the wrong point.
  function onCatalogueReady() {
    if (!catalogue.names.length)
      return
    if (settings.randomPoint && !sessionPoint)
      rollPoint()
    wantThumbnail()
  }

  function rollPoint() {
    sessionPoint = catalogue.another(point)
    phase = 0
    wantThumbnail()
  }

  // Switching point changes the loop, so start it from the top rather than
  // part-way through a shape the new point does not share.
  function choose(name) {
    if (!catalogue.has(name))
      return
    settings.set({ point: name })
    sessionPoint = name
    phase = 0
    wantThumbnail()
  }

  function reload() {
    palette.reload()
    settings.adopt()
    wantThumbnail()
    if (!probe.running)
      probe.running = true
  }

  function wantThumbnail() {
    if (!settings.markers || !point)
      return
    thumbnail.request(["/usr/bin/python3", pluginDir + "/tools/marker.py",
                       pluginDir + "/mandelbrot/points/" + point + ".json", "0",
                       thumbnail.outputPath].concat(palette.ramp))
  }

  // ----------------------------------------------------------------------
  // Timing
  //
  // One driver for every screen, so the surfaces commit in the same pass instead
  // of drifting against each other.
  // ----------------------------------------------------------------------
  property real phase: 0

  Timer {
    interval: Math.max(16, Math.round(1000 / settings.fps))
    repeat: true
    running: root.active && !root.covered && !settings.paused
    onTriggered: root.phase = (root.phase + interval / root.loopMs) % 1
  }

  // Off by default: gaps and transparency mean the desktop is rarely truly
  // hidden, and a stopped background reads as a glitch. All screens, because the
  // phase is shared.
  readonly property bool covered: {
    if (!settings.pauseWhenCovered)
      return false
    var monitors = Hyprland.monitors.values
    if (monitors.length === 0)
      return false
    for (var i = 0; i < monitors.length; i++) {
      var ws = monitors[i].activeWorkspace
      if (!ws || ws.toplevels.values.length === 0)
        return false
    }
    return true
  }

  // A theme switch rm -rf's current/theme and renames a new directory over it,
  // which kills a watch on anything inside. It also leaves this plugin's
  // background path byte for byte the same, so nothing else here would notice.
  // This file sits beside the swapped directory and is rewritten in place
  // afterwards, making it the one reliable signal that the palette changed.
  FileView {
    id: themeName
    path: root.stateDir + "/theme.name"
    watchChanges: true
    printErrors: false
    onLoaded: palette.reload()
    onFileChanged: reload()
  }

  // Fallback for a host that injects no `shell`. Idle whenever the binding works.
  Timer {
    interval: 2000
    repeat: true
    triggeredOnStart: true
    running: !root.bound || settings.poll
    onTriggered: if (!probe.running) probe.running = true
  }

  Process {
    id: probe
    clearEnvironment: true
    environment: ({ HOME: root.home })
    command: ["/usr/bin/timeout", "-k", "5", "10",
              "/usr/bin/readlink", "-f", root.stateDir + "/background"]
    stdout: StdioCollector {
      // Ignore an empty read: ln -nsf leaves a brief window with no target.
      onStreamFinished: {
        var s = String(text || "").trim()
        if (s)
          root.polledWallpaper = s
      }
    }
  }

  // ----------------------------------------------------------------------
  // Commands
  //
  // An IpcHandler exposes every property and function on it across IPC, and only
  // accepts types that survive that trip: a `var` property or an untyped
  // parameter is rejected outright. So the verbs here are a thin table taking
  // exactly one string, and the work is done by plain functions on the root,
  // which are not reachable from IPC and can be written normally.
  //
  // Verbs that take no input are declared with no parameters, because Quickshell
  // rejects a call that does not supply every declared argument -- a required
  // parameter would mean `fractal help` could not be run without a placeholder.
  // ----------------------------------------------------------------------
  IpcHandler {
    target: "fractal"

    function help(): string {
      var d = settings.defaults
      return [
        "fps <n>                how many frames a second to draw. Lower is easier on the",
        "                       gpu; higher looks smoother (" + d.fps + ")",
        "scale <0.25-1>         draw at this fraction of the screen and stretch the result",
        "                       back up. Lower is cheaper, softer and a bit flickery (" + d.scale + ")",
        "speed <octaves/sec>    how fast it zooms in. Each point plays a loop whose length",
        "                       follows from this, so every point zooms at the same rate ("
          + d.speed + ")",
        "bands <n>              how busy the colour banding is. Higher is more stripes ("
          + d.bands + ")",
        "pause <true|false|toggle>",
        "                       hold the animation still, or start it again",
        "pauseWhenCovered <true|false|toggle>",
        "                       hold it still while windows cover the whole screen",
        "randompoint <true|false|toggle>",
        "                       start on a different random point each time the shell",
        "                       restarts (" + d.randomPoint + ")",
        "point list             show the places in the set you can zoom into",
        "point <name>           zoom into that one",
        "point next             move along to the next one",
        "point random           jump to one at random now",
        "refresh                re-read your theme and settings, remake the picker image",
        "help                   this text",
        "",
        "Every setting above also accepts `get` to read its value without changing it.",
      ].join("\n")
    }

    function refresh(): void {
      root.reload()
    }

    function fps(value: string): string {
      return root.setNumber(value, "fps", 1, 1000)
    }

    function speed(value: string): string {
      return root.setNumber(value, "speed", 0.001, 4)
    }

    function scale(value: string): string {
      return root.setNumber(value, "scale", 0.25, 1)
    }

    function bands(value: string): string {
      return root.setNumber(value, "bands", 0.05, 20)
    }

    function pause(value: string): string {
      return root.setFlag(value, "paused")
    }

    function pauseWhenCovered(value: string): string {
      return root.setFlag(value, "pauseWhenCovered")
    }

    function randompoint(value: string): string {
      var was = settings.randomPoint
      var answer = root.setFlag(value, "randomPoint")
      // Turning it on should show what it does rather than wait for a restart.
      if (settings.randomPoint && !was)
        root.rollPoint()
      return answer
    }

    function point(value: string): string {
      if (value === "get" || value === "")
        return root.point
      if (value === "list")
        return catalogue.names.join(" ")
      if (value === "next")
        return root.chooseAndReport(catalogue.next(root.point))
      if (value === "random")
        return root.chooseAndReport(catalogue.another(root.point))
      if (!catalogue.has(value))
        return "unknown point '" + value + "'; try: fractal point list"
      return root.chooseAndReport(value)
    }
  }

  function chooseAndReport(name) {
    choose(name)
    return point
  }

  // The stored value in force, with the same clamping the accessors apply, so a
  // hand-edited shell.json cannot make `get` report something unusable.
  function settingNumber(key) {
    if (key === "fps")
      return settings.fps
    if (key === "speed")
      return settings.speed
    if (key === "scale")
      return settings.scale
    return settings.bands
  }

  function setNumber(value, key, low, high) {
    if (value !== "get") {
      var n = Number(value)
      if (!(isFinite(n) && n >= low && n <= high))
        return "usage: " + key + " get|<" + low + " to " + high + ">"
      var patch = {}
      patch[key] = key === "fps" ? Math.round(n) : n
      settings.set(patch)
    }
    return String(settingNumber(key))
  }

  function setFlag(value, key) {
    if (value === "true" || value === "false") {
      var set = {}
      set[key] = value === "true"
      settings.set(set)
    } else if (value === "toggle") {
      var flip = {}
      flip[key] = !settings.flag(key)
      settings.set(flip)
    } else if (value !== "get") {
      return "usage: " + key + " get|true|false|toggle"
    }
    return settings.flag(key) ? "true" : "false"
  }

  // One surface per screen. The scene is a single full-screen shader, so there
  // is nothing to split across surfaces.
  Variants {
    model: Quickshell.screens

    Scope {
      id: screenScope
      required property var modelData

      SceneWindow {
        screen: screenScope.modelData
        anchors { top: true; bottom: true; left: true; right: true }
        shown: root.active

        scene: Component {
          MandelbrotZoom {
            aspect: screenScope.modelData.height / Math.max(1, screenScope.modelData.width)
            phase: root.phase
            pointName: root.point
            shaderDir: root.pluginDir + "/mandelbrot/shaders/"
            renderScale: settings.scale
            bandScale: settings.bands
            colors: palette
          }
        }
      }
    }
  }
}
