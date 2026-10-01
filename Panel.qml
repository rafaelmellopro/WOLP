import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Pcs.js" as Pcs

Panel {
  id: wakePanel
  moduleName: "wolp.pc"

  // ---- data ----------------------------------------------------------------

  readonly property var pcs: Pcs.fromSettings(settings)
  // One PcMonitor per PC, in the same order as pcs.
  property var monitors: []
  property real now: Date.now()
  readonly property int pollMs: Math.max(5, Number(setting("pollSec", 30))) * 1000

  // empty | single | list | form
  readonly property string view: formOpen ? "form"
    : (pcs.length === 0 ? "empty" : (pcs.length === 1 ? "single" : "list"))

  // The single-PC view always has something to bind to, even mid-reload.
  readonly property var sm: monitors.length > 0 ? monitors[0] : idleMonitor

  readonly property int onlineCount: monitors.filter(function(m) { return m.pcState === "online" }).length
  readonly property bool anyBusy: monitors.some(function(m) { return m.transitioning })
  readonly property bool anyError: monitors.some(function(m) { return m.pcState === "error" })

  // List view keyboard cursor.
  property int selectedIndex: 0
  property bool cursorActive: false

  // ---- add / edit form -----------------------------------------------------

  property bool formOpen: false
  property int editIndex: -1          // -1 while adding
  property var formSeed: ({})         // starting values for the text fields
  property var draft: ({})            // edited in place as you type
  property string draftMode: "magic-packet"
  property string draftShutdown: "none"
  property string draftHttpMethod: "POST"
  property string formError: ""
  property bool confirmingRemove: false

  // ---- look ----------------------------------------------------------------

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color good: "#8fd694"
  readonly property color warn: "#f0c674"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var shutdownOptions: [
    { value: "none", label: "None" },
    { value: "upsnap", label: "UpSnap" },
    { value: "ssh", label: "SSH" },
    { value: "windows", label: "Windows RPC" },
    { value: "http", label: "HTTP request" },
    { value: "command", label: "Custom command" }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function dotColor(m) {
    switch (m.pcState) {
      case "online": return good
      case "waking": case "stopping": case "pending": return warn
      case "error": return urgent
      default: return dim
    }
  }

  function toneColor(tone) {
    return tone === "ok" ? good : (tone === "error" ? urgent : dim)
  }

  function shutdownLabel(method) {
    for (var i = 0; i < shutdownOptions.length; i++) {
      if (shutdownOptions[i].value === method) return method === "none" ? "Not set up" : shutdownOptions[i].label
    }
    return method
  }

  function details(m) {
    var pc = m.pc || {}
    var upsnapHost = String(pc.upsnapUrl || "").replace(/^\w+:\/\//, "").replace(/\/.*$/, "")
    var rows = []
    rows.push({ name: "Address", value: pc.host || (pc.mode === "upsnap" ? (m.detail || "UpSnap device") : "Not set") })
    if (pc.mac) rows.push({ name: "MAC", value: pc.mac })
    rows.push({ name: "Wake via", value: pc.mode === "upsnap" ? "UpSnap · " + upsnapHost : "Magic packet" })
    rows.push({ name: "Shut down via", value: shutdownLabel(m.shutdownMethod) })
    return rows
  }

  function checkedText(m) {
    if (!m.lastChecked) return "Not checked yet"
    var seconds = Math.max(0, Math.round((now - m.lastChecked) / 1000))
    if (seconds < 5) return "Checked just now"
    if (seconds < 60) return "Checked " + seconds + "s ago"
    return "Checked " + Math.floor(seconds / 60) + "m ago"
  }

  function rebuildMonitors(removed) {
    var list = []
    for (var i = 0; i < monitorRepeater.count; i++) {
      var item = monitorRepeater.itemAt(i)
      if (item && item !== removed) list.push(item)
    }
    monitors = list
    selectedIndex = Math.min(selectedIndex, Math.max(0, list.length - 1))
  }

  function refreshAll() {
    for (var i = 0; i < monitors.length; i++) monitors[i].refresh()
  }

  function selected() {
    return monitors.length > 0 ? monitors[Math.min(selectedIndex, monitors.length - 1)] : null
  }

  // The PC that keyboard shortcuts act on.
  function target() {
    return view === "single" ? sm : (view === "list" ? selected() : null)
  }

  function moveCursor(dy) {
    if (view !== "list" || monitors.length === 0) return
    if (!cursorActive) { cursorActive = true; return }
    selectedIndex = Math.max(0, Math.min(monitors.length - 1, selectedIndex + dy))
  }

  // ---- saving --------------------------------------------------------------

  function savePcs(list) {
    var shell = bar ? bar.shell : null
    if (!shell || typeof shell.updateEntryInline !== "function") {
      formError = "This version of Omarchy doesn't let plugins save settings."
      return false
    }
    shell.updateEntryInline(moduleName, Pcs.toEntry(settings, list))
    return true
  }

  function openForm(index) {
    var seed = index >= 0 ? pcs[index] : Pcs.withDefaults({ label: pcs.length === 0 ? "PC" : "" })
    editIndex = index
    // A fresh copy, so the fields refill even when reopening the same PC.
    formSeed = JSON.parse(JSON.stringify(seed))
    draft = JSON.parse(JSON.stringify(seed))
    draftMode = seed.mode
    draftShutdown = seed.shutdownMethod
    draftHttpMethod = seed.shutdownHttpMethod
    formError = ""
    confirmingRemove = false
    formOpen = true
    if (!opened) open()
    flick.contentY = 0
    Qt.callLater(function() { if (wakePanel.formOpen) nameField.focusInput() })
  }

  function closeForm() {
    formOpen = false
    formError = ""
    confirmingRemove = false
    flick.contentY = 0
    keyCatcher.forceActiveFocus()
  }

  function saveForm() {
    draft.mode = draftMode
    draft.shutdownMethod = draftShutdown
    draft.shutdownHttpMethod = draftHttpMethod
    var others = pcs.filter(function(pc, i) { return i !== editIndex })
    var result = Pcs.validate(draft, others)
    if (result.error !== "") {
      formError = result.error
      return
    }
    var list = pcs.slice()
    if (editIndex >= 0) list[editIndex] = result.pc
    else list.push(result.pc)
    if (savePcs(list)) closeForm()
  }

  function removePc() {
    var list = pcs.filter(function(pc, i) { return i !== editIndex })
    if (savePcs(list)) closeForm()
  }

  onOpenedChanged: {
    if (opened) {
      now = Date.now()
      cursorActive = false
      refreshAll()
    } else {
      for (var i = 0; i < monitors.length; i++) monitors[i].clearMessage()
      // Start fresh next time; an open form could point at a PC removed meanwhile.
      if (formOpen) closeForm()
    }
  }

  // ---- PC monitors ---------------------------------------------------------

  Repeater {
    id: monitorRepeater
    model: wakePanel.pcs

    PcMonitor {
      required property var modelData
      pc: modelData
      pollMs: wakePanel.pollMs
      panelOpen: wakePanel.opened
    }

    onItemAdded: wakePanel.rebuildMonitors(null)
    onItemRemoved: function(index, item) { wakePanel.rebuildMonitors(item) }
  }

  // Stand-in with the same properties as a PcMonitor, used while there is none.
  QtObject {
    id: idleMonitor
    property var pc: ({})
    property string label: ""
    property string pcState: "unknown"
    property string statusText: ""
    property string detail: ""
    property string shutdownMethod: "none"
    property bool canShutdown: false
    property bool canWake: false
    property bool canShutdownNow: false
    property bool transitioning: false
    property bool refreshing: false
    property bool confirmingShutdown: false
    property string shownMessage: ""
    property string shownTone: "info"
    property real lastChecked: 0
  }

  // Keeps "Checked 12s ago" current while the panel is open.
  Timer {
    interval: 1000
    running: wakePanel.opened
    repeat: true
    onTriggered: wakePanel.now = Date.now()
  }

  // ---- bar icon ------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: wakePanel.bar
    text: wakePanel.onlineCount > 0 ? "󰍹" : "󰶐"
    dimmed: wakePanel.onlineCount === 0 && !wakePanel.anyBusy
    active: wakePanel.anyError
    tooltipText: {
      if (wakePanel.opened) return ""
      if (wakePanel.monitors.length === 0) return "Wake PC: no PC set up"
      return wakePanel.monitors.map(function(m) { return m.label + ": " + m.statusText.toLowerCase() }).join("\n")
    }
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) wakePanel.refreshAll()
      else wakePanel.toggle()
    }

    SequentialAnimation on opacity {
      running: wakePanel.anyBusy
      loops: Animation.Infinite
      onStopped: button.opacity = 1
      NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
    }
  }

  // ---- reusable pieces -----------------------------------------------------

  // Labelled text input for the form. Inline components can't see this
  // file's ids, so colors and the font come in as properties.
  component Field: Column {
    id: field
    property string name: ""
    property alias text: input.text
    property alias placeholder: input.placeholderText
    property alias password: input.password
    property color fg: Color.foreground
    property string fontFamily: Style.font.family
    signal edited(string value)
    signal submitted()
    function focusInput() { input.forceActiveFocus() }
    spacing: Style.spacing.labelGap

    Text {
      text: field.name
      color: Qt.darker(field.fg, 1.4)
      font.family: field.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    TextField {
      id: input
      width: field.width
      foreground: field.fg
      font.family: field.fontFamily
      onTextChanged: field.edited(text)
      onAccepted: field.submitted()
    }
  }

  // Coloured circle showing a PC's state; pulses while it boots or stops.
  component StatusDot: Rectangle {
    id: dot
    property bool pulsing: false
    width: Style.space(9)
    height: width
    radius: width / 2
    Behavior on color { ColorAnimation { duration: 160 } }

    SequentialAnimation on opacity {
      running: dot.pulsing
      loops: Animation.Infinite
      onStopped: dot.opacity = 1
      NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
    }
  }

  // ---- panel ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: wakePanel
    bar: wakePanel.bar
    open: wakePanel.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the form is open, keys go to the text fields.
      blocked: wakePanel.formOpen

      onCloseRequested: {
        var m = wakePanel.target()
        if (m && m.confirmingShutdown) m.confirmingShutdown = false
        else wakePanel.close()
      }
      onMoveRequested: function(dx, dy) { wakePanel.moveCursor(dy) }
      onActivateRequested: {
        var m = wakePanel.target()
        if (wakePanel.view === "empty") wakePanel.openForm(-1)
        else if (m && m.confirmingShutdown) m.confirmShutdown()
      }
      onTabRequested: function(direction) { wakePanel.switchPanel(direction) }
      onTextKey: function(t) {
        var key = t.toLowerCase()
        var m = wakePanel.target()
        if (key === "a" || key === "+") wakePanel.openForm(-1)
        else if (key === "r") wakePanel.refreshAll()
        else if (!m) return
        else if (key === "w") m.wake()
        else if (key === "s") m.askShutdown()
        else if (key === "e" && wakePanel.view === "list") wakePanel.openForm(wakePanel.selectedIndex)
        else if (key === "y" && m.confirmingShutdown) m.confirmShutdown()
        else if (key === "n") m.confirmingShutdown = false
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          // ================= empty: nothing set up yet =================

          Column {
            visible: wakePanel.view === "empty"
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              width: parent.width
              title: "Wake PC"
              meta: "No PC set up yet"
              foreground: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              iconOpacity: 0.5
              iconComponent: Component {
                Text {
                  text: "󰶐"
                  color: wakePanel.fg
                  font.family: wakePanel.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            Text {
              width: parent.width
              text: "Add a PC to wake it and shut it down from the bar."
              color: wakePanel.dim
              font.family: wakePanel.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              iconText: "󰐕"
              text: "Add a PC"
              foreground: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              bordered: true
              onClicked: wakePanel.openForm(-1)
            }
          }

          // ================= single: one PC, full detail =================

          Column {
            visible: wakePanel.view === "single"
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              width: parent.width
              title: wakePanel.sm.label
              meta: wakePanel.sm.statusText
              detail: wakePanel.sm.pc.mode === "upsnap" ? "UpSnap" : "WoL"
              foreground: wakePanel.fg
              fontFamily: wakePanel.fontFamily

              iconComponent: Component {
                Item {
                  implicitWidth: Style.font.display + Style.space(6)
                  implicitHeight: Style.font.display + Style.space(6)

                  Text {
                    anchors.centerIn: parent
                    text: wakePanel.sm.pcState === "online" || wakePanel.sm.pcState === "stopping" ? "󰍹" : "󰶐"
                    color: wakePanel.sm.pcState === "online" ? wakePanel.fg : wakePanel.dim
                    font.family: wakePanel.fontFamily
                    font.pixelSize: Style.font.display
                  }

                  // Cut out of the icon with a ring of panel background.
                  StatusDot {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    width: Style.space(11)
                    color: wakePanel.dotColor(wakePanel.sm)
                    pulsing: wakePanel.sm.transitioning
                    border.width: Style.space(2)
                    border.color: Color.popups.background
                  }
                }
              }

              trailingControl: Component {
                Row {
                  spacing: Style.space(2)

                  PanelActionButton {
                    iconText: "󰐕"
                    tooltipText: "Add another PC (A)"
                    foreground: wakePanel.fg
                    fontFamily: wakePanel.fontFamily
                    onClicked: wakePanel.openForm(-1)
                  }

                  PanelActionButton {
                    iconText: "󰑐"
                    tooltipText: "Refresh (R)"
                    foreground: wakePanel.fg
                    fontFamily: wakePanel.fontFamily
                    enabled: !wakePanel.sm.refreshing
                    onClicked: wakePanel.refreshAll()
                  }
                }
              }
            }

            PanelSeparator { foreground: wakePanel.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: wakePanel.details(wakePanel.sm)

                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    id: rowName
                    width: Style.space(92)
                    text: modelData.name
                    color: wakePanel.dim
                    font.family: wakePanel.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    width: parent.width - rowName.width - parent.spacing
                    text: modelData.value
                    color: wakePanel.fg
                    font.family: wakePanel.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
              }
            }

            PanelSeparator { foreground: wakePanel.fg }

            // Wake + Shut down side by side.
            Row {
              id: actions
              visible: !wakePanel.sm.confirmingShutdown
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (actions.width - actions.spacing) / 2
                iconText: "󱐋"
                text: wakePanel.sm.pcState === "waking" ? "Waking…" : "Wake"
                tooltipText: "Wake (W)"
                foreground: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                bordered: true
                active: wakePanel.sm.pcState === "waking"
                enabled: wakePanel.sm.canWake
                opacity: enabled || active ? 1 : 0.4
                onClicked: wakePanel.sm.wake()
              }

              Button {
                width: (actions.width - actions.spacing) / 2
                iconText: "󰐥"
                text: wakePanel.sm.pcState === "stopping" ? "Stopping…" : "Shut down"
                tooltipText: "Shut down (S)"
                foreground: wakePanel.sm.canShutdownNow ? wakePanel.urgent : wakePanel.fg
                accent: wakePanel.urgent
                fontFamily: wakePanel.fontFamily
                bordered: true
                active: wakePanel.sm.pcState === "stopping"
                enabled: wakePanel.sm.canShutdownNow
                opacity: enabled || active ? 1 : 0.4
                onClicked: wakePanel.sm.askShutdown()
              }
            }

            // Confirmation replaces the buttons in place.
            Column {
              visible: wakePanel.sm.confirmingShutdown
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "Shut down " + wakePanel.sm.label + "?"
                color: wakePanel.urgent
                font.family: wakePanel.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: "Via " + wakePanel.shutdownLabel(wakePanel.sm.shutdownMethod) + ". Unsaved work on that PC will be lost."
                color: wakePanel.dim
                font.family: wakePanel.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Row {
                id: confirmButtons
                width: parent.width
                spacing: Style.space(8)

                Button {
                  width: (confirmButtons.width - confirmButtons.spacing) / 2
                  iconText: "󰐥"
                  text: "Shut down"
                  tooltipText: "Enter or Y"
                  foreground: wakePanel.urgent
                  accent: wakePanel.urgent
                  fontFamily: wakePanel.fontFamily
                  bordered: true
                  selected: true
                  onClicked: wakePanel.sm.confirmShutdown()
                }

                Button {
                  width: (confirmButtons.width - confirmButtons.spacing) / 2
                  text: "Cancel"
                  tooltipText: "Esc or N"
                  foreground: wakePanel.fg
                  fontFamily: wakePanel.fontFamily
                  bordered: true
                  onClicked: wakePanel.sm.confirmingShutdown = false
                }
              }
            }

            Text {
              visible: wakePanel.sm.shownMessage !== ""
              width: parent.width
              text: wakePanel.sm.shownMessage
              color: wakePanel.toneColor(wakePanel.sm.shownTone)
              font.family: wakePanel.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !wakePanel.sm.canShutdown
              width: parent.width
              text: "Shutdown isn't set up. Pick a shutdown method in this widget's settings."
              color: wakePanel.dim
              font.family: wakePanel.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Item {
              width: parent.width
              implicitHeight: singleChecked.implicitHeight

              Text {
                id: singleChecked
                anchors.left: parent.left
                text: wakePanel.checkedText(wakePanel.sm)
                color: wakePanel.dim
                font.family: wakePanel.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.right: parent.right
                visible: singleChecked.implicitWidth + implicitWidth + Style.space(12) <= parent.width
                text: "W wake · S off · R refresh"
                color: wakePanel.dim
                font.family: wakePanel.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ================= list: several PCs =================

          Column {
            visible: wakePanel.view === "list"
            width: parent.width
            spacing: Style.space(12)

            PanelHero {
              width: parent.width
              title: "Wake PC"
              meta: wakePanel.monitors.length + " PCs · " + wakePanel.onlineCount + " online"
              foreground: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              iconComponent: Component {
                Text {
                  text: wakePanel.onlineCount > 0 ? "󰍹" : "󰶐"
                  color: wakePanel.onlineCount > 0 ? wakePanel.fg : wakePanel.dim
                  font.family: wakePanel.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                Row {
                  spacing: Style.space(2)

                  PanelActionButton {
                    iconText: "󰐕"
                    tooltipText: "Add a PC (A)"
                    foreground: wakePanel.fg
                    fontFamily: wakePanel.fontFamily
                    onClicked: wakePanel.openForm(-1)
                  }

                  PanelActionButton {
                    iconText: "󰑐"
                    tooltipText: "Refresh all (R)"
                    foreground: wakePanel.fg
                    fontFamily: wakePanel.fontFamily
                    onClicked: wakePanel.refreshAll()
                  }
                }
              }
            }

            PanelSeparator { foreground: wakePanel.fg }

            Column {
              width: parent.width
              spacing: Style.space(10)

              Repeater {
                model: wakePanel.view === "list" ? wakePanel.monitors : []

                Column {
                  id: pcRow
                  required property var modelData
                  required property int index
                  readonly property var m: modelData
                  readonly property bool hasCursor: wakePanel.cursorActive && wakePanel.selectedIndex === index
                  width: parent.width
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(nameCol.implicitHeight, rowButtons.implicitHeight)

                    // Keyboard cursor highlight.
                    Rectangle {
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      radius: Style.cornerRadius
                      color: pcRow.hasCursor ? Style.selectedFillFor(wakePanel.fg, Color.accent) : "transparent"
                    }

                    StatusDot {
                      id: rowDot
                      anchors.left: parent.left
                      anchors.top: nameCol.top
                      anchors.topMargin: (rowName.height - height) / 2
                      color: wakePanel.dotColor(pcRow.m)
                      pulsing: pcRow.m.transitioning
                    }

                    Column {
                      id: nameCol
                      anchors.left: rowDot.right
                      anchors.leftMargin: Style.space(8)
                      anchors.right: rowButtons.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)

                      Text {
                        id: rowName
                        width: parent.width
                        text: pcRow.m.label
                        color: wakePanel.fg
                        font.family: wakePanel.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: pcRow.m.statusText + (pcRow.m.pc.host ? " · " + pcRow.m.pc.host : "")
                        color: wakePanel.dim
                        font.family: wakePanel.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Row {
                      id: rowButtons
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      PanelActionButton {
                        iconText: "󱐋"
                        tooltipText: "Wake"
                        foreground: wakePanel.fg
                        fontFamily: wakePanel.fontFamily
                        enabled: pcRow.m.canWake
                        onClicked: pcRow.m.wake()
                      }

                      PanelActionButton {
                        iconText: "󰐥"
                        tooltipText: pcRow.m.canShutdown ? "Shut down" : "Shutdown isn't set up"
                        foreground: wakePanel.fg
                        hoverColor: wakePanel.urgent
                        fontFamily: wakePanel.fontFamily
                        enabled: pcRow.m.canShutdownNow
                        onClicked: pcRow.m.askShutdown()
                      }

                      PanelActionButton {
                        iconText: "󰏫"
                        tooltipText: "Edit or remove"
                        foreground: wakePanel.fg
                        fontFamily: wakePanel.fontFamily
                        onClicked: wakePanel.openForm(pcRow.index)
                      }
                    }
                  }

                  // In-row shutdown confirmation.
                  Item {
                    visible: pcRow.m.confirmingShutdown
                    width: parent.width
                    implicitHeight: rowConfirmButtons.implicitHeight

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(17)
                      anchors.right: rowConfirmButtons.left
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Shut down " + pcRow.m.label + "?"
                      color: wakePanel.urgent
                      font.family: wakePanel.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Row {
                      id: rowConfirmButtons
                      anchors.right: parent.right
                      spacing: Style.space(6)

                      Button {
                        text: "Shut down"
                        foreground: wakePanel.urgent
                        accent: wakePanel.urgent
                        fontFamily: wakePanel.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        selected: true
                        onClicked: pcRow.m.confirmShutdown()
                      }

                      Button {
                        text: "Cancel"
                        foreground: wakePanel.fg
                        fontFamily: wakePanel.fontFamily
                        fontSize: Style.font.caption
                        bordered: true
                        onClicked: pcRow.m.confirmingShutdown = false
                      }
                    }
                  }

                  Text {
                    visible: pcRow.m.shownMessage !== ""
                    x: Style.space(17)
                    width: parent.width - x
                    text: pcRow.m.shownMessage
                    color: wakePanel.toneColor(pcRow.m.shownTone)
                    font.family: wakePanel.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            PanelSeparator { foreground: wakePanel.fg }

            Text {
              width: parent.width
              text: "↑↓ select · W wake · S off · E edit · A add"
              color: wakePanel.dim
              font.family: wakePanel.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }
          }

          // ================= form: add or edit a PC =================

          Column {
            visible: wakePanel.view === "form"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: wakePanel.editIndex >= 0 ? "Edit " + wakePanel.formSeed.label : (wakePanel.pcs.length === 0 ? "Add a PC" : "Add another PC")
              color: wakePanel.fg
              font.family: wakePanel.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Field {
              id: nameField
              width: parent.width
              name: "Name"
              placeholder: "e.g. Gaming PC"
              text: wakePanel.formSeed.label || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.label = value }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.labelGap

              Text {
                text: "Wake method"
                color: Qt.darker(wakePanel.fg, 1.4)
                font.family: wakePanel.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              ButtonGroup {
                options: [{ value: "magic-packet", label: "Magic packet" }, { value: "upsnap", label: "UpSnap" }]
                value: wakePanel.draftMode
                foreground: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onChanged: function(value) { wakePanel.draftMode = value }
              }
            }

            Field {
              width: parent.width
              visible: wakePanel.draftMode === "magic-packet"
              name: "MAC address"
              placeholder: "AA:BB:CC:DD:EE:FF"
              text: wakePanel.formSeed.mac || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.mac = value }
            }

            Row {
              id: broadcastRow
              visible: wakePanel.draftMode === "magic-packet"
              width: parent.width
              spacing: Style.space(8)

              Field {
                width: broadcastRow.width - portField.width - broadcastRow.spacing
                name: "Broadcast address"
                placeholder: "255.255.255.255"
                text: wakePanel.formSeed.broadcast || ""
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.broadcast = value }
              }

              Field {
                id: portField
                width: Style.space(70)
                name: "UDP port"
                placeholder: "9"
                text: String(wakePanel.formSeed.port || "")
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.port = value }
              }
            }

            Field {
              width: parent.width
              name: wakePanel.draftMode === "magic-packet" ? "Host / IP (checked with ping)" : "Host / IP (optional)"
              placeholder: "192.168.1.50"
              text: wakePanel.formSeed.host || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.host = value }
            }

            Column {
              visible: wakePanel.draftMode === "upsnap" || wakePanel.draftShutdown === "upsnap"
              width: parent.width
              spacing: Style.space(10)

              Field {
                width: parent.width
                name: "UpSnap URL"
                placeholder: "http://upsnap.lan:8090"
                text: wakePanel.formSeed.upsnapUrl || ""
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.upsnapUrl = value }
              }

              Field {
                width: parent.width
                name: "UpSnap device ID"
                placeholder: "Record ID from UpSnap"
                text: wakePanel.formSeed.deviceId || ""
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.deviceId = value }
              }

              Field {
                width: parent.width
                name: "UpSnap username / email"
                placeholder: "Leave empty if the device is public"
                text: wakePanel.formSeed.identity || ""
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.identity = value }
              }

              Field {
                width: parent.width
                name: "UpSnap password file"
                placeholder: "~/.config/upsnap-password"
                text: wakePanel.formSeed.passwordFile || ""
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.passwordFile = value }
              }
            }

            Dropdown {
              width: parent.width
              label: "Shutdown method"
              options: wakePanel.shutdownOptions
              value: wakePanel.draftShutdown
              fontFamily: wakePanel.fontFamily
              onChanged: function(value) { wakePanel.draftShutdown = value }
            }

            Field {
              width: parent.width
              visible: wakePanel.draftShutdown === "ssh" || wakePanel.draftShutdown === "windows"
              name: "Shutdown host"
              placeholder: "Same as Host / IP"
              text: wakePanel.formSeed.shutdownHost || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.shutdownHost = value }
            }

            Row {
              id: userRow
              visible: wakePanel.draftShutdown === "ssh" || wakePanel.draftShutdown === "windows"
              width: parent.width
              spacing: Style.space(8)

              Field {
                width: userRow.width - (sshPortField.visible ? sshPortField.width + userRow.spacing : 0)
                name: wakePanel.draftShutdown === "windows" ? "Windows user" : "SSH user"
                placeholder: wakePanel.draftShutdown === "windows" ? "user or DOMAIN\\user" : "Your login on that PC"
                text: wakePanel.formSeed.shutdownUser || ""
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.shutdownUser = value }
              }

              Field {
                id: sshPortField
                visible: wakePanel.draftShutdown === "ssh"
                width: Style.space(70)
                name: "SSH port"
                placeholder: "22"
                text: String(wakePanel.formSeed.sshPort || "")
                fg: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                onSubmitted: wakePanel.saveForm()
                onEdited: function(value) { wakePanel.draft.sshPort = value }
              }
            }

            Field {
              width: parent.width
              visible: wakePanel.draftShutdown === "ssh"
              name: "SSH key (optional)"
              placeholder: "Default keys / agent"
              text: wakePanel.formSeed.sshKey || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.sshKey = value }
            }

            Field {
              width: parent.width
              visible: wakePanel.draftShutdown === "windows"
              name: "Windows password file"
              placeholder: "File containing only the password"
              text: wakePanel.formSeed.shutdownPasswordFile || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.shutdownPasswordFile = value }
            }

            Field {
              width: parent.width
              visible: wakePanel.draftShutdown === "ssh" || wakePanel.draftShutdown === "command"
              name: wakePanel.draftShutdown === "ssh" ? "Command to run on the PC" : "Command to run here"
              placeholder: wakePanel.draftShutdown === "ssh" ? "sudo systemctl poweroff" : "e.g. curl -fsS https://…"
              text: wakePanel.formSeed.shutdownCommand || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.shutdownCommand = value }
            }

            Field {
              width: parent.width
              visible: wakePanel.draftShutdown === "http"
              name: "Shutdown URL"
              placeholder: "http://homeassistant.lan:8123/api/webhook/…"
              text: wakePanel.formSeed.shutdownUrl || ""
              fg: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onSubmitted: wakePanel.saveForm()
              onEdited: function(value) { wakePanel.draft.shutdownUrl = value }
            }

            ButtonGroup {
              visible: wakePanel.draftShutdown === "http"
              options: ["POST", "GET"]
              value: wakePanel.draftHttpMethod
              foreground: wakePanel.fg
              fontFamily: wakePanel.fontFamily
              onChanged: function(value) { wakePanel.draftHttpMethod = value }
            }

            Text {
              visible: wakePanel.formError !== ""
              width: parent.width
              text: wakePanel.formError
              color: wakePanel.urgent
              font.family: wakePanel.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: wakePanel.fg }

            Row {
              id: formButtons
              visible: !wakePanel.confirmingRemove
              width: parent.width
              spacing: Style.space(8)

              Button {
                width: (formButtons.width - formButtons.spacing) / 2
                text: wakePanel.editIndex >= 0 ? "Save" : "Add PC"
                foreground: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                bordered: true
                selected: true
                onClicked: wakePanel.saveForm()
              }

              Button {
                width: (formButtons.width - formButtons.spacing) / 2
                text: "Cancel"
                foreground: wakePanel.fg
                fontFamily: wakePanel.fontFamily
                bordered: true
                onClicked: wakePanel.closeForm()
              }
            }

            Button {
              visible: wakePanel.editIndex >= 0 && !wakePanel.confirmingRemove
              width: parent.width
              iconText: "󰩹"
              text: "Remove this PC"
              foreground: wakePanel.urgent
              accent: wakePanel.urgent
              fontFamily: wakePanel.fontFamily
              onClicked: wakePanel.confirmingRemove = true
            }

            Column {
              visible: wakePanel.confirmingRemove
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "Remove " + wakePanel.formSeed.label + " from the list?"
                color: wakePanel.urgent
                font.family: wakePanel.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                wrapMode: Text.WordWrap
              }

              Row {
                id: removeButtons
                width: parent.width
                spacing: Style.space(8)

                Button {
                  width: (removeButtons.width - removeButtons.spacing) / 2
                  text: "Remove"
                  foreground: wakePanel.urgent
                  accent: wakePanel.urgent
                  fontFamily: wakePanel.fontFamily
                  bordered: true
                  selected: true
                  onClicked: wakePanel.removePc()
                }

                Button {
                  width: (removeButtons.width - removeButtons.spacing) / 2
                  text: "Keep"
                  foreground: wakePanel.fg
                  fontFamily: wakePanel.fontFamily
                  bordered: true
                  onClicked: wakePanel.confirmingRemove = false
                }
              }
            }
          }
        }
      }
    }
  }
}
