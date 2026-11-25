import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // ---- config ----
    // Helper ships inside the package; resolve its path relative to this file
    // so the widget works on any machine (no hardcoded home path).
    readonly property string scriptPath: Qt.resolvedUrl("../code/mem-usage.py").toString().replace(/^file:\/\//, "")
    readonly property string cmd: "python3 '" + scriptPath + "'"
    readonly property int pollMs: 3000       // summary only — cheap
    readonly property int procPollMs: 5000   // full scan — only while open

    // ---- state ----
    property var mem: null          // summary from /proc/meminfo
    property var groups: []         // per-name process groups (popup only)
    property int rssFallback: 0     // processes we couldn't read PSS for
    property int procCount: 0
    property string errorMsg: ""
    property double lastFetchMs: 0
    property bool busy: false
    property int fetchSeq: 0
    property string openGroup: ""   // table row expanded to show individual PIDs
    property bool cleanArmed: false // "Clear" clicked once — next click deletes
    property bool cleaning: false
    property string cleanMsg: ""    // "Freed …" shown briefly on the tmp row

    Plasmoid.icon: "memory"
    toolTipMainText: mem ? (Math.round(mem.pct) + "% memory in use") : "Memory"
    toolTipSubText: {
        if (!mem) return errorMsg !== "" ? "Couldn't read /proc/meminfo" : "Loading…"
        var s = fmtKb(mem.used_kb) + " of " + fmtKb(mem.total_kb) + " · " + fmtKb(mem.available_kb) + " available"
        if (mem.swap_used_kb > 0) s += "\nSwap " + fmtKb(mem.swap_used_kb) + " (" + Math.round(mem.swap_pct) + "%)"
        return s + "\nClick for the breakdown"
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Refresh now"
            icon.name: "view-refresh"
            onTriggered: { root.refresh(); root.refreshProcs() }
        },
        PlasmaCore.Action {
            text: "Open System Monitor"
            icon.name: "utilities-system-monitor"
            onTriggered: root.openSystemMonitor()
        }
    ]

    // ---------- data ----------
    // Two sources: the panel percentage comes from /proc/meminfo alone (~20 ms),
    // while the process breakdown walks every /proc/<pid>/smaps_rollup and costs
    // ~400 ms, so it only runs while the popup is actually open.
    P5Support.DataSource {
        id: execSummary
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.busy = false
            if (data["exit code"] !== 0) { root.errorMsg = "exec"; return }
            try {
                var p = JSON.parse(data["stdout"])
                if (p.error) { root.errorMsg = p.error; return }
                root.mem = p
                root.lastFetchMs = p.fetched_ms
                root.errorMsg = ""
            } catch (e) {
                root.errorMsg = "parse"
            }
        }
    }

    P5Support.DataSource {
        id: execProcs
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            if (data["exit code"] !== 0) return
            try {
                var p = JSON.parse(data["stdout"])
                if (p.error) return
                root.mem = p                       // fresher summary rides along
                root.lastFetchMs = p.fetched_ms
                root.groups = p.groups ? p.groups : []
                root.rssFallback = p.rss_fallback ? p.rss_fallback : 0
                root.procCount = p.proc_count ? p.proc_count : 0
                root.errorMsg = ""
                if (p.cleaned) {
                    root.cleaning = false
                    root.cleanMsg = p.cleaned.error ? "Couldn't delete: " + p.cleaned.error
                                  : "Freed " + root.fmtKb(p.cleaned.freed_kb) + " from "
                                    + p.cleaned.count + " session" + (p.cleaned.count === 1 ? "" : "s")
                    cleanMsgTimer.restart()
                }
            } catch (e) { /* keep the last good table */ }
        }
    }

    // The trailing shell comment gives every run a distinct source name —
    // reconnecting an identical source name is a no-op, which would silently
    // swallow manual refreshes.
    //
    // The counter WRAPS, and must. Plasma5Support exposes source names through a
    // QQmlPropertyMap backed by a QQmlOpenMetaObject, which is append-only: every
    // name ever used stays a property forever (removeSource → clear() → setValue
    // → createProperty *adds* one), and each connect/disconnect calls
    // QMetaObjectBuilder::toMetaObject() to rebuild the metaobject over all of
    // them. An unbounded counter makes each 3 s poll O(polls so far) — after a
    // day of uptime plasmashell's main thread sat pinned at 100% rebuilding a
    // ~28k-property metaobject, and the panel lagged. Wrapping keeps the cost
    // constant; 8 × 3 s means a name is reused only after 24 s, long after its
    // DataContainer is gone, so refreshes still never collapse into a no-op.
    function refresh() {
        root.busy = true
        root.fetchSeq = (root.fetchSeq + 1) % 8
        execSummary.connectSource(root.cmd + " # " + root.fetchSeq)
    }
    function refreshProcs() {
        root.fetchSeq = (root.fetchSeq + 1) % 8
        execProcs.connectSource(root.cmd + " --procs # " + root.fetchSeq)
    }
    // Deletes and rescans in one helper run, so the table updates with the result.
    function cleanClaudeTmp() {
        root.cleanArmed = false
        root.cleaning = true
        root.fetchSeq = (root.fetchSeq + 1) % 8
        execProcs.connectSource(root.cmd + " --clean-claude-tmp --procs # " + root.fetchSeq)
    }
    function openSystemMonitor() {
        root.fetchSeq = (root.fetchSeq + 1) % 8
        execSummary.connectSource("plasma-systemmonitor >/dev/null 2>&1 & # " + root.fetchSeq)
        root.expanded = false
    }

    Timer { interval: root.pollMs; running: !root.expanded; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
    Timer { interval: root.procPollMs; running: root.expanded; repeat: true; triggeredOnStart: true; onTriggered: root.refreshProcs() }
    Timer { interval: 15000; running: root.busy; repeat: false; onTriggered: root.busy = false }
    Timer { interval: 4000; running: root.cleanArmed; repeat: false; onTriggered: root.cleanArmed = false }
    Timer { interval: 30000; running: root.cleaning; repeat: false; onTriggered: root.cleaning = false }
    Timer { id: cleanMsgTimer; interval: 6000; repeat: false; onTriggered: root.cleanMsg = "" }

    onExpandedChanged: if (!expanded) openGroup = ""

    // ---------- helpers ----------
    function fmtKb(kb) {
        if (kb === undefined || kb === null) return "—"
        if (kb < 1024) return kb + " kB"
        var mb = kb / 1024
        if (mb < 1024) return (mb < 10 ? mb.toFixed(1) : Math.round(mb)) + " MiB"
        return (mb / 1024).toFixed(mb / 1024 < 10 ? 2 : 1) + " GiB"
    }
    function fmtKbShort(kb) {
        if (kb === undefined || kb === null) return "—"
        var mb = kb / 1024
        if (mb < 1024) return Math.round(mb) + "M"
        var gb = mb / 1024
        return (gb < 10 ? gb.toFixed(1) : Math.round(gb)) + "G"
    }
    function ageStr(s) {
        if (!s) return ""
        var d = Math.floor(s / 86400)
        var h = Math.floor((s % 86400) / 3600)
        var m = Math.floor((s % 3600) / 60)
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }
    function agoStr(ms) {
        if (!ms) return "never"
        var secs = Math.floor(Math.max(0, new Date().getTime() - ms) / 1000)
        if (secs < 90) return "just now"
        return Math.floor(secs / 60) + "m ago"
    }
    // Orange/red only under real pressure — a permanently green panel number is
    // just noise, so normal usage keeps the ordinary text colour.
    function pctColor(p) {
        if (p === undefined || p === null) return Kirigami.Theme.textColor
        if (p >= 90) return Kirigami.Theme.negativeTextColor
        if (p >= 75) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.textColor
    }
    function shareOfTotal(kb) {
        return (mem && mem.total_kb) ? (kb * 100.0 / mem.total_kb) : 0
    }
    // Row bars are scaled against the biggest consumer, not against total RAM:
    // as a fraction of 47 GiB even the top process is a ~8% sliver, which reads
    // as noise rather than as a comparison. The % label still shows the honest
    // share of total. groups[0] is the largest — the helper sorts descending and
    // appends "Other" last.
    function shareOfMax(kb) {
        if (!groups || groups.length === 0) return 0
        var max = groups[0].kb
        return max > 0 ? Math.min(100, kb * 100.0 / max) : 0
    }

    // ---------- compact (in-panel) ----------
    compactRepresentation: MouseArea {
        id: compact
        Layout.minimumWidth: col.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.preferredWidth: col.implicitWidth + Kirigami.Units.smallSpacing * 2
        Layout.minimumHeight: col.implicitHeight
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.MiddleButton) root.openSystemMonitor()
            else root.expanded = !root.expanded
        }

        ColumnLayout {
            id: col
            anchors.centerIn: parent
            spacing: 0

            PlasmaComponents3.Label {   // percentage — headline
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                text: root.mem ? (Math.round(root.mem.pct) + "%") : "—"
                color: root.mem ? root.pctColor(root.mem.pct) : Kirigami.Theme.disabledTextColor
                font.bold: true
                font.pixelSize: Math.round(Kirigami.Theme.defaultFont.pixelSize * 1.1)
                font.features: { "tnum": 1 }
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 8
                horizontalAlignment: Text.AlignHCenter
            }
            PlasmaComponents3.Label {   // absolute usage — below
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                text: root.mem ? root.fmtKbShort(root.mem.used_kb)
                                : (root.errorMsg !== "" ? "!" : "…")
                opacity: 0.8
                font.pixelSize: Math.round(Kirigami.Theme.smallFont.pixelSize)
                font.features: { "tnum": 1 }
                fontSizeMode: Text.HorizontalFit
                minimumPixelSize: 7
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // ---------- full (popup) ----------
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 26
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            // ---- header ----
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Heading { level: 3; text: "Memory" }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Label {
                    text: root.agoStr(root.lastFetchMs)
                    opacity: 0.6
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "utilities-system-monitor"
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    text: "System Monitor"
                    onClicked: root.openSystemMonitor()
                    PlasmaComponents3.ToolTip.text: "Open System Monitor"
                    PlasmaComponents3.ToolTip.visible: hovered
                    PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
                PlasmaComponents3.ToolButton {
                    icon.name: "view-refresh"
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    text: "Refresh"
                    onClicked: root.refreshProcs()
                    PlasmaComponents3.ToolTip.text: "Refresh now"
                    PlasmaComponents3.ToolTip.visible: hovered
                    PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
            }

            // ---- headline: used of total ----
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents3.Label {
                    text: root.mem ? root.fmtKb(root.mem.used_kb) : "—"
                    font.bold: true
                    font.pixelSize: Math.round(Kirigami.Theme.defaultFont.pixelSize * 1.6)
                    color: root.mem ? root.pctColor(root.mem.pct) : Kirigami.Theme.textColor
                }
                PlasmaComponents3.Label {
                    text: root.mem ? ("of " + root.fmtKb(root.mem.total_kb)) : ""
                    opacity: 0.7
                    Layout.alignment: Qt.AlignBottom
                    Layout.bottomMargin: 2
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Label {
                    text: root.mem ? (Math.round(root.mem.pct) + "%") : ""
                    font.bold: true
                    font.pixelSize: Math.round(Kirigami.Theme.defaultFont.pixelSize * 1.6)
                    color: root.mem ? root.pctColor(root.mem.pct) : Kirigami.Theme.textColor
                }
            }

            // ---- composition bar: in use | reclaimable | free ----
            // The three segments come from MemTotal/MemAvailable/MemFree and so
            // sum to exactly the total — no rounding gap to paper over.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 0.9
                Layout.topMargin: Kirigami.Units.smallSpacing
                clip: true

                Rectangle {
                    anchors.fill: parent
                    radius: 2
                    color: Kirigami.Theme.alternateBackgroundColor
                }
                Row {
                    anchors.fill: parent
                    Rectangle {
                        width: root.mem ? parent.width * root.mem.used_kb / root.mem.total_kb : 0
                        height: parent.height
                        color: root.mem && root.mem.pct >= 90 ? Kirigami.Theme.negativeTextColor
                             : root.mem && root.mem.pct >= 75 ? Kirigami.Theme.neutralTextColor
                             : Kirigami.Theme.highlightColor
                        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                    }
                    Rectangle {
                        width: root.mem ? parent.width * root.mem.reclaimable_kb / root.mem.total_kb : 0
                        height: parent.height
                        color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                                       Kirigami.Theme.highlightColor.b, 0.28)
                        Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                    }
                }
            }

            // ---- legend / stats ----
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2
                spacing: Kirigami.Units.largeSpacing

                Repeater {
                    model: root.mem ? [
                        { key: "In use",      val: root.mem.used_kb,        dot: 1.0 },
                        { key: "Cache",       val: root.mem.reclaimable_kb, dot: 0.28 },
                        { key: "Free",        val: root.mem.free_kb,        dot: 0.0 }
                    ] : []
                    delegate: RowLayout {
                        required property var modelData
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            implicitWidth: Kirigami.Units.smallSpacing * 1.5
                            implicitHeight: Kirigami.Units.smallSpacing * 1.5
                            radius: width / 2
                            color: modelData.dot > 0
                                   ? Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                                             Kirigami.Theme.highlightColor.b, modelData.dot)
                                   : Kirigami.Theme.alternateBackgroundColor
                        }
                        PlasmaComponents3.Label {
                            text: modelData.key + " " + root.fmtKb(modelData.val)
                            opacity: 0.75
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.features: { "tnum": 1 }
                        }
                    }
                }
                Item { Layout.fillWidth: true }
            }

            // ---- swap, only when it's actually in use ----
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                visible: root.mem && root.mem.swap_used_kb > 0
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents3.Label {
                    text: "Swap"
                    opacity: 0.75
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.smallSpacing * 1.5
                    clip: true
                    Rectangle { anchors.fill: parent; radius: 2; color: Kirigami.Theme.alternateBackgroundColor }
                    Rectangle {
                        width: root.mem ? parent.width * root.mem.swap_pct / 100 : 0
                        height: parent.height
                        radius: 2
                        color: Kirigami.Theme.neutralTextColor
                        opacity: 0.7
                    }
                }
                PlasmaComponents3.Label {
                    text: root.mem ? (root.fmtKb(root.mem.swap_used_kb) + " of " + root.fmtKb(root.mem.swap_total_kb)) : ""
                    opacity: 0.75
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                    font.features: { "tnum": 1 }
                }
            }

            Kirigami.Separator { Layout.fillWidth: true; Layout.topMargin: Kirigami.Units.smallSpacing }

            // ---- top consumers ----
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                Kirigami.Heading { level: 4; text: "Top consumers" }
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Label {
                    text: root.procCount > 0 ? (root.procCount + " processes") : ""
                    opacity: 0.55
                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                }
            }

            PlasmaComponents3.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: parent.width
                    spacing: 1

                    Repeater {
                        // The model is the row COUNT, not the array itself. Assigning
                        // a fresh array every poll would destroy and rebuild every
                        // delegate, and a newly-built Rectangle starts at width 0 —
                        // so each refresh visibly animated the bars up from nothing.
                        // An int model keeps the delegates alive, so the bindings
                        // just update and Behavior animates from the previous value.
                        model: root.groups.length
                        delegate: ColumnLayout {
                            id: groupRow
                            required property int index
                            // Never null: a blank stand-in keeps every binding below
                            // total, rather than needing a guard apiece.
                            readonly property var g: index < root.groups.length
                                ? root.groups[index]
                                : ({ name: "", kb: 0, procs: 0, items: [], is_other: true })
                            readonly property bool isOpen: g.name !== "" && root.openGroup === g.name
                            Layout.fillWidth: true
                            spacing: 0

                            // group row — a proportional bar sits behind the text
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: Kirigami.Units.gridUnit * 1.6

                                Rectangle {   // bar, scaled against the biggest consumer
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: parent.height
                                    width: parent.width * root.shareOfMax(groupRow.g.kb) / 100
                                    radius: 2
                                    color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                                                   Kirigami.Theme.highlightColor.b, 0.22)
                                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                                }
                                Rectangle {   // hover/expanded highlight
                                    anchors.fill: parent
                                    radius: 2
                                    color: Kirigami.Theme.highlightColor
                                    opacity: groupRow.isOpen ? 0.10 : (rowMouse.containsMouse ? 0.06 : 0)
                                }

                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: groupRow.g.is_other ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    onClicked: {
                                        if (groupRow.g.is_other) return
                                        root.openGroup = groupRow.isOpen ? "" : groupRow.g.name
                                    }
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Kirigami.Units.smallSpacing
                                    anchors.rightMargin: Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing

                                    Kirigami.Icon {
                                        source: groupRow.isOpen ? "go-down-symbolic" : "go-next-symbolic"
                                        implicitWidth: Kirigami.Units.iconSizes.small
                                        implicitHeight: Kirigami.Units.iconSizes.small
                                        opacity: groupRow.g.is_other ? 0 : (rowMouse.containsMouse || groupRow.isOpen ? 0.7 : 0.3)
                                    }
                                    PlasmaComponents3.Label {
                                        text: groupRow.g.name
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: Kirigami.Units.gridUnit * 10
                                        font.bold: groupRow.isOpen
                                    }
                                    PlasmaComponents3.Label {
                                        text: "×" + groupRow.g.procs
                                        visible: groupRow.g.procs > 1
                                        opacity: 0.5
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    // tmp row: how much of it belongs to sessions that are gone
                                    PlasmaComponents3.Label {
                                        visible: groupRow.g.is_tmp === true
                                                 && (root.cleanMsg !== "" || (groupRow.g.ended_kb || 0) > 0)
                                        text: root.cleanMsg !== "" ? root.cleanMsg
                                              : root.fmtKb(groupRow.g.ended_kb) + " from ended sessions"
                                        color: root.cleanMsg !== "" ? Kirigami.Theme.positiveTextColor
                                                                    : Kirigami.Theme.neutralTextColor
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                        Layout.minimumWidth: 0
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    // Two-click delete: the first click arms it for 4 s.
                                    PlasmaComponents3.ToolButton {
                                        visible: groupRow.g.is_tmp === true && (groupRow.g.ended_kb || 0) > 0
                                        enabled: !root.cleaning
                                        icon.name: "edit-delete"
                                        text: root.cleanArmed ? ("Delete " + root.fmtKb(groupRow.g.ended_kb) + "?") : "Clear"
                                        display: PlasmaComponents3.AbstractButton.TextBesideIcon
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        implicitHeight: Kirigami.Units.gridUnit * 1.3
                                        onClicked: {
                                            if (root.cleanArmed) root.cleanClaudeTmp()
                                            else root.cleanArmed = true
                                        }
                                        PlasmaComponents3.ToolTip.text: root.cleanArmed
                                            ? "Click again to delete temp files of " + groupRow.g.ended + " ended Claude session"
                                              + (groupRow.g.ended === 1 ? "" : "s")
                                            : "Delete temp files of ended Claude sessions (live and recently-written ones are kept)"
                                        PlasmaComponents3.ToolTip.visible: hovered
                                        PlasmaComponents3.ToolTip.delay: Kirigami.Units.toolTipDelay
                                    }
                                    Item { Layout.fillWidth: true }
                                    PlasmaComponents3.Label {
                                        text: Math.round(root.shareOfTotal(groupRow.g.kb)) + "%"
                                        opacity: 0.55
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        font.features: { "tnum": 1 }
                                    }
                                    PlasmaComponents3.Label {
                                        text: root.fmtKb(groupRow.g.kb)
                                        font.bold: true
                                        font.features: { "tnum": 1 }
                                        horizontalAlignment: Text.AlignRight
                                        Layout.minimumWidth: Kirigami.Units.gridUnit * 4
                                    }
                                }
                            }

                            // per-process detail — what tells nine identical
                            // sessions of the same program apart
                            Repeater {
                                model: groupRow.isOpen ? groupRow.g.items : []
                                delegate: RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.leftMargin: Kirigami.Units.gridUnit + Kirigami.Units.smallSpacing
                                    Layout.rightMargin: Kirigami.Units.smallSpacing
                                    spacing: Kirigami.Units.smallSpacing

                                    // Claude temp rows: a session dir, not a process
                                    readonly property bool isTmp: modelData.measured === "tmpfs"
                                    PlasmaComponents3.Label {
                                        visible: parent.isTmp
                                        text: modelData.label || ""
                                        elide: Text.ElideMiddle
                                        Layout.maximumWidth: Kirigami.Units.gridUnit * 9
                                        opacity: modelData.status === "ended" ? 0.9 : 0.7
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    PlasmaComponents3.Label {
                                        visible: parent.isTmp && (modelData.session || "") !== ""
                                        text: modelData.session || ""
                                        opacity: 0.45
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        font.family: "monospace"
                                    }
                                    PlasmaComponents3.Label {
                                        visible: parent.isTmp && modelData.status !== "shared"
                                        text: modelData.status === "live" ? ("live " + (modelData.tty || ("pid " + modelData.pid)))
                                            : modelData.status === "recent" ? "no session · in use"
                                            : "ended"
                                        color: modelData.status === "ended" ? Kirigami.Theme.neutralTextColor
                                             : modelData.status === "live" ? Kirigami.Theme.positiveTextColor
                                             : Kirigami.Theme.textColor
                                        opacity: modelData.status === "recent" ? 0.55 : 0.9
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    PlasmaComponents3.Label {
                                        visible: !parent.isTmp
                                        text: modelData.pid
                                        opacity: 0.55
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        font.features: { "tnum": 1 }
                                    }
                                    PlasmaComponents3.Label {
                                        text: modelData.tty
                                        visible: !parent.isTmp && modelData.tty !== ""
                                        opacity: 0.55
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                    }
                                    PlasmaComponents3.Label {
                                        text: parent.isTmp
                                              ? (modelData.age_s > 0 ? ("· " + root.ageStr(modelData.age_s) + " ago") : "")
                                              : ("up " + root.ageStr(modelData.age_s))
                                        visible: text !== ""
                                        opacity: 0.55
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        font.features: { "tnum": 1 }
                                    }
                                    Item { Layout.fillWidth: true }
                                    PlasmaComponents3.Label {
                                        text: root.fmtKb(modelData.kb)
                                        opacity: 0.75
                                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        font.features: { "tnum": 1 }
                                    }
                                }
                            }

                            // The helper caps the per-group detail, so say so
                            // rather than let 8 of 10 rows read as the full list.
                            PlasmaComponents3.Label {
                                Layout.leftMargin: Kirigami.Units.gridUnit + Kirigami.Units.smallSpacing
                                visible: groupRow.isOpen
                                         && groupRow.g.procs > groupRow.g.items.length
                                text: "+ " + (groupRow.g.procs - groupRow.g.items.length)
                                      + " smaller, not shown"
                                opacity: 0.45
                                font.pointSize: Kirigami.Theme.smallFont.pointSize
                            }
                        }
                    }

                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        Layout.topMargin: Kirigami.Units.largeSpacing
                        visible: root.groups.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        opacity: 0.6
                        text: root.errorMsg !== "" ? "Couldn't read /proc" : "Scanning processes…"
                    }
                }
            }

            // ---- footnote: what the numbers actually mean ----
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                visible: root.groups.length > 0
                wrapMode: Text.WordWrap
                opacity: 0.5
                font.pointSize: Kirigami.Theme.smallFont.pointSize
                text: "Proportional set size — shared pages split between the processes sharing them"
                      + (root.rssFallback > 0 ? (", except " + root.rssFallback + " unreadable process"
                                                 + (root.rssFallback === 1 ? "" : "es") + " shown as RSS") : "")
                      + ". Claude temp files are tmpfs in /tmp, counted whether in RAM or swap."
                      + " Click a row for individual processes."
            }
        }
    }
}
