# Xenia

**Decentralized AI inference over the Logos messaging network.** A **user** (a
Basecamp app) sends a prompt into a content topic; a **provider** (a headless
[`logos-logoscore-cli`](https://github.com/logos-co/logos-logoscore-cli) node
running **ollama**) hears it, generates a completion then sends the response
back over the same topic. No inference server. No API key. No account.

> **Xenia** (ξενία) was the Greek rule of guest-friendship: a host fed then
> sheltered an arriving traveler *before* asking who they were. Service
> preceded identification. That inversion is the protocol here — a provider
> answers a sealed prompt from an asker it cannot identify, then forgets them.

> The idea in one line: **same content topic, two roles** — a GUI Basecamp app
> asks, a headless CLI node answers with a local LLM.

```
   Basecamp (inference-ui + inference-core)         logoscore CLI (cli-provider)
   ────────────────────────────────────────        ───────────────────────────
   sendPrompt("explain CRDTs")  ──▶ delivery ─┐
                                               │  /inference/1/<room>/json
                                               ▼  (Logos delivery / Waku)
                                  ┌──────────────────────────┐
                                  │   content topic on the   │
                                  │     Logos delivery net    │
                                  └──────────────────────────┘
                                               │
   responseReceived ◀── delivery ◀── inference_provider ◀── ollama (tinyllama)
   (answer + latency)                  (listens, runs the model, replies)
```

Architecturally this is a **ping ⟷ pong** with the "pong" replaced by an LLM
completion — see
[part11-core-ping-pong](https://github.com/hackyguru/logos-workshop/tree/master/part11-core-ping-pong)
in the workshop series.

## Naming — Xenia is the brand, `inference` is the wire

The app presents itself as **Xenia**. The identifiers deliberately do **not**
follow. They should not be renamed casually:

| Identifier | Why it stays |
|---|---|
| `inference`, `inference_ui`, `inference_provider` | Module ids — the loader plus the flake inputs resolve dependencies by name |
| `/inference/1/…` topics | On the wire. Renaming splits the network until every node ships the new build |
| `inference/v1/sign`, `inference/v1/box` | Identity domain separators — they derive provider fingerprints, so changing them invalidates every existing identity plus any funded session |

## How it works

- **Rendezvous, two ways:**
  - *Room* (legacy/local): the shared topic `/inference/1/<room>/json` — both
    sides pick the same room then meet there.
  - *Marketplace* (discovery): providers publish **signed capability cards**
    (models served, load/capacity, price scheme) every ~30s (jittered; load
    changes announce immediately) on the well-known
    topic `/inference/1/discovery/json`, then take prompts on their **own
    session topic** `/inference/1/p-<fingerprint>/json`. Users browse the
    global roster to reach any provider anywhere — no shared room needed.
- **User (Basecamp):** `inference-core` (C++) builds a verified roster from
  announces (v2 room / v3 discovery), seals prompts E2E to the chosen
  provider (auto = least-loaded, or pinned, optionally filtered by model),
  then matches sealed responses by id to compute latency. `inference-ui`
  (QML) is a prompt/response chat screen with a marketplace browser.
- **Provider (CLI):** `cli-provider/inference-provider.sh` loads the
  `inference_provider` module into logoscore. On each prompt it runs
  `ollama` (via `curl $OLLAMA_URL/api/generate`, async) then publishes the
  answer on the topic the prompt arrived on. `INFERENCE_MODELS=a,b,c`
  advertises multiple models; sealed prompts may request any of them.
- **Identity:** one BIP-39 mnemonic derives an Ed25519 signing key plus an
  X25519 box key. A provider's id is `sha256(sign_pk)[0:20]` — self-certifying,
  so it can be verified locally with no registry, no chain, no trusted third
  party. It survives restarts; it is recoverable from the mnemonic alone.
- **Privacy:** what travels the network is `{v, type, to, id, box}` — no prompt
  text, no sender id. The reply key sealed inside is fresh per prompt, so two
  prompts from the same person are unlinkable.

See **[docs/BRIEF.md](docs/BRIEF.md)** for the design plus message protocol,
**[docs/RUN.md](docs/RUN.md)** to build, install then run it end to end, plus
**[docs/PAYMENTS.md](docs/PAYMENTS.md)** for the payment layer.

## Paid inference

Every v3 capability card carries a signed `price` object with `scheme`
(`free`/`lez`), `amount`, `unit` (`request`/`1ktokens`) plus `asset`. A provider
started with `INFERENCE_ACCESS=lez` **declines any prompt without a funded
session** — enforcement, not advertisement.

Payment is **per session rather than per prompt**, forced by settlement time: a
shielded transfer takes about a minute to prove, so one payment unlocks a quota
of prompts (`INFERENCE_QUOTA`, default 10). The user deshields a unique amount
from a *shielded* balance to the provider's public account; the provider
confirms it with a bare `getAccountBalance` read, so it needs no wallet module
of its own. The credential rides in the sealed envelope's `cred` slot — the same
slot the PoW stamp uses — so the network never sees it.

> **Honest limitation.** The rail works end to end on the hosted testnet, but in
> the shipped flow the provider's `payTo` is an account the *user's own wallet*
> controls, so value does not yet move between two independent parties. There is
> also no per-token metering: a three-word question and a 512-token essay each
> spend one quota slot. Both are covered in
> [docs/PAYMENTS.md](docs/PAYMENTS.md).

## Layout

```
xenia/
├── inference-core/        # C++ module — sends prompts, receives responses
│   ├── src/inference_interface.h  ·  inference_plugin.{h,cpp}
│   ├── CMakeLists.txt  metadata.json  flake.nix
├── inference-ui/          # QML UI — prompt box + response list + marketplace
│   ├── Main.qml  metadata.json  flake.nix  icons/inference.png
├── cli-provider/          # the headless provider, built from logoscore-cli
│   ├── provider-core/     # the inference_provider module (runs ollama)
│   ├── setup-modules.sh  inference-provider.sh  README.md
└── docs/                  # BRIEF.md (design + protocol)  ·  RUN.md (build + run)
                           # PAYMENTS.md (anonymous LEZ-paid inference)
```

## Quick start

```bash
# 1. provider (a machine with ollama): pull the model, stage + run
ollama pull tinyllama
cd cli-provider && ./setup-modules.sh && ./inference-provider.sh agora

# 2. user (Basecamp, on a machine with the Logos nix toolchain): build + install
cd ../inference-core && nix build '.#lgx-portable'
cd ../inference-ui   && nix build '.#lgx-portable'    # install both .lgx into Basecamp

# 3. in Basecamp: open "Xenia" → room "agora" → Start → type a prompt → Send
```

> `inference_ui`'s **installed** manifest must also list `logos_execution_zone`
> plus `persona_core`, or the wallet bar blocks on a replica that never appears
> then freezes the Basecamp shell. This is a deploy-time dependency, not a
> source one — see the deployment note in [docs/PAYMENTS.md](docs/PAYMENTS.md).

## Status

Working end to end. The prompt→ollama→response pipeline, the signed/sealed v2+v3
protocol, the marketplace roster plus the LEZ payment rail have all been
exercised on real nodes across two machines. See **Honest limitation** above for
what payment does *not* yet prove, plus `docs/PAYMENTS.md` for the path to
bilateral anonymity — that one is blocked on wiring rather than on a wall.

## Contributing

Most useful first: **run a provider.** A laptop with ollama plus a shell script
joins the marketplace — no approval, no listing fee. Bring a model nobody else
is serving.

After that, in rough order of difficulty:

- **Attack the threat model.** Prompts unreadable, providers unable to lie about
  their identity, prompts unlinkable across sessions, payment that does not name
  the buyer — all of these are claims. The sealed-box construction plus the
  announce verification path are where I would start.
- **Make the money genuinely move.** Advertise the provider's shielded receiving
  address, verify eligibility by note scan instead of a public balance read,
  then pay with a private transfer rather than a deshield. The receiving side is
  already proven to work.
- **Per-deposit attribution.** Retire the amount-as-session-id workaround the
  circuit's missing memo field forced.
- **Reputation that is not a whitelist.** Today trust is a curated list plus
  canary audits. That is a floor, not a system.
