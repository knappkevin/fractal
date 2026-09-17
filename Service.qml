pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
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

  // Resolved in a function rather than inline so `rollPoint()` can ask for the
  // point without reading the `point` property itself. Reading that bound
  // property there while writing `sessionPoint` -- which the binding depends on
  // -- is a cycle, and QML reported it as one.
  function resolvedPoint() {
    var want = String(sessionPoint || settings.namedPoint || "")
    var list = catalogue.names
    return list && list.indexOf(want) >= 0 ? want : catalogue.fallback
  }

  readonly property string point: resolvedPoint()

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
    sessionPoint = catalogue.another(resolvedPoint())
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
    // Also stopped while the screensaver is up: it covers the desktop, so
    // animating underneath it would be a second full-screen shader pass per
    // monitor for nothing.
    running: root.active && !root.covered && !settings.paused && !root.screensaverShowing
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

  // ----------------------------------------------------------------------
  // The idle screensaver
  //
  // Off unless the user asks for it, and it only runs once Omarchy's own
  // screensaver has been switched off. `omarchy toggle screensaver` writes a
  // flag; Omarchy's launcher reads it, and this reads the same flag, so turning
  // this on without turning theirs off cannot end with two screensavers on one
  // screen.
  //
  // The flag is only ever READ here. Writing it would make this plugin the owner
  // of state it cannot clean up: remove the plugin and the machine is left with
  // no screensaver at all and nothing left to explain why.
  // ----------------------------------------------------------------------
  property bool omarchyScreensaverOff: false
  property bool leverKnown: false
  property bool warnedAboutLever: false
  property bool screensaverShowing: false

  readonly property string leverPath:
    home + "/.local/state/omarchy/toggles/screensaver-off"

  readonly property bool screensaverArmed:
    settings.screensaver && omarchyScreensaverOff

  // A flag file that may well not exist, so it is asked rather than watched: a
  // FileView cannot arm on a path that is not there. `test -e` rather than the
  // toggle helper because this runs forever, and the flag's location is
  // documented ("a flag file under ~/.local/state/omarchy/toggles/").
  Process {
    id: saverLever
    command: ["/usr/bin/test", "-e", root.leverPath]
    onExited: function(code) {
      root.omarchyScreensaverOff = code === 0
      root.leverKnown = true
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (!saverLever.running) saverLever.running = true
  }

  // The same primitive the shell's own idle service uses, with the same timeout
  // read from the same file.
  IdleMonitor {
    id: idleMonitor
    enabled: root.screensaverArmed
    timeout: settings.idleScreensaverSeconds
    respectInhibitors: true

    onIsIdleChanged: {
      if (!root.screensaverArmed) {
        root.screensaverShowing = false
        // The one moment the user is otherwise left guessing: the setting is on,
        // the desktop went idle, and nothing happened. Said once, not per cycle.
        if (idleMonitor.isIdle && settings.screensaver && leverKnown
            && !omarchyScreensaverOff && !root.warnedAboutLever) {
          root.warnedAboutLever = true
          console.warn("fractal: screensaver is on, but Omarchy's is on too;"
                       + " run `omarchy toggle screensaver` or this will not appear")
        }
        return
      }
      root.screensaverShowing = idleMonitor.isIdle
    }
  }

  // The screensaver's own phase, driven only while it is up. Same reason as
  // above: the wallpaper's timer stops whenever the desktop is covered, and a
  // screensaver is as covered as it gets.
  property real saverPhase: 0

  onScreensaverShowingChanged: if (screensaverShowing) saverPhase = 0

  Timer {
    interval: Math.max(16, Math.round(1000 / settings.fps))
    repeat: true
    running: root.screensaverShowing
    onTriggered: root.saverPhase = (root.saverPhase + interval / root.loopMs) % 1
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
        "screensaver <on|off>   run this fractal as the idle screensaver instead of",
        "                       Omarchy's. Needs theirs off first -- run",
        "                       `omarchy toggle screensaver` -- or both would show",
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

    function screensaver(value: string): string {
      return root.setScreensaver(value)
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

  // The screensaver is the one setting with a precondition, so it takes its own
  // setter rather than going through setFlag. Turning this on while Omarchy's
  // own screensaver is still enabled would put two of them on the same screen,
  // and a refusal naming the command is more use than a silent double.
  function setScreensaver(value) {
    if (value === "get" || value === "")
      return settings.screensaver ? "true" : "false"
    if (value === "on" || value === "true") {
      settings.set({ screensaver: true })
      // Deliberately no advice here. The flag is read on a timer, so any message
      // about it would be based on a reading up to a few seconds old -- and it
      // is wrong in exactly the case it exists for, the user who runs
      // `omarchy toggle screensaver` and this back to back. The gate in
      // `screensaverArmed` is what prevents two screensavers, and it is exact.
      return "true"
    }
    if (value === "off" || value === "false") {
      settings.set({ screensaver: false })
      screensaverShowing = false
      return "false"
    }
    return "usage: screensaver get|on|off"
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

  // One parked screensaver window per screen. Parked rather than summoned: a
  // layer window built after the shell's scene exists never maps, and this one
  // has to appear on a timer, unattended. Hidden, it costs nothing.
  Variants {
    model: Quickshell.screens

    Scope {
      id: saverScope
      required property var modelData

      ScreensaverWindow {
        screen: saverScope.modelData
        anchors { top: true; bottom: true; left: true; right: true }
        shown: root.screensaverShowing
        onDismissed: root.screensaverShowing = false

        // Handed over inside a Component, exactly as the wallpaper's scene is.
        // Reading `point` from a property binding on the window instead made QML
        // report a binding loop on `point`; in here it does not.
        scene: Component {
          MandelbrotZoom {
            aspect: saverScope.modelData.height / Math.max(1, saverScope.modelData.width)
            phase: root.saverPhase
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
