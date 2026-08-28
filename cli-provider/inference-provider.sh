#!/usr/bin/env bash
#
# inference-provider.sh — a headless AI inference provider running on the
# logos-logoscore-cli (https://github.com/logos-co/logos-logoscore-cli).
#
# It loads the `inference_provider` module into the logoscore daemon. That module
# subscribes to the inference content topic, and for every "prompt" it runs a
# local LLM via ollama (tinyllama) and sends back the "response" — entirely
# in-process (it wires delivery_module's messageReceived directly, the way
# Basecamp modules do). The user side runs in Basecamp (Xenia inference-ui/core).
#
#   prompt  (Basecamp)  ── /inference/1/<room>/json ──▶  ollama  (this CLI module)
#                       ◀──────────  response  ──────────
#
# Pipeline:
#   logoscore -D -m ./modules
#   logoscore load-module inference_provider          # pulls in delivery_module
#   logoscore call inference_provider start <room>    # createNode/start/subscribe + answer prompts
#   logoscore call inference_provider stats           # promptsSeen / responsesSent (polled below)
#
# Usage:
#   ./inference-provider.sh [room]                 # default room: agora
#   ROOM=demo ./inference-provider.sh
#   INFERENCE_MODEL=llama3.2 ./inference-provider.sh
#   OLLAMA_URL=http://host:11434 ./inference-provider.sh
#   INFERENCE_TCPPORT=60012 ./inference-provider.sh   # Waku TCP port (default 60010)
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOM="${1:-${ROOM:-agora}}"
TOPIC="/inference/1/${ROOM}/json"
export INFERENCE_TCPPORT="${INFERENCE_TCPPORT:-60010}"
export INFERENCE_MODEL="${INFERENCE_MODEL:-tinyllama}"
export OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
DAEMON_LOG="${DAEMON_LOG:-/tmp/logoscore-inference.log}"

c_cyan=$'\033[36m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_off=$'\033[0m'
log()  { printf '%s[provider]%s %s\n' "$c_cyan" "$c_off" "$*"; }
ok()   { printf '%s[provider]%s %s\n' "$c_grn"  "$c_off" "$*"; }
warn() { printf '%s[provider]%s %s\n' "$c_ylw"  "$c_off" "$*"; }
die()  { printf '%s[provider] %s%s\n' "$c_red"  "$*" "$c_off" >&2; exit 1; }

command -v jq   >/dev/null || die "jq is required (brew install jq / apt install jq)"
command -v curl >/dev/null || die "curl is required (the provider calls ollama over HTTP)"

# --- ollama preflight -------------------------------------------------------
log "checking ollama at $OLLAMA_URL (model: $INFERENCE_MODEL)…"
if ! curl -sS --max-time 5 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
    die "ollama not reachable at $OLLAMA_URL. Start it (the Ollama app, or 'ollama serve')."
fi
if ! curl -sS --max-time 5 "$OLLAMA_URL/api/tags" 2>/dev/null \
       | jq -e --arg m "$INFERENCE_MODEL" '.models[]?.name | startswith($m)' >/dev/null 2>&1; then
    warn "model '$INFERENCE_MODEL' not found in ollama. Pull it with: ollama pull $INFERENCE_MODEL"
    warn "continuing anyway — inferences will fail until the model is available."
else
    ok "ollama up, model '$INFERENCE_MODEL' available"
fi

# --- resolve the logoscore binary -------------------------------------------
# Two logoscore generations can be present in the nix store. This script drives
# the daemon.json-model CLI; the newer config-dir CLI advertises "config-dir" in
# --help and uses an incompatible daemon model. Pick the compatible one, not just
# the first glob hit. State-independent. An explicit LOGOSCORE always wins.
_ls_compatible() { ! "$1" --help 2>&1 | grep -q "config-dir"; }
if [[ -z "${LOGOSCORE:-}" ]]; then
    _cands=()
    command -v logoscore >/dev/null 2>&1 && _cands+=("$(command -v logoscore)")
    while IFS= read -r _c; do _cands+=("$_c"); done \
        < <(ls -d /nix/store/*-logos-logoscore-cli/bin/logoscore 2>/dev/null)
    for _c in ${_cands[@]+"${_cands[@]}"}; do
        [[ -x "$_c" ]] && _ls_compatible "$_c" && { LOGOSCORE="$_c"; break; }
    done
    [[ -z "${LOGOSCORE:-}" ]] && for _c in ${_cands[@]+"${_cands[@]}"}; do
        [[ -x "$_c" ]] && { LOGOSCORE="$_c"; break; }
    done
fi
[[ -n "${LOGOSCORE:-}" && -x "$LOGOSCORE" ]] || \
    die "logoscore binary not found. Put it on PATH or set LOGOSCORE=/path/to/logoscore"
log "logoscore: $LOGOSCORE"

# --- modules dirs ------------------------------------------------------------
PROV_MODULES="$HERE/modules"
[[ -d "$PROV_MODULES/inference_provider" ]] || die "inference_provider not staged — run ./setup-modules.sh first"
[[ -d "$PROV_MODULES/delivery_module" ]]    || die "delivery_module not staged — run ./setup-modules.sh first"

# capability_module ships inside the logoscore bundle (next to the binary).
REAL_BIN="$(readlink -f "$LOGOSCORE" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$LOGOSCORE")"
CAP_MODULES="$(cd "$(dirname "$REAL_BIN")/../modules" 2>/dev/null && pwd || true)"
M_ARGS=(-m "$PROV_MODULES")
[[ -n "$CAP_MODULES" && -d "$CAP_MODULES/capability_module" ]] && M_ARGS+=(-m "$CAP_MODULES")

lc() { "$LOGOSCORE" "$@" 2>/dev/null; }
daemon_running() { lc status --json | jq -e '.daemon.status=="running"' >/dev/null 2>&1; }
stat_field() { lc call inference_provider stats | jq -r --arg k "$1" '.result|fromjson|.[$k]' 2>/dev/null; }

STARTED_DAEMON=0
cleanup() {
    echo
    log "shutting down..."
    if [[ "$STARTED_DAEMON" == "1" ]]; then
        lc call inference_provider stop >/dev/null 2>&1 || true
        lc stop >/dev/null 2>&1 || true
        ok "daemon stopped."
    else
        warn "left the pre-existing daemon running."
    fi
}
trap cleanup INT TERM EXIT

# --- 1. daemon ---------------------------------------------------------------
if daemon_running; then
    log "reusing the running logoscore daemon"
else
    log "starting logoscore daemon (log: $DAEMON_LOG)"
    : > "$DAEMON_LOG"
    "$LOGOSCORE" -D "${M_ARGS[@]}" >"$DAEMON_LOG" 2>&1 &
    STARTED_DAEMON=1
    for _ in $(seq 1 30); do daemon_running && break; sleep 0.5; done
    daemon_running || die "daemon did not come up. Last log:
$(tail -n 12 "$DAEMON_LOG" 2>/dev/null)"
fi
ok "daemon is up"

# --- 2. load the modules ------------------------------------------------------
# accounts_module is optional: with it the provider identity is a real BIP-39
# account (mnemonic backup); without it a random seed file is used.
if [[ -d "$PROV_MODULES/accounts_module" ]]; then
    log "loading accounts_module (identity backend)..."
    lc load-module accounts_module --json >/dev/null 2>&1 || true
    lc list-modules --json | jq -e '.[]|select(.name=="accounts_module" and .status=="loaded")' >/dev/null 2>&1 \
        && ok "accounts_module loaded" \
        || warn "accounts_module failed to load — identity falls back to a seed file"
fi

log "loading inference_provider..."
lc load-module inference_provider --json >/dev/null 2>&1 || true
lc list-modules --json | jq -e '.[]|select(.name=="inference_provider" and .status=="loaded")' >/dev/null 2>&1 \
    || die "inference_provider is not loaded — see $DAEMON_LOG"
ok "inference_provider loaded"

# --- 3. start answering prompts ---------------------------------------------
log "start(room=$ROOM, model=$INFERENCE_MODEL, tcpPort=$INFERENCE_TCPPORT)..."
res="$(lc call inference_provider start "$ROOM" | jq -r '.result // "false"' 2>/dev/null)"
[[ "$res" == "true" ]] || warn "start did not return true (see $DAEMON_LOG) — continuing"

id="$(lc call inference_provider providerId | jq -r '.result // ""' 2>/dev/null)"
idjson="$(lc call inference_provider identityStatus | jq -r '.result // "{}"' 2>/dev/null)"
backend="$(jq -r '.backend // "?"' <<<"$idjson" 2>/dev/null)"
ok "ready — answering prompts on $TOPIC with '$INFERENCE_MODEL'"
log "provider id: ${id:-?}  (identity backend: ${backend:-?})"
if [[ "$(jq -r '.initialized' <<<"$idjson" 2>/dev/null)" == "true" && "$backend" == "accounts_module" ]]; then
    log "identity is mnemonic-backed — if this is a fresh account, the seed phrase was printed in $DAEMON_LOG (once)."
fi
echo   "──────────────────────────────────────────────────────────────"
log "send prompts from Basecamp's \"Xenia\" app (same room). Ctrl+C to stop."

# --- 4. show live prompt/response counts ------------------------------------
last=-1
while true; do
    seen="$(stat_field promptsSeen)"; sent="$(stat_field responsesSent)"
    if [[ "${seen:-}" =~ ^[0-9]+$ && "$seen" != "$last" ]]; then
        from="$(stat_field lastFrom)"; pid="$(stat_field lastPromptId)"
        earned="$(stat_field earned)"; sess="$(stat_field sessionsFunded)"
        # Only show the earnings tail for paid (lez) nodes.
        pay=""
        [[ "${earned:-null}" != "null" && -n "${earned:-}" ]] \
            && pay="  ·  💰 earned ${earned} LEZ across ${sess:-0} session(s)"
        ok "prompts: $seen  ·  responses: ${sent:-0}  ·  last: ${pid:--} from ${from:--}${pay}"
        last="$seen"
    fi
    daemon_running || { warn "daemon went away"; break; }
    sleep 2
done
