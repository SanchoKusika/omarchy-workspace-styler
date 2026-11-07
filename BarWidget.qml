import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Motion.js" as Motion

// Workspace indicators with a choice of looks and switch animations.
//
// Workspace handling follows Omarchy's own widget (omarchy.workspaces): each
// monitor owns a block of ten workspaces, the bar shows its own block plus
// any visiting ones, a click focuses a workspace or cycles the focused one's
// layout, and the wheel walks the row. On top of that the row is drawn by
// Strip.qml in the chosen style, and by default the marker moves with the
// same duration and bezier Hyprland uses for the workspace slide, read from
// `hyprctl -j animations` and re-read on every config reload.
//
// Right click opens the settings panel.
BarWidget {
  id: root
  moduleName: "io.github.sanchokusika.workspace-styler"

  readonly property var cfg: Motion.normalize(root.settings)

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  readonly property int slots: 10

  // ---- Monitor and workspace bookkeeping (as in omarchy.workspaces).

  readonly property var monitor: {
    var window = root.QsWindow.window
    var screen = window ? window.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
  readonly property string monitorName: root.monitor ? root.monitor.name : ""

  property var blocks: ({})

  function readBlocks(text) {
    var next = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length && i < 64; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 3 && fields[1] !== "") {
        var block = parseInt(fields[0], 10)
        if (isFinite(block) && block >= 0 && block < 100) next[fields[1]] = block
      }
    }
    root.blocks = next
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  function blockOf(id) { return Math.floor((id - 1) / root.slots) }
  function slotOf(id) { return (id - 1) % root.slots + 1 }

  function activeWorkspaceId() {
    return root.monitor && root.monitor.activeWorkspace ? root.monitor.activeWorkspace.id : -1
  }

  readonly property int block: {
    var block = root.blocks[root.monitorName]
    if (block !== undefined) return block
    var active = root.activeWorkspaceId()
    return active > 0 ? root.blockOf(active) : 0
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) if (values[i].id === id) return values[i]
    return null
  }

  // The monitor's first `persistent` workspaces always, any others of its
  // block that exist, then visitors from an unplugged monitor.
  function workspaceIds() {
    var base = root.block * root.slots
    var ids = []
    for (var n = 1; n <= root.cfg.persistent; n++) ids.push(base + n)
    var guests = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id <= 0) continue
      if (root.blockOf(id) === root.block) {
        if (ids.indexOf(id) === -1) ids.push(id)
      } else if (values[i].monitor && values[i].monitor.name === root.monitorName) {
        guests.push(id)
      }
    }
    ids.sort(function(a, b) { return a - b })
    guests.sort(function(a, b) { return a - b })
    return ids.concat(guests)
  }

  // Hover text: the workspace and the apps on it. App names come from other
  // programs, so Motion.appNames neutralizes them before the shared tooltip.
  function tipFor(label, ws) {
    if (!root.cfg.peek) return ""
    var head = strings.t("tip.workspace").arg(label)
    var apps = Motion.appNames(ws ? ws.toplevels.values : [], 5)
    if (apps.names.length === 0) return head + "\n" + strings.t("tip.empty")
    var line = apps.names.join(" · ")
    if (apps.extra > 0) line += " " + strings.t("tip.more").arg(Commons.I18n.formatNumber(apps.extra))
    return head + "\n" + line
  }

  readonly property var slotModel: {
    var ids = root.workspaceIds()
    var out = []
    for (var i = 0; i < ids.length; i++) {
      var ws = root.workspaceById(ids[i])
      var slot = root.slotOf(ids[i])
      var label = slot === root.slots ? "0" : String(slot)
      out.push({
        key: ids[i],
        label: label,
        occupied: ws !== null && ws.toplevels.values.length > 0,
        urgent: ws !== null && ws.urgent === true,
        guest: root.blockOf(ids[i]) !== root.block,
        tip: root.tipFor(label, ws)
      })
    }
    return out
  }

  function dispatch(expression) {
    if (root.bar) root.bar.run("hyprctl dispatch " + Util.shellQuote(expression))
  }

  function focusWorkspace(id) {
    id = Math.round(Number(id))
    if (!isFinite(id) || id <= 0) return
    if (root.blockOf(id) === root.block) {
      root.dispatch("o.workspaces.focus(" + root.slotOf(id) + ", \"" + root.monitorName.replace(/[^A-Za-z0-9_.-]/g, "") + "\")")
    } else {
      root.dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
    }
  }

  property real wheelAccumulator: 0

  function scrollWorkspaces(delta) {
    var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
    root.wheelAccumulator = wheel.remainder
    if (wheel.steps === 0) return
    var ids = root.workspaceIds()
    var index = ids.indexOf(root.activeWorkspaceId())
    if (index === -1) return
    var target = ids[Util.clamp(index - wheel.steps, 0, ids.length - 1)]
    if (target !== ids[index]) root.focusWorkspace(target)
  }

  // ---- Layout mode of the shown workspace (square tiles, circle scrolls,
  //      triangle floats), cached per workspace as Omarchy's widget does.

  property string activeMode: "dwindle"
  property bool modeStale: false
  property var modeCache: ({})
  property int modeGeneration: 0
  property int modeProcWorkspace: -1
  property int modeProcGeneration: 0

  function modeGlyph(mode) {
    if (mode === "scrolling") return "󰝥"
    if (mode === "floating") return "󰔶"
    return "󱓻"
  }

  function showActiveMode() {
    var mode = root.modeCache[root.activeWorkspaceId()]
    if (mode !== undefined) root.activeMode = mode
    else readMode()
  }

  function readMode() {
    if (modeProc.running) { root.modeStale = true; return }
    var id = root.activeWorkspaceId()
    if (id === -1) return
    root.modeProcWorkspace = id
    root.modeProcGeneration = root.modeGeneration
    modeProc.command = ["omarchy-hyprland-workspace-layout-current", String(id)]
    modeProc.running = true
  }

  function refresh() {
    root.modeCache = ({})
    root.modeGeneration++
    readMode()
  }

  function cycleLayout() {
    if (!root.bar) return
    var command = "omarchy-hyprland-workspace-layout-toggle"
    if (root.monitor && !root.monitor.focused) {
      command = "hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ monitor = \"" + root.monitorName.replace(/[^A-Za-z0-9_.-]/g, "") + "\" })") + " >/dev/null && " + command
    }
    root.bar.run(command)
  }

  Process {
    id: modeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var mode = text.trim()
        if (!/^[a-z]{1,16}$/.test(mode) || root.modeProcGeneration !== root.modeGeneration) return
        root.modeCache[root.modeProcWorkspace] = mode
        if (root.modeProcWorkspace === root.activeWorkspaceId()) root.activeMode = mode
      }
    }
    onExited: {
      if (!root.modeStale) return
      root.modeStale = false
      Qt.callLater(root.showActiveMode)
    }
  }

  // ---- Hyprland's workspace animation timing.

  property var hypr: ({ ok: false, enabled: true, ms: 0, curveName: "", curve: [0, 0.75, 0.15, 1], curves: [] })

  function readHyprland() {
    if (!hyprProc.running) hyprProc.running = true
  }

  Process {
    id: hyprProc
    command: ["hyprctl", "-j", "animations"]
    stdout: StdioCollector {
      onStreamFinished: {
        // A healthy reply is a few kilobytes; refuse anything absurd.
        if (text.length > 262144) return
        var parsed = Motion.parseHyprland(text)
        if (parsed.ok) root.hypr = parsed
      }
    }
  }

  function hyprCurve(name) {
    if (String(name).indexOf("hypr:") !== 0) return null
    var wanted = String(name).slice(5)
    for (var i = 0; i < root.hypr.curves.length; i++)
      if (root.hypr.curves[i].name === wanted) return root.hypr.curves[i].points
    return null
  }

  function curveFor(name, custom) {
    if (name === "custom") return custom
    return Motion.builtinCurve(name) || root.hyprCurve(name) || Motion.DEFAULTS.bezier
  }

  readonly property bool synced: cfg.timing === "hyprland"
  readonly property int transitionMs: Style.reduceMotion ? 0
    : (synced ? (hypr.enabled ? hypr.ms : 0) : cfg.duration)
  readonly property var transitionCurve: synced ? hypr.curve : curveFor(cfg.curve, cfg.bezier)

  // ---- Settings.

  // Applied locally first so the bar redraws on the click; the shell.json
  // write comes back through the bar as the same value.
  function saveSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (panelLoader.item && "settings" in panelLoader.item) panelLoader.item.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function resetSettings() {
    var entry = { id: root.moduleName }
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Settings panel (Panel.qml), same wiring as Omarchy's clock.

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function openTab(name) {
    if (!panelLoader.item) return
    if (name === "look" || name === "motion") panelLoader.item.tab = name
    panelLoader.item.open()
  }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = strip
    target.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onOpenedChanged: if (opened) readHyprland()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  // ---- Events.

  Component.onCompleted: {
    refresh()
    readHyprland()
    if (root.cfg.peek) Hyprland.refreshToplevels()
  }
  onMonitorChanged: root.showActiveMode()

  Connections {
    target: root.monitor
    function onActiveWorkspaceChanged() { root.showActiveMode() }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      if (name === "configreloaded") {
        root.refresh()
        root.readHyprland()
      }
      var switched = name === "workspacev2" && root.monitor !== null && root.monitor.focused
      if (switched || name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
      }
      // App classes for the hover text live in each window's IPC object,
      // which Hyprland only fills on request. Ask when windows come, go or
      // move, never on title changes, and only once per burst of events.
      if (root.cfg.peek && (name === "openwindow" || name === "closewindow" || name === "movewindowv2"))
        toplevelTimer.restart()
    }
  }

  Timer {
    id: toplevelTimer
    interval: 250
    onTriggered: Hyprland.refreshToplevels()
  }

  // Omarchy's layout commands ask "omarchy.workspaces" to refresh; answer for
  // it while this widget stands in for it.
  ShellIpc {
    target: "omarchy.workspaces"
    function refresh(): void { root.broadcast("refresh") }
  }

  ShellIpc {
    target: "io.github.sanchokusika.workspace-styler"
    function refresh(): void { root.broadcast("refresh"); root.broadcast("readHyprland") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    // Open the settings on a tab: "look" or "motion".
    function tab(name: string): void { root.openTab(name) }
  }

  // ---- The row.

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: strip.implicitWidth + trailingGap
  implicitHeight: strip.implicitHeight

  Strip {
    id: strip
    width: implicitWidth
    height: implicitHeight
    bar: root.bar
    slots: root.slotModel
    activeKey: root.activeWorkspaceId()
    activeGlyph: root.cfg.layoutGlyph ? root.modeGlyph(root.activeMode) : ""
    styleName: root.cfg.style
    effect: root.cfg.effect
    duration: root.transitionMs
    curve: root.transitionCurve
    wormLag: root.cfg.wormLag
    vertical: root.vertical
    barSize: root.barSize
    foreground: root.bar ? root.bar.barForeground : Commons.Color.foreground
    accent: Commons.Color.accent
    useAccent: root.cfg.accent
    urgentColor: root.bar ? root.bar.urgent : Commons.Color.urgent
    showUrgent: root.cfg.urgent
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

    onSlotPressed: function(key, button) {
      if (button === Qt.RightButton) root.togglePanel()
      else if (key === root.activeWorkspaceId()) root.cycleLayout()
      else root.focusWorkspace(key)
    }
    onWheelMoved: function(delta) { root.scrollWorkspaces(delta) }
  }
}
