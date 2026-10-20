# alpine-linux-zfs-nas
ZFS Samba NAS Vault with MergerFS Storage Tiers on Alpine Linux with Docker Support

## Architecture Overview
This repository provides the root filesystem overlay (`root/`) for a diskless Alpine Linux ZFS NAS appliance featuring:
* **Two-Tier ZFS Storage:** Combines a high-capacity HDD array (`vaultpool`) with a high-speed NVMe cache pool (`fastpool`).
* **Unified MergerFS Pooling (`/mnt`):** Dynamically merges `/fastpool` and `/vaultpool` under `/mnt` using the `epff` (*Existing Path, First Found*) creation policy (`/etc/init.d/mergerfs-storage`), routing writes based on dataset placement across tiers.
* **Hardware TPM 2.0 Encryption Unlock:** Automatically unseals ZFS pool encryption keys at boot via `clevis` (`/etc/init.d/zfs-tpm-loader`) and seals remote SMB backup credentials via `tpm2-tools`.
* **Diskless Alpine Persistence (`lbu`):** Runs from RAM and persists configuration changes back to USB boot media using `lbu commit -d` (`/etc/lbu/lbu.conf`).

---

## Installation & Updates (`install.sh` / `nas-update`)

Install or update the system directly from GitHub into a temporary staging directory using a single command:

```sh
# Interactive Install / Update (prompts to commit LBU and reboot if updates were applied)
wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-zfs-nas/main/install.sh | sh

# Non-Interactive Batch Mode (for scripts or cron; auto-commits LBU and reboots only if updates were applied)
wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-zfs-nas/main/install.sh | sh -s -- --batch
```

Once installed, the updater is also available locally at `/usr/local/bin/nas-update` (`nas-update` or `nas-update --batch`).

* **Safe Update Mode:** Automatically detects existing installations (`/etc/alpine-zfs-nas.installed` or installed scripts) and skips overwriting live configuration files (`/etc/samba/smb.conf`, `/etc/samba/shares.list`, `/etc/lbu/lbu.conf`, etc.).
* **Multi-Process Config Merging:** Non-destructively merges missing entries into shared system files (`/etc/modules`, `/etc/apk/repositories`, and `/etc/crontabs/root`) without overwriting modules, mirrors, or cron jobs added by other processes.
* **Automatic LBU Registration:** Registers all managed files outside `/etc` (`/usr/local/bin/*`, `/var/www/dashboard/*`) with `lbu include`.

---

## Interactive Dashboards & CLI Utilities

### 1. Unified NAS State Controller (`nas-ctl`)
A centralized interactive CLI menu wrapping core administrative tasks:
```bash
nas-ctl
```
* **[Status] System Telemetry & Drive States:** Triggers `generate-telemetry` and displays live `zpool list`, `zfs list`, and `array-control status` summaries.
* **[Samba] Share, User & Backup Management:** Lists active shares or launches `manage-shares`, `manage-share-users`, or `manage-remote-backups`.
* **[ZFS] Snapshot & Cache Tier Management:** Lists snapshots, takes instant manual snapshots, runs `zfs-autokeeper`, flushes NVMe cache via `cache-mover.sh`, or opens snapshot scheduling.
* **[Network] Network Settings:** Displays IP/interface details (`ip addr`, `hostname -i`) and updates the system hostname (`/etc/hostname`).
* **[Security] API Key Management:** Rotates the `nas-commander` API key via `nas-keytool rotate`.

### 2. Unified ZFS & Network Storage Manager (`manage-shares`)
Master interactive dashboard and CLI utility for provisioning ZFS datasets, quotas, snapshots, Docker storage, and Samba shares:
```bash
# Interactive TUI dashboard
manage-shares

# Non-interactive CLI commands
manage-shares --list
manage-shares --snapshot <dataset> [snapshot_name]
manage-shares --delete-dataset <dataset>
```
**Capabilities:**
* **Dataset Creation & Tier Selection:** Provision datasets as *HDD Archive Only* (`vaultpool`), *Cache-Tiered* (both `fastpool` and `vaultpool`), or *NVMe Cache Only* (`fastpool`), with workload recordsize tuning (`128K` General, `1M` Media, `16K` AppData).
* **Custom Direct ZFS Mounts & Auto-Docker Provisioning:** Supports mounting single-pool datasets directly to system paths (e.g., `/var/lib/docker`, `/var/lib/libvirt`). Mounting `/var/lib/docker` automatically installs and enables `docker` and `docker-cli-compose`.
* **Samba Network Share Management:** Dynamically compiles `/etc/samba/smb.conf` from `/etc/samba/shares.list`. Supports Read/Write (`RW`) and Read-Only (`RO`) modes, automatic Linux permission conflict detection (offering optional `force user = root` Administrator Masking), and zero-downtime `samba reload` when security masks are unchanged.
* **Quotas & Snapshot Lifecycle:** Configure dataset storage quotas, take manual snapshots, configure daily automated snapshot schedules (`custom:autosnap=daily`, `custom:keep_days=<N>`), toggle `.zfs` / `@Snapshots` network visibility, or wipe existing dataset snapshots.

### 3. Samba Share User Manager (`manage-share-users`)
Interactive utility for managing Samba authentication and access control groups (`storage-rw` and `storage-ro`):
```bash
manage-share-users
```
* Lists current Read/Write (`storage-rw`) and Read-Only (`storage-ro`) users.
* Creates system-isolated (`nologin`) Samba users (`smbpasswd -a`) defaulting to Read-Only.
* Elevates or restricts user permissions between `storage-rw` and `storage-ro`.
* Removes Samba and system user accounts cleanly.

### 4. Remote SMB Backup Vault (`manage-remote-backups` & `remote-backup-worker`)
Built-in automated backup manager for securely pulling data from remote SMB shares (such as Proxmox VMs, external routers, or secondary NAS units) directly into local ZFS datasets.

This process acts as an **incremental mirror**, keeping the local ZFS dataset in sync with the remote share while relying on native ZFS automated snapshots on the destination dataset for point-in-time recovery.

**Key Features:**
* **Zero-Plaintext Credentials:** SMB passwords are encrypted and sealed directly into the hardware TPM using `tpm2-tools` (`tpm2_createprimary`, `tpm2_create`, `tpm2_load`, `tpm2_unseal`). Passwords are only temporarily unsealed into volatile RAM (`/dev/shm`) during mount and immediately scrubbed.
* **Incremental Mirroring:** Utilizes `rsync` mirroring (`--delete --delete-excluded`) into `<destination>/<alias>` while filtering out Windows metadata (`System Volume Information` and `$RECYCLE.BIN`).
* **Queue Locking:** Uses `flock` (`/var/lock/remote-backup.lock`) and per-job PID lock directories to prevent overlapping backup runs.
* **Self-Healing Dependencies:** Running `manage-remote-backups` for the first time automatically installs `cifs-utils`, `rsync`, and `tpm2-tools`, and ensures `crond` is active.

```bash
# Launch interactive backup manager (Add, Run Manually, Edit, Delete)
manage-remote-backups

# Execute a specific backup worker job directly
remote-backup-worker <alias> [verbose]
```
Logs for scheduled background pulls are recorded at `/var/log/remote-backup-<alias>.log`.

---

## Hardware & Storage Control

### 1. Drive Power & Spindown Control (`array-control` & `spindown.start`)
Manages Seagate Exos array power states without unnecessarily waking sleeping disks:
```bash
array-control status   # Checks drive power state via 'smartctl -i -n standby'
array-control down     # Immediately spins down all array drives via 'hdparm -y'
array-control up       # Wakes all array drives via 'hdparm -I'
```
At boot, `/etc/local.d/spindown.start` configures a 1-hour idle spindown timer (`hdparm -S 242`) across all raw array drives.

### 2. NVMe-to-HDD Tier Migration (`cache-mover.sh`)
Migrates aged files from `/fastpool/<dataset>` to `/vaultpool/<dataset>` for cache-tiered datasets (datasets present on both pools), while skipping NVMe-only datasets to preserve flash pinning:
```bash
cache-mover.sh check      # Flushes only if fastpool capacity >= 80% (default every 15m in cron)
cache-mover.sh force      # Forces migration regardless of capacity (nightly at 02:00 AM)
cache-mover.sh force -v   # Forces migration with live console progress output
```
* Default idle file age threshold is `15` minutes (`DEFAULT_MMIN=15`), overridable per dataset in `/etc/zfs_tier_overrides.conf` (e.g., `media=60`).
* Logs migration activity to `/var/log/zfs_tier_migration.log`.

---

## Background Daemons, Telemetry & API Services

### 1. Automated ZFS Snapshot Lifecycle (`zfs-autokeeper`)
Executed daily at `00:05` via root crontab (`/etc/crontabs/root`):
```bash
zfs-autokeeper
```
* Scans all ZFS datasets for `custom:autosnap=daily` and creates `@auto-daily-YYYY-MM-DD_HHMM` snapshots (if not already taken that day).
* Prunes `@auto-*` snapshots older than `custom:keep_days` days.

### 2. Web Telemetry Dashboard (`generate-telemetry` & `array-dashboard`)
* **`generate-telemetry`:** Runs every minute via cron to atomically write `/var/www/dashboard/zfs-telemetry.json` with pool capacities, physical disk sleep states, dataset quotas/compression/Samba/snapshot statuses, and remote SMB backup statuses.
* **`/etc/init.d/array-dashboard`:** OpenRC service running `darkhttpd` on port `8080` serving `/var/www/dashboard/index.html`.

### 3. Remote Management API (`nas-commander` & `nas-keytool`)
Provides a Bearer-authenticated HTTP JSON API on port `8081` for remote automation:
```bash
# Generate or rotate the 32-character API key in /etc/nas-commander.env
nas-keytool generate
nas-keytool rotate

# Start the Commander API server (Port 8081)
nas-commander
```
* **`GET /`:** Health check returning `{"status": "running", "port": 8081}`.
* **`POST /`:** Requires `Authorization: Bearer <COMMANDER_API_KEY>` and JSON body `{"command": "<cmd>", "args": [...]}`. Supported commands: `manage_shares`, `generate_telemetry`, `zfs_snapshot`, `delete_dataset`, `zfs_autokeeper`, `array_control`, `cache_mover`, and `remote_backup`.

### 4. Login MOTD Banner (`/etc/profile.d/vault-motd.sh`)
Automatically displays at user login with a categorized reference of all NAS scripts, service commands, architecture paths, and live color-coded ZFS pool health, followed by any existing content in `/etc/motd` populated by other system processes.
