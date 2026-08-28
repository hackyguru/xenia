#!/usr/bin/env bash
#
# provision-oracle-a1.sh — create an Always-Free Oracle Cloud Ampere A1 VM
# (4 OCPU / 24 GB, Ubuntu 24.04 aarch64) ready to host the Xenia inference
# provider. Idempotent-ish: reuses the VCN/subnet if they exist, and refuses
# to launch a second instance if deploy/.instance.env points at a live one.
#
# Prereqs: `oci` CLI configured with API-key auth (`oci setup config`), jq,
#          an ssh public key.
#
# Usage:
#   ./provision-oracle-a1.sh                 # 4 OCPU / 24 GB, retry up to 4h
#   OCPUS=2 MEM_GB=12 ./provision-oracle-a1.sh
#   MAX_MINUTES=1440 ./provision-oracle-a1.sh   # keep hunting capacity longer
#
# A1 capacity in popular regions is scarce — "Out of host capacity" is normal.
# The script cycles every availability domain and retries until MAX_MINUTES.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HERE/.instance.env"

PROFILE="${OCI_PROFILE:-DEFAULT}"
SHAPE="VM.Standard.A1.Flex"
# sizes to try per sweep, biggest first — smaller A1 requests land far more
# often when capacity is tight. "ocpus:memGB" pairs. tinyllama is happy at 1:6.
SIZES="${SIZES:-4:24 2:12 1:6}"
BOOT_GB="${BOOT_GB:-100}"
NAME="${NAME:-logos-inference-provider}"
SSH_PUB="${SSH_PUB:-$HOME/.ssh/id_ed25519.pub}"
MAX_MINUTES="${MAX_MINUTES:-240}"
RETRY_SLEEP="${RETRY_SLEEP:-90}"
WAKU_PORT="${WAKU_PORT:-60010}"

c_cyan=$'\033[36m'; c_grn=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'
log() { printf '%s[provision]%s %s\n' "$c_cyan" "$c_off" "$*"; }
ok()  { printf '%s[provision]%s %s\n' "$c_grn" "$c_off" "$*"; }
die() { printf '%s[provision] %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"
OCI="$(command -v oci || true)"
[[ -z "$OCI" && -x "$HOME/.nix-profile/bin/oci" ]] && OCI="$HOME/.nix-profile/bin/oci"
[[ -n "$OCI" ]] || die "oci CLI not found (nix profile add nixpkgs#oci-cli)"
[[ -f "$SSH_PUB" ]] || die "ssh public key not found: $SSH_PUB (set SSH_PUB=...)"
[[ -f "$HERE/cloud-init.yaml" ]] || die "cloud-init.yaml missing next to this script"

oci() { "$OCI" --profile "$PROFILE" "$@"; }

# ── auth / tenancy ───────────────────────────────────────────────────────────
[[ -f "$HOME/.oci/config" ]] || die "no ~/.oci/config — run: oci setup config"
TENANCY="$(awk -F= -v p="[$PROFILE]" '
    $0 == p {f=1; next} /^\[/ {f=0}
    f && $1 ~ /^tenancy/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$HOME/.oci/config")"
[[ -n "$TENANCY" ]] || die "no tenancy in ~/.oci/config profile [$PROFILE]"
C="$TENANCY"   # free-tier accounts: work in the root compartment
C="${COMPARTMENT_OCID:-$C}"

log "verifying auth (profile: $PROFILE)…"
oci iam region-subscription list --tenancy-id "$TENANCY" >/dev/null \
    || die "oci auth failed — re-run 'oci setup config' (API-key auth)"
ok "authenticated"

# ── refuse to double-provision ───────────────────────────────────────────────
if [[ -f "$STATE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE"
    st="$(oci compute instance get --instance-id "${INSTANCE_ID:-x}" \
          --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    if [[ "$st" == "RUNNING" || "$st" == "PROVISIONING" || "$st" == "STARTING" ]]; then
        ok "instance already exists ($st): ${PUBLIC_IP:-?} — nothing to do"
        exit 0
    fi
    log "stale $STATE (instance state: ${st:-gone}) — re-provisioning"
fi

# ── network (get-or-create) ──────────────────────────────────────────────────
VCN_NAME="logos-provider-vcn"
VCN_ID="$(oci network vcn list -c "$C" --display-name "$VCN_NAME" \
          --query 'data[0].id' --raw-output 2>/dev/null || true)"
if [[ -z "$VCN_ID" || "$VCN_ID" == "null" ]]; then
    log "creating VCN $VCN_NAME (10.77.0.0/16)…"
    VCN_JSON="$(oci network vcn create -c "$C" --cidr-blocks '["10.77.0.0/16"]' \
        --display-name "$VCN_NAME" --dns-label logosprov \
        --wait-for-state AVAILABLE --query data)"
    VCN_ID="$(jq -r .id <<<"$VCN_JSON")"
else
    log "reusing VCN: $VCN_ID"
    VCN_JSON="$(oci network vcn get --vcn-id "$VCN_ID" --query data)"
fi
RT_ID="$(jq -r '."default-route-table-id"' <<<"$VCN_JSON")"
SL_ID="$(jq -r '."default-security-list-id"' <<<"$VCN_JSON")"

IGW_ID="$(oci network internet-gateway list -c "$C" --vcn-id "$VCN_ID" \
          --query 'data[0].id' --raw-output 2>/dev/null || true)"
if [[ -z "$IGW_ID" || "$IGW_ID" == "null" ]]; then
    log "creating internet gateway…"
    IGW_ID="$(oci network internet-gateway create -c "$C" --vcn-id "$VCN_ID" \
        --is-enabled true --display-name logos-provider-igw \
        --wait-for-state AVAILABLE --query data.id --raw-output)"
fi

log "routing 0.0.0.0/0 via internet gateway…"
oci network route-table update --rt-id "$RT_ID" --force --route-rules "[
  {\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}
]" >/dev/null

log "opening ingress: 22/tcp (ssh), $WAKU_PORT/tcp (waku), icmp…"
oci network security-list update --security-list-id "$SL_ID" --force \
  --ingress-security-rules "[
    {\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"isStateless\":false,
     \"tcpOptions\":{\"destinationPortRange\":{\"min\":22,\"max\":22}}},
    {\"protocol\":\"6\",\"source\":\"0.0.0.0/0\",\"isStateless\":false,
     \"tcpOptions\":{\"destinationPortRange\":{\"min\":$WAKU_PORT,\"max\":$WAKU_PORT}}},
    {\"protocol\":\"1\",\"source\":\"0.0.0.0/0\",\"isStateless\":false}
  ]" \
  --egress-security-rules '[
    {"protocol":"all","destination":"0.0.0.0/0","isStateless":false}
  ]' >/dev/null

SUBNET_ID="$(oci network subnet list -c "$C" --vcn-id "$VCN_ID" \
             --query 'data[0].id' --raw-output 2>/dev/null || true)"
if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
    log "creating public subnet 10.77.1.0/24…"
    SUBNET_ID="$(oci network subnet create -c "$C" --vcn-id "$VCN_ID" \
        --cidr-block 10.77.1.0/24 --display-name logos-provider-subnet \
        --dns-label provider --wait-for-state AVAILABLE \
        --query data.id --raw-output)"
fi
ok "network ready (subnet: $SUBNET_ID)"

# ── image: newest Ubuntu 24.04 for A1 (shape filter ⇒ aarch64) ──────────────
IMAGE_ID="$(oci compute image list -c "$C" \
    --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
    --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output 2>/dev/null || true)"
if [[ -z "$IMAGE_ID" || "$IMAGE_ID" == "null" ]]; then
    IMAGE_ID="$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" \
        --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
        --query 'data[0].id' --raw-output)"
fi
[[ -n "$IMAGE_ID" && "$IMAGE_ID" != "null" ]] || die "no Canonical Ubuntu image found for $SHAPE"
ok "image: $IMAGE_ID"

# ── launch, cycling ADs until capacity frees up ──────────────────────────────
# (while-read, not mapfile — macOS ships bash 3.2)
ADS=()
while IFS= read -r _ad; do [[ -n "$_ad" ]] && ADS+=("$_ad"); done \
    < <(oci iam availability-domain list -c "$TENANCY" | jq -r '.data[].name')
[[ ${#ADS[@]} -gt 0 ]] || die "no availability domains listed"
log "availability domains: ${ADS[*]}"

deadline=$(( $(date +%s) + MAX_MINUTES*60 ))
attempt=0
INSTANCE_ID=""
while [[ -z "$INSTANCE_ID" ]]; do
    for SIZE in $SIZES; do
    OCPUS="${SIZE%%:*}"; MEM_GB="${SIZE##*:}"
    for AD in "${ADS[@]}"; do
        attempt=$((attempt+1))
        log "attempt $attempt: launching $SHAPE ($OCPUS ocpu/${MEM_GB}GB) in ${AD}…"
        set +e
        OUT="$(oci compute instance launch -c "$C" \
            --availability-domain "$AD" \
            --shape "$SHAPE" \
            --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" \
            --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" \
            --assign-public-ip true \
            --display-name "$NAME" \
            --boot-volume-size-in-gbs "$BOOT_GB" \
            --ssh-authorized-keys-file "$SSH_PUB" \
            --user-data-file "$HERE/cloud-init.yaml" \
            --query data.id --raw-output 2>&1)"
        rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            INSTANCE_ID="$(tail -1 <<<"$OUT")"
            ok "launched: $INSTANCE_ID (AD: $AD, $OCPUS ocpu/${MEM_GB}GB)"
            break 2
        fi
        # Only clearly-fatal errors abort; anything transient (capacity,
        # timeouts, 429/5xx, flaky network) keeps the hunt alive.
        if grep -qiE "out of host capacity|out of capacity" <<<"$OUT"; then
            log "no capacity in $AD (normal for A1 free tier)"
        elif grep -qi "NotAuthorizedOrNotFound" <<<"$OUT"; then
            # free-tier A1 quota is often pinned to specific ADs; the others 404
            log "$AD not available to this tenancy (free tier is often single-AD) — skipping"
        elif grep -qiE "LimitExceeded|service limit" <<<"$OUT"; then
            die "service limit exceeded — you already use your free A1 quota (4 OCPU/24GB total). Lower OCPUS/MEM_GB or terminate the other A1 instance. Raw: $OUT"
        elif grep -qiE "NotAuthenticated|InvalidParameter|CannotParseRequest" <<<"$OUT"; then
            die "launch failed (non-retryable): $OUT"
        else
            log "transient error in $AD — will retry ($(head -3 <<<"$OUT" | tr '\n' ' '))"
        fi
    done
    done
    [[ -n "$INSTANCE_ID" ]] && break
    (( $(date +%s) < deadline )) || die "gave up after $MAX_MINUTES minutes of capacity hunting. Re-run to keep trying (or try at an off-peak hour / another region)."
    log "sleeping ${RETRY_SLEEP}s before the next AD sweep…"
    sleep "$RETRY_SLEEP"
done

# ── wait for RUNNING, grab the public IP ─────────────────────────────────────
log "waiting for RUNNING…"
for i in $(seq 1 60); do
    st="$(oci compute instance get --instance-id "$INSTANCE_ID" \
          --query 'data."lifecycle-state"' --raw-output)"
    [[ "$st" == "RUNNING" ]] && break
    sleep 10
done
[[ "${st:-}" == "RUNNING" ]] || die "instance did not reach RUNNING (state: ${st:-?})"

PUBLIC_IP="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
             --query 'data[0]."public-ip"' --raw-output)"
[[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "null" ]] || die "no public IP on the vnic"

cat > "$STATE" <<EOF
# written by provision-oracle-a1.sh — consumed by deploy-provider.sh
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
SUBNET_ID=$SUBNET_ID
VCN_ID=$VCN_ID
EOF

ok "instance up: ubuntu@$PUBLIC_IP  (state saved to deploy/.instance.env)"
ok "cloud-init now installs ollama/tinyllama/nix (takes ~5-10 min)."
ok "next: ./deploy-provider.sh"
