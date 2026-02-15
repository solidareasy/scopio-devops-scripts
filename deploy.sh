#!/bin/bash
set -e

# ── Deploy Scopio Workers via Tailscale SSH ──────────────────────────────────
# From your dev machine, deploys to one or more rent-a-mac machines:
#   1. Installs Node.js + Python if missing
#   2. Clones build repo from GitHub
#   3. Writes .env (secrets stay on target, never in git)
#   4. Sets up Python venv
#   5. Starts workers
#
# Prerequisites: target machine must be on Tailscale (run setup-tailscale.sh first)
#
# Usage:
#   yarn deploy mac-mini-02
#   yarn deploy mac-mini-01 mac-mini-02 mac-mini-03
#   WORKER_CMD="ingest --daemon --concurrency 4" yarn deploy mac-mini-05
#
# Environment variables:
#   DEPLOY_USER        — SSH user on targets (default: rentamac)
#   DEPLOY_DIR         — Remote install dir (default: ~/Desktop/studio)
#   WORKER_CMD         — Worker command (default: broker --i2 --e4 --t1 --p8)
#   GH_TOKEN           — GitHub token to clone private build repo (required)
#   DATABASE_URL       — PostgreSQL connection string (required)
#   REDIS_URL          — Redis connection string (required)
#   AWS_REGION         — AWS region (default: us-east-1)
#   AWS_ACCESS_KEY_ID  — AWS access key (required)
#   AWS_SECRET_ACCESS_KEY — AWS secret key (required)
#   SCOPIO_DRIVER_BUCKET  — S3 driver bucket (required)
#   SCOPIO_STUDIO_BUCKET  — S3 studio bucket (required)
#   NODE_VERSION       — Node.js version to install if missing (default: 22)
# ─────────────────────────────────────────────────────────────────────────────

DEPLOY_USER="${DEPLOY_USER:-rentamac}"
DEPLOY_DIR="${DEPLOY_DIR:-Desktop/studio}"
WORKER_CMD="${WORKER_CMD:-broker --i2 --e4 --t1 --p8}"
NODE_VERSION="${NODE_VERSION:-22}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

HOSTS=("$@")

if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "Usage: yarn deploy <host1> [host2] [host3] ..."
    echo ""
    echo "Examples:"
    echo "  yarn deploy mac-mini-02"
    echo "  yarn deploy mac-mini-01 mac-mini-02 mac-mini-03"
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
    exit 1
fi

CLONE_URL="https://${GH_TOKEN}@github.com/solidareasy/scopio-studio-build.git"

echo ""
echo "[deploy] ${#HOSTS[@]} machine(s): ${HOSTS[*]}"
echo "[deploy] Worker: $WORKER_CMD"
echo ""

# ── Deploy to a single host ─────────────────────────────────────────────────

deploy_to_host() {
    local host="$1"
    local target="$DEPLOY_USER@$host"

    echo "[$host] Deploying..."

    ssh $SSH_OPTS "$target" bash -s << REMOTEEOF
        set -e

        # ── PATH ──
        export PATH="/opt/homebrew/opt/node@$NODE_VERSION/bin:/opt/homebrew/bin:\$PATH"

        # ── 0. tmux ──
        if command -v tmux &>/dev/null; then
            echo "[ok] tmux \$(tmux -V)"
        else
            echo "[install] tmux..."
            brew install tmux >/dev/null 2>&1
            echo "[ok] tmux \$(tmux -V)"
        fi

        # ── 1. Node.js ──
        if command -v node &>/dev/null; then
            echo "[ok] Node.js \$(node -v)"
        else
            echo "[install] Node.js $NODE_VERSION..."
            if command -v brew &>/dev/null; then
                brew install node@$NODE_VERSION >/dev/null 2>&1
                export PATH="/opt/homebrew/opt/node@$NODE_VERSION/bin:\$PATH"
                grep -q "node@$NODE_VERSION" ~/.zshrc 2>/dev/null || \
                    echo 'export PATH="/opt/homebrew/opt/node@$NODE_VERSION/bin:\$PATH"' >> ~/.zshrc
            fi
            echo "[ok] Node.js \$(node -v)"
        fi

        # ── 2. Python 3.11+ ──
        NEED_PYTHON=false
        if command -v python3.11 &>/dev/null; then
            PYTHON_BIN=python3.11
        elif command -v python3 &>/dev/null; then
            PY_VER=\$(python3 -c "import sys; print(sys.version_info.minor)")
            if [ "\$PY_VER" -ge 11 ]; then
                PYTHON_BIN=python3
            else
                NEED_PYTHON=true
            fi
        else
            NEED_PYTHON=true
        fi

        if [ "\$NEED_PYTHON" = "true" ]; then
            echo "[install] Python 3.11..."
            brew install python@3.11 >/dev/null 2>&1 || true
            export PATH="/opt/homebrew/opt/python@3.11/libexec/bin:/opt/homebrew/opt/python@3.11/bin:\$PATH"
            PYTHON_BIN=python3.11
        fi
        echo "[ok] \$(\$PYTHON_BIN --version)"

        DEPLOY_DIR="\$HOME/$DEPLOY_DIR"

        # ── 3. Stop existing workers ──
        tmux kill-session -t studio 2>/dev/null && echo "[stop] Killed existing tmux session 'studio'" || true

        # ── 4. Clone or update repo ──
        if [ -d "\$DEPLOY_DIR/.git" ]; then
            echo "[git] Updating..."
            cd "\$DEPLOY_DIR"
            git remote set-url origin "$CLONE_URL" 2>/dev/null || true
            git fetch origin main --force --quiet
            git reset --hard origin/main --quiet
        else
            echo "[git] Cloning..."
            rm -rf "\$DEPLOY_DIR"
            git clone --quiet "$CLONE_URL" "\$DEPLOY_DIR" 2>/dev/null
        fi

        cd "\$DEPLOY_DIR"
        chmod +x worker.sh

        # ── 4b. Install Node.js dependencies ──
        echo "[deps] Installing Node.js dependencies..."
        cd "\$DEPLOY_DIR/packages/broker"
        npm install --production --ignore-scripts --quiet 2>&1 | tail -1
        cd "\$DEPLOY_DIR"
        echo "[ok] Node.js deps ready"

        # ── 5. Write .env ──
        cat > .env << 'ENVEOF'
DATABASE_URL=$DATABASE_URL
REDIS_URL=$REDIS_URL
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
SCOPIO_DRIVER_BUCKET=$SCOPIO_DRIVER_BUCKET
SCOPIO_STUDIO_BUCKET=$SCOPIO_STUDIO_BUCKET
ENVEOF
        chmod 600 .env
        echo "[ok] .env written"

        # ── 6. Setup Python venv (first deploy only) ──
        VENV_DIR="\$DEPLOY_DIR/packages/mlops/venv"
        if [ ! -d "\$VENV_DIR" ] || [ ! -f "\$VENV_DIR/bin/python" ]; then
            echo "[setup] Creating Python venv (this takes a few minutes on first deploy)..."
            \$PYTHON_BIN -m venv "\$VENV_DIR"
            "\$VENV_DIR/bin/pip" install --upgrade pip "setuptools<80" wheel --quiet
            "\$VENV_DIR/bin/pip" install --no-build-isolation -r "\$DEPLOY_DIR/packages/mlops/requirements.txt" --quiet
            if [ -d "\$DEPLOY_DIR/packages/model/src/python" ]; then
                "\$VENV_DIR/bin/pip" install -e "\$DEPLOY_DIR/packages/model/src/python" --quiet
            fi
            echo "[ok] Python venv ready"
        else
            echo "[ok] Python venv exists"
        fi

        # ── 7. Start workers in tmux ──
        tmux kill-session -t studio 2>/dev/null || true
        echo "[start] tmux session 'studio' — ./worker.sh $WORKER_CMD"
        tmux new-session -d -s studio -c "\$DEPLOY_DIR" "./worker.sh $WORKER_CMD"
        echo "[ok] Started in tmux session 'studio'"
REMOTEEOF

    echo "[$host] Done."
}

# ── Run in parallel ─────────────────────────────────────────────────────────

PIDS=()
for host in "${HOSTS[@]}"; do
    deploy_to_host "$host" &
    PIDS+=($!)
done

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
echo "Attach:  ssh $DEPLOY_USER@<host> 'tmux attach -t studio'"
echo "Stop:    yarn undeploy <host>"
