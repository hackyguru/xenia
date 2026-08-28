# Xenia — Run

Two halves: the **provider** (`cli-provider/`, a headless logoscore node running
ollama) and the **user** (`inference-core` + `inference-ui` in Basecamp). They meet
on the content topic `/inference/1/<room>/json`.

---

## A. Provider — headless ollama node

Needs **ollama** with the model pulled, plus `logoscore`, `jq`, `curl`.

```bash
# ollama (the Ollama app running is enough, or:)
ollama serve &
ollama pull tinyllama

cd xenia/cli-provider
./setup-modules.sh                 # one-time: nix-builds the dev delivery_module + inference_provider
./inference-provider.sh agora      # answer prompts on /inference/1/agora/json
```

Expected:

```
[provider] ollama up, model 'tinyllama' available
[provider] daemon is up
[provider] inference_provider loaded
[provider] start(room=agora, model=tinyllama, tcpPort=60010)...
[provider] ready — answering prompts on /inference/1/agora/json with 'tinyllama'
[provider] provider id: cli-llm-1a2b
```

Leave it running. `Ctrl+C` stops it. Use a different model with
`INFERENCE_MODEL=llama3.2 ./inference-provider.sh`.

The `provider id` printed is now the identity **fingerprint** (a 40-hex string),
not `cli-llm-xxxx` — stable across restarts. On the very first run the provider
creates an identity and prints its **seed phrase once** into the daemon log
(`/tmp/logoscore-inference.log`); back it up. `setup-modules.sh` also stages
`accounts_module` from a local Basecamp install so the provider gets a real
BIP-39 mnemonic (else a random seed-file identity, no mnemonic).

Identity knobs (provider):

```bash
IMPORT_MNEMONIC="twelve words …" ./inference-provider.sh agora   # recreate a known identity
IDENTITY_PASSPHRASE=hunter2       ./inference-provider.sh agora   # unlock an encrypted key file
```

**Run a second provider** (n→n) — another model on another Waku port:

```bash
INFERENCE_TCPPORT=60030 INFERENCE_MODEL=llama3.2 \
  LOGOS_IDENTITY_DIR=~/.logos-inference-2 ./inference-provider.sh agora
```

Users see both in the roster and can pick between them (or let it auto-balance).

> First `setup-modules.sh` build pulls the delivery_module Nim/Rust deps and
> compiles two modules — minutes on a cold cache, cached after. Skip a rebuild by
> pointing at prebuilt packages: `DELIVERY_LGX=… PROVIDER_LGX=… ./setup-modules.sh`.

---

## B. User — Basecamp app

On a machine with the Logos nix toolchain:

```bash
cd xenia/inference-core && nix build '.#lgx-portable'
cd ../inference-ui                     && nix build '.#lgx-portable'
```

Install both resulting `.lgx` into Basecamp (Package Manager → install from file,
or the workshop reinstall drill). You'll get a **Xenia** app.

> Dependency wiring: `inference` declares `delivery_module`; `inference_ui`
> declares `inference`. The loader pulls `delivery_module` in automatically.

Runs fine alongside the provider on one machine: Basecamp's delivery node uses
Waku port `60000`, the provider uses `60010` (set via `INFERENCE_TCPPORT`).

---

## C. Drive it

1. Open **Xenia** in Basecamp.
2. **First run:** the amber card asks you to **Create new account** (shows the
   seed phrase once — write it down) or **Import** an existing one. A locked key
   file shows an **Unlock** card instead.
3. Set **Room** to `agora` (must match the provider) and **Join**.
4. **Start** — the status dot goes green (local node up).
5. Once a provider announce is heard, the chip shows `🔒 N provider(s) — prompts
   encrypted`. Optionally pick a specific **Provider** from the dropdown or tick
   **Require 🔒** to refuse the plaintext fallback.
6. Type a prompt, **Send prompt** (or Ctrl+Enter).

The entry shows `🤖 thinking… Ns` (with `(retry N)` if it failed over), then
flips to the answer with `🔒 E2E · tinyllama · <fingerprint> · NN ms`. If no
provider answers within `INFERENCE_TIMEOUT_MS` after 2 retries the card turns
red — pick another provider and resend. The provider terminal logs
`prompts: N · responses: N · last: <id> from sealed:XXXX`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `ollama not reachable` | Start ollama (`ollama serve` / the app) and check `OLLAMA_URL`. |
| `model 'tinyllama' not found` | `ollama pull tinyllama` (or set `INFERENCE_MODEL` to one you have). |
| `inference_provider not staged` | Run `./setup-modules.sh` first. |
| daemon won't start; capability_module crash | A stale daemon — `./inference-provider.sh` again, or `logoscore stop`. Basecamp running is fine. |
| `logoscore binary not found` | Put `logoscore` on PATH or set `LOGOSCORE=…`. The script auto-skips the newer `config-dir` CLI. |
| prompts stay `🤖 thinking…` forever | (1) Same room on both sides. (2) Give the two delivery nodes time to peer on the network. (3) Keep the provider running. (4) On one host, ensure distinct Waku ports (default 60000 vs 60010). After ~90s a prompt retries, then turns red if still unanswered. |
| chip says `⚠ no providers heard — prompts go plaintext` | No verified announce yet: provider not started, wrong room, or nodes not peered. Wait ~15s after Start; tick **Require 🔒** to block plaintext entirely. |
| `🔐 Identity locked` on the provider | The key file has a passphrase — set `IDENTITY_PASSPHRASE`. In Basecamp, use the **Unlock** card. |
| response is `[inference failed …]` | The provider reached ollama but generation failed — check the model is pulled and `curl $OLLAMA_URL/api/generate` works directly. |

## What was verified vs. needs a 2-node run

- **Verified locally**: ollama + tinyllama answer via `/api/generate`; the
  prompt→ollama→response pipeline and the message protocol.
- **Needs the real run**: the live cross-node prompt→response over the delivery
  network (provider node ↔ Basecamp node peering), same dependency as part11.
