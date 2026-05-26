#!/bin/ash

# Clear the screen for a clean login presentation
clear

# Header
printf "\033[1;36m======================================================================\033[0m\n"
printf "\033[1;32m                 Alpine ZFS Storage & Media Vault\033[0m\n"
printf "\033[1;36m======================================================================\033[0m\n\n"

# Custom Master Utilities
printf "\033[1;33m► Interactive Master Dashboards:\033[0m\n"
printf "  \033[1;37mmanage-shares\033[0m        : Master UI for ZFS datasets, quotas, & Samba\n"
printf "  \033[1;37mmanage-share-users\033[0m   : Master UI to add/remove/modify Samba users\n\n"

# Hardware & Array Management
printf "\033[1;33m► Hardware & Storage Control:\033[0m\n"
printf "  \033[1;37marray-control status\033[0m : Manage array drive sleep states (up/down/status)\n"
printf "  \033[1;37mcache-mover.sh\033[0m       : Manually flush NVMe fastpool -> HDD vaultpool\n\n"

# Background Automations
printf "\033[1;33m► Background Daemons & Automations:\033[0m\n"
printf "  \033[1;37mzfs-autokeeper\033[0m       : (Daily at 00:05) Prunes expired snapshots\n"
printf "  \033[1;37mgenerate-telemetry\033[0m   : (Every Minute) Exports JSON to Web UI\n\n"

# Service Management
printf "\033[1;33m► Service Management:\033[0m\n"
printf "  Restart Samba        : rc-service samba restart\n"
printf "  Restart Web UI       : rc-service array-dashboard restart\n"
printf "  \033[1;31mSave OS to Flash     : lbu commit -d\033[0m\n\n"

# Crucial System Paths
printf "\033[1;33m► Key Architecture Paths:\033[0m\n"
printf "  \033[1;37m/mnt\033[0m                 : Master MergerFS mount (Network shares root)\n"
printf "  \033[1;37m/var/www/dashboard\033[0m   : Web UI root (JSON telemetry & dashboard)\n"
printf "  \033[1;37m/etc/samba/smb.conf\033[0m  : Master network protocol configuration\n\n"

# Live ZFS Telemetry
printf "\033[1;36m======================================================================\033[0m\n"
printf " Live ZFS Array Status:\n"
zpool list -H -o name,health,capacity | awk '{
    if ($2 == "ONLINE") color="\033[1;32m"
    else if ($2 == "DEGRADED") color="\033[1;33m"
    else color="\033[1;31m"
    printf "  - %-12s: %s%-8s\033[0m [Utilized: %s]\n", $1, color, $2, $3
}'
printf "\033[1;36m======================================================================\033[0m\n\n"
