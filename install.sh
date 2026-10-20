#!/bin/sh
# ==============================================================================
# Alpine Linux ZFS NAS - Unified Installer & Updater
# ==============================================================================
# Single-command interactive install / update:
#   wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-zfs-nas/main/install.sh | sh
#
# Single-command batch (non-interactive / cron) update:
#   wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-zfs-nas/main/install.sh | sh -s -- --batch
# ==============================================================================

set -u

GITHUB_REPO="${REPO_SLUG:-gpocali/alpine-linux-zfs-nas}"
GITHUB_BRANCH="${REPO_BRANCH:-main}"
TARGET_ROOT="${TARGET_ROOT:-/}"
LOCAL_SOURCE="${LOCAL_SOURCE_DIR:-}"

BATCH_MODE="${BATCH:-0}"
NO_REBOOT=0
FORCE_MODE=""
FORCE_CONFIGS=0
VERBOSE=0

LOCK_DIR="/tmp/alpine-nas-installer.lock"
STAGE_DIR=""

UPDATES_MADE=0
UPDATED_COUNT=0
CREATED_COUNT=0
MERGED_COUNT=0
SKIPPED_CONFIG_COUNT=0
UNCHANGED_COUNT=0
LBU_ADDED_COUNT=0
PKG_INSTALLED_COUNT=0

# Required Alpine APK packages for all deployed scripts & services:
# - python3               : Required by nas-ctl, nas-commander, and nas-keytool
# - zfs                   : Required for ZFS pool and dataset management
# - mergerfs, fuse        : Required by /etc/init.d/mergerfs-storage
# - samba, samba-common-tools : Required by manage-shares and manage-share-users
# - cifs-utils, rsync     : Required by cache-mover.sh, manage-remote-backups, and remote-backup-worker
# - tpm2-tools, clevis    : Required by zfs-tpm-loader, manage-remote-backups, and remote-backup-worker
# - smartmontools, hdparm : Required by array-control, generate-telemetry, and spindown.start
# - darkhttpd             : Required by /etc/init.d/array-dashboard
REQUIRED_PACKAGES="python3 zfs mergerfs fuse samba samba-common-tools cifs-utils rsync tpm2-tools clevis smartmontools hdparm darkhttpd"

# ==============================================================================
# Argument Parsing
# ==============================================================================
usage() {
    cat <<EOF
Usage: install.sh [OPTIONS]

Install or update the Alpine Linux ZFS NAS overlay from GitHub.

Options:
  -b, --batch, -y, --yes   Non-interactive batch mode: automatically runs
                           'lbu commit -d' and reboots if updates were applied
  --no-reboot              Do not reboot (or prompt to reboot) after updating
  -u, --update             Force update mode (never overwrite config files)
  --install                Force initial install mode
  --force-configs          Overwrite existing configuration files with repo defaults
  --branch <name>          GitHub branch to pull (default: ${GITHUB_BRANCH})
  --repo <owner/name>      GitHub repository slug (default: ${GITHUB_REPO})
  -v, --verbose            Print detailed file-by-file status
  -h, --help               Show this help message

Examples:
  # Interactive install or update via wget:
  wget -qO- https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/install.sh | sh

  # Automated batch update (for scripts or cron):
  wget -qO- https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/install.sh | sh -s -- --batch
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--batch|-y|--yes|--non-interactive)
            BATCH_MODE=1
            ;;
        --no-reboot)
            NO_REBOOT=1
            ;;
        -u|--update)
            FORCE_MODE="update"
            ;;
        --install)
            FORCE_MODE="install"
            ;;
        --force-configs)
            FORCE_CONFIGS=1
            ;;
        --branch)
            shift
            if [ $# -eq 0 ]; then
                echo "❌ Error: --branch requires a branch name." >&2
                exit 1
            fi
            GITHUB_BRANCH="$1"
            ;;
        --repo)
            shift
            if [ $# -eq 0 ]; then
                echo "❌ Error: --repo requires a repository slug (owner/repo)." >&2
                exit 1
            fi
            GITHUB_REPO="$1"
            ;;
        --local)
            shift
            if [ $# -eq 0 ]; then
                echo "❌ Error: --local requires a local repository directory path." >&2
                exit 1
            fi
            LOCAL_SOURCE="$1"
            ;;
        -v|--verbose)
            VERBOSE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Error: Unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

# ==============================================================================
# Helper Functions
# ==============================================================================
log_info() {
    printf "\033[1;36m[INFO]\033[0m %s\n" "$1"
}

log_ok() {
    printf "\033[1;32m[ OK ]\033[0m %s\n" "$1"
}

log_warn() {
    printf "\033[1;33m[WARN]\033[0m %s\n" "$1"
}

log_err() {
    printf "\033[1;31m[ERR ]\033[0m %s\n" "$1" >&2
}

log_verbose() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf "       %s\n" "$1"
    fi
}

cleanup() {
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        rm -rf "$STAGE_DIR"
    fi
    if [ -d "$LOCK_DIR" ] && [ -f "$LOCK_DIR/pid" ]; then
        if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
            rm -rf "$LOCK_DIR"
        fi
    fi
}

# Prompt user even when script is piped via 'wget -qO- ... | sh'
prompt_yes_no() {
    PROMPT_MSG="$1"
    DEFAULT_ANS="${2:-N}"
    ANS=""

    if [ -t 0 ]; then
        printf "%s" "$PROMPT_MSG"
        read -r ANS || ANS=""
    elif ( : </dev/tty ) 2>/dev/null; then
        printf "%s" "$PROMPT_MSG" >/dev/tty
        read -r ANS </dev/tty || ANS=""
    else
        log_warn "No interactive terminal available; defaulting response to '${DEFAULT_ANS}'."
        ANS="$DEFAULT_ANS"
    fi

    [ -z "$ANS" ] && ANS="$DEFAULT_ANS"
    case "$ANS" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Normalize Target Path (handles TARGET_ROOT="/" or custom prefix for testing)
target_path() {
    REL_PATH="${1#/}"
    if [ "$TARGET_ROOT" = "/" ]; then
        echo "/$REL_PATH"
    else
        echo "${TARGET_ROOT%/}/$REL_PATH"
    fi
}

# Ensure a file outside /etc is registered with Alpine LBU
register_lbu_path() {
    REL_PATH="${1#/}"
    DEST_FILE=$(target_path "$REL_PATH")

    # Only operate on real root or when lbu is present
    LBU_INCLUDE_FILE=$(target_path "etc/lbu/include")

    # Alpine LBU automatically includes /etc; files outside /etc (e.g. /usr/local/bin, /var/www)
    # must be registered in /etc/lbu/include.
    case "$REL_PATH" in
        etc/*)
            return 0
            ;;
    esac

    mkdir -p "$(dirname "$LBU_INCLUDE_FILE")"
    touch "$LBU_INCLUDE_FILE"

    if ! grep -qxF "$REL_PATH" "$LBU_INCLUDE_FILE" 2>/dev/null; then
        if [ "$TARGET_ROOT" = "/" ] && command -v lbu >/dev/null 2>&1; then
            lbu include "$DEST_FILE" >/dev/null 2>&1 || echo "$REL_PATH" >> "$LBU_INCLUDE_FILE"
        else
            echo "$REL_PATH" >> "$LBU_INCLUDE_FILE"
        fi
        LBU_ADDED_COUNT=$((LBU_ADDED_COUNT + 1))
        UPDATES_MADE=1
        log_info "Added /$REL_PATH to LBU include list."
    else
        log_verbose "Already in LBU include list: /$REL_PATH"
    fi
}

# ==============================================================================
# Pre-Flight & Concurrency Checks
# ==============================================================================
if [ "$TARGET_ROOT" = "/" ] && [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/pid" ]; then
        LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
        if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
            log_err "Another instance of install.sh is already running (PID: $LOCK_PID)."
            exit 1
        fi
        log_warn "Clearing stale installer lock (PID: ${LOCK_PID:-unknown})."
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR"
    else
        log_err "Could not acquire lock at $LOCK_DIR."
        exit 1
    fi
fi
echo "$$" > "$LOCK_DIR/pid"
trap 'cleanup; exit' INT TERM EXIT

# ==============================================================================
# Mode Detection (Initial Install vs. Update Mode)
# ==============================================================================
MARKER_FILE=$(target_path "etc/alpine-zfs-nas.installed")
PROBE_BIN=$(target_path "usr/local/bin/manage-shares")

if [ -n "$FORCE_MODE" ]; then
    INSTALL_MODE="$FORCE_MODE"
elif [ -f "$MARKER_FILE" ] || [ -f "$PROBE_BIN" ]; then
    INSTALL_MODE="update"
else
    INSTALL_MODE="install"
fi

printf "\033[1;36m======================================================================\033[0m\n"
printf "\033[1;32m         Alpine Linux ZFS NAS - %s\033[0m\n" "$( [ "$INSTALL_MODE" = "update" ] && echo "System Updater" || echo "System Installer" )"
printf "\033[1;36m======================================================================\033[0m\n"
log_info "Operating Mode : $INSTALL_MODE $( [ "$BATCH_MODE" -eq 1 ] && echo "(Batch / Non-Interactive)" || echo "(Interactive)" )"
log_info "Repository     : ${GITHUB_REPO} (branch: ${GITHUB_BRANCH})"

# ==============================================================================
# Stage Latest Repository from GitHub
# ==============================================================================
STAGE_DIR=$(mktemp -d /tmp/alpine-nas-staging.XXXXXX)
ARCHIVE_FILE="$STAGE_DIR/repo.tar.gz"
ARCHIVE_URL="https://github.com/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

log_info "Downloading latest repository snapshot to staging directory ($STAGE_DIR)..."

DOWNLOAD_OK=0
if [ -n "$LOCAL_SOURCE" ] && [ -d "$LOCAL_SOURCE/root" ]; then
    mkdir -p "$STAGE_DIR/local-repo"
    cp -R "$LOCAL_SOURCE/root" "$STAGE_DIR/local-repo/"
    [ -f "$LOCAL_SOURCE/install.sh" ] && cp "$LOCAL_SOURCE/install.sh" "$STAGE_DIR/local-repo/"
    DOWNLOAD_OK=1
elif command -v wget >/dev/null 2>&1; then
    if wget -qO "$ARCHIVE_FILE" "$ARCHIVE_URL" && [ -s "$ARCHIVE_FILE" ]; then
        if tar -xzf "$ARCHIVE_FILE" -C "$STAGE_DIR" 2>/dev/null; then
            DOWNLOAD_OK=1
        fi
    fi
fi

if [ "$DOWNLOAD_OK" -eq 0 ] && command -v git >/dev/null 2>&1; then
    log_warn "Tarball download failed; attempting git clone..."
    if git clone --depth 1 -b "$GITHUB_BRANCH" "https://github.com/${GITHUB_REPO}.git" "$STAGE_DIR/repo" >/dev/null 2>&1; then
        DOWNLOAD_OK=1
    fi
fi

if [ "$DOWNLOAD_OK" -eq 0 ]; then
    log_err "Failed to download repository from GitHub (${ARCHIVE_URL})."
    exit 1
fi

# Locate extracted repository directory containing root/
STAGE_REPO=""
for d in "$STAGE_DIR"/*; do
    if [ -d "$d/root" ]; then
        STAGE_REPO="$d"
        break
    fi
done

if [ -z "$STAGE_REPO" ] || [ ! -d "$STAGE_REPO/root" ]; then
    log_err "Staging validation failed: 'root/' overlay directory not found in downloaded archive."
    exit 1
fi

STAGE_ROOT="$STAGE_REPO/root"
log_ok "Staged latest files at $STAGE_ROOT"

# ==============================================================================
# Additive Mergers for Shared System Files (/etc/modules, repos, crontabs)
# ==============================================================================

# 1. /etc/modules: Append missing kernel modules without removing entries added by other processes
merge_etc_modules() {
    SRC_FILE="$1"
    DEST_FILE=$(target_path "etc/modules")
    mkdir -p "$(dirname "$DEST_FILE")"
    touch "$DEST_FILE"

    ADDED_MODULES=0
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line=$(printf "%s" "$raw_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac

        # Extract module name (first token)
        mod_name=$(printf "%s" "$line" | awk '{print $1}')
        if ! grep -Eq "^[[:space:]]*${mod_name}([[:space:]]|#|$)" "$DEST_FILE" 2>/dev/null; then
            # Ensure file ends with newline before appending
            [ -s "$DEST_FILE" ] && sed -i -e '$a\' "$DEST_FILE" 2>/dev/null || true
            echo "$line" >> "$DEST_FILE"
            ADDED_MODULES=$((ADDED_MODULES + 1))
            log_info "Merged kernel module '$line' into /etc/modules"
        fi
    done < "$SRC_FILE"

    if [ "$ADDED_MODULES" -gt 0 ]; then
        MERGED_COUNT=$((MERGED_COUNT + 1))
        UPDATES_MADE=1
    else
        UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
        log_verbose "No missing modules in /etc/modules"
    fi
}

# 2. /etc/apk/repositories: Append missing package repositories without overwriting system/user mirrors
merge_apk_repositories() {
    SRC_FILE="$1"
    DEST_FILE=$(target_path "etc/apk/repositories")
    mkdir -p "$(dirname "$DEST_FILE")"
    touch "$DEST_FILE"

    ADDED_REPOS=0
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line=$(printf "%s" "$raw_line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac

        if ! grep -qxF "$line" "$DEST_FILE" 2>/dev/null; then
            [ -s "$DEST_FILE" ] && sed -i -e '$a\' "$DEST_FILE" 2>/dev/null || true
            echo "$line" >> "$DEST_FILE"
            ADDED_REPOS=$((ADDED_REPOS + 1))
            log_info "Merged APK repository '$line' into /etc/apk/repositories"
        fi
    done < "$SRC_FILE"

    if [ "$ADDED_REPOS" -gt 0 ]; then
        MERGED_COUNT=$((MERGED_COUNT + 1))
        UPDATES_MADE=1
    else
        UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
        log_verbose "No missing entries in /etc/apk/repositories"
    fi
}

# 3. /etc/crontabs/root: Preserve jobs written by manage-remote-backups or user, adding only missing jobs
merge_root_crontab() {
    SRC_FILE="$1"
    DEST_FILE=$(target_path "etc/crontabs/root")
    mkdir -p "$(dirname "$DEST_FILE")"

    if [ ! -f "$DEST_FILE" ]; then
        tr -d '\r' < "$SRC_FILE" > "$DEST_FILE"
        chmod 0600 "$DEST_FILE"
        CREATED_COUNT=$((CREATED_COUNT + 1))
        UPDATES_MADE=1
        log_info "Created /etc/crontabs/root"
        if [ "$TARGET_ROOT" = "/" ] && command -v rc-service >/dev/null 2>&1; then
            rc-service crond reload >/dev/null 2>&1 || true
        fi
        return
    fi

    ADDED_CRONS=0
    PENDING_COMMENT=""

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line=$(printf "%s" "$raw_line" | tr -d '\r')
        trimmed=$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [ -z "$trimmed" ]; then
            PENDING_COMMENT=""
            continue
        fi

        case "$trimmed" in
            \#*)
                PENDING_COMMENT="$line"
                continue
                ;;
        esac

        # Extract the command signature (fields 6+ before output redirection '>' or '>>')
        cmd_sig=$(printf "%s" "$trimmed" | awk '{for(i=6;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}' | sed 's/[[:space:]]*>>.*$//;s/[[:space:]]*>.*$//')

        ALREADY_PRESENT=0
        if grep -qxF "$trimmed" "$DEST_FILE" 2>/dev/null; then
            ALREADY_PRESENT=1
        elif [ -n "$cmd_sig" ] && grep -v '^[[:space:]]*#' "$DEST_FILE" 2>/dev/null | grep -qF "$cmd_sig"; then
            ALREADY_PRESENT=1
        fi

        if [ "$ALREADY_PRESENT" -eq 0 ]; then
            [ -s "$DEST_FILE" ] && sed -i -e '$a\' "$DEST_FILE" 2>/dev/null || true
            if [ -n "$PENDING_COMMENT" ] && ! grep -qxF "$PENDING_COMMENT" "$DEST_FILE" 2>/dev/null; then
                echo "" >> "$DEST_FILE"
                echo "$PENDING_COMMENT" >> "$DEST_FILE"
            fi
            echo "$trimmed" >> "$DEST_FILE"
            ADDED_CRONS=$((ADDED_CRONS + 1))
            log_info "Merged cron job '$cmd_sig' into /etc/crontabs/root"
        fi
        PENDING_COMMENT=""
    done < "$SRC_FILE"

    if [ "$ADDED_CRONS" -gt 0 ]; then
        chmod 0600 "$DEST_FILE"
        MERGED_COUNT=$((MERGED_COUNT + 1))
        UPDATES_MADE=1
        if [ "$TARGET_ROOT" = "/" ] && command -v rc-service >/dev/null 2>&1; then
            rc-service crond reload >/dev/null 2>&1 || true
        fi
    else
        UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
        log_verbose "No missing cron jobs in /etc/crontabs/root"
    fi
}

# ==============================================================================
# Configuration & Managed File Handlers
# ==============================================================================

# Returns 0 if the relative path is a configuration file that must not be overwritten in update mode
is_protected_config() {
    REL_PATH="${1#/}"
    case "$REL_PATH" in
        etc/lbu/lbu.conf|etc/samba/shares.list|etc/samba/smb.conf|etc/nas-commander.env|etc/zfs_tier_overrides.conf|etc/remote-backups/*)
            return 0
            ;;
        etc/*.conf|etc/*/*.conf|etc/*.list|etc/*/*.list|etc/*.env|etc/*/*.env|etc/*.cfg|etc/*/*.cfg)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Determine appropriate permissions for a managed file
file_permissions_for() {
    REL_PATH="${1#/}"
    case "$REL_PATH" in
        usr/local/bin/*|etc/init.d/*|etc/local.d/*.start|etc/local.d/*.stop|etc/profile.d/*.sh)
            echo "755"
            ;;
        etc/crontabs/*|etc/nas-commander.env)
            echo "600"
            ;;
        *)
            echo "644"
            ;;
    esac
}

install_or_update_file() {
    SRC_FILE="$1"
    REL_PATH="${2#/}"
    DEST_FILE=$(target_path "$REL_PATH")
    TARGET_MODE=$(file_permissions_for "$REL_PATH")

    # 1. Handle multi-process shared configuration files via non-destructive merge
    case "$REL_PATH" in
        etc/modules)
            merge_etc_modules "$SRC_FILE"
            return
            ;;
        etc/apk/repositories)
            merge_apk_repositories "$SRC_FILE"
            return
            ;;
        etc/crontabs/root)
            merge_root_crontab "$SRC_FILE"
            return
            ;;
    esac

    # 2. Handle protected configuration files
    if is_protected_config "$REL_PATH" && [ "$FORCE_CONFIGS" -eq 0 ]; then
        if [ -f "$DEST_FILE" ]; then
            if [ "$INSTALL_MODE" = "update" ]; then
                SKIPPED_CONFIG_COUNT=$((SKIPPED_CONFIG_COUNT + 1))
                log_verbose "Skipped existing config in update mode: /$REL_PATH"
                return
            fi

            # Even during initial install, protect pre-populated user configurations
            case "$REL_PATH" in
                etc/samba/shares.list)
                    if [ -s "$DEST_FILE" ]; then
                        SKIPPED_CONFIG_COUNT=$((SKIPPED_CONFIG_COUNT + 1))
                        log_info "Preserved non-empty share list: /$REL_PATH"
                        return
                    fi
                    ;;
                etc/samba/smb.conf)
                    SHARES_LIST_FILE=$(target_path "etc/samba/shares.list")
                    if [ -s "$SHARES_LIST_FILE" ]; then
                        SKIPPED_CONFIG_COUNT=$((SKIPPED_CONFIG_COUNT + 1))
                        log_info "Preserved active Samba configuration: /$REL_PATH"
                        return
                    fi
                    ;;
                etc/lbu/lbu.conf)
                    # Only replace default Alpine lbu.conf if LBU_MEDIA / LBU_BACKUPDIR isn't already customized
                    if grep -Eq '^[[:space:]]*LBU_BACKUPDIR=' "$DEST_FILE" 2>/dev/null; then
                        SKIPPED_CONFIG_COUNT=$((SKIPPED_CONFIG_COUNT + 1))
                        log_info "Preserved custom LBU configuration: /$REL_PATH"
                        return
                    fi
                    ;;
            esac
        fi
    fi

    # 3. Stage normalized copy (strip CR if any)
    TMP_NORM="$STAGE_DIR/norm_file.$$"
    tr -d '\r' < "$SRC_FILE" > "$TMP_NORM"

    # Special safeguard for /etc/init.d/mergerfs-storage in update mode:
    # Preserve user-selected active command_args tiering line (e.g., /vaultpool vs /fastpool:/vaultpool)
    if [ "$REL_PATH" = "etc/init.d/mergerfs-storage" ] && [ "$INSTALL_MODE" = "update" ] && [ -f "$DEST_FILE" ] && [ "$FORCE_CONFIGS" -eq 0 ]; then
        EXISTING_ARGS=$(grep '^command_args=' "$DEST_FILE" 2>/dev/null | head -n 1 || true)
        NEW_ARGS=$(grep '^command_args=' "$TMP_NORM" 2>/dev/null | head -n 1 || true)
        if [ -n "$EXISTING_ARGS" ] && [ -n "$NEW_ARGS" ] && [ "$EXISTING_ARGS" != "$NEW_ARGS" ]; then
            awk -v existing="$EXISTING_ARGS" '
                /^command_args=/ { print existing; next }
                { print }
            ' "$TMP_NORM" > "${TMP_NORM}.merged"
            mv "${TMP_NORM}.merged" "$TMP_NORM"
            log_verbose "Preserved active command_args in /etc/init.d/mergerfs-storage"
        fi
    fi

    mkdir -p "$(dirname "$DEST_FILE")"

    if [ ! -f "$DEST_FILE" ]; then
        cp -f "$TMP_NORM" "$DEST_FILE"
        chmod "$TARGET_MODE" "$DEST_FILE"
        CREATED_COUNT=$((CREATED_COUNT + 1))
        UPDATES_MADE=1
        log_info "Installed new file: /$REL_PATH"
    elif ! cmp -s "$TMP_NORM" "$DEST_FILE"; then
        cp -f "$TMP_NORM" "$DEST_FILE"
        chmod "$TARGET_MODE" "$DEST_FILE"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        UPDATES_MADE=1
        log_info "Updated file: /$REL_PATH"
    else
        # Verify permissions match expected mode (BusyBox stat -c "%a" returns 3-digit octal like 755/644)
        CURRENT_MODE=$(stat -c "%a" "$DEST_FILE" 2>/dev/null || echo "$TARGET_MODE")
        CURRENT_MODE="${CURRENT_MODE#0}"
        if [ "$CURRENT_MODE" != "$TARGET_MODE" ]; then
            chmod "$TARGET_MODE" "$DEST_FILE"
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
            UPDATES_MADE=1
            log_info "Fixed permissions ($TARGET_MODE) on: /$REL_PATH"
        else
            UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
            log_verbose "Unchanged: /$REL_PATH"
        fi
    fi

    rm -f "$TMP_NORM"

    # 4. Ensure file is registered in LBU
    register_lbu_path "$REL_PATH"
}

# ==============================================================================
# Process All Files in Staged Overlay
# ==============================================================================
log_info "Synchronizing filesystem with staged repository..."

FILE_LIST="$STAGE_DIR/file_list.txt"
(cd "$STAGE_ROOT" && find . -type f | sed 's|^\./||' | sort) > "$FILE_LIST"

while IFS= read -r rel_file || [ -n "$rel_file" ]; do
    [ -z "$rel_file" ] && continue
    install_or_update_file "$STAGE_ROOT/$rel_file" "$rel_file"
done < "$FILE_LIST"

# Also install/update this script at /usr/local/bin/nas-update for convenient local & cron execution
if [ -f "$STAGE_REPO/install.sh" ]; then
    install_or_update_file "$STAGE_REPO/install.sh" "usr/local/bin/nas-update"
fi

# Record installation marker on first install
if [ ! -f "$MARKER_FILE" ]; then
    mkdir -p "$(dirname "$MARKER_FILE")"
    echo "INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')" > "$MARKER_FILE"
    chmod 0644 "$MARKER_FILE"
    UPDATES_MADE=1
fi

# Clean up staging directory now that filesystem updates are complete
if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
    STAGE_DIR=""
fi

# ==============================================================================
# Dependency Verification & APK Package Installation
# ==============================================================================
ensure_dependencies() {
    if [ "$TARGET_ROOT" != "/" ]; then
        log_verbose "Custom TARGET_ROOT ($TARGET_ROOT) active; skipping live APK dependency installation."
        return 0
    fi

    if ! command -v apk >/dev/null 2>&1; then
        log_warn "'apk' package manager not found; skipping dependency installation."
        return 0
    fi

    MISSING_PKGS=""
    MISSING_COUNT=0
    for pkg in $REQUIRED_PACKAGES; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            if [ -z "$MISSING_PKGS" ]; then
                MISSING_PKGS="$pkg"
            else
                MISSING_PKGS="$MISSING_PKGS $pkg"
            fi
            MISSING_COUNT=$((MISSING_COUNT + 1))
        else
            log_verbose "Dependency already installed: $pkg"
        fi
    done

    if [ "$MISSING_COUNT" -eq 0 ]; then
        log_ok "All required APK package dependencies are already installed."
        return 0
    fi

    log_info "Installing $MISSING_COUNT missing APK dependency package(s): $MISSING_PKGS"
    # shellcheck disable=SC2086
    if apk update >/dev/null 2>&1 && apk add $MISSING_PKGS; then
        PKG_INSTALLED_COUNT="$MISSING_COUNT"
        UPDATES_MADE=1
        log_ok "Installed missing dependencies: $MISSING_PKGS"
    else
        log_warn "Bulk 'apk add' encountered an error; attempting package-by-package installation..."
        for pkg in $MISSING_PKGS; do
            if apk add "$pkg"; then
                PKG_INSTALLED_COUNT=$((PKG_INSTALLED_COUNT + 1))
                UPDATES_MADE=1
                log_info "Installed dependency package: $pkg"
            else
                log_err "Failed to install dependency package: $pkg"
            fi
        done
    fi
}

ensure_dependencies

# ==============================================================================
# Summary Report
# ==============================================================================
echo ""
printf "\033[1;36m----------------------------------------------------------------------\033[0m\n"
printf "\033[1;37m Synchronization Summary (%s mode):\033[0m\n" "$INSTALL_MODE"
printf "   Created Files            : %d\n" "$CREATED_COUNT"
printf "   Updated Files            : %d\n" "$UPDATED_COUNT"
printf "   Merged System Configs    : %d\n" "$MERGED_COUNT"
printf "   Protected Configs Kept   : %d\n" "$SKIPPED_CONFIG_COUNT"
printf "   New LBU Include Entries  : %d\n" "$LBU_ADDED_COUNT"
printf "   APK Packages Installed   : %d\n" "$PKG_INSTALLED_COUNT"
printf "   Unchanged Files          : %d\n" "$UNCHANGED_COUNT"
printf "\033[1;36m----------------------------------------------------------------------\033[0m\n"

# ==============================================================================
# LBU Commit & Reboot Workflow (Batch vs. Interactive)
# ==============================================================================
commit_lbu() {
    if ! command -v lbu >/dev/null 2>&1; then
        log_warn "'lbu' command not found on this system; skipping LBU commit."
        return 0
    fi
    log_info "Committing configuration overlay to persistent media (lbu commit -d)..."
    if lbu commit -d; then
        log_ok "LBU commit completed successfully."
        return 0
    else
        log_err "LBU commit failed! Check /etc/lbu/lbu.conf and boot media."
        return 1
    fi
}

trigger_reboot() {
    log_info "Initiating system reboot..."
    if command -v reboot >/dev/null 2>&1; then
        reboot
    elif [ -x /sbin/reboot ]; then
        /sbin/reboot
    else
        log_err "Could not locate 'reboot' command."
        return 1
    fi
}

if [ "$BATCH_MODE" -eq 1 ]; then
    if [ "$UPDATES_MADE" -eq 1 ]; then
        log_info "Batch mode: Updates were applied."
        if ! commit_lbu; then
            log_err "Batch mode: Aborting automatic reboot because LBU commit failed."
            exit 1
        fi
        if [ "$NO_REBOOT" -eq 0 ]; then
            trigger_reboot
        else
            log_info "Batch mode: Reboot skipped (--no-reboot flag set)."
        fi
    else
        log_ok "Batch mode: System is already up to date. No LBU commit or reboot required."
    fi
    exit 0
fi

# Interactive Mode
echo ""
if prompt_yes_no "💾 Do you want to commit changes to LBU now (lbu commit -d)? [y/N]: " "N"; then
    commit_lbu || true
else
    if [ "$UPDATES_MADE" -eq 1 ]; then
        log_warn "Changes remain in RAM only. Run 'lbu commit -d' before rebooting to persist them."
    fi
fi

if [ "$UPDATES_MADE" -eq 1 ] && [ "$NO_REBOOT" -eq 0 ]; then
    echo ""
    if prompt_yes_no "🔄 Updates were applied. Do you want to reboot the system now? [y/N]: " "N"; then
        trigger_reboot
    else
        log_info "Reboot skipped. You can reboot later when ready."
    fi
else
    log_ok "No file updates were applied; no reboot required."
fi
