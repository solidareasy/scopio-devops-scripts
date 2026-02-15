#!/bin/bash
set -e

# ── Deploy Scopio Workers to multiple machines ──────────────────────────────
# Copies the worker tarball and optionally starts workers via Tailscale SSH.
# No env files are deployed — env vars must already be set on each target.
#
# Usage:
#   yarn deploy:machines mac1 mac2 mac3 ...
#   DEPLOY_HOSTS="mac1 mac2 mac3" yarn deploy:machines
#
# Environment variables:
#   DEPLOY_HOSTS       — Space-separated list of hostnames/IPs
#   DEPLOY_USER        — SSH user (default: current user)
#   DEPLOY_DIR         — Remote install dir (default: ~/scopio-workers)
#   DEPLOY_START_CMD   — Worker command to run after deploy (optional)
#                        e.g. "broker --i2 --e4 --t1 --p8"
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARBALL="$ROOT_DIR/dist/scopio-workers.tar.gz"

DEPLOY_USER="${DEPLOY_USER:-$(whoami)}"
DEPLOY_DIR="${DEPLOY_DIR:-~/scopio-workers}"
DEPLOY_START_CMD="${DEPLOY_START_CMD:-}"

# Collect hosts from args or env
if [ $# -gt 0 ]; then
    HOSTS=("$@")
elif [ -n "$DEPLOY_HOSTS" ]; then
    read -ra HOSTS <<< "$DEPLOY_HOSTS"
else
    echo "Usage: $0 <host1> <host2> ... or set DEPLOY_HOSTS"
    exit 1
fi

# ── Verify tarball exists ───────────────────────────────────────────────────

if [ ! -f "$TARBALL" ]; then
    echo "[error] $TARBALL not found. Run 'yarn build:pack' first."
    exit 1
fi

SIZE=$(du -sh "$TARBALL" | cut -f1)
echo "[deploy] Deploying scopio-workers.tar.gz ($SIZE) to ${#HOSTS[@]} machines..."
echo "[deploy] No env files will be deployed."
echo ""

# ── Deploy to each host in parallel ─────────────────────────────────────────

deploy_to_host() {
    local host="$1"
    local target="$DEPLOY_USER@$host"

    echo "[$host] Uploading..."
    scp -o StrictHostKeyChecking=no "$TARBALL" "$target:/tmp/scopio-workers.tar.gz"

    echo "[$host] Extracting..."
    ssh -o StrictHostKeyChecking=no "$target" bash << REMOTEEOF
        set -e
        DEPLOY_DIR="$DEPLOY_DIR"

        # Stop existing workers
        if [ -f "\$DEPLOY_DIR/worker.pid" ]; then
            OLD_PID=\$(cat "\$DEPLOY_DIR/worker.pid")
            kill "\$OLD_PID" 2>/dev/null || true
            sleep 1
        fi

        # Extract
        rm -rf "\$DEPLOY_DIR"
        mkdir -p "\$DEPLOY_DIR"
        tar -xzf /tmp/scopio-workers.tar.gz -C "\$DEPLOY_DIR" --strip-components=1
        rm -f /tmp/scopio-workers.tar.gz

        echo "Extracted to \$DEPLOY_DIR"
REMOTEEOF

    # Start workers if command specified
    if [ -n "$DEPLOY_START_CMD" ]; then
        echo "[$host] Starting: worker.sh $DEPLOY_START_CMD"
        ssh -o StrictHostKeyChecking=no "$target" bash << REMOTEEOF
            set -e
            cd "$DEPLOY_DIR"
            nohup ./worker.sh $DEPLOY_START_CMD > worker.log 2>&1 &
            echo \$! > worker.pid
            echo "Started (pid=\$!)"
REMOTEEOF
    fi

    echo "[$host] Done."
}

PIDS=()
for host in "${HOSTS[@]}"; do
    deploy_to_host "$host" &
    PIDS+=($!)
done

# Wait for all deployments
FAILED=0
for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then
        echo "[error] Deploy to ${HOSTS[$i]} failed."
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "[done] Deployed to all ${#HOSTS[@]} machines."
else
    echo "[warn] $FAILED/${#HOSTS[@]} deployments failed."
    exit 1
fi

echo ""
echo "To start workers manually on each machine:"
echo "  ssh user@host 'cd $DEPLOY_DIR && ./worker.sh broker --i2 --e4 --t1 --p8'"
echo ""
echo "Or run individual workers:"
echo "  ./worker.sh ingest --daemon --concurrency 2"
echo "  ./worker.sh embed  --daemon --concurrency 4"
echo "  ./worker.sh train  --daemon"
echo "  ./worker.sh predict --daemon --concurrency 8"
echo ""
echo "CLI (batch) mode:"
echo "  ./worker.sh ingest --in s3://scopio-driver/gold"
echo "  ./worker.sh embed  --in s3://scopio-driver/gold"
echo "  ./worker.sh train  --in s3://scopio-driver/gold"
