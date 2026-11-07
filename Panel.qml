import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Motion.js" as Motion

// Settings for the workspace styler, opened by right-clicking the row.
//
// Two tabs: Look picks the indicator style, Motion picks the switch effect
// and its timing. Every choice is a card with a live preview that keeps
// switching between fake workspaces, so what you pick is what you saw.
// Changes are written to this widget's entry in shell.json at once.
//
// Keys: h/l or arrows walk the cards of the open tab, 1/2 switch tabs,
// Escape closes, Tab moves to the neighbouring bar panel.
Panel {
  id: root
  moduleName: "io.github.sanchokusika.workspace-styler"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property var cfg: hostWidget ? hostWidget.cfg : Motion.normalize({})
  readonly property var hypr: hostWidget ? hostWidget.hypr : ({ ok: false, enabled: true, ms: 0, curveName: "", curve: [0, 0.75, 0.15, 1], curves: [] })
  readonly property int previewMs: hostWidget ? hostWidget.transitionMs : 300
  readonly property var previewCurve: hostWidget ? hostWidget.transitionCurve : Motion.DEFAULTS.bezier

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property string tab: "look"

  // ---- Live preview data: five fake workspaces, some occupied, visited in
  //      an order that mixes short hops, long jumps and both directions.
  readonly property var demoSlots: [
    { key: 1, label: "1", occupied: true, guest: false },
    { key: 2, label: "2", occupied: true, guest: false },
    { key: 3, label: "3", occupied: false, guest: false },
    { key: 4, label: "4", occupied: true, guest: false },
    { key: 5, label: "5", occupied: false, guest: false, urgent: true }
  ]
  readonly property var demoOrder: [1, 2, 4, 3, 5, 2, 1, 4]
  property int demoStep: 0
  readonly property int demoKey: demoOrder[demoStep % demoOrder.length]

  Timer {
    interval: Math.max(900, root.previewMs + 750)
    running: root.opened
    repeat: true
    onTriggered: root.demoStep++
  }

  function save(values) {
    if (root.hostWidget) root.hostWidget.saveSettings(values)
  }

  function open() {
    if (root.hostWidget) root.hostWidget.readHyprland()
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function step(list, current, dx) {
    var i = list.indexOf(current)
    return list[(i + dx + list.length) % list.length]
  }

  function moveSelection(dx) {
    if (root.tab === "look") root.save({ style: root.step(Motion.STYLES, root.cfg.style, dx) })
    else root.save({ effect: root.step(Motion.EFFECTS, root.cfg.effect, dx) })
  }

  function curveLabel(name) {
    if (name.indexOf("hypr:") === 0) return name.slice(5)
    return strings.t("curve." + name, name)
  }

  readonly property var curveOptions: {
    var list = []
    for (var i = 0; i < Motion.BUILTIN_CURVES.length; i++) list.push(Motion.BUILTIN_CURVES[i].value)
    var seen = {}
    for (var j = 0; j < root.hypr.curves.length; j++) {
      var name = root.hypr.curves[j].name
      if (seen[name]) continue
      seen[name] = true
      list.push("hypr:" + name)
    }
    list.push("custom")
    return list
  }

  // ---- A pickable card with a live preview strip.
  component Card: Item {
    id: card
    property string title: ""
    property string cardStyle: "pills"
    property string cardEffect: "slide"
    property bool selected: false
    signal picked()

    implicitHeight: Style.space(78)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: card.selected
        ? Util.alpha(root.accent, 0.12)
        : (cardMouse.containsMouse ? Util.alpha(root.fg, 0.07) : Util.alpha(root.fg, 0.03))
      border.width: card.selected ? Math.max(2, Style.space(2)) : 1
      border.color: card.selected ? root.accent : Util.alpha(root.fg, cardMouse.containsMouse ? 0.4 : 0.16)

      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }

    Item {
      id: stage
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(10)
      height: Style.bar.sizeHorizontal
      clip: true

      Strip {
        anchors.centerIn: parent
        width: implicitWidth
        height: implicitHeight
        interactive: false
        slots: root.demoSlots
        activeKey: root.demoKey
        styleName: card.cardStyle
        effect: card.cardEffect
        duration: root.previewMs
        curve: root.previewCurve
        wormLag: root.cfg.wormLag
        barSize: Style.bar.sizeHorizontal
        foreground: root.fg
        accent: root.accent
        useAccent: root.cfg.accent
        showUrgent: root.cfg.urgent
        urgentColor: Commons.Color.urgent
        fontFamily: root.fontFamily
        activeGlyph: root.cfg.layoutGlyph ? "󱓻" : ""
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(8)
      textFormat: Text.PlainText
      text: card.title
      color: card.selected ? root.fg : Util.alpha(root.fg, 0.75)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: card.selected
    }

    MouseArea {
      id: cardMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: card.picked()
    }
  }

  // ---- A labelled slider row that saves when released.
  component SliderRow: Column {
    id: sliderRow
    property string label: ""
    property string valueText: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 1
    property real stepSize: 0.01
    property alias liveValue: slider.liveValue
    signal committed(real value)

    spacing: Style.space(4)

    Item {
      width: parent.width
      height: rowLabel.implicitHeight

      Text {
        id: rowLabel
        anchors.left: parent.left
        textFormat: Text.PlainText
        text: sliderRow.label
        color: Qt.darker(root.fg, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      Text {
        anchors.right: parent.right
        anchors.baseline: rowLabel.baseline
        textFormat: Text.PlainText
        text: sliderRow.valueText
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    PanelSlider {
      id: slider
      width: parent.width
      bar: root.bar
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: sliderRow.stepSize
      value: sliderRow.value
      onReleased: function(v) { sliderRow.committed(v) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.moveSelection(dx) }
      onTextKey: function(t) {
        if (t === "1") root.tab = "look"
        else if (t === "2") root.tab = "motion"
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroller.width
          spacing: Style.space(12)

          // ---- Header: title and the current setup, live.
          Item {
            width: parent.width
            height: Math.max(titleColumn.implicitHeight, hero.height)

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: strings.t("title")
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: strings.t("style." + root.cfg.style) + " · " + strings.t("effect." + root.cfg.effect)
                  + " · " + (root.previewMs > 0
                    ? strings.t("timing.ms").arg(Commons.I18n.formatNumber(root.previewMs))
                    : strings.t("timing.instant"))
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: hero
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: heroStrip.implicitWidth + Style.space(24)
              height: Style.bar.sizeHorizontal + Style.space(8)
              radius: Style.cornerRadius
              color: Commons.Color.bar.background
              border.width: 1
              border.color: Util.alpha(root.fg, 0.14)

              Strip {
                id: heroStrip
                anchors.centerIn: parent
                width: implicitWidth
                height: implicitHeight
                interactive: false
                slots: root.demoSlots
                activeKey: root.demoKey
                styleName: root.cfg.style
                effect: root.cfg.effect
                duration: root.previewMs
                curve: root.previewCurve
                wormLag: root.cfg.wormLag
                barSize: Style.bar.sizeHorizontal
                foreground: Commons.Color.bar.text
                accent: root.accent
                useAccent: root.cfg.accent
                showUrgent: root.cfg.urgent
                urgentColor: Commons.Color.urgent
                fontFamily: root.fontFamily
                activeGlyph: root.cfg.layoutGlyph ? "󱓻" : ""
              }
            }
          }

          ButtonGroup {
            options: [
              { value: "look", label: strings.t("tab.look") },
              { value: "motion", label: strings.t("tab.motion") }
            ]
            value: root.tab
            focusable: false
            foreground: root.fg
            accent: root.accent
            fontFamily: root.fontFamily
            onChanged: function(v) { root.tab = v }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          // ================= Look =================
          Column {
            visible: root.tab === "look"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("section.style")
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Grid {
              id: styleGrid
              width: parent.width
              columns: 3
              spacing: Style.space(8)
              readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: Motion.STYLES

                Card {
                  required property string modelData
                  width: styleGrid.cellWidth
                  title: strings.t("style." + modelData)
                  cardStyle: modelData
                  cardEffect: root.cfg.effect
                  selected: root.cfg.style === modelData
                  onPicked: root.save({ style: modelData })
                }
              }
            }

            Toggle {
              width: parent.width
              label: strings.t("option.accent")
              description: strings.t("option.accentHint")
              checked: root.cfg.accent
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.save({ accent: !root.cfg.accent })
            }

            Toggle {
              width: parent.width
              visible: root.cfg.style === "numbers" || root.cfg.style === "underline"
              label: strings.t("option.glyph")
              description: strings.t("option.glyphHint")
              checked: root.cfg.layoutGlyph
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.save({ layoutGlyph: !root.cfg.layoutGlyph })
            }

            Toggle {
              width: parent.width
              label: strings.t("option.peek")
              description: strings.t("option.peekHint")
              checked: root.cfg.peek
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.save({ peek: !root.cfg.peek })
            }

            Toggle {
              width: parent.width
              label: strings.t("option.urgent")
              description: strings.t("option.urgentHint")
              checked: root.cfg.urgent
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.save({ urgent: !root.cfg.urgent })
            }

            SliderRow {
              width: parent.width
              label: strings.t("option.persistent")
              valueText: Commons.I18n.formatNumber(Math.round(liveValue))
              value: root.cfg.persistent
              minimum: 1
              maximum: 10
              stepSize: 1
              onCommitted: function(v) { root.save({ persistent: Math.round(v) }) }
            }
          }

          // ================= Motion =================
          Column {
            visible: root.tab === "motion"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: strings.t("section.effect")
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Grid {
              id: effectGrid
              width: parent.width
              columns: 4
              spacing: Style.space(8)
              readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

              Repeater {
                model: Motion.EFFECTS

                Card {
                  required property string modelData
                  width: effectGrid.cellWidth
                  title: strings.t("effect." + modelData)
                  cardStyle: root.cfg.style
                  cardEffect: modelData
                  selected: root.cfg.effect === modelData
                  onPicked: root.save({ effect: modelData })
                }
              }
            }

            SliderRow {
              width: parent.width
              visible: root.cfg.effect === "worm"
              label: strings.t("option.wormLag")
              valueText: Commons.I18n.formatNumber(Math.round(liveValue * 100)) + "%"
              value: root.cfg.wormLag
              minimum: 0.1
              maximum: 0.7
              stepSize: 0.05
              onCommitted: function(v) { root.save({ wormLag: Math.round(v * 100) / 100 }) }
            }

            PanelSeparator { width: parent.width; foreground: root.fg }

            PanelSectionHeader {
              text: strings.t("section.timing")
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            ButtonGroup {
              options: [
                { value: "hyprland", label: strings.t("timing.hyprland") },
                { value: "custom", label: strings.t("timing.custom") }
              ]
              value: root.cfg.timing
              focusable: false
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function(v) { root.save({ timing: v }) }
            }

            // Synced: what Hyprland runs, read from hyprctl.
            Row {
              visible: root.cfg.timing === "hyprland"
              width: parent.width
              spacing: Style.space(14)

              CurvePlot {
                id: syncPlot
                width: Style.space(84)
                height: Style.space(84)
                points: root.hypr.curve
                foreground: root.fg
                accent: root.accent
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - syncPlot.width - parent.spacing
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: !root.hypr.ok ? strings.t("timing.hyprUnknown")
                    : (!root.hypr.enabled || Style.reduceMotion) ? strings.t("timing.hyprOff")
                    : strings.t("timing.hyprInfo").arg(Commons.I18n.formatNumber(root.hypr.ms)).arg(root.hypr.curveName)
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: strings.t("timing.hyprHint")
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Custom: duration, curve, and optionally your own points.
            Column {
              visible: root.cfg.timing === "custom"
              width: parent.width
              spacing: Style.space(10)

              SliderRow {
                width: parent.width
                label: strings.t("option.duration")
                valueText: strings.t("timing.ms").arg(Commons.I18n.formatNumber(Math.round(liveValue)))
                value: root.cfg.duration
                minimum: 50
                maximum: 1500
                stepSize: 10
                onCommitted: function(v) { root.save({ duration: Math.round(v) }) }
              }

              PanelSectionHeader {
                text: strings.t("section.curve")
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Row {
                width: parent.width
                spacing: Style.space(14)

                Flow {
                  id: curveFlow
                  width: parent.width - customPlot.width - parent.spacing
                  spacing: Style.space(6)

                  Repeater {
                    model: root.curveOptions

                    Button {
                      required property string modelData
                      text: root.curveLabel(modelData)
                      selected: root.cfg.curve === modelData
                      bordered: true
                      foreground: root.fg
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: {
                        if (modelData === "custom" && root.cfg.curve !== "custom" && root.hostWidget) {
                          // Start your own curve from the one you were on.
                          var from = root.hostWidget.curveFor(root.cfg.curve, root.cfg.bezier)
                          root.save({ curve: "custom", bezier: from.slice(0, 4) })
                        } else {
                          root.save({ curve: modelData })
                        }
                      }
                    }
                  }
                }

                CurvePlot {
                  id: customPlot
                  width: Style.space(96)
                  height: Style.space(96)
                  points: root.cfg.curve === "custom"
                    ? [x1Row.liveValue, y1Row.liveValue, x2Row.liveValue, y2Row.liveValue]
                    : (root.hostWidget ? root.hostWidget.curveFor(root.cfg.curve, root.cfg.bezier) : Motion.DEFAULTS.bezier)
                  foreground: root.fg
                  accent: root.accent
                }
              }

              Grid {
                visible: root.cfg.curve === "custom"
                width: parent.width
                columns: 2
                columnSpacing: Style.space(14)
                rowSpacing: Style.space(8)
                readonly property real cellWidth: (width - columnSpacing) / 2

                SliderRow {
                  id: x1Row
                  width: parent.cellWidth
                  label: "X1"
                  valueText: Commons.I18n.formatNumber(liveValue, 2)
                  value: root.cfg.bezier[0]
                  minimum: 0; maximum: 1; stepSize: 0.01
                  onCommitted: function(v) { root.save({ bezier: [v, root.cfg.bezier[1], root.cfg.bezier[2], root.cfg.bezier[3]] }) }
                }
                SliderRow {
                  id: y1Row
                  width: parent.cellWidth
                  label: "Y1"
                  valueText: Commons.I18n.formatNumber(liveValue, 2)
                  value: root.cfg.bezier[1]
                  minimum: -0.5; maximum: 1.5; stepSize: 0.01
                  onCommitted: function(v) { root.save({ bezier: [root.cfg.bezier[0], v, root.cfg.bezier[2], root.cfg.bezier[3]] }) }
                }
                SliderRow {
                  id: x2Row
                  width: parent.cellWidth
                  label: "X2"
                  valueText: Commons.I18n.formatNumber(liveValue, 2)
                  value: root.cfg.bezier[2]
                  minimum: 0; maximum: 1; stepSize: 0.01
                  onCommitted: function(v) { root.save({ bezier: [root.cfg.bezier[0], root.cfg.bezier[1], v, root.cfg.bezier[3]] }) }
                }
                SliderRow {
                  id: y2Row
                  width: parent.cellWidth
                  label: "Y2"
                  valueText: Commons.I18n.formatNumber(liveValue, 2)
                  value: root.cfg.bezier[3]
                  minimum: -0.5; maximum: 1.5; stepSize: 0.01
                  onCommitted: function(v) { root.save({ bezier: [root.cfg.bezier[0], root.cfg.bezier[1], root.cfg.bezier[2], v] }) }
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.fg }

          Item {
            width: parent.width
            height: resetButton.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: strings.t("hint.keys")
              color: Qt.darker(root.fg, 1.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              id: resetButton
              anchors.right: parent.right
              text: strings.t("action.reset")
              bordered: true
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: if (root.hostWidget) root.hostWidget.resetSettings()
            }
          }
        }
      }
    }
  }
}
