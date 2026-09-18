import QtQuick
import qs.Commons

// A titled block in the settings menu: a heading, then whatever the caller puts
// inside it. Keeps Menu.qml to a list of what the plugin offers rather than a
// wall of layout.
Column {
  id: section

  default property alias content: body.data

  property string title: ""
  property string note: ""

  width: parent ? parent.width : 0
  spacing: Style.spacing.xs

  Text {
    visible: section.title !== ""
    text: section.title
    color: Color.menu.text
    opacity: 0.65
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  Text {
    visible: section.note !== ""
    text: section.note
    color: Color.menu.text
    opacity: 0.5
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    width: parent.width
    wrapMode: Text.WordWrap
  }

  Column {
    id: body
    width: parent.width
    spacing: Style.spacing.md
  }
}