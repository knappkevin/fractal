import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The plugin's control panel, opened by `omarchy-shell fractal menu`.
//
// It belongs to the service rather than being a `panel` or `menu` entry point,
// so the window exists exactly while the service does and the whole command
// surface stays in one place -- the shape knappkevin.terminal-wallpaper uses.
//
// Every control writes through the service, which owns the same functions the
// IPC verbs call, so the two can never disagree about what a setting means.
PanelWindow {
  id: menu

  // Set by the service that owns this window.
  property var service: null

  readonly property bool showing: service !== null && service.menuOpen

  // The number is the degree of z^d + c. Degree 2 is the Mandelbrot set; 3 and 4
  // are the Multibrots, named for that same number, so the row can say what it is
  // instead of showing a bare 2, 3 or 4.
  function degreeOption(d) {
    if (d === 2) return { value: "2", label: "Mandelbrot Set (z² + c)" }
    if (d === 3) return { value: "3", label: "Cubic Multibrot (z³ + c)" }
    if (d === 4) return { value: "4", label: "Quartic Multibrot (z⁴ + c)" }
    return { value: String(d), label: "Degree " + d }
  }

  visible: showing
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "omarchy-fractal-menu"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: showing ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // Clicking off the card closes, as does Escape below.
  Rectangle {
    anchors.fill: parent
    color: Color.menu.scrim
    MouseArea {
      anchors.fill: parent
      onClicked: menu.service.closeMenu()
    }
  }

  BorderSurface {
    id: card

    width: Math.min(parent.width - Style.space(64), Style.space(460))
    height: Math.min(parent.height - Style.space(48),
                     content.implicitHeight + card.contentTopInset + card.contentBottomInset)
    anchors.centerIn: parent
    color: Color.menu.background
    borderSpec: Border.localOrSurfaceSpec("menu", "border", Color.menu.border,
                                          Color.menu.border, Math.max(1, Style.space(2)))
    radius: Style.cornerRadius
    padding: Style.spacing.panelPadding

    // Swallow clicks that land on the card so they do not reach the scrim.
    MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }

    Item {
      id: keyCatcher
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset

      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          menu.service.closeMenu()
          event.accepted = true
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: flick.width
          spacing: Style.spacing.lg

          // ------------------------------------------------------------------
          Text {
            text: "Fractal"
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            text: menu.service.point + " · " + menu.service.mode + " · "
                  + Math.round(menu.service.loopMs / 1000) + "s a loop"
            color: Color.menu.text
            opacity: 0.5
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          // ------------------------------------------------------------------
          MenuSection {
            title: "Zoom"

            SliderRow {
              view: flick
              label: "Speed"
              value: menu.service.settingsStore.speed
              minimum: menu.service.settingsStore.rangeFor("speed").minimum
              maximum: menu.service.settingsStore.rangeFor("speed").maximum
              step: menu.service.settingsStore.rangeFor("speed").step
              onEdited: function(v) { menu.service.setNumber(String(v), "speed") }
            }

            SliderRow {
              view: flick
              label: "Colour bands"
              value: menu.service.settingsStore.bands
              minimum: menu.service.settingsStore.rangeFor("bands").minimum
              maximum: menu.service.settingsStore.rangeFor("bands").maximum
              step: menu.service.settingsStore.rangeFor("bands").step
              onEdited: function(v) { menu.service.setNumber(String(v), "bands") }
            }

            SliderRow {
              view: flick
              label: "Resolution"
              value: menu.service.settingsStore.scale
              minimum: menu.service.settingsStore.rangeFor("scale").minimum
              maximum: menu.service.settingsStore.rangeFor("scale").maximum
              step: menu.service.settingsStore.rangeFor("scale").step
              onEdited: function(v) { menu.service.setNumber(String(v), "scale") }
            }

            SliderRow {
              view: flick
              label: "Frame rate"
              integer: true
              value: menu.service.settingsStore.fps
              minimum: menu.service.settingsStore.rangeFor("fps").minimum
              maximum: menu.service.settingsStore.rangeFor("fps").maximum
              step: menu.service.settingsStore.rangeFor("fps").step
              onEdited: function(v) { menu.service.setNumber(String(v), "fps") }
            }
          }

          // ------------------------------------------------------------------
          MenuSection {
            title: "Playback"

            Toggle {
              label: "Pause"
              description: "Hold the animation still."
              checked: menu.service.settingsStore.paused
              foreground: Color.menu.text
              width: parent.width
              onClicked: menu.service.setFlag("toggle", "paused")
            }

            Toggle {
              label: "Pause when covered"
              description: "Stop drawing while windows cover the whole screen."
              checked: menu.service.settingsStore.pauseWhenCovered
              foreground: Color.menu.text
              width: parent.width
              onClicked: menu.service.setFlag("toggle", "pauseWhenCovered")
            }

            Toggle {
              label: "Random point each start"
              description: "Begin on a different place in the set every launch."
              checked: menu.service.settingsStore.randomPoint
              foreground: Color.menu.text
              width: parent.width
              onClicked: menu.service.setFlag("toggle", "randomPoint")
            }
          }

          // ------------------------------------------------------------------
          MenuSection {
            title: "Point"

            Dropdown {
              label: "Drawing"
              width: parent.width
              value: menu.service.mode
              // Titles, not the stored words: "mandel" and "julia" are what the
              // setting holds, not what the sets are called.
              options: [
                { value: "mandel", label: "Mandelbrot Set" },
                { value: "julia", label: "Julia Set" },
                { value: "both", label: "Both" }
              ]
              onChanged: function(v) { menu.service.setMode(v) }
            }

            Dropdown {
              label: "Degree"
              width: parent.width
              value: String(menu.service.settingsStore.powers)
              options: menu.service.pointDegrees.map(function(d) { return menu.degreeOption(d) })
              onChanged: function(v) { menu.service.setPower(v) }
            }

            Dropdown {
              label: "Place in the set"
              width: parent.width
              value: menu.service.place
              options: menu.service.pointPlaces
              onChanged: function(v) { menu.service.choose(v) }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md

              Button {
                text: "Next"
                foreground: Color.menu.text
                onClicked: menu.service.chooseNext()
              }

              Button {
                text: "Surprise me"
                foreground: Color.menu.text
                onClicked: menu.service.chooseRandom()
              }
            }
          }

          // ------------------------------------------------------------------
          MenuSection {
            title: "System"

            Toggle {
              label: "Screensaver"
              description: "Run this fractal as the idle screensaver. Turning "
                           + "this on switches Omarchy's own screensaver off, "
                           + "since only one of them can hold the idle timeout."
              checked: menu.service.settingsStore.screensaver
              foreground: Color.menu.text
              width: parent.width
              onClicked: menu.service.setScreensaver(
                           menu.service.settingsStore.screensaver ? "off" : "on")
            }
          }

          // ------------------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              text: "Restore defaults"
              foreground: Color.menu.text
              onClicked: menu.service.resetSettings()
            }

            Button {
              text: "Change wallpaper"
              foreground: Color.menu.text
              onClicked: menu.service.changeWallpaper()
            }

            Button {
              text: "Close"
              foreground: Color.menu.text
              onClicked: menu.service.closeMenu()
            }
          }
        }
      }
    }
  }
}