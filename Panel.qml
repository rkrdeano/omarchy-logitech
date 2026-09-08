import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Every label below carries `textFormat: Text.PlainText`. Device names and
// pairing output are chosen by the peripheral, and Qt's default AutoText turns
// anything markup-shaped into rich text — which will load the resources it
// names, from inside the long-lived shell process. Labels this plugin does not
// own (the bar tooltip, PanelHero) cannot be configured that way, so the
// strings handed to them go through Model.plainText instead.
Panel {
  id: root
  moduleName: "io.github.rkrdeano.logitech"
  ipcTarget: "io.github.rkrdeano.logitech"
  manageIpc: false

  property int rowIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property bool vertical: bar ? bar.vertical : false

  readonly property bool showBattery: logi.boolSetting("showBattery", true)
  readonly property bool hideWhenNoReceiver: logi.boolSetting("hideWhenNoReceiver", true)

  // Prefer the icon of whatever is actually awake: a live mouse or keyboard
  // says more than the dongle it happens to be talking through.
  readonly property string barGlyph: {
    var devices = Model.allDevices(logi.status)
    var keyboard = false
    for (var i = 0; i < devices.length; i++) {
      if (!devices[i].online) continue
      var icon = Model.deviceIcon(devices[i].kind)
      if (icon === Model.ICON.mouse) return Model.ICON.mouse
      if (icon === Model.ICON.keyboard) keyboard = true
    }
    if (keyboard) return Model.ICON.keyboard
    return Model.ICON.receiver
  }

  // Battery text is dropped on a vertical bar, where a widget only gets the
  // bar's width and the percentage would be clipped.
  readonly property string barText: {
    if (!root.showBattery || root.vertical) return root.barGlyph
    var pct = logi.lowestBattery
    return pct < 0 ? root.barGlyph : root.barGlyph + " " + pct + "%"
  }

  function selectedRow() {
    var rows = logi.rows
    if (!rows || rows.length === 0) return null
    if (rowIndex < 0 || rowIndex >= rows.length) return null
    var row = rows[rowIndex]
    return row && row.selectable ? row : null
  }

  function ensureCursor() {
    var rows = logi.rows
    if (!rows || rows.length === 0) { rowIndex = 0; return }
    if (rowIndex >= 0 && rowIndex < rows.length && rows[rowIndex].selectable) return
    var first = Model.firstSelectable(rows)
    rowIndex = first < 0 ? 0 : first
  }

  function moveCursor(dy) {
    if (logi.pairingReceiver) return
    cursorActive = true
    ensureCursor()
    // A pending unpair owns the cursor until it is confirmed or dismissed.
    if (logi.unpairTarget) return
    if (dy !== 0) rowIndex = Model.stepCursor(logi.rows, rowIndex, dy > 0 ? 1 : -1)
  }

  function activateCursor() {
    if (logi.unpairTarget) { logi.confirmUnpair(); return }
    var row = selectedRow()
    if (!row) return
    if (row.type === "pair") logi.startPairing(row.receiver)
    else if (row.type === "device") logi.requestUnpair(row.receiver, row.device)
  }

  function deleteSelected() {
    if (logi.unpairTarget) return
    var row = selectedRow()
    if (row && row.type === "device") logi.requestUnpair(row.receiver, row.device)
  }

  // Escape peels one layer at a time: pairing, then a pending unpair, then
  // the panel itself.
  function popLayer() {
    if (logi.pairingReceiver) {
      if (logi.pairing) logi.cancelPairing()
      else logi.dismissPairing()
      return
    }
    if (logi.unpairTarget) { logi.cancelUnpair(); return }
    root.close()
  }

  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0
  visible: !root.hideWhenNoReceiver || logi.hasReceiver

  onOpenedChanged: if (opened) {
    cursorActive = false
    logi.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: logi
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { logi.refresh(); return "ok" }
    function status(): string { return logi.statusText }
    function battery(): string {
      var dev = Model.lowestBatteryDevice(logi.status)
      return dev ? dev.name + " " + Model.batteryText(dev) : "no battery reading"
    }
    function cancelPair(): string { root.popLayer(); return "ok" }
    // What the pairing card is showing, without needing the panel on screen.
    function pairingState(): string {
      if (!logi.pairingReceiver) return "idle"
      var parts = [logi.pairing ? "running" : (logi.pendingPairReceiver ? "queued" : "finished")]
      parts.push("elapsed=" + logi.pairingElapsedSec + "s")
      parts.push("result=" + (logi.pairingResult === "" ? "pending" : logi.pairingResult))
      parts.push("passkeyShown=" + (logi.pairingPasskey !== "" && logi.pairingResult === ""))
      parts.push("lines=" + logi.pairingLines.length)
      return parts.join(" ")
    }
    // Pairs against the first receiver unless one is named; the panel shows
    // the instructions, so open it too.
    function pair(receiver: string): string {
      var receivers = logi.status.receivers || []
      if (receivers.length === 0) return "no receiver"
      var target = receivers[0]
      var wanted = String(receiver || "")
      if (wanted !== "") {
        for (var i = 0; i < receivers.length; i++) {
          if (String(receivers[i].serial) === wanted
            || String(receivers[i].kind).toLowerCase() === wanted.toLowerCase()) target = receivers[i]
        }
      }
      root.open()
      logi.startPairing(target)
      if (!logi.pairingReceiver) return "could not start pairing"
      return (logi.pairing ? "pairing with " : "pairing queued for ") + Model.receiverLabel(target)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    fontSize: Style.bar.iconFont
    active: logi.batteryLow || logi.pairing
    activeColor: logi.pairing ? Color.accent : root.urgent
    opacity: logi.onlineCount > 0 ? 1.0 : 0.6
    tooltipText: {
      if (logi.pairing) return "Pairing… click to watch"
      if (!logi.hasReceiver) return "No Logitech receiver plugged in"
      var dev = Model.lowestBatteryDevice(logi.status)
      var base = logi.statusText
      if (dev) base += " — " + dev.name + " " + Model.batteryText(dev)
      // Rendered by the bar's own tooltip, which uses AutoText.
      return Model.plainText(base + " · right-click to refresh", 200)
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) logi.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive || logi.unpairTarget) root.activateCursor()
      onCloseRequested: root.popLayer()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.cursorActive) root.deleteSelected()
      onTextKey: function(t) {
        if (t === "r" || t === "R") logi.refresh()
        else if (t === "u" || t === "U") root.deleteSelected()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Logitech"
            meta: Model.plainText(logi.pairing
              ? "Pairing… " + logi.pairingElapsedSec + "s"
              : logi.statusText, 120)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: logi.onlineCount > 0 ? 1.0 : 0.6
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.barGlyph
                color: logi.batteryLow ? root.urgent : (logi.onlineCount > 0 ? Color.accent : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: Model.ICON.refresh
                tooltipText: "Refresh"
                enabled: !logi.refreshing && !logi.pairing
                opacity: logi.refreshing ? 0.5 : 1.0
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: logi.refresh()
              }
            }
          }

          // ---------- Pairing takes over the panel while it runs ----------
          Column {
            id: pairingCard
            width: parent.width
            spacing: Style.space(10)
            visible: logi.pairingReceiver !== null

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              textFormat: Text.PlainText
              text: logi.pairing ? "PAIRING" : (logi.pairingResult === "success" ? "PAIRED" : "PAIRING FINISHED")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: logi.pairingReceiver ? Model.receiverLabel(logi.pairingReceiver) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // The passkey is the one line the user must act on, so it is
            // pulled out of the transcript and shown large.
            BorderSurface {
              width: parent.width
              // Only while it is still something to act on: once pairing has
              // succeeded or failed, a passkey on screen is a stale
              // instruction telling you to do work that is already done.
              visible: logi.pairingPasskey !== "" && logi.pairingResult === ""
              radius: Style.cornerRadius
              color: Style.selectedFillFor(root.foreground, Color.accent)
              implicitHeight: passkeyText.implicitHeight + Style.space(20)

              Text {
                textFormat: Text.PlainText
                id: passkeyText
                anchors.centerIn: parent
                width: parent.width - Style.space(20)
                text: logi.pairingPasskey
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: logi.pairingPasskey !== "" && logi.pairingResult === ""
              text: "Once you press enter the device is paired, but the receiver "
                + "can take another half minute to confirm it here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: logi.pairingLines

              Text {
                textFormat: Text.PlainText
                required property var modelData
                width: pairingCard.width
                // Once there is an outcome, the steps that led to it are
                // noise; leave only the line that says what happened.
                visible: modelData.kind !== "passkey"
                  && (logi.pairingResult === "" || modelData.kind === "success" || modelData.kind === "error")
                text: modelData.text
                color: modelData.kind === "error" ? root.urgent
                  : (modelData.kind === "success" ? Color.accent : root.foreground)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }

            Button {
              width: parent.width
              bordered: true
              text: logi.pairing
                ? (logi.pairingPasskey === "" ? "Cancel pairing" : "Stop waiting")
                : "Done"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.popLayer()
            }
          }

          // ---------- Receivers and their devices ----------
          Column {
            id: rowList
            width: parent.width
            spacing: Style.space(4)
            visible: !pairingCard.visible

            Repeater {
              model: logi.rows

              Loader {
                required property var modelData
                required property int index
                width: rowList.width
                sourceComponent: {
                  if (modelData.type === "device") return deviceRowComponent
                  if (modelData.type === "pair") return pairRowComponent
                  if (modelData.type === "receiver") return receiverRowComponent
                  return noteRowComponent
                }
                onLoaded: {
                  item.row = modelData
                  item.rowIndex = index
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: !logi.hasReceiver && (logi.status.devices || []).length === 0
              text: logi.refreshing
                ? "Looking for receivers…"
                : "No Logitech receiver found.\n\nPlug a Unifying or Bolt receiver into a USB port; it appears here on its own."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: logi.lastError !== ""
            text: Model.ICON.alert + "  " + logi.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !pairingCard.visible && logi.hasReceiver
            text: "enter: pair / unpair · u: unpair · r: refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ---------- Row components ----------

  Component {
    id: receiverRowComponent

    Item {
      property var row: null
      property int rowIndex: 0
      implicitHeight: receiverContent.implicitHeight + Style.space(10)

      Column {
        id: receiverContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(2)

        PanelSectionHeader {
          textFormat: Text.PlainText
          text: row ? row.label.toUpperCase() : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          text: row ? row.meta : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Component {
    id: noteRowComponent

    Text {
      textFormat: Text.PlainText
      property var row: null
      property int rowIndex: 0
      text: row ? row.label : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      leftPadding: Style.space(10)
      topPadding: Style.space(4)
      bottomPadding: Style.space(4)
    }
  }

  Component {
    id: deviceRowComponent

    CursorSurface {
      id: deviceRow
      property var row: null
      property int rowIndex: 0

      readonly property var device: row ? row.device : null
      readonly property bool selected: root.cursorActive && root.rowIndex === rowIndex
      readonly property bool confirming: logi.unpairTarget
        && row && row.receiver
        && logi.unpairTarget.device.number === (device ? device.number : -1)
        && logi.unpairTarget.receiver.serial === row.receiver.serial

      hasCursor: selected && !confirming
      current: confirming
      foreground: root.foreground
      implicitHeight: deviceContent.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        id: deviceMouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: row && row.selectable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onContainsMouseChanged: if (containsMouse && row && row.selectable) {
          root.cursorActive = true
          root.rowIndex = deviceRow.rowIndex
        }
        onClicked: function(mouse) {
          if (!row || !row.selectable) return
          if (mouse.button === Qt.RightButton) logi.requestUnpair(row.receiver, deviceRow.device)
        }
      }

      Item {
        id: deviceContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        implicitHeight: Math.max(deviceIcon.implicitHeight, deviceLabels.implicitHeight, unpairBtn.implicitHeight, confirmRow.implicitHeight)

        Text {
          textFormat: Text.PlainText
          id: deviceIcon
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: deviceRow.device ? Model.deviceIcon(deviceRow.device.kind) : ""
          color: deviceRow.device && deviceRow.device.online ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        Column {
          id: deviceLabels
          anchors.left: deviceIcon.right
          anchors.leftMargin: Style.space(10)
          anchors.right: confirmRow.visible ? confirmRow.left : (batteryLabel.visible ? batteryLabel.left : unpairBtn.left)
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)
          visible: !confirmRow.visible

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: deviceRow.device ? deviceRow.device.name : ""
            color: deviceRow.device && deviceRow.device.online ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: deviceRow.device ? Model.statusLine(deviceRow.device) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          textFormat: Text.PlainText
          id: batteryLabel
          anchors.right: unpairBtn.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          visible: !confirmRow.visible && deviceRow.device !== null && Model.batteryPercent(deviceRow.device) >= 0
          text: deviceRow.device ? Model.batteryIcon(deviceRow.device) : ""
          color: {
            var pct = deviceRow.device ? Model.batteryPercent(deviceRow.device) : -1
            if (pct >= 0 && pct <= logi.lowBatteryPercent) return root.urgent
            return deviceRow.device && deviceRow.device.battery && deviceRow.device.battery.charging ? Color.accent : root.dim
          }
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        PanelActionButton {
          id: unpairBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !confirmRow.visible && row !== null && row.selectable
            && (deviceMouse.containsMouse || deviceRow.selected)
          iconText: Model.ICON.unpair
          tooltipText: "Unpair"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onClicked: if (row) logi.requestUnpair(row.receiver, deviceRow.device)
        }

        // Inline confirmation rather than a modal: the row you are about to
        // clear stays on screen and in place while you decide.
        Row {
          id: confirmRow
          anchors.right: parent.right
          anchors.left: deviceIcon.right
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          visible: deviceRow.confirming
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, confirmRow.width - cancelButton.width - unpairButton.width - Style.space(16))
            text: "Unpair " + (deviceRow.device ? deviceRow.device.name : "") + "?"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Button {
            id: cancelButton
            anchors.verticalCenter: parent.verticalCenter
            text: "Cancel"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: logi.cancelUnpair()
          }

          Button {
            id: unpairButton
            anchors.verticalCenter: parent.verticalCenter
            text: "Unpair"
            bordered: true
            hasCursor: true
            foreground: root.urgent
            accent: root.urgent
            fontFamily: root.fontFamily
            onClicked: logi.confirmUnpair()
          }
        }
      }
    }
  }

  Component {
    id: pairRowComponent

    CursorSurface {
      id: pairRow
      property var row: null
      property int rowIndex: 0

      readonly property bool selected: root.cursorActive && root.rowIndex === rowIndex
      readonly property bool available: row !== null && row.selectable

      hasCursor: selected && available
      foreground: root.foreground
      opacity: available ? 1.0 : 0.5
      implicitHeight: pairContent.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: pairRow.available ? Qt.PointingHandCursor : Qt.ArrowCursor
        onContainsMouseChanged: if (containsMouse && pairRow.available) {
          root.cursorActive = true
          root.rowIndex = pairRow.rowIndex
        }
        onClicked: if (pairRow.available && row) logi.startPairing(row.receiver)
      }

      Row {
        id: pairContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: Model.ICON.pair
          color: pairRow.available ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: row ? row.label : ""
          color: pairRow.available ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
