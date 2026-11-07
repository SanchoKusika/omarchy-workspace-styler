.pragma library

// Pure helpers for the workspace styler: the catalogue of looks, effects and
// curves, settings validation, Hyprland timing parsing, and a cubic-bezier
// evaluator so every part of a transition can run on the curve Hyprland uses.

var STYLES = ["numbers", "underline", "pills", "dots", "blocks", "minimal"]
var EFFECTS = ["slide", "worm", "comet", "hop", "fade", "grow", "drop", "none"]
var TIMINGS = ["hyprland", "custom"]

// Curves offered for the custom timing. Hyprland's own named curves are
// added at runtime from `hyprctl animations -j`.
var BUILTIN_CURVES = [
  { value: "omarchy", points: [0.23, 1.0, 0.32, 1.0] },
  { value: "outCubic", points: [0.33, 1.0, 0.68, 1.0] },
  { value: "smooth", points: [0.4, 0.0, 0.2, 1.0] },
  { value: "inOutCubic", points: [0.65, 0.0, 0.35, 1.0] },
  { value: "linear", points: [0.0, 0.0, 1.0, 1.0] }
]

var DEFAULTS = {
  style: "pills",
  effect: "worm",
  timing: "hyprland",
  duration: 280,
  curve: "omarchy",
  bezier: [0.23, 1.0, 0.32, 1.0],
  wormLag: 0.35,
  accent: false,
  layoutGlyph: true,
  peek: true,
  urgent: true,
  persistent: 5
}

var MAX_HYPR_CURVES = 32
var MAX_NAME = 40

function clamp(v, lo, hi) {
  v = Number(v)
  if (!isFinite(v)) return lo
  return Math.max(lo, Math.min(hi, v))
}

function pick(list, value, fallback) {
  return list.indexOf(String(value)) !== -1 ? String(value) : fallback
}

function validCurveName(name) {
  var s = String(name || "")
  if (s.length === 0 || s.length > MAX_NAME + 5) return false
  return /^(hypr:)?[A-Za-z0-9_.-]+$/.test(s) || s === "custom"
}

function validBezier(points) {
  if (!points || points.length !== 4) return null
  var out = [clamp(points[0], 0, 1), clamp(points[1], -1, 2), clamp(points[2], 0, 1), clamp(points[3], -1, 2)]
  for (var i = 0; i < 4; i++) out[i] = Math.round(out[i] * 100) / 100
  return out
}

// shell.json is user-editable, so every field is validated and bounded.
function normalize(settings) {
  var s = settings || {}
  return {
    style: pick(STYLES, s.style, DEFAULTS.style),
    effect: pick(EFFECTS, s.effect, DEFAULTS.effect),
    timing: pick(TIMINGS, s.timing, DEFAULTS.timing),
    duration: Math.round(clamp(s.duration === undefined ? DEFAULTS.duration : s.duration, 0, 2000)),
    curve: validCurveName(s.curve) ? String(s.curve) : DEFAULTS.curve,
    bezier: validBezier(s.bezier) || DEFAULTS.bezier.slice(),
    wormLag: clamp(s.wormLag === undefined ? DEFAULTS.wormLag : s.wormLag, 0.05, 0.8),
    accent: s.accent === true,
    layoutGlyph: s.layoutGlyph !== false,
    peek: s.peek !== false,
    urgent: s.urgent !== false,
    persistent: Math.round(clamp(s.persistent === undefined ? DEFAULTS.persistent : s.persistent, 1, 10))
  }
}

// Window titles and classes come from other programs. Before they reach a
// tooltip (an Omarchy-owned Text whose format a plugin cannot set) anything
// markup-shaped is neutralized: angle brackets and ampersands become
// look-alike characters, control characters go, and the length is capped.
function plainLabel(value, max) {
  var limit = max > 0 ? max : 32
  var s = String(value === undefined || value === null ? "" : value)
  if (s.length > 512) s = s.slice(0, 512)
  s = s.replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069]/g, " ")
  s = s.replace(/</g, "\u2039").replace(/>/g, "\u203a").replace(/&/g, "\uff06")
  s = s.replace(/\s+/g, " ").trim()
  if (s.length > limit) s = s.slice(0, limit - 1).trim() + "\u2026"
  return s
}

// The apps on a workspace for its tooltip: class names (or titles when a
// class is missing), de-duplicated, at most `max` of them.
function appNames(toplevels, max) {
  var limit = max > 0 ? max : 5
  var names = []
  var extra = 0
  var list = toplevels || []
  for (var i = 0; i < list.length && i < 64; i++) {
    var t = list[i]
    if (!t) continue
    var ipc = t.lastIpcObject || {}
    var name = plainLabel(ipc["class"] || ipc.initialClass || t.title || "", 28)
    if (!name || names.indexOf(name) !== -1) continue
    if (names.length < limit) names.push(name)
    else extra++
  }
  return { names: names, extra: extra }
}

function builtinCurve(name) {
  for (var i = 0; i < BUILTIN_CURVES.length; i++)
    if (BUILTIN_CURVES[i].value === name) return BUILTIN_CURVES[i].points
  return null
}

// ---- Hyprland timing ----------------------------------------------------

// Hyprland's animation tree: a leaf that is not overridden takes its
// parent's values.
var PARENTS = {
  workspacesIn: "workspaces",
  workspacesOut: "workspaces",
  workspaces: "global"
}

// Parses `hyprctl animations -j` ([[animations], [beziers]]) into the timing
// a workspace switch actually runs with.
function parseHyprland(raw) {
  var result = { ok: false, enabled: true, ms: 0, curveName: "", curve: [0, 0.75, 0.15, 1], curves: [] }
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { return result }
  if (!Array.isArray(data) || data.length < 2 || !Array.isArray(data[0]) || !Array.isArray(data[1])) return result

  var leaves = {}
  for (var i = 0; i < data[0].length && i < 256; i++) {
    var a = data[0][i]
    if (a && typeof a.name === "string") leaves[a.name] = a
  }

  var beziers = {}
  for (var j = 0; j < data[1].length && j < 256; j++) {
    var b = data[1][j]
    if (!b || typeof b.name !== "string" || b.name.length > MAX_NAME || !/^[A-Za-z0-9_.-]+$/.test(b.name)) continue
    var pts = validBezier([b.X0, b.Y0, b.X1, b.Y1])
    if (!pts) continue
    beziers[b.name] = pts
    if (result.curves.length < MAX_HYPR_CURVES) result.curves.push({ name: b.name, points: pts })
  }

  // Resolve a field by walking up from the leaf until a node overrides it.
  function resolve(name) {
    var node = leaves[name]
    var guard = 0
    while (node && !node.overridden && PARENTS[node.name] && guard++ < 4) node = leaves[PARENTS[node.name]]
    return node || null
  }

  var leaf = resolve("workspacesIn") || resolve("workspaces") || leaves.global
  if (!leaf) return result

  // A switch is instant if any node on the way up is disabled.
  var enabled = true
  var walk = leaves.workspacesIn
  var guard = 0
  while (walk && guard++ < 4) {
    if (walk.enabled === false) enabled = false
    walk = PARENTS[walk.name] ? leaves[PARENTS[walk.name]] : null
  }

  result.ok = true
  result.enabled = enabled
  // Hyprland speed is in deciseconds: 1 = 100 ms.
  result.ms = Math.round(clamp(leaf.speed, 0, 100) * 100)
  result.curveName = typeof leaf.bezier === "string" && beziers[leaf.bezier] ? leaf.bezier : "default"
  result.curve = beziers[result.curveName] || [0, 0.75, 0.15, 1]
  return result
}

// ---- Cubic bezier --------------------------------------------------------

// y for a given x on the unit cubic bezier (0,0) (x1,y1) (x2,y2) (1,1), the
// same curve Hyprland and CSS use.
function bezier(points, x) {
  if (x <= 0) return 0
  if (x >= 1) return 1
  var x1 = points[0], y1 = points[1], x2 = points[2], y2 = points[3]
  if (x1 === y1 && x2 === y2) return x

  function cx(t) { return ((1 - 3 * x2 + 3 * x1) * t + (3 * x2 - 6 * x1)) * t * t + 3 * x1 * t }
  function cy(t) { return ((1 - 3 * y2 + 3 * y1) * t + (3 * y2 - 6 * y1)) * t * t + 3 * y1 * t }
  function dx(t) { return 3 * (1 - 3 * x2 + 3 * x1) * t * t + 2 * (3 * x2 - 6 * x1) * t + 3 * x1 }

  var t = x
  for (var i = 0; i < 8; i++) {
    var err = cx(t) - x
    if (Math.abs(err) < 1e-5) return cy(t)
    var d = dx(t)
    if (Math.abs(d) < 1e-6) break
    t -= err / d
  }
  // Newton stalled on a flat stretch: bisect instead.
  var lo = 0, hi = 1
  t = x
  for (var k = 0; k < 30; k++) {
    var v = cx(t)
    if (Math.abs(v - x) < 1e-5) break
    if (v < x) lo = t
    else hi = t
    t = (lo + hi) / 2
  }
  return cy(t)
}

function lerp(a, b, t) {
  return a + (b - a) * t
}

// ---- Style geometry ------------------------------------------------------

// Per-style geometry along the bar ("main" axis) and across it ("cross").
// `space` is Style.space so everything follows the shell's scale.
function metrics(style, space, vertical, barSize) {
  switch (style) {
  case "numbers":
    return {
      slotMin: vertical ? Math.round(barSize * 0.85) : space(20), slotMax: vertical ? Math.round(barSize * 0.85) : space(20),
      spacing: vertical ? space(2) : space(1),
      markMin: space(18), markMax: space(18), markCross: space(18), crossOffset: 0,
      base: "none", baseMain: 0, baseCross: 0, round: "theme", text: true, fillAlpha: 0.2
    }
  case "underline":
    return {
      slotMin: vertical ? Math.round(barSize * 0.85) : space(20), slotMax: vertical ? Math.round(barSize * 0.85) : space(20),
      spacing: vertical ? space(2) : space(1),
      markMin: space(10), markMax: space(10), markCross: Math.max(2, space(2)), crossOffset: space(9),
      base: "none", baseMain: 0, baseCross: 0, round: "theme", text: true, fillAlpha: 1
    }
  case "pills":
    var dot = space(7), pill = space(24), gap = space(5)
    return {
      slotMin: dot + gap, slotMax: pill + gap, spacing: 0,
      markMin: dot, markMax: pill, markCross: dot, crossOffset: 0,
      base: "dot", baseMain: dot, baseCross: dot, round: "full", text: false, fillAlpha: 1
    }
  case "dots":
    return {
      slotMin: space(15), slotMax: space(15), spacing: 0,
      markMin: space(9), markMax: space(9), markCross: space(9), crossOffset: 0,
      base: "ring", baseMain: space(6), baseCross: space(6), round: "full", text: false, fillAlpha: 1
    }
  case "blocks":
    return {
      slotMin: space(17), slotMax: space(17), spacing: 0,
      markMin: space(14), markMax: space(14), markCross: space(6), crossOffset: 0,
      base: "block", baseMain: space(14), baseCross: space(6), round: "small", text: false, fillAlpha: 1
    }
  }
  return null
}
