# deploy/ — host cli-provider on an Oracle Cloud Always-Free A1 VM

Runs the Xenia inference provider 24/7 for $0: a `VM.Standard.A1.Flex`
(4 OCPU / 24 GB, aarch64 Ubuntu 24.04) running ollama + the logoscore daemon.

## One-time: Oracle auth (manual, ~5 min)

1. Account: [oracle.com/cloud/free](https://www.oracle.com/cloud/free/) (credit
   card for verification; Always-Free resources never charge).
2. API key: `oci setup config` — accept the defaults, let it generate a key
   pair, then paste the printed **public** key into the OCI console under
   *Profile → My profile → API keys → Add API key → Paste public key*.
3. Check: `oci iam region-subscription list` returns JSON.

Use API-key auth (not `oci session authenticate`) — capacity hunting can
outlive a browser session token.

## Provision + deploy

```bash
cd xenia/cli-provider/deploy
./provision-oracle-a1.sh     # network + A1 instance; retries "Out of host capacity" up to 4h
./deploy-provider.sh         # rsync, nix-build logoscore + modules on the VM, systemd service
```

`provision` writes the instance OCID/IP to `.instance.env` (git-ignored) and
won't double-provision. `deploy` is re-runnable — edit code locally, run it
again.

## Day-2

```bash
source .instance.env
ssh ubuntu@$PUBLIC_IP journalctl -fu inference-provider   # provider logs
ssh ubuntu@$PUBLIC_IP systemctl restart inference-provider
ROOM=demo ./deploy-provider.sh                            # redeploy on another room
```

## Gotchas

- **"Out of host capacity"** is chronic for free-tier A1 in popular regions.
  The script sweeps every AD and retries for `MAX_MINUTES` (default 240).
  Off-peak hours work better; upgrading the account to pay-as-you-go (still
  $0 within Always-Free limits) reportedly gets priority *and* stops Oracle's
  idle-instance reclamation.
- **Idle reclamation**: Oracle reclaims Always-Free A1 instances on purely
  free accounts that sit under ~20% CPU. An inference provider that actually
  gets prompts is usually fine; PAYG upgrade removes the risk entirely.
- **First deploy is slow**: the VM nix-builds the logos stack (Nim/Rust waku
  deps) from source. If the build 403s fetching crates.io, it's the known
  zerokit cargo-vendor fetch issue — build the delivery module lgx locally
  with the UA-patched fetcher workaround and pass it in via
  `DELIVERY_LGX=… ./setup-modules.sh` on the VM instead.
- The Waku port (`60010/tcp`) is opened in both the OCI security list
  (provision script) and the instance iptables (cloud-init). If you change
  `INFERENCE_TCPPORT`, change both.
