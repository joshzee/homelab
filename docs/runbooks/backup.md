# Homelab Backup Runbook

- Owner: Josh
- Status: Draft — automation not yet implemented
- Cluster: Homelab K3s
- Control-plane host: `lab-node-01`
- Datastore: SQLite
- Last manual backup tested: 2026-11-06

> This runbook must not be marked operational until the backup script,
> verification process, and restore procedure have been tested.

## Purpose

This runbook describes how to create, verify, retain, and recover the homelab
K3s backup.

It protects against:

- Failure or replacement of the ZBook
- Operating-system corruption or reinstallation
- Accidental deletion of the K3s cluster
- Failed K3s upgrades
- Corruption or deletion of persistent application data
- Loss of the local homelab Git repository

A backup is successful only when it is:

1. Created without errors
2. Encrypted
3. Verified
4. Stored on another device
5. Covered by a tested restore procedure

## Recovery objectives

### Current RPO

Backups are currently performed manually. The possible data loss is therefore
the time since the most recent successful backup.

### Target RPO

After automation, persistent application data should have an RPO of 24 hours.

An additional backup must run before:

- K3s upgrades
- Operating-system upgrades
- Storage changes
- Control-plane changes
- Destructive application maintenance

### Target RTO

The initial target is to restore the control plane and critical applications
within four hours.

This target remains unverified until the first restore drill.

## Backup strategy

The homelab uses two backup types.

### Full disaster-recovery backup

A full backup contains:

- K3s SQLite datastore
- K3s server token
- K3s configuration
- K3s systemd configuration
- Local-path persistent-volume data
- SOPS/age recovery material
- Committed homelab Git repository data
- Checksums and backup metadata

Full backups will run weekly and before major changes.

### Routine application-data backup

Routine backups will protect application data more frequently.

Applications that cannot provide an online, application-consistent backup may
be paused briefly while their data is captured.

Encryption, verification, and transfer must occur after applications have
resumed.

## Application availability

A complete daily maintenance window is not required.

During a full backup:

- Flux reconciliation is temporarily suspended.
- Linkding and Audiobookshelf are briefly stopped to prevent database writes.
- K3s is briefly stopped while the SQLite datastore is captured.
- K3s and applications are restarted before encryption and transfer begin.

The backup automation must minimise this interruption and report its duration.

## Persistent workload inventory

| Namespace | Workload | Persistent data | Quiescing action |
|---|---|---|---|
| `linkding` | `deployment/linkding` | Linkding application database and data | Scale to zero |
| `audiobookshelf` | `deployment/audiobookshelf` | Configuration, metadata, audiobooks and podcasts | Scale to zero |

Every new PVC must be added to this inventory before it is considered
protected.

The backup script must fail safely if it discovers an unknown PVC rather than
silently ignoring it.

## Backup naming

Standard full-backup filenames use:

`homelab-k3s-full-<UTC_TIMESTAMP>.tar.gz.age`

The corresponding checksum file uses:

`homelab-k3s-full-<UTC_TIMESTAMP>.sha256`

Special backups may replace `full` with a reason:

`homelab-k3s-pre-upgrade-<UTC_TIMESTAMP>.tar.gz.age`

## Backup locations

### ZBook

Temporary backup data is created under:

`/var/backups/homelab/<UTC_TIMESTAMP>/`

Plaintext staging data must be deleted after encryption and verification.

### MacBook

Encrypted backups are retained under:

`~/Backups/homelab/k3s/`

### External SSD

Encrypted backups are also copied to:

`/Volumes/JoshDev/Backups/homelab/k3s/`

### Future NAS

The NAS will become the primary local backup destination.

The NAS must not become the only backup copy. At least one encrypted copy must
exist on a separate device or at an off-site location.

## Automated backup procedure

See [`backup-automation.md`](backup-automation.md) for the automation design.
