.pragma library

// Helpers for the list of PCs.
//
// Storage: the first PC lives in the widget's normal settings (the same keys
// Omarchy's settings page edits), and every additional PC lives in the
// `extraPcs` array of that same widget entry. Callers only ever see a plain
// list of PC objects; fromSettings/toEntry translate to and from storage.

var KEYS = [
  "label", "mode", "mac", "broadcast", "port", "host",
  "upsnapUrl", "deviceId", "identity", "passwordFile",
  "shutdownMethod", "shutdownHost", "shutdownUser", "shutdownPasswordFile",
  "shutdownCommand", "sshPort", "sshKey", "shutdownUrl", "shutdownHttpMethod"
]

var DEFAULTS = {
  label: "PC", mode: "magic-packet", mac: "", broadcast: "255.255.255.255", port: 9, host: "",
  upsnapUrl: "", deviceId: "", identity: "", passwordFile: "",
  shutdownMethod: "none", shutdownHost: "", shutdownUser: "", shutdownPasswordFile: "",
  shutdownCommand: "", sshPort: 22, sshKey: "", shutdownUrl: "", shutdownHttpMethod: "POST"
}

// Settings loaded from shell.json at startup arrive through Qt, where lists
// are array-like objects rather than real JS arrays (Array.isArray is false).
// Accept anything with a length and copy it into a real array.
function toArray(value) {
  if (!value || typeof value !== "object" || typeof value.length !== "number") return []
  var out = []
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && typeof value.length !== "number"
}

function withDefaults(pc) {
  var out = {}
  for (var i = 0; i < KEYS.length; i++) {
    var key = KEYS[i]
    var value = pc ? pc[key] : undefined
    out[key] = value === undefined || value === null ? DEFAULTS[key] : value
  }
  return out
}

// Drop keys that still hold their default, so shell.json stays short.
function compact(pc) {
  var out = {}
  for (var i = 0; i < KEYS.length; i++) {
    var key = KEYS[i]
    if (pc[key] !== undefined && pc[key] !== DEFAULTS[key]) out[key] = pc[key]
  }
  return out
}

// A PC counts as set up once it has anything to wake or check.
function isConfigured(pc) {
  return !!(pc && (pc.mac || pc.host || pc.upsnapUrl || pc.deviceId))
}

function fromSettings(settings) {
  var list = []
  var first = {}
  for (var i = 0; i < KEYS.length; i++) {
    if (settings && settings[KEYS[i]] !== undefined) first[KEYS[i]] = settings[KEYS[i]]
  }
  if (isConfigured(first)) list.push(withDefaults(first))
  var extra = toArray(settings ? settings.extraPcs : null)
  for (var j = 0; j < extra.length; j++) {
    if (isPlainObject(extra[j])) list.push(withDefaults(extra[j]))
  }
  return list
}

// Build the full widget entry for a new list, keeping non-PC settings
// (like pollSec) untouched.
function toEntry(settings, list) {
  var entry = {}
  for (var key in settings) {
    if (key !== "id" && key !== "extraPcs" && KEYS.indexOf(key) === -1) entry[key] = settings[key]
  }
  if (list.length > 0) {
    var first = compact(list[0])
    for (var k in first) entry[k] = first[k]
  }
  if (list.length > 1) entry.extraPcs = list.slice(1).map(compact)
  return entry
}

function normalizeMac(value) {
  var digits = String(value || "").replace(/[^0-9a-fA-F]/g, "")
  if (digits.length !== 12) return null
  return digits.toUpperCase().match(/.{2}/g).join(":")
}

// Returns { pc, error }. pc is cleaned up (trimmed strings, numbers, MAC in
// AA:BB:.. form) when error is "".
function validate(draft, others) {
  var pc = withDefaults(draft)
  for (var i = 0; i < KEYS.length; i++) {
    if (typeof pc[KEYS[i]] === "string") pc[KEYS[i]] = pc[KEYS[i]].trim()
  }
  pc.port = Number(pc.port) || DEFAULTS.port
  pc.sshPort = Number(pc.sshPort) || DEFAULTS.sshPort

  function fail(message) { return { pc: pc, error: message } }

  if (pc.label === "") return fail("Give the PC a name.")
  for (var j = 0; j < others.length; j++) {
    if (others[j].label === pc.label) return fail("Another PC is already called " + pc.label + ".")
  }

  if (pc.mode === "magic-packet") {
    var mac = normalizeMac(pc.mac)
    if (!mac) return fail("MAC address must be 6 pairs of hex digits, like AA:BB:CC:DD:EE:FF.")
    pc.mac = mac
    if (pc.host === "") return fail("Enter the PC's host or IP so its status can be checked.")
  } else {
    if (pc.upsnapUrl === "" || pc.deviceId === "") return fail("UpSnap needs a URL and a device ID.")
    if (pc.mac !== "") pc.mac = normalizeMac(pc.mac) || pc.mac
  }

  var shutdownHost = pc.shutdownHost || pc.host
  switch (pc.shutdownMethod) {
    case "upsnap":
      if (pc.upsnapUrl === "" || pc.deviceId === "") return fail("UpSnap shutdown needs the UpSnap URL and device ID.")
      break
    case "ssh":
      if (shutdownHost === "") return fail("SSH shutdown needs a host.")
      break
    case "windows":
      if (shutdownHost === "") return fail("Windows shutdown needs a host.")
      if (pc.shutdownUser === "") return fail("Windows shutdown needs a username.")
      break
    case "http":
      if (!/^https?:\/\//.test(pc.shutdownUrl)) return fail("Shutdown URL must start with http:// or https://.")
      break
    case "command":
      if (pc.shutdownCommand === "") return fail("Enter the shutdown command.")
      break
  }
  return { pc: pc, error: "" }
}
