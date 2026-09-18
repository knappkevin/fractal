import QtQuick
import qs.Commons
import qs.Ui

// One numeric setting: a label, a slider for feel, and a field for the exact
// value. A slider is a poor way to hit 0.03, or any exact frame rate, so the
// field is the precise half of the pair.
//
// `value` is bound by the caller and never assigned here. Assigning it would
// destroy the binding, and a value changed anywhere else -- restore defaults, or
// the command line -- would then leave this row showing the old one.
Column {
  id: row

  // The Flickable this sits in, so the wheel scrolls the menu instead of
  // changing whichever slider the pointer happens to be over.
  property var view: null

  property string label: ""
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false

  signal edited(real value)

  width: parent ? parent.width : 0
  spacing: Style.spacing.xs

  function display(v) {
    return row.integer ? String(Math.round(v))
                       : String(Math.round(v * 10000) / 10000)
  }

  // The knob while it is being dragged, the setting otherwise: a value changed
  // elsewhere has to be visible here.
  readonly property real shown: slider.dragging ? slider.liveValue : row.value

  // Take whatever was typed, clamped to what the setter would accept, and write
  // it. The field is then corrected to what was actually taken, so a typo or an
  // out-of-range number does not sit there looking accepted.
  function commitText() {
    var n = Number(field.text)
    if (!isFinite(n)) {
      field.text = row.display(row.value)
      return
    }
    n = Math.max(row.minimum, Math.min(row.maximum, n))
    if (row.integer)
      n = Math.round(n)
    field.text = row.display(n)
    if (n !== row.value)
      row.edited(n)
  }

  // Fires for changes made anywhere, including this row's own writes, so the
  // field is always showing the value in force.
  onValueChanged: field.text = row.display(row.value)

  Text {
    text: row.label + ": " + row.display(row.shown)
    color: Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Row {
    width: parent.width
    spacing: Style.spacing.sm

    Item {
      width: parent.width - field.width - Style.spacing.sm
      implicitHeight: slider.implicitHeight

      PanelSlider {
        id: slider
        width: parent.width
        value: row.value
        minimum: row.minimum
        maximum: row.maximum
        step: row.step
        integer: row.integer
        fillColor: Color.menu.text
        onReleased: function(v) { row.edited(v) }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        onWheel: function(wheel) {
          var f = row.view
          if (!f) {
            wheel.accepted = false
            return
          }
          f.contentY = Math.max(0, Math.min(f.contentHeight - f.height,
                                            f.contentY - wheel.angleDelta.y))
          wheel.accepted = true
        }
      }
    }

    TextField {
      id: field
      width: Style.space(84)
      text: row.display(row.value)
      foreground: Color.menu.text
      onEditingFinished: row.commitText()
      Keys.onReturnPressed: row.commitText()
      Keys.onEnterPressed: row.commitText()
    }
  }
}