import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // hyprmoncfg owns saved layouts and automatic switching. Keeping its small
  // service client here gives the bar one display entry without losing the
  // built-in panel's brightness, text-size, scale, or monitor controls.
  property bool hyprInstalled: false
  property bool hyprInstallKnown: false
  property bool hyprCompatible: false
  property bool hyprInstalling: false
  property string hyprInstalledVersion: ""
  property bool hyprServiceEnabled: false
  property bool hyprServiceActive: false
  property bool hyprServiceKnown: false
  property bool hyprActionPending: false
  property bool hyprTargetManaged: false
  property string hyprError: ""
  property int hyprRequestSequence: 0
  property var hyprDocument: ({ profiles: [], monitors: [], daemon: { running: false } })
  readonly property string hyprRuntimeDir: String(Quickshell.env("XDG_RUNTIME_DIR") || "")
  readonly property string hyprSocketPath: hyprRuntimeDir + "/hyprmoncfgd.sock"
  readonly property string hyprInstallFailurePath: hyprRuntimeDir + "/hyprmoncfg-display-install.failed"
  readonly property string hyprInstallCompletePath: hyprRuntimeDir + "/hyprmoncfg-display-install.complete"
  readonly property bool hyprConnected: hyprSocket.connected
  readonly property bool hyprManaged: hyprActionPending
    ? hyprTargetManaged
    : (hyprServiceEnabled || hyprServiceActive || hyprConnected)
  readonly property string hyprActiveProfile: hyprDocument && hyprDocument.active_profile
    ? String(hyprDocument.active_profile.name || "")
    : ""
  readonly property string hyprRecommendedProfile: hyprDocument && hyprDocument.recommended_profile
    ? String(hyprDocument.recommended_profile.name || "")
    : ""
  readonly property string hyprProfileName: hyprActiveProfile !== ""
    ? hyprActiveProfile
    : (hyprRecommendedProfile !== "" ? hyprRecommendedProfile : "Automatic switching")
  readonly property string hyprProfileDescription: {
    if (!hyprInstallKnown) return "Checking hyprmoncfg…"
    if (!hyprCompatible) return hyprInstalled ? "hyprmoncfg 1.12.0 or newer is required" : "hyprmoncfg is not installed"
    if (hyprActionPending) return hyprTargetManaged ? "Starting automatic switching…" : "Stopping automatic switching…"
    if (!hyprManaged) return "Off · current layout stays in place"
    if (!hyprConnected) return "Starting the background service…"
    var count = hyprDocument && hyprDocument.monitors instanceof Array
      ? hyprDocument.monitors.filter(function(monitor) { return monitor && monitor.enabled !== false }).length
      : enabledDisplayCount
    var displaysLabel = count === 1 ? "1 display" : count + " displays"
    if (hyprActiveProfile !== "") return displaysLabel + " · Active"
    if (hyprRecommendedProfile !== "") return displaysLabel + " · Best match available"
    return displaysLabel + " · Custom layout"
  }

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    list.push("layouts")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    if (section === "layouts") return hyprCompatible ? 2 : 1
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
      return
    }
    if (focusSection === "layouts") {
      if (!hyprCompatible) installHyprmoncfg()
      else if (selectedIndex === 0) setHyprManaged(!hyprManaged)
      else if (selectedIndex === 1) launchHyprEditor()
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function checkHyprmoncfg() {
    if (hyprVersionProc.running) return
    hyprVersionProc.command = [
      "sh",
      "-c",
      "if test \"$3\" = \"1\"; then if test -f \"$1\"; then cat \"$1\"; exit 2; elif ! test -f \"$2\"; then exit 3; fi; fi; if command -v hyprmoncfg >/dev/null 2>&1; then hyprmoncfg version; else exit 1; fi",
      "sh",
      root.hyprInstallFailurePath,
      root.hyprInstallCompletePath,
      root.hyprInstalling ? "1" : "0"
    ]
    hyprVersionProc.running = true
  }

  function checkHyprService() {
    if (!root.hyprCompatible || hyprEnabledProc.running || hyprActiveProc.running) return
    hyprEnabledProc.running = true
  }

  function connectHyprmoncfg() {
    if (!root.hyprCompatible || !root.hyprServiceActive || root.hyprSocketPath === "/hyprmoncfgd.sock") return
    if (!hyprSocket.connected) hyprSocket.connected = true
  }

  function sendHyprRequest(method, params) {
    if (!hyprSocket.connected) return
    root.hyprRequestSequence++
    var request = {
      type: "request",
      protocol_version: 1,
      id: String(root.hyprRequestSequence),
      method: method,
      params: params || {}
    }
    hyprSocket.write(JSON.stringify(request) + "\n")
    hyprSocket.flush()
  }

  function updateHyprDocument(value) {
    if (value && typeof value === "object") root.hyprDocument = value
  }

  function handleHyprMessage(line) {
    var envelope
    try { envelope = JSON.parse(String(line || "")) }
    catch (error) { root.hyprError = "Could not read hyprmoncfg status."; return }
    if (!envelope || typeof envelope !== "object") return
    if (envelope.error) {
      root.hyprError = String(envelope.error.message || "hyprmoncfg could not load the layout.")
      return
    }
    if (envelope.type === "event" && envelope.event === "status") root.updateHyprDocument(envelope.data)
    else if (envelope.result) root.updateHyprDocument(envelope.result)
  }

  function setHyprManaged(enabled) {
    if (!root.hyprCompatible || hyprServiceProc.running || root.hyprActionPending) return
    root.hyprError = ""
    root.hyprActionPending = true
    root.hyprTargetManaged = enabled === true
    hyprServiceProc.command = enabled === true
      ? ["systemctl", "--user", "enable", "--now", "hyprmoncfgd.service"]
      : ["systemctl", "--user", "disable", "--now", "hyprmoncfgd.service"]
    hyprServiceProc.running = true
  }

  function launchHyprEditor() {
    if (!root.hyprCompatible) {
      root.hyprError = "Install hyprmoncfg 1.12.0 or newer to create automatic display layouts."
      return
    }
    hyprEditorProc.command = ["gtk-launch", "hyprmoncfg-omarchy"]
    hyprEditorProc.startDetached()
    root.close()
  }

  function installHyprmoncfg() {
    if (root.hyprRuntimeDir === "" || root.hyprInstalling) {
      if (root.hyprRuntimeDir === "") root.hyprError = "Could not find the user runtime directory."
      return
    }
    root.hyprInstalling = true
    root.hyprError = ""
    hyprInstallPreparation.command = ["rm", "-f", root.hyprInstallFailurePath, root.hyprInstallCompletePath]
    hyprInstallPreparation.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
    checkHyprmoncfg()
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      checkHyprmoncfg()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onHyprCompatibleChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: {
      root.refresh()
      root.checkHyprService()
    }
  }

  Process {
    id: hyprVersionProc
    stdout: StdioCollector { id: hyprVersionOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 3 && root.hyprInstalling) return

      var installed = exitCode === 0
      var output = installed ? String(hyprVersionOutput.text || "") : ""
      var compatible = installed && Model.versionAtLeast(output, "1.12.0")
      root.hyprInstallKnown = true
      root.hyprInstalled = installed
      root.hyprInstalledVersion = output.trim()

      if (root.hyprInstalling && exitCode === 2) {
        root.hyprInstalling = false
        hyprInstallPoll.stop()
        hyprInstallTimeout.stop()
        root.hyprError = String(hyprVersionOutput.text || "").trim() === "130"
          ? "Installation was canceled."
          : "Installation did not finish. Check the Omarchy terminal and try again."
        return
      }

      if (root.hyprInstalling && !compatible) {
        root.hyprInstalling = false
        hyprInstallPoll.stop()
        hyprInstallTimeout.stop()
        root.hyprError = "The update finished, but hyprmoncfg 1.12.0 or newer is still required."
        return
      }

      root.hyprCompatible = compatible
      if (compatible) {
        root.hyprInstalling = false
        hyprInstallPoll.stop()
        hyprInstallTimeout.stop()
        root.checkHyprService()
      } else {
        hyprSocket.connected = false
        root.hyprServiceKnown = false
      }
    }
  }

  Process {
    id: hyprInstallPreparation
    onExited: function(exitCode) {
      if (!root.hyprInstalling) return
      if (exitCode !== 0) {
        root.hyprInstalling = false
        root.hyprError = "Could not prepare the hyprmoncfg installation."
        return
      }
      hyprInstaller.command = Model.installProcessArgs()
      hyprInstaller.startDetached()
      hyprInstallPoll.restart()
      hyprInstallTimeout.restart()
    }
  }

  Process { id: hyprInstaller }

  Timer {
    id: hyprInstallPoll
    interval: 1000
    repeat: true
    running: root.hyprInstalling && !root.hyprCompatible
    onTriggered: root.checkHyprmoncfg()
  }

  Timer {
    id: hyprInstallTimeout
    interval: 300000
    onTriggered: {
      if (!root.hyprInstalling) return
      root.hyprInstalling = false
      hyprInstallPoll.stop()
      root.hyprError = "Installation is still waiting. Check the Omarchy terminal and try again."
    }
  }

  Process {
    id: hyprEnabledProc
    command: ["systemctl", "--user", "is-enabled", "--quiet", "hyprmoncfgd.service"]
    onExited: function(exitCode) {
      root.hyprServiceEnabled = exitCode === 0
      hyprActiveProc.running = true
    }
  }

  Process {
    id: hyprActiveProc
    command: ["systemctl", "--user", "is-active", "--quiet", "hyprmoncfgd.service"]
    onExited: function(exitCode) {
      root.hyprServiceActive = exitCode === 0
      root.hyprServiceKnown = true
      if (root.hyprServiceActive) root.connectHyprmoncfg()
      else hyprSocket.connected = false
      if (root.hyprActionPending) {
        var reachedTarget = root.hyprTargetManaged
          ? (root.hyprServiceEnabled && root.hyprServiceActive)
          : (!root.hyprServiceEnabled && !root.hyprServiceActive)
        if (reachedTarget) root.hyprActionPending = false
      }
    }
  }

  Process {
    id: hyprServiceProc
    stderr: StdioCollector { id: hyprServiceError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.hyprActionPending = false
        root.hyprError = String(hyprServiceError.text || "Could not change automatic layout switching.").trim()
      }
      hyprServiceRefresh.restart()
    }
  }

  Process { id: hyprEditorProc }

  Timer {
    id: hyprServiceRefresh
    interval: 300
    onTriggered: root.checkHyprService()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.hyprCompatible && root.hyprServiceActive && !root.hyprConnected
    onTriggered: {
      root.checkHyprService()
      root.connectHyprmoncfg()
    }
  }

  Socket {
    id: hyprSocket
    path: root.hyprSocketPath
    connected: false
    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleHyprMessage(line) }
    }
    onConnectedChanged: {
      if (connected) {
        root.hyprError = ""
        root.sendHyprRequest("subscribe", {})
      }
    }
    onError: function(error) { connected = false }
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    tooltipText: root.hyprManaged && root.hyprProfileName !== ""
      ? "Display · " + root.hyprProfileName
      : "Display"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
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
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                text: {
                  if (root.hyprManaged && root.hyprActiveProfile !== "") return root.hyprActiveProfile.toUpperCase()
                  var count = root.enabledDisplayCount > 0 ? root.enabledDisplayCount : root.displays.length
                  return (count === 1 ? "1 DISPLAY" : count + " DISPLAYS")
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: "CONNECTED DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays

              MonitorRow {
                required property var modelData
                required property int index

                width: panelColumn.width
                display: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Automatic layouts ----------
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "AUTOMATIC LAYOUTS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Column {
              visible: !root.hyprCompatible
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: root.hyprInstalled
                  ? "Update hyprmoncfg to enable profiles and automatic switching."
                  : "Install hyprmoncfg to build visual layouts and switch them automatically."
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Button {
                id: hyprInstallButton
                width: parent.width
                text: root.hyprInstalling
                  ? (root.hyprInstalled ? "Updating hyprmoncfg…" : "Installing hyprmoncfg…")
                  : (root.hyprInstalled ? "Update hyprmoncfg" : "Install hyprmoncfg")
                iconText: root.hyprInstalling ? "󰦖" : (root.hyprInstalled ? "󰚰" : "󰏔")
                iconSpinning: root.hyprInstalling
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.body
                bordered: true
                selected: true
                enabled: root.hyprInstallKnown && !root.hyprInstalling
                hasCursor: root.cursorActive && root.focusSection === "layouts" && root.selectedIndex === 0
                onHovered: function(hovered) {
                  if (!hovered || root.reflowingText) return
                  root.cursorActive = true
                  root.focusSection = "layouts"
                  root.selectedIndex = 0
                }
                onClicked: root.installHyprmoncfg()
              }
            }

            Toggle {
              id: hyprManagedRow
              width: parent.width
              label: root.hyprProfileName
              description: root.hyprProfileDescription
              checked: root.hyprManaged
              visible: root.hyprCompatible
              enabled: !root.hyprActionPending
              hasCursor: root.cursorActive && root.focusSection === "layouts" && root.selectedIndex === 0
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(hyprManagedRow)
              onHovered: function(hovered) {
                if (!hovered || root.reflowingText) return
                root.cursorActive = true
                root.focusSection = "layouts"
                root.selectedIndex = 0
              }
              onClicked: root.setHyprManaged(!root.hyprManaged)
            }

            CursorSurface {
              id: hyprEditorRow
              width: parent.width
              implicitHeight: hyprEditorContent.implicitHeight + Style.spacing.xl
              hasCursor: root.cursorActive && root.focusSection === "layouts" && root.selectedIndex === 1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(hyprEditorRow)
              foreground: root.bar.foreground
              visible: root.hyprCompatible

              Row {
                id: hyprEditorContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(12)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰏘"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Column {
                  width: parent.width - parent.children[0].width - editorChevron.width - parent.spacing * 2
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: "Open layout editor"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: "Arrange displays and save profiles"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }

                Text {
                  id: editorChevron
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰅂"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "layouts"
                  root.selectedIndex = 1
                }
                onClicked: root.launchHyprEditor()
              }
            }

            Text {
              visible: root.hyprError !== ""
              width: parent.width
              text: root.hyprError
              color: root.bar.urgent
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: monitorRow.display.name + (monitorRow.display.focused ? " · focused" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
