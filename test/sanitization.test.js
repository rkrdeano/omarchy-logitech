// Bounds and escaping for peripheral-controlled strings.
//
// Every name, battery word, and line of pairing output in this plugin is
// chosen by the device or by the solaar process, not by us. Run with:
//
//   node test/sanitization.test.js

const M = require("../Model.js")

let failures = 0

function check(name, condition, got) {
  if (condition) {
    console.log("PASS  " + name)
  } else {
    console.log("FAIL  " + name + "  got: " + JSON.stringify(got))
    failures++
  }
}

const markup = '<img src="http://evil.example/x">'

// The bar tooltip and PanelHero belong to the shell and render with Qt's
// default AutoText, which loads the resources any markup names. Strings bound
// for them must not contain the characters that put Qt on that path.
const tooltip = M.plainText("2 devices, 1 online - Mouse " + markup + " 42%", 200)
check("tooltip carries no markup characters", !/[<>&]/.test(tooltip), tooltip)

// Panel labels render PlainText, so they may keep the characters; what they
// must not do is grow without bound.
const status = M.parseStatus(JSON.stringify({
  receivers: [{
    name: "R", kind: "bolt", paired: 1, maxDevices: 6, canPair: true,
    devices: [{
      number: 1, name: "Mouse " + "A".repeat(9000), kind: "mouse", online: true,
      battery: { percent: -5, status: "x" }
    }]
  }],
  devices: [], errors: []
}))
const device = status.receivers[0].devices[0]
check("device name is capped", device.name.length <= 64, device.name.length)
check("battery percent is clamped", device.battery.percent === 0, device.battery.percent)

const flood = M.parseStatus(JSON.stringify({
  receivers: Array.from({ length: 50 }, (_, i) => ({
    name: "R" + i, kind: "bolt", paired: 0, maxDevices: 6, canPair: true,
    devices: Array.from({ length: 90 }, (_, j) => ({ number: j, name: "D" + j, kind: "mouse", online: false }))
  })),
  devices: [], errors: []
}))
check("receiver count is capped", flood.receivers.length === 8, flood.receivers.length)
check("device count is capped", flood.receivers[0].devices.length === 16, flood.receivers[0].devices.length)

const longLine = M.classifyPairLine("Bolt Pairing: type passkey " + "9".repeat(4000))
check("pairing line is capped", longLine.text.length <= 200, longLine.text.length)

const escaped = M.classifyPairLine("ok" + String.fromCharCode(27) + "[2Jwiped")
check("control characters are stripped", escaped.text.indexOf(String.fromCharCode(27)) === -1, escaped.text)

check("pairing transcript has a line limit", M.MAX_PAIRING_LINES === 40, M.MAX_PAIRING_LINES)

console.log(failures === 0 ? "\nall checks passed" : "\n" + failures + " check(s) failed")
process.exit(failures === 0 ? 0 : 1)
