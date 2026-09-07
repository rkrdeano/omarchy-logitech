import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property var status: Model.emptyStatus()
  property var rows: Model.buildRows(status)
  property string lastError: ""
  property bool refreshing: false

  // Pairing is a live conversation with the user ("press the button now"),
  // so the transcript is kept as it arrives rather than only at exit.
  property var pairingReceiver: null
  property var pairingLines: []
  property string pairingPasskey: ""
  property string pairingResult: ""     // "", "success", "error"
  readonly property bool pairing: pairProcess.running

  property var unpairTarget: null       // { receiver, device } awaiting confirmation
  readonly property bool unpairing: unpairProcess.running

  readonly property string binDir: {
    var url = String(Qt.resolvedUrl("bin/"))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  readonly property bool hasReceiver: (status.receivers || []).length > 0
  readonly property string statusText: Model.summary(status)
  readonly property int lowestBattery: Model.lowestBattery(status)
  readonly property int onlineCount: Model.onlineCount(status)
  readonly property int lowBatteryPercent: intSetting("lowBatteryPercent", 20, 0, 100)
  readonly property bool batteryLow: lowestBattery >= 0 && lowestBattery <= lowBatteryPercent
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 120, 30, 3600)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    return value === true || String(value) === "true"
  }

  // Talking to a receiver means opening its hidraw device and pinging every
  // paired device, so a poll must never overlap a pairing or an unpair.
  function refresh() {
    if (statusProcess.running || pairProcess.running || unpairProcess.running) return
    refreshing = true
    statusProcess.command = [root.binDir + "logi-status"]
    statusProcess.running = true
  }

  function startPairing(receiver) {
    if (!receiver || pairProcess.running || statusProcess.running) return
    root.pairingReceiver = receiver
    root.pairingLines = []
    root.pairingPasskey = ""
    root.pairingResult = ""
    root.lastError = ""
    // Match by serial: two receivers of the same kind would both answer to a
    // name substring, and Solaar would just take the first.
    pairProcess.command = [root.binDir + "logi-pair", String(receiver.serial || receiver.name || "")]
    pairProcess.running = true
  }

  function cancelPairing() {
    if (pairProcess.running) pairProcess.running = false
    root.pairingResult = ""
    root.pairingReceiver = null
    root.pairingLines = []
    root.pairingPasskey = ""
  }

  function dismissPairing() {
    root.pairingReceiver = null
    root.pairingLines = []
    root.pairingPasskey = ""
    root.pairingResult = ""
  }

  function requestUnpair(receiver, device) {
    if (!receiver || !device) return
    root.unpairTarget = { receiver: receiver, device: device }
  }

  function cancelUnpair() {
    root.unpairTarget = null
  }

  function confirmUnpair() {
    var target = root.unpairTarget
    root.unpairTarget = null
    if (!target || unpairProcess.running || statusProcess.running) return
    root.lastError = ""
    unpairProcess.command = [
      root.binDir + "logi-unpair",
      String(target.receiver.serial || target.receiver.name || ""),
      String(target.device.number)
    ]
    unpairProcess.running = true
  }

  function appendPairingLine(line) {
    var entry = Model.classifyPairLine(line)
    if (!entry) return
    var next = root.pairingLines.slice()
    next.push(entry)
    root.pairingLines = next
    if (entry.kind === "passkey") root.pairingPasskey = entry.text
    else if (entry.kind === "success") root.pairingResult = "success"
    else if (entry.kind === "error") root.pairingResult = "error"
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Receivers come and go with the USB port. udev tells us the moment a
  // hidraw node appears or disappears, which beats waiting out the poll.
  Timer {
    id: udevDebounce
    interval: 900
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      var parsed = Model.parseStatus(String(statusStdout.text || ""))
      if (parsed.ok) {
        root.status = parsed
        root.rows = Model.buildRows(parsed)
        root.lastError = parsed.error ? Model.elide(parsed.error) : ""
      } else {
        root.lastError = Model.elide(String(statusStderr.text || "") || "Could not read Logitech receivers")
      }
    }
  }

  Process {
    id: pairProcess
    running: false
    // Solaar prints the pairing instructions one line at a time; each one is
    // shown as it lands so the user can follow along.
    stdout: SplitParser { onRead: function(line) { root.appendPairingLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.appendPairingLine(line) } }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.pairingResult === "") {
        root.pairingResult = "error"
        root.appendPairingLine("Pairing did not complete.")
      } else if (root.pairingResult === "") {
        // Solaar exited cleanly without a "Paired device" line: the pairing
        // window simply timed out with nobody pressing a button.
        root.pairingResult = "error"
        root.appendPairingLine("No device paired before the receiver timed out.")
      }
      root.refresh()
    }
  }

  Process {
    id: unpairProcess
    running: false
    stdout: StdioCollector { id: unpairStdout; waitForEnd: true }
    stderr: StdioCollector { id: unpairStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = Model.elide(String(unpairStderr.text || "") || String(unpairStdout.text || "") || "Unpair failed")
      }
      root.refresh()
    }
  }

  Process {
    id: udevProcess
    running: true
    // stdbuf: udevadm block-buffers when its stdout is a pipe, which would
    // hold events until the buffer filled — minutes late, or never.
    command: ["stdbuf", "-oL", "udevadm", "monitor", "--udev", "--subsystem-match=hidraw"]
    stdout: SplitParser {
      onRead: function(line) {
        if (String(line).indexOf("hidraw") >= 0) udevDebounce.restart()
      }
    }
    onExited: udevRestart.restart()
  }

  Timer {
    id: udevRestart
    interval: 5000
    repeat: false
    onTriggered: udevProcess.running = true
  }
}
