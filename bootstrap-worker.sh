#!/bin/bash
set -e

# ── Bootstrap Scopio Worker Machine ─────────────────────────────────────────
# Single curl command to setup a fresh rent-a-mac from zero:
#   1. Install + connect Tailscale (with custom hostname)
#   2. Install Node.js + Python + Git
#   3. Clone worker build from GitHub
#   4. Create .env + start workers
#
# Usage:
#
#   export TAILSCALE_AUTH_KEY="tskey-auth-..." \
#   TAILSCALE_HOSTNAME="mac-mini-02" \
#   DATABASE_URL="postgresql://scopio:scopio@dev-scopio-desktop-linux:5432/scopio_studio?schema=studio" \
#   REDIS_URL="redis://dev-scopio-desktop-linux:6379" \
#   AWS_REGION="us-east-1" \
#   AWS_ACCESS_KEY_ID="..." \
#   AWS_SECRET_ACCESS_KEY="..." \
#   SCOPIO_DRIVER_BUCKET="scopio-driver" \
#   SCOPIO_STUDIO_BUCKET="scopio-studio" \
#   WORKER_CMD="broker --i2 --e4 --t1 --p8" \
#   && curl -fsSL https://gist.githubusercontent.com/viniciustrindade/d3d1c76b9c2c9d5d98e874c8feac4350/raw/bootstrap-worker.sh | bash
#
# Environment variables:
#   TAILSCALE_AUTH_KEY     — Tailscale auth key (required)
#   TAILSCALE_HOSTNAME     — Custom device name in Tailscale (e.g. "mac-mini-02")
#   GH_TOKEN               — GitHub token to clone private repo (or use gh auth login)
#   WORKER_CMD             — Worker command to run (default: prints usage)
#   DEPLOY_DIR             — Install directory (default: ~/Desktop/studio)
#   NODE_VERSION           — Node.js version (default: 22)
#   PYTHON_VERSION         — Python version (default: 3.11)
# ─────────────────────────────────────────────────────────────────────────────

BUILD_REPO="https://github.com/solidareasy/scopio-studio-build.git"
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/Desktop/studio}"
NODE_VERSION="${NODE_VERSION:-22}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"
PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]')

log() { echo ""; echo "════════════════════════════════════════"; echo "  $1"; echo "════════════════════════════════════════"; }

# ── 1. Tailscale ────────────────────────────────────────────────────────────

log "1/5  Tailscale"

if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
    echo "Tailscale already connected."
    tailscale status | head -5
else
    if [ -z "$TAILSCALE_AUTH_KEY" ]; then
        echo "[error] TAILSCALE_AUTH_KEY is required."
        exit 1
    fi
    curl -fsSL https://raw.githubusercontent.com/solidareasy/scopio-devops-scripts/main/setup-tailscale.sh | \
        TAILSCALE_AUTH_KEY="$TAILSCALE_AUTH_KEY" TAILSCALE_HEADLESS="${TAILSCALE_HEADLESS:-true}" TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}" bash
fi

# Rename if already connected but hostname differs
if [ -n "$TAILSCALE_HOSTNAME" ]; then
    CURRENT_TS_NAME=$(tailscale status --self --json 2>/dev/null | grep -o '"HostName":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    if [ -n "$CURRENT_TS_NAME" ] && [ "$CURRENT_TS_NAME" != "$TAILSCALE_HOSTNAME" ]; then
        echo "Renaming: $CURRENT_TS_NAME -> $TAILSCALE_HOSTNAME"
        sudo tailscale up --hostname="$TAILSCALE_HOSTNAME" --ssh
    fi
fi

# ── 2. Node.js ──────────────────────────────────────────────────────────────

log "2/5  Node.js"

# Ensure brew node is in PATH
if [ -d "/opt/homebrew/opt/node@$NODE_VERSION/bin" ]; then
    export PATH="/opt/homebrew/opt/node@$NODE_VERSION/bin:$PATH"
fi

if command -v node &>/dev/null; then
    echo "Node.js $(node -v) found."
else
    echo "Installing Node.js $NODE_VERSION..."
    case "$PLATFORM" in
        darwin)
            if command -v brew &>/dev/null; then
                brew install "node@$NODE_VERSION"
                export PATH="/opt/homebrew/opt/node@$NODE_VERSION/bin:$PATH"
                echo "export PATH=\"/opt/homebrew/opt/node@$NODE_VERSION/bin:\$PATH\"" >> ~/.zshrc
            else
                curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
                export NVM_DIR="$HOME/.nvm"
                [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
                nvm install "$NODE_VERSION"
            fi
            ;;
        linux)
            curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
            nvm install "$NODE_VERSION"
            ;;
    esac
    echo "Node.js $(node -v) installed."
fi

# ── 3. Python ───────────────────────────────────────────────────────────────

log "3/5  Python"

if command -v python3 &>/dev/null; then
    echo "Python $(python3 --version) found."
else
    echo "Installing Python $PYTHON_VERSION..."
    case "$PLATFORM" in
        darwin)
            brew install "python@$PYTHON_VERSION"
            ;;
        linux)
            sudo apt-get update -qq && sudo apt-get install -y -qq \
                "python${PYTHON_VERSION}" "python${PYTHON_VERSION}-venv" \
                python3-pip libpq-dev build-essential git
            ;;
    esac
    echo "Python $(python3 --version) installed."
fi

# ── 4. Clone build repo ────────────────────────────────────────────────────

log "4/5  Worker package"

# Build clone URL with token if provided
if [ -n "$GH_TOKEN" ]; then
    CLONE_URL="https://${GH_TOKEN}@github.com/solidareasy/scopio-studio-build.git"
else
    CLONE_URL="$BUILD_REPO"
fi

if [ -d "$DEPLOY_DIR/.git" ]; then
    echo "Updating existing repo at $DEPLOY_DIR..."
    cd "$DEPLOY_DIR"
    git pull --force origin main
else
    echo "Cloning $BUILD_REPO into $DEPLOY_DIR..."
    git clone "$CLONE_URL" "$DEPLOY_DIR"
fi

echo "Workers ready at $DEPLOY_DIR"

# ── 5. Create .env + start ─────────────────────────────────────────────────

log "5/5  Configure & Start"

ENV_FILE="$DEPLOY_DIR/.env"
echo "Writing $ENV_FILE..."

cat > "$ENV_FILE" << ENVEOF
# Auto-generated by bootstrap-worker.sh
DATABASE_URL=${DATABASE_URL}
REDIS_URL=${REDIS_URL}
AWS_REGION=${AWS_REGION:-us-east-1}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
SCOPIO_DRIVER_BUCKET=${SCOPIO_DRIVER_BUCKET}
SCOPIO_STUDIO_BUCKET=${SCOPIO_STUDIO_BUCKET}
SCOPIO_STUDIO_AWS_S3_ENDPOINT=${SCOPIO_STUDIO_AWS_S3_ENDPOINT:-}
ENVEOF

chmod 600 "$ENV_FILE"

# Validate
MISSING=()
for var in DATABASE_URL REDIS_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY SCOPIO_DRIVER_BUCKET SCOPIO_STUDIO_BUCKET; do
    if [ -z "${!var}" ]; then MISSING+=("$var"); fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "[warn] Missing env vars (edit $ENV_FILE before starting):"
    printf "  %s\n" "${MISSING[@]}"
    echo ""
    echo "Then start manually:"
    echo "  cd $DEPLOY_DIR && ./worker.sh broker --i2 --e4 --t1 --p8"
    exit 0
fi

echo "All env vars set."

# Start workers
if [ -n "$WORKER_CMD" ]; then
    echo ""
    echo "Starting: ./worker.sh $WORKER_CMD"
    cd "$DEPLOY_DIR"
    nohup ./worker.sh $WORKER_CMD > worker.log 2>&1 &
    echo $! > worker.pid
    echo "Started (pid=$!) — logs: $DEPLOY_DIR/worker.log"
else
    echo ""
    echo "Ready! Start workers with:"
    echo "  cd $DEPLOY_DIR"
    echo ""
    echo "  # Event mode (daemon)"
    echo "  ./worker.sh broker --i2 --e4 --t1 --p8"
    echo ""
    echo "  # CLI mode (batch)"
    echo "  ./worker.sh ingest --in s3://scopio-driver/gold"
fi

# ── Clear shell history (secrets were passed as env vars on the command line) ─

echo ""
echo "Clearing shell history to protect secrets..."

# Unset sensitive env vars from current shell
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY TAILSCALE_AUTH_KEY DATABASE_URL GH_TOKEN

# Clear history for all common shells
history -c 2>/dev/null || true                  # bash
[ -n "$HISTFILE" ] && : > "$HISTFILE" 2>/dev/null || true
: > ~/.bash_history 2>/dev/null || true
: > ~/.zsh_history 2>/dev/null || true
fc -p 2>/dev/null || true                       # zsh reset

echo "History cleared. Secrets are stored only in $ENV_FILE (chmod 600)."
echo ""
echo "Done."
