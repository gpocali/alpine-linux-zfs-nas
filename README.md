# alpine-linux-zfs-nas
ZFS Samba NAS Vault with MergerFS Storage Tiers on Alpine Linux with Docker Support

## Remote SMB Backup Vault
The array includes a built-in automated backup manager for securely pulling data from remote SMB shares (such as Proxmox VMs, external routers, or secondary NAS units) directly into the ZFS datasets. 

This process acts as an **incremental mirror**, keeping the local ZFS dataset in perfect sync with the remote share. By relying on native ZFS automated snapshots on the destination dataset, you retain full version control and point-in-time recovery without ballooning storage usage.

**Key Features:**
* **Zero-Plaintext Credentials:** SMB passwords are encrypted and sealed directly into the hardware TPM using `clevis-tpm2`. Passwords are only temporarily unsealed into volatile RAM (`/dev/shm`) during the exact moment of the backup and instantly scrubbed.
* **Incremental Mirroring:** Utilizes strict `rsync` mirroring (`--delete --delete-excluded`) while automatically filtering out Windows metadata junk like `System Volume Information` and `$RECYCLE.BIN`.
* **Chronological Structure:** Backups are automatically routed into `[Month Number] [Month Name]` directories for clean archiving.
* **Self-Healing Dependencies:** Running the manager for the first time will automatically provision `cifs-utils`, `rsync`, and `clevis` dependencies, and wire the background worker into Alpine's cron system.

### Usage
To configure a new remote backup mirror, run the interactive manager:
```bash
manage-remote-backups

```

This interface will prompt you for:

1. An alias for the job (e.g., `proxmox_vzdump`).
2. The remote SMB path and username.
3. The SMB password (which will be intercepted and sealed into the TPM).
4. The local ZFS destination path.
5. The cron schedule interval.

The system will then inject the worker script (`/usr/local/bin/remote-backup-worker`) into the root crontab, allowing Alpine to execute the incremental pull autonomously on your defined schedule. Logs for these background pulls are recorded at `/var/log/remote-backup-<alias>.log`.
