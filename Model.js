// Shaping helpers for the Logitech widget. No QML types in here, so the
// parsing and row-building can be exercised with plain JS.

// Nerd Font glyphs, written as surrogate pairs so this file stays ASCII.
var ICON = {
  mouse: "󰍽",            // nf-md-mouse
  keyboard: "󰌌",         // nf-md-keyboard
  receiver: "󰕓",         // nf-md-usb
  battery: "󰁹",          // nf-md-battery
  batteryCharging: "󰂄",  // nf-md-battery-charging
  batteryUnknown: "󰁺",   // nf-md-battery-unknown
  pair: "󰐗",             // nf-md-plus-circle
  unpair: "󰅙",           // nf-md-close-circle
  refresh: "󰑐",          // nf-md-refresh
  alert: "󰀦"             // nf-md-alert
}

function emptyStatus() {
  return { receivers: [], devices: [], errors: [], ok: false }
}

// Bounds for anything a peripheral chooses. `bin/logi-status` already caps its
// output, but a plugin must not depend on its own helper being the only thing
// that ever reaches these bindings, so the caps are re-applied here.
var MAX_TEXT = 64
var MAX_LINE = 200
var MAX_RECEIVERS = 8
var MAX_DEVICES = 16
var MAX_PAIRING_LINES = 40

// Strip control characters (which can reflow or blank a label) and truncate.
function safeText(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\u0000-\u001F\u007F-\u009F]/g, " ").trim()
  var max = limit || MAX_TEXT
  return text.length > max ? text.substring(0, max - 1) + "\u2026" : text
}

// For sinks this plugin does not own — the shell's bar tooltip and PanelHero
// render with Qt's default AutoText, which turns anything markup-shaped into
// rich text and will load the resources it names. Qt only takes that path when
// it sees a tag or an entity, so removing "<", ">" and "&" keeps a
// device-chosen string literal no matter how the sink is configured.
function plainText(value, limit) {
  return safeText(value, limit).replace(/[<>&]/g, "")
}

function normalizeDevice(dev) {
  if (!dev || typeof dev !== "object") return null
  var battery = null
  if (dev.battery && typeof dev.battery === "object") {
    var percent = parseInt(dev.battery.percent, 10)
    battery = {
      percent: isFinite(percent) ? Math.max(0, Math.min(100, percent)) : null,
      approximate: safeText(dev.battery.approximate, 32),
      status: safeText(dev.battery.status, 32),
      charging: dev.battery.charging === true
    }
  }
  var number = parseInt(dev.number, 10)
  return {
    number: isFinite(number) ? number : 0,
    name: safeText(dev.name) || "Unknown device",
    codename: safeText(dev.codename, 32),
    kind: safeText(dev.kind, 24),
    serial: safeText(dev.serial, 32),
    wpid: safeText(dev.wpid, 16),
    online: dev.online === true,
    battery: battery
  }
}

function normalizeReceiver(rcv) {
  if (!rcv || typeof rcv !== "object") return null
  var devices = []
  var source = rcv.devices || []
  for (var i = 0; i < source.length && devices.length < MAX_DEVICES; i++) {
    var dev = normalizeDevice(source[i])
    if (dev) devices.push(dev)
  }
  var paired = parseInt(rcv.paired, 10)
  var maximum = parseInt(rcv.maxDevices, 10)
  return {
    name: safeText(rcv.name) || "Logitech Receiver",
    path: safeText(rcv.path, 128),
    serial: safeText(rcv.serial, 32),
    kind: safeText(rcv.kind, 24),
    paired: isFinite(paired) ? paired : devices.length,
    maxDevices: isFinite(maximum) ? maximum : 0,
    canPair: rcv.canPair !== false,
    devices: devices
  }
}

// `bin/logi-status` emits one JSON object. Anything else — a Python
// traceback, an empty read after the process was killed — is treated as
// "no data" rather than throwing inside a QML binding.
function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return emptyStatus()
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return emptyStatus()
  }
  if (!data || typeof data !== "object") return emptyStatus()

  var receivers = []
  var rawReceivers = data.receivers || []
  for (var i = 0; i < rawReceivers.length && receivers.length < MAX_RECEIVERS; i++) {
    var rcv = normalizeReceiver(rawReceivers[i])
    if (rcv) receivers.push(rcv)
  }

  var devices = []
  var rawDevices = data.devices || []
  for (var j = 0; j < rawDevices.length && devices.length < MAX_DEVICES; j++) {
    var dev = normalizeDevice(rawDevices[j])
    if (dev) devices.push(dev)
  }

  var errors = []
  var rawErrors = data.errors || []
  for (var k = 0; k < rawErrors.length && errors.length < 5; k++) {
    errors.push(safeText(rawErrors[k], MAX_LINE))
  }

  return {
    receivers: receivers,
    devices: devices,
    errors: errors,
    error: safeText(data.error, MAX_LINE),
    ok: true
  }
}

function deviceIcon(kind) {
  var k = String(kind || "").toLowerCase()
  if (k.indexOf("keyboard") >= 0 || k.indexOf("numpad") >= 0) return ICON.keyboard
  return ICON.mouse
}

function kindLabel(kind) {
  var k = String(kind || "").trim()
  if (k === "") return "device"
  return k.charAt(0).toUpperCase() + k.slice(1)
}

function receiverLabel(rcv) {
  if (!rcv) return ""
  var kind = String(rcv.kind || "").toLowerCase()
  if (kind === "bolt") return "Bolt receiver"
  if (kind === "unifying") return "Unifying receiver"
  if (kind === "nano") return "Nano receiver"
  return String(rcv.name || "Receiver")
}

// A short receiver id for tooltips and the confirm dialog. Bolt serials are
// 32 hex characters, which is too long to show whole.
function shortSerial(serial) {
  var s = String(serial || "")
  return s.length > 10 ? s.slice(0, 8) + "…" : s
}

function batteryPercent(dev) {
  if (!dev || !dev.battery) return -1
  var p = dev.battery.percent
  return typeof p === "number" && isFinite(p) ? p : -1
}

// "95%", "good", or "" when the device won't report anything.
function batteryText(dev) {
  if (!dev || !dev.battery) return ""
  var pct = batteryPercent(dev)
  if (pct >= 0) return pct + "%"
  var approx = String(dev.battery.approximate || "")
  return approx === "" ? "" : approx
}

function batteryIcon(dev) {
  if (!dev || !dev.battery) return ICON.batteryUnknown
  return dev.battery.charging ? ICON.batteryCharging : ICON.battery
}

function statusLine(dev) {
  if (!dev) return ""
  if (!dev.online) return "Offline"
  var parts = []
  var battery = batteryText(dev)
  if (battery !== "") {
    var state = String(dev.battery && dev.battery.status || "")
    parts.push(state === "discharging" || state === "" ? battery : battery + " · " + state)
  }
  parts.push(kindLabel(dev.kind))
  return parts.join(" · ")
}

function allDevices(status) {
  var out = []
  var receivers = status && status.receivers ? status.receivers : []
  for (var i = 0; i < receivers.length; i++) {
    var devs = receivers[i].devices || []
    for (var j = 0; j < devs.length; j++) out.push(devs[j])
  }
  var wired = status && status.devices ? status.devices : []
  for (var k = 0; k < wired.length; k++) out.push(wired[k])
  return out
}

function onlineCount(status) {
  var devs = allDevices(status)
  var n = 0
  for (var i = 0; i < devs.length; i++) if (devs[i].online) n += 1
  return n
}

// Lowest battery among *online* devices; offline ones report nothing useful,
// so counting them would keep the bar permanently at "unknown".
function lowestBattery(status) {
  var devs = allDevices(status)
  var lowest = -1
  for (var i = 0; i < devs.length; i++) {
    if (!devs[i].online) continue
    var pct = batteryPercent(devs[i])
    if (pct < 0) continue
    if (lowest < 0 || pct < lowest) lowest = pct
  }
  return lowest
}

function lowestBatteryDevice(status) {
  var devs = allDevices(status)
  var best = null
  var bestPct = -1
  for (var i = 0; i < devs.length; i++) {
    if (!devs[i].online) continue
    var pct = batteryPercent(devs[i])
    if (pct < 0) continue
    if (best === null || pct < bestPct) { best = devs[i]; bestPct = pct }
  }
  return best
}

function summary(status) {
  if (!status || !status.ok) return "Reading receivers…"
  var receivers = status.receivers || []
  var devs = allDevices(status)
  if (receivers.length === 0 && devs.length === 0) return "No Logitech receiver"
  if (devs.length === 0) return receivers.length === 1 ? "Receiver, no paired devices" : receivers.length + " receivers, no paired devices"
  var online = onlineCount(status)
  var devText = devs.length === 1 ? "1 device" : devs.length + " devices"
  return devText + ", " + online + " online"
}

// Flatten receivers and their devices into the list the panel renders and the
// keyboard cursor walks. Header rows carry `selectable: false` so j/k skip
// straight between the things you can actually act on.
function buildRows(status) {
  var rows = []
  var receivers = status && status.receivers ? status.receivers : []
  for (var i = 0; i < receivers.length; i++) {
    var rcv = receivers[i]
    rows.push({
      type: "receiver",
      key: "r:" + (rcv.serial || i),
      selectable: false,
      receiver: rcv,
      label: receiverLabel(rcv),
      meta: rcv.paired + " of " + (rcv.maxDevices || "?") + " slots used"
    })
    var devs = rcv.devices || []
    for (var j = 0; j < devs.length; j++) {
      rows.push({
        type: "device",
        key: "d:" + (rcv.serial || i) + ":" + devs[j].number,
        selectable: true,
        receiver: rcv,
        device: devs[j]
      })
    }
    if (devs.length === 0) {
      rows.push({
        type: "empty",
        key: "e:" + (rcv.serial || i),
        selectable: false,
        label: "No devices paired to this receiver"
      })
    }
    rows.push({
      type: "pair",
      key: "p:" + (rcv.serial || i),
      selectable: rcv.canPair !== false,
      receiver: rcv,
      label: rcv.canPair === false ? "All pairing slots are full" : "Pair a new device"
    })
  }
  var wired = status && status.devices ? status.devices : []
  if (wired.length > 0) {
    rows.push({ type: "section", key: "s:wired", selectable: false, label: "Directly connected" })
    for (var k = 0; k < wired.length; k++) {
      rows.push({
        type: "device",
        key: "w:" + (wired[k].serial || k),
        selectable: false,   // nothing to unpair: no receiver in the middle
        receiver: null,
        device: wired[k]
      })
    }
  }
  return rows
}

function firstSelectable(rows) {
  for (var i = 0; i < rows.length; i++) if (rows[i].selectable) return i
  return -1
}

// Step to the next selectable row in `direction`, staying put at the ends
// rather than wrapping — wrapping in a short list feels like a glitch.
function stepCursor(rows, from, direction) {
  var i = from + direction
  while (i >= 0 && i < rows.length) {
    if (rows[i].selectable) return i
    i += direction
  }
  return from
}

// Classify a line of `solaar pair` output for display. The passkey line is
// the one that matters most, so it gets its own kind and is stripped down to
// the instruction itself.
function classifyPairLine(line) {
  // A pairing line is process output, so it gets the same treatment as a
  // device name: control characters out, length capped.
  var text = safeText(line, MAX_LINE)
  if (text === "") return null
  var lower = text.toLowerCase()
  if (lower.indexOf("rules cannot access modifier keys") >= 0) return null  // solaar's Wayland notice
  if (lower.indexOf("passkey") >= 0 || lower.indexOf("press left and right") >= 0 || /bolt pairing: press /.test(lower)) {
    return { kind: "passkey", text: text.replace(/^Bolt Pairing:\s*/i, "") }
  }
  if (lower.indexOf("paired device") >= 0) return { kind: "success", text: text }
  if (lower.indexOf("error") >= 0 || lower.indexOf("failed") >= 0 || lower.indexOf("no bolt-compatible") >= 0) {
    return { kind: "error", text: text.replace(/^solaar:\s*error:\s*/i, "") }
  }
  return { kind: "info", text: text.replace(/^Bolt Pairing:\s*/i, "") }
}

function elide(text, limit) {
  return safeText(String(text || "").replace(/\s+/g, " "), limit || 160)
}

if (typeof module !== "undefined") {
  module.exports = {
    ICON: ICON, parseStatus: parseStatus, deviceIcon: deviceIcon, kindLabel: kindLabel,
    safeText: safeText, plainText: plainText, MAX_PAIRING_LINES: MAX_PAIRING_LINES,
    normalizeDevice: normalizeDevice, normalizeReceiver: normalizeReceiver,
    receiverLabel: receiverLabel, shortSerial: shortSerial, batteryPercent: batteryPercent,
    batteryText: batteryText, batteryIcon: batteryIcon, statusLine: statusLine,
    allDevices: allDevices, onlineCount: onlineCount, lowestBattery: lowestBattery,
    lowestBatteryDevice: lowestBatteryDevice, summary: summary, buildRows: buildRows,
    firstSelectable: firstSelectable, stepCursor: stepCursor,
    classifyPairLine: classifyPairLine, elide: elide
  }
}
