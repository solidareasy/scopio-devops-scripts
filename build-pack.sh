#!/bin/bash
set -e

# ── Build & Pack Scopio Workers (broker + mlops) ────────────────────────────
# Builds the broker (TypeScript) and bundles mlops (Python) into the
# scopio-studio-build git repo for worker machines to clone.
#
# Usage:
#   yarn build:pack                  # build + push to git
#   yarn build:pack --skip-build     # reuse existing dist/, just push
#
# Output:
#   Pushes to github.com/solidareasy/scopio-studio-build
# ─────────────────────────────────────────────────────────────────────────────

BUILD_REPO="git@github.com:solidareasy/scopio-studio-build.git"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BROKER_DIR="$ROOT_DIR/packages/broker"
MLOPS_DIR="$ROOT_DIR/packages/mlops"
MODEL_DIR="$ROOT_DIR/packages/model"
DIST_DIR="$ROOT_DIR/dist"
PACK_DIR="$DIST_DIR/scopio-studio-build"
SKIP_BUILD="false"

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD="true" ;;
    esac
done

# ── 1. Build broker ────────────────────────────────────────────────────────

if [ "$SKIP_BUILD" = "true" ]; then
    echo "[skip] Reusing existing broker build..."
else
    echo "[build] Compiling broker (TypeScript)..."
    cd "$BROKER_DIR" && npx tsc
fi

if [ ! -d "$BROKER_DIR/dist" ]; then
    echo "[error] Broker dist/ not found. Build failed?"
    exit 1
fi

# ── 2. Assemble package ────────────────────────────────────────────────────

echo "[pack] Assembling scopio-studio-build..."

# Clone or reset the build repo
if [ -d "$PACK_DIR/.git" ]; then
    echo "[git] Cleaning existing repo..."
    cd "$PACK_DIR"
    git rm -rf --quiet . 2>/dev/null || true
    git clean -fdx --quiet
else
    rm -rf "$PACK_DIR"
    echo "[git] Cloning $BUILD_REPO..."
    git clone "$BUILD_REPO" "$PACK_DIR" 2>/dev/null || {
        mkdir -p "$PACK_DIR"
        cd "$PACK_DIR"
        git init
        git remote add origin "$BUILD_REPO"
    }
fi

cd "$PACK_DIR"
mkdir -p packages/broker packages/mlops packages/model

# Broker: compiled JS + package.json + node_modules
cp -r "$BROKER_DIR/dist"         packages/broker/dist
cp    "$BROKER_DIR/package.json" packages/broker/package.json
if [ -d "$BROKER_DIR/node_modules" ]; then
    cp -r "$BROKER_DIR/node_modules" packages/broker/node_modules
fi

# MLOps: source + requirements (venv created on target)
cp -r "$MLOPS_DIR/src"              packages/mlops/src
cp    "$MLOPS_DIR/package.json"     packages/mlops/package.json
cp    "$MLOPS_DIR/requirements.txt" packages/mlops/requirements.txt

# Model: prisma schema + python package (shared by broker & mlops)
if [ -d "$MODEL_DIR/prisma" ]; then
    cp -r "$MODEL_DIR/prisma" packages/model/prisma
fi
if [ -d "$MODEL_DIR/src/python" ]; then
    cp -r "$MODEL_DIR/src" packages/model/src
fi
if [ -f "$MODEL_DIR/package.json" ]; then
    cp "$MODEL_DIR/package.json" packages/model/package.json
fi

# Root package.json (minimal — no workspaces, no postinstall)
cat > package.json << 'PKGJSON'
{
    "name": "scopio-studio-build",
    "version": "0.1.0",
    "private": true
}
PKGJSON

# ── 3. Worker entry script ─────────────────────────────────────────────────

cat > worker.sh << 'EOF'
#!/bin/bash
set -e

# ── Scopio Worker Runner ────────────────────────────────────────────────────
# Runs broker or mlops workers in CLI or event (daemon) mode.
# Loads .env from the deploy directory if present.
#
# Required env vars (set in .env or environment):
#   DATABASE_URL, REDIS_URL, AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#   SCOPIO_DRIVER_BUCKET, SCOPIO_STUDIO_BUCKET
#
# Usage:
#   # ── Event mode (daemon — listens on BullMQ queues) ──
#   ./worker.sh broker --i2 --e4 --t1 --p8     # TUI: 2 ingest, 4 embed, 1 train, 8 predict
#   ./worker.sh ingest --daemon --concurrency 2
#   ./worker.sh embed  --daemon --concurrency 4
#   ./worker.sh train  --daemon
#   ./worker.sh predict --daemon --concurrency 8
#
#   # ── CLI mode (batch — process and exit) ──
#   ./worker.sh ingest --in s3://scopio-driver/gold
#   ./worker.sh embed  --in s3://scopio-driver/gold --force
#   ./worker.sh train  --in s3://scopio-driver/gold
#   ./worker.sh predict
# ─────────────────────────────────────────────────────────────────────────────

WORKER_DIR="$(cd "$(dirname "$0")" && pwd)"
MLOPS_DIR="$WORKER_DIR/packages/mlops"
BROKER_DIR="$WORKER_DIR/packages/broker"
VENV_DIR="$MLOPS_DIR/venv"

# Load .env if present
if [ -f "$WORKER_DIR/.env" ]; then
    set -a
    source "$WORKER_DIR/.env"
    set +a
fi

export PYTHONPATH="$WORKER_DIR:$MLOPS_DIR"

COMMAND="${1:?Usage: ./worker.sh <broker|ingest|embed|train|predict> [args...]}"
shift

# ── Setup Python venv (first run only) ──────────────────────────────────────

setup_venv() {
    if [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/python" ]; then
        return
    fi
    echo "[setup] Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip
    "$VENV_DIR/bin/pip" install -r "$MLOPS_DIR/requirements.txt"
    if [ -d "$WORKER_DIR/packages/model/src/python" ]; then
        "$VENV_DIR/bin/pip" install -e "$WORKER_DIR/packages/model/src/python"
    fi
    echo "[setup] Python environment ready."
}

# ── Validate env ────────────────────────────────────────────────────────────

check_env() {
    local missing=()
    for var in DATABASE_URL REDIS_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY SCOPIO_DRIVER_BUCKET SCOPIO_STUDIO_BUCKET; do
        if [ -z "${!var}" ]; then
            missing+=("$var")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "[error] Missing required environment variables:"
        printf "  %s\n" "${missing[@]}"
        exit 1
    fi
}

# ── Run ─────────────────────────────────────────────────────────────────────

check_env

case "$COMMAND" in
    broker)
        echo "[start] Broker TUI..."
        cd "$BROKER_DIR"
        exec node dist/bin/tui.js "$@"
        ;;
    ingest|embed|train|predict)
        setup_venv
        echo "[start] MLOps worker: $COMMAND $*"
        cd "$MLOPS_DIR"
        exec "$VENV_DIR/bin/python" -m src.pipeline.cli "$COMMAND" "$@"
        ;;
    *)
        echo "Unknown command: $COMMAND"
        echo "Available: broker, ingest, embed, train, predict"
        exit 1
        ;;
esac
EOF

chmod +x worker.sh

# ── 4. .gitignore ──────────────────────────────────────────────────────────

cat > .gitignore << 'EOF'
.env
venv/
*.pyc
__pycache__/
worker.pid
worker.log
EOF

# ── 5. Push to git ─────────────────────────────────────────────────────────

echo "[git] Committing and pushing..."

git add -A
git commit -m "build: $(date '+%Y-%m-%d %H:%M:%S')" --allow-empty
git branch -M main
git push -u origin main --force

echo ""
echo "[done] Pushed to $BUILD_REPO"
echo ""
echo "Workers clone with:"
echo "  git clone $BUILD_REPO ~/Desktop/studio"
