#!/bin/ash

# --- Configuration ---
MODE="auto"
VERBOSE=0
THRESHOLD=80
FAST="/fastpool"
VAULT="/vaultpool"
LOG_FILE="/var/log/zfs_tier_migration.log"
LOCK_DIR="/tmp/zfs_tier_migration.lock"

# --- Tiering Timing ---
DEFAULT_MMIN=15
OVERRIDE_FILE="/etc/zfs_tier_overrides.conf"
# ---------------------

# --- Argument Parsing ---
for arg in "$@"; do
    case $arg in
        check)
            MODE="auto"
            ;;
        force)
            MODE="force"
            ;;
        -v|--verbose)
            VERBOSE=1
            ;;
    esac
done

# --- Helper Functions ---
log_msg() {
    # Always write to the log file
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
    
    # Only print to standard output (console) if verbose flag is passed
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
    fi
}

# --- Concurrency Lock with Stale Lock Detection ---
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ]; then
        LOCK_PID=$(cat "$LOCK_DIR/pid")
        if ! kill -0 "$LOCK_PID" 2>/dev/null; then
            log_msg "WARNING: Stale lock detected (Process $LOCK_PID is dead). Clearing and resuming."
            rm -rf "$LOCK_DIR"
            if ! mkdir "$LOCK_DIR" 2>/dev/null; then
                log_msg "CRITICAL: Failed to recreate lock after clearing stale lock. Exiting."
                exit 1
            fi
        else
            log_msg "SKIPPED: Script is already running (Active PID: $LOCK_PID)."
            exit 0
        fi
    else
        log_msg "SKIPPED: Script is currently spinning up (Lock exists, pending PID)."
        exit 0
    fi
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"; exit' INT TERM EXIT


# --- 1. Capacity Watchdog Logic ---
if [ "$MODE" != "force" ]; then
    CAP=$(zpool list -H -o capacity fastpool 2>/dev/null | tr -d '%')
    if [ -z "$CAP" ]; then exit 0; fi 
    if [ "$CAP" -lt "$THRESHOLD" ]; then
        exit 0
    fi
    log_msg "Capacity at ${CAP}%. Threshold (${THRESHOLD}%) breached. Initiating emergency flush."
else
    log_msg "Forced run initiated (Manual or Nightly schedule)."
fi


# --- 2. Symmetric Tiering Move Logic ---
for dir in "$FAST"/*; do
    [ -d "$dir" ] || continue
    DIR_NAME=$(basename "$dir")

    if [ -d "$VAULT/$DIR_NAME" ]; then
        
        # --- Override Logic Check ---
        TARGET_MMIN=$DEFAULT_MMIN
        if [ -f "$OVERRIDE_FILE" ]; then
            OVERRIDE_VAL=$(grep "^${DIR_NAME}=" "$OVERRIDE_FILE" 2>/dev/null | cut -d'=' -f2)
            
            if [ -n "$OVERRIDE_VAL" ]; then
                case "$OVERRIDE_VAL" in
                    ''|*[!0-9]*) 
                        log_msg "WARNING: Invalid override value '$OVERRIDE_VAL' for $DIR_NAME. Defaulting to ${DEFAULT_MMIN}m."
                        ;;
                    *) 
                        TARGET_MMIN=$OVERRIDE_VAL 
                        ;;
                esac
            fi
        fi

        log_msg "-> Tiered dataset found: $DIR_NAME. Migrating data idle for ${TARGET_MMIN}m+"
        
        # Navigate into the cache dataset
        cd "$FAST/$DIR_NAME" || continue
        
        # Execute the move, handling output based on the VERBOSE flag
        if [ "$VERBOSE" -eq 1 ]; then
            # Added --info=progress2 for a live, overall percentage and ETA bar.
            # We pipe through 'tr' to strip the carriage returns (\r) before they hit the log file, 
            # keeping your log file clean of animation text-garbage, while displaying normally on screen.
            find . -type f -mmin "+${TARGET_MMIN}" -print0 | rsync -0 -axRv --info=progress2 --remove-source-files --files-from=- . "$VAULT/$DIR_NAME/" 2>&1 | tee /dev/tty | tr -d '\r' >> "$LOG_FILE"
        else
            # Silently append rsync details to the log file only
            find . -type f -mmin "+${TARGET_MMIN}" -print0 | rsync -0 -axRv --remove-source-files --files-from=- . "$VAULT/$DIR_NAME/" >> "$LOG_FILE" 2>&1
        fi
        
        # Safely clean up empty subfolders left behind, ignoring the dataset root
        find "$FAST/$DIR_NAME" -mindepth 1 -type d -empty -delete
    else
        log_msg "-> Sabrent-only dataset found: $DIR_NAME. Skipping to preserve flash pinning."
    fi
done

log_msg "Cache flush complete. Sleeping drives will spin down automatically."
log_msg "--------------------------------------------------------"