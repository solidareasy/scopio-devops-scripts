#!/bin/bash
set -e

# ── Setup Tailscale ─────────────────────────────────────────────────────────
# Installs, starts daemon, connects, and enables SSH on any platform.
#
# Environment variables (loaded from config/envs/<env>/common.envrc):
#   TAILSCALE_AUTH_KEY   — Auth key for non-interactive login (required for headless)
#   TAILSCALE_HEADLESS   — Force headless mode: "true" (auto-detected on macOS)
#   TAILSCALE_HOSTNAME   — Custom device name in Tailscale (e.g. "mac-mini-02")
#
# Usage:
#   yarn tailscale                                  # desktop (interactive login)
#   TAILSCALE_AUTH_KEY=tskey-auth-... yarn tailscale # any machine (non-interactive)
#   TAILSCALE_HEADLESS=true yarn tailscale           # headless mac (rent-a-mac, CI)
# ─────────────────────────────────────────────────────────────────────────────

PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]')
HEADLESS="${TAILSCALE_HEADLESS:-true}"

case "$PLATFORM" in
    mingw*|msys*|cygwin*) PLATFORM="windows" ;;
esac

# Auto-detect headless macOS (no GUI session)
if [ "$HEADLESS" = "false" ] && [ "$PLATFORM" = "darwin" ]; then
    if [ -z "$DISPLAY" ] && ! command -v open &>/dev/null 2>&1; then
        HEADLESS="true"
        echo "[headless] Auto-detected headless macOS — using CLI daemon mode."
    fi
fi

# ── Helper: find tailscale binary ───────────────────────────────────────────

find_tailscale() {
    # 1. Already in PATH
    if command -v tailscale &>/dev/null; then
        TAILSCALE_BIN="tailscale"
        return 0
    fi

    # 2. macOS cask: CLI inside the .app bundle
    if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
        TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        return 0
    fi

    # 3. Homebrew formula paths (Apple Silicon + Intel)
    for p in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
        if [ -x "$p" ]; then
            TAILSCALE_BIN="$p"
            return 0
        fi
    done

    # 4. Linux common paths
    for p in /usr/bin/tailscale /usr/sbin/tailscale /usr/local/bin/tailscale; do
        if [ -x "$p" ]; then
            TAILSCALE_BIN="$p"
            return 0
        fi
    done

    return 1
}

# ── 1. Install ──────────────────────────────────────────────────────────────


# ── 0. Remove desktop (cask) Tailscale if switching to headless ───────────

if [ "$HEADLESS" = "true" ] && [ "$PLATFORM" = "darwin" ]; then
    if [ -d "/Applications/Tailscale.app" ]; then
        echo "[clean] Removing desktop Tailscale.app (switching to headless)..."
        # Stop the GUI app
        osascript -e 'quit app "Tailscale"' 2>/dev/null || true
        sleep 1
        # Uninstall cask if installed via brew
        brew uninstall --cask tailscale 2>/dev/null || true
        # Remove manually if cask uninstall didn't catch it
        if [ -d "/Applications/Tailscale.app" ]; then
            rm -rf "/Applications/Tailscale.app"
        fi
        echo "[ok] Desktop Tailscale removed"
    fi
fi

if ! find_tailscale; then
    echo "Tailscale not found. Installing..."

    case "$PLATFORM" in
        darwin)
            if ! command -v brew &>/dev/null; then
                echo "Homebrew not found. Installing Homebrew first..."
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                # Add brew to PATH for Apple Silicon
                if [ -f /opt/homebrew/bin/brew ]; then
                    eval "$(/opt/homebrew/bin/brew shellenv)"
                fi
            fi
            if [ "$HEADLESS" = "true" ]; then
                brew install tailscale
            else
                brew install --cask tailscale
            fi
            ;;
        linux)
            curl -fsSL https://tailscale.com/install.sh | sh
            ;;
        windows)
            if command -v winget &>/dev/null; then
                winget install --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements
            elif command -v choco &>/dev/null; then
                choco install tailscale -y
            else
                echo "No package manager found (winget or choco)."
                echo "  Install manually: https://tailscale.com/download/windows"
                exit 1
            fi
            ;;
        *)
            echo "Unsupported platform: $PLATFORM"
            exit 1
            ;;
    esac

    # Re-find after install
    if ! find_tailscale; then
        echo "[error] Tailscale installed but binary not found in any known path."
        echo "  Try opening a new terminal or add it to PATH."
        exit 1
    fi
fi

echo "Tailscale $($TAILSCALE_BIN version | head -1) is installed. ($TAILSCALE_BIN)"

# ── 2. Start daemon ─────────────────────────────────────────────────────────

case "$PLATFORM" in
    darwin)
        if [ "$HEADLESS" = "true" ]; then
            if ! sudo launchctl list 2>/dev/null | grep -q "com.tailscale.tailscaled"; then
                echo "Starting tailscaled system service..."
                sudo brew services start tailscale
                sleep 3
            fi
        else
            if ! pgrep -x "Tailscale" &>/dev/null; then
                echo "Opening Tailscale app..."
                open -a Tailscale
                sleep 3
            fi
        fi
        ;;
    linux)
        if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
            echo "Starting tailscaled service..."
            sudo systemctl enable --now tailscaled
            sleep 2
        fi
        ;;
    windows)
        if ! tasklist 2>/dev/null | grep -qi "tailscale"; then
            echo "Starting Tailscale service..."
            net start Tailscale 2>/dev/null || true
        fi
        ;;
esac

# ── 3. Connect + enable SSH ─────────────────────────────────────────────────

STATUS=$($TAILSCALE_BIN status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 || echo "Unknown")

TS_UP_ARGS=(--ssh)

if [ -n "$TAILSCALE_HOSTNAME" ]; then
    TS_UP_ARGS+=(--hostname="$TAILSCALE_HOSTNAME")
fi

if [ "$STATUS" = "Running" ]; then
    # Already connected — check if rename is needed
    CURRENT_HOSTNAME=$($TAILSCALE_BIN status --json 2>/dev/null | grep -o '"Self":{[^}]*}' | grep -o '"HostName":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [ -n "$TAILSCALE_HOSTNAME" ] && [ "$CURRENT_HOSTNAME" != "$TAILSCALE_HOSTNAME" ]; then
        echo "Renaming device: $CURRENT_HOSTNAME -> $TAILSCALE_HOSTNAME"
        sudo $TAILSCALE_BIN up "${TS_UP_ARGS[@]}"
    else
        echo "Tailscale is already connected as '$CURRENT_HOSTNAME'."
    fi

    $TAILSCALE_BIN status
    exit 0
fi

echo "Tailscale is not connected (state: $STATUS). Connecting..."

if [ -n "$TAILSCALE_HOSTNAME" ]; then
    echo "Device name: $TAILSCALE_HOSTNAME"
fi

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    echo "Authenticating with TAILSCALE_AUTH_KEY..."
    sudo $TAILSCALE_BIN up --authkey="$TAILSCALE_AUTH_KEY" "${TS_UP_ARGS[@]}"
else
    if [ "$HEADLESS" = "true" ]; then
        echo "ERROR: Headless mode requires TAILSCALE_AUTH_KEY."
        echo "  Generate one at: https://login.tailscale.com/admin/settings/keys"
        echo "  Then set it in your environment or profile.envrc"
        exit 1
    fi
    echo "No TAILSCALE_AUTH_KEY set — opening interactive login..."
    sudo $TAILSCALE_BIN up "${TS_UP_ARGS[@]}"
fi

echo ""
echo "Tailscale is connected with SSH enabled."
$TAILSCALE_BIN status

# ── 4. Ensure service persists across reboots ─────────────────────────────

if [ "$HEADLESS" = "true" ] && [ "$PLATFORM" = "darwin" ]; then
    brew services start tailscale 2>/dev/null || true
    echo "[ok] tailscale service enabled (survives reboot)"
fi
