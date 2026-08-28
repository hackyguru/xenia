#include "inference_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QProcess>
#include <QtMath>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QUuid>

#include <climits>

// Content-topic format: /<app>/<version>/<subtopic>/<format>
// The inference provider (logoscore CLI) subscribes to the exact same topic.
static const QString TOPIC_PREFIX = "/inference/1/";
static const QString TOPIC_SUFFIX = "/json";
// Marketplace discovery: providers everywhere announce capability cards here;
// we browse them and reach any provider on its own session topic — no shared
// room required.
static const QString DISCOVERY_TOPIC = "/inference/1/discovery/json";
// A provider is live until ~3 missed announces (providers announce every ~30s
// jittered; load changes announce immediately, so this only bounds how long a
// silently-dead provider can linger in the roster).
static const qint64 PROVIDER_LIVE_MS = 90000;

InferencePlugin::InferencePlugin(QObject* parent)
    : QObject(parent)
    , m_myId(QUuid::createUuid().toString(QUuid::WithoutBraces).left(8))
{
    const qint64 t = qEnvironmentVariableIntValue("INFERENCE_TIMEOUT_MS");
    if (t > 0) m_timeoutMs = t;
    // Provider whitelist, seedable for headless/scripted setups. The UI edits
    // it at runtime; env gives it a durable default.
    for (const QString& fp : qEnvironmentVariable("INFERENCE_TRUSTED")
                                 .split(',', Qt::SkipEmptyParts))
        m_trusted.insert(fp.trimmed());
    m_trustedOnly = qEnvironmentVariableIntValue("INFERENCE_TRUSTED_ONLY") > 0;
    // Canary auditing is parked as opt-in until it's durable enough to gate
    // routing on (black-box model verification isn't there yet). The whitelist
    // is the trust mechanism; audits, when enabled, are informational only.
    m_autoAudit = qEnvironmentVariableIntValue("INFERENCE_AUTO_AUDIT") > 0;
    // Payment backend for incentivized (access=lez) providers: "mock" runs the
    // paid flow with a synthetic session id (dev/macOS); "lez" pays for real by
    // deshielding (private→public) a one-time amount to the provider's public
    // account through persona_core — the user stays shielded.
    m_payBackend = qEnvironmentVariable("INFERENCE_PAY_BACKEND", "mock").trimmed().toLower();
    m_seq = qEnvironmentVariable("LEZ_SEQUENCER", "https://testnet.lez.logos.co").trimmed();
    loadTrust();
    qDebug() << "InferencePlugin: created, myId =" << m_myId
             << "timeoutMs =" << m_timeoutMs;
}

InferencePlugin::~InferencePlugin() = default;

void InferencePlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    m_identity = new InferenceIdentity(logosAPI, "user");
    if (m_identity->isInitialized()) {
        qDebug() << "InferencePlugin: identity loaded, fingerprint"
                 << m_identity->fingerprint();
    }
    qDebug() << "InferencePlugin: LogosAPI wired up";
}

// ── Identity ─────────────────────────────────────────────────────────
// The UI drives create/import; nothing is auto-created. The identity never
// goes on the wire (prompts stay pseudonymous) — it anchors the future RLN
// membership + payment keys and gives the user a stable, recoverable root.

QString InferencePlugin::identityStatus()
{
    QJsonObject o;
    const bool init = m_identity && m_identity->isInitialized();
    o["initialized"] = init;
    o["locked"]      = m_identity && m_identity->isLocked();
    o["backend"]     = init ? m_identity->backend() : QString();
    o["fingerprint"] = init ? m_identity->fingerprint() : QString();
    o["signPk"]      = init ? QString::fromLatin1(m_identity->signPublicKey().toBase64()) : QString();
    o["boxPk"]       = init ? QString::fromLatin1(m_identity->boxPublicKey().toBase64()) : QString();
    // Session prompt-routing settings (piggybacked so the UI needs one poll).
    o["requireEncryption"] = m_requireEncryption;
    o["preferredProvider"] = m_preferredProvider;
    o["modelFilter"]       = m_modelFilter;
    o["trustedOnly"]       = m_trustedOnly;
    o["trustedCount"]      = m_trusted.size();
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

bool InferencePlugin::unlock(const QString& passphrase)
{
    const bool ok = m_identity && m_identity->unlock(passphrase);
    if (ok)
        emit eventResponse("identityChanged", QVariantList{ m_identity->fingerprint() });
    return ok;
}

bool InferencePlugin::setRequireEncryption(bool required)
{
    m_requireEncryption = required;
    qDebug() << "InferencePlugin: requireEncryption =" << required;
    return true;
}

bool InferencePlugin::setPreferredProvider(const QString& fingerprint)
{
    m_preferredProvider = fingerprint.trimmed();
    qDebug() << "InferencePlugin: preferredProvider ="
             << (m_preferredProvider.isEmpty() ? "(auto)" : m_preferredProvider);
    return true;
}

bool InferencePlugin::setModelFilter(const QString& model)
{
    m_modelFilter = model.trimmed();
    qDebug() << "InferencePlugin: modelFilter ="
             << (m_modelFilter.isEmpty() ? "(any)" : m_modelFilter);
    return true;
}

// The whitelist survives restarts in the same directory as the identity key
// (~/.logos-inference, or LOGOS_IDENTITY_DIR). Env vars seed additively.
QString InferencePlugin::trustFilePath()
{
    QString dir = qEnvironmentVariable("LOGOS_IDENTITY_DIR");
    if (dir.isEmpty()) dir = QDir::homePath() + "/.logos-inference";
    return dir + "/trusted-providers.json";
}

void InferencePlugin::loadTrust()
{
    QFile f(trustFilePath());
    if (!f.open(QIODevice::ReadOnly)) return;
    const QJsonDocument d = QJsonDocument::fromJson(f.readAll());
    if (!d.isObject()) return;
    for (const QJsonValue& v : d.object().value("trusted").toArray())
        if (!v.toString().isEmpty()) m_trusted.insert(v.toString());
    if (d.object().contains("trustedOnly"))
        m_trustedOnly = d.object().value("trustedOnly").toBool();
    qDebug() << "InferencePlugin: trust list loaded —" << m_trusted.size()
             << "provider(s), trustedOnly =" << m_trustedOnly;
}

void InferencePlugin::saveTrust() const
{
    QDir().mkpath(QFileInfo(trustFilePath()).path());
    QFile f(trustFilePath());
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "InferencePlugin: cannot write" << trustFilePath();
        return;
    }
    QJsonObject o;
    o["trusted"]     = QJsonArray::fromStringList(QStringList(m_trusted.values()));
    o["trustedOnly"] = m_trustedOnly;
    f.write(QJsonDocument(o).toJson(QJsonDocument::Indented));
}

bool InferencePlugin::setTrustedOnly(bool enabled)
{
    m_trustedOnly = enabled;
    saveTrust();
    qDebug() << "InferencePlugin: trustedOnly =" << enabled
             << "(" << m_trusted.size() << "trusted )";
    return true;
}

bool InferencePlugin::setTrusted(const QString& fingerprint, bool trusted)
{
    const QString fp = fingerprint.trimmed();
    if (fp.isEmpty()) return false;
    if (trusted) m_trusted.insert(fp); else m_trusted.remove(fp);
    saveTrust();
    return true;
}

QString InferencePlugin::createAccount(const QString& passphrase)
{
    if (!m_identity) return QString();
    const QString mnemonic = m_identity->createAccount(passphrase);
    if (m_identity->isInitialized())
        emit eventResponse("identityChanged", QVariantList{ m_identity->fingerprint() });
    return mnemonic;
}

bool InferencePlugin::importAccount(const QString& mnemonic, const QString& passphrase)
{
    if (!m_identity) return false;
    const bool ok = m_identity->importAccount(mnemonic, passphrase);
    if (ok)
        emit eventResponse("identityChanged", QVariantList{ m_identity->fingerprint() });
    return ok;
}

qint64 InferencePlugin::nowMs()
{
    return QDateTime::currentMSecsSinceEpoch();
}

// ── Delivery lifecycle ───────────────────────────────────────────────

bool InferencePlugin::startDelivery()
{
    if (m_started) return true;

    // connectionStateChanged can fire synchronously inside start(); mark
    // "connecting" first so we don't clobber a later "Connected".
    setDeliveryStatus(1);

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "InferencePlugin: delivery_module client unavailable";
        setDeliveryStatus(3);
        return false;
    }

    // createNode is "call once per process" — skip it on re-Start.
    if (!m_createNodeDone) {
        QJsonObject cfgObj;
        cfgObj["logLevel"] = "INFO";
        cfgObj["mode"]     = "Core";
        cfgObj["preset"]   = "logos.dev";
        // The logos.dev preset still pins clusterId 2, but the fleet moved to
        // cluster 3 — peers drop us during the metadata handshake unless we
        // override it explicitly (explicit fields merge over the preset).
        int clusterId = qEnvironmentVariableIntValue("INFERENCE_CLUSTER_ID");
        if (clusterId <= 0) clusterId = 3;
        cfgObj["clusterId"] = clusterId;
        // Running a second delivery node on one machine? Override the port.
        const int customPort = qEnvironmentVariableIntValue("INFERENCE_TCPPORT");
        if (customPort > 0) {
            cfgObj["tcpPort"]       = customPort;
            cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);
        }
        const QString cfg = QString::fromUtf8(
            QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
        if (!invokeBool("createNode", "createNode", cfg)) {
            setDeliveryStatus(3);
            return false;
        }
        m_createNodeDone = true;
    }

    // Register the inbound handler BEFORE start so we don't miss the first event.
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    if (m_deliveryObject) {
        m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                handleMessageReceived(data);
            });

        m_deliveryClient->onEvent(m_deliveryObject, "connectionStateChanged",
            [this](const QString&, const QVariantList& data) {
                if (data.isEmpty()) return;
                const QString status = data[0].toString();
                if (status.contains("Connected", Qt::CaseInsensitive)) {
                    setDeliveryStatus(2);
                } else if (!status.isEmpty()) {
                    setDeliveryStatus(1);
                }
            });

        m_deliveryClient->onEvent(m_deliveryObject, "messageError",
            [](const QString&, const QVariantList& data) {
                if (data.size() >= 3) qWarning() << "inference: delivery send error:" << data[2];
            });
    } else {
        qWarning() << "InferencePlugin: no delivery_module object — events will be missed";
    }

    if (!invokeBool("start", "start")) {
        setDeliveryStatus(3);
        return false;
    }
    m_started = true;

    if (invokeBool("subscribe", "subscribe", topicForRoom(m_room))) {
        m_subscribed = true;
        qDebug() << "InferencePlugin: subscribed to" << topicForRoom(m_room);
    }

    // Marketplace: listen for capability cards from providers everywhere.
    // Soft-fail — the room flow still works without discovery.
    if (!invokeBool("subscribe discovery", "subscribe", DISCOVERY_TOPIC))
        qWarning() << "InferencePlugin: discovery subscribe failed —"
                   << "roster limited to this room";

    // Optimistically flip to "connected (locally up)" — the real
    // connectionStateChanged can take a while (and is flaky on logos.dev's
    // bootstrap). Same rationale as part3-polling / part11.
    if (m_deliveryStatus < 2) setDeliveryStatus(2);

    if (!m_sweepTimer) {
        m_sweepTimer = new QTimer(this);
        connect(m_sweepTimer, &QTimer::timeout, this, &InferencePlugin::sweepPending);
    }
    m_sweepTimer->start(3000);
    return true;
}

bool InferencePlugin::stopDelivery()
{
    if (!m_started) return true;

    if (m_sweepTimer) m_sweepTimer->stop();
    if (m_deliveryClient) {
        if (m_subscribed) {
            m_deliveryClient->invokeRemoteMethod(
                "delivery_module", "unsubscribe", topicForRoom(m_room));
        }
        m_deliveryClient->invokeRemoteMethod(
            "delivery_module", "unsubscribe", DISCOVERY_TOPIC);
        for (const QString& t : m_sessionSubs)
            m_deliveryClient->invokeRemoteMethod("delivery_module", "unsubscribe", t);
        invokeBool("stop", "stop");
    }
    m_sessionSubs.clear();

    m_deliveryObject = nullptr;
    m_started        = false;
    m_subscribed     = false;
    setDeliveryStatus(0);
    return true;
}

int InferencePlugin::deliveryStatus() { return m_deliveryStatus; }

// ── Rooms ────────────────────────────────────────────────────────────

bool InferencePlugin::joinRoom(const QString& room)
{
    const QString clean = room.trimmed();
    if (clean.isEmpty() || clean == m_room) return true;

    if (m_started && m_deliveryClient) {
        if (m_subscribed) {
            m_deliveryClient->invokeRemoteMethod(
                "delivery_module", "unsubscribe", topicForRoom(m_room));
            m_subscribed = false;
        }
        if (invokeBool("subscribe", "subscribe", topicForRoom(clean))) {
            m_subscribed = true;
        }
    }
    m_room = clean;
    // Room-scoped roster entries don't carry over: an old room's provider is
    // not subscribed to the new room's topic. Marketplace (discovery) entries
    // are global — they have their own session topics — so they stay.
    bool removed = false;
    for (auto it = m_providers.begin(); it != m_providers.end();) {
        if (it->origin == "room") { it = m_providers.erase(it); removed = true; }
        else ++it;
    }
    if (removed)
        emit eventResponse("providersChanged", QVariantList{ m_providers.size() });
    qDebug() << "InferencePlugin: joined room" << m_room << "topic" << topicForRoom(m_room);
    emit eventResponse("roomChanged", QVariantList{ m_room });
    return true;
}

QString InferencePlugin::room() { return m_room; }

// ── Prompt ───────────────────────────────────────────────────────────

// Reputation: this client's own experience with a provider, smoothed so a
// provider with no history scores 0.5 (neutral) rather than 0 or 1. Local and
// subjective by design — no gossip, no trust in other users' claims.
double InferencePlugin::scoreOf(const ProviderRec& p)
{
    return (p.hits + 1.0) / (p.hits + p.misses + 2.0);
}

// Choose a provider from the verified roster: the preferred one if it's live
// and not excluded, else the best of (reputation bucket, then load, then
// random). Reputation is bucketed to quarters — at low sample counts the
// score is noisy, and fine-grained ranking would defeat the random tie-break
// that spreads users across the fleet. A provider that answers reliably
// climbs; one that eats prompts sinks; newcomers start neutral.
const ProviderRec* InferencePlugin::pickProvider(QString& fpOut,
                                                 const QStringList& exclude) const
{
    const qint64 cutoff = nowMs() - PROVIDER_LIVE_MS;

    // Eligibility: live, not already tried, serves the model filter, and its
    // access demand is one we can meet (pow up to 22 bits ≈ seconds of CPU;
    // beyond that, decline to grind).
    const auto eligible = [this, cutoff, &exclude](const QString& id, const ProviderRec& p) {
        if (p.lastSeenMs < cutoff || exclude.contains(id)) return false;
        if (m_trustedOnly && !m_trusted.contains(id)) return false;   // whitelist
        if (!m_modelFilter.isEmpty() && !p.models.contains(m_modelFilter)) return false;
        if (p.access == "pow" && p.powBits > 22) return false;
        // Incentivized (access=lez) providers ARE payable — we open a stream
        // to them (dispatchPrompt → ensureStream). A provider that's priced but
        // not stream-based (legacy per-request) we still can't pay, so skip.
        if (p.access != "lez" && p.priceAmount > 0.0) return false;
        return true;
    };

    if (!m_preferredProvider.isEmpty() && !exclude.contains(m_preferredProvider)) {
        const auto it = m_providers.constFind(m_preferredProvider);
        if (it != m_providers.constEnd() && eligible(it.key(), it.value())) {
            fpOut = it.key();
            return &it.value();
        }
    }

    // Rank eligible providers by: reputation bucket (desc), then price (asc —
    // cheaper wins, meaningful once LEZ prices differ), then load (asc). Random
    // among exact ties keeps the fleet spread. All prices are 0 today, so price
    // is a no-op tiebreak now and starts mattering the day providers differ.
    int bestBucket = -1; double bestPrice = 1e18; int minLoad = INT_MAX;
    for (auto it = m_providers.constBegin(); it != m_providers.constEnd(); ++it) {
        const ProviderRec& p = it.value();
        if (!eligible(it.key(), p)) continue;
        const int b = static_cast<int>(scoreOf(p) * 4);
        if (b > bestBucket ||
            (b == bestBucket && p.priceAmount < bestPrice) ||
            (b == bestBucket && p.priceAmount == bestPrice && p.load < minLoad)) {
            bestBucket = b; bestPrice = p.priceAmount; minLoad = p.load;
        }
    }
    if (bestBucket < 0) return nullptr;   // none available

    QStringList tied;
    for (auto it = m_providers.constBegin(); it != m_providers.constEnd(); ++it) {
        const ProviderRec& p = it.value();
        if (!eligible(it.key(), p)) continue;
        if (static_cast<int>(scoreOf(p) * 4) == bestBucket
            && p.priceAmount == bestPrice && p.load == minLoad)
            tied << it.key();
    }
    fpOut = tied.at(QRandomGenerator::global()->bounded(tied.size()));
    return &m_providers.constFind(fpOut).value();
}

// Hashcash stamp for providers that gate anonymous prompts: find a nonce so
// SHA-256(promptId|providerId|nonce) has `bits` leading zero bits. ~50-300ms
// at the default 18 bits; the iteration cap keeps a hostile difficulty from
// hanging the client (picker already skips >22-bit providers).
bool InferencePlugin::computePow(const QString& promptId, const QString& providerFp,
                                 int bits, QString& nonceOut)
{
    const QByteArray prefix = (promptId + "|" + providerFp + "|").toUtf8();
    for (quint64 n = 0; n < (quint64(1) << 26); ++n) {
        const QByteArray nonce = QByteArray::number(n, 16);
        const QByteArray d = QCryptographicHash::hash(prefix + nonce,
                                                      QCryptographicHash::Sha256);
        int zeros = 0;
        for (const char cc : d) {
            const unsigned char c = static_cast<unsigned char>(cc);
            if (c == 0) { zeros += 8; continue; }
            for (int b = 7; b >= 0 && !((c >> b) & 1); --b) ++zeros;
            break;
        }
        if (zeros >= bits) { nonceOut = QString::fromLatin1(nonce); return true; }
    }
    return false;
}

// Encode a hex account id as base58 (Bitcoin alphabet) — the LEZ sequencer's
// getAccountBalance RPC wants base58. Empty in → empty out.
static QString hexToB58(const QString& hex)
{
    const QByteArray bytes = QByteArray::fromHex(hex.toLatin1());
    if (bytes.isEmpty()) return QString();
    static const char* A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    int zeros = 0;
    while (zeros < bytes.size() && bytes.at(zeros) == 0) ++zeros;
    QList<int> digits;                                   // base58, little-endian
    for (unsigned char byte : bytes) {
        int carry = byte;
        for (int i = 0; i < digits.size(); ++i) {
            carry += digits[i] * 256;
            digits[i] = carry % 58;
            carry /= 58;
        }
        while (carry) { digits.append(carry % 58); carry /= 58; }
    }
    QString s(zeros, QLatin1Char('1'));
    for (int i = digits.size() - 1; i >= 0; --i) s.append(QLatin1Char(A[digits[i]]));
    return s;
}

// A public account's transparent balance from the sequencer RPC (-1 on error).
double InferencePlugin::seqBalance(const QString& payToHex) const
{
    const QString b58 = hexToB58(payToHex);
    if (b58.isEmpty()) return -1.0;
    QProcess p;
    const QString body = QStringLiteral(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountBalance\",\"params\":[\"%1\"]}").arg(b58);
    p.start("curl", {"-s", "-m", "10", "-X", "POST", m_seq,
                     "-H", "content-type: application/json", "-d", body});
    if (!p.waitForFinished(12000)) { p.kill(); return -1.0; }
    const QJsonValue r = QJsonDocument::fromJson(p.readAllStandardOutput())
                             .object().value("result");
    return r.isDouble() ? r.toDouble() : -1.0;
}

// Ensure a prepaid session to a paid provider, returning the session amount
// (which doubles as its id). One session per provider, reused across prompts.
//
// Mock backend (dev/macOS): mark ready immediately with a synthetic amount so
// the paid flow runs end to end without a funded wallet. Real backend
// (INFERENCE_PAY_BACKEND=lez): on first use, deshield a unique one-time amount
// (private→public) to the provider's public payTo through persona_core — the
// payer stays shielded — and report not-ready until pollPayments() sees it land.
bool InferencePlugin::ensureSession(const QString& providerFp, const ProviderRec& p,
                                    QString& amountOut)
{
    if (p.payTo.isEmpty()) return false;   // provider advertised no pay account
    const auto it = m_sessions.find(providerFp);
    if (it != m_sessions.end()) {
        // Reuse the current session until its prepaid quota is spent; once spent,
        // drop it and fall through to open (pay for) a fresh one.
        const bool exhausted = it->ready && p.quota > 0 && it->used >= p.quota;
        if (!exhausted) {
            amountOut = QString::number(qulonglong(it->amount));
            if (it->ready) it->used++;   // count this prompt against the quota
            return it->ready;
        }
        qInfo() << "InferencePlugin: session to" << providerFp << "spent ("
                << it->used << "/" << p.quota << ") — opening a new one";
        m_sessions.erase(it);
    }

    // A session's payment amount is (advertised price, at least 1) plus a small
    // random salt so each session's on-chain credit is unique — that uniqueness
    // is what lets the provider bind a payment to a session without a memo.
    const qulonglong base = qMax<qulonglong>(1, qulonglong(qCeil(p.priceAmount)));
    const qulonglong amount = base + QRandomGenerator::global()->bounded(1, 20);
    PaySession s;
    s.amount = double(amount);

    if (m_payBackend != "lez") {           // mock: instantly ready
        s.ready = true;
        m_sessions.insert(providerFp, s);
        amountOut = QString::number(amount);
        qDebug() << "InferencePlugin: opened (mock) session to" << providerFp << "amount" << amount;
        return true;
    }

    if (!m_walletClient) m_walletClient = logosAPI ? logosAPI->getClient("persona_core") : nullptr;
    if (!m_walletClient) {
        m_payError = QStringLiteral("Open the Persona wallet app to enable payments.");
        qWarning() << "InferencePlugin: persona_core unavailable — can't pay" << providerFp;
        return false;
    }
    // The LEZ wallet must be OPEN before we fire a payment — otherwise the
    // deshield silently fails (fire-and-forget) and the prompt parks for minutes.
    // Check first and fail fast with a clear, actionable reason.
    {
        const QVariant sv = m_walletClient->invokeRemoteMethod(
            "persona_core", "lezStatus", QVariantList{});
        const QJsonObject st = QJsonDocument::fromJson(sv.toString().toUtf8()).object();
        if (!st.value("ready").toBool()) {
            m_payError = st.value("hasWallet").toBool()
                ? QStringLiteral("Open your LEZ wallet (Persona app) to pay this provider.")
                : QStringLiteral("Set up your LEZ wallet (Persona app) to pay this provider.");
            qWarning() << "InferencePlugin: LEZ wallet not open — can't pay" << providerFp;
            return false;
        }
    }
    s.baseline = seqBalance(p.payTo);      // count only credit received from here on
    if (s.baseline < 0.0) {
        m_payError = QStringLiteral("Can't reach the LEZ sequencer to verify payment — check the network.");
        qWarning() << "InferencePlugin: can't read payTo balance for" << providerFp << "— not paying";
        return false;
    }
    m_payError.clear();
    // Fire the one-time payment: deshield from our (auto-picked) private account
    // to the provider's public account. Async — settles in ~a minute; pollPayments
    // flips the session ready once the credit shows up.
    m_walletClient->invokeRemoteMethod("persona_core", "lezTransfer",
        QVariantList{ QStringLiteral("deshielded"), QString(), p.payTo, QString::number(amount) });
    m_sessions.insert(providerFp, s);
    amountOut = QString::number(amount);
    qInfo() << "InferencePlugin: paying" << amount << "to" << providerFp
            << "(deshield → " << p.payTo.left(10) << "…) — awaiting settlement";
    if (!m_payTimer) {
        m_payTimer = new QTimer(this);
        connect(m_payTimer, &QTimer::timeout, this, &InferencePlugin::pollPayments);
        m_payTimer->start(6000);
    } else if (!m_payTimer->isActive()) {
        m_payTimer->start(6000);
    }
    return false;   // parked until funded
}

// Poll each pending session's payTo balance; when the one-time payment has
// landed, mark the session ready and release the prompts parked on it.
void InferencePlugin::pollPayments()
{
    bool anyPending = false;
    for (auto it = m_sessions.begin(); it != m_sessions.end(); ++it) {
        if (it.value().ready) continue;
        const auto pit = m_providers.constFind(it.key());
        if (pit == m_providers.constEnd() || pit->payTo.isEmpty()) continue;
        const double bal = seqBalance(pit->payTo);
        if (bal < 0.0) { anyPending = true; continue; }
        if (bal - it.value().baseline + 1e-9 >= it.value().amount) {
            it.value().ready = true;
            qInfo() << "InferencePlugin: session to" << it.key() << "funded ("
                    << it.value().amount << ") — releasing parked prompts";
            // Release every prompt waiting on this provider.
            for (PromptRec& rec : m_prompts) {
                if (rec.waitPay && rec.payFp == it.key() && !rec.answered && !rec.failed) {
                    rec.waitPay = false;
                    dispatchPrompt(rec);
                }
            }
        } else {
            anyPending = true;
        }
    }
    if (!anyPending && m_payTimer) m_payTimer->stop();
}

// ── Canary auditing ──────────────────────────────────────────────────
// The real defense against model substitution (advertise qwen3:8b, secretly
// run tinyllama): a small bank of OBJECTIVE questions any competent model
// answers correctly and toy models fail. An audit is a normal sealed prompt
// requesting the advertised model — the provider can't tell it from real
// traffic (prompts are E2E-sealed under ephemeral keys), so it can't behave
// only when watched. A wrong answer is provable: the delivered model isn't
// what was promised. Calibrated live against qwen3:8b vs tinyllama.
struct Canary { const char* q; const char* expect; };
static const Canary CANARIES[] = {
    { "What is 47 * 23? Reply with only the number.", "1081" },
    { "What is the square root of 1764? Reply with only the number.", "42" },
    { "What is 15% of 240? Reply with only the number.", "36" },
    { "What is the chemical symbol for tungsten? Reply with only the symbol.", "W" },
    { "What is 128 + 256? Reply with only the number.", "384" },
    { "How many sides does a hexagon have? Reply with only the number.", "6" },
};

// Only audit providers whose advertised model should ace objective questions.
// Toy models (tinyllama, sub-3B) legitimately fail these, so auditing them
// would punish honest advertising — skip them.
static bool modelLikelyCapable(const QString& modelIn)
{
    const QString m = modelIn.toLower();
    if (m.contains("tiny")) return false;
    QRegularExpression re("([0-9]+(?:\\.[0-9]+)?)b");
    auto it = re.globalMatch(m);
    double sz = -1;
    while (it.hasNext()) sz = qMax(sz, it.next().captured(1).toDouble());
    return !(sz > 0 && sz < 3);   // <3B ⇒ toy; unknown size ⇒ assume capable
}

// Grade a canary answer: does the model's reply contain the expected token?
// Case-insensitive, punctuation-tolerant (models wrap short answers in prose
// even when told not to; the discriminator is whether the right token appears
// at all — capable models include it, substituted toys don't).
static bool canaryPasses(const QString& expect, const QString& answer)
{
    const QString a = answer.toLower();
    const QString e = expect.toLower();
    // Word/number boundary so "6" doesn't match "16" and "w" doesn't match "who".
    QRegularExpression re("(^|[^a-z0-9])" + QRegularExpression::escape(e) + "([^a-z0-9]|$)");
    return re.match(a).hasMatch();
}

// Fire one audit at a specific provider (does nothing if it's not live or its
// model isn't auditable). Manual trigger + auto-on-first-sight both call this.
bool InferencePlugin::auditProvider(const QString& fingerprint)
{
    const auto it = m_providers.find(fingerprint);
    if (it == m_providers.end()) return false;
    if (!modelLikelyCapable(it->model)) return false;
    if (!m_started && !startDelivery()) return false;

    const Canary& c = CANARIES[QRandomGenerator::global()->bounded(
        int(sizeof(CANARIES) / sizeof(CANARIES[0])))];
    PromptRec rec;
    rec.id       = QUuid::createUuid().toString(QUuid::WithoutBraces);
    rec.prompt   = QString::fromUtf8(c.q);
    rec.sentMs   = nowMs();
    rec.canary   = true;
    rec.expect   = QString::fromUtf8(c.expect);
    rec.pin      = fingerprint;        // audit THIS provider, not the picker's choice
    rec.reqModel = it->model;          // demand the advertised model
    it->lastAuditMs = nowMs();

    if (!dispatchPrompt(rec)) return false;
    m_prompts.prepend(rec);
    pruneHistory();
    qDebug() << "InferencePlugin: auditing" << fingerprint << "with canary" << rec.id;
    return true;
}

// Put one attempt of `rec` on the wire — sealed to the next untried provider,
// or plaintext when none is available and plaintext is allowed. Shared by
// sendPrompt (first attempt) and sweepPending (retries).
bool InferencePlugin::dispatchPrompt(PromptRec& rec)
{
    QJsonObject obj;
    obj["type"] = "prompt";
    obj["id"]   = rec.id;

    rec.sealed = false;
    QString sendTopic = topicForRoom(m_room);   // plaintext fallback stays in-room
    QString providerFp;
    const ProviderRec* prov = nullptr;
    // Canary audits (and any pinned send) target one specific provider rather
    // than the auto-picker, so we test exactly who we mean to test.
    if (!rec.pin.isEmpty()) {
        const auto it = m_providers.constFind(rec.pin);
        const qint64 cutoff = nowMs() - PROVIDER_LIVE_MS;
        // A provider we've PAID must remain the target across retries — we
        // committed funds to it, so re-select it even if already tried. Other
        // pins (canary audits) still honor the tried set.
        const bool paidPin = m_sessions.contains(rec.pin) && m_sessions.value(rec.pin).ready;
        if (it != m_providers.constEnd() && it->lastSeenMs >= cutoff
            && (paidPin || !rec.tried.contains(rec.pin))) {
            prov = &it.value();
            providerFp = rec.pin;
        }
    } else {
        prov = pickProvider(providerFp, rec.tried);
    }
    QByteArray ephSk, ephPk;
    if (prov && InferenceIdentity::genEphemeralKeypair(ephSk, ephPk)) {
        QJsonObject inner;
        inner["prompt"]  = rec.prompt;
        inner["replyPk"] = QString::fromLatin1(ephPk.toBase64());
        // Multi-model marketplace providers run whichever model we ask for;
        // only request one when the user filtered (the provider's default
        // otherwise). Rides inside the sealed box — the request stays private.
        const QString wantModel = !rec.reqModel.isEmpty() ? rec.reqModel : m_modelFilter;
        if (!wantModel.isEmpty()) inner["model"] = wantModel;
        // Credential seam: meet the provider's access demand. Today: a
        // hashcash stamp; later: identity, voucher, RLN proof, LEZ note —
        // all inside the sealed box, invisible to the network.
        if (prov->access == "pow") {
            QString nonce;
            if (!computePow(rec.id, providerFp, prov->powBits, nonce)) {
                qWarning() << "InferencePlugin: pow for" << providerFp
                           << "(" << prov->powBits << "bits) not found — skipping provider";
                rec.tried << providerFp;   // don't retry this one
                return dispatchPrompt(rec);
            }
            QJsonObject cred;
            cred["type"]  = "pow";
            cred["nonce"] = nonce;
            inner["cred"] = cred;
        } else if (prov->access == "lez") {
            // Incentivized provider: prepay a session (a one-time deshield to its
            // public payTo). If the payment hasn't settled yet, PARK this prompt
            // on the provider — don't seal/send and don't fail over to someone
            // else (we've committed funds here) — pollPayments releases it once
            // the credit lands.
            QString amount;
            if (!ensureSession(providerFp, *prov, amount)) {
                if (m_sessions.contains(providerFp)) {   // paying, not yet funded → park
                    rec.waitPay    = true;
                    rec.payFp      = providerFp;
                    rec.provider   = providerFp;
                    if (rec.payStartMs == 0) rec.payStartMs = nowMs();
                    qDebug() << "InferencePlugin: prompt" << rec.id << "parked — awaiting"
                             << "payment settlement to" << providerFp;
                    return true;
                }
                // Couldn't even START paying (wallet not open, no funds, no
                // sequencer) — fail fast with the actionable reason instead of
                // silently degrading to a plaintext send a paid provider rejects.
                if (!m_payError.isEmpty()) {
                    rec.reason = m_payError;
                    qWarning() << "InferencePlugin: paid prompt" << rec.id
                               << "not sent —" << m_payError;
                    return false;   // sendPrompt/sweep mark it failed, carrying rec.reason
                }
                qWarning() << "InferencePlugin: can't open a paid session to" << providerFp
                           << "— skipping provider";
                rec.tried << providerFp;
                return dispatchPrompt(rec);
            }
            QJsonObject cred;
            cred["type"]   = "lez-prepay";
            cred["amount"] = amount;              // the unique amount = session id
            inner["cred"] = cred;
            // We've paid this provider — pin so every retry re-seals to it (and
            // never fails over to a free provider or plaintext).
            rec.pin   = providerFp;
            rec.payFp = providerFp;
        }
        const QByteArray sealed = InferenceIdentity::seal(
            prov->boxPk, QJsonDocument(inner).toJson(QJsonDocument::Compact));
        if (!sealed.isEmpty()) {
            rec.sealed   = true;
            rec.provider = providerFp;   // most recent provider asked
            rec.tried << providerFp;
            rec.ephSks << ephSk;         // keep — an earlier provider may still answer
            obj["v"]   = 2;
            obj["to"]  = providerFp;
            obj["box"] = QString::fromLatin1(sealed.toBase64());
            // Marketplace providers are reached on their own session topic —
            // join it first so their response (sent on the same topic) is heard.
            sendTopic = prov->topic.isEmpty() ? sendTopic : prov->topic;
            if (sendTopic != topicForRoom(m_room) && !m_sessionSubs.contains(sendTopic)) {
                if (invokeBool("subscribe session", "subscribe", sendTopic))
                    m_sessionSubs.insert(sendTopic);
            }
        }
    }
    if (!rec.sealed) {
        // A prompt we've paid for must never go out in the clear — a paid
        // provider rejects plaintext, so that would just burn the payment. Keep
        // it pending (still pinned to the paid provider) for a sealed retry; the
        // sweep re-dispatches it (e.g. once the provider is reachable again).
        if (!rec.payFp.isEmpty() && m_sessions.contains(rec.payFp)) {
            rec.lastSendMs = nowMs();   // restart the retry clock; don't send now
            qDebug() << "InferencePlugin: paid prompt" << rec.id
                     << "not sealed this pass — holding for a sealed retry to" << rec.payFp;
            return true;
        }
        if (m_requireEncryption) return false;   // never send in the clear
        // No verified provider heard from yet (or sealing failed): legacy
        // plaintext broadcast, so the demo still works against old providers.
        obj["from"]   = m_myId;
        obj["ts"]     = rec.sentMs;
        obj["prompt"] = rec.prompt;
        rec.provider.clear();
    }

    rec.lastSendMs = nowMs();
    const QString payload = QString::fromUtf8(
        QJsonDocument(obj).toJson(QJsonDocument::Compact));
    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", sendTopic, payload);
    if (!r.isValid()) {
        qWarning() << "InferencePlugin: delivery_module.send RPC failed";
    }
    qDebug() << "InferencePlugin: sent" << (rec.sealed ? "sealed" : "plaintext")
             << "prompt" << rec.id << "attempt" << (rec.retries + 1)
             << "on" << sendTopic
             << (rec.sealed ? "provider " + rec.provider : QString());
    return true;
}

QString InferencePlugin::sendPrompt(const QString& prompt)
{
    const QString text = prompt.trimmed();
    if (text.isEmpty()) return QString();
    if (!m_started && !startDelivery()) return QString();

    PromptRec rec;
    // Full UUID (128-bit), not an 8-hex-char prefix: the id is the correlation
    // key across the whole network, and a 32-bit id starts colliding around
    // tens of thousands of prompts — reachable on a busy multi-user network.
    rec.id     = QUuid::createUuid().toString(QUuid::WithoutBraces);
    rec.prompt = text;
    rec.sentMs = nowMs();

    if (!dispatchPrompt(rec)) {
        // requireEncryption is on and no live provider to seal to. Record it as
        // a failed exchange (not a silent drop) so the UI shows why nothing was
        // sent instead of appearing to swallow the prompt.
        qWarning() << "InferencePlugin: prompt not sent — encryption required"
                   << "but no live provider in the roster";
        rec.failed = true;
        m_prompts.prepend(rec);
        emit eventResponse("promptFailed", QVariantList{ rec.id });
        pruneHistory();
        return rec.id;
    }

    m_prompts.prepend(rec);
    emit eventResponse("promptSent", QVariantList{ rec.id, m_room });
    pruneHistory();
    return rec.id;
}

// Bound the in-memory exchange history on a long-lived user node. Drops the
// oldest SETTLED (answered/failed) records past the cap; never drops a prompt
// still in flight (its ephemeral keys are needed to open a late answer).
void InferencePlugin::pruneHistory()
{
    const int cap = 200;
    if (m_prompts.size() <= cap) return;
    for (int i = m_prompts.size() - 1; i >= 0 && m_prompts.size() > cap; --i) {
        if (m_prompts[i].answered || m_prompts[i].failed)
            m_prompts.removeAt(i);
    }
}

// Timeout/retry sweep: a prompt unanswered for m_timeoutMs is re-sent to the
// next-best provider (fresh ephemeral key, same id — first answer wins), up
// to m_maxRetries; after that it's marked failed so the UI stops saying
// "thinking…" about a dead provider.
void InferencePlugin::sweepPending()
{
    const qint64 now = nowMs();
    static const qint64 PAY_DEADLINE_MS = 240000;   // give a shielded spend ~4 min to settle
    for (PromptRec& p : m_prompts) {
        if (p.answered || p.failed) continue;
        // Parked awaiting payment: not a provider timeout — leave it for
        // pollPayments to release, unless the payment never settles.
        if (p.waitPay) {
            if (p.payStartMs > 0 && now - p.payStartMs > PAY_DEADLINE_MS) {
                p.waitPay = false; p.failed = true;
                qWarning() << "InferencePlugin: prompt" << p.id
                           << "failed — payment to" << p.payFp << "never settled";
                emit eventResponse("promptFailed", QVariantList{ p.id });
            }
            continue;
        }
        if (now - p.lastSendMs < m_timeoutMs) continue;

        // Reputation: whoever we asked ate this attempt without answering.
        // (Plaintext broadcasts have no provider to charge.)
        if (!p.provider.isEmpty()) {
            const auto it = m_providers.find(p.provider);
            if (it != m_providers.end()) ++it->misses;
        }

        if (p.retries >= m_maxRetries) {
            // Mark failed but KEEP p.ephSks: a slow provider's sealed answer can
            // still arrive and un-fail the prompt (handleResponse handles that).
            p.failed = true;
            qWarning() << "InferencePlugin: prompt" << p.id << "failed after"
                       << p.retries << "retries";
            emit eventResponse("promptFailed", QVariantList{ p.id });
            continue;
        }
        ++p.retries;
        if (!dispatchPrompt(p)) {
            // requireEncryption and nobody left to try — fail immediately.
            p.failed = true;
            emit eventResponse("promptFailed", QVariantList{ p.id });
        }
    }
}

// ── Query helpers ────────────────────────────────────────────────────

QString InferencePlugin::listExchanges()
{
    QJsonArray arr;
    const qint64 now = nowMs();
    for (const PromptRec& p : m_prompts) {
        if (p.canary) continue;   // audits are internal, not user prompts
        QJsonObject o;
        o["id"]       = p.id;
        o["prompt"]   = p.prompt;
        o["sentMs"]   = p.sentMs;
        o["ageMs"]    = now - p.sentMs;
        o["answered"] = p.answered;
        o["rttMs"]    = static_cast<double>(p.rttMs);
        o["text"]     = p.text;
        o["provider"] = p.provider;
        o["model"]    = p.model;
        o["sealed"]   = p.sealed;
        o["failed"]   = p.failed;
        o["retries"]  = p.retries;
        o["paying"]   = p.waitPay;   // parked while its payment's zk proof settles
        o["reason"]   = p.reason;    // failure reason (e.g. wallet not open)
        arr.append(o);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

bool InferencePlugin::clearExchanges()
{
    m_prompts.clear();
    emit eventResponse("cleared", QVariantList{});
    return true;
}

QString InferencePlugin::myId() { return m_myId; }

// ── Private helpers ──────────────────────────────────────────────────

QString InferencePlugin::topicForRoom(const QString& room) const
{
    return TOPIC_PREFIX + room + TOPIC_SUFFIX;
}

// A marketplace provider's session topic — where its prompts (and responses)
// travel. Must match the provider side's sessionTopic().
QString InferencePlugin::providerTopic(const QString& fingerprint) const
{
    return TOPIC_PREFIX + "p-" + fingerprint + TOPIC_SUFFIX;
}

void InferencePlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived: [hash, contentTopic, payload_base64, ts_ns]
    if (data.size() < 3) return;

    const QString topic = data[1].toString();
    // Ours if it's the room, the discovery feed, or a provider session
    // topic we've joined to talk to a marketplace provider.
    if (topic != topicForRoom(m_room) && topic != DISCOVERY_TOPIC &&
        !m_sessionSubs.contains(topic))
        return;

    // delivery_module ≥0.2.0 emits the payload as raw bytes (QByteArray, or a
    // QVariantList of byte values over IPC); older builds sent base64 text.
    // Our messages are always JSON objects, so sniff the leading brace.
    QByteArray payload;
    if (data[2].userType() == QMetaType::QVariantList) {
        for (const QVariant& b : data[2].toList())
            payload.append(char(b.toUInt()));
    } else {
        payload = data[2].toByteArray();
    }
    if (!payload.startsWith('{'))
        payload = QByteArray::fromBase64(payload);

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) return;

    const QJsonObject obj  = doc.object();
    const QString     type = obj.value("type").toString();

    if (type == "announce")      handleAnnounce(obj);
    else if (type == "response") handleResponse(obj);
    // prompts are the provider's business, not ours
}

// Verify a provider announce and upsert the roster. Self-certifying: the id
// must be the fingerprint of the signing key, and the announce must verify
// under that key — so nobody can advertise a box key under someone else's id.
// v2 = room announce (single model, reachable via the room topic).
// v3 = marketplace capability card from the discovery topic (models list,
//      capacity, price scheme, reachable on the provider's session topic).
void InferencePlugin::handleAnnounce(const QJsonObject& obj)
{
    const int     v         = obj.value("v").toInt();
    const QString id        = obj.value("id").toString();
    const QString signPkB64 = obj.value("signPk").toString();
    const QString boxPkB64  = obj.value("boxPk").toString();
    const int     load      = obj.value("load").toInt();
    const qint64  ts        = static_cast<qint64>(obj.value("ts").toDouble());
    const QByteArray sig    = QByteArray::fromBase64(obj.value("sig").toString().toLatin1());
    const QByteArray signPk = QByteArray::fromBase64(signPkB64.toLatin1());
    const QByteArray boxPk  = QByteArray::fromBase64(boxPkB64.toLatin1());
    if (id.isEmpty() || signPk.size() != 32 || boxPk.size() != 32) return;

    if (InferenceIdentity::fingerprintOf(signPk) != id) {
        qWarning() << "InferencePlugin: announce id/key mismatch for" << id << "— ignored";
        return;
    }

    QString     model;
    QStringList models;
    int         cap = 0;
    QString     price;
    QString     access;
    int         powBits = 0;
    double      priceAmt = 0.0;
    QString     priceUnit, priceAsset;
    QString     payTo;
    double      rate = 0.0;
    int         quota = 0;
    if (v >= 3) {
        for (const QJsonValue& mv : obj.value("models").toArray())
            models << mv.toString();
        if (models.isEmpty()) return;
        model = models.first();
        cap   = obj.value("cap").toInt();
        const QJsonObject priceObj = obj.value("price").toObject();
        price     = priceObj.value("scheme").toString();
        access    = priceObj.value("access").toString("open");
        powBits   = priceObj.value("powbits").toInt();
        priceAmt  = priceObj.value("amount").toDouble();
        priceUnit = priceObj.value("unit").toString("request");
        priceAsset= priceObj.value("asset").toString();
        payTo     = priceObj.value("payTo").toString();
        rate      = priceObj.value("rate").toDouble();
        quota     = priceObj.value("quota").toInt();
        const QString priceJson = QString::fromUtf8(
            QJsonDocument(priceObj).toJson(QJsonDocument::Compact));
        const QByteArray canon3 =
            QString("inference/v1/announce3|%1|%2|%3|%4|%5|%6|%7|%8")
                .arg(id, signPkB64, boxPkB64, models.join(','),
                     QString::number(load), QString::number(cap),
                     priceJson, QString::number(ts)).toUtf8();
        if (!InferenceIdentity::verify(canon3, sig, signPk)) {
            qWarning() << "InferencePlugin: bad v3 card signature from" << id << "— ignored";
            return;
        }
    } else {
        model  = obj.value("model").toString();
        models = QStringList{ model };
        const QByteArray canon = QString("inference/v1/announce|%1|%2|%3|%4|%5|%6")
            .arg(id, signPkB64, boxPkB64, model,
                 QString::number(load), QString::number(ts)).toUtf8();
        if (!InferenceIdentity::verify(canon, sig, signPk)) {
            qWarning() << "InferencePlugin: bad announce signature from" << id << "— ignored";
            return;
        }
    }

    // Freshness: reject stale/replayed announces. The signed `ts` must be near
    // now (±60s for clock skew) — otherwise a captured announce could be
    // replayed to keep a dead provider 'live' and black-hole prompts. This
    // also bounds boxPk to the current epoch (rotation grace is only 1 day).
    const qint64 skew = qAbs(nowMs() - ts);
    if (ts <= 0 || skew > 60000) {
        qWarning() << "InferencePlugin: stale announce from" << id
                   << "(" << skew << "ms skew) — ignored";
        return;
    }

    const bool isNew = !m_providers.contains(id);
    ProviderRec& p = m_providers[id];
    p.signPk = signPk;
    p.boxPk  = boxPk;
    p.model  = model;
    p.models = models;
    p.load   = load;
    p.lastSeenMs = nowMs();
    // A provider heard on both channels keeps its marketplace entry: the
    // session topic reaches it from anywhere, the room topic only here.
    if (v >= 3 || p.origin.isEmpty()) {
        p.origin = (v >= 3) ? "discovery" : "room";
        p.topic  = (v >= 3) ? providerTopic(id) : topicForRoom(m_room);
    }
    if (v >= 3) {
        p.cap        = cap;
        p.price      = price;
        p.access     = access;
        p.powBits    = powBits;
        p.payTo      = payTo;
        p.rate       = rate;
        p.quota      = quota;
        p.priceAmount = priceAmt;
        p.priceUnit  = priceUnit;
        p.priceAsset = priceAsset;
    }
    if (isNew) {
        qDebug() << "InferencePlugin: provider" << id << "joined roster ("
                 << models.join(',') << "," << p.origin << ")";
        emit eventResponse("providersChanged", QVariantList{ m_providers.size() });
        // First sight of a capable provider → audit it once so its integrity is
        // known before it earns much traffic. Deferred a few seconds so the
        // roster (and any pow bits) has settled. Auto-audit is opt-outable.
        if (m_autoAudit && modelLikelyCapable(model)) {
            const QString fp = id;
            QTimer::singleShot(4000, this, [this, fp]() { auditProvider(fp); });
        }
    }
}

void InferencePlugin::handleResponse(const QJsonObject& obj)
{
    const QString id   = obj.value("id").toString();
    const QString from = obj.value("from").toString();
    if (id.isEmpty()) return;

    for (PromptRec& p : m_prompts) {
        if (p.id != id || p.answered) continue;

        QString text, model, answeredBy = from;
        if (obj.value("v").toInt() >= 2 && p.sealed) {
            // Sealed response: try every ephemeral secret we used for this
            // prompt (one per attempt), so a late answer from any tried
            // provider still opens. Opening at all already proves it came from
            // a provider we sealed to (they needed our reply key, sealed to
            // THEIR box key) — the signature is a second, explicit check.
            const QString boxB64 = obj.value("box").toString();
            const QByteArray box = QByteArray::fromBase64(boxB64.toLatin1());
            QByteArray inner;
            for (const QByteArray& sk : p.ephSks) {
                inner = InferenceIdentity::openWith(sk, box);
                if (!inner.isEmpty()) break;
            }
            if (inner.isEmpty()) return;   // not for us / tampered

            // Verify the signature against a provider we ACTUALLY asked
            // (p.provider or any in p.tried), not the self-asserted `from`.
            const QString signer = p.tried.contains(from) ? from : p.provider;
            const auto it = m_providers.constFind(signer);
            if (it != m_providers.constEnd()) {
                const QByteArray canon =
                    QString("inference/v1/response|%1|%2").arg(id, boxB64).toUtf8();
                const QByteArray sig =
                    QByteArray::fromBase64(obj.value("sig").toString().toLatin1());
                if (!InferenceIdentity::verify(canon, sig, it->signPk)) {
                    qWarning() << "InferencePlugin: response" << id
                               << "bad signature for" << signer << "— dropped";
                    return;
                }
                answeredBy = signer;
            } else {
                // Can't verify (provider expired from roster). The box already
                // proves origin, so accept but keep the provider we asked.
                answeredBy = p.provider;
                qWarning() << "InferencePlugin: response" << id
                           << "signer not in roster — accepted on box proof only";
            }
            const QJsonDocument d = QJsonDocument::fromJson(inner);
            if (!d.isObject()) return;
            text  = d.object().value("text").toString();
            model = d.object().value("model").toString();
        } else if (!p.sealed) {
            // Legacy plaintext response to a plaintext prompt.
            text  = obj.value("text").toString();
            model = obj.value("model").toString();
        } else {
            return;   // plaintext answer to a sealed prompt — not acceptable
        }

        p.answered = true;
        p.failed   = false;   // a late answer beats a timeout verdict
        p.rttMs    = nowMs() - p.sentMs;
        p.text     = text;
        p.provider = answeredBy;
        p.model    = model;
        p.ephSks.clear();   // reply channel closed — keys no longer needed
        // Reputation + integrity. A sealed answer earns a hit either way (they
        // responded). If this was a canary, also grade it: a right answer
        // confirms the advertised model, a wrong one is proof of substitution.
        {
            const auto it = m_providers.find(answeredBy);
            if (it != m_providers.end()) {
                ++it->hits;
                if (p.canary) {
                    ++it->audits;
                    const bool ok = canaryPasses(p.expect, text);
                    if (ok) ++it->auditsPassed;
                    qWarning().noquote() << "InferencePlugin: audit of" << answeredBy
                        << (ok ? "PASSED" : "FAILED")
                        << "— canary expected" << p.expect << ", got:"
                        << text.left(60);
                    emit eventResponse("auditResult",
                        QVariantList{ answeredBy, ok });
                }
            }
        }
        qDebug() << "InferencePlugin: response for" << id << "from" << answeredBy
                 << (p.sealed ? "(sealed)" : "(plaintext)")
                 << "rtt" << p.rttMs << "ms" << "(" << p.text.size() << "chars )";
        emit eventResponse("responseReceived",
            QVariantList{ id, from, static_cast<double>(p.rttMs) });
        return;
    }
}

// Active prepaid sessions — what we're paying / have paid, and quota left, so
// the UI can make the paid flow legible instead of a silent park.
QString InferencePlugin::paymentStatus()
{
    QJsonArray arr;
    for (auto it = m_sessions.constBegin(); it != m_sessions.constEnd(); ++it) {
        const QString fp = it.key();
        const auto pit = m_providers.constFind(fp);
        int waiting = 0;
        for (const PromptRec& r : m_prompts)
            if (r.waitPay && r.payFp == fp && !r.answered && !r.failed) ++waiting;
        arr.append(QJsonObject{
            {"provider", fp},
            {"amount", it.value().amount},
            {"ready",  it.value().ready},
            {"used",   it.value().used},
            {"quota",  pit != m_providers.constEnd() ? pit->quota : 0},
            {"waiting", waiting}
        });
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

QString InferencePlugin::listProviders()
{
    QJsonArray arr;
    const qint64 now = nowMs();
    for (auto it = m_providers.constBegin(); it != m_providers.constEnd(); ++it) {
        QJsonObject o;
        o["id"]     = it.key();
        o["model"]  = it->model;
        o["models"] = QJsonArray::fromStringList(it->models);
        o["load"]   = it->load;
        o["cap"]    = it->cap;
        o["origin"] = it->origin;
        o["price"]       = it->price.isEmpty() ? "free" : it->price;
        o["priceAmount"] = it->priceAmount;
        o["priceUnit"]   = it->priceUnit.isEmpty() ? "request" : it->priceUnit;
        o["priceAsset"]  = it->priceAsset;
        o["access"] = it->access.isEmpty() ? "open" : it->access;
        o["payTo"]  = it->payTo;
        o["rate"]   = it->rate;
        o["trusted"]      = m_trusted.contains(it.key());
        o["audits"]       = it->audits;
        o["auditsPassed"] = it->auditsPassed;
        o["integrity"]    = it->audits == 0 ? QStringLiteral("unknown")
                          : it->auditsPassed == it->audits ? QStringLiteral("verified")
                          : it->auditsPassed == 0 ? QStringLiteral("failed")
                          : QStringLiteral("mixed");
        o["hits"]   = it->hits;
        o["misses"] = it->misses;
        o["score"]  = scoreOf(it.value());
        o["ageMs"]  = static_cast<double>(now - it->lastSeenMs);
        o["live"]   = (now - it->lastSeenMs) < PROVIDER_LIVE_MS;
        arr.append(o);
    }
    return QString::fromUtf8(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

void InferencePlugin::setDeliveryStatus(int status)
{
    if (m_deliveryStatus == status) return;
    m_deliveryStatus = status;
    emit eventResponse("deliveryStatusChanged", QVariantList{ status });
}

bool InferencePlugin::invokeBool(const char* what,
                                 const QString& method,
                                 const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        qWarning() << "InferencePlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "InferencePlugin:" << what << "failed:" << lr.error.toString();
            return false;
        }
        return true;
    }
    if (!r.toBool()) {
        qWarning() << "InferencePlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
