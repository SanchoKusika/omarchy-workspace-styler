import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Motion.js" as Motion

// A row of workspace indicators in one of the styles from Motion.js, with
// the switch between two workspaces drawn by one of its effects.
//
// One linear progress `p` runs 0 -> 1 over `duration`; every moving part is
// derived from it through `curve`, the same cubic bezier Hyprland slides the
// workspace with, so the marker lands exactly when the screen does. The worm
// runs its two ends on staggered slices of the same span, so it still ends
// on time.
//
// The bar widget feeds it real workspaces; the settings panel feeds it a
// fake row for its live previews.
Item {
  id: strip

  property var bar: null
  property bool interactive: true
  // [{ key, label, occupied, guest }]
  property var slots: []
  property int activeKey: -1
  property string activeGlyph: ""
  property string styleName: "pills"
  property string effect: "worm"
  property int duration: 280
  property var curve: [0.23, 1.0, 0.32, 1.0]
  property real wormLag: 0.35
  property bool vertical: false
  property real barSize: Style.bar.sizeHorizontal
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property bool useAccent: false
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property real guestGap: Style.space(6)
  property color urgentColor: Commons.Color.urgent
  property bool showUrgent: true

  // A workspace asking for attention breathes in the urgent color until you
  // visit it. Constant motion, so it runs linear, and not at all when
  // animations are off.
  readonly property bool anyUrgent: {
    if (!showUrgent) return false
    for (var i = 0; i < slots.length; i++) if (slots[i].urgent === true) return true
    return false
  }
  property real pulse: 1
  SequentialAnimation on pulse {
    running: strip.anyUrgent && !Style.reduceMotion
    loops: Animation.Infinite
    onRunningChanged: if (!running) strip.pulse = 1
    NumberAnimation { from: 1; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.35; to: 1; duration: 700; easing.type: Easing.InOutSine }
  }

  function isUrgent(slot) {
    return strip.showUrgent && slot && slot.urgent === true && slot.key !== strip.toKey
  }

  signal slotPressed(int key, int button)
  signal wheelMoved(int delta)

  readonly property bool minimal: styleName === "minimal"
  readonly property var m: Motion.metrics(styleName, function(px) { return Style.space(px) }, vertical, barSize)
  readonly property color markColor: useAccent ? accent : foreground
  readonly property int effectiveDuration: effect === "none" ? 0 : Math.max(0, duration)

  // ---- Transition state.
  property int fromKey: -1
  property int toKey: -1
  // Where the marker stood when a switch interrupted a running one.
  property var fromRect: null
  // Each slot's share of the wide (pill) size when the transition began.
  property var fromWeights: ({})
  property string fromLabel: ""
  property real p: 1

  function labelFor(key) {
    for (var i = 0; i < slots.length; i++) if (slots[i].key === key) return String(slots[i].label)
    return key > 0 ? String(key % 10) : ""
  }

  function snap(key) {
    anim.stop()
    fromKey = key
    toKey = key
    fromRect = null
    var w = {}
    w[key] = 1
    fromWeights = w
    fromLabel = labelFor(key)
    p = 1
  }

  function begin() {
    var next = strip.activeKey
    if (next === strip.toKey) return
    if (strip.toKey < 0 || next < 0 || strip.effectiveDuration <= 0) {
      snap(next)
      return
    }
    if (anim.running) {
      var f = strip.frame
      strip.fromRect = f.primary ? { s: f.primary.s, e: f.primary.e } : null
      strip.fromWeights = f.weightMap
      strip.fromLabel = f.e < 0.5 ? strip.fromLabel : labelFor(strip.toKey)
    } else {
      strip.fromRect = null
      var w = {}
      w[strip.toKey] = 1
      strip.fromWeights = w
      strip.fromLabel = labelFor(strip.toKey)
    }
    strip.fromKey = strip.toKey
    strip.toKey = next
    anim.stop()
    strip.p = 0
    anim.start()
  }

  onActiveKeyChanged: begin()
  Component.onCompleted: snap(activeKey)

  NumberAnimation {
    id: anim
    target: strip
    property: "p"
    from: 0
    to: 1
    duration: strip.effectiveDuration
    easing.type: Easing.Linear
  }

  // Everything drawn this frame, from p.
  readonly property var frame: compute(p, slots, fromKey, toKey, fromRect, fromWeights, m, effect, curve, wormLag, guestGap)

  function compute(p, slots, fromKey, toKey, fromRect, fromWeights, m, effect, curve, wormLag, guestGap) {
    var n = slots.length
    var e = Motion.bezier(curve, p)
    var weights = []
    var weightMap = {}
    for (var i = 0; i < n; i++) {
      var key = slots[i].key
      var w0 = fromWeights[key] || 0
      var w1 = key === toKey ? 1 : 0
      var w = Math.max(0, Math.min(1, w0 + (w1 - w0) * e))
      weights.push(w)
      weightMap[key] = w
    }

    var out = { e: e, weights: weights, weightMap: weightMap, starts: [], sizes: [], total: 0, markers: [], primary: null }
    if (!m) return out

    var pos = 0
    for (var j = 0; j < n; j++) {
      if (j > 0) pos += m.spacing
      if (j > 0 && slots[j].guest && !slots[j - 1].guest) pos += guestGap
      out.starts.push(pos)
      var size = m.slotMin + (m.slotMax - m.slotMin) * weights[j]
      out.sizes.push(size)
      pos += size
    }
    out.total = pos

    function indexOfKey(k) {
      for (var q = 0; q < n; q++) if (slots[q].key === k) return q
      return -1
    }

    // A workspace that has just gone (an emptied one Hyprland destroyed)
    // still has a place to slide from: where it would sit by number.
    function rectAt(k) {
      var idx = indexOfKey(k)
      if (idx === -1) {
        var at = pos
        for (var r = 0; r < n; r++) {
          if (!slots[r].guest && slots[r].key > k) { at = out.starts[r]; break }
        }
        return { s: at, e: at + m.markMin }
      }
      var c = out.starts[idx] + out.sizes[idx] / 2
      var mm = m.markMin + (m.markMax - m.markMin) * weights[idx]
      return { s: c - mm / 2, e: c + mm / 2 }
    }

    var A = fromRect || rectAt(fromKey)
    var B = rectAt(toKey)
    var lerp = Motion.lerp
    var bell = Math.sin(Math.PI * Math.max(0, Math.min(1, e)))

    if (effect === "worm") {
      var lag = Math.max(0.05, Math.min(0.8, wormLag))
      var lead = Motion.bezier(curve, Math.min(1, p / (1 - lag)))
      var trail = Motion.bezier(curve, Math.max(0, (p - lag) / (1 - lag)))
      var forward = B.s >= A.s
      out.markers.push({
        s: lerp(A.s, B.s, forward ? trail : lead),
        e: lerp(A.e, B.e, forward ? lead : trail),
        cross: 1, opacity: 1, scale: 1, shift: 0
      })
    } else if (effect === "comet") {
      // Ghosts run the same curve a little later each and fade along the
      // way, so the marker draws a tail that has burnt out by arrival.
      var ghosts = 4
      for (var g = ghosts; g >= 1; g--) {
        var delay = g * 0.075
        var gp = Math.max(0, Math.min(1, (p - delay) / (1 - delay)))
        var ge = Motion.bezier(curve, gp)
        var life = Math.sin(Math.PI * Math.max(0, Math.min(1, p)))
        out.markers.push({
          s: lerp(A.s, B.s, ge), e: lerp(A.e, B.e, ge),
          cross: 1 - g * 0.12, opacity: (0.5 - g * 0.1) * life, scale: 1, shift: 0
        })
      }
      out.markers.push({ s: lerp(A.s, B.s, e), e: lerp(A.e, B.e, e), cross: 1, opacity: 1, scale: 1, shift: 0 })
    } else if (effect === "hop") {
      // A little jump over the row: up and across, landing on the curve.
      var lift = Math.max(2, (strip.barSize - m.markCross) / 2 - 1)
      var arc = Math.sin(Math.PI * Math.max(0, Math.min(1, p)))
      out.markers.push({
        s: lerp(A.s, B.s, e), e: lerp(A.e, B.e, e),
        cross: 1 - 0.15 * arc, opacity: 1, scale: 1, shift: -lift * arc
      })
    } else if (effect === "fade") {
      if (e < 1) out.markers.push({ s: A.s, e: A.e, cross: 1, opacity: 1 - e, scale: 1, shift: 0 })
      out.markers.push({ s: B.s, e: B.e, cross: 1, opacity: Math.min(1, e), scale: 1, shift: 0 })
    } else if (effect === "grow") {
      if (e < 1) out.markers.push({ s: A.s, e: A.e, cross: 1, opacity: 1 - e, scale: 1 - 0.45 * Math.min(1, e), shift: 0 })
      out.markers.push({ s: B.s, e: B.e, cross: 1, opacity: Math.min(1, e), scale: 0.55 + 0.45 * Math.min(1, e), shift: 0 })
    } else if (effect === "drop") {
      out.markers.push({
        s: lerp(A.s, B.s, e), e: lerp(A.e, B.e, e),
        cross: 1 - 0.55 * bell, opacity: 1 - 0.25 * bell, scale: 1, shift: 0
      })
    } else {
      out.markers.push({ s: lerp(A.s, B.s, e), e: lerp(A.e, B.e, e), cross: 1, opacity: 1, scale: 1, shift: 0 })
    }

    // The marker a new switch starts from if it cuts this one short.
    if (effect === "fade" || effect === "grow") out.primary = e < 0.5 ? A : B
    else out.primary = out.markers[out.markers.length - 1]
    return out
  }

  function radiusFor(w, h) {
    if (!m) return 0
    var small = Math.min(w, h)
    if (m.round === "full") return small / 2
    if (Style.cornerRadius <= 0) return 0
    if (m.round === "small") return Math.min(Style.space(2), small / 2)
    return Math.min(Style.cornerRadius, small / 2)
  }

  implicitWidth: minimal
    ? (vertical ? barSize : minimalRow.implicitWidth + Style.space(10))
    : (vertical ? barSize : frame.total)
  implicitHeight: minimal
    ? barSize
    : (vertical ? frame.total : barSize)

  // ---- Base marks: dots, rings and blocks every workspace carries.
  Repeater {
    model: !strip.minimal && strip.m && strip.m.base !== "none" ? strip.slots : []

    Rectangle {
      required property var modelData
      required property int index
      readonly property bool occupied: modelData.occupied === true
      readonly property real slotStart: strip.frame.starts[index] || 0
      readonly property real slotSize: strip.frame.sizes[index] || 0
      readonly property real mainLen: strip.m.baseMain
      readonly property real crossLen: strip.m.baseCross

      x: strip.vertical ? (strip.barSize - crossLen) / 2 : slotStart + (slotSize - mainLen) / 2
      y: strip.vertical ? slotStart + (slotSize - mainLen) / 2 : (strip.barSize - crossLen) / 2
      width: strip.vertical ? crossLen : mainLen
      height: strip.vertical ? mainLen : crossLen
      radius: strip.radiusFor(width, height)
      antialiasing: true

      readonly property bool urgent: strip.isUrgent(modelData)
      readonly property bool ring: strip.m.base === "ring" && !occupied && !urgent
      color: urgent ? Util.alpha(strip.urgentColor, strip.pulse)
        : ring ? "transparent"
        : Util.alpha(strip.foreground, strip.m.base === "block" ? (occupied ? 0.5 : 0.2) : (occupied ? 0.6 : 0.28))
      border.width: ring ? Math.max(1, Style.space(1)) : 0
      border.color: Util.alpha(strip.foreground, 0.55)
    }
  }

  // ---- The moving marker (two of them while fading or growing).
  Repeater {
    model: !strip.minimal && strip.m ? strip.frame.markers : []

    Rectangle {
      required property var modelData
      readonly property real len: Math.max(0, modelData.e - modelData.s)
      readonly property real crossLen: strip.m.markCross * modelData.cross

      x: strip.vertical ? (strip.barSize - crossLen) / 2 + strip.m.crossOffset + modelData.shift : modelData.s
      y: strip.vertical ? modelData.s : (strip.barSize - crossLen) / 2 + strip.m.crossOffset + modelData.shift
      width: strip.vertical ? crossLen : len
      height: strip.vertical ? len : crossLen
      radius: strip.radiusFor(width, height)
      antialiasing: true
      opacity: modelData.opacity
      scale: modelData.scale
      color: Util.alpha(strip.markColor, strip.m.fillAlpha)
    }
  }

  // ---- Labels and hit areas. WidgetButton keeps the bar's click routing,
  //      drag handling, press feedback and glyph rendering.
  Repeater {
    model: !strip.minimal && strip.m ? strip.slots : []

    WidgetButton {
      required property var modelData
      required property int index
      readonly property real weight: strip.frame.weights[index] || 0
      readonly property bool isActive: modelData.key === strip.toKey
      readonly property bool showsText: strip.m.text
      readonly property bool urgent: strip.isUrgent(modelData)

      x: strip.vertical ? 0 : (strip.frame.starts[index] || 0)
      y: strip.vertical ? (strip.frame.starts[index] || 0) : 0
      width: strip.vertical ? strip.barSize : (strip.frame.sizes[index] || 0)
      height: strip.vertical ? (strip.frame.sizes[index] || 0) : strip.barSize

      bar: strip.bar
      interactive: strip.interactive
      text: showsText ? (isActive && strip.activeGlyph !== "" ? strip.activeGlyph : String(modelData.label)) : ""
      labelVisible: showsText
      hasVisualContent: true
      fontFamily: strip.fontFamily
      fontSize: strip.fontSize
      foreground: urgent ? strip.urgentColor : strip.foreground
      active: strip.useAccent && weight > 0.5
      activeColor: strip.accent
      tooltipText: modelData.tip ? String(modelData.tip) : ""
      opacity: !showsText ? 1 : (urgent ? strip.pulse : (modelData.occupied || weight > 0.5 ? 1 : 0.5))
      onPressed: function(button) { strip.slotPressed(modelData.key, button) }
      onWheelMoved: function(delta) { strip.wheelMoved(delta) }
    }
  }

  // ---- Minimal: "3 / 5", the number itself carrying the effect.
  Item {
    id: minimalBox
    visible: strip.minimal
    anchors.fill: parent

    readonly property real e: strip.frame.e
    readonly property int dir: strip.toKey >= strip.fromKey ? 1 : -1
    readonly property real travel: strip.fontSize * 1.1
    readonly property bool moves: strip.effect === "slide" || strip.effect === "worm" || strip.effect === "drop"
    readonly property bool grows: strip.effect === "grow"
    readonly property bool settled: strip.p >= 1 || strip.effectiveDuration <= 0

    Row {
      id: minimalRow
      anchors.centerIn: parent
      spacing: Style.space(4)

      Item {
        id: numberBox
        width: Math.max(numberMetrics.advanceWidth("0") * 2, oldNumber.implicitWidth, newNumber.implicitWidth)
        height: strip.barSize
        clip: true

        Text {
          id: oldNumber
          visible: !minimalBox.settled
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: minimalBox.moves ? -minimalBox.dir * minimalBox.travel * minimalBox.e : 0
          text: strip.fromLabel
          color: strip.foreground
          opacity: Math.max(0, 1 - minimalBox.e)
          scale: minimalBox.grows ? 1 - 0.4 * Math.min(1, minimalBox.e) : 1
          font.family: strip.fontFamily
          font.pixelSize: strip.fontSize
          font.bold: true
        }

        Text {
          id: newNumber
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: minimalBox.moves && !minimalBox.settled ? minimalBox.dir * minimalBox.travel * (1 - minimalBox.e) : 0
          text: strip.labelFor(strip.toKey)
          color: strip.useAccent ? strip.accent : strip.foreground
          opacity: minimalBox.settled ? 1 : Math.min(1, minimalBox.e)
          scale: minimalBox.grows && !minimalBox.settled ? 0.6 + 0.4 * Math.min(1, minimalBox.e) : 1
          font.family: strip.fontFamily
          font.pixelSize: strip.fontSize
          font.bold: true
        }
      }

      Text {
        visible: !strip.vertical
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "/ " + Commons.I18n.formatNumber(strip.slots.length)
        color: Util.alpha(strip.foreground, 0.55)
        font.family: strip.fontFamily
        font.pixelSize: strip.fontSize
      }
    }

    FontMetrics {
      id: numberMetrics
      font.family: strip.fontFamily
      font.pixelSize: strip.fontSize
      font.bold: true
    }

    WidgetButton {
      anchors.fill: parent
      visible: strip.minimal
      bar: strip.bar
      interactive: strip.interactive && strip.minimal
      text: ""
      labelVisible: false
      hasVisualContent: true
      onPressed: function(button) { strip.slotPressed(strip.toKey, button) }
      onWheelMoved: function(delta) { strip.wheelMoved(delta) }
    }
  }
}
