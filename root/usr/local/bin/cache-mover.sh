#!/bin/ash

# --- Configuration ---
MODE=$1
THRESHOLD=80
FAST="/fastpool"
VAULT="/vaultpool"
# ---------------------

# 1. Capacity Watchdog Logic
if [ "$MODE" != "force" ]; then
    # Grab the exact capacity integer from the fastpool
    CAP=$(zpool list -H -o capacity fastpool 2>/dev/null | tr -d '%')
    
    # If the pool doesn't exist yet, silently exit to prevent errors
    if [ -z "$CAP" ]; then exit 0; fi 
    
    if [ "$CAP" -lt "$THRESHOLD" ]; then
        # We are under 80%, do nothing and exit silently
        exit 0
    fi
    echo "$(date): Capacity at ${CAP}%. Threshold (${THRESHOLD}%) breached. Initiating emergency flush."
else
    echo "$(date): Forced run initiated (Nightly 2:00 AM schedule)."
fi

# 2. Symmetric Tiering Move Logic
# Loop through all top-level dataset directories in the NVMe cache
for dir in "$FAST"/*; do
    [ -d "$dir" ] || continue
    DIR_NAME=$(basename "$dir")

    if [ -d "$VAULT/$DIR_NAME" ]; then
        echo " -> Tiered dataset found: $DIR_NAME. Migrating idle data..."
        
        # Navigate into the cache dataset
        cd "$FAST/$DIR_NAME" || continue
        
        # The Safety Filter:
        # 1. 'find . -type f -mmin +15' locates only files unmodified for 15+ minutes.
        # 2. '-print0' and 'rsync -0' ensure files with spaces in their names don't break the command.
        # 3. '-R' (relative) ensures the internal folder structure is preserved when moved.
        find . -type f -mmin +15 -print0 | rsync -0 -axR --remove-source-files --files-from=- . "$VAULT/$DIR_NAME/"
        
        # Safely clean up empty subfolders left behind, ignoring the dataset root
        find "$FAST/$DIR_NAME" -mindepth 1 -type d -empty -delete
    else
        echo " -> Sabrent-only dataset found: $DIR_NAME. Skipping to preserve flash pinning."
    fi
done

echo "$(date): Cache flush complete. Sleeping drives will spin down automatically."
echo "--------------------------------------------------------"
