// Run with: node --test tests/
// Loads Motion.js (a QML .pragma library) into a plain JS context.
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const source = readFileSync(fileURLToPath(new URL("../Motion.js", import.meta.url)), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.runInNewContext(source + "\nthis.M = { STYLES, EFFECTS, DEFAULTS, normalize, plainLabel, appNames, parseHyprland, bezier, metrics }", M)
const {
  STYLES, EFFECTS, DEFAULTS, normalize, plainLabel, appNames, parseHyprland, bezier, metrics
} = M.M
// Values from the vm context are from another realm; compare them as JSON.
const plain = v => JSON.parse(JSON.stringify(v))

// ---- Untrusted text --------------------------------------------------------

test("markup-shaped window names cannot become rich text", () => {
  const out = plainLabel('<img src="https://example.invalid/tracker">', 64)
  assert.ok(!out.includes("<") && !out.includes(">"), out)
  assert.ok(!plainLabel("<b>bold</b> &amp;").includes("&"))
  assert.ok(!plainLabel("<style>*{}</style>").includes("<"))
})

test("control and bidi characters are dropped, length is capped", () => {
  assert.equal(plainLabel("a\u0000b\nc‮d"), "a b c d")
  const long = plainLabel("x".repeat(400), 20)
  assert.equal(long.length, 20)
  assert.ok(long.endsWith("…"))
  assert.equal(plainLabel(undefined), "")
  assert.equal(plainLabel(null), "")
})

test("app names are de-duplicated, neutralized and bounded", () => {
  const tl = (cls, title) => ({ lastIpcObject: cls === null ? {} : { class: cls }, title })
  const apps = appNames([
    tl("kitty"), tl("kitty"), tl(null, "<script>x</script>"),
    tl("a"), tl("b"), tl("c"), tl("d"), tl("e")
  ], 5)
  assert.equal(apps.names.length, 5)
  assert.equal(apps.names[0], "kitty")
  assert.ok(apps.names.every(n => !n.includes("<")))
  assert.equal(apps.extra, 2)
  assert.deepEqual(plain(appNames(null, 5).names), [])
})

// ---- Settings ---------------------------------------------------------------

test("settings from shell.json are validated and bounded", () => {
  const n = normalize({
    style: "<evil>", effect: 42, timing: "x", duration: "1e9",
    curve: "../../etc", bezier: [5, 9, "q", -7], wormLag: 3, persistent: -4, peek: "no"
  })
  assert.equal(n.style, DEFAULTS.style)
  assert.equal(n.effect, DEFAULTS.effect)
  assert.equal(n.timing, "hyprland")
  assert.equal(n.duration, 2000)
  assert.equal(n.curve, DEFAULTS.curve)
  assert.deepEqual(plain(n.bezier), [1, 2, 0, -1])
  assert.equal(n.wormLag, 0.8)
  assert.equal(n.persistent, 1)
  assert.equal(n.peek, true)
  assert.deepEqual(plain(normalize(undefined)), plain(normalize({})))
})

test("every style has geometry, every effect a label key", () => {
  const space = px => px
  for (const s of STYLES) if (s !== "minimal") assert.ok(metrics(s, space, false, 26), s)
  assert.equal(new Set(EFFECTS).size, EFFECTS.length)
})

// ---- Curves -----------------------------------------------------------------

test("bezier hits its ends and follows known curves", () => {
  const quint = [0.22, 1, 0.36, 1]
  assert.equal(bezier(quint, 0), 0)
  assert.equal(bezier(quint, 1), 1)
  assert.ok(Math.abs(bezier([0, 0, 1, 1], 0.37) - 0.37) < 1e-6)
  // easeOutQuint is ~3/4 done a quarter of the way in.
  assert.ok(bezier(quint, 0.25) > 0.7 && bezier(quint, 0.25) < 0.8)
  let last = 0
  for (let x = 0; x <= 1; x += 0.01) {
    const y = bezier([0.65, 0, 0.35, 1], x)
    assert.ok(y >= last - 1e-6)
    last = y
  }
})

// ---- Hyprland timing ----------------------------------------------------------

const beziers = [
  { name: "easeOutQuint", X0: 0.22, Y0: 1, X1: 0.36, Y1: 1 },
  { name: "default", X0: 0, Y0: 0.75, X1: 0.15, Y1: 1 }
]
const anim = (name, overridden, speed, bezier = "easeOutQuint", enabled = true) =>
  ({ name, overridden, speed, bezier, enabled, style: "slide" })

test("workspacesIn timing is read, speed is deciseconds", () => {
  const r = parseHyprland(JSON.stringify([[anim("global", true, 8, "default"), anim("workspaces", true, 6), anim("workspacesIn", true, 4)], beziers]))
  assert.equal(r.ok, true)
  assert.equal(r.ms, 400)
  assert.equal(r.curveName, "easeOutQuint")
  assert.deepEqual(plain(r.curve), [0.22, 1, 0.36, 1])
})

test("leaves that are not overridden inherit up the tree", () => {
  const r = parseHyprland(JSON.stringify([[anim("global", true, 8, "default"), anim("workspaces", false, 0, ""), anim("workspacesIn", false, 0, "")], beziers]))
  assert.equal(r.ms, 800)
  assert.equal(r.curveName, "default")
})

test("a disabled branch makes switches instant", () => {
  const r = parseHyprland(JSON.stringify([[anim("global", true, 8), anim("workspaces", true, 6, "easeOutQuint", false), anim("workspacesIn", true, 6)], beziers]))
  assert.equal(r.enabled, false)
})

test("garbage from hyprctl is rejected", () => {
  assert.equal(parseHyprland("not json").ok, false)
  assert.equal(parseHyprland("{}").ok, false)
  const r = parseHyprland(JSON.stringify([[anim("workspacesIn", true, 6)], [{ name: "<x>", X0: 0, Y0: 0, X1: 1, Y1: 1 }]]))
  assert.ok(r.curves.every(c => !c.name.includes("<")))
})
