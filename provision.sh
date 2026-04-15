#!/bin/bash
set -euo pipefail

SERVICE_TYPE="_flipper._tcp"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
SSH_USER="user"
BROWSE_TIMEOUT=2      # seconds to collect mDNS responses

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
                printf "  [%d] %s.local\n" "$SEEN_COUNT" "$instance"
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
    if [ ${#INSTANCES[@]} -eq 1 ]; then
        IDX=0
        echo "Selected: ${INSTANCES[0]}.local"
    else
        read -rp "Select device number [1-${#INSTANCES[@]}]: " CHOICE
        if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#INSTANCES[@]} ]; then
            echo "Invalid selection."
            exit 1
        fi
        IDX=$((CHOICE - 1))
        echo "Selected: ${INSTANCES[$IDX]}.local"
    fi

    HOST="${INSTANCES[$IDX]}.local"
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

echo "Installing SSH key to $SSH_USER@$HOST (password: '$SSH_USER')..."
ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$SSH_USER@$HOST"
echo ""

echo "Done. Connect with: ssh $SSH_USER@$HOST"
