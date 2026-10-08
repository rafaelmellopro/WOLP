// Tests for Pcs.js. Run with: node tests/pcs.test.js
// Pcs.js starts with QML's `.pragma library` line, which Node doesn't know,
// so the test strips that line and evaluates the rest.
const assert = require("assert")
const fs = require("fs")
const path = require("path")

const source = fs.readFileSync(path.join(__dirname, "..", "Pcs.js"), "utf8").replace(/^\.pragma library\s*/, "")
const Pcs = new Function(source + "\nreturn { fromSettings, toEntry, validate, withDefaults, normalizeMac, plainText }")()

const mine = {
  label: "TestPC", mac: "AA:BB:CC:DD:EE:01", broadcast: "192.168.1.255", host: "192.168.1.10",
  upsnapUrl: "http://upsnap.lan:8090", deviceId: "abc123", shutdownMethod: "upsnap", pollSec: 45
}

function test(name, fn) {
  fn()
  console.log("ok -", name)
}

test("one PC comes from the plain widget settings", () => {
  const list = Pcs.fromSettings(mine)
  assert.equal(list.length, 1)
  assert.equal(list[0].label, "TestPC")
  assert.equal(list[0].port, 9) // default filled in
})

test("saving an unchanged list gives back the same settings", () => {
  assert.deepEqual(Pcs.toEntry(mine, Pcs.fromSettings(mine)), mine)
})

test("extra PCs go into extraPcs, without default values", () => {
  const v = Pcs.validate({ label: "NAS", mac: "aa-bb-cc-dd-ee-ff", host: "10.0.0.5", shutdownMethod: "ssh" }, [])
  assert.equal(v.error, "")
  const entry = Pcs.toEntry(mine, Pcs.fromSettings(mine).concat([v.pc]))
  assert.deepEqual(entry.extraPcs, [{ label: "NAS", mac: "AA:BB:CC:DD:EE:FF", host: "10.0.0.5", shutdownMethod: "ssh" }])
  assert.equal(Pcs.fromSettings(entry).length, 2)
})

test("removing the first PC moves the next one into its place", () => {
  const two = Pcs.toEntry(mine, Pcs.fromSettings(mine).concat([Pcs.withDefaults({ label: "NAS", mac: "AA:BB:CC:DD:EE:FF", host: "10.0.0.5" })]))
  const entry = Pcs.toEntry(two, Pcs.fromSettings(two).slice(1))
  assert.equal(entry.label, "NAS")
  assert.equal(entry.extraPcs, undefined)
  assert.equal(entry.upsnapUrl, undefined)
  assert.equal(entry.pollSec, 45) // non-PC settings survive
})

test("extraPcs loaded through Qt (array-like, not a real array) still works", () => {
  const qtList = { 0: { label: "NAS", mac: "AA:BB:CC:DD:EE:FF", host: "10.0.0.5" }, length: 1 }
  assert.equal(Array.isArray(qtList), false)
  assert.equal(Pcs.fromSettings(Object.assign({}, mine, { extraPcs: qtList })).length, 2)
})

test("an empty widget has no PCs", () => {
  assert.equal(Pcs.fromSettings({}).length, 0)
})

test("validation explains what's missing", () => {
  const list = Pcs.fromSettings(mine)
  assert.match(Pcs.validate({ label: "" }, list).error, /name/)
  assert.match(Pcs.validate({ label: "NAS" }, list).error, /MAC/)
  assert.match(Pcs.validate({ label: "NAS", mac: "aabbccddeeff" }, list).error, /host/)
  assert.match(Pcs.validate({ label: "TestPC", mac: "aabbccddeeff", host: "x" }, list).error, /already/)
  assert.match(Pcs.validate({ label: "X", mode: "upsnap" }, list).error, /UpSnap/)
  assert.match(Pcs.validate({ label: "X", mac: "aabbccddeeff", host: "x", shutdownMethod: "windows" }, list).error, /username/)
  assert.match(Pcs.validate({ label: "X", mac: "aabbccddeeff", host: "x", shutdownMethod: "http", shutdownUrl: "nope" }, list).error, /http/)
})

test("plain-HTTP URLs that carry secrets are rejected; https and loopback pass", () => {
  const list = Pcs.fromSettings(mine)
  const upsnap = (url) => Pcs.validate(
    { label: "X", mode: "upsnap", upsnapUrl: url, deviceId: "abc" }, list).error
  assert.match(upsnap("http://upsnap.lan:8090"), /https/)
  assert.equal(upsnap("https://upsnap.lan:8090"), "")
  assert.equal(upsnap("http://localhost:8090"), "")
  assert.equal(upsnap("http://127.0.0.1:8090"), "")

  const webhook = (url) => Pcs.validate(
    { label: "X", mac: "aabbccddeeff", host: "x", shutdownMethod: "http", shutdownUrl: url }, list).error
  assert.match(webhook("http://home.lan:8123/api/webhook/x"), /https/)
  assert.equal(webhook("https://home.lan:8123/api/webhook/x"), "")
  assert.equal(webhook("http://localhost:8123/api/webhook/x"), "")

  // A shutdownMethod of upsnap checks the URL even in magic-packet mode.
  assert.match(Pcs.validate(
    { label: "X", mac: "aabbccddeeff", host: "x", shutdownMethod: "upsnap", upsnapUrl: "http://upsnap.lan:8090", deviceId: "abc" }, list).error, /https/)
})

test("outside text can't carry markup into the shell", () => {
  assert.equal(Pcs.plainText('Desk<img src="data:image/svg+xml;base64,AAAA">'), 'Deskimg src="data:image/svg+xml;base64,AAAA"')
  assert.equal(Pcs.plainText("Gaming PC"), "Gaming PC")
  assert.equal(Pcs.plainText("a\nb\u0000c"), "abc")
  assert.equal(Pcs.plainText(undefined), "")
  assert.equal(Pcs.plainText(42), "42")
  assert.equal(Pcs.plainText("x".repeat(500)).length, 200)
})
