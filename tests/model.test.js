const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

const root = path.join(__dirname, "..")

test("display model preserves stock brightness and scaling behavior", () => {
  assert.equal(Model.clampBrightness(0), 1)
  assert.equal(Model.clampBrightness(101), 100)
  assert.equal(Model.normalizeScale("1.2500"), "1.25")
  assert.deepEqual(Model.parseDisplays('[{"enabled":true},{"enabled":false}]'), {
    displays: [{ enabled: true }, { enabled: false }],
    enabledDisplayCount: 1
  })
})

test("hyprmoncfg compatibility requires protocol-capable releases", () => {
  assert.equal(Model.versionAtLeast("hyprmoncfg 1.12.0", "1.12.0"), true)
  assert.equal(Model.versionAtLeast("hyprmoncfg v1.14.2", "1.12.0"), true)
  assert.equal(Model.versionAtLeast("hyprmoncfg dev", "1.12.0"), true)
  assert.equal(Model.versionAtLeast("hyprmoncfg 1.11.9", "1.12.0"), false)
})

test("installation stays visible and restarts the user daemon", () => {
  const args = Model.installProcessArgs()
  assert.deepEqual(args.slice(0, 6), ["omarchy", "launch", "floating", "terminal", "with", "presentation"])
  assert.match(args[6], /omarchy pkg aur add hyprmoncfg/)
  assert.match(args[6], /systemctl --user restart hyprmoncfgd\.service/)
  assert.match(args[6], /gtk-launch hyprmoncfg-omarchy/)
  assert.doesNotMatch(args[6], /&\s*$/)
})

test("manifest is a public 1.0 display clone with a right-side default", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))
  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.version, "1.0.0")
  assert.equal(manifest.omarchy.clonedFrom, "omarchy.monitor")
  assert.equal(manifest.barWidget.defaultSection, "right")
  assert.equal(manifest.hyprmoncfg.minimumVersion, "1.12.0")
})

test("panel exposes onboarding, management, and editor actions", () => {
  const qml = fs.readFileSync(path.join(root, "Panel.qml"), "utf8")
  assert.match(qml, /root\.hyprInstalled \? "Update hyprmoncfg" : "Install hyprmoncfg"/)
  assert.match(qml, /id: hyprInstallTimeout/)
  assert.match(qml, /interval: 300000/)
  assert.match(qml, /\["systemctl", "--user", "enable", "--now", "hyprmoncfgd\.service"\]/)
  assert.match(qml, /\["gtk-launch", "hyprmoncfg-omarchy"\]/)
  assert.match(qml, /text: "AUTOMATIC LAYOUTS"/)
})
