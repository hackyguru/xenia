#include "provider_plugin.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDebug>
#include <QElapsedTimer>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QFile>
#include <QProcess>
#include <QRandomGenerator>
#include <QTimer>
#include <QUuid>

// Must match the inference user (part13 inference-core / inference-ui).
static const QString TOPIC_PREFIX = "/inference/1/";
static const QString TOPIC_SUFFIX = "/json";
// Marketplace discovery: a single well-known topic every provider announces
// capability cards on, and every user browses — no shared room needed.
static const QString DISCOVERY_TOPIC = "/inference/1/discovery/json";

// Encode a hex account id as base58 (Bitcoin alphabet) — the form the LEZ
// sequencer's getAccountBalance RPC expects. Empty in → empty out.
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

ProviderPlugin::ProviderPlugin(QObject* parent)
    : QObject(parent)
    , m_id("cli-llm-" + QUuid::createUuid().toString(QUuid::WithoutBraces).left(4))
    , m_model(qEnvironmentVariable("INFERENCE_MODEL", "tinyllama"))
    , m_ollamaUrl(qEnvironmentVariable("OLLAMA_URL", "http://localhost:11434"))
{
    // Marketplace capability card: every model this node serves. INFERENCE_MODELS
    // (comma-separated) wins; else the single INFERENCE_MODEL. The first entry
    // is the default when a prompt doesn't request a specific model.
    const QString multi = qEnvironmentVariable("INFERENCE_MODELS");
    for (const QString& m : multi.split(',', Qt::SkipEmptyParts))
        m_models << m.trimmed();
    if (m_models.isEmpty()) m_models << m_model;
    m_model = m_models.first();
    // Cap concurrent inferences. ollama serializes per model anyway, so beyond
    // a small number extra prompts just queue and blow past the user's timeout;
    // better to decline them so they fail over to a less-busy provider. 0/unset
    // → default 4; set INFERENCE_MAX_INFLIGHT to tune.
    const int cap = qEnvironmentVariableIntValue("INFERENCE_MAX_INFLIGHT");
    m_maxInflight = cap > 0 ? cap : 4;

    // Pricing — advertised in the capability card so users choose on cost.
    // Zero today (LEZ payments aren't live); the structure is the seam:
    //   amount  — price per `unit` (0 = free)
    //   unit    — "request" or "1ktokens"
    //   asset   — LEZ asset/denomination id (empty until LEZ)
    //   scheme  — "free" while amount==0, else "lez" (payable via a LEZ note)
    // When LEZ lands: set amount>0 + asset, flip nothing else — the client
    // already reads these and will attach a lez-note credential to pay.
    m_priceAmount = qEnvironmentVariable("INFERENCE_PRICE", "0").toDouble();
    m_priceUnit   = qEnvironmentVariable("INFERENCE_PRICE_UNIT", "request").trimmed();
    m_priceAsset  = qEnvironmentVariable("INFERENCE_PRICE_ASSET", "").trimmed();

    // Access policy — the credential seam. "open" (default) answers anyone;
    // "pow" requires a hashcash stamp inside the sealed prompt, so anonymous
    // users pay ~a CPU-second per request instead of being unlimited. Future
    // credential types (identity tiers, vouchers, RLN proofs, LEZ notes) slot
    // into the same `cred` field without another protocol change.
    m_access = qEnvironmentVariable("INFERENCE_ACCESS", "open").trimmed().toLower();
    if (m_access != "pow" && m_access != "lez") m_access = "open";
    const int bits = qEnvironmentVariableIntValue("INFERENCE_POW_BITS");
    m_powBits = (bits >= 8 && bits <= 30) ? bits : 18;

    // Incentivization (INFERENCE_ACCESS=lez): this node only answers prompts
    // backed by an open LIP-155 payment stream to its LEZ account. payTo is the
    // provider's LEZ account (advertised so clients open a stream to it); rate
    // is the stream draw in TokensPerSecond. Verification/claims go through the
    // PaymentBackend — a mock today (accepts a well-formed stream cred), the
    // real payment_streams_module (loaded beside inference_provider) on Linux.
    m_payTo = qEnvironmentVariable("INFERENCE_PAY_TO", "").trimmed().toLower();
    m_rate  = qEnvironmentVariable("INFERENCE_RATE", "1").toDouble();
    m_payBackend = qEnvironmentVariable("INFERENCE_PAY_BACKEND", "mock").trimmed().toLower();
    // Per-session prepay: users pay a one-time amount to m_payTo (a PUBLIC LEZ
    // account, provisioned once in Basecamp) which unlocks INFERENCE_QUOTA
    // prompts. We only need to READ that account's balance, so the provider
    // needs no LEZ module — just the sequencer's getAccountBalance RPC, which
    // wants the id in base58.
    const int q = qEnvironmentVariableIntValue("INFERENCE_QUOTA");
    m_quota = q > 0 ? q : 10;
    m_seq   = qEnvironmentVariable("LEZ_SEQUENCER", "https://testnet.lez.logos.co").trimmed();
    m_payToB58 = hexToB58(m_payTo);
    if (m_access == "lez" && m_payTo.isEmpty())
        qWarning() << "ProviderPlugin: INFERENCE_ACCESS=lez but no INFERENCE_PAY_TO"
                   << "— clients can't pay; set a PUBLIC LEZ account id (64 hex)";

    qDebug() << "ProviderPlugin: created, id =" << m_id
             << "model =" << m_model << "ollama =" << m_ollamaUrl
             << "maxInflight =" << m_maxInflight
             << "access =" << m_access
             << (m_access == "pow" ? QString("(%1 bits)").arg(m_powBits) : QString());
}

// Hashcash: leading zero bits of SHA-256(promptId|providerId|nonce) must meet
// the advertised difficulty. Binding to promptId+providerId stops stamp reuse
// across prompts or providers; verification is one hash.
static int leadingZeroBits(const QByteArray& digest)
{
    int bits = 0;
    for (const char cc : digest) {
        const unsigned char c = static_cast<unsigned char>(cc);
        if (c == 0) { bits += 8; continue; }
        for (int b = 7; b >= 0 && !((c >> b) & 1); --b) ++bits;
        break;
    }
    return bits;
}

bool ProviderPlugin::powValid(const QString& promptId, const QString& nonce) const
{
    if (nonce.isEmpty() || nonce.size() > 64) return false;
    const QByteArray digest = QCryptographicHash::hash(
        (promptId + "|" + m_id + "|" + nonce).toUtf8(), QCryptographicHash::Sha256);
    return leadingZeroBits(digest) >= m_powBits;
}

// m_payTo's transparent balance, straight from the sequencer RPC (no LEZ
// module needed — the provider only ever READS). -1 on any error.
double ProviderPlugin::seqBalance()
{
    if (m_payToB58.isEmpty()) return -1.0;
    QProcess p;
    const QString body = QStringLiteral(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountBalance\",\"params\":[\"%1\"]}")
        .arg(m_payToB58);
    p.start("curl", {"-s", "-m", "10", "-X", "POST", m_seq,
                     "-H", "content-type: application/json", "-d", body});
    if (!p.waitForFinished(12000)) { p.kill(); return -1.0; }
    const QJsonValue r = QJsonDocument::fromJson(p.readAllStandardOutput())
                             .object().value("result");
    return r.isDouble() ? r.toDouble() : -1.0;
}

// PaymentBackend seam — per-session prepay. A prompt is served if its cred names
// a session (identified by its unique payment amount) that we've seen funded on
// m_payTo, and whose prompt quota isn't spent.
//
// We can only read the running balance (the sequencer exposes no per-tx
// history), so funding is confirmed by cumulative accounting: a new session is
// funded once m_payTo has received at least Σ(already-confirmed amounts) + this
// amount. Amounts are unique per session, so under light traffic this
// attributes credit deterministically. Known v1 limits: a truly concurrent pair
// of equal-value payments can't be told apart, and sessions don't survive a
// provider restart (the received funds fold into the fresh baseline). The robust
// upgrades are block-scanning deposits or a dedicated per-session sub-account.
//
// The mock backend (dev / macOS) skips the on-chain check so the paid flow runs
// end to end without a funded LEZ account.
bool ProviderPlugin::sessionEligible(const QJsonObject& cred)
{
    const QString key = cred.value("amount").toString();   // amount doubles as session id
    bool okNum = false;
    const double amount = key.toDouble(&okNum);
    if (!okNum || amount <= 0.0) return false;

    if (m_payBackend != "lez") return true;                // mock: any well-formed cred passes

    // Already-confirmed session → gate on remaining quota.
    auto it = m_sessions.find(key);
    if (it != m_sessions.end()) {
        if (it.value() >= m_quota) {
            qDebug() << "ProviderPlugin: session" << key << "quota spent (" << m_quota << ")";
            return false;
        }
        it.value()++;
        persistSessions();
        return true;
    }

    // New session → confirm the one-time payment actually landed on m_payTo.
    const double bal = seqBalance();
    if (bal < 0.0) { qWarning() << "ProviderPlugin: can't read payTo balance — declining"; return false; }
    if (m_startBalance < 0.0) m_startBalance = bal;        // late baseline if start() couldn't
    const double received = bal - m_startBalance;
    if (received + 1e-9 < m_confirmedTotal + amount) {
        qDebug() << "ProviderPlugin: session" << key << "unfunded (received" << received
                 << "need" << (m_confirmedTotal + amount) << ") — declining";
        return false;
    }
    m_confirmedTotal += amount;
    m_sessions.insert(key, 1);
    persistSessions();
    qInfo() << "ProviderPlugin: session" << key << "funded — unlocking" << m_quota << "prompts";
    return true;
}

// The paid-session ledger persists next to the node so a restart/redeploy
// doesn't wipe funded sessions (which would burn users' prepaid quota).
QString ProviderPlugin::sessionsPath() const
{
    const QString home = qEnvironmentVariable("HOME");
    return (home.isEmpty() ? QStringLiteral("/tmp") : home)
           + QStringLiteral("/.inference-provider-sessions.json");
}

void ProviderPlugin::persistSessions() const
{
    QJsonObject s;
    for (auto it = m_sessions.constBegin(); it != m_sessions.constEnd(); ++it)
        s[it.key()] = it.value();
    const QJsonObject o{{"payTo", m_payTo}, {"startBalance", m_startBalance},
                        {"confirmedTotal", m_confirmedTotal}, {"sessions", s}};
    QFile f(sessionsPath());
    if (f.open(QIODevice::WriteOnly))
        f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

void ProviderPlugin::loadSessions()
{
    QFile f(sessionsPath());
    if (!f.open(QIODevice::ReadOnly)) return;
    const QJsonObject o = QJsonDocument::fromJson(f.readAll()).object();
    // Only restore a ledger written for THIS payTo — a different account's
    // history (or a reconfigured provider) must start clean.
    if (o.value("payTo").toString() != m_payTo) return;
    m_startBalance   = o.value("startBalance").toDouble(-1.0);
    m_confirmedTotal = o.value("confirmedTotal").toDouble(0.0);
    const QJsonObject s = o.value("sessions").toObject();
    for (auto it = s.constBegin(); it != s.constEnd(); ++it)
        m_sessions.insert(it.key(), it.value().toInt());
    qInfo() << "ProviderPlugin: restored" << m_sessions.size() << "paid session(s), baseline"
            << m_startBalance << "confirmedTotal" << m_confirmedTotal;
}

ProviderPlugin::~ProviderPlugin() = default;

void ProviderPlugin::initLogos(LogosAPI* api)
{
    logosAPI = api;
    m_identity = new InferenceIdentity(logosAPI, "provider");
    // An identity may already exist on disk from a previous run.
    if (m_identity->isInitialized()) {
        m_id = m_identity->fingerprint();
        qDebug() << "ProviderPlugin: identity loaded, id =" << m_id;
    }
    qDebug() << "ProviderPlugin: LogosAPI wired up";
}

// Make sure this provider has a durable identity before it goes on the air.
// Priority: existing key file > $IMPORT_MNEMONIC > freshly created account.
// The Ed25519 fingerprint replaces the old random cli-llm-xxxx id, so the
// same provider keeps the same id across restarts (and it's spoof-resistant
// once announces are signed — PR2).
void ProviderPlugin::ensureIdentity()
{
    // A passphrase-protected key file needs IDENTITY_PASSPHRASE to unlock
    // (headless nodes have no prompt). Wrong/missing passphrase falls through
    // to the not-initialized path below, which refuses to overwrite the file.
    if (m_identity && m_identity->isLocked()) {
        const QString pass = qEnvironmentVariable("IDENTITY_PASSPHRASE");
        if (!m_identity->unlock(pass)) {
            qWarning() << "ProviderPlugin: identity key file is passphrase-protected"
                       << "and IDENTITY_PASSPHRASE didn't unlock it — running with"
                       << "the ephemeral id" << m_id;
            return;
        }
    }

    if (!m_identity || m_identity->isInitialized()) {
        if (m_identity && m_identity->isInitialized()) m_id = m_identity->fingerprint();
        return;
    }

    const QString importMnemonic = qEnvironmentVariable("IMPORT_MNEMONIC");
    if (!importMnemonic.isEmpty()) {
        if (m_identity->importAccount(importMnemonic,
                                      qEnvironmentVariable("IDENTITY_PASSPHRASE"))) {
            qInfo() << "ProviderPlugin: identity imported from IMPORT_MNEMONIC";
        } else {
            qWarning() << "ProviderPlugin: IMPORT_MNEMONIC import failed —"
                       << "creating a fresh identity instead";
        }
    }

    if (!m_identity->isInitialized()) {
        const QString mnemonic =
            m_identity->createAccount(qEnvironmentVariable("IDENTITY_PASSPHRASE"));
        if (!mnemonic.isEmpty()) {
            // The one and only time the mnemonic is visible. qInfo (not qDebug)
            // so it reaches the daemon log even at default verbosity.
            qInfo().noquote() << "\n"
                "──────────────────────────────────────────────────────────\n"
                " NEW PROVIDER IDENTITY — write this seed phrase down.\n"
                " It will not be shown again:\n\n   " + mnemonic + "\n"
                "──────────────────────────────────────────────────────────";
        }
    }

    if (m_identity->isInitialized()) {
        m_id = m_identity->fingerprint();
        qInfo() << "ProviderPlugin: identity ready, backend" << m_identity->backend()
                << "fingerprint" << m_id;
    } else {
        qWarning() << "ProviderPlugin: no identity — keeping ephemeral id" << m_id;
    }
}

QString ProviderPlugin::identityStatus()
{
    QJsonObject o;
    const bool init = m_identity && m_identity->isInitialized();
    o["initialized"] = init;
    o["locked"]      = m_identity && m_identity->isLocked();
    o["backend"]     = init ? m_identity->backend() : QString();
    o["fingerprint"] = init ? m_identity->fingerprint() : QString();
    o["signPk"]      = init ? QString::fromLatin1(m_identity->signPublicKey().toBase64()) : QString();
    o["boxPk"]       = init ? QString::fromLatin1(m_identity->boxPublicKey().toBase64()) : QString();
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString ProviderPlugin::createAccount(const QString& passphrase)
{
    if (!m_identity) return QString();
    const QString mnemonic = m_identity->createAccount(passphrase);
    if (m_identity->isInitialized()) m_id = m_identity->fingerprint();
    return mnemonic;
}

bool ProviderPlugin::importAccount(const QString& mnemonic, const QString& passphrase)
{
    if (!m_identity) return false;
    const bool ok = m_identity->importAccount(mnemonic, passphrase);
    if (ok) m_id = m_identity->fingerprint();
    return ok;
}

bool ProviderPlugin::start(const QString& room)
{
    const QString clean = room.trimmed().isEmpty() ? QStringLiteral("agora") : room.trimmed();

    ensureIdentity();

    if (m_started) {
        if (clean != m_room && m_deliveryClient) {
            invokeBool("unsubscribe", "unsubscribe", topicForRoom(m_room));
            m_room = clean;
            invokeBool("subscribe", "subscribe", topicForRoom(m_room));
        }
        return true;
    }
    m_room = clean;

    m_deliveryClient = logosAPI->getClient("delivery_module");
    if (!m_deliveryClient) {
        qWarning() << "ProviderPlugin: delivery_module client unavailable";
        return false;
    }

    if (!m_createNodeDone) {
        // Default to tcpPort 60010 so a standalone CLI node doesn't collide with a
        // co-running Basecamp delivery node on 60000. Override with INFERENCE_TCPPORT.
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
        int customPort = qEnvironmentVariableIntValue("INFERENCE_TCPPORT");
        if (customPort <= 0) customPort = 60010;
        cfgObj["tcpPort"]       = customPort;
        cfgObj["discv5UdpPort"] = 9000 + (customPort - 60000);
        const QString cfg = QString::fromUtf8(
            QJsonDocument(cfgObj).toJson(QJsonDocument::Compact));
        if (!invokeBool("createNode", "createNode", cfg)) return false;
        m_createNodeDone = true;
    }

    // Register the inbound handler BEFORE start so we don't miss anything.
    m_deliveryObject = m_deliveryClient->requestObject("delivery_module");
    if (m_deliveryObject) {
        m_deliveryClient->onEvent(m_deliveryObject, "messageReceived",
            [this](const QString&, const QVariantList& data) {
                handleMessageReceived(data);
            });
    } else {
        qWarning() << "ProviderPlugin: no delivery_module object — cannot hear prompts";
        return false;
    }

    if (!invokeBool("start", "start")) return false;
    m_started = true;

    // Restore any persisted paid sessions (same payTo); only baseline fresh when
    // there's no saved ledger — so a restart doesn't wipe funded sessions.
    if (m_access == "lez" && m_payBackend == "lez" && !m_payToB58.isEmpty()) {
        loadSessions();
        if (m_startBalance < 0.0) m_startBalance = seqBalance();   // no ledger → fresh baseline
        qInfo() << "ProviderPlugin: prepay pay-to" << m_payToB58
                << "baseline balance" << m_startBalance << "quota/session" << m_quota
                << "restored-sessions" << m_sessions.size();
    }

    if (!invokeBool("subscribe", "subscribe", topicForRoom(m_room))) return false;

    // Marketplace: also serve on our own session topic (any user who discovers
    // us can seal prompts straight to it — no shared room required), and
    // announce capability cards on the global discovery topic.
    if (m_identity && m_identity->isInitialized()) {
        if (!invokeBool("subscribe session", "subscribe", sessionTopic()))
            qWarning() << "ProviderPlugin: session topic subscribe failed —"
                       << "reachable via room only";
        if (!invokeBool("subscribe discovery", "subscribe", DISCOVERY_TOPIC))
            qWarning() << "ProviderPlugin: discovery subscribe failed —"
                       << "cards may not propagate";
    }

    // Announce this provider (fingerprint + keys + model + load) so users can
    // build a verified roster and seal prompts to our box key. Re-announced
    // every ~30s with jitter (announce traffic is the network's per-node fixed
    // cost — at N providers everyone carries N cards/interval, so the interval
    // is the scale knob; jitter stops fleet-wide announce synchronization).
    // Load *changes* still announce immediately (capacity edges below), so
    // routing stays fresh. Users expire entries after ~3 missed announces.
    if (!m_announceTimer) {
        m_announceTimer = new QTimer(this);
        m_announceTimer->setSingleShot(true);
        connect(m_announceTimer, &QTimer::timeout, this, [this]() {
            sendAnnounce();
            scheduleAnnounce();
        });
    }
    scheduleAnnounce();
    sendAnnounce();

    qDebug() << "ProviderPlugin:" << m_id << "listening on" << topicForRoom(m_room)
             << "model" << m_model;
    emit eventResponse("listening", QVariantList{ m_room, m_id, m_model });
    return true;
}

// Base interval ±20% jitter. INFERENCE_ANNOUNCE_MS overrides the base (handy
// for demos where 30s feels slow).
void ProviderPlugin::scheduleAnnounce()
{
    if (!m_announceTimer) return;
    int base = qEnvironmentVariableIntValue("INFERENCE_ANNOUNCE_MS");
    if (base <= 0) base = 30000;
    const int jitter = base / 5;   // ±20%
    m_announceTimer->start(base - jitter
                           + QRandomGenerator::global()->bounded(2 * jitter));
}

void ProviderPlugin::sendAnnounce()
{
    if (!m_started || !m_deliveryClient) return;
    if (!m_identity || !m_identity->isInitialized()) return;

    const QString signPk = QString::fromLatin1(m_identity->signPublicKey().toBase64());
    const QString boxPk  = QString::fromLatin1(m_identity->boxPublicKey().toBase64());
    const qint64  ts     = QDateTime::currentMSecsSinceEpoch();

    // Canonical signed bytes: pipe-joined fields, same order both sides.
    const QByteArray canon = QString("inference/v1/announce|%1|%2|%3|%4|%5|%6")
        .arg(m_id, signPk, boxPk, m_model,
             QString::number(m_inflight), QString::number(ts)).toUtf8();

    QJsonObject a;
    a["v"]      = 2;
    a["type"]   = "announce";
    a["id"]     = m_id;
    a["signPk"] = signPk;
    a["boxPk"]  = boxPk;
    a["model"]  = m_model;
    a["load"]   = m_inflight;
    a["ts"]     = ts;
    a["sig"]    = QString::fromLatin1(m_identity->sign(canon).toBase64());

    m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topicForRoom(m_room),
        QString::fromUtf8(QJsonDocument(a).toJson(QJsonDocument::Compact)));

    // v3 capability card on the global discovery topic. Same identity, richer
    // payload: every model served, capacity alongside load, and a price object.
    // `price` is the economics seam — {"scheme":"free"} today; when LEZ private
    // payments land, the scheme/terms change here and the signed canon already
    // covers them (no protocol bump needed).
    //
    // Deferred by 500ms rather than sent back-to-back with the v2 announce:
    // two immediate sends into delivery_module have crashed the daemon in the
    // wild (segfault in the send path — upstream issue; single sends are fine).
    const int inflightNow = m_inflight;
    QTimer::singleShot(500, this, [this, signPk, boxPk, inflightNow]() {
        if (!m_started || !m_deliveryClient) return;
        if (!m_identity || !m_identity->isInitialized()) return;
        sendCard(signPk, boxPk, inflightNow);
    });
}

void ProviderPlugin::sendCard(const QString& signPk, const QString& boxPk, int load)
{
    const qint64 ts = QDateTime::currentMSecsSinceEpoch();
    // The price/terms object rides inside the signed canon as opaque JSON, so
    // adding keys here needs no protocol bump. (Qt serializes object keys
    // alphabetically; the JS dashboard verifies against a parse→stringify of
    // the same bytes, so ordering stays consistent across implementations.)
    //   scheme — "free" (amount 0) or "lez" (payable via a LEZ note, later)
    //   amount — price per unit; unit — "request"|"1ktokens"; asset — LEZ id
    //   access — credential demand ("open"|"pow") + powbits when pow
    QJsonObject price;
    // access=lez ⇒ incentivized: advertise the LEZ pay account + stream rate so
    // clients open a LIP-155 stream to us; scheme flips to "lez".
    const bool paid = (m_access == "lez");
    price["scheme"] = (paid || m_priceAmount > 0.0) ? "lez" : "free";
    price["amount"] = m_priceAmount;
    price["unit"]   = m_priceUnit;
    price["asset"]  = m_priceAsset;
    price["access"] = m_access;
    if (m_access == "pow") price["powbits"] = m_powBits;
    if (paid) { price["payTo"] = m_payTo; price["rate"] = m_rate; price["quota"] = m_quota; }
    const QString priceJson = QString::fromUtf8(
        QJsonDocument(price).toJson(QJsonDocument::Compact));
    const QString modelsCsv = m_models.join(',');

    const QByteArray canon3 =
        QString("inference/v1/announce3|%1|%2|%3|%4|%5|%6|%7|%8")
            .arg(m_id, signPk, boxPk, modelsCsv,
                 QString::number(load), QString::number(m_maxInflight),
                 priceJson, QString::number(ts)).toUtf8();

    QJsonObject card;
    card["v"]      = 3;
    card["type"]   = "announce";
    card["id"]     = m_id;
    card["signPk"] = signPk;
    card["boxPk"]  = boxPk;
    card["models"] = QJsonArray::fromStringList(m_models);
    card["load"]   = load;
    card["cap"]    = m_maxInflight;
    card["price"]  = price;
    card["ts"]     = ts;
    card["sig"]    = QString::fromLatin1(m_identity->sign(canon3).toBase64());

    m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", DISCOVERY_TOPIC,
        QString::fromUtf8(QJsonDocument(card).toJson(QJsonDocument::Compact)));
}

bool ProviderPlugin::stop()
{
    if (!m_started) return true;
    if (m_announceTimer) m_announceTimer->stop();
    if (m_deliveryClient) {
        invokeBool("unsubscribe", "unsubscribe", topicForRoom(m_room));
        if (m_identity && m_identity->isInitialized()) {
            invokeBool("unsubscribe session", "unsubscribe", sessionTopic());
            invokeBool("unsubscribe discovery", "unsubscribe", DISCOVERY_TOPIC);
        }
        invokeBool("stop", "stop");
    }
    m_deliveryObject = nullptr;
    m_started = false;
    return true;
}

QString ProviderPlugin::stats()
{
    QJsonObject o;
    o["id"]            = m_id;
    o["room"]          = m_room;
    o["listening"]     = m_started;
    o["model"]         = m_model;
    o["models"]        = QJsonArray::fromStringList(m_models);
    o["sessionTopic"]  = sessionTopic();
    o["promptsSeen"]   = m_promptsSeen;
    o["responsesSent"] = m_responsesSent;
    o["inflight"]      = m_inflight;
    o["lastPromptId"]  = m_lastPromptId;
    o["lastFrom"]      = m_lastFrom;
    // Earnings (paid providers) — what this node has been paid, from the local
    // session ledger. Cheap: no RPC, just the in-memory confirmed totals.
    if (m_access == "lez") {
        int paidPrompts = 0;
        for (auto it = m_sessions.constBegin(); it != m_sessions.constEnd(); ++it)
            paidPrompts += it.value();
        o["payTo"]             = m_payTo;
        o["quotaPerSession"]   = m_quota;
        o["earned"]            = m_confirmedTotal;   // Σ funded session amounts (LEZ)
        o["sessionsFunded"]    = m_sessions.size();
        o["paidPromptsServed"] = paidPrompts;
    }
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QString ProviderPlugin::providerId() { return m_id; }

QString ProviderPlugin::topicForRoom(const QString& room) const
{
    return TOPIC_PREFIX + room + TOPIC_SUFFIX;
}

// Where this provider takes direct (marketplace) prompts: a topic derived from
// its own fingerprint, so discovery-roster users can reach it with no shared
// room. Responses go back on the same topic.
QString ProviderPlugin::sessionTopic() const
{
    return TOPIC_PREFIX + "p-" + m_id + TOPIC_SUFFIX;
}

void ProviderPlugin::handleMessageReceived(const QVariantList& data)
{
    // delivery_module.messageReceived: [hash, contentTopic, payload_base64, ts_ns]
    if (data.size() < 3) return;

    const QString topic = data[1].toString();
    // Prompts arrive on the shared room topic (legacy) or on our own session
    // topic (marketplace users who found us via discovery).
    const bool onSession = (topic == sessionTopic());
    if (topic != topicForRoom(m_room) && !onSession) return;

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

    const QJsonObject obj = doc.object();
    if (obj.value("type").toString() != "prompt") return;   // only answer prompts

    const QString id = obj.value("id").toString();
    if (id.isEmpty()) return;

    QString prompt;         // what we feed the model
    QString replyPkB64;     // v2: seal the response to this ephemeral key
    QString fromLabel;      // for stats/logs only
    QString reqModel;       // v3 marketplace prompts may request a model

    if (obj.value("v").toInt() >= 2) {
        // v2 sealed prompt: only for us, and only readable by us.
        if (obj.value("to").toString() != m_id) return;
        if (!m_identity || !m_identity->isInitialized()) return;

        const QByteArray sealed =
            QByteArray::fromBase64(obj.value("box").toString().toLatin1());
        const QByteArray inner = m_identity->open(sealed);
        if (inner.isEmpty()) {
            qWarning() << "ProviderPlugin: sealed prompt" << id
                       << "failed to open (wrong key or tampered) — dropping";
            return;
        }
        const QJsonDocument innerDoc = QJsonDocument::fromJson(inner);
        if (!innerDoc.isObject()) return;
        prompt     = innerDoc.object().value("prompt").toString();
        replyPkB64 = innerDoc.object().value("replyPk").toString();
        if (replyPkB64.isEmpty()) return;   // no way to answer privately
        fromLabel  = "sealed:" + replyPkB64.left(8);
        // Honour a requested model only if we actually serve it; otherwise the
        // default keeps the old single-model behaviour.
        reqModel = innerDoc.object().value("model").toString();
        if (!reqModel.isEmpty() && !m_models.contains(reqModel)) {
            qDebug() << "ProviderPlugin: prompt" << id << "requested model"
                     << reqModel << "we don't serve — using" << m_model;
            reqModel.clear();
        }
        // Credential seam: enforce this node's access policy. "pow" = hashcash
        // stamp; "lez" = an open LIP-155 payment stream to this provider
        // (incentivized). Future types (identity, voucher, RLN proof) slot in
        // the same way.
        if (m_access == "pow") {
            const QJsonObject cred = innerDoc.object().value("cred").toObject();
            if (cred.value("type").toString() != "pow" ||
                !powValid(id, cred.value("nonce").toString())) {
                qDebug() << "ProviderPlugin: prompt" << id
                         << "has no valid pow stamp (" << m_powBits
                         << "bits required) — declining";
                return;
            }
        } else if (m_access == "lez") {
            const QJsonObject cred = innerDoc.object().value("cred").toObject();
            if (cred.value("type").toString() != "lez-prepay" ||
                !sessionEligible(cred)) {
                qDebug() << "ProviderPlugin: prompt" << id
                         << "has no funded prepaid session — declining";
                return;
            }
        }
    } else {
        // v1 plaintext prompt (legacy UIs) — answered in plaintext as before.
        // Plaintext carries no credential, so it's only served by open nodes.
        if (m_access != "open") return;
        prompt    = obj.value("prompt").toString();
        fromLabel = obj.value("from").toString();
    }
    if (prompt.isEmpty()) return;

    // Dedup concurrent duplicate delivery: gossipsub can redeliver the same
    // message, and we don't want to run ollama twice (and double-count load)
    // for one id already in flight. (An id re-sent AFTER we've answered is
    // allowed through — that's a legitimate retry when our reply was lost.)
    if (m_inflightIds.contains(id)) {
        qDebug() << "ProviderPlugin: duplicate in-flight prompt" << id << "— ignoring";
        return;
    }

    // Concurrency cap: at capacity, decline (don't answer) so the user's
    // failover routes this prompt to a less-busy provider instead of it
    // queueing here past the timeout. Our next announce carries the true load,
    // so users stop picking us until we drain.
    if (m_inflight >= m_maxInflight) {
        qDebug() << "ProviderPlugin: at capacity (" << m_inflight << "/"
                 << m_maxInflight << ") — declining prompt" << id;
        return;
    }

    ++m_promptsSeen;
    ++m_inflight;
    m_inflightIds.insert(id);
    m_lastPromptId = id;
    m_lastFrom     = fromLabel;
    // Just hit the cap → announce "full" now instead of waiting up to 10s, so
    // users stop routing to us promptly. (Balances the drain-side re-announce
    // in sendResponse.)
    if (m_inflight == m_maxInflight) sendAnnounce();
    qDebug() << "ProviderPlugin: prompt" << id << "from" << fromLabel
             << (replyPkB64.isEmpty() ? "(plaintext)" : "(sealed)")
             << "→ running" << m_model;

    // Defer the inference so we don't block (and don't re-enter delivery_module
    // from inside its own event dispatch — delivery-guide gotcha #9). The actual
    // ollama call is async (QProcess), so it never blocks the event loop either.
    const QString topicCopy = topic;
    const QString modelCopy = reqModel.isEmpty() ? m_model : reqModel;
    QTimer::singleShot(0, this, [this, id, replyPkB64, prompt, modelCopy, topicCopy]() {
        runInference(id, replyPkB64, prompt, modelCopy, topicCopy);
    });
}

void ProviderPlugin::runInference(const QString& id, const QString& replyPkB64,
                                  const QString& prompt, const QString& model,
                                  const QString& topic)
{
    // Ask ollama via its HTTP API (the server is already running on $OLLAMA_URL).
    // We shell out to curl rather than link Qt Network, and pass the request body
    // on stdin (curl -d @-) so the prompt needs no shell escaping.
    QJsonObject req;
    req["model"]  = model;
    req["prompt"] = prompt;
    req["stream"] = false;
    // Thinking-mode models default to a long <think> preamble — minutes of
    // extra CPU tokens per answer on this class of hardware, easily blowing
    // the user's 90s retry window. Disable it (chat-sized answers don't need
    // it). Gated by family: ollama rejects think=false on non-thinking models.
    if (model.startsWith("qwen3") || model.startsWith("deepseek-r1"))
        req["think"] = false;
    // Bound answer length so an open-ended prompt ("what is liverpool") can't
    // ramble past the user's ~90s timeout on CPU (an 8B model runs ~7 tok/s
    // here, so 512 tokens ≈ 70s worst case). INFERENCE_NUM_PREDICT overrides.
    QJsonObject opts;
    const int np = qEnvironmentVariableIntValue("INFERENCE_NUM_PREDICT");
    opts["num_predict"] = np > 0 ? np : 512;
    req["options"] = opts;
    // Keep the model resident so a request after a lull doesn't pay a cold
    // reload on top of generation (the spike that pushed prompts over the
    // timeout). INFERENCE_KEEP_ALIVE overrides. ollama wants a NUMBER for
    // seconds (-1 = never unload) or a duration STRING ("30m"); a numeric
    // string like "-1" fails its duration parser, so send numerics as JSON
    // numbers and everything else as a string.
    const QString ka = qEnvironmentVariable("INFERENCE_KEEP_ALIVE", "30m");
    bool kaIsNum = false;
    const qlonglong kaNum = ka.toLongLong(&kaIsNum);
    if (kaIsNum) req["keep_alive"] = static_cast<double>(kaNum);
    else         req["keep_alive"] = ka;
    const QByteArray body = QJsonDocument(req).toJson(QJsonDocument::Compact);
    const QString url = m_ollamaUrl + "/api/generate";

    auto* proc  = new QProcess(this);
    auto* timer = new QElapsedTimer;
    timer->start();

    connect(proc, &QProcess::finished, this,
        [this, proc, timer, id, replyPkB64, model, topic](int exitCode, QProcess::ExitStatus) {
            const qint64 ms = timer->elapsed();
            delete timer;
            const QByteArray out = proc->readAllStandardOutput();
            const QByteArray errOut = proc->readAllStandardError();
            proc->deleteLater();

            QString text;
            QJsonParseError e{};
            const QJsonDocument d = QJsonDocument::fromJson(out, &e);
            if (e.error == QJsonParseError::NoError && d.isObject()) {
                const QJsonObject o = d.object();
                text = o.value("response").toString();
                if (text.isEmpty() && o.contains("error"))
                    text = "[model error] " + o.value("error").toString();
            }
            if (text.isEmpty()) {
                qWarning() << "ProviderPlugin: empty/invalid ollama reply (exit" << exitCode
                           << "):" << out.left(200) << errOut.left(200);
                text = "[inference failed — is ollama running and the model pulled?]";
            }
            qDebug() << "ProviderPlugin: inference for" << id << "done in" << ms
                     << "ms," << text.size() << "chars";
            sendResponse(id, replyPkB64, text.trimmed(), model, topic);
        });

    // If curl can't even start (missing binary), QProcess emits errorOccurred
    // and NOT finished — so the finished handler above would never run and
    // m_inflight would leak. Handle that one case explicitly. (Crashes after a
    // successful start still emit finished, so no double-send here.)
    connect(proc, &QProcess::errorOccurred, this,
        [this, proc, timer, id, replyPkB64, model, topic](QProcess::ProcessError err) {
            if (err != QProcess::FailedToStart) return;
            delete timer;
            proc->deleteLater();
            qWarning() << "ProviderPlugin: curl failed to start for" << id;
            sendResponse(id, replyPkB64,
                         "[inference failed — curl not found on the provider]",
                         model, topic);
        });

    // curl is at /usr/bin/curl on macOS / standard on Linux — on the base PATH.
    proc->start("curl", { "-sS", "--max-time", "180", url, "-d", "@-" });
    proc->write(body);
    proc->closeWriteChannel();
}

void ProviderPlugin::sendResponse(const QString& id, const QString& replyPkB64,
                                  const QString& text, const QString& model,
                                  const QString& topic)
{
    const bool wasFull = (m_inflight >= m_maxInflight);
    if (m_inflight > 0) --m_inflight;
    m_inflightIds.remove(id);
    // Just dropped below the cap → announce availability now so users can route
    // to us again without waiting for the next periodic announce.
    if (wasFull && m_inflight < m_maxInflight && m_started) sendAnnounce();
    if (!m_deliveryClient) return;

    QJsonObject resp;
    resp["id"]   = id;
    resp["from"] = m_id;

    if (!replyPkB64.isEmpty() && m_identity && m_identity->isInitialized()) {
        // v2: seal {text, model} to the prompt's ephemeral reply key. Only the
        // asker can read it; the signature binds it to this provider.
        QJsonObject inner;
        inner["text"]  = text;
        inner["model"] = model;
        const QByteArray sealed = InferenceIdentity::seal(
            QByteArray::fromBase64(replyPkB64.toLatin1()),
            QJsonDocument(inner).toJson(QJsonDocument::Compact));
        if (sealed.isEmpty()) {
            qWarning() << "ProviderPlugin: sealing response" << id << "failed — dropping";
            return;
        }
        const QString boxB64 = QString::fromLatin1(sealed.toBase64());
        const QByteArray canon =
            QString("inference/v1/response|%1|%2").arg(id, boxB64).toUtf8();
        resp["v"]    = 2;
        resp["type"] = "response";
        resp["box"]  = boxB64;
        resp["sig"]  = QString::fromLatin1(m_identity->sign(canon).toBase64());
    } else {
        // v1 plaintext response (legacy prompt had no reply key).
        resp["type"]  = "response";
        resp["text"]  = text;
        resp["model"] = model;
    }

    const QString payload = QString::fromUtf8(
        QJsonDocument(resp).toJson(QJsonDocument::Compact));

    const QVariant r = m_deliveryClient->invokeRemoteMethod(
        "delivery_module", "send", topic, payload);
    if (r.isValid()) {
        ++m_responsesSent;
        emit eventResponse("responseSent", QVariantList{ id });
    } else {
        qWarning() << "ProviderPlugin: response send RPC failed for" << id;
    }
}

bool ProviderPlugin::invokeBool(const char* what,
                                const QString& method,
                                const QVariant& arg)
{
    const QVariant r = arg.isValid()
        ? m_deliveryClient->invokeRemoteMethod("delivery_module", method, arg)
        : m_deliveryClient->invokeRemoteMethod("delivery_module", method);
    if (!r.isValid()) {
        qWarning() << "ProviderPlugin:" << what << "RPC failed (invalid QVariant)";
        return false;
    }
    if (r.canConvert<LogosResult>()) {
        const LogosResult lr = r.value<LogosResult>();
        if (!lr.success) {
            qWarning() << "ProviderPlugin:" << what << "failed:" << lr.error.toString();
            return false;
        }
        return true;
    }
    if (!r.toBool()) {
        qWarning() << "ProviderPlugin:" << what << "returned false:" << r;
        return false;
    }
    return true;
}
