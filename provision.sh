#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_TYPE="_flipper._tcp"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
SSH_USER="user"
REMOTE_DIR="/home/user/f1"
BROWSE_TIMEOUT=3
RESOLVE_TIMEOUT=3

# ── Step 1: Discover Flipper One devices via mDNS ───────────────────────────

echo "Searching for Flipper One devices on LAN (${BROWSE_TIMEOUT}s)..."
echo ""

BROWSE_OUTPUT=$(mktemp)
dns-sd -B "$SERVICE_TYPE" . > "$BROWSE_OUTPUT" 2>/dev/null &
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

# ── Step 2: Resolve each device (hostname, IP, serial) ──────────────────────

declare -a HOSTNAMES
declare -a IPS
declare -a SERIALS

for instance in "${INSTANCES[@]}"; do
    # Lookup service to get hostname and TXT record (serial)
    LOOKUP_OUTPUT=$(mktemp)
    dns-sd -L "$instance" "$SERVICE_TYPE" local. > "$LOOKUP_OUTPUT" 2>/dev/null &
    LOOKUP_PID=$!
    sleep "$RESOLVE_TIMEOUT"
    kill "$LOOKUP_PID" 2>/dev/null || true
    wait "$LOOKUP_PID" 2>/dev/null || true

    # Parse hostname (e.g., "rk3576-debian13-0.local.") and serial from TXT
    hostname=$(grep 'can be reached at' "$LOOKUP_OUTPUT" | sed -E 's/.*can be reached at ([^ :]+).*/\1/' | sed 's/\.$//')
    serial=$(grep -oE 'serial=[^ ]+' "$LOOKUP_OUTPUT" | cut -d= -f2 || echo "unknown")
    rm -f "$LOOKUP_OUTPUT"

    if [ -z "$hostname" ]; then
        hostname="${instance}.local"
    fi

    # Resolve hostname to IP address
    RESOLVE_OUTPUT=$(mktemp)
    dns-sd -G v4 "$hostname" > "$RESOLVE_OUTPUT" 2>/dev/null &
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

# ── Step 3: Display devices and let user choose ─────────────────────────────

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
HOSTNAME="${HOSTNAMES[$IDX]}"
SERIAL="${SERIALS[$IDX]}"

echo ""
echo "Selected: $HOSTNAME ($HOST) serial=$SERIAL"
echo ""

# ── Step 4: Remove old SSH host keys ────────────────────────────────────────

echo "Removing old SSH host key for $HOST from known_hosts..."
ssh-keygen -R "$HOST" 2>&1 | grep -v '^#' || true

echo "Removing old SSH host key for $HOSTNAME from known_hosts..."
ssh-keygen -R "$HOSTNAME" 2>&1 | grep -v '^#' || true

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
    fswatch -r --event Created --event Removed --event Renamed --event Updated \
        --exclude "$SCRIPT_DIR/logs" --exclude "$SCRIPT_DIR/.git" \
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

# ── Step 8: Start mutagen sync in foreground ────────────────────────────────

MUTAGEN="$(command -v mutagen || echo /opt/homebrew/Cellar/mutagen/0.18.1/bin/mutagen)"

# Cleanup on exit: terminate mutagen session and fswatch
cleanup() {
    echo ""
    echo "Stopping mutagen sync session..."
    "$MUTAGEN" sync terminate --label-selector "flipper=provision" 2>/dev/null || true
    if [ -n "$FSWATCH_PID" ]; then
        kill "$FSWATCH_PID" 2>/dev/null
        wait "$FSWATCH_PID" 2>/dev/null || true
    fi
    echo "Done."
}
trap cleanup EXIT

# Terminate any existing sync sessions for this path
"$MUTAGEN" sync terminate --label-selector "flipper=provision" 2>/dev/null || true

echo "Starting mutagen sync: $SCRIPT_DIR → $SSH_USER@$HOST:$REMOTE_DIR"
echo ""

SESSION=$("$MUTAGEN" sync create \
    "$SCRIPT_DIR" \
    "$SSH_USER@$HOST:$REMOTE_DIR" \
    --label "flipper=provision" \
    --sync-mode two-way-safe \
    --ignore ".git" \
    --ignore ".gitignore" \
    --ignore ".DS_Store" \
    --ignore "logs" \
    2>&1 | grep -oE 'sync_[A-Za-z0-9]+' || true)

if [ -n "$SESSION" ]; then
    echo "Sync session created: $SESSION"
else
    echo "Sync session created."
fi

echo "Monitoring sync (Ctrl+C to stop)..."
echo ""

# Keep in foreground — monitor will show ongoing sync activity
"$MUTAGEN" sync monitor --label-selector "flipper=provision"
