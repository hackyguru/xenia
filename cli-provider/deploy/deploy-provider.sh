#!/usr/bin/env bash
#
# deploy-provider.sh — push cli-provider to the Oracle A1 VM, build the stack
# there (logoscore CLI + modules, all aarch64-linux via nix), and install a
# systemd service so the provider survives reboots.
#
# Reads deploy/.instance.env (written by provision-oracle-a1.sh), or:
#   ./deploy-provider.sh <public-ip>
#
# Tunables:
#   ROOM=agora INFERENCE_MODEL=tinyllama ./deploy-provider.sh
#   LOGOSCORE_REV=<sha>   logoscore-cli rev to build (default: the rev verified
#                         against this repo's provider on 2026-07-03)
#
# The first run nix-builds Qt-adjacent logos deps from source on the VM —
# expect it to take a while (run inside tmux/ssh keepalive is set).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="$(dirname "$HERE")"   # …/cli-provider

ROOM="${ROOM:-agora}"
INFERENCE_MODEL="${INFERENCE_MODEL:-tinyllama}"
# Marketplace capability card: all models served (csv, first = default).
INFERENCE_MODELS="${INFERENCE_MODELS:-$INFERENCE_MODEL}"
# Access policy: open (default) or pow (anonymous prompts need a hashcash stamp).
INFERENCE_ACCESS="${INFERENCE_ACCESS:-open}"
INFERENCE_POW_BITS="${INFERENCE_POW_BITS:-18}"
# Pricing (0 = free; the LEZ-ready seam).
INFERENCE_PRICE="${INFERENCE_PRICE:-0}"
INFERENCE_PRICE_UNIT="${INFERENCE_PRICE_UNIT:-request}"
INFERENCE_PRICE_ASSET="${INFERENCE_PRICE_ASSET:-}"
# Generation tuning: cap answer length (bounds worst-case time vs the client
# timeout) and keep the model resident ("-1" = never unload; 16GB fits both).
INFERENCE_NUM_PREDICT="${INFERENCE_NUM_PREDICT:-512}"
INFERENCE_KEEP_ALIVE="${INFERENCE_KEEP_ALIVE:-30m}"
# Incentivization (INFERENCE_ACCESS=lez): provider LEZ pay account + stream rate.
INFERENCE_PAY_TO="${INFERENCE_PAY_TO:-}"
INFERENCE_RATE="${INFERENCE_RATE:-1}"
INFERENCE_PAY_BACKEND="${INFERENCE_PAY_BACKEND:-mock}"
INFERENCE_TCPPORT="${INFERENCE_TCPPORT:-60010}"
# pre-release-679a9af — the generation verified working with inference-provider.sh
LOGOSCORE_REV="${LOGOSCORE_REV:-679a9af8fd0064c2997c2ea3ed1fa53b422bfe0d}"

c_cyan=$'\033[36m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'
log() { printf '%s[deploy]%s %s\n' "$c_cyan" "$c_off" "$*"; }
ok()  { printf '%s[deploy]%s %s\n' "$c_grn" "$c_off" "$*"; }
die() { printf '%s[deploy] %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

IP="${1:-}"
if [[ -z "$IP" && -f "$HERE/.instance.env" ]]; then
    # shellcheck disable=SC1091
    source "$HERE/.instance.env"
    IP="${PUBLIC_IP:-}"
fi
[[ -n "$IP" ]] || die "no target: run provision-oracle-a1.sh first, or pass an IP"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=10)
SSH=(ssh "${SSH_OPTS[@]}" "ubuntu@$IP")

# ── wait for first-boot provisioning ─────────────────────────────────────────
log "waiting for ssh + cloud-init on ${IP}…"
for i in $(seq 1 60); do
    "${SSH[@]}" -o ConnectTimeout=5 true 2>/dev/null && break
    sleep 10
done
"${SSH[@]}" true || die "cannot ssh to ubuntu@$IP"
"${SSH[@]}" "cloud-init status --wait >/dev/null 2>&1 || true"
"${SSH[@]}" "test -f /var/lib/cloud/instance/logos-bootstrap-done" \
    || die "cloud-init bootstrap did not finish — check: ssh ubuntu@$IP sudo cat /var/log/cloud-init-output.log"
ok "VM bootstrapped (ollama + nix present)"

# ── push sources ─────────────────────────────────────────────────────────────
log "rsyncing cli-provider → ubuntu@$IP:~/cli-provider…"
rsync -az --delete \
    --exclude modules/ --exclude 'deploy/.instance.env' --exclude '*.log' \
    -e "ssh ${SSH_OPTS[*]}" \
    "$CLI_DIR/" "ubuntu@$IP:cli-provider/"

# ── build + install on the VM ────────────────────────────────────────────────
log "building logoscore CLI + modules on the VM (first run is long)…"
"${SSH[@]}" ROOM="$ROOM" INFERENCE_MODEL="$INFERENCE_MODEL" \
            INFERENCE_MODELS="$INFERENCE_MODELS" \
            INFERENCE_ACCESS="$INFERENCE_ACCESS" INFERENCE_POW_BITS="$INFERENCE_POW_BITS" \
            INFERENCE_PRICE="$INFERENCE_PRICE" INFERENCE_PRICE_UNIT="$INFERENCE_PRICE_UNIT" \
            INFERENCE_PRICE_ASSET="$INFERENCE_PRICE_ASSET" \
            INFERENCE_NUM_PREDICT="$INFERENCE_NUM_PREDICT" INFERENCE_KEEP_ALIVE="$INFERENCE_KEEP_ALIVE" \
            INFERENCE_PAY_TO="$INFERENCE_PAY_TO" INFERENCE_RATE="$INFERENCE_RATE" INFERENCE_PAY_BACKEND="$INFERENCE_PAY_BACKEND" \
            INFERENCE_TCPPORT="$INFERENCE_TCPPORT" LOGOSCORE_REV="$LOGOSCORE_REV" \
            'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

echo "[remote] nix build logoscore-cli @ $LOGOSCORE_REV ($(uname -m)-linux)…"
nix build "github:logos-co/logos-logoscore-cli/$LOGOSCORE_REV#cli" \
    -o "$HOME/.logoscore-cli" --print-build-logs
LOGOSCORE="$HOME/.logoscore-cli/bin/logoscore"
"$LOGOSCORE" --version || true

echo "[remote] staging modules (delivery_module + inference_provider)…"
cd "$HOME/cli-provider"
./setup-modules.sh

echo "[remote] installing systemd service…"
sudo tee /etc/systemd/system/inference-provider.service >/dev/null <<UNIT
[Unit]
Description=Xenia inference provider (logoscore + ollama)
After=network-online.target ollama.service
Wants=network-online.target ollama.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/cli-provider
Environment=LOGOSCORE=/home/ubuntu/.logoscore-cli/bin/logoscore
Environment=ROOM=$ROOM
Environment=INFERENCE_MODEL=$INFERENCE_MODEL
Environment=INFERENCE_MODELS=$INFERENCE_MODELS
Environment=INFERENCE_ACCESS=$INFERENCE_ACCESS
Environment=INFERENCE_POW_BITS=$INFERENCE_POW_BITS
Environment=INFERENCE_PRICE=$INFERENCE_PRICE
Environment=INFERENCE_PRICE_UNIT=$INFERENCE_PRICE_UNIT
Environment=INFERENCE_PRICE_ASSET=$INFERENCE_PRICE_ASSET
Environment=INFERENCE_NUM_PREDICT=$INFERENCE_NUM_PREDICT
Environment=INFERENCE_KEEP_ALIVE=$INFERENCE_KEEP_ALIVE
Environment=INFERENCE_PAY_TO=$INFERENCE_PAY_TO
Environment=INFERENCE_RATE=$INFERENCE_RATE
Environment=INFERENCE_PAY_BACKEND=$INFERENCE_PAY_BACKEND
Environment=INFERENCE_TCPPORT=$INFERENCE_TCPPORT
Environment=OLLAMA_URL=http://127.0.0.1:11434
Environment=DAEMON_LOG=/home/ubuntu/logoscore-inference.log
ExecStart=/home/ubuntu/cli-provider/inference-provider.sh
# always: the script exits 0 when the daemon dies underneath it (a daemon
# segfault must not leave the provider offline)
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable inference-provider
# restart (not enable --now): a redeploy must load the fresh modules even when
# the service is already running
sudo systemctl restart inference-provider
sleep 8
systemctl --no-pager --full status inference-provider | head -25 || true
REMOTE

ok "deployed. provider is answering room '$ROOM' with '$INFERENCE_MODEL'."
ok "watch it:   ssh ubuntu@$IP journalctl -fu inference-provider"
ok "test from Basecamp: Xenia → join room '$ROOM' → Start → send a prompt"
