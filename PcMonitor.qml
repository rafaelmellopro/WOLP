import QtQuick
import Quickshell
import Quickshell.Io
import "Pcs.js" as Pcs

// Watches one PC: polls its status and runs wake/shutdown through
// wake-pc.py. Has no visuals; Panel.qml creates one per PC and draws them.
Item {
  id: mon

  property var pc: ({})
  property int pollMs: 30000
  property bool panelOpen: false

  // unknown | online | offline | pending | waking | stopping | error
  property string pcState: "unknown"
  property string detail: ""
  property real latency: -1
  property real lastChecked: 0
  // While waking or shutting down, poll fast until the PC reaches targetState.
  property string targetState: ""
  property int attemptsLeft: 0
  property bool confirmingShutdown: false
  // Result of the last action. tone: ok | error | info
  property string messageText: ""
  property string messageTone: "info"

  readonly property string helper: String(Qt.resolvedUrl("wake-pc.py")).replace(/^file:\/\//, "")
  readonly property string label: String(pc.label || "PC")
  readonly property string shutdownMethod: String(pc.shutdownMethod || "none")
  readonly property bool canShutdown: shutdownMethod !== "none"
  readonly property bool transitioning: attemptsLeft > 0
  readonly property bool busy: transitioning || actionProc.running
  readonly property bool canWake: !busy && pcState !== "online"
  readonly property bool canShutdownNow: !busy && canShutdown && pcState === "online"
  readonly property bool refreshing: statusProc.running

  readonly property string statusText: {
    switch (pcState) {
      case "online": return latency >= 0 ? "Online · " + latency.toFixed(1) + " ms" : "Online"
      case "offline": return "Offline"
      case "waking": return "Waking up"
      case "stopping": return "Shutting down"
      case "pending": return "Pending in UpSnap"
      case "error": return "Error"
      default: return "Checking"
    }
  }

  // The message to show under this PC: the last action's result, or the
  // status error if there is no action message.
  readonly property string shownMessage: messageText !== "" ? messageText : (pcState === "error" ? detail : "")
  readonly property string shownTone: messageText !== "" ? messageTone : "error"

  // The settings go to wake-pc.py in an environment variable, not as
  // arguments: any local user can read a process's arguments with `ps`, but
  // only the same user can read its environment. Shutdown URLs and commands
  // can carry tokens.
  function helperConfig() {
    return JSON.stringify({
      "mode": String(pc.mode),
      "mac": String(pc.mac),
      "broadcast": String(pc.broadcast),
      "port": String(pc.port),
      "host": String(pc.host),
      "upsnap-url": String(pc.upsnapUrl),
      "device-id": String(pc.deviceId),
      "identity": String(pc.identity),
      "password-file": String(pc.passwordFile),
      "shutdown-method": shutdownMethod,
      "shutdown-host": String(pc.shutdownHost),
      "shutdown-user": String(pc.shutdownUser),
      "shutdown-password-file": String(pc.shutdownPasswordFile),
      "shutdown-command": String(pc.shutdownCommand),
      "ssh-port": String(pc.sshPort),
      "ssh-key": String(pc.sshKey),
      "shutdown-url": String(pc.shutdownUrl),
      "shutdown-http-method": String(pc.shutdownHttpMethod)
    })
  }

  function start(proc, action) {
    proc.command = ["python3", helper, action]
    proc.environment = { "WAKE_PC_CONFIG": helperConfig() }
    proc.running = true
  }

  function parse(text) {
    try {
      var result = JSON.parse(String(text).trim())
      result.detail = Pcs.plainText(result.detail)
      return result
    } catch (e) {
      return { state: "error", detail: "Bad helper output" }
    }
  }

  function notify(message) {
    Quickshell.execDetached(["notify-send", "-a", "WOLP", "-i", "computer", label, message])
  }

  function say(tone, text) {
    messageTone = tone
    messageText = text
  }

  function clearMessage() {
    if (!busy) messageText = ""
    confirmingShutdown = false
  }

  function refresh() {
    if (!statusProc.running) {
      start(statusProc, "status")
    }
  }

  function runAction(action) {
    if (actionProc.running) return
    actionProc.action = action
    start(actionProc, action)
    say("info", action === "wake" ? "Sending wake request…" : "Sending shutdown request…")
  }

  function wake() {
    if (canWake) runAction("wake")
  }

  function askShutdown() {
    if (canShutdownNow) confirmingShutdown = true
  }

  function confirmShutdown() {
    confirmingShutdown = false
    if (canShutdownNow) runAction("shutdown")
  }

  function handleStatus(result) {
    detail = result.detail || ""
    latency = typeof result.latency === "number" ? result.latency : -1
    lastChecked = Date.now()
    if (!transitioning || result.state === "error") {
      pcState = result.state
      return
    }

    if (result.state === targetState) {
      var done = label + (targetState === "online" ? " is online" : " is off")
      say("ok", done)
      notify(done)
      attemptsLeft = 0
      pcState = result.state
    } else if (--attemptsLeft === 0) {
      var failed = label + (targetState === "online" ? " did not come online" : " did not shut down")
      say("error", failed)
      notify(failed)
      pcState = result.state
    } else if (result.state === "pending") {
      pcState = "pending"
    }
  }

  onCanShutdownNowChanged: if (!canShutdownNow) confirmingShutdown = false

  Process {
    id: statusProc
    stdout: StdioCollector {
      onStreamFinished: mon.handleStatus(mon.parse(text))
    }
  }

  Process {
    id: actionProc
    property string action: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var result = mon.parse(text)
        var waking = actionProc.action === "wake"
        if (result.state === "sent") {
          // Poll every 3s for ~2 minutes while the machine boots / powers off.
          mon.targetState = waking ? "online" : "offline"
          mon.attemptsLeft = 40
          mon.pcState = waking ? "waking" : "stopping"
          mon.say("info", result.detail || (waking ? "Wake request sent" : "Shutdown request sent"))
        } else {
          mon.pcState = "error"
          mon.detail = result.detail || ""
          var failed = (waking ? "Wake" : "Shutdown") + " failed: " + mon.detail
          mon.say("error", failed)
          if (!mon.panelOpen) mon.notify(failed)
        }
      }
    }
  }

  Timer {
    interval: mon.transitioning ? 3000 : mon.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: mon.refresh()
  }
}
