import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Zen Wallpaper: the bar chip and its popup.
//
//   left click    open the popup (mode, sound, stills, theme, stream URL)
//   middle click  animated <-> still
//   scroll        volume
//
// Everything shown comes from `omarchy-zen status --json`; every action
// is a fixed argv through Util.execArgv, so nothing typed here reaches a shell
// as code. The engine itself is Service.qml; the two talk through the config
// file and the "zen" IPC target, never directly.
Panel {
  id: root
  moduleName: "fans.omarchy.zen-wallpaper"
  ipcTarget: "fans.omarchy.zen-wallpaper"
  manageIpc: false

  readonly property string cli: Qt.resolvedUrl("bin/omarchy-zen").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var status: null
  property var lib: null
  property string browse: "cat:zen"        // bookmarks | cat:<id> | ch:<id>
  property string followDraft: ""
  // creator view: which videos, in what order, how many rows
  property string chKind: "all"          // all | live | stream | upload
  property string chSort: "newest"       // newest | popular | longest
  property string chFilter: ""
  property int chLimit: 30
  property string channelNote: ""
  onBrowseChanged: { chKind = "all"; chSort = "newest"; chFilter = ""; chLimit = 30; channelNote = "" }
  property bool loading: false
  property string error: ""
  property string urlDraft: ""
  property bool urlEdited: false

  readonly property var cfg: status && status.config ? status.config : ({})
  readonly property var engine: status && status.engine ? status.engine : null
  readonly property var stream: status && status.stream ? status.stream : null
  readonly property string mode: cfg.mode || "animated"
  readonly property bool sound: cfg.sound !== false
  readonly property real volume: typeof cfg.volume === "number" ? cfg.volume : 0.35
  readonly property bool engineUp: engine !== null
  readonly property var browseOptions: {
    var nStreams = lib && lib.bookmarks ? lib.bookmarks.length : 0
    var nCreators = lib && lib.saved_creators ? lib.saved_creators.length : 0
    var opts = [{ value: "bookmarks", label: "Bookmarks" + (lib ? " (" + nStreams + " stream" + (nStreams === 1 ? "" : "s")
                  + (nCreators ? " · " + nCreators + " creator" + (nCreators === 1 ? "" : "s") : "") + ")" : "") }]
    var cats = lib && lib.categories ? lib.categories : [{ id: "zen", name: "Zen" }]
    for (var i = 0; i < cats.length; i++)
      opts.push({ value: "cat:" + cats[i].id, label: cats[i].name + (cats[i].bookmarked ? "  ·  " + cats[i].bookmarked + " bookmarked" : "") })
    var chans = lib && lib.channels ? lib.channels : [{ id: "AetherJourneyMusic", name: "Aether Journey" }]
    var seen = false
    for (var k = 0; k < chans.length; k++) {
      if ("ch:" + chans[k].id === browse) seen = true
      opts.push({ value: "ch:" + chans[k].id, label: (chans[k].bookmarked ? "★ " : "") + "Creator: " + chans[k].name
                  + (chans[k].bookmarked_streams ? "  ·  " + chans[k].bookmarked_streams + " bookmarked" : "") })
    }
    // A creator you are looking at without having bookmarked it.
    if (!seen && browse.indexOf("ch:") === 0)
      opts.push({ value: browse, label: "Creator: " + (creator ? creator.name : browse.substring(3)) + " (not bookmarked)" })
    return opts
  }
  readonly property var creator: lib && lib.kind === "channel" && lib.creator ? lib.creator : null
  readonly property bool libLoading: libProc.running
  readonly property var libRows: {
    if (!lib) return []
    var rows = lib.entries || []
    if (lib.kind !== "channel" && lib.now && lib.now.id && !rows.some(function(e) { return e.id === lib.now.id }))
      rows = [Object.assign({}, lib.now, { isNow: true })].concat(rows)
    return rows
  }
  readonly property string engineState: engine ? String(engine.state || "") : ""

  // updates: what `update-check` reported for this widget's version (docs/update-alerts.md)
  property string version: ""
  property var updateInfo: null
  readonly property bool updateAvailable: !!updateInfo && updateInfo.update_available === true
                                          && updateInfo.dismissed !== updateInfo.latest
  readonly property bool updateMismatch: !!updateInfo && updateInfo.mismatch === true
  readonly property string updateKey: updateAvailable ? String(updateInfo.latest) : (updateMismatch ? "mismatch" : "")
  property string updateHiddenKey: ""
  readonly property bool updatePending: updateKey !== "" && updateKey !== updateHiddenKey

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) { load(); loadLibrary(false); checkUpdates() }
  Component.onCompleted: load()

  // ---- updates ----------------------------------------------------------------
  FileView {
    path: Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, "")
    printErrors: false
    onLoaded: {
      try { root.version = String(JSON.parse(text()).version || "") } catch (e) { root.version = "" }
      root.checkUpdates()
    }
  }
  function checkUpdates() {
    if (root.setting("update_check", true) === false || updateProc.running) return
    updateProc.command = [root.cli, "update-check", root.version]
    updateProc.running = true
  }
  Process {
    id: updateProc
    stdout: StdioCollector { id: updateOut; waitForEnd: true }
    stderr: StdioCollector { id: updateErr; waitForEnd: true }
    onExited: function(code) {
      var d = null
      try { d = JSON.parse(updateOut.text) } catch (e) { d = null }
      if (d) { root.updateInfo = d; return }
      if (code !== 0 && String(updateErr.text || "").indexOf("unknown command") >= 0)
        root.updateInfo = { mismatch: true, update_available: false, latest: null, notes: [], dismissed: "", cli: "older" }
    }
  }
  Timer { interval: 6 * 3600 * 1000; running: true; repeat: true; onTriggered: root.checkUpdates() }
  function runUpdate() {
    root.updateHiddenKey = root.updateKey
    Util.execArgv([root.cli, "update-run", root.updateAvailable ? "all" : "install"])
  }
  function dismissUpdate() {
    root.updateHiddenKey = root.updateKey
    if (root.updateAvailable && root.updateInfo.latest) Util.execArgv([root.cli, "update-dismiss", String(root.updateInfo.latest)])
  }

  // ---- data -------------------------------------------------------------------
  function load() {
    if (statusProc.running) return
    loading = true
    statusProc.running = true
  }
  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(code) {
      root.loading = false
      if (code !== 0) { root.error = String(statusErr.text || "").trim() || ("status exited " + code); return }
      try {
        root.status = JSON.parse(statusOut.text); root.error = ""
        if (!root.urlEdited) root.urlDraft = String(root.cfg.url || "")
      } catch (e) { root.error = "bad JSON from status" }
    }
  }
  Timer { interval: 3000; running: root.opened; repeat: true; onTriggered: root.load() }
  Timer { interval: 10000; running: !root.opened; repeat: true; onTriggered: root.load() }
  // A new stream (from the popup, the command line or the daily refresh):
  // reload the library so the playing row moves.
  property string lastStreamId: ""
  onStatusChanged: {
    var id = root.stream && root.stream.video_id ? String(root.stream.video_id) : ""
    if (id !== root.lastStreamId) { root.lastStreamId = id; if (root.opened) root.loadLibrary(false) }
  }
  // After Play the resolve takes a few seconds: look again three times.
  Timer { id: playReload; interval: 2500; repeat: true; property int left: 0
    onTriggered: { root.load(); root.loadLibrary(false); if (--left <= 0) stop() } }
  Timer { id: reloadSoon; interval: 900; onTriggered: { root.load(); root.loadLibrary(false) } }

  // ---- library (catalog, creators, bookmarks, ratings) ----
  function loadLibrary(refresh) {
    if (libProc.running) { libAgain.restart(); return }
    var argv = [root.cli, "library", "--json"]
    if (root.browse === "bookmarks") argv.push("--bookmarks")
    else if (root.browse.indexOf("ch:") === 0)
      argv.push("--channel", root.browse.substring(3), "--kind", root.chKind, "--sort", root.chSort,
                "--filter", root.chFilter, "--limit", String(root.chLimit))
    else argv.push("--category", root.browse.substring(4))
    if (refresh) argv.push("--refresh")
    libProc.command = argv
    libProc.running = true
  }
  Timer { id: libAgain; interval: 400; onTriggered: root.loadLibrary(false) }
  Process {
    id: libProc
    stdout: StdioCollector { id: libOut; waitForEnd: true }
    stderr: StdioCollector { id: libErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) { root.error = String(libErr.text || "").trim() || ("library exited " + code); return }
      try { root.lib = JSON.parse(libOut.text) } catch (e) { root.error = "bad JSON from library" }
    }
  }
  // Bookmark (save) a creator, or remove the bookmark. With browseAfter the
  // popup switches to that creator's catalog once the helper answers.
  Process {
    id: chanProc
    property bool browseAfter: false
    stdout: StdioCollector { id: chanOut; waitForEnd: true }
    stderr: StdioCollector { id: chanErr; waitForEnd: true }
    onExited: function(code) {
      root.channelNote = ""
      if (code !== 0) { root.channelNote = (String(chanErr.text || "").trim().replace(/^omarchy-zen: /, "") || ("channel exited " + code)); return }
      var rec = null
      try { rec = JSON.parse(chanOut.text) } catch (e) { rec = null }
      if (rec && chanProc.browseAfter) { root.browse = "ch:" + rec.id }
      root.error = ""
      root.loadLibrary(false)
    }
  }
  function channelCmd(argv, browseAfter, note) {
    if (chanProc.running) return
    chanProc.browseAfter = browseAfter
    root.channelNote = note || "Saving…"
    chanProc.command = [root.cli, "channel"].concat(argv).concat(["--json"])
    chanProc.running = true
  }
  function follow() {
    var u = String(followDraft || "").trim()
    if (!u) return
    root.followDraft = ""
    channelCmd(["add", u], true, "Looking the creator up on YouTube…")
  }
  // A row's creator: open their catalog (bookmarked or not).
  function browseCreator(row) {
    var ref = row.creator ? row.creator.id : String(row.creator_ref || "")
    if (!ref) return
    root.browse = "ch:" + ref
    root.loadLibrary(false)
  }
  function reloadCreator() { root.chLimit = 30; root.loadLibrary(false) }
  Timer { id: filterTimer; interval: 400; onTriggered: root.reloadCreator() }
  function fmtDuration(sec) {
    sec = Number(sec || 0)
    if (sec <= 0) return ""
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60)
    return h > 0 ? h + " h" + (m ? " " + m + " min" : "") : m + " min"
  }

  function act(argv) {
    Util.execArgv([root.cli].concat(argv))
    reloadSoon.restart()
    if (argv[0] === "play" || argv[0] === "set-url" || argv[0] === "daily") { playReload.left = 3; playReload.restart() }
  }
  function fmtCount(n) {
    n = Number(n || 0)
    if (n >= 1000000) return (n / 1000000).toFixed(n >= 10000000 ? 0 : 1) + "M"
    if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k"
    return String(n)
  }
  function setMode(m) { act(["mode", m]) }
  function useUrl() {
    var u = String(urlDraft || "").trim()
    if (!u) return
    root.urlEdited = false
    act(["set-url", u])
  }

  // Media convention: pause while playing, play while paused or stopped; a
  // picture for still, a dimmed picture for off.
  function modeIcon() {
    if (!root.engineUp || root.mode === "off" || root.mode === "still") return "󰋩"
    if (root.engineState === "playing") return "󰏤"
    return "󰐊"
  }
  function stateText() {
    if (!root.status) return root.error ? root.error : "Loading…"
    if (!root.engineUp) return "Engine not running. Enable the plugin (omarchy plugin enable fans.omarchy.zen-wallpaper) or restart the shell."
    var s = root.engineState
    var head = s === "playing" ? (root.mode === "animated" ? "Playing" : (root.sound ? "Playing sound, still wallpaper" : "Still wallpaper"))
      : s === "paused" ? "Paused"
      : s === "paused-fullscreen" ? "Video paused behind a fullscreen window" + (root.sound ? ", sound on" : "")
      : s === "resolving" ? "Finding the stream…"
      : s === "error" ? "Problem: " + (root.engine.error || "unknown") + (root.engine.retries ? " (retrying)" : "")
      : s === "off" ? "Off" : "Idle"
    var q = root.stream && root.stream.video_height ? " · " + root.stream.video_height + "p" : ""
    var live = root.stream && root.stream.is_live ? " · live" : ""
    return head + (root.mode === "animated" ? q : "") + live
  }
  function ago(sec) {
    if (!sec) return ""
    var s = Math.max(0, Math.floor(root.status.now - sec))
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    if (s < 86400) return Math.floor(s / 3600) + "h ago"
    return Math.floor(s / 86400) + "d ago"
  }

  // ---- chip -------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.modeIcon()
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "Zen Wallpaper"
      + (root.stream && root.stream.title ? " · " + root.stream.title : "")
      + " — " + root.stateText() + " · middle-click: animated / still, scroll: volume"
      + (root.updateAvailable ? " · " + root.updateInfo.latest + " is available" : (root.updateMismatch ? " · finish updating" : ""))
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.setMode(root.mode === "animated" ? "still" : "animated")
      else root.toggle()
    }
  }
  WheelHandler {
    target: button
    onWheel: function(event) {
      var v = Math.max(0, Math.min(1, root.volume + (event.angleDelta.y > 0 ? 0.05 : -0.05)))
      root.act(["volume", v.toFixed(2)])
    }
  }
  Rectangle {
    visible: root.updatePending || (root.engineUp && root.engineState === "error")
    width: Style.space(6); height: width; radius: width / 2
    color: root.engineUp && root.engineState === "error" ? Color.urgent : Color.accent
    anchors { right: parent.right; top: parent.top; margins: Style.space(3) }
  }

  // ---- popup ------------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Flickable {
        id: flick
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
          width: flick.width
          spacing: Style.space(8)

          // The author's Suno invite: make your own music (opens the browser).
          Button {
            text: "Make your own music with Suno"; iconText: "󰝚"; foreground: Color.accent; fontFamily: root.fontFamily
            fontSize: Style.font.caption; iconSize: Style.font.caption
            tooltipText: "suno.com/invite/@markusix — the author's invite link"
            onClicked: { root.close(); Util.execArgv([root.cli, "suno"]) }
          }

          PanelHero {
            width: parent.width
            title: "Zen Wallpaper"
            meta: (root.stream && root.stream.title ? root.stream.title + (root.stream.channel ? " — " + root.stream.channel : "") + "\n" : "") + root.stateText()
          }

          // ---- update banner (docs/update-alerts.md) ----
          Rectangle {
            id: updateBanner
            width: parent.width
            visible: root.updatePending
            height: visible ? updateRow.implicitHeight + Style.space(14) : 0
            radius: Style.space(6)
            color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.08)
            border.width: 1
            border.color: Color.accent
            Row {
              id: updateRow
              width: parent.width - Style.space(14)
              anchors.centerIn: parent
              spacing: Style.space(8)
              Column {
                id: updateCol
                width: parent.width - updateButtons.width - parent.spacing
                spacing: Style.space(2)
                Text {
                  width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                  text: root.updateAvailable
                        ? "Zen Wallpaper " + root.updateInfo.latest + " is available (you have " + root.version + ")"
                        : "Finish updating Zen Wallpaper: the chip is " + root.version + ", its helper is " + (root.updateInfo ? root.updateInfo.cli : "")
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
                }
                Repeater {
                  model: root.updateAvailable ? root.updateInfo.notes.slice(0, 4) : []
                  delegate: Text {
                    required property var modelData
                    width: updateCol.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: "•  " + modelData
                    color: root.foreground; opacity: 0.8; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  width: parent.width; wrapMode: Text.Wrap; textFormat: Text.PlainText
                  text: root.updateAvailable
                        ? "Update opens a terminal: omarchy plugin update shows the changes and asks, install.sh asks, then a shell restart loads the new engine."
                        : "Run install.sh once so the helper matches. It asks before changing anything."
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                }
              }
              Column {
                id: updateButtons
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                Button {
                  text: root.updateAvailable ? "Update…" : "Finish update…"; foreground: Color.accent; fontFamily: root.fontFamily
                  onClicked: root.runUpdate()
                }
                Button { text: "Later"; foreground: root.dim; fontFamily: root.fontFamily; onClicked: root.dismissUpdate() }
              }
            }
          }

          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            visible: root.error !== ""
            color: Color.urgent; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: root.error
          }

          // ---- mode ----
          PanelSectionHeader { width: parent.width; text: "Wallpaper" }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Button {
              text: "Animated"; iconText: "󰕧"; fontFamily: root.fontFamily; selected: root.mode === "animated"
              foreground: root.mode === "animated" ? Color.accent : root.foreground
              tooltipText: "The stream plays under your windows"
              onClicked: root.setMode("animated")
            }
            Button {
              text: "Still"; iconText: "󰋩"; fontFamily: root.fontFamily; selected: root.mode === "still"
              foreground: root.mode === "still" ? Color.accent : root.foreground
              tooltipText: "A frame from the stream is your Omarchy background (a new one every day)"
              onClicked: root.setMode("still")
            }
            Button {
              text: "Off"; iconText: "󰛊"; fontFamily: root.fontFamily; selected: root.mode === "off"
              foreground: root.mode === "off" ? Color.accent : root.foreground
              tooltipText: "Nothing plays; your Omarchy background shows"
              onClicked: root.setMode("off")
            }
            Button {
              visible: root.engineUp && root.mode !== "off"
              text: root.engine && root.engine.paused ? "Resume" : "Pause"
              iconText: root.engine && root.engine.paused ? "󰐊" : "󰏤"
              foreground: root.dim; fontFamily: root.fontFamily
              onClicked: root.act([root.engine && root.engine.paused ? "resume" : "pause"])
            }
          }

          // ---- sound ----
          Toggle {
            width: parent.width
            label: "Sound"
            description: root.mode === "still" ? "The stream's music keeps playing under the still" : "Play the stream's audio"
            checked: root.sound
            fontFamily: root.fontFamily
            onClicked: root.act(["sound", root.sound ? "off" : "on"])
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.sound
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Volume"; textFormat: Text.PlainText
              color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
            PanelSlider {
              id: volumeSlider
              width: parent.width - x - volumeText.width - Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              bar: root.bar
              minimum: 0; maximum: 1; step: 0.05
              value: root.volume
              onReleased: function(v) { root.act(["volume", Number(v).toFixed(2)]) }
            }
            Text {
              id: volumeText
              anchors.verticalCenter: parent.verticalCenter
              text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue : root.volume) * 100) + "%"; textFormat: Text.PlainText
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            }
          }

          // ---- scene actions ----
          PanelSeparator { width: parent.width }
          PanelSectionHeader { width: parent.width; text: "This scene" }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Button {
              text: "Grab a still"; iconText: "󰄀"; foreground: Color.accent; fontFamily: root.fontFamily
              tooltipText: "One frame from the stream becomes your Omarchy background now"
              onClicked: root.act(["still"])
            }
            Button {
              text: "Make a theme with Aether"; iconText: "󰏘"; foreground: Color.accent; fontFamily: root.fontFamily
              tooltipText: "Aether extracts a palette from the last still and applies it as the Omarchy theme \"" + (root.cfg.theme_name || "zen") + "\" (terminals restart)"
              onClicked: root.act(["theme"])
            }
            Button {
              text: "Refresh today"; iconText: "󰑐"; foreground: root.foreground; fontFamily: root.fontFamily
              tooltipText: "Run the daily refresh now: newest video of a channel, a new still" + (root.cfg.daily_theme ? ", a new theme" : "")
              onClicked: root.act(["daily", "--force"])
            }
            Button {
              text: "Open on YouTube"; iconText: "󰗃"; foreground: root.dim; fontFamily: root.fontFamily
              onClicked: { root.close(); Util.execArgv([root.cli, "open"]) }
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: (root.status && root.status.frame ? "Last still " + root.ago(root.status.frame.taken) : "No still yet")
              + (root.status && root.status.daily ? " · daily refresh " + root.ago(root.status.daily.last) : "")
          }

          // ---- library ----
          PanelSeparator { width: parent.width }
          Row {
            width: parent.width
            spacing: Style.space(8)
            PanelSectionHeader { anchors.verticalCenter: parent.verticalCenter; text: "Library" }
            Dropdown {
              id: browseDropdown
              width: Style.space(230)
              anchors.verticalCenter: parent.verticalCenter
              showLabel: false
              options: root.browseOptions
              fontFamily: root.fontFamily
              Connections {
                target: root
                function onBrowseOptionsChanged() { if (browseDropdown.value !== root.browse) browseDropdown.value = root.browse }
              }
              Component.onCompleted: value = root.browse
              onChanged: function(v) { if (v !== root.browse) { root.browse = v; root.loadLibrary(false) } }
            }
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: ""; iconText: "󰑐"; foreground: root.dim; fontFamily: root.fontFamily
              tooltipText: "Fetch the newest catalog, creator lists and community ratings"
              onClicked: root.loadLibrary(true)
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: !root.lib ? "Loading the library…"
              : (root.browse === "bookmarks" ? "Your bookmarked creators and streams. Bookmark a stream with the flag on its row, a creator with the flag in their catalog."
                : (root.browse.indexOf("ch:") === 0 ? (root.libLoading && !root.creator ? "Fetching the catalog from YouTube…" : "Everything this creator has on YouTube: live now, past streams and uploads.")
                  : "The ten most popular long streams in this category, from YouTube searches (catalog " + (root.lib.generated || "") + ")."))
              + (root.lib && root.lib.ratings_api_available ? " Stars and plays are shared with every install." : " Community stars and play counts are not available yet; your stars stay on this machine until then.")
          }
          // ---- a creator's catalog ----
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.creator !== null
            Text {
              width: parent.width; elide: Text.ElideRight; textFormat: Text.PlainText
              color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true
              text: root.creator ? root.creator.name + (root.creator.followers > 0 ? "  ·  " + root.fmtCount(root.creator.followers) + " subscribers" : "") : ""
            }
            Text {
              width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
              text: root.creator && root.creator.counts
                ? root.creator.counts.all + " on YouTube: " + root.creator.counts.live + " live now, " + root.creator.counts.stream + " past streams, "
                  + root.creator.counts.upload + " uploads" + (root.chFilter ? " matching \u201c" + root.chFilter + "\u201d" : "")
                : ""
            }
            Text {
              width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
              visible: root.channelNote !== ""
              color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
              text: root.channelNote
            }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Button {
                text: root.creator && root.creator.bookmarked ? "Bookmarked" : "Bookmark this creator"
                iconText: root.creator && root.creator.bookmarked ? "󰃀" : "󰃃"
                foreground: root.creator && root.creator.bookmarked ? Color.accent : root.foreground; fontFamily: root.fontFamily
                tooltipText: root.creator && root.creator.bookmarked ? "Remove the bookmark" + (root.creator.builtin ? " (a built-in creator stays in the selector)" : "")
                  : "Keep this creator in the Library selector and under Bookmarks"
                onClicked: if (root.creator) root.channelCmd(["toggle", root.creator.channel_id || root.creator.id], true)
              }
              Button {
                text: "Play newest"; iconText: "󰐊"; foreground: Color.accent; fontFamily: root.fontFamily
                tooltipText: "Their newest stream or upload becomes the wallpaper, rechecked every day"
                onClicked: if (root.creator) root.act(["play", root.creator.url])
              }
              Button {
                text: "Open on YouTube"; iconText: "󰗃"; foreground: root.dim; fontFamily: root.fontFamily
                onClicked: if (root.creator) { root.close(); Util.execArgv([root.cli, "channel", "open", root.creator.url]) }
              }
            }
            Flow {
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                model: [{ k: "all", n: "All" }, { k: "live", n: "Live now" }, { k: "stream", n: "Past streams" }, { k: "upload", n: "Uploads" }]
                delegate: Button {
                  required property var modelData
                  visible: !root.creator || !root.creator.counts || modelData.k === "all" || root.creator.counts[modelData.k] > 0
                  text: modelData.n + (root.creator && root.creator.counts ? " (" + root.creator.counts[modelData.k] + ")" : "")
                  selected: root.chKind === modelData.k
                  foreground: root.chKind === modelData.k ? Color.accent : root.foreground; fontFamily: root.fontFamily
                  onClicked: if (root.chKind !== modelData.k) { root.chKind = modelData.k; root.reloadCreator() }
                }
              }
            }
            Row {
              width: parent.width
              spacing: Style.space(8)
              Dropdown {
                id: sortDropdown
                width: Style.space(150)
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                options: [{ value: "newest", label: "Newest first" }, { value: "popular", label: "Most viewed" }, { value: "longest", label: "Longest" }]
                fontFamily: root.fontFamily
                Connections {
                  target: root
                  function onChSortChanged() { if (sortDropdown.value !== root.chSort) sortDropdown.value = root.chSort }
                }
                Component.onCompleted: value = root.chSort
                onChanged: function(v) { if (v !== root.chSort) { root.chSort = v; root.reloadCreator() } }
              }
              TextField {
                id: filterField
                width: parent.width - sortDropdown.width - parent.spacing
                foreground: root.foreground
                placeholderText: "Filter this catalog by title"
                font.family: root.fontFamily
                Connections {
                  target: root
                  function onChFilterChanged() { if (filterField.text !== root.chFilter) filterField.text = root.chFilter }
                }
                onTextEdited: { root.chFilter = text; filterTimer.restart() }
                onAccepted: { filterTimer.stop(); root.reloadCreator() }
              }
            }
          }

          // ---- bookmarked creators (Bookmarks view) ----
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.browse === "bookmarks" && !!root.lib && (root.lib.saved_creators || []).length > 0
            PanelSectionHeader { width: parent.width; text: "Bookmarked creators" }
            Repeater {
              model: root.browse === "bookmarks" && root.lib ? (root.lib.saved_creators || []) : []
              delegate: Row {
                id: crow
                required property var modelData
                width: column.width
                spacing: Style.space(6)
                Text {
                  width: parent.width - browseBtn.width - unbmBtn.width - parent.spacing * 2
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight; textFormat: Text.PlainText
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                  text: crow.modelData.name + (crow.modelData.followers > 0 ? "  ·  " + root.fmtCount(crow.modelData.followers) + " subscribers" : "")
                }
                Button {
                  id: browseBtn
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Browse"; iconText: "󰀄"; foreground: Color.accent; fontFamily: root.fontFamily
                  tooltipText: "Everything " + crow.modelData.name + " has on YouTube"
                  onClicked: { root.browse = "ch:" + crow.modelData.id; root.loadLibrary(false) }
                }
                Button {
                  id: unbmBtn
                  anchors.verticalCenter: parent.verticalCenter
                  text: ""; iconText: "󰃀"; foreground: Color.accent; fontFamily: root.fontFamily
                  tooltipText: "Remove the bookmark"
                  onClicked: root.channelCmd(["remove", crow.modelData.channel_id || crow.modelData.id], false)
                }
              }
            }
            PanelSectionHeader { width: parent.width; text: "Bookmarked streams" }
          }
          Repeater {
            model: root.libRows
            delegate: Column {
              id: erow
              required property var modelData
              width: column.width
              spacing: Style.space(2)
              Row {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  width: parent.width - playBtn.width - parent.spacing
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight; textFormat: Text.PlainText
                  color: erow.modelData.playing ? Color.accent : root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                  text: (erow.modelData.isNow ? "Now playing: " : "") + (erow.modelData.title || erow.modelData.id)
                }
                Button {
                  id: playBtn
                  text: erow.modelData.playing ? "Playing" : "Play"; iconText: "󰐊"; fontFamily: root.fontFamily
                  foreground: erow.modelData.playing ? root.dim : Color.accent
                  onClicked: if (!erow.modelData.playing) root.act(["play", String(erow.modelData.id)])
                }
              }
              Row {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  width: parent.width - starRow.width - bmBtn.width - (creatorBtn.visible ? creatorBtn.width + parent.spacing : 0) - parent.spacing * 2
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight; textFormat: Text.PlainText
                  color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                  text: (root.lib && root.lib.kind === "channel" ? "" : (erow.modelData.channel || "")) + (erow.modelData.live ? " · live" : "")
                    + (!erow.modelData.live && erow.modelData.duration > 0 && root.lib && root.lib.kind === "channel" ? " · " + root.fmtDuration(erow.modelData.duration) : "")
                    + (erow.modelData.live && erow.modelData.viewers > 0 ? " · ~" + root.fmtCount(erow.modelData.viewers) + " watching" : "")
                    + (!erow.modelData.live && erow.modelData.views > 0 ? " · " + root.fmtCount(erow.modelData.views) + " YouTube views" : "")
                    + (root.lib && root.lib.ratings_api_available ? " · " + root.fmtCount(erow.modelData.plays || 0) + " Zen play" + (erow.modelData.plays === 1 ? "" : "s") : "")
                    + (erow.modelData.count > 0 ? " · " + Number(erow.modelData.avg).toFixed(1) + " ★ (" + erow.modelData.count + ")" : "")
                }
                Row {
                  id: starRow
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)
                  Repeater {
                    model: 5
                    delegate: Text {
                      required property int index
                      textFormat: Text.PlainText
                      text: index < (erow.modelData.my_stars || 0) ? "★" : "☆"
                      color: index < (erow.modelData.my_stars || 0) ? Color.accent : root.dim
                      font.family: root.fontFamily; font.pixelSize: Style.font.body
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.act(["rate", String(erow.modelData.id), String((erow.modelData.my_stars || 0) === index + 1 ? 0 : index + 1)])
                      }
                    }
                  }
                }
                Button {
                  id: creatorBtn
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !!root.lib && root.lib.kind !== "channel" && !!(erow.modelData.creator || erow.modelData.creator_ref)
                  text: ""; iconText: "󰀄"; fontFamily: root.fontFamily
                  foreground: erow.modelData.creator && erow.modelData.creator.bookmarked ? Color.accent : root.dim
                  tooltipText: "Browse everything " + (erow.modelData.channel || "this creator") + " has on YouTube"
                    + (erow.modelData.creator && erow.modelData.creator.bookmarked ? " (bookmarked creator)" : "")
                  onClicked: root.browseCreator(erow.modelData)
                }
                Button {
                  id: bmBtn
                  anchors.verticalCenter: parent.verticalCenter
                  text: ""; iconText: erow.modelData.bookmarked ? "󰃀" : "󰃃"; fontFamily: root.fontFamily
                  foreground: erow.modelData.bookmarked ? Color.accent : root.dim
                  tooltipText: erow.modelData.bookmarked ? "Remove the bookmark" : "Bookmark"
                  onClicked: root.act(["bookmark", "toggle", String(erow.modelData.id)])
                }
              }
              PanelSeparator { width: parent.width; strength: 0.06 }
            }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            visible: root.lib !== null && root.libRows.length === 0
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: root.browse === "bookmarks" ? "No bookmarked streams yet."
              : (root.creator ? (root.chFilter ? "Nothing in this catalog matches." : "Nothing here yet.") : "Nothing here yet.")
          }
          Button {
            visible: root.creator !== null && root.libRows.length < (root.creator ? root.creator.total : 0)
            text: root.libLoading ? "Loading…" : "Show 30 more  (" + root.libRows.length + " of " + (root.creator ? root.creator.total : 0) + ")"
            foreground: Color.accent; fontFamily: root.fontFamily
            onClicked: if (!root.libLoading) { root.chLimit += 30; root.loadLibrary(false) }
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            visible: root.channelNote !== ""
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: root.channelNote
          }
          Row {
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: followField
              width: parent.width - followButton.width - parent.spacing
              foreground: root.foreground
              placeholderText: "Bookmark a creator: channel link, @handle, or any of their videos"
              font.family: root.fontFamily
              text: root.followDraft
              onTextEdited: root.followDraft = text
              onAccepted: root.follow()
            }
            Button {
              id: followButton
              anchors.verticalCenter: parent.verticalCenter
              text: "Save"; foreground: Color.accent; fontFamily: root.fontFamily
              tooltipText: "Bookmark this creator and browse their catalog"
              onClicked: root.follow()
            }
          }

          // ---- stream ----
          PanelSeparator { width: parent.width }
          PanelSectionHeader { width: parent.width; text: "Stream" }
          Row {
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: urlField
              width: parent.width - useButton.width - parent.spacing
              foreground: root.foreground
              placeholderText: "https://www.youtube.com/watch?v=…  (video, live, playlist or channel)"
              font.family: root.fontFamily
              text: root.urlDraft
              onTextEdited: { root.urlDraft = text; root.urlEdited = true }
              onAccepted: root.useUrl()
            }
            Button {
              id: useButton
              anchors.verticalCenter: parent.verticalCenter
              text: "Use"; foreground: Color.accent; fontFamily: root.fontFamily
              tooltipText: "Play this YouTube video, live stream, playlist or channel (newest upload)"
              onClicked: root.useUrl()
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            Dropdown {
              id: qualityDropdown
              width: Style.space(140)
              label: "Video quality"
              options: [{ value: "480", label: "480p" }, { value: "720", label: "720p" }, { value: "1080", label: "1080p" }]
              fontFamily: root.fontFamily
              // The dropdown assigns its own value on selection, which would
              // break a binding; follow the config by hand instead.
              Connections {
                target: root
                function onStatusChanged() { var v = String(root.cfg.quality || 720); if (qualityDropdown.value !== v) qualityDropdown.value = v }
              }
              Component.onCompleted: value = String(root.cfg.quality || 720)
              onChanged: function(v) { if (v !== String(root.cfg.quality || 720)) root.act(["quality", v]) }
            }
          }

          // ---- daily ----
          PanelSeparator { width: parent.width }
          PanelSectionHeader { width: parent.width; text: "Every day" }
          Toggle {
            width: parent.width
            label: "Daily refresh"
            description: "A new still each day; for a channel or playlist, its newest video"
            checked: root.cfg.daily_refresh !== false
            fontFamily: root.fontFamily
            onClicked: root.act(["daily-refresh", root.cfg.daily_refresh !== false ? "off" : "on"])
          }
          Toggle {
            width: parent.width
            label: "Daily theme"
            description: "Also rebuild the Aether theme from the new still (terminals restart once a day)"
            checked: root.cfg.daily_theme === true
            fontFamily: root.fontFamily
            onClicked: root.act(["daily-theme", root.cfg.daily_theme === true ? "off" : "on"])
          }
          Toggle {
            width: parent.width
            label: "Pause video behind fullscreen windows"
            description: "Stop decoding the picture while a fullscreen window covers it; the sound keeps playing"
            checked: root.cfg.pause_when_fullscreen !== false
            fontFamily: root.fontFamily
            onClicked: root.act(["fullscreen-pause", root.cfg.pause_when_fullscreen !== false ? "off" : "on"])
          }
          Text {
            width: parent.width; wrapMode: Text.WordWrap; textFormat: Text.PlainText
            color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
            text: "The stream plays live from YouTube through yt-dlp; only still frames are saved (~/.local/share/omarchy-zen/frames). Command line: omarchy-zen.\nZen Wallpaper " + root.version + " · an Omarchy.Fans product by ModPunk · MIT"
          }
        }
      }
    }
  }
}
