#!/bin/bash
set -e

# ── Deploy Scopio Workers to machines via Tailscale SSH ──────────────────────
# Clones the build repo, writes .env, and starts workers on each target.
# Run from your dev machine after 'yarn build:pack'.
#
# Usage:
#   yarn deploy:machines mac-mini-01 mac-mini-02 mac-mini-03
#   yarn deploy:machines mac-mini-01 mac-mini-02 -- ingest --daemon --concurrency 4
#
# Environment variables (loaded from config/envs/<env>/common.envrc or set manually):
#   DEPLOY_USER        — SSH user on targets (default: rentamac)
#   DEPLOY_DIR         — Remote install dir (default: ~/Desktop/studio)
#   WORKER_CMD         — Worker command (default: broker --i2 --e4 --t1 --p8)
#   GH_TOKEN           — GitHub token to clone private build repo (required)
#
#   # .env written to each machine:
#   DATABASE_URL, REDIS_URL, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#   SCOPIO_DRIVER_BUCKET, SCOPIO_STUDIO_BUCKET
# ─────────────────────────────────────────────────────────────────────────────

BUILD_REPO="https://github.com/solidareasy/scopio-studio-build.git"
DEPLOY_USER="${DEPLOY_USER:-rentamac}"
DEPLOY_DIR="${DEPLOY_DIR:-~/Desktop/studio}"
WORKER_CMD="${WORKER_CMD:-broker --i2 --e4 --t1 --p8}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Parse hosts and optional worker command after --
HOSTS=()
for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        shift
        WORKER_CMD="$*"
        break
    fi
    HOSTS+=("$arg")
    shift
done

if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "Usage: $0 <host1> <host2> ... [-- worker_cmd]"
    echo ""
    echo "Examples:"
    echo "  yarn deploy:machines mac-mini-01 mac-mini-02 mac-mini-03"
    echo "  yarn deploy:machines mac-mini-01 -- ingest --daemon --concurrency 4"
    exit 1
fi

# Validate required env vars
MISSING=()
for var in GH_TOKEN DATABASE_URL REDIS_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY SCOPIO_DRIVER_BUCKET SCOPIO_STUDIO_BUCKET; do
    if [ -z "${!var}" ]; then MISSING+=("$var"); fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "[error] Missing required environment variables:"
    printf "  %s\n" "${MISSING[@]}"
    echo ""
    echo "Load your env first: source .envrc (or export them manually)"
    exit 1
fi

CLONE_URL="https://${GH_TOKEN}@github.com/solidareasy/scopio-studio-build.git"

echo "[deploy] Deploying to ${#HOSTS[@]} machines via Tailscale SSH"
echo "[deploy] Worker command: $WORKER_CMD"
echo "[deploy] Target dir: $DEPLOY_DIR"
echo ""

# ── Deploy to each host in parallel ─────────────────────────────────────────

deploy_to_host() {
    local host="$1"
    local target="$DEPLOY_USER@$host"

    echo "[$host] Connecting..."

    ssh $SSH_OPTS "$target" bash -s << REMOTEEOF
        set -e
        export PATH="/opt/homebrew/opt/node@22/bin:\$PATH"
        DEPLOY_DIR="$DEPLOY_DIR"

        # ── Stop existing workers ──
        if [ -f "\$DEPLOY_DIR/worker.pid" ]; then
            OLD_PID=\$(cat "\$DEPLOY_DIR/worker.pid")
            kill "\$OLD_PID" 2>/dev/null && echo "Stopped old worker (pid=\$OLD_PID)" || true
            sleep 1
        fi

        # ── Clone or pull ──
        if [ -d "\$DEPLOY_DIR/.git" ]; then
            echo "Updating repo..."
            cd "\$DEPLOY_DIR"
            git remote set-url origin "$CLONE_URL"
            git fetch origin main --force
            git reset --hard origin/main
        else
            echo "Cloning repo..."
            rm -rf "\$DEPLOY_DIR"
            git clone "$CLONE_URL" "\$DEPLOY_DIR"
        fi

        cd "\$DEPLOY_DIR"
        chmod +x worker.sh

        # ── Write .env ──
        cat > .env << 'ENVEOF'
DATABASE_URL=$DATABASE_URL
REDIS_URL=$REDIS_URL
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
SCOPIO_DRIVER_BUCKET=$SCOPIO_DRIVER_BUCKET
SCOPIO_STUDIO_BUCKET=$SCOPIO_STUDIO_BUCKET
ENVEOF
        chmod 600 .env
        echo ".env written"

        # ── Start workers ──
        echo "Starting: ./worker.sh $WORKER_CMD"
        nohup ./worker.sh $WORKER_CMD > worker.log 2>&1 &
        echo \$! > worker.pid
        echo "Started (pid=\$!)"
REMOTEEOF

    echo "[$host] Done."
}

PIDS=()
for host in "${HOSTS[@]}"; do
    deploy_to_host "$host" &
    PIDS+=($!)
done

# Wait for all
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
echo "Check logs:    ssh $DEPLOY_USER@<host> 'tail -f $DEPLOY_DIR/worker.log'"
echo "Stop workers:  ssh $DEPLOY_USER@<host> 'kill \$(cat $DEPLOY_DIR/worker.pid)'"
