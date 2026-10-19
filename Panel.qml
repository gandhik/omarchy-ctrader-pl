import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Portfolio popup: the headline unrealised figure, the account line, then one
// row per open position. All state is read off the host bar widget so there is
// a single reader of the state file.
Panel {
  id: root
  moduleName: "ctrader-pl"
  ipcTarget: ""
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var host: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // the popout coordinator has to be handed that widget as our identity.
  readonly property var barIdentity: hostWidget || root

  readonly property var snapshot: host ? host.snapshot : Model.parseState("")
  readonly property double nowMs: host ? host.nowMs : Date.now()
  readonly property color profitColor: host ? host.profitColor : "#4fb286"
  readonly property color lossColor: host ? host.lossColor : Color.urgent
  readonly property color neutralColor: bar ? bar.barForeground : Color.foreground
  readonly property color dimColor: Qt.darker(neutralColor, 1.5)
  readonly property bool showAccountRow: setting("showAccountRow", true) === true
  readonly property string tradingViewExchange: String(setting("tradingViewExchange", "") || "")

  // Chart state lives on the host widget, not here, so it survives the popup
  // being closed and reopened.
  readonly property var chart: host ? host.chart : Model.parseChart("")
  readonly property bool chartOpen: host ? host.chartOpen === true : false
  readonly property string chartRangeKey: host ? host.chartRange : "6h"

  function toggleChart() { if (host) host.chartOpen = !host.chartOpen }
  function setChartRange(key) { if (host) host.chartRange = key }

  readonly property var account: snapshot.account
  readonly property var unrealized: snapshot.unrealized
  readonly property var positions: snapshot.positions

  // Deliberately reloadState() and not host.refresh(): the host's refresh
  // used to call back into this panel, and the two recursed until the JS
  // stack blew.
  function refresh() { if (host) host.reloadState() }

  function open() {
    root.controller.show()
    root.refresh()
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function openChart(symbol) {
    var url = Model.tradingViewUrl(symbol, root.tradingViewExchange)
    if (!url) return
    Util.execArgv(["omarchy-launch-browser", url])
    root.close()
  }

  function colorFor(value) {
    return Model.plColor(value, profitColor, lossColor, neutralColor)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onReturnRequested: root.refresh()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(10)

          // ---- Headline: the number the widget exists for, at hero size.
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "UNREALISED P/L"
              color: Qt.darker(root.neutralColor, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Row {
              spacing: Style.space(8)

              Text {
                id: heroNumber
                textFormat: Text.PlainText
                text: root.unrealized ? Model.signedMoney(root.unrealized.net) : "—"
                color: root.unrealized ? root.colorFor(root.unrealized.net) : root.dimColor
                font.family: Style.font.family
                font.pixelSize: Style.font.displayLarge
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                anchors.baseline: heroNumber.baseline
                text: root.unrealized && root.unrealized.currency ? root.unrealized.currency : ""
                color: Qt.darker(root.neutralColor, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
              }

              Text {
                textFormat: Text.PlainText
                anchors.baseline: heroNumber.baseline
                visible: root.unrealized && root.unrealized.returnPct !== undefined
                text: root.unrealized ? Model.formatPct(root.unrealized.returnPct) : ""
                color: root.unrealized ? root.colorFor(root.unrealized.net) : root.dimColor
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: Model.statusLine(root.snapshot, root.nowMs)
                    + (root.snapshot.environment ? "  ·  " + root.snapshot.environment.toUpperCase() : "")
              color: root.snapshot.status === "error" ? root.lossColor : Qt.darker(root.neutralColor, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { width: parent.width }

          // ---- P&L over time -----------------------------------------------
          // Collapsed by default: the popup's first job is the book as it
          // stands, and an always-open graph pushes the positions below the
          // fold on a small screen.
          Button {
            width: parent.width
            leftAlign: true
            bordered: true
            focusable: false
            foreground: root.neutralColor
            fontSize: Style.font.bodySmall
            iconText: root.chartOpen ? "\u25be" : "\u25b8"
            iconSize: Style.font.caption
            text: (root.chartOpen ? "Hide" : "Show") + " P&L histogram"
            onClicked: root.toggleChart()
          }

          Column {
            id: chartSection
            visible: root.chartOpen
            width: parent.width
            spacing: Style.space(6)

            readonly property var range: Model.chartRange(root.chart, root.chartRangeKey)
            readonly property var vscale: Model.chartScale(range)
            readonly property bool hasPoints: range.points.length > 0
            // The value-axis gutter. Hoisted so the bars, the zero rule and the
            // time ticks all start from the same left edge.
            readonly property real axisWidth: Style.space(46)
            readonly property real plotHeight: Style.space(116)
            readonly property var axisMarks: Model.axisMarks(range, vscale, plotHeight)

            // Range picker on the left, what the window actually did on the right.
            Item {
              width: parent.width
              height: Math.max(rangePicker.implicitHeight, windowDelta.implicitHeight)

              ButtonGroup {
                id: rangePicker
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                focusable: false
                fontSize: Style.font.caption
                foreground: root.neutralColor
                options: root.chart.rangeKeys
                value: root.chartRangeKey
                onChanged: function(key) { root.setChartRange(key) }
              }

              Text {
                id: windowDelta
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: Model.chartSummary(chartSection.range, root.nowMs)
                color: {
                  var d = Model.chartDelta(chartSection.range)
                  return d === null ? Qt.darker(root.neutralColor, 1.5) : root.colorFor(d)
                }
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // ---- The plot.
            Item {
              id: plot
              width: parent.width
              height: chartSection.plotHeight

              readonly property real plotWidth: Math.max(1, width - chartSection.axisWidth)
              readonly property real zeroY: Model.chartY(0, chartSection.vscale, height)

              // Value axis: peak, break-even and trough, each sitting at its
              // own height. A full gridline set would out-ink the bars at this
              // size, and labelling the padded frame bounds would print a
              // figure no sample ever reached.
              Repeater {
                model: chartSection.hasPoints ? chartSection.axisMarks : []

                Text {
                  required property var modelData
                  x: 0
                  width: chartSection.axisWidth - Style.space(6)
                  horizontalAlignment: Text.AlignRight
                  y: Math.max(0, Math.min(plot.height - implicitHeight,
                                          modelData.y - implicitHeight / 2))
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: Qt.darker(root.neutralColor, modelData.muted ? 2.0 : 1.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              // Break-even. Bars read as depth below it or height above it, so
              // it is the one rule that has to be there.
              Rectangle {
                x: chartSection.axisWidth
                width: plot.plotWidth
                y: plot.zeroY
                height: 1
                color: Qt.darker(root.neutralColor, 1.9)
                visible: chartSection.hasPoints
              }

              Item {
                id: bars
                x: chartSection.axisWidth
                width: plot.plotWidth
                height: plot.height

                Repeater {
                  model: chartSection.range.points

                  Rectangle {
                    required property var modelData
                    readonly property real valueY: Model.chartY(modelData.net, chartSection.vscale, bars.height)
                    readonly property bool hot: hoverArea.point !== null
                                                && hoverArea.point.i === modelData.i

                    x: Model.chartBarX(modelData, chartSection.range, bars.width)
                    width: Model.chartBarWidth(chartSection.range, bars.width)
                    // Bars grow out of the zero rule in whichever direction the
                    // sign points; a losing window hangs below it.
                    y: Math.min(plot.zeroY, valueY)
                    height: Math.max(1, Math.abs(valueY - plot.zeroY))
                    color: root.colorFor(modelData.net)
                    opacity: hot ? 1.0 : 0.78
                  }
                }
              }

              // Reading off a bar is the whole point of hovering, so the
              // readout carries both the time and the figure.
              MouseArea {
                id: hoverArea
                x: chartSection.axisWidth
                width: plot.plotWidth
                height: plot.height
                hoverEnabled: true
                property var point: null
                onPositionChanged: function(mouse) {
                  point = Model.chartPointAt(chartSection.range, mouse.x / Math.max(1, width))
                }
                onExited: point = null
              }

              Text {
                anchors.right: parent.right
                anchors.top: parent.top
                textFormat: Text.PlainText
                visible: hoverArea.point !== null
                text: hoverArea.point
                      ? Model.pointLabel(hoverArea.point, chartSection.range)
                        + "   " + Model.signedMoney(hoverArea.point.net)
                      : ""
                color: hoverArea.point ? root.colorFor(hoverArea.point.net) : root.neutralColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.space(24)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                visible: !chartSection.hasPoints
                text: root.snapshot.status === "ok"
                      ? "No samples in this window yet — the graph fills in as the poller ticks."
                      : "Waiting for the poller to record its first sample."
                color: Qt.darker(root.neutralColor, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            // ---- Time axis.
            Item {
              width: parent.width
              height: Style.space(12)
              visible: chartSection.hasPoints

              Repeater {
                model: Model.chartTicks(chartSection.range, 4)

                Text {
                  required property var modelData
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: Qt.darker(root.neutralColor, 1.6)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  // Centred on the tick, but pinned inside the frame so the
                  // first and last labels do not hang off either edge.
                  x: {
                    var left = chartSection.axisWidth
                    var span = Math.max(1, parent.width - left)
                    var centred = left + span * modelData.at - implicitWidth / 2
                    return Math.max(left, Math.min(parent.width - implicitWidth, centred))
                  }
                }
              }
            }

            // Says why a 24h or 7d window looks mostly empty on the first day.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              visible: chartSection.hasPoints
                       && Model.chartCoverage(chartSection.range) < 0.95
              text: "History starts when the poller does — this window is still filling in."
              color: Qt.darker(root.neutralColor, 1.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator {
            width: parent.width
            visible: root.chartOpen
          }

          // ---- Account line: what the P/L is measured against.
          Grid {
            visible: root.showAccountRow && root.account !== null
            width: parent.width
            columns: 4
            columnSpacing: Style.space(14)
            rowSpacing: Style.space(4)

            Repeater {
              model: root.account ? [
                { label: "Balance", value: Model.money(root.account.balance), tone: "plain" },
                { label: "Equity", value: Model.money(root.account.equity), tone: "plain" },
                { label: "Margin", value: Model.money(root.account.usedMargin), tone: "plain" },
                { label: "Free", value: Model.money(root.account.freeMargin), tone: "plain" }
              ] : []

              Column {
                required property var modelData
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: modelData.label.toUpperCase()
                  color: Qt.darker(root.neutralColor, 1.5)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.value
                  color: root.neutralColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            visible: root.showAccountRow && root.account !== null
          }

          PanelSectionHeader {
            text: root.positions.length === 1
                  ? "1 OPEN POSITION"
                  : root.positions.length + " OPEN POSITIONS"
            foreground: root.neutralColor
          }

          // ---- Empty and error states, so the popup always says something.
          Text {
            visible: root.positions.length === 0
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: {
              if (root.snapshot.status === "unconfigured")
                return "No cTrader account connected yet.\n\nRun this once in a terminal:\n  ctrader-auth"
              if (root.snapshot.status === "error")
                return root.snapshot.error
              if (root.snapshot.status === "ok")
                return "Flat — nothing open right now."
              return "Waiting for the first snapshot…"
            }
            color: root.snapshot.status === "error" ? root.lossColor : Qt.darker(root.neutralColor, 1.3)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          // ---- One row per position, biggest mover first (the poller sorts).
          Repeater {
            model: root.positions

            Rectangle {
              id: positionRow
              required property var modelData
              width: column.width
              height: rowContent.implicitHeight + Style.space(12)
              radius: Style.space(6)
              color: rowHover.hovered ? Style.hoverFill : "transparent"

              HoverHandler {
                id: rowHover
                cursorShape: Qt.PointingHandCursor
              }

              // Click a position to chart it on TradingView.
              TapHandler {
                acceptedButtons: Qt.LeftButton
                onTapped: root.openChart(positionRow.modelData.symbol)
              }

              Row {
                id: rowContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                // Side marker: a coloured rule is faster to scan down a
                // column than the words BUY and SELL.
                Rectangle {
                  width: Style.space(3)
                  height: rowLeft.implicitHeight
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: positionRow.modelData.side === "SELL"
                         ? Qt.darker(root.neutralColor, 1.6)
                         : root.neutralColor
                }

                Column {
                  id: rowLeft
                  width: parent.width - rowRight.width - Style.space(16)
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    text: positionRow.modelData.symbol
                    color: root.neutralColor
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: parent.width
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    elide: Text.ElideRight
                    text: {
                      var m = positionRow.modelData
                      var bits = [m.side + " " + Model.formatLots(m.lots) + " lot"
                                  + (Math.abs(Number(m.lots) - 1) < 0.0001 ? "" : "s"),
                                  "@ " + Model.formatPrice(m.openPrice, m.digits)]
                      var age = Model.openedAgo(m.openedAt, root.nowMs)
                      if (age) bits.push(age)
                      return bits.join("  ·  ")
                    }
                    color: Qt.darker(root.neutralColor, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                Column {
                  id: rowRight
                  spacing: Style.space(2)

                  // Width comes only from the two labels' implicit widths, and
                  // each label is then sized from that. Binding either label to
                  // parent.width instead would make the Column's width depend on
                  // a child whose width depends on the Column — a loop QML
                  // resolves by blowing the JS stack.
                  readonly property real colWidth: Math.max(rowPnl.implicitWidth,
                                                            rowCosts.visible ? rowCosts.implicitWidth : 0)
                  width: colWidth

                  Text {
                    id: rowPnl
                    textFormat: Text.PlainText
                    text: Model.signedMoney(positionRow.modelData.pnl)
                    color: root.colorFor(positionRow.modelData.pnl)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    horizontalAlignment: Text.AlignRight
                    width: rowRight.colWidth
                  }

                  Text {
                    id: rowCosts
                    textFormat: Text.PlainText
                    // Swap and commission are already inside the net figure
                    // above; showing them tells you how much of the number is
                    // carry rather than direction.
                    visible: Math.abs(Number(positionRow.modelData.swap) || 0)
                             + Math.abs(Number(positionRow.modelData.commission) || 0) >= 0.005
                    text: "sw " + Model.money(positionRow.modelData.swap)
                          + "  cm " + Model.money(positionRow.modelData.commission)
                    color: Qt.darker(root.neutralColor, 1.6)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignRight
                    width: rowRight.colWidth
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
