#!/bin/bash
set -e

# ── Undeploy Scopio Workers via Tailscale SSH ────────────────────────────────
# From your dev machine, stops workers and cleans one or more rent-a-mac machines:
#   1. Stops running worker process
#   2. Removes deploy directory entirely
#
# Usage:
#   yarn undeploy mac-mini-02
#   yarn undeploy mac-mini-01 mac-mini-02 mac-mini-03
#
# Environment variables:
#   DEPLOY_USER — SSH user on targets (default: rentamac)
#   DEPLOY_DIR  — Remote install dir (default: ~/Desktop/studio)
# ─────────────────────────────────────────────────────────────────────────────

DEPLOY_USER="${DEPLOY_USER:-rentamac}"
DEPLOY_DIR="${DEPLOY_DIR:-Desktop/studio}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

HOSTS=("$@")

if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "Usage: yarn undeploy <host1> [host2] [host3] ..."
    echo ""
    echo "Examples:"
    echo "  yarn undeploy mac-mini-02"
    echo "  yarn undeploy mac-mini-01 mac-mini-02 mac-mini-03"
    exit 1
fi

echo ""
echo "[undeploy] ${#HOSTS[@]} machine(s): ${HOSTS[*]}"
echo ""

# ── Undeploy from a single host ─────────────────────────────────────────────

undeploy_host() {
    local host="$1"
    local target="$DEPLOY_USER@$host"

    echo "[$host] Cleaning up..."

    ssh $SSH_OPTS "$target" bash -s << REMOTEEOF
        set -e
        DEPLOY_DIR="\$HOME/$DEPLOY_DIR"

        # ── 1. Stop workers ──
        if tmux has-session -t studio 2>/dev/null; then
            tmux kill-session -t studio
            echo "[stop] Killed tmux session 'studio'"
        else
            echo "[ok] No tmux session 'studio' found"
        fi

        # ── 2. Remove deploy directory ──
        if [ -d "\$DEPLOY_DIR" ]; then
            rm -rf "\$DEPLOY_DIR"
            echo "[clean] Removed \$DEPLOY_DIR"
        else
            echo "[ok] \$DEPLOY_DIR does not exist"
        fi

        echo "[done] Machine cleaned."
REMOTEEOF

    echo "[$host] Done."
}

# ── Run in parallel ─────────────────────────────────────────────────────────

PIDS=()
for host in "${HOSTS[@]}"; do
    undeploy_host "$host" &
    PIDS+=($!)
done

FAILED=0
for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then
        echo "[error] Undeploy on ${HOSTS[$i]} failed."
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "[done] Cleaned ${#HOSTS[@]} machine(s)."
else
    echo "[warn] $FAILED/${#HOSTS[@]} undeploys failed."
    exit 1
fi
