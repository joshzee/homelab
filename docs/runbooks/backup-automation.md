## Backup automation components

The backup is implemented as a set of grouped scripts. Each script represents
a meaningful operational phase rather than an individual command.

### 1. Pre-flight checks

Script:

`scripts/backup/zbook/01-preflight.sh`

This script performs read-only checks:

- Confirm the host is the expected ZBook
- Confirm K3s is healthy
- Confirm required tools are installed
- Confirm required directories exist
- Confirm sufficient disk space exists
- Confirm no other backup is running

This script makes no changes and may be run repeatedly.

### 2. Persistent-volume inventory

Script:

`scripts/backup/zbook/02-inventory-pvcs.sh`

This script:

- Lists every PVC in every namespace
- Maps known PVCs to protected workloads
- Identifies unknown PVCs
- Refuses approval if persistent data is not covered by the backup plan

This script makes no changes and may be run repeatedly.

### 3. Consistent data capture

Script:

`scripts/backup/zbook/03-capture.sh`

This script performs one state-changing transaction:

1. Suspend the relevant Flux reconciliation.
2. Stop known persistent-data writers.
3. Confirm writer Pods have terminated.
4. Stop K3s.
5. Archive the K3s datastore, token, configuration, and local-path data.
6. Restart K3s.
7. Resume Flux and application workloads.
8. Confirm the cluster and protected applications are healthy.
9. Generate checksums for the captured archives.

These operations must remain together because K3s and the applications must
not be left stopped at a manual breakpoint.

The script must contain failure handling that attempts to restart K3s and
resume workloads if capture fails.

A successful completion of this script is a safe breakpoint.

### 4. Package and verify

Script:

`scripts/backup/mac/04-package.sh`

This script:

- Retrieves the captured archives from the ZBook
- Creates the homelab Git bundle
- Adds required recovery material
- Creates the encrypted backup package
- Creates the outer checksum
- Decrypts and lists the package as a verification test
- Verifies internal checksums

Applications remain online during this phase.

A successful completion of this script is a safe breakpoint.

### 5. Replicate

Script:

`scripts/backup/mac/05-replicate.sh`

This script:

- Copies the encrypted package and checksum to the external destination
- Verifies the destination checksum
- Records which destinations contain a verified copy

It must not copy plaintext staging data.

### 6. Cleanup

Script:

`scripts/backup/mac/06-cleanup.sh`

This script removes plaintext staging files only after:

- Package verification has passed
- At least two encrypted copies exist
- Both encrypted copies have matching checksums

Cleanup requires an explicit backup identifier and must validate every target
path before deleting anything.

## Automation sequencing

During initial testing, each script is started manually and its result is
reviewed before continuing.

During the pre-NAS phase, systemd on the ZBook may automate the ZBook capture
steps. Packaging, replication, and cleanup on the MacBook remain separately
controlled operations.

After the NAS is introduced, the automation design will be reviewed so that
the ZBook can send encrypted backups directly to the NAS without depending on
the MacBook being online.
