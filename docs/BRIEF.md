# Xenia — Brief

## Goal

Run **AI inference as a Logos service**: an inference *user* (Basecamp module)
publishes a prompt to a content topic; an inference *provider* (headless logoscore
CLI node running a local LLM) consumes it, generates a completion with ollama, and
publishes the response. No central inference API — just Logos delivery between a
user and a provider, exactly like part11's ping/pong but with an LLM in the
responder.

## Architecture

```
        Basecamp (user)                              logoscore CLI (provider)
 ┌────────────────────────┐                    ┌──────────────────────────────┐
 │ inference-ui (QML)      │  logos.callModule  │ inference-provider.sh         │
 │   prompt box + Send ────┼──────────┐         │   logoscore load-module …     │
 │   response list         │          ▼         │   call inference_provider start│
 │ inference-core (C++)     │   sendPrompt()     │            │                  │
 │   delivery_module        │          │         │            ▼                  │
 └───────────┬─────────────┘          │         │   inference_provider (C++)    │
             │ delivery.send  {prompt} │         │     on prompt → ollama        │
             ▼                         │         │     curl /api/generate        │
   ╔══════════════════════════════════════════════════════╗   │                 │
   ║   content topic /inference/1/<room>/json (Waku)       ║   ▼                 │
   ╚══════════════════════════════════════════════════════╝  ollama (tinyllama)  │
             ▲                         │         │            │                  │
             │ delivery {response} ◀───┼─────────┼── delivery.send {response} ◀──┘
   inference-core.handleMessageReceived          └──────────────────────────────┘
```

Both ends `subscribe` to the identical topic; gossip routing carries the prompt
to the provider and the response back to the user.

## Identity (one account = one mnemonic)

Every node has an `InferenceIdentity` (see `inference_identity.{h,cpp}`, shared
verbatim by both cores). One BIP-39 mnemonic → a 32-byte root secret (via
`accounts_module`'s BIP-32 `m/44'/60'/0'/0/0`, or a random seed-file fallback);
from the root, HMAC-SHA256 domain separation derives:

| Domain | Key | Use |
|--------|-----|-----|
| `inference/v1/sign`         | Ed25519 | sign announces + responses |
| `inference/v1/box\|<epoch>` | X25519  | seal/open prompts (rotated daily) |
| `inference/v1/rln`          | —       | reserved (RLN membership, later) |

The **providerId is the fingerprint** `sha256(sign_pk)[0:20]` — self-certifying,
stable across restarts, recoverable from the mnemonic. Users never put their
identity on the wire. `accounts_module` signHash is broken, so *all* signing and
encryption happen in-plugin via OpenSSL. At rest only the root is stored
(`~/.logos-inference/identity-<role>.key`, chmod 600); with a passphrase it's
PBKDF2-SHA256 → ChaCha20-Poly1305 encrypted and the identity starts **locked**
until `unlock()`.

## Message protocol (v2 — signed + end-to-end encrypted)

JSON payloads on the shared topic. v1 plaintext (below) is still accepted as a
fallback so old UIs/providers interoperate.

**announce** (provider → topic, every 10s, signed, cleartext):
```json
{ "v":2, "type":"announce", "id":"<fingerprint>", "signPk":"<b64>", "boxPk":"<b64>",
  "model":"tinyllama", "load":0, "ts":1719300000000, "sig":"<ed25519 b64>" }
```
Users verify `id == fingerprint(signPk)` **and** the signature before trusting
`boxPk`, then keep a roster (entries expire after 30s). `load` = in-flight
prompts, used to pick the least-loaded provider.

**prompt** (user → topic, sealed to the chosen provider):
```json
{ "v":2, "type":"prompt", "to":"<providerId>", "id":"<uuid>", "box":"<sealed b64>" }
```
`box` = `seal(provider.boxPk, {prompt, replyPk})`. On the wire there is **no
prompt text and no sender id** — only routing crumbs. `replyPk` is a fresh
ephemeral X25519 key per prompt, so two prompts are unlinkable.

**response** (provider → topic, sealed to the reply key, signed):
```json
{ "v":2, "type":"response", "id":"<uuid>", "from":"<providerId>",
  "box":"<seal(replyPk,{text,model}) b64>", "sig":"<ed25519 b64>" }
```
The user opens `box` with the prompt's ephemeral secret and verifies `sig`
against the roster entry for `from`. Plaintext answers to sealed prompts are
rejected.

**Sealed-box construction** (ECIES, OpenSSL primitives): fresh X25519 keypair →
ECDH with recipient → HMAC-SHA256 KDF (bound to both public keys) →
ChaCha20-Poly1305. Wire bytes: `ephPk(32) ‖ ciphertext ‖ tag(16)`.

**v1 fallback** — `{type:"prompt", id, from, ts, prompt}` and
`{type:"response", id, from, text, model}` in cleartext. Used only when the user
has heard no live provider announce (and `requireEncryption` is off).

## n→n: roster, routing, failover

- **Many users, many providers** share one topic. Each provider announces; each
  user builds an independently-verified roster.
- **Routing**: prompts seal to the *preferred* provider if set and live, else the
  least-loaded live one (`setPreferredProvider("")` = auto).
- **Failover**: a user-side sweep (every 3s) re-sends any prompt unanswered for
  `INFERENCE_TIMEOUT_MS` (default 90s) to the next-best provider — fresh
  ephemeral key, same `id`, first answer wins — up to 2 retries, then marks it
  failed. `requireEncryption` makes `sendPrompt` refuse the plaintext fallback.
- **id** stays the correlation key; the provider only reacts to prompts, the user
  only to announces/responses (gossipsub doesn't echo your own publishes).

## How the provider runs the model

The `inference_provider` module, on `messageReceived` for a prompt:
1. **Defers** the work with `QTimer::singleShot(0, …)` — never call back into
   `delivery_module` from inside its own event dispatch (delivery-guide gotcha #9).
2. Runs ollama **asynchronously** via `QProcess`:
   `curl -sS $OLLAMA_URL/api/generate -d '{"model":"tinyllama","prompt":"…","stream":false}'`
   (request body on stdin → no shell escaping). Async so generation never blocks
   the node's event loop.
3. On `QProcess::finished`, parses `.response` and publishes the `response`
   message via `delivery_module.send` (safe here — outside delivery's dispatch).

Why `curl` and not Qt Network? It keeps the module's build to Qt Core only
(`QProcess` is Core), and the ollama server is already running on `$OLLAMA_URL`.
`curl` is on the base PATH (`/usr/bin/curl`); `ollama` at `/usr/local/bin/ollama`.

## Config / knobs

| Key | Default | Where |
|-----|---------|-------|
| topic room | `agora` | both sides — must match |
| `INFERENCE_MODEL` | `tinyllama` | provider (ollama model) |
| `OLLAMA_URL` | `http://localhost:11434` | provider |
| `INFERENCE_TCPPORT` | provider `60010`, Basecamp `60000` | Waku port (distinct so both run on one machine) |
| `LOGOS_IDENTITY_DIR` | `~/.logos-inference` | where the identity key file lives |
| `IMPORT_MNEMONIC` | — | provider: import this seed on first start instead of creating one |
| `IDENTITY_PASSPHRASE` | — | provider: unlock a passphrase-protected key file (headless) |
| `INFERENCE_TIMEOUT_MS` | `90000` | user: retry a prompt to the next provider after this |

## Key constraints (shared with part11)

- **Dev variant required.** The standalone logoscore CLI loads modules via a dev
  `logos_host` and looks up `manifest.main["darwin-arm64-dev"]`; `setup-modules.sh`
  builds the `.#lgx` (dev) packages for both `delivery_module` and
  `inference_provider`.
- **Two cores coexist** on one machine (instance-scoped Qt sockets) — the provider
  daemon and Basecamp run together with different Waku ports.
- **Network reachability.** Prompt↔response only flows once the two delivery nodes
  peer on the configured network (the logos.dev/bootstrap caveat from part11
  applies here too).

## Files of interest

- `cli-provider/provider-core/src/provider_plugin.cpp` — the prompt → ollama →
  response pipeline.
- `inference-core/src/inference_plugin.cpp` — send prompt, match response, latency.
- `inference-ui/Main.qml` — the prompt/response screen.
