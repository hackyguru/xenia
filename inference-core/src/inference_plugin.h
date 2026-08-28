#ifndef INFERENCE_PLUGIN_H
#define INFERENCE_PLUGIN_H

#include <QObject>
#include <QString>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QTimer>
#include <QVariant>
#include "inference_interface.h"
#include "inference_identity.h"
#include "logos_api.h"
#include "logos_api_client.h"
#include "logos_object.h"
#include "logos_sdk.h"

// One prompt I have sent, and the response (if it has come back yet).
struct PromptRec {
    QString id;
    QString prompt;
    qint64  sentMs   = 0;
    bool    answered = false;
    qint64  rttMs    = -1;
    QString text;          // the model's reply
    QString provider;      // who answered (from the response payload)
    QString model;         // which model produced it
    // E2E: one ephemeral X25519 secret PER attempt. Each sealed (re)send uses a
    // fresh reply key, and a valid answer may come from any provider we tried —
    // so we keep every secret and try them all when a response arrives (first
    // answer wins). Cleared only once answered. The matching public keys ride
    // inside the sealed prompts; nothing links two prompts to each other.
    QList<QByteArray> ephSks;
    bool    sealed   = false;
    // Failover: which providers we've already tried, and when we last sent.
    QStringList tried;
    int     retries    = 0;
    bool    failed     = false;
    qint64  lastSendMs = 0;
    // Canary audit: a trap prompt aimed at one provider (pin) requesting a
    // specific model (reqModel), graded against expect. Hidden from the UI.
    bool    canary     = false;
    QString expect;
    QString pin;
    QString reqModel;
    // Paid providers (access=lez): the prompt is parked here while its
    // prepaid session's one-time payment settles on-chain — not dispatched to
    // anyone until pollPayments() confirms the payment landed, then released.
    bool    waitPay    = false;
    QString payFp;             // provider we're paying for this prompt
    qint64  payStartMs = 0;    // when we began waiting (safety deadline)
    QString reason;            // why it failed (e.g. wallet not open), for the UI
};

// A provider we've heard a (signature-verified) announce from — either in the
// current room (legacy v2) or on the global discovery topic (v3 capability
// card). `topic` is where prompts for it go: the room topic for room
// providers, its own session topic for marketplace ones.
struct ProviderRec {
    QByteArray  signPk;     // Ed25519 — verifies its responses
    QByteArray  boxPk;      // X25519 — we seal prompts to this
    QString     model;      // primary model (first of models)
    QStringList models;     // every model served (v3; [model] for v2)
    QString     topic;      // where to send prompts for this provider
    QString     origin;     // "room" | "discovery"
    QString     price;      // price scheme: "free" | "lez"
    double      priceAmount = 0.0;  // per-unit price (0 = free)
    QString     priceUnit;          // "request" | "1ktokens"
    QString     priceAsset;         // LEZ asset id (empty until LEZ)
    QString     access;     // credential demand: "open" | "pow" | "lez"
    int         powBits    = 0;   // hashcash difficulty when access == "pow"
    QString     payTo;      // provider LEZ account (access == "lez")
    double      rate       = 0.0; // stream draw, TokensPerSecond (access == "lez")
    int         quota      = 0;   // prompts one prepaid session buys (access == "lez")
    int         cap        = 0;   // concurrency capacity (v3; 0 = unknown)
    int         load       = 0;
    qint64      lastSeenMs = 0;
    // Local reputation — this client's own experience, never from the wire.
    int         hits       = 0;   // sealed answers received
    int         misses     = 0;   // attempts that timed out unanswered
    // Integrity: canary audits of "did you run the model you advertised".
    int         audits       = 0;
    int         auditsPassed = 0;
    qint64      lastAuditMs   = 0;
};

class InferencePlugin : public QObject, public InferenceInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID InferenceInterface_iid FILE "metadata.json")
    Q_INTERFACES(InferenceInterface PluginInterface)

public:
    explicit InferencePlugin(QObject* parent = nullptr);
    ~InferencePlugin() override;

    QString name() const override { return "inference"; }
    QString version() const override { return "0.1.0"; }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    Q_INVOKABLE bool    startDelivery() override;
    Q_INVOKABLE bool    stopDelivery() override;
    Q_INVOKABLE int     deliveryStatus() override;

    Q_INVOKABLE bool    joinRoom(const QString& room) override;
    Q_INVOKABLE QString room() override;

    Q_INVOKABLE QString sendPrompt(const QString& prompt) override;

    Q_INVOKABLE QString listExchanges() override;
    Q_INVOKABLE bool    clearExchanges() override;
    Q_INVOKABLE QString myId() override;

    Q_INVOKABLE QString identityStatus() override;
    Q_INVOKABLE QString createAccount(const QString& passphrase) override;
    Q_INVOKABLE bool    importAccount(const QString& mnemonic,
                                      const QString& passphrase) override;
    Q_INVOKABLE QString listProviders() override;
    Q_INVOKABLE QString paymentStatus() override;
    Q_INVOKABLE bool    unlock(const QString& passphrase) override;
    Q_INVOKABLE bool    setRequireEncryption(bool required) override;
    Q_INVOKABLE bool    setPreferredProvider(const QString& fingerprint) override;
    Q_INVOKABLE bool    setModelFilter(const QString& model) override;
    Q_INVOKABLE bool    setTrustedOnly(bool enabled) override;
    Q_INVOKABLE bool    setTrusted(const QString& fingerprint, bool trusted) override;
    Q_INVOKABLE bool    auditProvider(const QString& fingerprint) override;

signals:
    void eventResponse(const QString& eventName, const QVariantList& args);

private:
    QString topicForRoom(const QString& room) const;
    QString providerTopic(const QString& fingerprint) const;
    void    handleMessageReceived(const QVariantList& data);
    void    handleAnnounce(const QJsonObject& obj);
    void    handleResponse(const QJsonObject& obj);
    const ProviderRec* pickProvider(QString& fpOut, const QStringList& exclude) const;
    static double scoreOf(const ProviderRec& p);
    static QString trustFilePath();
    void    loadTrust();
    void    saveTrust() const;
    static bool   computePow(const QString& promptId, const QString& providerFp,
                             int bits, QString& nonceOut);
    // Per-session prepay. Ensures a prepaid session to a paid provider: on first
    // use it fires a one-time deshield (private→public) of a unique amount to
    // the provider's public payTo via persona_core, then reports readiness once
    // pollPayments() sees the payment settle. amountOut is the session id.
    bool    ensureSession(const QString& providerFp, const ProviderRec& p,
                          QString& amountOut);
    double  seqBalance(const QString& payToHex) const;   // public balance via RPC (-1 err)
    void    pollPayments();                              // release parked prompts once funded
    bool    dispatchPrompt(PromptRec& rec);
    void    sweepPending();
    void    pruneHistory();
    void    setDeliveryStatus(int status);
    bool    invokeBool(const char* what, const QString& method,
                       const QVariant& arg = QVariant());
    static qint64 nowMs();

    QString           m_myId;
    QString           m_room = "agora";
    QList<PromptRec>  m_prompts;   // newest first
    QHash<QString, ProviderRec> m_providers;   // fingerprint → verified announce
    QSet<QString>     m_sessionSubs;           // provider session topics we joined
    QString           m_preferredProvider;     // "" = auto (least loaded)
    QString           m_modelFilter;           // "" = any model
    QSet<QString>     m_trusted;               // provider whitelist (🛡)
    bool              m_trustedOnly = false;   // enforce the whitelist
    // Prepaid sessions to paid providers (per-session prepay). providerFp → the
    // session's unique payment amount, the payTo balance baseline when we opened
    // it, and whether the payment has settled on-chain yet.
    struct PaySession { double amount = 0.0; double baseline = 0.0; bool ready = false; int used = 0; };
    QHash<QString, PaySession> m_sessions;
    QString           m_payBackend;
    QString           m_seq;                    // LEZ sequencer URL (LEZ_SEQUENCER)
    QString           m_payError;               // last "can't pay" reason (wallet not open, etc.)
    LogosAPIClient*   m_walletClient = nullptr; // persona_core (makes the payment)
    QTimer*           m_payTimer     = nullptr; // polls payTo until sessions fund
    bool              m_autoAudit   = false;   // opt-in (INFERENCE_AUTO_AUDIT); informational only
    bool              m_requireEncryption = false;
    qint64            m_timeoutMs = 90000;     // INFERENCE_TIMEOUT_MS override
    int               m_maxRetries = 2;
    QTimer*           m_sweepTimer = nullptr;

    LogosAPIClient* m_deliveryClient = nullptr;
    LogosObject*    m_deliveryObject = nullptr;
    InferenceIdentity* m_identity    = nullptr;
    int             m_deliveryStatus = 0;
    bool            m_started        = false;
    bool            m_createNodeDone = false;
    bool            m_subscribed     = false;
};

#endif
