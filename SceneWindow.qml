import Quickshell
import Quickshell.Wayland
import QtQuick

// One click-through layer surface on the Bottom layer, directly above the
// wallpaper renderer. The wallpaper itself is left alone, so its transitions
// and the double click gestures on the desktop keep working.
PanelWindow {
  id: win

  property Component scene: null
  property bool shown: false

  WlrLayershell.namespace: "omarchy-fractal"
  WlrLayershell.layer: WlrLayer.Bottom
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  color: "black"

  // Empty input region, or the surface swallows the wallpaper's double click
  // gestures, which are what open the background and theme switchers.
  mask: Region {}

  // Never destroyed, only hidden. updatesEnabled is left alone: a parked layer
  // surface can lose its buffer and leave a black desktop.
  visible: shown && !remap.remapping

  // Hyprland leaves a mapped layer surface at its old global position when its
  // monitor moves, so unmap and remap it once the new position has settled.
  // Same approach as Omarchy's own Ui/ScreenMoveRemap.qml.
  Item {
    id: remap
    visible: false
    property bool remapping: false
    readonly property var scr: win.screen

    Timer {
      id: settle
      interval: 200
      onTriggered: remap.remapping = true
    }
    Timer {
      interval: 50
      running: remap.remapping
      onTriggered: remap.remapping = false
    }
    Connections {
      target: remap.scr
      function onXChanged() { settle.restart() }
      function onYChanged() { settle.restart() }
    }
  }

  // A Component, so the scene is only built while the effect is selected.
  Loader {
    anchors.fill: parent
    active: win.shown
    sourceComponent: win.scene
  }
}
