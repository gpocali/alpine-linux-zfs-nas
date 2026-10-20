#!/bin/ash

# Clear the screen for a clean login presentation
clear

# Header
printf "\033[1;36m======================================================================\033[0m\n"
printf "\033[1;32m                 Alpine ZFS Storage & Media Vault\033[0m\n"
printf "\033[1;36m======================================================================\033[0m\n\n"

# Custom Master Utilities
printf "\033[1;33m► Interactive Master Dashboards & CLI:\033[0m\n"
printf "  \033[1;37mnas-ctl\033[0m               : Unified CLI controller (Status, Shares, ZFS, Net, Keys)\n"
printf "  \033[1;37mmanage-shares\033[0m         : Master UI for ZFS datasets, quotas, snapshots, & Samba\n"
printf "  \033[1;37mmanage-share-users\033[0m    : Master UI to add/remove/modify Samba users\n"
printf "  \033[1;37mmanage-remote-backups\033[0m : Master UI for TPM-sealed remote SMB backup mirrors\n\n"

# Security & API Management
printf "\033[1;33m► Security & Remote API Management:\033[0m\n"
printf "  \033[1;37mnas-keytool\033[0m           : Generate or rotate Commander API key (generate/rotate)\n"
printf "  \033[1;37mnas-commander\033[0m         : Authenticated REST API daemon for remote control (8081)\n\n"

# Hardware & Array Management
printf "\033[1;33m► Hardware & Storage Control:\033[0m\n"
printf "  \033[1;37marray-control status\033[0m  : Manage array drive sleep states (up/down/status)\n"
printf "  \033[1;37mcache-mover.sh\033[0m        : Flush NVMe fastpool -> HDD vaultpool (check/force/-v)\n\n"

# Background Automations
printf "\033[1;33m► Background Daemons & Automations:\033[0m\n"
printf "  \033[1;37mzfs-autokeeper\033[0m        : (Daily at 00:05) Takes daily snaps & prunes expired\n"
printf "  \033[1;37mgenerate-telemetry\033[0m    : (Every Minute) Exports JSON telemetry to Web UI\n"
printf "  \033[1;37mremote-backup-worker\033[0m  : (Cron Scheduled) Unseals TPM & runs rsync SMB mirror\n\n"

# Service Management
printf "\033[1;33m► Service Management:\033[0m\n"
printf "  Restart Samba         : rc-service samba restart\n"
printf "  Restart Web UI        : rc-service array-dashboard restart\n"
printf "  \033[1;31mSave OS to Flash      : lbu commit -d\033[0m\n\n"

# Crucial System Paths
printf "\033[1;33m► Key Architecture Paths:\033[0m\n"
printf "  \033[1;37m/mnt\033[0m                  : Master MergerFS mount (Network shares root)\n"
printf "  \033[1;37m/var/www/dashboard\033[0m    : Web UI root (JSON telemetry & dashboard)\n"
printf "  \033[1;37m/etc/samba/smb.conf\033[0m   : Master network protocol configuration\n"
printf "  \033[1;37m/etc/remote-backups\033[0m   : TPM-sealed remote SMB backup configurations\n\n"

# Live ZFS Telemetry
printf "\033[1;36m======================================================================\033[0m\n"
printf " Live ZFS Array Status:\n"
zpool list -H -o name,health,capacity 2>/dev/null | awk '{
    if ($2 == "ONLINE") color="\033[1;32m"
    else if ($2 == "DEGRADED") color="\033[1;33m"
    else color="\033[1;31m"
    printf "  - %-12s: %s%-8s\033[0m [Utilized: %s]\n", $1, color, $2, $3
}'
printf "\033[1;36m======================================================================\033[0m\n\n"

# Preserve and display any existing /etc/motd content populated by other processes
if [ -s /etc/motd ]; then
    cat /etc/motd
    printf "\n"
fi

