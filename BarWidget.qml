import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Unrealised P/L pill for the Omarchy bar.
//
// The widget owns the state file and the colour decision; Panel.qml renders
// the portfolio popup from the same state object, so the pill and the list can
// never disagree about what the book is worth.
//
// Left click opens the portfolio, right click forces the poller to refetch,
// middle click copies the total.
BarWidget {
  id: root
  moduleName: "ctrader-pl"

  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/ctrader/state.json"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")

  readonly property string chartPath: Quickshell.env("HOME") + "/.local/state/omarchy/ctrader/chart.json"

  property var snapshot: Model.parseState("")
  property var chart: Model.parseChart("")
  property double nowMs: Date.now()

  // The chart toggle and range live on the widget rather than the panel so
  // reopening the popup returns to the view the user left it in.
  property bool chartOpen: setting("chartOpenByDefault", false) === true
  property string chartRange: setting("chartRange", "6h")

  readonly property bool showCurrency: setting("showCurrency", true) === true
  readonly property color profitColor: setting("profitColor", "#4fb286")
  // Loss defaults to the theme's own urgent colour so the pill stays in
  // palette; a user who wants a specific red can set lossColor.
  readonly property color lossColor: {
    var configured = setting("lossColor", "")
    return configured && String(configured).length > 0
      ? configured
      : (bar ? bar.urgent : Color.urgent)
  }
  readonly property color neutralColor: bar ? bar.barForeground : Color.foreground

  readonly property bool stale: Model.isStale(snapshot, nowMs, setting("staleAfterSeconds", 60))
  readonly property string label: Model.barLabel(snapshot, showCurrency)
  readonly property color labelColor: {
    if (!snapshot.unrealized) return Qt.darker(neutralColor, 1.5)
    var base = Model.plColor(snapshot.unrealized.net, profitColor, lossColor, neutralColor)
    // A stale figure is worse than no figure if it still looks confident, so
    // a lost connection keeps the number but drains the colour out of it.
    return stale ? Qt.darker(base, 1.7) : base
  }

  // Re-read the snapshot file. The panel calls this directly rather than
  // refresh(), so the two never bounce a refresh back and forth.
  function reloadState() {
    stateFile.reload()
    chartFile.reload()
  }

  function refresh() {
    reloadState()
  }

  // Nudges the poller into an immediate tick instead of waiting out its
  // interval. Harmless if the unit is not running.
  function forceUpdate() {
    if (bar) bar.run("systemctl --user restart omarchy-ctrader.service")
  }

  function copyTotal() {
    if (!bar || !snapshot.unrealized) return
    bar.run("printf '%s' " + JSON.stringify(Model.signedMoney(snapshot.unrealized.net)) + " | wl-copy")
  }

  // ---- Panel plumbing. Bar.findPanelWidget requires open/close/opened on the
  //      bar-widget root, so these forward to the popup.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property real openPanelIndicatorWidth: button.labelWidth

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("host" in target) target.host = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.snapshot = Model.parseState(text())
    onLoadFailed: root.snapshot = Model.parseState("")
  }

  // The history series behind the P&L graph. Written by the same poller tick
  // that writes the snapshot, and pre-bucketed there so this side only has to
  // parse a few KB rather than walk 48h of raw samples.
  FileView {
    id: chartFile
    path: root.chartPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.chart = Model.parseChart(text())
    onLoadFailed: root.chart = Model.parseChart("")
  }

  // Drives the "stale" fade and the relative timestamps in the popup. The
  // state file only changes when the poller ticks, so without this the age
  // text would freeze the moment the connection dropped — exactly when it
  // matters most.
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // The first read can race shell startup; one delayed reload self-corrects
  // and is a no-op when the first read already worked.
  Timer {
    interval: 1500
    running: true
    onTriggered: root.reloadState()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "ctrader"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.label
    labelVisible: !root.vertical
    hasVisualContent: true
    foreground: root.labelColor
    useActiveColor: false
    horizontalMargin: 8.75
    verticalPadding: 8.75
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    tooltipText: root.opened ? "" : Model.statusLine(root.snapshot, root.nowMs)

    onPressed: function(b) {
      if (b === Qt.RightButton) root.forceUpdate()
      else if (b === Qt.MiddleButton) root.copyTotal()
      else root.togglePanel()
    }

    // A vertical bar has no room for "+1,234.50 AUD", so it falls back to a
    // trend arrow that still carries the sign through colour.
    OpticalGlyph {
      visible: root.vertical
      // Fixed size, not anchors.fill: the button sizes itself from its
      // children, so a child that sizes itself from the button closes a loop
      // that QML unwinds as a JS stack overflow.
      anchors.centerIn: parent
      width: Style.bar.iconSlot
      height: Style.bar.iconSlot
      text: {
        if (!root.snapshot.unrealized) return "~"
        var n = Number(root.snapshot.unrealized.net)
        if (!isFinite(n) || Math.abs(n) < 0.005) return "="
        return n > 0 ? "▲" : "▼"
      }
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: root.labelColor
    }
  }
}
