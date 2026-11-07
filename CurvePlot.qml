import QtQuick
import qs.Commons
import qs.Commons as Commons

// The timing curve, drawn the way curve editors draw it: time to the right,
// progress upward, with the two control handles. Room is left above and
// below the unit square for curves that overshoot.
Item {
  id: root

  property var points: [0.23, 1.0, 0.32, 1.0]
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent

  onPointsChanged: canvas.requestPaint()
  onForegroundChanged: canvas.requestPaint()
  onAccentChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Util.alpha(root.foreground, 0.04)
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.14)
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var p = root.points || [0, 0, 1, 1]
      var pad = Math.max(6, width * 0.12)
      var w = width - pad * 2
      var h = height - pad * 2
      function X(v) { return pad + v * w }
      function Y(v) { return pad + (1 - v) * h }
      function css(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + (a === undefined ? c.a : a) + ")"
      }

      // Unit square.
      ctx.strokeStyle = css(root.foreground, 0.16)
      ctx.lineWidth = 1
      ctx.setLineDash([2, 3])
      ctx.strokeRect(X(0), Y(1), w, h)
      ctx.setLineDash([])

      // Handles.
      ctx.strokeStyle = css(root.foreground, 0.45)
      ctx.beginPath()
      ctx.moveTo(X(0), Y(0)); ctx.lineTo(X(p[0]), Y(p[1]))
      ctx.moveTo(X(1), Y(1)); ctx.lineTo(X(p[2]), Y(p[3]))
      ctx.stroke()

      // Curve.
      ctx.strokeStyle = css(root.accent, 1)
      ctx.lineWidth = 2
      ctx.beginPath()
      ctx.moveTo(X(0), Y(0))
      ctx.bezierCurveTo(X(p[0]), Y(p[1]), X(p[2]), Y(p[3]), X(1), Y(1))
      ctx.stroke()

      // Handle knobs.
      ctx.fillStyle = css(root.foreground, 1)
      var r = 2.5
      ctx.beginPath(); ctx.arc(X(p[0]), Y(p[1]), r, 0, Math.PI * 2); ctx.fill()
      ctx.beginPath(); ctx.arc(X(p[2]), Y(p[3]), r, 0, Math.PI * 2); ctx.fill()
    }
  }
}
