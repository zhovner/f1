#!/bin/bash
set -euo pipefail
trap 'exit 0' INT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_TYPE="_flipper._tcp"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
SSH_USER="user"
REMOTE_DIR="/home/$SSH_USER/f1"
BROWSE_TIMEOUT=2      # seconds to collect mDNS responses
RESOLVE_TIMEOUT=2     # seconds to resolve hostname

SSH_OPTS=(-o LogLevel=error -o StrictHostKeyChecking=accept-new)

RSYNC_EXCLUDES=(
    --exclude '/.git/'
    --exclude '/.gitignore'
    --exclude '.DS_Store'
    --exclude '.claude/'
    --exclude 'logs/'
    --exclude 'provision.sh'
)

if [ -n "${1:-}" ]; then
    # ── Manual mode: IP or hostname provided as argument ────────────────────
    HOST="$1"
    echo "Using provided host: $HOST"
    echo ""
else
    # ── Discover Flipper One devices via mDNS (streaming) ───────────────────

    echo "Searching for Flipper One devices on LAN..."
    echo ""

    BROWSE_OUTPUT=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$BROWSE_OUTPUT'" EXIT

    # Start dns-sd in background, stream its output
    dns-sd -B "$SERVICE_TYPE" . >"$BROWSE_OUTPUT" 2>&1 </dev/null &
    BROWSE_PID=$!

    INSTANCES=()
    SEEN_COUNT=0
    DEADLINE=$(($(date +%s) + BROWSE_TIMEOUT))

    # Poll for new Add lines until deadline
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        while IFS= read -r instance; do
            # Skip if already seen
            found=false
            for existing in "${INSTANCES[@]+"${INSTANCES[@]}"}"; do
                [ "$existing" = "$instance" ] && found=true && break
            done
            if [ "$found" = false ] && [ -n "$instance" ]; then
                INSTANCES+=("$instance")
                SEEN_COUNT=$((SEEN_COUNT + 1))
                printf "  [%d] %s\n" "$SEEN_COUNT" "$instance"
            fi
        done < <(awk '$2 == "Add" {print $NF}' "$BROWSE_OUTPUT" 2>/dev/null | sort -u)
        sleep 0.1
    done

    kill "$BROWSE_PID" 2>/dev/null || true
    wait "$BROWSE_PID" 2>/dev/null || true

    if [ ${#INSTANCES[@]} -eq 0 ]; then
        echo "No Flipper One devices found on LAN."
        echo "Make sure the device is powered on and connected to the same network."
        exit 1
    fi

    echo ""
    read -rp "Select device number [1-${#INSTANCES[@]}]: " CHOICE
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#INSTANCES[@]} ]; then
        echo "Invalid selection."
        exit 1
    fi
    IDX=$((CHOICE - 1))

    SELECTED="${INSTANCES[$IDX]}"

    # ── Resolve actual hostname via dns-sd -L ───────────────────────────────
    # Instance name != hostname (instance may include serial prefix etc.)

    echo "Resolving ${SELECTED}..."
    LOOKUP_OUTPUT=$(mktemp)
    dns-sd -L "$SELECTED" "$SERVICE_TYPE" local. >"$LOOKUP_OUTPUT" 2>&1 </dev/null &
    LOOKUP_PID=$!
    sleep "$RESOLVE_TIMEOUT"
    kill "$LOOKUP_PID" 2>/dev/null || true
    wait "$LOOKUP_PID" 2>/dev/null || true

    HOST=$(grep 'can be reached at' "$LOOKUP_OUTPUT" | head -1 | sed -E 's/.*can be reached at ([^ :]+).*/\1/' | sed 's/\.$//')
    rm -f "$LOOKUP_OUTPUT"

    if [ -z "$HOST" ]; then
        HOST="${SELECTED}.local"
    fi

    echo "Host: $HOST"
    echo ""
fi

# ── Remove old SSH host key ──────────────────────────────────────────────────

echo "Removing old SSH host key for $HOST..."
ssh-keygen -R "$HOST" 2>&1 | grep -v '^#' || true
echo ""

# ── Upload SSH key ───────────────────────────────────────────────────────────

if [ ! -f "$SSH_KEY" ]; then
    echo "SSH key not found at $SSH_KEY"
    echo "Generate one with: ssh-keygen -t ed25519"
    exit 1
fi

echo "Installing SSH key to $SSH_USER@$HOST..."
ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$SSH_USER@$HOST"
echo ""

# ── Sync files to remote host ───────────────────────────────────────────────

do_sync() {
    # Pull remote changes first (newer files win)
    rsync -rltz --update --force --itemize-changes \
        --no-perms --no-owner --no-group --omit-dir-times \
        -e "ssh ${SSH_OPTS[*]}" \
        "${RSYNC_EXCLUDES[@]}" \
        "$SSH_USER@$HOST:$REMOTE_DIR/" "$SCRIPT_DIR/" </dev/null
    # Push local changes to remote (newer files win, delete remote-only files)
    rsync -rltz --update --delete --force --itemize-changes \
        --no-perms --no-owner --no-group --omit-dir-times \
        -e "ssh ${SSH_OPTS[*]}" \
        "${RSYNC_EXCLUDES[@]}" \
        "$SCRIPT_DIR/" "$SSH_USER@$HOST:$REMOTE_DIR/" </dev/null
}

read -rp "Sync current folder to $SSH_USER@$HOST:$REMOTE_DIR? [Y/n] " SYNC_ANSWER
SYNC_ANSWER="${SYNC_ANSWER:-Y}"

if [[ "$SYNC_ANSWER" =~ ^[Yy]$ ]]; then
    echo ""
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$HOST" "mkdir -p '$REMOTE_DIR'"
    echo "Syncing files..."
    do_sync
    echo "Done."
    echo ""

    echo "Press Enter to sync again, Ctrl+C to quit."
    set +e
    while true; do
        if ! read -r </dev/tty; then
            echo "(stdin closed, exiting)"
            break
        fi
        echo -n "[$(date '+%H:%M:%S')] Syncing... "
        OUT=$(do_sync 2>&1)
        if [ -n "$OUT" ]; then
            echo ""
            echo "$OUT" | sed 's/^/  /'
        else
            echo "no changes."
        fi
    done
else
    echo ""
    echo "Done. Connect with: ssh $SSH_USER@$HOST"
fi
