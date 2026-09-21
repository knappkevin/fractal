pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

import "mandelbrot"
import "menu"
import qs.Ui

// Draws an endless fractal zoom above the wallpaper and below every window.
//
// Picking the plugin's image in the background switcher turns it on; any other
// wallpaper turns it off. The wallpaper renderer is untouched: this owns a
// click-through surface on the Bottom layer directly above it.
//
// Layout: the settings store is Settings.qml, the picker image Thumbnail.qml,
// the theme palette ThemeColors.qml, the layer surface SceneWindow.qml, the
// settings panel menu/Menu.qml, and the fractal itself under mandelbrot/. This
// file wires them together and holds the command surface, which cannot live
// elsewhere -- see the note above IpcHandler.
Item {
  id: root

  // Injected by the host, after Component.onCompleted. Not safe during construction.
  property var shell
  property var manifest

  readonly property string pluginId:
    manifest && manifest.id ? String(manifest.id) : "knappkevin.fractal"

  // Injected by the host, with the environment as the fallback for a host that
  // does not inject it. The image picker is a program in this tree, so anything
  // that opens a GUI from here needs to be told where the tree is.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""

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

  function isMarker(path) {
    return String(path).split("/").pop().toLowerCase().match(markerPattern) !== null
  }

  readonly property bool active: isMarker(wallpaper)

  // ----------------------------------------------------------------------
  // Surviving a theme switch.
  //
  // Omarchy replaces the theme directory, rewrites theme.name, and only then
  // picks the new theme's background. Our marker lived in the directory it just
  // replaced, so that pick cannot see it and falls back to the theme's first
  // image: choosing the effect and then changing theme loses it, which is not
  // what choosing it meant.
  //
  // The two halves of that arrive in either order -- the watch on theme.name can
  // be delivered after the shell has already been told about the new background
  // -- so each side asks the question using the other side's recency, and the
  // answer is the wallpaper we were on until a moment ago.
  // ----------------------------------------------------------------------
  property string previousWallpaper: ""
  property double backgroundChangedAt: 0
  property double themeChangedAt: 0
  property bool restoreBackground: false

  // Wide enough for the gap between the two events, which is a fraction of a
  // second, and narrow enough that a background picked by hand is not mistaken
  // for one Omarchy chose.
  readonly property int themeSwitchWindow: 1500

  onWallpaperChanged: {
    // Asked before previousWallpaper moves on: a switch to the theme's own first
    // image, moments after theme.name was rewritten, is the theme change taking
    // the background away rather than someone choosing something else.
    //
    // `active` still reads the *old* wallpaper here -- a binding that depends on
    // a changing property is not re-evaluated until after this handler -- so the
    // new value is taken from the property directly.
    if (!restoreBackground && !isMarker(wallpaper) && isMarker(previousWallpaper)
        && Date.now() - themeChangedAt < themeSwitchWindow)
      restoreBackground = true

    previousWallpaper = wallpaper
    backgroundChangedAt = Date.now()

    // The picker image follows the palette, not the wallpaper: see onReloaded.
    palette.reload()
  }

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
    mode: root.mode
    power: settings.powers
    onNamesChanged: root.onCatalogueReady()
  }

  // Which renderings the catalogue offers: the Mandelbrot set at each point, the
  // Julia set of each parameter, or both. Owned by the settings so it persists
  // with the point beside it.
  readonly property string mode: settings.mode

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
    onFinished: root.restoreWallpaper()
    }

  Menu {
    service: root
  }

  // Omarchy's background picker, the same way its own bar button opens it.
  //
  // The one process here that inherits the environment rather than being handed
  // a minimal one: this opens a GUI, through the shell's own image picker, and
  // that needs the session it is running in. Every other process this plugin
  // runs is a file or an IPC call, and is given only what it needs; see the note
  // in the README on why.
  Process {
    id: switcher
    // Environment is added to the inherited one, not a replacement: this is the
    // one process here whose child is a GUI.
    environment: ({ OMARCHY_PATH: root.omarchyPath })
    command: ["/usr/bin/bash", "-c",
              "background=$(omarchy-theme-bg-switcher); [[ -n $background ]]"
              + " && omarchy-theme-bg-set \"$background\""]
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
    if (catalogue.has(want))
      return want
    // A place rather than a rendering, which is what the panel picks: resolve it
    // to whichever rendering this mode offers for it. Only a name this mode
    // cannot draw at all -- a place outside the current degree, say -- falls
    // back to the mode's default, because showing nothing is worse.
    var julia = catalogue.base(want) + catalogue.juliaSuffix
    if (catalogue.has(julia))
      return julia
    return catalogue.has(catalogue.base(want)) ? catalogue.base(want)
                                               : catalogue.defaultVariant
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
    // A place or a rendering: the panel picks places, `point <name>` may be
    // either, and both are stored as given so the pick survives a mode change.
    if (!catalogue.knows(name))
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
    // A restore needs the image whether or not the picker offers one: it is the
    // background, not just a thumbnail.
    if (!point || (!settings.markers && !restoreBackground))
      return
    thumbnail.request(["/usr/bin/python3", pluginDir + "/tools/marker.py",
                       pluginDir + "/mandelbrot/points/" + point + ".json", "0",
                       thumbnail.outputPath].concat(palette.ramp))
  }

  // Put the effect back as the background after a theme switch took it away.
  //
  // Runs when the picker image lands, which is about a second after the switch:
  // long enough that Omarchy has finished choosing the new theme's own first
  // background, so this cannot race it. Omarchy's own command does the work --
  // the same one the background picker runs -- so the effect is restored exactly
  // as a pick would have put it there: symlink rewritten, shell told to show it.
  function restoreWallpaper() {
    if (!restoreBackground)
      return
    restoreBackground = false
    if (!point)
      return
    restoreProcess.command = ["/usr/bin/timeout", "-k", "5", "30",
                              "/usr/share/omarchy/bin/omarchy-theme-bg-set",
                              thumbnail.outputPath]
    restoreProcess.running = true
  }

  Process {
    id: restoreProcess
    clearEnvironment: true
    environment: ({
      HOME: root.home,
      PATH: "/usr/share/omarchy/bin:/usr/bin:/bin",
      XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
      WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY")
    })
    onExited: function(code) {
      if (code !== 0)
        console.warn("fractal: could not put the background back after the theme"
                     + " change (exit " + code + ")")
    }
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
  property bool stayAwake: false
  property bool leverKnown: false
  property bool warnedAboutLever: false
  property bool screensaverShowing: false

  readonly property string leverPath:
    home + "/.local/state/omarchy/toggles/screensaver-off"

  // The bar's stay-awake indicator is the other lever over the same idle timeout,
  // and it is not an idle inhibitor: a client inhibitor is what `respectInhibitors`
  // covers, a different mechanism entirely. So its flag has to be read the same way
  // the screensaver lever is, or this plugin can cover a screen the user has asked
  // to stay awake.
  readonly property string stayAwakePath:
    home + "/.local/state/omarchy/indicators/stay-awake"

  readonly property bool screensaverArmed:
    settings.screensaver && omarchyScreensaverOff && !stayAwake

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

  // The same probe one directory over. The flag can also be set while the fractal
  // is already up, and disabling the monitor does not take a window down with it,
  // so that case is dismissed here -- what Omarchy's own service does when it
  // cancels a cycle for stay-awake.
  Process {
    id: stayAwakeLever
    command: ["/usr/bin/test", "-e", root.stayAwakePath]
    onExited: function(code) {
      var held = code === 0
      if (held === root.stayAwake)
        return
      root.stayAwake = held
      if (held)
        root.screensaverShowing = false
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (!saverLever.running) saverLever.running = true
      if (!stayAwakeLever.running) stayAwakeLever.running = true
    }
  }

  // Turns Omarchy's own screensaver off, once. Its command flips a flag rather
  // than setting one, so the lever is asked first.
  Process {
    id: saverOff
    clearEnvironment: true
    environment: ({ HOME: root.home, PATH: "/usr/share/omarchy/bin:/usr/bin:/bin" })
    command: ["/usr/bin/bash", "-c",
              "omarchy-toggle-enabled screensaver-off || omarchy-toggle screensaver-off"]
    onExited: function() {
      // Read the lever back, so the gate agrees with what just happened instead
      // of waiting for the next poll.
      if (!saverLever.running)
        saverLever.running = true
    }
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
    onFileChanged: {
      root.themeChangedAt = Date.now()
      // The other half of the same question. The shell may already have been told
      // about the new background, in which case it is the wallpaper change that
      // carries the recency rather than this one.
      if (!root.restoreBackground && !root.active && root.isMarker(root.previousWallpaper)
          && Date.now() - root.backgroundChangedAt < root.themeSwitchWindow)
        root.restoreBackground = true
      root.reload()
    }
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

    // Only what the panel does not cover. Every setting is in `fractal menu`,
    // and the verbs for them still exist for scripting, but listing them here
    // was noise: the panel is how they are meant to be changed.
    function help(): string {
      return [
        "menu                   open the settings panel: every setting as a",
        "                       slider, field or switch, plus restore defaults",
        "pause <true|false|toggle>",
        "                       hold the animation still, or start it again",
        "defaults               put every setting back to its shipped value",
        "point list             the places in the set you can zoom into",
        "point <name>           zoom into that one",
        "point next             move along to the next one",
        "point random           jump to one at random now",
        "help                   this text",
        "",
        "The panel covers the settings. `fractal <setting> get` still reads one.",
      ].join("\n")
    }

    function refresh(): void {
      root.reload()
    }

    function fps(value: string): string {
      return root.setNumber(value, "fps")
    }

    function speed(value: string): string {
      return root.setNumber(value, "speed")
    }

    function scale(value: string): string {
      return root.setNumber(value, "scale")
    }

    function bands(value: string): string {
      return root.setNumber(value, "bands")
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
        return catalogue.places.join(" ")
      if (value === "next")
        return root.chooseAndReport(catalogue.next(root.point))
      if (value === "random")
        return root.chooseAndReport(catalogue.another(root.point))
      if (!catalogue.knows(value))
        return "unknown point '" + value + "'; try: fractal point list"
      return root.chooseAndReport(value)
    }

    function screensaver(value: string): string {
      return root.setScreensaver(value)
    }

    function power(value: string): string {
      return root.setPower(value)
    }


    function set(value: string): string {
      return root.setMode(value)
    }

    function defaults(): string {
      root.resetSettings()
      return "defaults restored"
    }

    // Declared with no parameters on purpose: Quickshell rejects a call that
    // does not supply every declared argument, and `fractal menu` has to work
    // bare. It toggles, which is what a menu command wants to do anyway, and the
    // panel also closes on Escape or a click outside.
    function menu(): string {
      if (root.menuOpen)
        root.closeMenu()
      else
        root.openMenu()
      return root.menuOpen ? "open" : "closed"
    }
  }

  function chooseAndReport(name) {
    choose(name)
    return point
  }

  function chooseNext() {
    return chooseAndReport(catalogue.next(point))
  }

  function chooseRandom() {
    return chooseAndReport(catalogue.another(point))
  }

  // ----------------------------------------------------------------------
  // Menu
  //
  // The panel is a window of this service rather than a `panel` or `menu` entry
  // point, so it exists exactly while the service does and the command surface
  // stays in one place -- the shape knappkevin.terminal-wallpaper uses. Every
  // control in it calls the same functions the IPC verbs do, so the two cannot
  // drift apart.
  // ----------------------------------------------------------------------
  property bool menuOpen: false

  // The settings store, for the panel: it is an id rather than a property, so
  // another file cannot reach it without this.
  readonly property alias settingsStore: settings

  // What the panel needs from the catalogue, which is likewise an id.
  readonly property var pointPlaces: catalogue.places

  // Where the current rendering sits, which is what the panel's place row shows
  // and selects. The rendering itself is the Drawing row's business.
  readonly property string place: catalogue.base(point)

  // The degrees the catalogue can actually draw, for the panel's control.
  readonly property var pointDegrees: catalogue.availablePowers

  function openMenu() {
    menuOpen = true
  }

  function closeMenu() {
    menuOpen = false
  }

  // Hand the desktop back to the stock switcher. The panel closes first: both
  // surfaces live on the overlay layer, and leaving ours up would leave the
  // switcher somewhere behind it.
  function changeWallpaper() {
    closeMenu()
    if (!switcher.running)
      switcher.running = true
  }

  // Every setting back to its shipped value, then re-read and re-rendered: the
  // point and the rendering may both have moved, so the picker image is stale.
  function resetSettings() {
    settings.reset()
    sessionPoint = resolvedPoint()
    phase = 0
    reload()
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

  function setNumber(value, key) {
    var range = settings.rangeFor(key)
    if (value !== "get") {
      var n = Number(value)
      if (!(isFinite(n) && n >= range.minimum && n <= range.maximum))
        return "usage: " + key + " get|<" + range.minimum + " to " + range.maximum + ">"
      var patch = {}
      patch[key] = range.integer ? Math.round(n) : n
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
      // Omarchy's own screensaver would win the same idle timeout and nothing of
      // ours would appear. Its lever is a flag file and its command is a toggle,
      // so this asks the lever first rather than flipping it blindly.
      if (!saverOff.running)
        saverOff.running = true
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

  // Switches which rendering the catalogue offers, carrying the current pick
  // across: `julia` shows the same point's Julia set, `mandel` the Mandelbrot
  // one, and `both` leaves the pick alone and just offers all twenty-four.
  // Switches family. A pick carries across by name where the new degree offers
  // that name, and falls back to that degree's own default where it does not.
  function setPower(value) {
    if (value === "get" || value === "")
      return String(settings.powers)
    var n = Math.round(Number(value))
    if (n !== 2 && n !== 3 && n !== 4)
      return "usage: power get|2|3|4"
    // Refuse a degree with no points rather than accepting it and quietly
    // drawing another one.
    if (catalogue.availablePowers.indexOf(n) < 0)
      return "no degree " + n + " points in the catalogue; have " + catalogue.availablePowers.join(" ")
    settings.set({ power: n })
    sessionPoint = resolvedPoint()
    phase = 0
    wantThumbnail()
    return String(n)
  }


  function setMode(value) {
    if (value === "get" || value === "")
      return mode
    if (value !== "mandel" && value !== "julia" && value !== "both")
      return "usage: set get|mandel|julia|both"

    // Resolved in the mode we are leaving, so the pick is still a valid name.
    var here = resolvedPoint()
    var want = here
    if (value === "julia" && !catalogue.isJulia(here))
      want = here + catalogue.juliaSuffix
    else if (value === "mandel" && catalogue.isJulia(here))
      want = catalogue.base(here)

    settings.set({ mode: value, point: want })
    sessionPoint = want
    phase = 0
    wantThumbnail()
    return value
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

  // ----------------------------------------------------------------------
  // Double click on the desktop
  //
  // The effect's own surface has an empty input region on purpose, so the
  // wallpaper's own gestures pass underneath it to Omarchy's picker. This is a
  // second, transparent surface on the same layer as the wallpaper that catches
  // the gesture first and opens the panel instead -- but only while the effect
  // *is* the background. With any other image chosen the plugin is not
  // responsible for the desktop and this must not be in the way.
  // ----------------------------------------------------------------------
  Variants {
    model: Quickshell.screens

    Scope {
      id: desktopScope
      required property var modelData

      PanelWindow {
        id: desktop
        screen: desktopScope.modelData

        visible: root.active
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        updatesEnabled: true
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "omarchy-fractal-input"
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        ScreenMoveRemap {
          window: desktop
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onDoubleClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
              root.openMenu()
            else
              root.changeWallpaper()
            mouse.accepted = true
          }
        }
      }
    }
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
