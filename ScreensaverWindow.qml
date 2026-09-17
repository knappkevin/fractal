import Quickshell
import Quickshell.Wayland
import QtQuick

// The screensaver: the same fractal as the wallpaper, fullscreen on the Overlay
// layer, above every window.
//
// Shaped exactly like SceneWindow -- a parked layer surface taking a scene
// Component -- because that shape is the one that does not trip QML's binding
// loop detection. Handing the scene its inputs as properties on this window
// instead made QML report a binding loop on `point`, every load.
//
// Created and parked by the service rather than mounted on demand through the
// host's overlay loader: a layer window built after the shell's scene exists
// never maps, and this one has to appear on a timer, unattended.
PanelWindow {
  id: win

  property Component scene: null
  property bool shown: false

  // Any click dismisses, and it does not reach the window underneath -- the
  // usual screensaver bargain, and the one dismissal that does not depend on the
  // idle monitor agreeing with us.
  signal dismissed()

  WlrLayershell.namespace: "omarchy-fractal-screensaver"
  WlrLayershell.layer: WlrLayer.Overlay

  // None, deliberately. A keypress should reach whatever is underneath and count
  // as activity, which is what the idle monitor is watching for. Taking keyboard
  // focus would swallow that keypress and leave nothing to notice the user came
  // back -- the whole dismissal would then rest on this MouseArea.
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  color: "black"

  visible: shown
  anchors { top: true; bottom: true; left: true; right: true }

  MouseArea {
    anchors.fill: parent
    onClicked: win.dismissed()
  }

  Loader {
    anchors.fill: parent
    active: win.shown
    sourceComponent: win.scene
  }
}
