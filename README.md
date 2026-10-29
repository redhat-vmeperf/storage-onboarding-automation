# Storage Onboarding Automation

Automates the end-to-end process of connecting a ScaleLab cloud allocation to the Storage LTA (cloud99) iSCSI infrastructure.

## Overview

When a new cloud is allocated in the ScaleLab, its worker nodes need VLAN sub-interfaces, iSCSI initiator configuration, and storage-side resources (portals, volumes, host objects, LUN mappings) before they can access shared storage. This tooling automates that entire workflow across four storage vendors.

## Supported Storage Arrays

| Vendor | Model | CLI Transport |
|---|---|---|
| `netapp-asa` | NetApp ASA A70 | SSH (ONTAP CLI, flat LUN namespace) |
| `pure` | Pure FlashArray X70R5 | SSH (Purity CLI) |
| `ibm` | IBM FlashSystem 7300 | SSH (SVC CLI — `svctask`/`svcinfo`) |
| `netapp-aff` | NetApp AFF A300 | SSH (standard ONTAP CLI with volumes) |

## Quick Start

```bash
# 1. Edit or copy an env file for your cloud
cp env/example.env env/cloud<NN>.env
vi env/cloud<NN>.env   # set CLOUD_ID and STORAGE_ARRAYS

# 2. Preview what will happen (dry-run)
bash scripts/setup-storage-lta.sh -e env/cloud<NN>.env -n storage-setup

# 3. Run it for real
bash scripts/setup-storage-lta.sh -e env/cloud<NN>.env storage-setup
```

## Stages

The script runs in stages that can be executed individually or all at once:

| Stage | Description |
|---|---|
| `collect` | Query the QUADS API, extract host/interface/MAC data to `results/` |
| `verify` | Check that target interfaces aren't already assigned to cloud99 |
| `jira-draft` | Generate a VLAN-change Jira request for ScaleLab ops |
| `host-setup` | Create VLAN sub-interfaces (NNCPs on OCP) + iSCSI/multipath config |
| `storage-setup` | Configure storage arrays: portals, volumes, hosts, LUN mappings |
| `check` | Verify connectivity from workers to storage portal IPs |
| `all` | Run all stages in order |

### `storage-setup` Sub-stages

For each vendor in `STORAGE_ARRAYS`, the storage-setup stage runs:

| Sub-stage | What it does |
|---|---|
| **A** | Create network resources — iSCSI portal IPs, subnets, VLANs, LIFs |
| **B** | Create volumes / LUNs |
| **C** | Create host objects / igroups with worker IQNs |
| **D** | Map LUNs to hosts |
| **E** | Run iSCSI discovery + login from each worker, verify multipath |

Every create operation checks for existing resources first (idempotent). Re-running is safe.

## VLAN and Subnet Convention

VLANs and subnets are deterministic — derived from the storage vendor and cloud ID:

```
VLAN   = storage_digit x 100 + cloud_id
Subnet = 172.(15 + storage_digit).(100 + cloud_id).0/24
```

| Vendor | Digit (path A / B) | Example (cloud06) |
|---|---|---|
| IBM | 1 / 2 | VLAN 106/206, subnet 172.16.106.0/24, 172.17.106.0/24 |
| NetApp ASA | 3 / 4 | VLAN 306/406, subnet 172.18.106.0/24, 172.19.106.0/24 |
| Pure | 5 / 6 | VLAN 506/606, subnet 172.20.106.0/24, 172.21.106.0/24 |
| NetApp A300 | 7 / 8 | VLAN 706/806, subnet 172.22.106.0/24, 172.23.106.0/24 |

Each vendor gets two paths (A and B) distributed across two physical NICs (alternating) for multipath resilience.

## Environment File

Minimal required configuration:

```bash
CLOUD_ID=6
STORAGE_ARRAYS="netapp-asa pure"
```

Optional settings with defaults:

```bash
NETWORKS="3 4"          # BIOS-level NIC numbers (em3, em4)
TARGET_TYPE="ocp"       # ocp | vmware | bare
SSH_USER="core"         # auto-set from TARGET_TYPE
LUN_SIZE="1TB"          # size per volume/LUN per vendor
LUN_COUNT=1             # number of volumes/LUNs per vendor
EXCLUDE_HOSTS=""        # space-separated hostnames to skip
```

See `env/example.env` for a fully commented template.

## Credentials

Storage array credentials are fetched from the **Bitwarden Secrets Manager CLI** (`bws`). The script expects `bws` to be authenticated before running (i.e., `BWS_ACCESS_TOKEN` is set).

Secret keys used:

| Key | Description |
|---|---|
| `STORAGE_IBM_MGMT_IP` / `_USER` / `_PW` | IBM FlashSystem SSH access |
| `STORAGE_NETAPP_ASA_MGMT_IP` / `_USER` / `_PW` | NetApp ASA SSH access |
| `STORAGE_NETAPP_AFF_MGMT_IP` / `_USER` / `_MGMT_PW` | NetApp A300 SSH access |
| `STORAGE_PURE_MGMT_IP` / `_USER` / `_PW` | Pure FlashArray SSH access |

Credentials are cached in-memory for the duration of a single run (one `bws secret list` call, filtered to `STORAGE_*` keys — non-storage secrets in the BWS project are never retained) and are never written to disk. Optionally set `BWS_PROJECT_ID` to scope the list call to a dedicated storage-credentials project.

## Prerequisites

On the provisioner node:

- `bash` 4.x+
- `jq`, `sshpass`, `curl`
- `bws` CLI (Bitwarden Secrets Manager) with `BWS_ACCESS_TOKEN` set
- `oc` (for OCP target type) with a valid KUBECONFIG

## Project Structure

```
storage-onboarding-automation/
  scripts/
    setup-storage-lta.sh         # main script
    storage-lta-subnet-calc.sh   # standalone VLAN/subnet calculator
  env/
    example.env                  # template — copy for your cloud
    cloud20.env
  results/                       # generated CSVs, Jira drafts
  logs/                          # per-run timestamped logs
```

## Options

```
-e FILE      Environment file (required)
-n           Dry-run mode — show what would be done, change nothing
-v           Verbose output
-w HOST      Single-worker mode — run only against this host
-h           Show help
```

## Examples

```bash
# Dry-run storage setup for cloud20
bash scripts/setup-storage-lta.sh -e env/cloud20.env -n storage-setup

# Run host-setup on a single worker
bash scripts/setup-storage-lta.sh -e env/cloud06.env -w worker000-r640 host-setup

# Full pipeline (collect through check)
bash scripts/setup-storage-lta.sh -e env/cloud06.env all

# Verbose mode for debugging
bash scripts/setup-storage-lta.sh -e env/cloud20.env -v storage-setup
```
