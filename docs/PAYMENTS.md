# Xenia — Payments: anonymous LEZ-paid inference

Turn the free inference marketplace into a **paid** one, where a user pays a
provider for each session of inference over the **Logos Execution Zone (LEZ)** —
and the **user's money identity stays hidden**. No mocks: proven end to end
across two machines on the hosted testnet (`testnet.lez.logos.co`).

> One line: the user **deshields** a small amount from their *private* LEZ
> balance to the provider's *public* account, the provider **verifies the credit
> over a plain RPC read** before serving, and the payment buys a quota of prompts.

## Roles

```
   Alice — the user (Basecamp)                Bob — the provider (logoscore CLI)
   ─────────────────────────────             ──────────────────────────────────
   inference-ui + inference-core             inference_provider + ollama
   persona_core (LEZ)  ← pays from           reads payTo balance over RPC
   private, shielded balance                 (no wallet module needed)
```

- **Alice stays anonymous** — she pays with a *shielded* note; the sender is
  hidden by the zk circuit. Bob only ever sees "a public credit arrived."
- **Bob needs no wallet on his node** — he only *reads* his `payTo` account's
  balance via the sequencer RPC. Creating that account and spending its earnings
  need a Basecamp wallet elsewhere (see *Limitations*).

## Payment flow — per-session prepay

```
  Alice picks a paid provider ─────────────────────────────────────────────┐
                                                                            │
  ensureSession(): first prompt to that provider →                         │
     lezTransfer("deshielded", amount, payTo)  via persona_core            │  amount =
     (private → public; Alice shielded)                                     │  base + small
                          │                                                 │  random salt
                          ▼                                                 │  (= session id,
  ── deshield settles on testnet.lez.logos.co (~1 min zk proof) ──         │   binds pay→
                          │                                                 │   session; no
  prompt is PARKED until the credit lands ── pollPayments() watches         │   memo needed)
  the payTo balance via getAccountBalance RPC                               │
                          │                                                 │
                          ▼  credit seen                                    │
  prompt released, sealed with cred = {type:"lez-prepay", amount} ─────────┘
                          │
                          ▼
  Bob: sessionEligible(cred) — confirms the one-time payment landed on payTo,
       unlocks INFERENCE_QUOTA prompts for this session, runs ollama
                          │
                          ▼
  Alice gets a sealed answer.  Next prompts in the session are FREE until the
  quota is spent, then a new session (new payment) opens automatically.
```

Everything private (the prompt, the credential) rides inside the sealed
envelope (`box`), invisible to the network — the payment credential slots into
the same `cred` field as the pow/RLN credentials.

## Run it

**Provider** (env on top of the normal `inference-provider.sh` / deploy):

```bash
INFERENCE_ACCESS=lez                 # only answer prompts backed by a paid session
INFERENCE_PAY_BACKEND=lez            # real payments (not the "mock" dev backend)
INFERENCE_PAY_TO=<64-hex account id> # the provider's PUBLIC LEZ account (see below)
INFERENCE_QUOTA=10                   # prompts unlocked per paid session (default 10)
INFERENCE_PRICE=1                    # advertised price floor (per session)
INFERENCE_MODELS=tinyllama           # keep it fast — big models blow the client timeout
```

The provider only *reads* `payTo` over RPC, so it needs no wallet. But `payTo`
must be a **registered public LEZ account** — create one once in a Basecamp
`persona_core` ("+ Public" registers it on-chain) and paste its hex id here.

**User** (Basecamp): run the inference app with `INFERENCE_PAY_BACKEND=lez`, open
the **Logos Wallet** once (the wallet bar in the inference UI auto-opens it), and
make sure the LEZ wallet has a **private balance** (pinata → shield). Send a
prompt to a paid provider; the wallet bar + session line show the deshield
settling and the quota remaining.

## Why these choices

- **Per-session prepay, not per-request.** An on-chain LEZ transfer is a ~1-min
  zk proof — far too slow to gate every prompt. One payment buys a quota of
  prompts; only the first prompt of a session waits on settlement.
- **Not payment streams (LIP-155).** The intended primitive is
  [`lez-payment-streams`](https://github.com/logos-co/lez-payment-streams), but
  its program isn't deployed on the hosted testnet and can't be registered by a
  third party (`getProgramIds` lists only amm, authenticated_transfer, pinata,
  privacy_preserving_circuit, token; there is no register-program RPC). So we
  settle on the deployed `privacy_preserving_circuit` via a one-time deshield.
- **Amount as session id.** `transfer_deshielded`/`transfer_private` have no memo
  field, so the payment's (unique) amount doubles as the session identifier —
  the provider binds a payment to a session by matching the amount.
- **User-anonymous, provider public.** Keeping the provider's `payTo` transparent
  lets it verify with a bare RPC read (no LEZ module on the node). Shielding the
  provider too (bilateral anonymity) needs `logos_execution_zone` on its box.
- **Sessions persist.** The provider writes its session ledger to
  `~/.inference-provider-sessions.json`, so a restart/redeploy doesn't burn a
  user's prepaid quota.

## Limitations (honest)

- **Only the Basecamp-bundled LEZ module can *write* to the hosted testnet.** Its
  program image IDs match the deployed ones; a source build's don't, so its
  writes are silently dropped. This is why the *user* pays from Basecamp — and
  why a provider on the CLI can only *read*, never spend, its earnings.
- **`payTo` in the shipped (public) flow is not yet a genuinely independent Bob.**
  The provider's public account is one the *user's* wallet controls, so the money
  doesn't truly leave Alice. See the bilateral path below for the real fix.
- **Amount-collision edge case.** Two *concurrent* payments of the *same* amount
  can't be told apart under the running-balance accounting. Negligible with wide
  amounts on a funded wallet; a robust fix is per-deposit attribution via the
  zonescan indexer API (adds a third-party dependency).

## Bilateral anonymity (shielded provider) — proven feasible

The shipped flow is *user*-anonymous (the provider's account is public so it can
verify with a bare RPC read). Shielding the **provider** too — so neither party's
money identity is visible, and Bob is a genuinely independent earner — was long
assumed blocked by the build/reproducibility walls. **It isn't.** Verified
2026-07 on the Oracle (x86_64-linux) node:

- `logos_execution_zone` (**lez_core 0.3.0**) **builds** for `linux-amd64-dev`
  (`nix build …#lgx`) — the risc0/zerokit wall did not block it.
- It **loads** in the logoscore CLI beside `inference_provider`.
- Bob creates his **own** wallet (own seed), a **private** account, and
  `get_private_account_keys` → a shielded receiving address. All *local* key ops,
  so the write-wall doesn't apply.
- His node **syncs** the testnet (`sync_to_block` to tip) — which *is* the note
  trial-decrypt machinery, so incoming shielded notes are detected by the same
  path that already works.

The write-wall only blocks *spending* (Bob withdrawing) — not *receiving*, which
is all reads. So the remaining work is wiring, not a wall:

1. Provider advertises its shielded receiving address (compact reference; the raw
   keys are ~3 KB, too big for every capability card) and, on start, opens its
   lez_core wallet + syncs.
2. `sessionEligible` verifies by **note scan** (`sync_to_block` + `get_balance`
   on the private account) instead of the public RPC read.
3. The user pays with **`transfer_private`** to the provider's keys instead of
   `deshield`, and releases the parked prompt when the transfer completes (Bob's
   private balance isn't publicly pollable).

## Deployment note — the inference UI must load the wallet stack

Paid inference settles through `persona_core` (which drives
`logos_execution_zone`). Those must be **loaded** when the Xenia app
opens, or the wallet bar's remote calls block on a replica that never appears
("Timeout waiting for replica: persona_core") and freeze the whole Basecamp
shell. So `inference_ui`'s **manifest** must list them as dependencies:

```json
"dependencies": ["logos_execution_zone", "persona_core", "inference"]
```

The wallet-bar queries are also issued asynchronously as a second line of
defence, but the dependency is what actually prevents the stall (and removes the
separate "open the Logos Wallet app" trip — the stack loads with the app). This
isn't baked into `inference_ui`'s source `metadata.json` because `persona_core` (formerly `logos_wallet`)
lives in a separate tree (`logos-workshop`) and pinning a cross-repo flake input
is brittle; add it to the installed manifest at deploy time (Basecamp bundles
`logos_execution_zone`; install `persona_core` alongside).

## Where it lives

- User: `inference-core/src/inference_plugin.cpp` — `ensureSession`,
  `pollPayments`, `paymentStatus`, the sealed `lez-prepay` cred.
- Provider: `cli-provider/provider-core/src/provider_plugin.cpp` —
  `sessionEligible`, `seqBalance`, session persistence, earnings in `stats()`.
- UI: `inference-ui/Main.qml` — the wallet balance bar + live session status.
- Wallet: the `persona_core` module (the Persona wallet, github.com/hackyguru/persona) provides
  `lezTransfer` / `lezReceiveAddress` / balances.
