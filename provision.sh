#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_TYPE="_flipper._tcp"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
SSH_USER="user"
REMOTE_DIR="/home/user/f1"
BROWSE_TIMEOUT=3
RESOLVE_TIMEOUT=3
WEBDAV_MODE=false
WEBDAV_PORT=8080
WEBDAV_CONFIG=""

# Parse arguments
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --webdav) WEBDAV_MODE=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

if [ -n "${1:-}" ]; then
    # ── Manual mode: IP provided as argument ────────────────────────────────
    HOST="$1"
    echo "Using provided IP: $HOST"
    echo ""
else
    # ── Step 1: Discover Flipper One devices via mDNS ───────────────────────

    echo "Searching for Flipper One devices on LAN (${BROWSE_TIMEOUT}s)..."
    echo ""

    BROWSE_OUTPUT=$(mktemp)
    dns-sd -B "$SERVICE_TYPE" . >"$BROWSE_OUTPUT" 2>&1 </dev/null &
    BROWSE_PID=$!
    sleep "$BROWSE_TIMEOUT"
    kill "$BROWSE_PID" 2>/dev/null || true
    wait "$BROWSE_PID" 2>/dev/null || true

    # Parse instance names from dns-sd browse output
    # Output lines look like: "12:00:00.000  Add  2  4  local.  _flipper._tcp.  rk3576-debian13-0"
    INSTANCES=()
    while IFS= read -r line; do
        [ -n "$line" ] && INSTANCES+=("$line")
    done < <(awk '$2 == "Add" {print $NF}' "$BROWSE_OUTPUT" | sort -u)
    rm -f "$BROWSE_OUTPUT"

    if [ ${#INSTANCES[@]} -eq 0 ]; then
        echo "No Flipper One devices found on LAN."
        echo "Make sure the device is powered on and connected to the same network."
        exit 1
    fi

    # ── Step 2: Resolve each device (hostname, IP, serial) ──────────────────

    declare -a HOSTNAMES
    declare -a IPS
    declare -a SERIALS

    for instance in "${INSTANCES[@]}"; do
        # Lookup service to get hostname and TXT record (serial)
        LOOKUP_OUTPUT=$(mktemp)
        dns-sd -L "$instance" "$SERVICE_TYPE" local. >"$LOOKUP_OUTPUT" 2>&1 </dev/null &
        LOOKUP_PID=$!
        sleep "$RESOLVE_TIMEOUT"
        kill "$LOOKUP_PID" 2>/dev/null || true
        wait "$LOOKUP_PID" 2>/dev/null || true

        # Parse hostname (e.g., "rk3576-debian13-0.local.") and serial from TXT
        hostname=$(grep 'can be reached at' "$LOOKUP_OUTPUT" | head -1 | sed -E 's/.*can be reached at ([^ :]+).*/\1/' | sed 's/\.$//')
        serial=$(grep -oE 'serial=[^ ]+' "$LOOKUP_OUTPUT" | head -1 | cut -d= -f2 || echo "unknown")
        rm -f "$LOOKUP_OUTPUT"

        if [ -z "$hostname" ]; then
            hostname="${instance}.local"
        fi

        # Resolve hostname to IP address
        RESOLVE_OUTPUT=$(mktemp)
        dns-sd -G v4 "$hostname" >"$RESOLVE_OUTPUT" 2>&1 </dev/null &
        RESOLVE_PID=$!
        sleep "$RESOLVE_TIMEOUT"
        kill "$RESOLVE_PID" 2>/dev/null || true
        wait "$RESOLVE_PID" 2>/dev/null || true

        # Parse IP from resolve output
        # Lines look like: "Timestamp  A/R Flags  if  Hostname  Address  TTL"
        ip=$(awk '$2 == "Add" {print $(NF-1)}' "$RESOLVE_OUTPUT" | head -1)
        rm -f "$RESOLVE_OUTPUT"

        if [ -z "$ip" ]; then
            ip="(unresolved)"
        fi

        HOSTNAMES+=("$hostname")
        IPS+=("$ip")
        SERIALS+=("$serial")
    done

    # ── Step 3: Display devices and let user choose ─────────────────────────

    echo "Found ${#INSTANCES[@]} Flipper One device(s):"
    echo ""
    printf "  %-4s %-18s %-20s %s\n" "#" "IP Address" "Serial" "Hostname"
    printf "  %-4s %-18s %-20s %s\n" "---" "------------------" "--------------------" "--------"
    for i in "${!INSTANCES[@]}"; do
        printf "  %-4s %-18s %-20s %s\n" "$((i+1))" "${IPS[$i]}" "${SERIALS[$i]}" "${HOSTNAMES[$i]}"
    done
    echo ""

    read -rp "Select device number [1-${#INSTANCES[@]}]: " CHOICE
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#INSTANCES[@]} ]; then
        echo "Invalid selection."
        exit 1
    fi

    IDX=$((CHOICE - 1))
    HOST="${IPS[$IDX]}"
    echo ""
    echo "Selected: ${HOSTNAMES[$IDX]} ($HOST) serial=${SERIALS[$IDX]}"
    echo ""
fi

# ── Step 4: Remove old SSH host keys ────────────────────────────────────────

echo "Removing old SSH host key for $HOST from known_hosts..."
ssh-keygen -R "$HOST" 2>&1 | grep -v '^#' || true

echo ""

# ── Step 5: Upload SSH key ──────────────────────────────────────────────────

if [ ! -f "$SSH_KEY" ]; then
    echo "SSH key not found at $SSH_KEY"
    echo "Generate one with: ssh-keygen -t ed25519"
    exit 1
fi

echo "Installing SSH key to $SSH_USER@$HOST (enter password '$SSH_USER')..."
ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$SSH_USER@$HOST"
echo ""

# ── Step 6: Auto-commit git tracked files if modified ───────────────────────

cd "$SCRIPT_DIR"
if git -C "$SCRIPT_DIR" diff --quiet && git -C "$SCRIPT_DIR" diff --cached --quiet; then
    echo "Git: no uncommitted changes."
else
    echo "Git: committing modified tracked files before sync..."
    git -C "$SCRIPT_DIR" add -u
    git -C "$SCRIPT_DIR" commit -m "Auto-commit before mutagen sync $(date +%Y%m%d-%H%M%S)"
    echo ""
fi
echo ""

# ── Step 7: Start fswatch file monitor ──────────────────────────────────────

mkdir -p "$SCRIPT_DIR/logs"
FSWATCH_LOG="$SCRIPT_DIR/logs/fswatch.log"

FSWATCH_PID=""
if command -v fswatch >/dev/null 2>&1; then
    echo "Starting fswatch file monitor → $FSWATCH_LOG"
    fswatch -r -x --event-flag-separator=' ' \
        --event Created --event Removed --event Renamed --event Updated \
        --exclude '/logs/' --exclude '/\.git/' \
        "$SCRIPT_DIR" | while IFS= read -r f; do
        line="$(date '+%Y-%m-%d %H:%M:%S') $f"
        echo "$line"
        echo "$line" >> "$FSWATCH_LOG"
    done &
    FSWATCH_PID=$!
else
    echo "WARNING: fswatch not installed, skipping file monitor."
    echo "  Install with: brew install fswatch"
fi
echo ""

# ── Step 8: Start file sharing in foreground ─────────────────────────────────

# Cleanup on exit
cleanup() {
    echo ""
    if [ "$WEBDAV_MODE" = true ]; then
        echo "Stopping WebDAV server..."
        rm -f "$WEBDAV_CONFIG" 2>/dev/null
    else
        echo "Stopping mutagen sync session..."
        timeout 5 "$MUTAGEN" sync terminate --label-selector "flipper=provision" 2>/dev/null || true
    fi
    if [ -n "$FSWATCH_PID" ]; then
        kill "$FSWATCH_PID" 2>/dev/null
        wait "$FSWATCH_PID" 2>/dev/null || true
    fi
    echo "Done."
}
trap cleanup EXIT

if [ "$WEBDAV_MODE" = true ]; then
    # ── WebDAV mode ──────────────────────────────────────────────────────────

    if ! command -v wsgidav >/dev/null 2>&1; then
        echo "wsgidav not found, please install:"
        echo "  pip install wsgidav cheroot"
        exit 1
    fi

    # Generate temporary credentials
    DAV_USER="flipper"
    DAV_PASS=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12 || true)

    # Get local IP address (the one facing the device)
    LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "YOUR_MAC_IP")

    # Create temporary wsgidav config with authentication
    WEBDAV_CONFIG=$(mktemp /tmp/wsgidav-XXXXXX.yaml)
    cat > "$WEBDAV_CONFIG" <<YAML
host: 0.0.0.0
port: $WEBDAV_PORT
provider_mapping:
    "/": "$SCRIPT_DIR"
http_authenticator:
    domain_controller: null
    accept_basic: true
    accept_digest: true
    default_to_digest: true
simple_dc:
    user_mapping:
        "*":
            "$DAV_USER":
                password: "$DAV_PASS"
verbose: 3
YAML

    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  WebDAV server starting on http://${LOCAL_IP}:${WEBDAV_PORT}   "
    echo "║                                                                ║"
    echo "║  User: $DAV_USER                                              "
    echo "║  Pass: $DAV_PASS                                              "
    echo "║                                                                ║"
    echo "║  Run on the device:                                            ║"
    echo "║                                                                ║"
    echo "║  sudo mkdir -p $REMOTE_DIR && sudo mount -t davfs \\           "
    echo "║    http://${LOCAL_IP}:${WEBDAV_PORT} $REMOTE_DIR               "
    echo "║                                                                ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Ctrl+C to stop."
    echo ""

    # Run wsgidav in foreground (logs to stdout)
    wsgidav --config "$WEBDAV_CONFIG"

else
    # ── Mutagen mode (default) ───────────────────────────────────────────────

    MUTAGEN="$(command -v mutagen || true)"
    if [ -z "$MUTAGEN" ]; then
        echo "Mutagen not found, please install:"
        echo "  brew install mutagen-io/mutagen/mutagen"
        exit 1
    fi

    # Terminate any existing sync sessions for this path (timeout after 5s)
    timeout 5 "$MUTAGEN" sync terminate --label-selector "flipper=provision" 2>/dev/null || true

    echo "Starting mutagen sync: $SCRIPT_DIR → $SSH_USER@$HOST:$REMOTE_DIR"
    echo ""

    CREATE_OUTPUT=$("$MUTAGEN" sync create \
        "$SCRIPT_DIR" \
        "$SSH_USER@$HOST:$REMOTE_DIR" \
        --label "flipper=provision" \
        --sync-mode two-way-safe \
        --ignore "/.git" \
        --ignore "/.gitignore" \
        --ignore ".DS_Store" \
        --ignore "/logs" \
        --ignore "/provision.sh" \
        2>&1)

    SESSION=$(echo "$CREATE_OUTPUT" | grep -oE 'sync_[A-Za-z0-9]+' || true)
    if [ -n "$SESSION" ]; then
        echo "Sync session created: $SESSION"
    else
        echo "Sync session created."
    fi

    echo "Monitoring sync (Ctrl+C to stop)..."
    echo ""

    # Keep in foreground — monitor will show ongoing sync activity
    "$MUTAGEN" sync monitor --label-selector "flipper=provision"
fi
