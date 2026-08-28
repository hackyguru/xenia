// Xenia — ask any model on the Logos network, pay privately.
// (module id stays `inference`/`inference_ui`; the topic namespace is on the wire)
//
// QML frontend for the `inference` core module. Providers are discovered from
// signed capability cards on the global discovery topic; prompts are sealed
// end-to-end to the chosen provider and paid (when priced) through the shared
// persona_core wallet — the payer stays shielded.
//
// Visuals follow the Basecamp design system (Logos.Theme + Logos.Controls),
// mirroring the Persona wallet app so the two feel like one product family.
// The network plumbing (rooms, topics, node control) lives behind "Advanced";
// the everyday surface is just: pick a model, chat, watch it answer.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

Rectangle {
    id: root
    width: 720
    height: 940
    color: Theme.palette.background

    property int    deliveryStatus: 0
    property var    exchanges: []
    property string myId: ""
    property string currentRoom: "agora"
    property bool   identityInit: false
    property bool   identityLocked: false
    property string identityFp: ""
    property string identityBackend: ""
    property string freshMnemonic: ""   // held only while the reveal overlay is open
    property var    providers: []       // verified roster from signed announces
    property bool   requireEncryption: false
    property string preferredProvider: ""   // "" = auto
    property string modelFilter: ""         // "" = any model
    property bool   trustedOnly: false      // whitelist enforcement
    // distinctModels() is O(providers x models) and was being re-run from a
    // binding on every announce, rebuilding every chip. Cache it and recompute
    // only when the roster actually changes.
    property var    modelsCache: []
    property string modelSearch: ""         // narrows the chip row when models are many
    readonly property int modelChipCap: 14  // chips rendered before we require a search
    onProvidersChanged: modelsCache = distinctModels()
    property int    trustedCount: 0
    property bool   advancedOpen: false
    property bool   _autoStarted: false     // auto-connect attempted this session
    property string copied: ""

    // ── First-run onboarding (create-with-seed / restore / unlock) ───
    // Full-screen gate shown until an identity exists and is unlocked.
    // 0 = welcome · 1 = phrase · 2 = confirm · 3 = restore
    property int    onbStep: 0
    property var    onbVerifyIdx: []        // word positions to confirm at verify
    property bool   onbSaved: false         // user ticked "I saved my phrase"
    property string onbError: ""            // restore / unlock failure, plain words
    property bool   onbPreview: false       // walk the flow without touching the account
    readonly property bool onbActive: identityLocked || !identityInit
                                      || freshMnemonic.length > 0 || onbPreview
    property string walletMsg: ""           // wallet dialog feedback line

    // ── LEZ wallet (payment source for lez/paid providers) ───────────
    property bool   walletHasWallet: false  // a wallet exists on disk
    property bool   walletOpen: false       // LEZ side is open (can pay)
    property string walletPrivBal: "…"      // shielded balance we pay from
    property string walletPubBal: "…"       // transparent balance
    property bool   walletBusy: false
    property var    paySessions: []         // active prepaid sessions to providers
    property var    payStartTick: ({})      // provider → tick when its proof started
    property int    payTick: 0              // ~1s counter for the elapsed display

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callInf(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("inference", method, args)
    }

    // Paid providers are settled through the shared persona_core wallet module
    // (formerly logos_wallet), so we query it straight from here to show the
    // balance the payment spends from
    // (and to open it — otherwise a paid prompt silently can't pay).
    // ASYNC only. A synchronous callModule to persona_core blocks the QML thread
    // when the module isn't loaded (e.g. Xenia opened without the wallet
    // app / easynode first) — which froze the whole UI. Async can never hang it.
    function callWallet(method, args, cb) {
        if (typeof logos === "undefined" || !logos.callModuleAsync) { if (cb) cb(null); return }
        logos.callModuleAsync("persona_core", method, args, function(raw) { if (cb) cb(raw) })
    }
    function walletParse(raw) {
        var v = raw
        for (var i = 0; i < 2 && typeof v === "string"; i++) { try { v = JSON.parse(v) } catch (e) { break } }
        return (v && typeof v === "object") ? v : null
    }
    property bool walletLoaded: false        // persona_core module is present/loaded
    function refreshWallet() {
        callWallet("lezStatus", [], function(raw) {
            const st = walletParse(raw)
            walletLoaded = !!st
            if (!st) return   // module not loaded yet — chip prompts to open Persona
            walletHasWallet = !!st.hasWallet
            walletOpen      = !!st.ready
            walletBusy      = !!st.busy
            // Auto-open a persisted wallet so paying just works (no separate app trip).
            if (walletHasWallet && !walletOpen && !walletBusy) { callWallet("lezOpen", [], null); return }
            if (!walletOpen) return
            // Balance we can pay with = the TOTAL across every private account
            // (the deshield auto-picks whichever holds funds).
            callWallet("lezAccounts", [], function(araw) {
                const acc = walletParse(araw)
                if (acc && acc.ok && Array.isArray(acc.accounts)) {
                    var priv = 0, pub = 0
                    for (var i = 0; i < acc.accounts.length; i++) {
                        var b = Number(acc.accounts[i].balance) || 0
                        if (acc.accounts[i].isPublic) pub += b; else priv += b
                    }
                    walletPrivBal = String(priv)
                    walletPubBal  = String(pub)
                }
            })
        })
    }

    // Basecamp JSON-encodes every remote-method return, so a C++ QString arrives
    // in QML as a JSON-string literal. Unwrap that layer before using.
    function unwrapRemote(raw, defaultVal) {
        if (raw === null || raw === undefined) return defaultVal
        if (typeof raw !== "string") return raw
        try { return JSON.parse(raw) } catch (e) { return defaultVal }
    }

    function refresh() {
        const sNum = unwrapRemote(callInf("deliveryStatus", []), 0)
        deliveryStatus = (typeof sNum === "number") ? sNum : 0
        // Consumer idiom: the network connects itself. One attempt per open;
        // the Advanced sheet keeps a manual switch for the curious.
        if (!_autoStarted && deliveryStatus === 0) {
            _autoStarted = true
            callInf("startDelivery", [])
        }
        if (myId === "") {
            const v = unwrapRemote(callInf("myId", []), "")
            myId = (typeof v === "string") ? v : ""
        }
        const r = unwrapRemote(callInf("room", []), "agora")
        if (typeof r === "string" && r.length > 0) currentRoom = r
        const inner = unwrapRemote(callInf("listExchanges", []), [])
        try {
            exchanges = (typeof inner === "string") ? JSON.parse(inner) : inner
        } catch (e) { exchanges = [] }
        refreshIdentity()
        const provRaw = unwrapRemote(callInf("listProviders", []), [])
        try {
            providers = (typeof provRaw === "string") ? JSON.parse(provRaw) : provRaw
        } catch (e) { providers = [] }
        const psRaw = unwrapRemote(callInf("paymentStatus", []), [])   // cheap in-memory call
        try {
            paySessions = (typeof psRaw === "string") ? JSON.parse(psRaw) : psRaw
        } catch (e) { paySessions = [] }
        // Track when each in-flight (not-yet-funded) payment's proof started, so
        // we can show a live elapsed time while the zk proof generates.
        var seen = {}
        for (var i = 0; i < paySessions.length; i++) {
            var f = paySessions[i].provider; seen[f] = true
            if (!paySessions[i].ready && payStartTick[f] === undefined) payStartTick[f] = payTick
            if (paySessions[i].ready) delete payStartTick[f]
        }
        for (var k in payStartTick) if (!seen[k]) delete payStartTick[k]
        // Wallet queries are heavier (lezAccounts walks every account), so
        // throttle them — every ~6s — to keep the 1s refresh loop light.
        if (_walletTick++ % 6 === 0) refreshWallet()
    }
    property int _walletTick: 0

    function liveProviders() {
        var n = 0
        for (var i = 0; i < providers.length; i++)
            if (providers[i].live) n++
        return n
    }

    function refreshIdentity() {
        const raw = unwrapRemote(callInf("identityStatus", []), "")
        try {
            const st = (typeof raw === "string") ? JSON.parse(raw) : raw
            identityInit      = !!st.initialized
            identityLocked    = !!st.locked
            identityFp        = st.fingerprint || ""
            identityBackend   = st.backend || ""
            requireEncryption = !!st.requireEncryption
            preferredProvider = st.preferredProvider || ""
            modelFilter       = st.modelFilter || ""
            trustedOnly       = !!st.trustedOnly
            trustedCount      = st.trustedCount || 0
        } catch (e) { /* keep previous state */ }
    }

    function providerModels(p) {
        return (p.models && p.models.length > 0) ? p.models.join(", ") : (p.model || "?")
    }

    // Human price label: "Free" or e.g. "0.5 / prompt". Assetless amounts are
    // LEZ units until LEZ names them.
    function priceLabel(p) {
        // Incentivized (LEZ payment stream): billed by rate over time, not a
        // per-request amount — so priceAmount is 0 but it is NOT free.
        if (p.access === "lez") return "⚡ " + (p.rate || 0) + "/s"
        if (!p.priceAmount || p.priceAmount <= 0) return "Free"
        var unit = p.priceUnit === "1ktokens" ? "1k tokens" : "prompt"
        return p.priceAmount + " / " + unit
    }
    function isPaid(p) { return p.access === "lez" || (p.priceAmount > 0) }

    // Every distinct model advertised by a live provider — feeds the model picker.
    function distinctModels() {
        var out = []
        for (var i = 0; i < providers.length; i++) {
            if (!providers[i].live) continue
            var ms = (providers[i].models && providers[i].models.length > 0)
                     ? providers[i].models : [providers[i].model]
            for (var j = 0; j < ms.length; j++)
                if (ms[j] && out.indexOf(ms[j]) === -1) out.push(ms[j])
        }
        out.sort()
        return out
    }

    // Chips to render right now: search-filtered, then capped so a large
    // marketplace can't produce an unbounded row. hiddenModels() reports the
    // remainder so the count is never silently dropped.
    function shownModels() {
        var q = modelSearch.trim().toLowerCase()
        var out = []
        for (var i = 0; i < modelsCache.length && out.length < modelChipCap; i++)
            if (q === "" || modelsCache[i].toLowerCase().indexOf(q) !== -1)
                out.push(modelsCache[i])
        return out
    }
    function matchingModelCount() {
        var q = modelSearch.trim().toLowerCase()
        if (q === "") return modelsCache.length
        var n = 0
        for (var i = 0; i < modelsCache.length; i++)
            if (modelsCache[i].toLowerCase().indexOf(q) !== -1) n++
        return n
    }

    function providerServes(p, m) {
        if (!m || m.length === 0) return true
        var ms = (p.models && p.models.length > 0) ? p.models : [p.model]
        return ms.indexOf(m) !== -1
    }

    function findProvider(fp) {
        for (var i = 0; i < providers.length; i++)
            if (providers[i].id === fp) return providers[i]
        return null
    }

    // Providers a prompt could go to right now (live, serving the model
    // filter, and — when Trusted only is on — whitelisted).
    function eligibleProviders() {
        var n = 0
        for (var i = 0; i < providers.length; i++)
            if (providers[i].live && providerServes(providers[i], modelFilter)
                && (!trustedOnly || providers[i].trusted)) n++
        return n
    }

    // One plain sentence: where will my next prompt go?
    function routingSummary() {
        if (preferredProvider.length > 0)
            return "Prompts go to your pinned provider "
                   + preferredProvider.substring(0, 10) + "…"
                   + (modelFilter ? " running " + modelFilter : "")
        var n = eligibleProviders()
        if (n === 0) {
            if (trustedOnly && trustedCount === 0)
                return "Trusted-only is on but nothing is trusted yet — trust a provider below"
            return modelFilter
                ? "No online provider serves " + modelFilter + " right now"
                : "Looking for providers on the network…"
        }
        return "Auto-picking the best of " + n + " available provider" + (n > 1 ? "s" : "")
               + (modelFilter ? " serving " + modelFilter : "")
    }

    function setModel(v) {
        callInf("setModelFilter", [v])
        // A pinned provider that can't serve the new model would silently
        // never be picked — unpin instead.
        var p = findProvider(preferredProvider)
        if (p && !providerServes(p, v))
            callInf("setPreferredProvider", [""])
        refreshIdentity()
    }

    function unlockIdentity() {
        onbError = ""
        const ok = unwrapRemote(callInf("unlock", [unlockField.text]), false)
        if (ok === true) unlockField.text = ""
        else onbError = "That passphrase didn't unlock the key — try again."
        refreshIdentity()
    }

    function createIdentity() {
        onbError = ""
        const m = unwrapRemote(callInf("createAccount", [""]), "")
        refreshIdentity()
        if (typeof m === "string" && m.length > 0) {
            freshMnemonic = m
            onbSaved = false
            onbStep = 1
        }
    }

    function importIdentity() {
        const phrase = onbImportField.text.trim()
        if (phrase.length === 0) return
        onbError = ""
        const ok = unwrapRemote(callInf("importAccount", [phrase, ""]), false)
        if (ok === true) {
            onbImportField.text = ""
            onbStep = 0
        } else {
            onbError = "That phrase couldn't be restored — check the words and try again."
        }
        refreshIdentity()
    }

    // Move from "here's your phrase" to the confirm step, choosing 3 random
    // word positions the user must fill back in (the Persona onboarding drill).
    function onbToVerify() {
        var words = freshMnemonic.trim().split(/\s+/)
        var idx = []
        while (idx.length < 3 && words.length >= 3) {
            var r = Math.floor(Math.random() * words.length)
            if (idx.indexOf(r) === -1) idx.push(r)
        }
        idx.sort(function (a, b) { return a - b })
        onbVerifyIdx = idx
        onbStep = 2
    }
    function onbVerifyOk(fields) {
        var words = freshMnemonic.trim().split(/\s+/)
        for (var i = 0; i < onbVerifyIdx.length; i++)
            if ((fields[i] || "").trim().toLowerCase()
                !== (words[onbVerifyIdx[i]] || "").toLowerCase())
                return false
        return true
    }
    // Finish onboarding: wipe the phrase from memory and drop into the app.
    function onbFinish() {
        freshMnemonic = ""
        onbStep = 0
        onbSaved = false
        onbError = ""
        onbPreview = false
    }
    // Dev preview: walk the whole flow without creating/restoring anything.
    function onbPreviewStart() {
        onbPreview = true
        onbSaved = false
        onbStep = 0
    }
    function onbPreviewSeed() {
        freshMnemonic = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        onbSaved = false
        onbStep = 1
    }

    // Any live provider that would need the wallet to answer?
    function anyPaidLive() {
        for (var i = 0; i < providers.length; i++)
            if (providers[i].live && isPaid(providers[i])) return true
        return false
    }

    function send() {
        const p = promptField.text.trim()
        if (p.length === 0 || deliveryStatus === 0) return
        callInf("sendPrompt", [p])
        promptField.text = ""
        refresh()
    }

    function copy(text, key) {
        clipProxy.text = text
        clipProxy.selectAll()
        clipProxy.copy()
        copied = key
        copiedReset.restart()
    }
    Timer { id: copiedReset; interval: 1400; onTriggered: root.copied = "" }
    TextEdit { id: clipProxy; visible: false }

    function statusText(s) {
        if (s === 0) return "Offline"
        if (s === 1) return "Connecting"
        if (s === 2) return "Online"
        if (s === 3) return "Error"
        return ""
    }
    function statusColor(s) {
        if (s === 2) return Theme.palette.success
        if (s === 1) return Theme.palette.warning
        if (s === 3) return Theme.palette.error
        return Theme.palette.textTertiary
    }
    function topicFor(room) { return "/inference/1/" + room + "/json" }
    function clock(sec) {
        var mm = Math.floor(sec / 60), ss = sec % 60
        return mm + ":" + (ss < 10 ? "0" : "") + ss
    }

    // ── Design-system building blocks (Persona idiom) ────────────────

    // Neutral charcoal card with an optional coral-ticked micro-title.
    // glow: true adds a faint coral wash + floating orbs (hero cards).
    component Card: Rectangle {
        id: cardRoot
        default property alias content: cardCol.data
        property string title: ""
        property string tip: ""
        property bool glow: false
        Layout.fillWidth: true
        color: Theme.palette.backgroundTertiary
        border.color: Theme.palette.borderSubtle
        border.width: 1
        radius: Theme.spacing.radiusLarge
        implicitHeight: cardCol.implicitHeight + Theme.spacing.large * 2

        Rectangle {
            visible: cardRoot.glow
            anchors.fill: parent
            radius: cardRoot.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.colors.getColor(Theme.palette.primary, 0.10) }
                GradientStop { position: 0.6; color: "transparent" }
            }
        }
        Rectangle {
            visible: cardRoot.glow
            width: 120; height: 120; radius: 60
            anchors { top: parent.top; right: parent.right; topMargin: 14; rightMargin: 22 }
            color: "transparent"
            border.width: 1.5
            border.color: Theme.colors.getColor(Theme.palette.primary, 0.25)
        }
        Rectangle {
            visible: cardRoot.glow
            width: 52; height: 52; radius: 26
            anchors { top: parent.top; right: parent.right; topMargin: 52; rightMargin: 120 }
            color: Theme.colors.getColor(Theme.palette.primary, 0.10)
        }

        ColumnLayout {
            id: cardCol
            anchors { fill: parent; margins: Theme.spacing.large }
            spacing: Theme.spacing.medium
            RowLayout {
                visible: cardRoot.title.length > 0
                spacing: Theme.spacing.small
                Rectangle { implicitWidth: 4; implicitHeight: 12; radius: 2; color: Theme.palette.primary }
                LogosText {
                    text: cardRoot.title
                    color: Theme.palette.textSecondary
                    font.pixelSize: 11
                    font.weight: Theme.typography.weightMedium
                    font.letterSpacing: 0.8
                    font.capitalization: Font.AllUppercase
                }
                InfoTip { tip: cardRoot.tip }
            }
        }
    }

    // Auto-sizing button in the Basecamp idiom; accent = coral-tinted CTA.
    component ActionButton: Control {
        id: btn
        property string text: ""
        property string tip: ""
        property bool accent: false
        property bool danger: false
        signal clicked
        hoverEnabled: true
        implicitHeight: 36
        implicitWidth: btnLabel.implicitWidth + 32
        readonly property bool isActive: btnMa.pressed || btn.hovered
        scale: (btnMa.pressed && btn.enabled) ? 0.96 : 1.0
        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
        Tip { text: btn.tip; visible: btn.hovered && btn.tip.length > 0 }
        background: Rectangle {
            radius: Theme.spacing.radiusXlarge
            gradient: (btn.accent && btn.enabled) ? accentGrad : null
            color: !btn.enabled ? Theme.palette.backgroundMuted : btn.danger ? Theme.colors.getColor(Theme.palette.error, btn.isActive ? 0.30 : 0.15) : (btn.isActive ? Theme.palette.backgroundMuted : Theme.palette.backgroundSecondary)
            border.width: (btn.accent && btn.enabled) ? 0 : 1
            border.color: !btn.enabled ? Theme.palette.border : btn.danger ? Theme.palette.error : (btn.isActive ? Theme.palette.overlayOrange : Theme.palette.border)
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: "#FFFFFF"
                opacity: (btn.accent && btn.enabled && btn.isActive) ? 0.14 : 0
                Behavior on opacity { NumberAnimation { duration: 120 } }
            }
        }
        contentItem: LogosText {
            id: btnLabel
            text: btn.text
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: Theme.typography.secondaryText
            font.weight: btn.accent ? Theme.typography.weightBold : Theme.typography.weightMedium
            color: !btn.enabled ? Theme.palette.textMuted : btn.accent ? "#241511" : btn.danger ? Theme.palette.error : Theme.palette.text
        }
        MouseArea {
            id: btnMa
            anchors.fill: parent
            enabled: btn.enabled
            cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: btn.clicked()
        }
    }
    // Brand coral gradient (same ramp as the Persona plugin icon tile).
    Gradient {
        id: accentGrad
        GradientStop { position: 0.0; color: "#F28E6B" }
        GradientStop { position: 1.0; color: "#E1613A" }
    }

    // Small pill ghost-button for inline actions (copy, trust, links).
    component MiniButton: Control {
        id: mb
        property string label: ""
        property string tip: ""
        property bool active: false
        signal clicked
        hoverEnabled: true
        implicitHeight: 26
        implicitWidth: mbLabel.implicitWidth + 20
        scale: mbMa.pressed ? 0.94 : 1.0
        Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
        Tip { text: mb.tip; visible: mb.hovered && mb.tip.length > 0 }
        background: Rectangle {
            radius: Theme.spacing.radiusPill
            color: mb.active ? Theme.colors.getColor(Theme.palette.primary, 0.13)
                             : mb.hovered ? Theme.palette.backgroundMuted : "transparent"
            border.width: 1
            border.color: mb.active ? Theme.colors.getColor(Theme.palette.primary, 0.45)
                                    : mb.hovered ? Theme.palette.overlayOrange : Theme.palette.borderSubtle
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }
        }
        contentItem: LogosText {
            id: mbLabel
            text: mb.label
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: 11
            font.weight: Theme.typography.weightMedium
            color: mb.active ? Theme.palette.primary
                             : mb.hovered ? Theme.palette.text : Theme.palette.textSecondary
            Behavior on color { ColorAnimation { duration: 120 } }
        }
        MouseArea {
            id: mbMa
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: mb.clicked()
        }
    }

    // Status dot with a soft halo; pulses while something is in flight.
    component StatusDot: Item {
        id: sdot
        property color c: Theme.palette.textTertiary
        property bool pulsing: false
        implicitWidth: 16
        implicitHeight: 16
        onPulsingChanged: if (!pulsing) halo.opacity = 1
        Rectangle {
            id: halo
            anchors.fill: parent
            radius: width / 2
            color: Theme.colors.getColor(sdot.c, 0.22)
            SequentialAnimation on opacity {
                running: sdot.pulsing
                loops: Animation.Infinite
                NumberAnimation { from: 1; to: 0.25; duration: 700; easing.type: Easing.InOutQuad }
                NumberAnimation { from: 0.25; to: 1; duration: 700; easing.type: Easing.InOutQuad }
            }
        }
        Rectangle {
            anchors.centerIn: parent
            width: 8; height: 8; radius: 4
            color: sdot.c
        }
    }

    // Monospace text for fingerprints and topics.
    component Mono: LogosText {
        font.family: "Menlo"
        font.pixelSize: Theme.typography.secondaryText
        color: Theme.palette.text
    }

    component Hairline: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Theme.palette.borderHairline
    }

    // Fixed-width form label so all input rows align.
    component FormLabel: LogosText {
        Layout.preferredWidth: 74
        color: Theme.palette.textSecondary
        font.pixelSize: Theme.typography.secondaryText
    }

    // LogosToolTip tuned for multi-line hints: wraps at ~320px, no timeout.
    component Tip: LogosToolTip {
        id: tipRoot
        timeout: -1
        delay: 150
        placement: LogosToolTip.Top
        width: Math.min(implicitWidth, 320)
        height: labelItem.implicitHeight + verticalPadding * 2 + 4
        horizontalPadding: Theme.spacing.small
        verticalPadding: Theme.spacing.tiny
        Component.onCompleted: labelItem.wrapMode = Text.Wrap
    }

    // Tiny circled "i" that reveals a tooltip on hover.
    component InfoTip: Item {
        id: itip
        property string tip: ""
        implicitWidth: 16
        implicitHeight: 16
        visible: tip.length > 0
        HoverHandler { id: itipHover }
        Rectangle {
            anchors.fill: parent
            radius: 8
            color: itipHover.hovered ? Theme.colors.getColor(Theme.palette.primary, 0.16) : "transparent"
            border.width: 1
            border.color: itipHover.hovered ? Theme.palette.primary : Theme.palette.borderStrong
            Behavior on border.color { ColorAnimation { duration: 120 } }
            LogosText {
                anchors.centerIn: parent
                text: "i"
                font.pixelSize: 10
                font.weight: Theme.typography.weightBold
                color: itipHover.hovered ? Theme.palette.primary : Theme.palette.textTertiary
            }
        }
        Tip { text: itip.tip; visible: itipHover.hovered }
    }

    // Small tinted capsule chip (e.g. price, balance).
    component Chip: Rectangle {
        id: chip
        property string label: ""
        property color tint: Theme.palette.primary
        property string tip: ""
        radius: Theme.spacing.radiusPill
        color: Theme.colors.getColor(chip.tint, 0.13)
        border.width: 1
        border.color: Theme.colors.getColor(chip.tint, 0.45)
        implicitHeight: 24
        implicitWidth: chipLabel.implicitWidth + 20
        HoverHandler { id: chipHover }
        Tip { text: chip.tip; visible: chipHover.hovered && chip.tip.length > 0 }
        LogosText {
            id: chipLabel
            anchors.centerIn: parent
            text: chip.label
            font.pixelSize: 11
            font.weight: Theme.typography.weightMedium
            color: chip.tint
        }
    }

    // Status capsule — halo dot + label in an inset pill.
    component StatusPill: Rectangle {
        id: spill
        property color c: Theme.palette.success
        property bool pulsing: false
        property string label: ""
        property string tip: ""
        HoverHandler { id: spillHover }
        Tip { text: spill.tip; visible: spillHover.hovered && spill.tip.length > 0 }
        radius: Theme.spacing.radiusPill
        color: Theme.palette.backgroundInset
        border.width: 1
        border.color: Theme.palette.borderHairline
        implicitHeight: 30
        implicitWidth: spillRow.implicitWidth + 24
        RowLayout {
            id: spillRow
            anchors.centerIn: parent
            spacing: 6
            StatusDot { c: spill.c; pulsing: spill.pulsing }
            LogosText {
                text: spill.label
                font.pixelSize: Theme.typography.secondaryText
                font.weight: Theme.typography.weightMedium
                color: Theme.palette.text
            }
        }
    }

    // Round identicon avatar seeded by a provider fingerprint — a face for
    // each provider so rows read as "people", not hex.
    component ProviderAvatar: Item {
        id: avat
        property string seed: ""
        implicitWidth: 28
        implicitHeight: 28
        onSeedChanged: avatCanvas.requestPaint()
        Canvas {
            id: avatCanvas
            anchors.fill: parent
            onPaint: {
                var c = getContext("2d");
                c.reset();
                var cellsAcross = 8;
                var scale = width / cellsAcross;
                var rs = [0, 0, 0, 0];
                var s = avat.seed;
                for (var i = 0; i < s.length; i++)
                    rs[i % 4] = ((rs[i % 4] << 5) - rs[i % 4]) + s.charCodeAt(i);
                function rnd() {
                    var t = rs[0] ^ (rs[0] << 11);
                    rs[0] = rs[1]; rs[1] = rs[2]; rs[2] = rs[3];
                    rs[3] = (rs[3] ^ (rs[3] >> 19) ^ t ^ (t >> 8));
                    return ((rs[3] >>> 0) / ((1 << 31) >>> 0));
                }
                function col() {
                    var h = rnd();
                    var sat = 0.4 + rnd() * 0.6;
                    var lig = 0.3 + (rnd() + rnd()) * 0.25;
                    return Qt.hsla(h, sat, lig, 1);
                }
                var main = col(), bg = col(), spot = col();
                var half = cellsAcross / 2;
                var rows = [];
                for (var y = 0; y < cellsAcross; y++) {
                    var row = [];
                    for (var x = 0; x < half; x++)
                        row.push(Math.floor(rnd() * 2.3));
                    rows.push(row.concat(row.slice().reverse()));
                }
                c.beginPath();
                c.arc(width / 2, height / 2, width / 2, 0, Math.PI * 2);
                c.clip();
                c.fillStyle = bg;
                c.fillRect(0, 0, width, height);
                for (var yy = 0; yy < cellsAcross; yy++)
                    for (var xx = 0; xx < cellsAcross; xx++) {
                        var v = rows[yy][xx];
                        if (v > 0) {
                            c.fillStyle = (v === 1) ? main : spot;
                            c.fillRect(xx * scale, yy * scale, scale + 0.5, scale + 0.5);
                        }
                    }
            }
        }
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: Theme.palette.borderHairline
        }
    }

    // Tinted, plain-language notice.
    component NoticeBanner: Rectangle {
        id: nb
        property color tint: Theme.palette.info
        property string text: ""
        Layout.fillWidth: true
        color: Theme.colors.getColor(nb.tint, 0.10)
        border.color: Theme.colors.getColor(nb.tint, 0.40)
        border.width: 1
        radius: Theme.spacing.radiusMedium
        implicitHeight: nbText.implicitHeight + Theme.spacing.medium * 2
        LogosText {
            id: nbText
            anchors {
                left: parent.left; right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: Theme.spacing.medium; rightMargin: Theme.spacing.medium
            }
            text: nb.text
            wrapMode: Text.Wrap
            color: Theme.palette.text
            font.pixelSize: Theme.typography.secondaryText
        }
    }

    // Label ▸ value row for the Advanced sheet; copyKey adds a Copy button.
    component InfoRow: RowLayout {
        property string k: ""
        property string v: ""
        property string copyKey: ""
        Layout.fillWidth: true
        spacing: Theme.spacing.medium
        LogosText {
            Layout.preferredWidth: 118
            text: k
            color: Theme.palette.textTertiary
            font.pixelSize: 10
            font.weight: Theme.typography.weightMedium
            font.letterSpacing: 0.8
            font.capitalization: Font.AllUppercase
        }
        Mono {
            Layout.fillWidth: true
            text: v.length ? v : "—"
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
        }
        MiniButton {
            visible: copyKey.length > 0
            label: root.copied === copyKey ? "✓ Copied" : "Copy"
            onClicked: root.copy(v, copyKey)
        }
    }

    // Labelled pill switch for the Advanced toggles.
    component ToggleRow: RowLayout {
        id: trow
        property string label: ""
        property string tip: ""
        property bool checked: false
        signal toggled(bool on)
        Layout.fillWidth: true
        spacing: Theme.spacing.small
        LogosText {
            Layout.fillWidth: true
            text: trow.label
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
        }
        InfoTip { tip: trow.tip }
        Rectangle {
            implicitWidth: 40
            implicitHeight: 22
            radius: 11
            color: trow.checked ? Theme.colors.getColor(Theme.palette.primary, 0.55)
                                : Theme.palette.backgroundMuted
            border.width: 1
            border.color: trow.checked ? Theme.palette.primary : Theme.palette.border
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
                width: 16; height: 16; radius: 8
                anchors.verticalCenter: parent.verticalCenter
                x: trow.checked ? parent.width - width - 3 : 3
                color: trow.checked ? "#FFFFFF" : Theme.palette.textTertiary
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: trow.toggled(!trow.checked)
            }
        }
    }

    // ── Layout ───────────────────────────────────────────────────────
    ColumnLayout {
        anchors {
            top: parent.top
            bottom: parent.bottom
            topMargin: Theme.spacing.xlarge
            bottomMargin: Theme.spacing.xlarge
            horizontalCenter: parent.horizontalCenter
        }
        width: Math.min(root.width - Theme.spacing.xlarge * 2, 1080)
        spacing: Theme.spacing.large

        // Header — plugin logo, name, wallet chip, network status
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacing.medium
            Image {
                source: "icons/inference.png"
                Layout.preferredWidth: 32
                Layout.preferredHeight: 32
                sourceSize: Qt.size(128, 128)
                smooth: true
            }
            LogosText {
                text: "Xenia"
                color: Theme.palette.text
                font.pixelSize: Theme.typography.subtitleText
                font.weight: Theme.typography.weightBold
            }
            Item { Layout.fillWidth: true }
            Chip {
                visible: root.walletOpen
                label: "🔒 " + root.walletPrivBal + " private"
                tint: Theme.palette.success
                tip: "Your shielded Persona balance — paid prompts are settled from here without revealing who you are. Click for details."
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: walletOverlay.open()
                }
            }
            Chip {
                visible: !root.walletOpen && root.identityInit
                label: root.walletBusy ? "Wallet opening…"
                       : !root.walletLoaded ? "Wallet unavailable"
                       : root.walletHasWallet ? "Wallet closed" : "Set up payments"
                tint: Theme.palette.warning
                tip: "Paid providers are settled through your Persona wallet. Click to connect it — free providers work without it."
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: walletOverlay.open()
                }
            }
            StatusPill {
                c: statusColor(root.deliveryStatus)
                pulsing: root.deliveryStatus === 1
                label: statusText(root.deliveryStatus)
                tip: root.deliveryStatus === 2
                     ? "Connected to the Logos delivery network. Prompts are end-to-end encrypted to the provider that answers."
                     : "The app connects to the Logos network automatically when it opens."
            }
            // TEMP: preview the first-run setup without touching the account.
            MiniButton {
                label: "Preview setup"
                tip: "Walk through the first-run onboarding with a dummy phrase (nothing is created or changed)."
                onClicked: root.onbPreviewStart()
            }
        }

        // ── Providers ────────────────────────────────────────────────
        Card {
            visible: root.identityInit
            title: "Providers"
            tip: "Everyone currently offering to run models for you, discovered live from the network. Click a provider to always use it; click again to let the app pick."
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small

                // Model picker: only models someone actually serves right now.
                // A RowLayout cannot wrap, so a busy marketplace used to push
                // chips off-screen with no way to reach them. Header row carries
                // the count plus a search box; the chips themselves live in a
                // Flow so they wrap, and are capped so the row stays bounded.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    LogosText {
                        text: liveProviders() > 0
                              ? liveProviders() + " online"
                              : "Searching…"
                        color: liveProviders() > 0 ? Theme.palette.success : Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                        font.weight: Theme.typography.weightMedium
                    }
                    LogosText {
                        visible: root.modelsCache.length > 0
                        text: "· " + root.modelsCache.length + " model" + (root.modelsCache.length === 1 ? "" : "s")
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                    Item { Layout.fillWidth: true }
                    LogosTextField {
                        id: modelSearchField
                        visible: root.modelsCache.length > root.modelChipCap
                        Layout.preferredWidth: 180
                        placeholderText: "Search models…"
                        onTextChanged: root.modelSearch = text
                    }
                    MiniButton {
                        visible: root.modelSearch.length > 0
                        label: "Clear"
                        onClicked: { modelSearchField.text = ""; root.modelSearch = "" }
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    MiniButton {
                        label: "Any model"
                        active: root.modelFilter === ""
                        onClicked: setModel("")
                    }
                    Repeater {
                        model: root.shownModels()
                        MiniButton {
                            required property var modelData
                            label: modelData
                            active: root.modelFilter === modelData
                            onClicked: setModel(modelData)
                        }
                    }
                    // Never silently truncate — say how many are not shown.
                    MiniButton {
                        property int extra: root.matchingModelCount() - root.shownModels().length
                        visible: extra > 0
                        label: "+" + extra + " more — search"
                        tip: "Too many models to show at once. Type in the search box to narrow the list."
                        onClicked: modelSearchField.forceActiveFocus()
                    }
                    // The active filter may be scrolled out of the capped set;
                    // keep it visible so it can always be switched off.
                    MiniButton {
                        visible: root.modelFilter !== "" && root.shownModels().indexOf(root.modelFilter) === -1
                        label: root.modelFilter + " ✕"
                        active: true
                        tip: "Currently filtering by this model. Click to clear."
                        onClicked: setModel("")
                    }
                }

                // Empty roster: friendly scan state instead of a bare list.
                RowLayout {
                    visible: root.providers.length === 0
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosSpinner { running: parent.visible; implicitWidth: 18; implicitHeight: 18; thickness: 2 }
                    LogosText {
                        Layout.fillWidth: true
                        text: root.deliveryStatus === 2
                              ? "Listening for providers on the network — they announce every ~30 seconds…"
                              : "Connecting to the network…"
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                        wrapMode: Text.Wrap
                    }
                }

                // A Repeater in a ColumnLayout instantiated every provider and
                // grew without bound, pushing the chat pane off a page that does
                // not scroll. A ListView virtualizes the delegates and caps its
                // own height, so the roster scrolls inside the card instead.
                ListView {
                    id: provList
                    visible: root.providers.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 6 * (44 + Theme.spacing.tiny))
                    clip: true
                    spacing: Theme.spacing.tiny
                    model: root.providers
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {
                        policy: provList.contentHeight > provList.height ? ScrollBar.AsNeeded
                                                                         : ScrollBar.AlwaysOff
                    }
                    delegate: Rectangle {
                            required property var modelData
                            property bool pinned: modelData.id === root.preferredProvider
                            property bool eligible: modelData.live
                                                    && providerServes(modelData, root.modelFilter)
                                                    && (!root.trustedOnly || modelData.trusted)
                            width: provList.width
                            height: 44
                            radius: Theme.spacing.radiusMedium
                            opacity: eligible ? 1.0 : 0.45
                            color: pinned ? Theme.colors.getColor(Theme.palette.primary, 0.10)
                                   : (pRow.containsMouse && eligible ? Theme.palette.backgroundMuted : "transparent")
                            border.width: 1
                            border.color: pinned ? Theme.colors.getColor(Theme.palette.primary, 0.45) : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }

                            RowLayout {
                                anchors {
                                    left: parent.left; right: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: Theme.spacing.small; rightMargin: Theme.spacing.small
                                }
                                spacing: Theme.spacing.small
                                StatusDot {
                                    c: modelData.live ? Theme.palette.success : Theme.palette.textTertiary
                                }
                                ProviderAvatar { seed: modelData.id }
                                ColumnLayout {
                                    spacing: 1
                                    RowLayout {
                                        spacing: Theme.spacing.tiny
                                        Mono {
                                            text: modelData.id.substring(0, 12) + "…"
                                            font.pixelSize: 12
                                        }
                                        LogosText {
                                            visible: pinned
                                            text: "PINNED"
                                            color: Theme.palette.primary
                                            font.pixelSize: 9
                                            font.weight: Theme.typography.weightBold
                                            font.letterSpacing: 0.8
                                        }
                                    }
                                    LogosText {
                                        text: providerModels(modelData)
                                              + (!modelData.live
                                                 ? " · last heard " + Math.floor(modelData.ageMs / 1000) + "s ago"
                                                 : (!eligible && root.modelFilter && !providerServes(modelData, root.modelFilter)
                                                    ? " · doesn't serve " + root.modelFilter : ""))
                                        color: Theme.palette.textTertiary
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                }
                                Item { Layout.fillWidth: true }
                                // Integrity: did a canary audit confirm the advertised
                                // model? Click to (re)run the check.
                                Chip {
                                    visible: modelData.integrity === "verified"
                                             || modelData.integrity === "failed"
                                             || modelData.integrity === "mixed"
                                    label: modelData.integrity === "verified" ? "✓ Verified"
                                           : modelData.integrity === "mixed" ? "⚠ Mixed" : "✗ Flagged"
                                    tint: modelData.integrity === "verified" ? Theme.palette.success
                                          : modelData.integrity === "mixed" ? Theme.palette.warning
                                          : Theme.palette.error
                                    tip: modelData.integrity === "verified"
                                         ? "A spot-check confirmed this provider runs the model it advertises. Click to re-check."
                                         : "A spot-check suggests this provider may substitute a weaker model. Click to re-check."
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { callInf("auditProvider", [modelData.id]); refresh() }
                                    }
                                }
                                // My own experience with this provider (answers vs timeouts).
                                LogosText {
                                    visible: (modelData.hits || 0) + (modelData.misses || 0) > 0
                                    text: Math.round((modelData.score || 0.5) * 100) + "%"
                                    font.pixelSize: 11
                                    font.weight: Theme.typography.weightMedium
                                    color: (modelData.score || 0.5) >= 0.75 ? Theme.palette.success
                                           : (modelData.score || 0.5) >= 0.5 ? Theme.palette.warning
                                           : Theme.palette.error
                                    HoverHandler { id: scoreHover }
                                    Tip {
                                        text: "How reliably this provider has answered you so far."
                                        visible: scoreHover.hovered
                                    }
                                }
                                Chip {
                                    visible: modelData.cap > 0 && modelData.load >= modelData.cap
                                    label: "Busy"
                                    tint: Theme.palette.error
                                    tip: "At capacity right now — prompts may wait."
                                }
                                Chip {
                                    label: priceLabel(modelData)
                                    tint: isPaid(modelData) ? Theme.palette.info : Theme.palette.success
                                    tip: isPaid(modelData)
                                         ? "Paid privately from your Persona wallet — a small prepay opens a session of prompts."
                                         : "This provider answers for free."
                                }
                                MiniButton {
                                    label: modelData.trusted ? "🛡 Trusted" : "Trust"
                                    active: modelData.trusted === true
                                    tip: modelData.trusted
                                         ? "On your trusted list. Click to remove."
                                         : "Add to your trusted list. With “Only trusted providers” on (Advanced), prompts go nowhere else."
                                    onClicked: {
                                        callInf("setTrusted", [modelData.id, !modelData.trusted])
                                        refresh()
                                    }
                                }
                            }
                            MouseArea {
                                id: pRow
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: eligible
                                cursorShape: eligible ? Qt.PointingHandCursor : Qt.ArrowCursor
                                // Row click pins; the chips above sit on top and win.
                                z: -1
                                onClicked: {
                                    const fp = pinned ? "" : modelData.id
                                    callInf("setPreferredProvider", [fp])
                                    refreshIdentity()
                                }
                            }
                        }
                }

                // Roster overflow hint — the list scrolls, so say so.
                LogosText {
                    visible: root.providers.length > 6
                    Layout.fillWidth: true
                    text: "Showing 6 of " + root.providers.length + " providers — scroll the list for the rest."
                    color: Theme.palette.textTertiary
                    font.pixelSize: 11
                }
            }
        }

        // Gentle nudge: paid providers are visible but the wallet isn't ready.
        Rectangle {
            visible: root.identityInit && !root.walletOpen && anyPaidLive()
            Layout.fillWidth: true
            color: Theme.colors.getColor(Theme.palette.info, 0.10)
            border.color: Theme.colors.getColor(Theme.palette.info, 0.40)
            border.width: 1
            radius: Theme.spacing.radiusMedium
            implicitHeight: nudgeRow.implicitHeight + Theme.spacing.medium * 2
            RowLayout {
                id: nudgeRow
                anchors {
                    left: parent.left; right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Theme.spacing.medium; rightMargin: Theme.spacing.medium
                }
                spacing: Theme.spacing.medium
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.secondaryText
                    text: "Some of these providers are paid. Connect your Persona wallet once and they'll be settled privately, straight from your shielded balance."
                }
                ActionButton {
                    text: "Connect wallet"
                    onClicked: walletOverlay.open()
                }
            }
        }

        // ── Payment status pills — the paid flow stays legible ───────
        Repeater {
            model: root.paySessions
            NoticeBanner {
                required property var modelData
                tint: modelData.ready ? Theme.palette.success : Theme.palette.warning
                text: {
                    var fp = String(modelData.provider).substring(0, 10) + "…"
                    if (!modelData.ready) {
                        var st = root.payStartTick[modelData.provider]
                        var el = (st !== undefined) ? Math.max(0, root.payTick - st) : 0
                        return "🔐 Paying " + fp + " privately — proving the payment ("
                               + clock(el) + " elapsed, about a minute)"
                               + (modelData.waiting > 0 ? ". " + modelData.waiting + " prompt(s) will send once it settles." : ".")
                    }
                    var left = Math.max(0, (modelData.quota || 0) - (modelData.used || 0))
                    return "💳 Session with " + fp + " active — " + left + " of "
                           + (modelData.quota || 0) + " prepaid prompts left."
                }
            }
        }

        // ── Conversation ─────────────────────────────────────────────
        Card {
            visible: root.identityInit
            Layout.fillHeight: true
            implicitHeight: 0   // let fillHeight own the size
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Theme.spacing.small

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    Rectangle { implicitWidth: 4; implicitHeight: 12; radius: 2; color: Theme.palette.primary }
                    LogosText {
                        text: "Conversation"
                        color: Theme.palette.textSecondary
                        font.pixelSize: 11
                        font.weight: Theme.typography.weightMedium
                        font.letterSpacing: 0.8
                        font.capitalization: Font.AllUppercase
                    }
                    Item { Layout.fillWidth: true }
                    MiniButton {
                        visible: root.exchanges.length > 0
                        label: "Clear"
                        tip: "Remove the conversation from this screen. Nothing is stored on the network."
                        onClicked: { callInf("clearExchanges", []); refresh() }
                    }
                }

                ListView {
                    id: chatList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: Theme.spacing.medium
                    // Backend list is newest-first; laying out bottom-to-top puts
                    // the newest at the bottom — the chat idiom — with the view
                    // anchored there as answers stream in.
                    verticalLayoutDirection: ListView.BottomToTop
                    model: root.exchanges
                    delegate: ColumnLayout {
                        required property var modelData
                        width: chatList.width
                        spacing: Theme.spacing.tiny

                        // You — right-aligned coral bubble
                        RowLayout {
                            Layout.fillWidth: true
                            Item { Layout.fillWidth: true }
                            Rectangle {
                                radius: Theme.spacing.radiusLarge
                                color: Theme.colors.getColor(Theme.palette.primary, 0.13)
                                border.width: 1
                                border.color: Theme.colors.getColor(Theme.palette.primary, 0.35)
                                implicitWidth: Math.min(promptText.implicitWidth + Theme.spacing.medium * 2,
                                                        chatList.width * 0.78)
                                implicitHeight: promptText.implicitHeight + Theme.spacing.medium * 2
                                LogosText {
                                    id: promptText
                                    anchors { fill: parent; margins: Theme.spacing.medium }
                                    text: modelData.prompt
                                    wrapMode: Text.Wrap
                                    color: Theme.palette.text
                                    font.pixelSize: Theme.typography.primaryText
                                }
                            }
                        }

                        // The model — left-aligned charcoal bubble
                        RowLayout {
                            Layout.fillWidth: true
                            Rectangle {
                                radius: Theme.spacing.radiusLarge
                                color: modelData.failed
                                       ? Theme.colors.getColor(Theme.palette.error, 0.08)
                                       : Theme.palette.backgroundSecondary
                                border.width: 1
                                border.color: modelData.failed
                                              ? Theme.colors.getColor(Theme.palette.error, 0.40)
                                              : Theme.palette.borderSubtle
                                implicitWidth: Math.min(Math.max(answerCol.implicitWidth + Theme.spacing.medium * 2, 120),
                                                        chatList.width * 0.78)
                                implicitHeight: answerCol.implicitHeight + Theme.spacing.medium * 2
                                ColumnLayout {
                                    id: answerCol
                                    anchors { fill: parent; margins: Theme.spacing.medium }
                                    spacing: Theme.spacing.tiny
                                    RowLayout {
                                        visible: !modelData.answered && !modelData.failed
                                        spacing: Theme.spacing.small
                                        LogosSpinner { running: parent.visible; implicitWidth: 16; implicitHeight: 16; thickness: 2 }
                                        LogosText {
                                            text: modelData.paying
                                                  ? "Securing your payment… " + Math.floor(modelData.ageMs / 1000) + "s (about a minute)"
                                                  : "Thinking… " + Math.floor(modelData.ageMs / 1000) + "s"
                                                    + (modelData.retries > 0 ? " · retry " + modelData.retries : "")
                                            color: Theme.palette.textSecondary
                                            font.pixelSize: Theme.typography.secondaryText
                                        }
                                    }
                                    LogosText {
                                        visible: modelData.answered || modelData.failed
                                        Layout.fillWidth: true
                                        wrapMode: Text.Wrap
                                        textFormat: Text.PlainText
                                        color: modelData.failed ? Theme.palette.error : Theme.palette.text
                                        font.pixelSize: Theme.typography.primaryText
                                        text: modelData.failed
                                              ? (modelData.reason && modelData.reason.length > 0
                                                 ? modelData.reason
                                                 : "No provider answered — try again, or pick a different provider.")
                                              : (modelData.text && modelData.text.length > 0
                                                 ? modelData.text : "(empty response)")
                                    }
                                    LogosText {
                                        visible: modelData.answered
                                        text: (modelData.sealed ? "🔒 Encrypted · " : "")
                                              + (modelData.model || "model")
                                              + " · " + String(modelData.provider || "?").substring(0, 10) + "…"
                                              + " · " + modelData.rttMs + " ms"
                                        color: Theme.palette.textTertiary
                                        font.pixelSize: 10
                                    }
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                    }

                    // Empty state — an invitation, not a void.
                    ColumnLayout {
                        anchors.centerIn: parent
                        visible: root.exchanges.length === 0
                        width: Math.min(parent.width - 80, 420)
                        spacing: Theme.spacing.small
                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter
                            implicitWidth: 56; implicitHeight: 56; radius: 28
                            color: Theme.colors.getColor(Theme.palette.primary, 0.12)
                            border.width: 1
                            border.color: Theme.colors.getColor(Theme.palette.primary, 0.35)
                            LogosText {
                                anchors.centerIn: parent
                                text: "✦"
                                font.pixelSize: 22
                                color: Theme.palette.primary
                            }
                        }
                        LogosText {
                            Layout.alignment: Qt.AlignHCenter
                            text: "Ask anything"
                            color: Theme.palette.text
                            font.pixelSize: 17
                            font.weight: Theme.typography.weightBold
                        }
                        LogosText {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            text: "Your question travels encrypted to a provider on the Logos "
                                + "network and the answer comes straight back to you."
                            color: Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }
                }

                // Composer
                Rectangle {
                    Layout.fillWidth: true
                    radius: Theme.spacing.radiusLarge
                    color: Theme.palette.backgroundInset
                    border.width: 1
                    border.color: promptField.activeFocus
                                  ? Theme.colors.getColor(Theme.palette.primary, 0.55)
                                  : Theme.palette.borderHairline
                    Behavior on border.color { ColorAnimation { duration: 120 } }
                    implicitHeight: composerRow.implicitHeight + Theme.spacing.small * 2
                    RowLayout {
                        id: composerRow
                        anchors {
                            left: parent.left; right: parent.right
                            verticalCenter: parent.verticalCenter
                            leftMargin: Theme.spacing.medium; rightMargin: Theme.spacing.small
                        }
                        spacing: Theme.spacing.small
                        TextArea {
                            id: promptField
                            Layout.fillWidth: true
                            Layout.maximumHeight: 120
                            placeholderText: "Ask anything…"
                            placeholderTextColor: Theme.palette.textTertiary
                            wrapMode: TextArea.Wrap
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.primaryText
                            selectByMouse: true
                            background: null
                            // Enter sends (the chat idiom); Shift+Enter makes a new line.
                            Keys.onPressed: (e) => {
                                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter)
                                    && !(e.modifiers & Qt.ShiftModifier)) {
                                    send(); e.accepted = true
                                }
                            }
                        }
                        ActionButton {
                            Layout.alignment: Qt.AlignBottom
                            text: "Send"
                            accent: true
                            enabled: root.deliveryStatus === 2 && promptField.text.trim().length > 0
                            tip: root.deliveryStatus === 2 ? "" : "Waiting for the network connection…"
                            onClicked: send()
                        }
                    }
                }

                // Where will my next prompt go? One quiet sentence.
                LogosText {
                    Layout.fillWidth: true
                    text: routingSummary()
                    color: eligibleProviders() > 0 || root.preferredProvider.length > 0
                           ? Theme.palette.textTertiary : Theme.palette.warning
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
        }

        // ── Advanced — the plumbing, out of the way but reachable ────
        RowLayout {
            visible: root.identityInit
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            MiniButton {
                label: root.advancedOpen ? "Hide advanced" : "Advanced"
                onClicked: root.advancedOpen = !root.advancedOpen
            }
        }

        Card {
            visible: root.identityInit && root.advancedOpen
            title: "Advanced"
            tip: "Network plumbing and safety controls. The defaults are right for almost everyone."
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.medium

                ToggleRow {
                    label: "Only talk to encrypted providers"
                    tip: "Refuse the plaintext fallback: if no verified provider is known, prompts wait instead of going out unencrypted."
                    checked: root.requireEncryption
                    onToggled: (on) => { callInf("setRequireEncryption", [on]); refreshIdentity() }
                }
                ToggleRow {
                    label: "Only use trusted providers (" + root.trustedCount + " trusted)"
                    tip: "Prompts only ever go to providers you've explicitly trusted in the list above."
                    checked: root.trustedOnly
                    onToggled: (on) => { callInf("setTrustedOnly", [on]); refreshIdentity() }
                }
                Hairline {}
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosText {
                        text: "Room"
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                        Layout.preferredWidth: 118
                    }
                    LogosTextField {
                        id: roomField
                        Layout.fillWidth: true
                        placeholderText: root.currentRoom
                    }
                    ActionButton {
                        text: "Join"
                        enabled: roomField.text.trim().length > 0
                                 && roomField.text.trim() !== root.currentRoom
                        onClicked: { callInf("joinRoom", [roomField.text.trim()]); refresh() }
                    }
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.textTertiary
                    font.pixelSize: 11
                    text: "Most providers are found automatically. Rooms are shared channels — join the same room as a provider to talk to it directly."
                }
                Hairline {}
                InfoRow { k: "Identity"; v: root.identityFp; copyKey: "fp" }
                InfoRow { k: "Key backend"; v: root.identityBackend }
                InfoRow { k: "Session id"; v: root.myId }
                InfoRow { k: "Room topic"; v: topicFor(root.currentRoom); copyKey: "topic" }
                Hairline {}
                RowLayout {
                    Layout.fillWidth: true
                    LogosText {
                        Layout.fillWidth: true
                        text: "Network connection"
                        color: Theme.palette.textSecondary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                    MiniButton {
                        label: root.deliveryStatus === 0 ? "Connect" : "Disconnect"
                        onClicked: {
                            if (root.deliveryStatus === 0) callInf("startDelivery", [])
                            else                           callInf("stopDelivery", [])
                            refresh()
                        }
                    }
                }
            }
        }
    }

    // ── First-run onboarding: create-with-seed, restore, or unlock ───
    // Full-screen gate shown until an identity exists and is unlocked —
    // the same carousel drill as Persona's wallet setup.
    Rectangle {
        id: onbOverlay
        visible: root.onbActive
        anchors.fill: parent
        z: 200
        color: Theme.palette.background
        MouseArea { anchors.fill: parent; hoverEnabled: true }
        // faint brand wash from the top
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Theme.colors.getColor(Theme.palette.primary, 0.06) }
                GradientStop { position: 0.5; color: "transparent" }
            }
        }
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacing.xlarge * 2, 560)
            spacing: Theme.spacing.large
            opacity: onbOverlay.visible ? 1 : 0
            scale: onbOverlay.visible ? 1 : 0.98
            Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

            // Brand header — every step
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: Theme.spacing.medium
                Image {
                    source: "icons/inference.png"
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    sourceSize: Qt.size(128, 128)
                    smooth: true
                }
                LogosText {
                    text: "Xenia"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.panelTitleText
                    font.weight: Theme.typography.weightBold
                }
                MiniButton {
                    visible: root.onbPreview
                    label: "Exit preview"
                    onClicked: root.onbFinish()
                }
            }

            // Step dots — fixed under the header so they never move as the
            // card height changes per step.
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Theme.spacing.tiny
                spacing: Theme.spacing.small
                visible: !root.identityLocked && root.onbStep <= 2
                Repeater {
                    model: 3
                    delegate: Rectangle {
                        implicitWidth: root.onbStep === index ? 22 : 8
                        implicitHeight: 8
                        radius: 4
                        color: root.onbStep === index ? Theme.palette.primary : Theme.palette.borderSubtle
                        Behavior on implicitWidth { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
            }

            // ── Locked key file → unlock (replaces the carousel) ─────
            Card {
                visible: root.identityLocked
                glow: true
                LogosText {
                    text: "Welcome back"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.primaryText
                    text: "Your account key is protected with a passphrase. Unlock it to start asking."
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    LogosTextField {
                        id: unlockField
                        Layout.fillWidth: true
                        echoMode: TextInput.Password
                        placeholderText: "Passphrase"
                        Keys.onReturnPressed: unlockIdentity()
                    }
                    ActionButton {
                        text: "Unlock"
                        accent: true
                        enabled: unlockField.text.length > 0
                        onClicked: unlockIdentity()
                    }
                }
                LogosText {
                    visible: root.onbError.length > 0
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: root.onbError
                    color: Theme.palette.error
                    font.pixelSize: Theme.typography.secondaryText
                }
            }

            // ── Create-flow carousel: welcome → phrase → confirm ─────
            SwipeView {
                id: onbSwipe
                visible: !root.identityLocked && root.onbStep <= 2
                Layout.fillWidth: true
                // Fixed to the recovery-phrase step (the tallest); a constant
                // height keeps the centered block and the dots from shifting.
                Layout.preferredHeight: 470
                currentIndex: Math.min(root.onbStep, 2)
                interactive: false
                clip: true
                onCurrentIndexChanged: if (currentIndex === 2) { vfA.text = ""; vfB.text = ""; vfC.text = "" }

                // Step 0 — welcome
                Item {
                    implicitHeight: card0.implicitHeight
                    Card {
                        id: card0
                        anchors.fill: parent
                        glow: true
                        Item { Layout.fillHeight: true }
                        LogosText {
                            text: "Your private AI, on your terms"
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.subtitleText
                            font.weight: Theme.typography.weightBold
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.primaryText
                            text: "Ask any model offered on the Logos network — your account keys keep every question yours alone."
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: Theme.spacing.tiny
                            Layout.bottomMargin: Theme.spacing.tiny
                            spacing: Theme.spacing.medium
                            Repeater {
                                model: [
                                    "Prompts travel end-to-end encrypted — only the provider that answers can read them.",
                                    "Providers compete for your prompts; the app picks the best one, or you pin a favourite.",
                                    "Paid models settle privately through your Persona wallet — nobody learns who is asking."
                                ]
                                delegate: RowLayout {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    spacing: Theme.spacing.small
                                    Rectangle {
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: 7
                                        implicitWidth: 6
                                        implicitHeight: 6
                                        radius: 3
                                        color: Theme.palette.primary
                                    }
                                    LogosText {
                                        Layout.fillWidth: true
                                        text: parent.modelData
                                        color: Theme.palette.textSecondary
                                        font.pixelSize: Theme.typography.secondaryText
                                        wrapMode: Text.Wrap
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.medium
                            ActionButton {
                                accent: true
                                // If an account was already created this session (came
                                // back from the phrase step), re-show it instead of
                                // re-creating — never strands the user without their seed.
                                text: root.freshMnemonic.length > 0 ? "Resume setup" : "Create my account"
                                onClicked: root.onbPreview ? root.onbPreviewSeed()
                                           : root.freshMnemonic.length > 0 ? (root.onbStep = 1)
                                           : createIdentity()
                            }
                            ActionButton {
                                visible: root.freshMnemonic.length === 0
                                text: "I already have a recovery phrase"
                                onClicked: { root.onbError = ""; root.onbStep = 3 }
                            }
                            Item { Layout.fillWidth: true }
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                // Step 1 — the recovery phrase
                Item {
                    implicitHeight: card1.implicitHeight
                    Card {
                        id: card1
                        anchors.fill: parent
                        Item { Layout.fillHeight: true }
                        LogosText {
                            text: "Your recovery phrase"
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.subtitleText
                            font.weight: Theme.typography.weightBold
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            color: Theme.colors.getColor(Theme.palette.warning, 0.10)
                            border.color: Theme.colors.getColor(Theme.palette.warning, 0.45)
                            border.width: 1
                            radius: Theme.spacing.radiusMedium
                            implicitHeight: warnT.implicitHeight + Theme.spacing.medium * 2
                            LogosText {
                                id: warnT
                                anchors {
                                    left: parent.left; right: parent.right
                                    verticalCenter: parent.verticalCenter
                                    margins: Theme.spacing.medium
                                }
                                wrapMode: Text.Wrap
                                text: "⚠ The only way to recover your account. Write the words down in order, keep them offline, and never share them."
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                        Flow {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            Repeater {
                                model: root.freshMnemonic.trim().length > 0 ? root.freshMnemonic.trim().split(/\s+/) : []
                                delegate: Rectangle {
                                    radius: Theme.spacing.radiusMedium
                                    color: Theme.palette.backgroundTertiary
                                    border.width: 1
                                    border.color: Theme.palette.borderHairline
                                    implicitWidth: chipT.implicitWidth + 14
                                    implicitHeight: 27
                                    LogosText {
                                        id: chipT
                                        anchors.centerIn: parent
                                        text: index + 1 + ". " + modelData
                                        font.family: "Menlo"
                                        font.pixelSize: 11
                                        color: Theme.palette.text
                                    }
                                }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            ActionButton {
                                text: root.copied === "onbmn" ? "✓ Copied" : "Copy phrase"
                                onClicked: root.copy(root.freshMnemonic, "onbmn")
                            }
                            Item { Layout.fillWidth: true }
                        }
                        LogosCheckbox {
                            id: onbSavedBox
                            text: "I've written these words down and stored them safely"
                            onClicked: root.onbSaved = checked
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            ActionButton {
                                text: "Back"
                                onClicked: root.onbStep = 0
                            }
                            Item { Layout.fillWidth: true }
                            ActionButton {
                                accent: true
                                text: "Continue"
                                enabled: root.onbSaved
                                onClicked: root.onbToVerify()
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }
                }

                // Step 2 — confirm three words
                Item {
                    implicitHeight: card2.implicitHeight
                    Card {
                        id: card2
                        anchors.fill: parent
                        Item { Layout.fillHeight: true }
                        LogosText {
                            text: "Confirm your recovery phrase"
                            color: Theme.palette.text
                            font.pixelSize: Theme.typography.subtitleText
                            font.weight: Theme.typography.weightBold
                        }
                        LogosText {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            color: Theme.palette.textSecondary
                            font.pixelSize: Theme.typography.primaryText
                            text: "Type the missing words to confirm you saved them."
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel { text: "Word #" + (root.onbVerifyIdx.length > 0 ? root.onbVerifyIdx[0] + 1 : "") }
                            LogosTextField { id: vfA; Layout.fillWidth: true; placeholderText: "…" }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel { text: "Word #" + (root.onbVerifyIdx.length > 1 ? root.onbVerifyIdx[1] + 1 : "") }
                            LogosTextField { id: vfB; Layout.fillWidth: true; placeholderText: "…" }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            FormLabel { text: "Word #" + (root.onbVerifyIdx.length > 2 ? root.onbVerifyIdx[2] + 1 : "") }
                            LogosTextField { id: vfC; Layout.fillWidth: true; placeholderText: "…" }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.small
                            ActionButton {
                                text: "Back"
                                onClicked: root.onbStep = 1
                            }
                            Item { Layout.fillWidth: true }
                            ActionButton {
                                accent: true
                                text: "Finish setup"
                                enabled: root.onbPreview || root.onbVerifyOk([vfA.text, vfB.text, vfC.text])
                                onClicked: root.onbFinish()
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }
                }
            }

            // ── Restore — separate side-path (reached from welcome) ──
            Card {
                visible: !root.identityLocked && root.onbStep === 3
                LogosText {
                    text: "Restore your account"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.subtitleText
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: Theme.palette.textSecondary
                    font.pixelSize: Theme.typography.primaryText
                    text: "Enter your 12 or 24-word recovery phrase, separated by spaces."
                }
                LogosTextArea {
                    id: onbImportField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 96
                    placeholderText: "word one  word two  word three  …"
                }
                LogosText {
                    visible: root.onbError.length > 0
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: root.onbError
                    color: Theme.palette.error
                    font.pixelSize: Theme.typography.secondaryText
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.small
                    ActionButton {
                        text: "Back"
                        onClicked: { root.onbError = ""; root.onbStep = 0 }
                    }
                    Item { Layout.fillWidth: true }
                    ActionButton {
                        accent: true
                        text: "Restore account"
                        enabled: root.onbPreview
                                 || onbImportField.text.trim().split(/\s+/).length === 12
                                 || onbImportField.text.trim().split(/\s+/).length === 24
                        onClicked: root.onbPreview ? root.onbFinish() : importIdentity()
                    }
                }
            }
        }
    }

    // ── Wallet connection dialog ─────────────────────────────────────
    // One place to see and fix payment readiness: is Persona there, is the
    // wallet open, what can I spend — plus a faucet top-up on the testnet.
    Rectangle {
        id: walletOverlay
        function open() {
            root.walletMsg = ""
            refreshWallet()
            visible = true
        }
        visible: false
        anchors.fill: parent
        z: 100
        color: Qt.rgba(0, 0, 0, 0.62)
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: walletOverlay.visible = false
        }
        Card {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacing.xlarge * 2, 520)
            opacity: walletOverlay.visible ? 1 : 0
            scale: walletOverlay.visible ? 1 : 0.95
            Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            // keep clicks inside the card from dismissing the dialog
            MouseArea { anchors.fill: parent; onClicked: {} }
            title: "Persona wallet"

            LogosText {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.primaryText
                text: "Paid providers are settled from your shielded Persona balance. "
                    + "The payment carries no identity — a provider only ever sees that a credit arrived."
            }

            // Status at a glance
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                StatusDot {
                    c: root.walletOpen ? Theme.palette.success
                       : root.walletBusy ? Theme.palette.warning
                       : Theme.palette.textTertiary
                    pulsing: root.walletBusy
                }
                LogosText {
                    Layout.fillWidth: true
                    text: !root.walletLoaded ? "Persona isn't reachable"
                          : root.walletOpen ? "Connected — ready to pay"
                          : root.walletBusy ? "Opening your wallet…"
                          : root.walletHasWallet ? "Wallet found, currently closed"
                          : "No wallet yet"
                    color: Theme.palette.text
                    font.pixelSize: Theme.typography.primaryText
                    font.weight: Theme.typography.weightMedium
                }
                MiniButton {
                    label: "Refresh"
                    onClicked: refreshWallet()
                }
            }

            Hairline {}
            InfoRow { k: "Private balance"; v: root.walletOpen ? root.walletPrivBal + " (pays prompts)" : "—" }
            InfoRow { k: "Public balance"; v: root.walletOpen ? root.walletPubBal : "—" }
            Hairline {}

            // Plain-language guidance per state
            LogosText {
                visible: !root.walletLoaded
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                text: "The Persona wallet module isn't answering. Open the Persona app once, then come back — free providers keep working in the meantime."
            }
            LogosText {
                visible: root.walletLoaded && !root.walletHasWallet
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                text: "You don't have a wallet yet. Create one in the Persona app — it takes a minute and gives you a recovery phrase. This app will pick it up automatically."
            }
            LogosText {
                visible: root.walletOpen && Number(root.walletPrivBal) === 0
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: Theme.palette.textSecondary
                font.pixelSize: Theme.typography.secondaryText
                text: "Your private balance is empty. On the testnet you can add free tokens below; shielding them keeps your payments private."
            }

            LogosText {
                visible: root.walletMsg.length > 0
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: root.walletMsg
                color: root.walletMsg.indexOf("✓") !== -1 ? Theme.palette.success : Theme.palette.error
                font.pixelSize: Theme.typography.secondaryText
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.small
                ActionButton {
                    visible: root.walletOpen
                    text: root.walletBusy ? "Requesting…" : "Get free tokens"
                    enabled: !root.walletBusy
                    tip: "Testnet faucet — adds free tokens to your shielded balance so you can try paid providers."
                    onClicked: {
                        root.walletMsg = ""
                        root.walletBusy = true
                        callWallet("lezFund", [], null)
                    }
                }
                Item { Layout.fillWidth: true }
                ActionButton {
                    text: "Close"
                    onClicked: walletOverlay.visible = false
                }
                ActionButton {
                    visible: root.walletLoaded && root.walletHasWallet && !root.walletOpen
                    accent: true
                    text: root.walletBusy ? "Opening…" : "Open wallet"
                    enabled: !root.walletBusy
                    onClicked: {
                        root.walletMsg = ""
                        root.walletBusy = true
                        callWallet("lezOpen", [], null)
                    }
                }
            }
        }
    }

    // Live wallet results — Persona finishes slow operations via events, so
    // the dialog reacts the moment an open / faucet call lands.
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        function onModuleEventReceived(m, e, d) {
            if (m !== "persona_core") return
            var r
            try { r = JSON.parse(d[0]) } catch (x) { r = null }
            if (e === "lezOpenFinished") {
                root.walletBusy = false
                root.walletMsg = (r && r.ok) ? "Wallet connected ✓"
                                 : "Couldn't open the wallet: " + (r && r.error ? r.error : "no reply")
                refreshWallet()
            } else if (e === "lezFundFinished") {
                root.walletBusy = false
                root.walletMsg = (r && r.ok)
                                 ? "Added " + (r.prize || 150) + " free tokens to your balance ✓"
                                 : "Couldn't get tokens: " + (r && r.error ? r.error : "no reply")
                refreshWallet()
            }
        }
    }

    // Poll for live updates. A production app would subscribe to inference's
    // responseReceived / promptSent events via logos.onModuleEvent(...).
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: { root.payTick++; refresh() }
    }

    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.onModuleEvent) {
            logos.onModuleEvent("persona_core", "lezOpenFinished")
            logos.onModuleEvent("persona_core", "lezFundFinished")
        }
        refresh()
    }
}
