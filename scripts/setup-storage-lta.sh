#!/usr/bin/env bash
#
# setup-storage-lta.sh — Storage LTA onboarding utility
#
# Automates the end-to-end process of connecting a ScaleLab cloud allocation
# to the Storage LTA (cloud99).  Stages:
#   collect    — query QUADS API, extract host/interface/MAC data
#   verify     — check that target interfaces aren't already in use
#   jira-draft — generate a VLAN-change Jira request (SCALELAB project)
#   host-setup — create VLAN sub-interfaces, configure iSCSI + multipath
#   check      — verify connectivity to storage portal IPs
#
# Design principles:
#   - Minimal required input: CLOUD_ID + STORAGE_ARRAYS in an env file
#   - Everything else auto-discovered from the QUADS API
#   - Alternating NIC-to-path mapping for multipath resilience
#   - Dry-run mode for safe previewing
#
# VLAN/subnet formulas from storage-lta-subnet-calc.sh:
#   VLAN   = storage_digit × 100 + cloud_id
#   Subnet = 172.(15 + storage_digit).(100 + cloud_id).0/24

set -euo pipefail

PROG="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${REPO_DIR}/results"

# =============================================================================
# Defaults (overridable via env file)
# =============================================================================
CLOUD_ID=""
STORAGE_ARRAYS=""
NETWORKS="3 4"
EXCLUDE_HOSTS=""
TARGET_TYPE="ocp"
SSH_USER=""
QUADS_API="https://quads2.rdu2.scalelab.redhat.com/api/v3"
CLOUD99_OUTER_VLAN="2080"

# Volume / LUN configuration for storage-setup stage
LUN_SIZE="1TB"
LUN_COUNT=1

# Script options
DRY_RUN=false
VERBOSE=false
SINGLE_WORKER=""
ENV_FILE=""
LOG_DIR="${REPO_DIR}/logs"
LOG_FILE=""

# =============================================================================
# Platform digit table (from storage-lta-subnet-calc.sh)
# name|pathA_digit — path B is always pathA_digit + 1
# =============================================================================
declare -A PLATFORM_DIGITS
PLATFORM_DIGITS=(
    [ibm]=1
    [netapp-asa]=3
    [pure]=5
    [netapp-aff]=7
)

declare -A PLATFORM_NAMES
PLATFORM_NAMES=(
    [ibm]="IBM FlashSystem 7300"
    [netapp-asa]="NetApp ASA A70"
    [pure]="Pure FlashArray X70R5"
    [netapp-aff]="NetApp AFF A300"
)

# =============================================================================
# Model-to-OS interface name mapping (from ScaleLabTipsAndTricks)
# Key: MODEL:emN  Value: OS-level name on EL9
# =============================================================================
declare -A IFACE_OS_MAP
IFACE_OS_MAP=(
    [R630:em1]="eno1"        [R630:em2]="eno2"        [R630:em3]="eno3"        [R630:em4]="eno4"
    [R640:em1]="ens1f0"      [R640:em2]="ens1f1"      [R640:em3]="ens2f0np0"   [R640:em4]="ens2f1np1"   [R640:em5]="eno2np1"
    [R650:em1]="ens1f0"      [R650:em2]="ens1f1"      [R650:em3]="ens2f0np0"   [R650:em4]="ens2f1np1"   [R650:em5]="eno12409np1"
    [R660:em1]="ens1f0"      [R660:em2]="ens1f1"      [R660:em3]="ens2f0np0"   [R660:em4]="ens2f1np1"   [R660:em5]="eno12409np1"
    [R750:em1]="ens3f0"      [R750:em2]="ens3f1"      [R750:em3]="ens6f0np0"   [R750:em4]="ens6f1np1"   [R750:em5]="eno12409np1"
    [R6625:em1]="ens2f0"     [R6625:em2]="ens2f1"     [R6625:em3]="ens1f0np0"  [R6625:em4]="ens1f1np1"  [R6625:em5]="eno12409np1"
)

# =============================================================================
# Multipath device configs per vendor
# =============================================================================
MULTIPATH_IBM='devices {
        device {
                vendor                  "IBM"
                product                 "2145"
                path_grouping_policy    "group_by_prio"
                prio                    "alua"
                path_checker            "tur"
                path_selector           "service-time 0"
                failback                "immediate"
                no_path_retry           "queue"
                rr_weight               "uniform"
                rr_min_io_rq            1
                fast_io_fail_tmo        5
                dev_loss_tmo            infinity
        }
}'

MULTIPATH_PURE='devices {
        device {
                vendor                  "PURE"
                product                 "FlashArray"
                path_grouping_policy    "group_by_prio"
                prio                    "alua"
                path_checker            "tur"
                path_selector           "service-time 0"
                failback                "immediate"
                no_path_retry           1
                rr_weight               "uniform"
                rr_min_io_rq            1
                fast_io_fail_tmo        10
                dev_loss_tmo            60
        }
}'

MULTIPATH_NETAPP='devices {
        device {
                vendor                  "NETAPP"
                product                 "LUN"
                path_grouping_policy    "group_by_prio"
                prio                    "ontap"
                path_checker            "tur"
                path_selector           "service-time 0"
                failback                "immediate"
                no_path_retry           "queue"
                rr_weight               "uniform"
                rr_min_io_rq            128
                fast_io_fail_tmo        5
                dev_loss_tmo            infinity
                features                "3 queue_if_no_path pg_init_retries 50"
        }
}'

# =============================================================================
# Logging
# =============================================================================
log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; if [[ -n "${LOG_FILE:-}" ]]; then echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; fi; }
log_verbose() { if [[ "$VERBOSE" == "true" ]]; then log "[VERBOSE] $*"; fi; }
log_error()   { log "[ERROR] $*"; }
log_success() { log "[OK] $*"; }
log_warn()    { log "[WARN] $*"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: ${PROG} -e <env-file> [STAGE] [OPTIONS]

Stages (run one at a time, or 'all'):
  collect        Query QUADS API, output MAC CSV to results/
  verify         Check interfaces aren't already in cloud99 / active use
  jira-draft     Generate Jira VLAN change request text
  host-setup     Create VLAN sub-interfaces + iSCSI/multipath config
  storage-setup  Configure storage arrays (portals, volumes, hosts, mappings)
  check          Verify connectivity to storage portal IPs
  all            Run all stages in order

Options:
  -e FILE      Environment file (required)
  -n           Dry-run mode — show what would be done, change nothing
  -v           Verbose output
  -w HOST      Single-worker mode — run only on this host
  -h           Show this help

The env file must set at minimum:
  CLOUD_ID=6
  STORAGE_ARRAYS="ibm pure"

See env/example.env for a full example.
EOF
    exit 0
}

# =============================================================================
# VLAN / Subnet helpers (from storage-lta-subnet-calc.sh formulas)
# =============================================================================
calc_vlan()        { echo $(( $1 * 100 + CLOUD_ID )); }
calc_subnet_base() { echo "172.$(( 15 + $1 )).$(( 100 + CLOUD_ID ))"; }

get_platform_digit_a() {
    local vendor="$1"
    local digit="${PLATFORM_DIGITS[$vendor]:-}"
    if [[ -z "$digit" ]]; then
        log_error "Unknown storage vendor '${vendor}'. Known: ${!PLATFORM_DIGITS[*]}"
        return 1
    fi
    echo "$digit"
}

# =============================================================================
# NIC-to-path mapping — alternating convention
#
# Vendors at odd positions (1st, 3rd) in STORAGE_ARRAYS:
#   path A → first network NIC, path B → second network NIC
# Vendors at even positions (2nd, 4th):
#   path B → first network NIC, path A → second network NIC
#
# Result: each physical NIC carries exactly one path per vendor.
# =============================================================================

# Prints lines: <emN> <vlan_id> <subnet_base> <vendor> <path>
# for every (vendor, path, NIC) combination.
compute_vlan_layout() {
    local -a networks_arr
    read -r -a networks_arr <<< "$NETWORKS"
    if (( ${#networks_arr[@]} < 2 )); then
        log_error "NETWORKS must list at least 2 network numbers (got: ${NETWORKS})"
        return 1
    fi
    local nic_first="em${networks_arr[0]}"
    local nic_second="em${networks_arr[1]}"

    local -a vendors_arr
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"

    local idx=0
    for vendor in "${vendors_arr[@]}"; do
        local digitA
        digitA=$(get_platform_digit_a "$vendor") || return 1
        local digitB=$(( digitA + 1 ))

        local vlanA vlanB subA subB
        vlanA=$(calc_vlan "$digitA")
        vlanB=$(calc_vlan "$digitB")
        subA=$(calc_subnet_base "$digitA")
        subB=$(calc_subnet_base "$digitB")

        if (( idx % 2 == 0 )); then
            # Odd-position vendor (0-indexed even): path A → first NIC
            echo "${nic_first}  ${vlanA}  ${subA}  ${vendor}  A"
            echo "${nic_second} ${vlanB}  ${subB}  ${vendor}  B"
        else
            # Even-position vendor (0-indexed odd): flipped
            echo "${nic_first}  ${vlanB}  ${subB}  ${vendor}  B"
            echo "${nic_second} ${vlanA}  ${subA}  ${vendor}  A"
        fi
        (( idx++ )) || true
    done
}

# =============================================================================
# QUADS API helpers
# =============================================================================
quads_query_hosts() {
    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local cache_file="${RESULTS_DIR}/${cloud_name}.json"

    # Check results dir first, then repo root (legacy location)
    if [[ -f "$cache_file" ]]; then
        log "Using cached QUADS data: ${cache_file}"
        cat "$cache_file"
        return
    fi
    if [[ -f "${REPO_DIR}/${cloud_name}.json" ]]; then
        log "Using cached QUADS data: ${REPO_DIR}/${cloud_name}.json"
        cat "${REPO_DIR}/${cloud_name}.json"
        return
    fi

    local url="${QUADS_API}/hosts?cloud=${cloud_name}"
    log "Querying QUADS API: ${url}"
    local response
    response=$(curl -sf "$url") || {
        # Try without zero-padding
        url="${QUADS_API}/hosts?cloud=cloud${CLOUD_ID}"
        log "Retrying: ${url}"
        response=$(curl -sf "$url") || {
            log_error "Failed to query QUADS API for cloud ${CLOUD_ID}"
            return 1
        }
    }

    mkdir -p "$RESULTS_DIR"
    echo "$response" | python3 -m json.tool > "$cache_file" 2>/dev/null || echo "$response" > "$cache_file"
    log "Cached QUADS response to ${cache_file}"
    cat "$cache_file"
}

# Extract hosts JSON → lines of: hostname model
parse_hosts() {
    local json="$1"
    echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    print(h['name'], h.get('model', 'UNKNOWN'))
"
}

# Extract interfaces for a given host and network numbers
# Output: hostname interface_name mac_address
parse_interfaces() {
    local json="$1"
    local -a net_nums
    read -r -a net_nums <<< "$NETWORKS"

    local iface_filter=""
    for n in "${net_nums[@]}"; do
        iface_filter+="\"em${n}\","
    done
    iface_filter="${iface_filter%,}"

    echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
wanted = {${iface_filter}}
exclude = set('''${EXCLUDE_HOSTS}'''.split())
for h in data:
    if h['name'] in exclude:
        continue
    for iface in h.get('interfaces', []):
        if iface['name'] in wanted:
            print(h['name'], iface['name'], iface['mac_address'])
"
}

# Get model for a specific host
get_host_model() {
    local json="$1"
    local hostname="$2"
    echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    if h['name'] == '${hostname}':
        print(h.get('model', 'UNKNOWN'))
        break
"
}

# Resolve BIOS interface name (emN) to OS-level name for a model
resolve_os_iface() {
    local model="$1"
    local bios_name="$2"
    local key="${model}:${bios_name}"
    local os_name="${IFACE_OS_MAP[$key]:-}"
    if [[ -z "$os_name" ]]; then
        log_warn "No OS interface mapping for ${key}; using BIOS name '${bios_name}'"
        echo "$bios_name"
    else
        echo "$os_name"
    fi
}

# =============================================================================
# Remote execution helpers — OCP vs bare-metal
#
# OCP CoreOS workers cannot be configured via SSH + nmcli.
#   - VLAN interfaces → NNCP (NodeNetworkConfigurationPolicy) CRDs via oc apply
#   - Host commands   → oc debug node/<name> -- chroot /host <cmd>
#
# Bare-metal / VMware hosts use direct SSH + nmcli.
# =============================================================================
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# run_on_host — execute a command on a host, dispatching by TARGET_TYPE.
#   For OCP:        oc debug node/<node> -- chroot /host bash -c '<cmd>'
#   For bare-metal: ssh <user>@<host> '<cmd>'
run_on_host() {
    local host="$1"
    shift
    local cmd="$*"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$TARGET_TYPE" == "ocp" ]]; then
            log "[DRY-RUN] Would run on node ${host} via oc debug: ${cmd}"
        else
            log "[DRY-RUN] Would execute on ${host} via SSH: ${cmd}"
        fi
        return 0
    fi

    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        log_verbose "oc debug node/${host}: ${cmd}"
        oc debug "node/${host}" --quiet -- chroot /host bash -c "$cmd" 2>&1
    else
        log_verbose "SSH ${host}: ${cmd}"
        ssh $SSH_OPTS "${SSH_USER}@${host}" "$cmd" 2>&1
    fi
}

# Resolve a QUADS FQDN to the identifier used for remote execution.
#   OCP:        the short node name known to oc (e.g. "f01-h23-000-r640")
#   bare-metal: the FQDN or InternalIP
get_worker_id() {
    local hostname="$1"
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        # OCP node names are typically the short hostname
        local short="${hostname%%.*}"
        # Verify it exists in oc get nodes
        if command -v oc &>/dev/null; then
            if oc get node "$short" &>/dev/null 2>&1; then
                echo "$short"
                return
            fi
            # Try the FQDN
            if oc get node "$hostname" &>/dev/null 2>&1; then
                echo "$hostname"
                return
            fi
        fi
        # Fallback: return the short name and let oc debug fail with a clear message
        echo "$short"
    else
        echo "$hostname"
    fi
}

# Test that we can reach a host (SSH or oc debug)
test_host_reachable() {
    local worker_id="$1"
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        oc debug "node/${worker_id}" -- echo ok &>/dev/null 2>&1
    else
        ssh $SSH_OPTS "${SSH_USER}@${worker_id}" "echo ok" &>/dev/null 2>&1
    fi
}

# =============================================================================
# STAGE: collect
# =============================================================================
do_collect() {
    log "=== STAGE: collect ==="
    log "Cloud ID: ${CLOUD_ID}, Networks: ${NETWORKS}"

    local json
    json=$(quads_query_hosts) || return 1

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local csv_file="${RESULTS_DIR}/${cloud_name}.csv"

    log "Extracting interfaces for networks: ${NETWORKS}"

    {
        echo "hostname,interface,mac_address"
        parse_interfaces "$json" | while read -r hostname iface mac; do
            echo "${hostname},${iface},${mac}"
        done
    } > "$csv_file"

    local count
    count=$(( $(wc -l < "$csv_file") - 1 ))
    log_success "Collected ${count} interface(s) → ${csv_file}"

    if [[ "$VERBOSE" == "true" ]]; then
        log_verbose "Contents:"
        cat "$csv_file" >&2
    fi
}

# =============================================================================
# STAGE: verify
# =============================================================================
do_verify() {
    log "=== STAGE: verify ==="

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local csv_file="${RESULTS_DIR}/${cloud_name}.csv"
    if [[ ! -f "$csv_file" ]]; then
        log_error "No CSV found at ${csv_file}. Run 'collect' stage first."
        return 1
    fi

    local issues=0
    local checked=0

    # Read all MACs and verify against the full QUADS host list
    log "Verifying MAC addresses against QUADS host inventory..."
    local all_hosts_response
    all_hosts_response=$(curl -sf "${QUADS_API}/hosts?retired=false&broken=false" 2>/dev/null) || {
        log_warn "Could not query full QUADS inventory for verification. Skipping MAC cross-check."
        all_hosts_response=""
    }

    tail -n +2 "$csv_file" | while IFS=',' read -r hostname iface mac; do
        (( checked++ )) || true

        if [[ -n "$all_hosts_response" ]]; then
            local match
            match=$(echo "$all_hosts_response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
mac = '${mac}'
for h in data:
    for i in h.get('interfaces', []):
        if i['mac_address'] == mac:
            print(f\"{h['name']}:{i['name']}\")
            sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null) || match="ERROR"

            if [[ "$match" == "NOT_FOUND" ]]; then
                log_warn "  MAC ${mac} (${hostname}/${iface}) not found in QUADS inventory"
                (( issues++ )) || true
            elif [[ "$match" != "${hostname}:${iface}" && "$match" != "ERROR" ]]; then
                log_warn "  MAC ${mac} mapped to ${match} in QUADS, but CSV says ${hostname}:${iface}"
                (( issues++ )) || true
            else
                log_verbose "  OK: ${mac} → ${hostname}:${iface}"
            fi
        fi
    done

    if (( issues > 0 )); then
        log_warn "Verification found ${issues} issue(s). Review before proceeding."
    else
        log_success "All MAC addresses verified (${checked} checked, 0 issues)"
    fi
}

# =============================================================================
# STAGE: jira-draft
# =============================================================================
do_jira_draft() {
    log "=== STAGE: jira-draft ==="

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local csv_file="${RESULTS_DIR}/${cloud_name}.csv"
    if [[ ! -f "$csv_file" ]]; then
        log_error "No CSV found at ${csv_file}. Run 'collect' stage first."
        return 1
    fi

    local draft_file="${RESULTS_DIR}/${cloud_name}-jira-draft.txt"
    local -a networks_arr
    read -r -a networks_arr <<< "$NETWORKS"

    {
        cat <<HEADER
The request is for requesting vlan membership change for ${#networks_arr[@]} interfaces on specific ${cloud_name} hosts.

Please re-assign vlan membership for the following hosts and interfaces currently in ${cloud_name} to cloud99

hostname,interface,mac_address
HEADER

        tail -n +2 "$csv_file" | while IFS=',' read -r hostname iface mac; do
            echo "${hostname},${iface},${mac}"
        done

        echo ""
        echo "--- quads commands ---"
        echo ""

        # Collect unique hostnames, then emit quads commands per host per network
        local prev_host=""
        tail -n +2 "$csv_file" | sort | while IFS=',' read -r hostname iface mac; do
            local nic_num="${iface#em}"
            echo "quads --modify-switch-conf --host ${hostname} --nic${nic_num} ${CLOUD99_OUTER_VLAN} --change # reassign vlan membership from ${cloud_name} for ${mac} to cloud99"
        done

        echo ""
        echo "Note that while these hosts are part of ${cloud_name} some of these interfaces shared above may show cloud outer-vlan membership in another cloud. The desired result is for them to be in cloud99."
    } > "$draft_file"

    log_success "Jira draft written to: ${draft_file}"

    if [[ "$VERBOSE" == "true" ]]; then
        echo "--- begin jira draft ---" >&2
        cat "$draft_file" >&2
        echo "--- end jira draft ---" >&2
    fi
}

# =============================================================================
# STAGE: host-setup
#
# Two paths depending on TARGET_TYPE:
#   ocp  → generate NNCP YAMLs for VLAN interfaces, apply via oc apply;
#          iSCSI/multipath via oc debug
#   bare/vmware → SSH + nmcli for VLANs, SSH for iSCSI/multipath
# =============================================================================

# ---- OCP: Generate NNCP YAML for a single VLAN interface --------------------
# Generates a NodeNetworkConfigurationPolicy that creates a VLAN sub-interface
# with DHCP on all matching nodes.
generate_nncp_yaml() {
    local os_nic="$1"
    local vlan_id="$2"
    local vendor="$3"
    local path="$4"
    local node_selector_key="$5"
    local node_selector_value="$6"

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local profile="vlan${vlan_id}"
    local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"

    # Per-node NNCPs need unique names; include hostname when targeting a specific node
    local nncp_name="${cloud_name}-${profile}-storage-lta"
    if [[ "$node_selector_key" == "kubernetes.io/hostname" ]]; then
        nncp_name="${cloud_name}-${node_selector_value}-${profile}-storage-lta"
    fi

    cat <<EOF
---
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${nncp_name}
  labels:
    storage-lta/cloud: "${cloud_name}"
    storage-lta/vendor: "${vendor}"
    storage-lta/path: "${path}"
spec:
  nodeSelector:
    ${node_selector_key}: "${node_selector_value}"
  desiredState:
    interfaces:
      - name: ${os_nic}
        type: ethernet
        state: up
        mtu: 9000
      - name: ${os_nic}.${vlan_id}
        type: vlan
        state: up
        ipv4:
          dhcp: true
          enabled: true
        ipv6:
          enabled: false
        vlan:
          base-iface: ${os_nic}
          id: ${vlan_id}
        mtu: 9000
EOF
}

# ---- OCP: Generate all NNCP YAMLs and apply them ----------------------------
setup_vlan_interfaces_ocp() {
    local json="$1"
    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local nncp_dir="${RESULTS_DIR}/${cloud_name}-nncp"
    mkdir -p "$nncp_dir"
    # Clear old NNCPs from previous runs
    rm -f "${nncp_dir}"/*.yaml 2>/dev/null || true

    # Determine if all nodes share the same model (from QUADS data)
    local -a models=()
    mapfile -t models < <(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
exclude = set('''${EXCLUDE_HOSTS}'''.split())
models = set()
for h in data:
    if h['name'] not in exclude:
        models.add(h.get('model', 'UNKNOWN'))
for m in sorted(models):
    print(m)
")

    log "  Node models in cloud: ${models[*]}"

    # Get actual OCP worker node names from the cluster
    local -a ocp_workers=()
    if command -v oc &>/dev/null && [[ "$DRY_RUN" != "true" ]]; then
        mapfile -t ocp_workers < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        log "  OCP worker nodes: ${ocp_workers[*]}"
    fi

    if (( ${#models[@]} == 1 )); then
        # All same model — one set of NNCPs with worker nodeSelector
        local model="${models[0]}"
        log "  All nodes are ${model} — generating NNCPs with worker nodeSelector"

        compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
            local os_nic
            os_nic=$(resolve_os_iface "$model" "$bios_nic")
            local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
            local nncp_file="${nncp_dir}/nncp-vlan${vlan_id}.yaml"

            log "    ${bios_nic} (${os_nic}): vlan${vlan_id} → ${vendor_name} path ${path} (DHCP)"

            generate_nncp_yaml "$os_nic" "$vlan_id" "$vendor" "$path" \
                "node-role.kubernetes.io/worker" "" \
                > "$nncp_file"
        done
    else
        # Mixed models — need per-node NNCPs using actual OCP node names.
        # Build a MAC → OCP node name map by probing each OCP worker.
        log "  Mixed models detected — generating per-node NNCPs"
        log "  Building MAC → OCP node mapping..."

        declare -A mac_to_ocp_node=()
        declare -A ocp_node_model=()
        for ocp_node in "${ocp_workers[@]}"; do
            # Discover MACs on this OCP node to match against QUADS data
            local node_macs
            node_macs=$(oc debug "node/${ocp_node}" -- chroot /host bash -c \
                'for d in /sys/class/net/*/address; do iface=$(echo $d | cut -d/ -f5); mac=$(cat $d); echo "$iface $mac"; done' 2>/dev/null | grep -v "^lo " || true)
            while read -r iface mac; do
                mac_to_ocp_node["$mac"]="$ocp_node"
            done <<< "$node_macs"
        done

        # Now match QUADS hosts to OCP nodes via em3 MAC
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && continue
            fi
            if [[ -n "$SINGLE_WORKER" && "$hostname" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi

            # Find this host's em3 MAC to identify the OCP node
            local em3_mac
            em3_mac=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    if h['name'] == '${hostname}':
        for i in h.get('interfaces', []):
            if i['name'] == 'em3':
                print(i['mac_address'])
                break
        break
" 2>/dev/null)

            local ocp_node="${mac_to_ocp_node[$em3_mac]:-}"
            if [[ -z "$ocp_node" ]]; then
                log_warn "    Could not find OCP node for ${hostname} (em3 MAC: ${em3_mac}). Skipping."
                continue
            fi

            log "    ${hostname} (${model}) → OCP node: ${ocp_node}"

            compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
                local os_nic
                os_nic=$(resolve_os_iface "$model" "$bios_nic")
                local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
                local nncp_file="${nncp_dir}/nncp-${ocp_node}-vlan${vlan_id}.yaml"

                log "      ${bios_nic} (${os_nic}): vlan${vlan_id} → ${vendor_name} path ${path}"

                generate_nncp_yaml "$os_nic" "$vlan_id" "$vendor" "$path" \
                    "kubernetes.io/hostname" "$ocp_node" \
                    > "$nncp_file"
            done
        done
    fi

    log ""
    log "  NNCP manifests written to: ${nncp_dir}/"
    local nncp_count
    nncp_count=$(find "$nncp_dir" -name '*.yaml' | wc -l)
    log "  Total NNCPs: ${nncp_count}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would apply: oc apply -f ${nncp_dir}/"
        return 0
    fi

    if ! command -v oc &>/dev/null; then
        log_error "  'oc' command not found. NNCPs generated but not applied."
        log "  Apply manually: oc apply -f ${nncp_dir}/"
        return 1
    fi

    log "  Applying NNCPs..."
    if oc apply -f "$nncp_dir/" 2>&1; then
        log_success "  NNCPs applied. Waiting for rollout..."
        # Give nmstate time to reconcile
        local timeout=120
        local elapsed=0
        local all_available=false
        while (( elapsed < timeout )); do
            local not_ready
            not_ready=$(oc get nncp -l "storage-lta/cloud=${cloud_name}" \
                -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Available")].status!="True")].metadata.name}' 2>/dev/null || true)
            if [[ -z "$not_ready" ]]; then
                all_available=true
                break
            fi
            log_verbose "  Waiting for NNCPs: ${not_ready} (${elapsed}s/${timeout}s)"
            sleep 10
            (( elapsed += 10 ))
        done

        if [[ "$all_available" == "true" ]]; then
            log_success "  All NNCPs available"
        else
            log_warn "  Some NNCPs not yet available after ${timeout}s. Check: oc get nncp -l storage-lta/cloud=${cloud_name}"
        fi
    else
        log_error "  oc apply failed. Review the NNCP YAMLs in ${nncp_dir}/"
        return 1
    fi
}

# ---- OCP: iSCSI + multipath via oc debug ------------------------------------
setup_iscsi_initiator_ocp() {
    local node="$1"
    log "  Configuring iSCSI initiator on node ${node} via oc debug..."

    run_on_host "$node" "systemctl enable --now iscsid 2>/dev/null; \
        test -s /etc/iscsi/initiatorname.iscsi || echo \"InitiatorName=\$(iscsi-iname)\" > /etc/iscsi/initiatorname.iscsi; \
        echo OK" || {
        log_warn "  Could not configure iSCSI on ${node}"
        return 0
    }
    log_success "  iSCSI initiator ready on ${node}"
}

setup_multipath_vendor_ocp() {
    local node="$1"
    local vendor="$2"

    local vendor_pattern=""
    local config_block=""
    case "$vendor" in
        ibm)
            config_block="$MULTIPATH_IBM"
            vendor_pattern='vendor.*"IBM"'
            ;;
        pure)
            config_block="$MULTIPATH_PURE"
            vendor_pattern='vendor.*"PURE"'
            ;;
        netapp-asa|netapp-aff)
            config_block="$MULTIPATH_NETAPP"
            vendor_pattern='vendor.*"NETAPP"'
            ;;
        *)
            log_warn "  No multipath config known for vendor '${vendor}'; skipping"
            return 0
            ;;
    esac

    local check
    check=$(run_on_host "$node" "grep -q '${vendor_pattern}' /etc/multipath.conf 2>/dev/null && echo EXISTS || echo NOT_FOUND")
    if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

    if [[ "$check" == "EXISTS" ]]; then
        log_verbose "  Multipath config for ${vendor} already present on ${node}"
        return 0
    fi

    log "  Adding multipath config for ${vendor} on ${node} via oc debug..."
    run_on_host "$node" "cp /etc/multipath.conf /etc/multipath.conf.bak.\$(date +%s); \
        cat >> /etc/multipath.conf <<'EOFMP'
${config_block}
EOFMP
echo ADDED" || {
        log_error "  Failed to update multipath.conf on ${node}"
        return 1
    }
    log_success "  Multipath config for ${vendor} added on ${node}"
}

# ---- Bare-metal / VMware: VLAN interfaces via SSH + nmcli --------------------
setup_vlan_interfaces_ssh() {
    local worker="$1"
    local model="$2"

    log "  Setting up VLAN sub-interfaces on ${worker} via nmcli (model: ${model})..."

    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        local os_nic
        os_nic=$(resolve_os_iface "$model" "$bios_nic")
        local profile="vlan${vlan_id}"
        local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"

        log "    ${bios_nic} (${os_nic}): ${profile} → ${vendor_name} path ${path} (${subnet_base}.0/24, DHCP)"

        if [[ "$DRY_RUN" == "true" ]]; then continue; fi

        # Set parent MTU to 9000 if needed
        run_on_host "$worker" "
            current_mtu=\$(ip link show ${os_nic} 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo 0)
            if [ \"\$current_mtu\" -lt 9000 ] 2>/dev/null; then
                parent_profile=\$(nmcli -g NAME device show ${os_nic} 2>/dev/null || true)
                if [ -n \"\$parent_profile\" ]; then
                    nmcli connection modify \"\$parent_profile\" 802-3-ethernet.mtu 9000 2>/dev/null || true
                    nmcli connection up \"\$parent_profile\" 2>/dev/null || true
                fi
            fi
        " || true

        # Create VLAN sub-interface with DHCP
        run_on_host "$worker" "
            if nmcli -g NAME connection show 2>/dev/null | grep -qx '${profile}'; then
                nmcli connection down '${profile}' 2>/dev/null || true
                nmcli connection modify '${profile}' \
                    ipv4.method auto \
                    ipv6.method disabled \
                    ipv4.dns '' \
                    ipv4.gateway '' \
                    mtu 9000 \
                    connection.autoconnect yes
            else
                nmcli connection add \
                    type vlan \
                    con-name '${profile}' \
                    ifname '${profile}' \
                    dev '${os_nic}' \
                    id '${vlan_id}' \
                    ipv4.method auto \
                    ipv6.method disabled \
                    ipv4.dns '' \
                    ipv4.gateway '' \
                    mtu 9000 \
                    connection.autoconnect yes
            fi
            nmcli connection up '${profile}'
        " || {
            log_error "    Failed to create/activate ${profile} on ${worker}"
            continue
        }
        log_success "    ${profile} active on ${worker}"
    done
}

# ---- Bare-metal: iSCSI + multipath via SSH -----------------------------------
setup_iscsi_initiator_ssh() {
    local worker="$1"
    log "  Configuring iSCSI initiator on ${worker} via SSH..."

    local check
    check=$(run_on_host "$worker" "systemctl is-active iscsid 2>/dev/null || echo inactive")
    if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

    if [[ "$check" != "active" ]]; then
        run_on_host "$worker" "systemctl enable --now iscsid" || log_warn "  Could not start iscsid on ${worker}"
    fi

    run_on_host "$worker" "test -s /etc/iscsi/initiatorname.iscsi || echo 'InitiatorName=\$(iscsi-iname)' | tee /etc/iscsi/initiatorname.iscsi" || true
    log_success "  iSCSI initiator ready on ${worker}"
}

setup_multipath_vendor_ssh() {
    local worker="$1"
    local vendor="$2"

    local config_block=""
    local vendor_pattern=""
    case "$vendor" in
        ibm)
            config_block="$MULTIPATH_IBM"
            vendor_pattern='vendor.*"IBM"'
            ;;
        pure)
            config_block="$MULTIPATH_PURE"
            vendor_pattern='vendor.*"PURE"'
            ;;
        netapp-asa|netapp-aff)
            config_block="$MULTIPATH_NETAPP"
            vendor_pattern='vendor.*"NETAPP"'
            ;;
        *)
            log_warn "  No multipath config known for vendor '${vendor}'; skipping"
            return 0
            ;;
    esac

    local check
    check=$(run_on_host "$worker" "grep -q '${vendor_pattern}' /etc/multipath.conf 2>/dev/null && echo EXISTS || echo NOT_FOUND")
    if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

    if [[ "$check" == "EXISTS" ]]; then
        log_verbose "  Multipath config for ${vendor} already present on ${worker}"
        return 0
    fi

    log "  Adding multipath config for ${vendor} on ${worker}..."
    run_on_host "$worker" "cp /etc/multipath.conf /etc/multipath.conf.bak.\$(date +%s); \
        cat >> /etc/multipath.conf <<'EOFMP'
${config_block}
EOFMP
echo ADDED" || {
        log_error "  Failed to update multipath.conf on ${worker}"
        return 1
    }
    log_success "  Multipath config for ${vendor} added on ${worker}"
}

# ---- Main host-setup dispatcher ----------------------------------------------
do_host_setup() {
    log "=== STAGE: host-setup ==="

    if [[ -z "$STORAGE_ARRAYS" ]]; then
        log_error "STORAGE_ARRAYS not set. Cannot determine which VLANs to create."
        return 1
    fi

    log "Target type: ${TARGET_TYPE}"
    log "VLAN layout plan (alternating NIC-to-path mapping):"
    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
        log "  ${bios_nic}: vlan${vlan_id} → ${vendor_name} path ${path} (${subnet_base}.0/24)"
    done

    local json
    json=$(quads_query_hosts) || return 1

    local -a vendors_arr
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"

    # ---- OCP path: NNCP for VLANs, oc debug for iSCSI/multipath ----
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        log ""
        log "--- OCP mode: VLAN interfaces via NNCP ---"
        setup_vlan_interfaces_ocp "$json"

        log ""
        log "--- OCP mode: iSCSI + multipath via oc debug ---"

        # Get actual OCP worker node names
        local -a ocp_worker_list=()
        if command -v oc &>/dev/null; then
            mapfile -t ocp_worker_list < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi

        if (( ${#ocp_worker_list[@]} == 0 )); then
            log_warn "  No OCP worker nodes found. Skipping iSCSI/multipath setup."
        else
            for node in "${ocp_worker_list[@]}"; do
                if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
                    continue
                fi

                log ""
                log "=== Processing OCP node: ${node} ==="

                if [[ "$DRY_RUN" != "true" ]]; then
                    if ! test_host_reachable "$node"; then
                        log_error "  Cannot reach node ${node} via oc debug. Skipping."
                        continue
                    fi
                fi

                setup_iscsi_initiator_ocp "$node"

                for vendor in "${vendors_arr[@]}"; do
                    setup_multipath_vendor_ocp "$node" "$vendor"
                done

                if [[ "$DRY_RUN" != "true" ]]; then
                    log "  Restarting multipathd and iscsi services..."
                    run_on_host "$node" "systemctl restart multipathd iscsi 2>/dev/null; systemctl enable multipathd iscsid 2>/dev/null" || true
                    log_success "  Services restarted on ${node}"
                fi
            done
        fi

    # ---- Bare-metal / VMware path: SSH + nmcli ----
    else
        log ""
        log "--- Bare-metal/VMware mode: SSH + nmcli ---"
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && { log "Skipping excluded host: ${hostname}"; continue; }
            fi
            if [[ -n "$SINGLE_WORKER" && "$hostname" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi

            local worker
            worker=$(get_worker_id "$hostname")
            log ""
            log "=== Processing: ${hostname} (${model}) ==="

            if [[ "$DRY_RUN" != "true" ]]; then
                if ! test_host_reachable "$worker"; then
                    log_error "  Cannot SSH to ${worker}. Skipping."
                    continue
                fi
            fi

            setup_vlan_interfaces_ssh "$worker" "$model"
            setup_iscsi_initiator_ssh "$worker"

            for vendor in "${vendors_arr[@]}"; do
                setup_multipath_vendor_ssh "$worker" "$vendor"
            done

            if [[ "$DRY_RUN" != "true" ]]; then
                log "  Restarting multipathd and iscsi services..."
                run_on_host "$worker" "systemctl restart multipathd iscsi 2>/dev/null; systemctl enable multipathd iscsid 2>/dev/null" || true
                log_success "  Services restarted on ${worker}"
            fi
        done
    fi
}

# =============================================================================
# BWS credential helpers (Bitwarden Secrets Manager CLI)
# =============================================================================
_BWS_CACHE=""
bws_load_cache() {
    if ! command -v bws &>/dev/null; then
        log_error "bws CLI not found. Install Bitwarden Secrets Manager CLI."
        return 1
    fi
    # Keep only storage credentials in the cache; set BWS_PROJECT_ID to
    # scope the list call to a dedicated project.
    local -a bws_list=(bws secret list -o json)
    if [[ -n "${BWS_PROJECT_ID:-}" ]]; then
        bws_list+=("${BWS_PROJECT_ID}")
    fi
    _BWS_CACHE=$("${bws_list[@]}" 2>/dev/null \
        | jq '[.[] | select(.key | startswith("STORAGE_"))]') || {
        log_error "bws secret list failed. Ensure BWS_ACCESS_TOKEN is set."
        return 1
    }
}
bws_get() {
    local key="$1"
    if [[ -z "$_BWS_CACHE" ]]; then
        bws_load_cache || return 1
    fi
    echo "$_BWS_CACHE" | jq -r --arg k "$key" '.[] | select(.key == $k) | .value'
}

storage_ssh() {
    local vendor="$1"; shift

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would SSH to ${vendor}: $*"
        return 0
    fi

    local host user pw
    case "$vendor" in
        ibm)
            host=$(bws_get "STORAGE_IBM_MGMT_IP")
            user=$(bws_get "STORAGE_IBM_USER")
            pw=$(bws_get "STORAGE_IBM_PW") ;;
        netapp-asa)
            host=$(bws_get "STORAGE_NETAPP_ASA_MGMT_IP")
            user=$(bws_get "STORAGE_NETAPP_ASA_USER")
            pw=$(bws_get "STORAGE_NETAPP_ASA_PW") ;;
        netapp-aff)
            host=$(bws_get "STORAGE_NETAPP_AFF_MGMT_IP")
            user=$(bws_get "STORAGE_NETAPP_AFF_USER")
            pw=$(bws_get "STORAGE_NETAPP_AFF_MGMT_PW") ;;
        pure)
            host=$(bws_get "STORAGE_PURE_MGMT_IP")
            user=$(bws_get "STORAGE_PURE_USER")
            pw=$(bws_get "STORAGE_PURE_PW") ;;
        *)
            log_error "Unknown vendor for storage_ssh: $vendor"
            return 1 ;;
    esac

    if [[ -z "$host" || -z "$user" || -z "$pw" ]]; then
        log_error "Missing credentials for ${vendor} (host=${host:-EMPTY}, user=${user:-EMPTY})"
        return 1
    fi

    log_verbose "  storage_ssh ${vendor} (${host}): $*"
    # PubkeyAuthentication=no: arrays authenticate via password only; a local
    # ssh-agent key the array doesn't know makes some arrays (IBM Storage
    # Virtualize: CMMVC7016E) abort the connection instead of falling back.
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PubkeyAuthentication=no "${user}@${host}" "$@"
}

# =============================================================================
# Collect iSCSI initiator IQNs from workers
# =============================================================================
collect_worker_iqns() {
    local -a iqns=()

    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        local -a ocp_workers=()
        if command -v oc &>/dev/null; then
            mapfile -t ocp_workers < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi
        for node in "${ocp_workers[@]}"; do
            if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi
            local iqn
            iqn=$(run_on_host "$node" "grep -oP 'InitiatorName=\K.*' /etc/iscsi/initiatorname.iscsi 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$iqn" && "$iqn" == iqn.* ]]; then
                iqns+=("${node}:${iqn}")
                log "  ${node}: ${iqn}"
            else
                log_warn "  ${node}: no valid IQN found"
            fi
        done
    else
        local json
        json=$(quads_query_hosts) || return 1
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && continue
            fi
            local worker
            worker=$(get_worker_id "$hostname")
            local iqn
            iqn=$(run_on_host "$worker" "grep -oP 'InitiatorName=\K.*' /etc/iscsi/initiatorname.iscsi 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$iqn" && "$iqn" == iqn.* ]]; then
                iqns+=("${worker}:${iqn}")
                log "  ${worker}: ${iqn}"
            else
                log_warn "  ${worker}: no valid IQN found"
            fi
        done
    fi

    # Guard: printf '%s\n' with an empty array still emits one blank line,
    # which mapfile would turn into a phantom empty "worker:iqn" pair.
    if (( ${#iqns[@]} > 0 )); then
        printf '%s\n' "${iqns[@]}"
    fi
}

# =============================================================================
# Parse LUN_SIZE into vendor-specific format
# =============================================================================
parse_lun_size_ibm() {
    local size="$1"
    local num unit
    num=$(echo "$size" | grep -oP '^\d+')
    unit=$(echo "$size" | grep -oP '[A-Za-z]+$' | tr '[:upper:]' '[:lower:]')
    case "$unit" in
        tb) echo "${num} tb" ;;
        gb) echo "${num} gb" ;;
        *)  echo "${num} gb" ;;
    esac
}

parse_lun_size_pure() {
    local size="$1"
    local num unit
    num=$(echo "$size" | grep -oP '^\d+')
    unit=$(echo "$size" | grep -oP '[A-Za-z]+$' | tr '[:upper:]' '[:lower:]')
    case "$unit" in
        tb) echo "${num}T" ;;
        gb) echo "${num}G" ;;
        *)  echo "${num}G" ;;
    esac
}

# =============================================================================
# STORAGE-SETUP: NetApp ASA A70
# =============================================================================
storage_setup_netapp_asa() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- NetApp ASA A70: storage-setup for ${cloud_name} ---"

    local svm="svm_${cloud_name}"
    local ipspace="ipspace_${cloud_name}"

    # Derive VLAN IDs and subnets from compute_vlan_layout (filter to netapp-asa)
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "netapp-asa" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No netapp-asa entries in VLAN layout. Skipping."
        return 0
    fi

    # Nodes on the ASA
    local node1="ntap-asa-a70-01"
    local node2="ntap-asa-a70-02"
    local port_a="e1b"
    local port_b="e7b"

    # --- Sub-stage A: verify or create IPspace, broadcast domains, VLAN ports, SVM, LIFs ---
    log "  [A] Checking IPspace, broadcast domains, VLAN ports, SVM, and LIFs..."

    local vlanA="${vlan_ids[0]}"
    local vlanB="${vlan_ids[1]}"
    local subA="${subnet_bases[0]}"
    local subB="${subnet_bases[1]}"
    local bd_a="bd_${cloud_name}_a"
    local bd_b="bd_${cloud_name}_b"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would ensure: ipspace ${ipspace}, broadcast domains, VLAN ports, SVM ${svm}, 4 LIFs"
    else
        # Step 1: IPspace (checked independently)
        local ipspace_check
        ipspace_check=$(storage_ssh netapp-asa "ipspace show -ipspace ${ipspace}" 2>/dev/null | grep -c "${ipspace}" || true)
        if [[ "$ipspace_check" -gt 0 ]]; then
            log_success "  IPspace ${ipspace} already exists"
        else
            storage_ssh netapp-asa "ipspace create -ipspace ${ipspace}" 2>/dev/null || log_warn "  IPspace creation failed (may already exist)"
            log_success "  IPspace ${ipspace} created"
        fi

        # Step 2: Broadcast domains (checked independently — no duplicate-entry noise on re-runs)
        local bd
        for bd in "$bd_a" "$bd_b"; do
            local bd_check
            bd_check=$(storage_ssh netapp-asa "network port broadcast-domain show -broadcast-domain ${bd}" 2>/dev/null | grep -c "${bd}" || true)
            if [[ "$bd_check" -gt 0 ]]; then
                log_success "  Broadcast domain ${bd} already exists"
            else
                storage_ssh netapp-asa "network port broadcast-domain create -broadcast-domain ${bd} -mtu 9000 -ipspace ${ipspace}" 2>/dev/null || log_warn "  Broadcast domain ${bd} creation failed"
                log_success "  Broadcast domain ${bd} created"
            fi
        done

        # Step 3: VLAN ports + broadcast-domain membership (reconciled on every run;
        # one port query drives create-if-missing, remove-from-wrong-domain, add-to-target)
        local -a add_a=() add_b=()
        local node vp cur_bd target_bd
        for node in "$node1" "$node2"; do
            for vp in "${port_a}-${vlanA}" "${port_b}-${vlanB}"; do
                if [[ "$vp" == "${port_b}-${vlanB}" ]]; then
                    target_bd="$bd_b"
                else
                    target_bd="$bd_a"
                fi
                cur_bd=$(storage_ssh netapp-asa "network port show -node ${node} -port ${vp} -fields broadcast-domain" 2>/dev/null | grep "${vp}" | awk '{print $3}' || true)
                if [[ -z "$cur_bd" ]]; then
                    # VLAN port doesn't exist yet — create it (auto-assigned to a Default-ipspace domain)
                    storage_ssh netapp-asa "network port vlan create -node ${node} -vlan-name ${vp}" 2>/dev/null || log_warn "  VLAN port ${node}:${vp} creation failed"
                    log_success "  VLAN port ${node}:${vp} created"
                elif [[ "$cur_bd" == "$target_bd" ]]; then
                    log_verbose "  ${node}:${vp} already in ${target_bd}"
                    continue
                elif [[ "$cur_bd" != "-" ]]; then
                    log "  Moving ${node}:${vp} from ${cur_bd} to ${target_bd}"
                    storage_ssh netapp-asa "network port broadcast-domain remove-ports -ipspace Default -broadcast-domain ${cur_bd} -ports ${node}:${vp}" 2>/dev/null || true
                fi
                if [[ "$target_bd" == "$bd_a" ]]; then
                    add_a+=("${node}:${vp}")
                else
                    add_b+=("${node}:${vp}")
                fi
            done
        done

        if (( ${#add_a[@]} > 0 )); then
            storage_ssh netapp-asa "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_a} -ports $(IFS=,; echo "${add_a[*]}")" 2>/dev/null || log_warn "  Failed to add ports to ${bd_a}"
            log_success "  Ports added to ${bd_a}"
        else
            log_success "  Path-A ports already homed in ${bd_a}"
        fi
        if (( ${#add_b[@]} > 0 )); then
            storage_ssh netapp-asa "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_b} -ports $(IFS=,; echo "${add_b[*]}")" 2>/dev/null || log_warn "  Failed to add ports to ${bd_b}"
            log_success "  Ports added to ${bd_b}"
        else
            log_success "  Path-B ports already homed in ${bd_b}"
        fi

        # Step 4: SVM (checked independently)
        local svm_exists
        svm_exists=$(storage_ssh netapp-asa "vserver show -vserver ${svm} -fields vserver" 2>/dev/null | grep -c "${svm}" || true)
        if [[ "$svm_exists" -gt 0 ]]; then
            log_success "  SVM ${svm} already exists"
        else
            storage_ssh netapp-asa "vserver create -vserver ${svm} -ipspace ${ipspace} -rootvolume ${svm}_root -rootvolume-security-style unix" 2>/dev/null || log_warn "  SVM creation failed"
            log_success "  SVM ${svm} created"
        fi

        # (No `vserver iscsi create` step: ASA r2 enables the iSCSI service
        #  implicitly — that step is standard-ONTAP/AFF only.)

        # Step 5: LIFs (checked by count, not just displayed)
        local lif_count
        lif_count=$(storage_ssh netapp-asa "network interface show -vserver ${svm} -fields address" 2>/dev/null | grep -c "iscsi_${cloud_name}" || true)
        if [[ "$lif_count" -ge 4 ]]; then
            log_success "  All 4 LIFs already exist"
            local lif_output
            lif_output=$(storage_ssh netapp-asa "network interface show -vserver ${svm} -fields address,status-oper" 2>/dev/null) || true
            log "  LIF status:"
            echo "$lif_output" | grep -E "iscsi|${cloud_name}" | while IFS= read -r line; do
                log "    $line"
            done || true
        else
            log "  Creating LIFs (found ${lif_count}/4)..."
            storage_ssh netapp-asa "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_a -data-protocol iscsi -home-node ${node1} -home-port ${port_a}-${vlanA} -address ${subA}.2 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            storage_ssh netapp-asa "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_a -data-protocol iscsi -home-node ${node2} -home-port ${port_a}-${vlanA} -address ${subA}.3 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            storage_ssh netapp-asa "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_b -data-protocol iscsi -home-node ${node1} -home-port ${port_b}-${vlanB} -address ${subB}.2 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            storage_ssh netapp-asa "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_b -data-protocol iscsi -home-node ${node2} -home-port ${port_b}-${vlanB} -address ${subB}.3 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            log_success "  LIF creation commands issued"
        fi
    fi

    # --- Sub-stage B: Volumes/LUNs ---
    log "  [B] Creating LUN(s)..."
    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local lun_name
        lun_name=$(printf "${cloud_name}_iscsi_lta_ntapasa_lun%02d" "$i")
        local lun_check
        lun_check=$(storage_ssh netapp-asa "lun show -vserver ${svm} -path ${lun_name} -fields path" 2>/dev/null | grep -c "${lun_name}" || true)
        if [[ "$lun_check" -gt 0 ]]; then
            log_success "  LUN ${lun_name} already exists"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: lun create -vserver ${svm} -path ${lun_name} -size ${LUN_SIZE} -ostype linux"
            else
                storage_ssh netapp-asa "lun create -vserver ${svm} -path ${lun_name} -size ${LUN_SIZE} -ostype linux" 2>/dev/null || {
                    log_error "  Failed to create LUN ${lun_name}"
                    continue
                }
                log_success "  LUN ${lun_name} created (${LUN_SIZE})"
            fi
        fi
    done

    # --- Sub-stage C: igroup ---
    log "  [C] Creating igroup..."
    local ig_name="${cloud_name}_iscsi_ig"
    local ig_check
    ig_check=$(storage_ssh netapp-asa "lun igroup show -vserver ${svm} -igroup ${ig_name}" 2>/dev/null | grep -c "${ig_name}" || true)

    local iqn_list=""
    for pair in "${iqn_pairs[@]}"; do
        local iqn="${pair#*:}"
        [[ -n "$iqn_list" ]] && iqn_list+=","
        iqn_list+="$iqn"
    done

    if [[ "$ig_check" -gt 0 ]]; then
        log_success "  igroup ${ig_name} already exists"
        # Add any missing initiators
        for pair in "${iqn_pairs[@]}"; do
            local worker_name="${pair%%:*}"
            local iqn="${pair#*:}"
            local already
            already=$(storage_ssh netapp-asa "lun igroup show -vserver ${svm} -igroup ${ig_name} -fields initiator" 2>/dev/null | grep -c "$iqn" || true)
            if [[ "$already" -eq 0 ]]; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    storage_ssh netapp-asa "lun igroup add -vserver ${svm} -igroup ${ig_name} -initiator ${iqn}" 2>/dev/null || true
                    log "  Added initiator ${iqn} (${worker_name}) to ${ig_name}"
                else
                    log "[DRY-RUN] Would add initiator ${iqn} to ${ig_name}"
                fi
            fi
        done
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create igroup ${ig_name} with initiators: ${iqn_list}"
        elif [[ -n "$iqn_list" ]]; then
            storage_ssh netapp-asa "lun igroup create -vserver ${svm} -igroup ${ig_name} -protocol iscsi -ostype linux -initiator ${iqn_list}" 2>/dev/null || {
                log_error "  Failed to create igroup ${ig_name}"
                return 1
            }
            log_success "  igroup ${ig_name} created with ${#iqn_pairs[@]} initiators"
        else
            log_warn "  No IQNs collected — skipping igroup creation"
        fi
    fi

    # --- Sub-stage D: LUN mapping ---
    log "  [D] Mapping LUN(s) to igroup..."
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local lun_name
        lun_name=$(printf "${cloud_name}_iscsi_lta_ntapasa_lun%02d" "$i")
        local lun_id=$(( i - 1 ))
        local map_check
        map_check=$(storage_ssh netapp-asa "lun mapping show -vserver ${svm} -path ${lun_name} -fields igroup" 2>/dev/null | grep -c "${ig_name}" || true)
        if [[ "$map_check" -gt 0 ]]; then
            log_success "  LUN ${lun_name} already mapped to ${ig_name}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would map: lun mapping create -vserver ${svm} -path ${lun_name} -igroup ${ig_name} -lun-id ${lun_id}"
            else
                storage_ssh netapp-asa "lun mapping create -vserver ${svm} -path ${lun_name} -igroup ${ig_name} -lun-id ${lun_id}" 2>/dev/null || {
                    log_error "  Failed to map LUN ${lun_name}"
                    continue
                }
                log_success "  LUN ${lun_name} mapped to ${ig_name} (lun-id ${lun_id})"
            fi
        fi
    done

    # Verify final state
    log "  Verifying final state..."
    local verify_out
    verify_out=$(storage_ssh netapp-asa "lun show -vserver ${svm}" 2>/dev/null) || true
    echo "$verify_out" | grep -E "${cloud_name}" | while IFS= read -r line; do
        log "    $line"
    done || true
    verify_out=$(storage_ssh netapp-asa "lun mapping show -vserver ${svm}" 2>/dev/null) || true
    echo "$verify_out" | grep -E "${cloud_name}" | while IFS= read -r line; do
        log "    $line"
    done || true

    log_success "  NetApp ASA storage-setup complete for ${cloud_name}"
}

# =============================================================================
# STORAGE-SETUP: Pure FlashArray X70R5 (INSPECT ONLY — generate commands)
# =============================================================================
storage_setup_pure() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- Pure FlashArray X70R5: storage-setup for ${cloud_name} ---"

    # Derive VLAN layout for Pure
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "pure" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No pure entries in VLAN layout. Skipping."
        return 0
    fi

    local hg_name="${cloud_name}_iscsi_hg"

    # --- Sub-stage A: Create subnets and portal IPs ---
    log "  [A] Creating subnets and portal IPs..."
    local idx
    for (( idx=0; idx<${#vlan_ids[@]}; idx++ )); do
        local vid="${vlan_ids[$idx]}"
        local sub="${subnet_bases[$idx]}"
        local pth="${paths[$idx]}"
        local subnet_name="${cloud_name}_pure_path${pth}"

        # Check if subnet already exists
        local sub_check
        sub_check=$(storage_ssh pure "purenetwork subnet list" 2>/dev/null | grep -c "${subnet_name}" || true)
        if [[ "$sub_check" -gt 0 ]]; then
            log_success "  Subnet ${subnet_name} already exists"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create subnet: purenetwork subnet create --vlan ${vid} --prefix ${sub}.0/24 --gateway ${sub}.1 ${subnet_name}"
            else
                storage_ssh pure "purenetwork subnet create --vlan ${vid} --prefix ${sub}.0/24 --gateway ${sub}.1 ${subnet_name}" 2>/dev/null || {
                    log_error "  Failed to create subnet ${subnet_name}"
                }
                log_success "  Subnet ${subnet_name} created (VLAN ${vid})"
            fi
        fi

        # Create eth interfaces: ct0 and ct1 on eth14
        for ct_idx in 0 1; do
            local portal_ip="${sub}.$(( ct_idx + 2 ))"
            local iface="ct${ct_idx}.eth14.${vid}"

            local eth_check
            eth_check=$(storage_ssh pure "purenetwork eth list" 2>/dev/null | grep -c "${iface}" || true)
            if [[ "$eth_check" -gt 0 ]]; then
                log_success "  Interface ${iface} already exists"
            else
                if [[ "$DRY_RUN" == "true" ]]; then
                    log "[DRY-RUN] Would create: purenetwork eth create --address ${portal_ip} ${iface}"
                else
                    storage_ssh pure "purenetwork eth create --address ${portal_ip} ${iface}" 2>/dev/null || {
                        log_error "  Failed to create interface ${iface}"
                    }
                    log_success "  Interface ${iface} created (${portal_ip})"
                fi
            fi
        done
    done

    # --- Sub-stage B: Create volume(s) ---
    log "  [B] Creating volume(s)..."
    local pure_size
    pure_size=$(parse_lun_size_pure "$LUN_SIZE")
    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name
        vol_name=$(printf "${cloud_name}_iscsi_lta_pure_vol%02d" "$i")

        local vol_check
        vol_check=$(storage_ssh pure "purevol list" 2>/dev/null | grep -c "${vol_name}" || true)
        if [[ "$vol_check" -gt 0 ]]; then
            log_success "  Volume ${vol_name} already exists"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: purevol create --size ${pure_size} ${vol_name}"
            else
                storage_ssh pure "purevol create --size ${pure_size} ${vol_name}" 2>/dev/null || {
                    log_error "  Failed to create volume ${vol_name}"
                    continue
                }
                log_success "  Volume ${vol_name} created (${pure_size})"
            fi
        fi
    done

    # --- Sub-stage C: Create hosts and host group ---
    log "  [C] Creating hosts and host group..."

    # Create host group
    local hg_check
    hg_check=$(storage_ssh pure "purehostgroup list" 2>/dev/null | grep -c "${hg_name}" || true)
    if [[ "$hg_check" -gt 0 ]]; then
        log_success "  Host group ${hg_name} already exists"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create: purehostgroup create ${hg_name}"
        else
            storage_ssh pure "purehostgroup create ${hg_name}" 2>/dev/null || {
                log_error "  Failed to create host group ${hg_name}"
            }
            log_success "  Host group ${hg_name} created"
        fi
    fi

    # Create per-worker hosts and connect to host group
    for pair in "${iqn_pairs[@]}"; do
        local worker_name="${pair%%:*}"
        local iqn="${pair#*:}"
        local host_name="${cloud_name}_host_${worker_name}"

        local host_check
        host_check=$(storage_ssh pure "purehost list" 2>/dev/null | grep -c "${host_name}" || true)
        if [[ "$host_check" -gt 0 ]]; then
            log_success "  Host ${host_name} already exists"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: purehost create --iqnlist ${iqn} ${host_name}"
            else
                storage_ssh pure "purehost create --iqnlist ${iqn} ${host_name}" 2>/dev/null || {
                    log_error "  Failed to create host ${host_name}"
                    continue
                }
                log_success "  Host ${host_name} created (${iqn})"
            fi
        fi

        # Connect host to host group (idempotent — Pure ignores if already connected)
        local conn_check
        conn_check=$(storage_ssh pure "purehost list --connect" 2>/dev/null | grep "${host_name}" | grep -c "${hg_name}" || true)
        if [[ "$conn_check" -gt 0 ]]; then
            log_success "  Host ${host_name} already in ${hg_name}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would connect: purehost connect --hostgroup ${hg_name} ${host_name}"
            else
                storage_ssh pure "purehost connect --hostgroup ${hg_name} ${host_name}" 2>/dev/null || {
                    log_error "  Failed to connect ${host_name} to ${hg_name}"
                }
                log_success "  Host ${host_name} connected to ${hg_name}"
            fi
        fi
    done

    # --- Sub-stage D: Map volume(s) to host group ---
    log "  [D] Mapping volume(s) to host group..."
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name
        vol_name=$(printf "${cloud_name}_iscsi_lta_pure_vol%02d" "$i")

        local map_check
        map_check=$(storage_ssh pure "purevol list --connect" 2>/dev/null | grep "${vol_name}" | grep -c "${hg_name}" || true)
        if [[ "$map_check" -gt 0 ]]; then
            log_success "  Volume ${vol_name} already mapped to ${hg_name}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would connect: purevol connect --hostgroup ${hg_name} ${vol_name}"
            else
                storage_ssh pure "purevol connect --hostgroup ${hg_name} ${vol_name}" 2>/dev/null || {
                    log_error "  Failed to map volume ${vol_name} to ${hg_name}"
                    continue
                }
                log_success "  Volume ${vol_name} mapped to ${hg_name}"
            fi
        fi
    done

    # --- Verify ---
    log "  Verifying final state..."
    local verify_out
    verify_out=$(storage_ssh pure "purenetwork subnet list" 2>/dev/null) || true
    echo "$verify_out" | grep -E "${cloud_name}" | while IFS= read -r line; do
        log "    $line"
    done || true
    verify_out=$(storage_ssh pure "purevol list --connect" 2>/dev/null) || true
    echo "$verify_out" | grep -E "${cloud_name}" | while IFS= read -r line; do
        log "    $line"
    done || true

    log_success "  Pure storage-setup complete for ${cloud_name}"
}

# =============================================================================
# STORAGE-SETUP: IBM FlashSystem 7300
# =============================================================================
storage_setup_ibm() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- IBM FlashSystem 7300: storage-setup for ${cloud_name} ---"

    # Derive VLAN layout for IBM
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "ibm" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No ibm entries in VLAN layout. Skipping."
        return 0
    fi

    local portset_name="${cloud_name}_iscsi_portset"

    # --- Sub-stage A: Portset + iSCSI VLAN IPs ---
    log "  [A] Creating portset and iSCSI VLAN IPs..."
    local portset_check
    portset_check=$(storage_ssh ibm "svcinfo lsportset -delim :" 2>/dev/null | grep -c "${portset_name}" || true)

    if [[ "$portset_check" -gt 0 ]]; then
        log_success "  Portset ${portset_name} already exists"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create portset: svctask mkportset -name ${portset_name} -type host"
        else
            storage_ssh ibm "svctask mkportset -name ${portset_name} -type host" 2>/dev/null || {
                log_error "  Failed to create portset ${portset_name}"
                return 1
            }
            log_success "  Portset ${portset_name} created"
        fi
    fi

    # Create iSCSI IPs on node ports (node1 ports 5,7; node2 ports 6,8)
    # Path A uses ports 5 (node1) and 6 (node2)
    # Path B uses ports 7 (node1) and 8 (node2)
    local -a ip_configs=()
    if (( ${#vlan_ids[@]} >= 1 )); then
        local vlanA="${vlan_ids[0]}"
        local subA="${subnet_bases[0]}"
        ip_configs+=("node1 5 ${subA}.2 ${vlanA}")
        ip_configs+=("node2 6 ${subA}.3 ${vlanA}")
    fi
    if (( ${#vlan_ids[@]} >= 2 )); then
        local vlanB="${vlan_ids[1]}"
        local subB="${subnet_bases[1]}"
        ip_configs+=("node1 7 ${subB}.2 ${vlanB}")
        ip_configs+=("node2 8 ${subB}.3 ${vlanB}")
    fi

    local -a portal_ips=()
    for cfg in "${ip_configs[@]}"; do
        local node port ip vlan
        read -r node port ip vlan <<< "$cfg"

        # Check if IP already exists
        local ip_check
        ip_check=$(storage_ssh ibm "svcinfo lsip -delim :" 2>/dev/null | grep -c "${ip}" || true)

        if [[ "$ip_check" -gt 0 ]]; then
            log_success "  IP ${ip} already configured on ${node}:port${port}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: svctask mkip -node ${node} -port ${port} -ip ${ip} -prefix 24 -portset ${portset_name} -vlan ${vlan}"
            else
                storage_ssh ibm "svctask mkip -node ${node} -port ${port} -ip ${ip} -prefix 24 -portset ${portset_name} -vlan ${vlan}" 2>/dev/null || {
                    log_error "  Failed to create IP ${ip} on ${node}:port${port}"
                    continue
                }
                log_success "  IP ${ip} created on ${node}:port${port} (VLAN ${vlan})"
            fi
        fi
        portal_ips+=("$ip")

        # Add to portset
        local member_check
        member_check=$(storage_ssh ibm "svcinfo lsportsetmember -delim : ${portset_name}" 2>/dev/null | grep -c "${ip}" || true)
        if [[ "$member_check" -eq 0 ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would add: svctask addportsetmember -portset ${portset_name} -ip ${ip}"
            else
                storage_ssh ibm "svctask addportsetmember -portset ${portset_name} -ip ${ip}" 2>/dev/null || true
                log "  Added ${ip} to portset ${portset_name}"
            fi
        fi
    done

    # --- Sub-stage B: Volumes (vdisks) ---
    log "  [B] Creating vdisk(s)..."
    local ibm_size_parts
    ibm_size_parts=$(parse_lun_size_ibm "$LUN_SIZE")
    local ibm_num ibm_unit
    read -r ibm_num ibm_unit <<< "$ibm_size_parts"

    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vdisk_name
        vdisk_name=$(printf "${cloud_name}_iscsi_lta_ibm_vdisk%02d" "$i")
        local vd_check
        vd_check=$(storage_ssh ibm "svcinfo lsvdisk ${vdisk_name}" 2>/dev/null | grep -c "${vdisk_name}" || true)
        if [[ "$vd_check" -gt 0 ]]; then
            log_success "  vdisk ${vdisk_name} already exists"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: svctask mkvdisk -mdiskgrp Pool0 -iogrp io_grp0 -size ${ibm_num} -unit ${ibm_unit} -name ${vdisk_name}"
            else
                storage_ssh ibm "svctask mkvdisk -mdiskgrp Pool0 -iogrp io_grp0 -size ${ibm_num} -unit ${ibm_unit} -name ${vdisk_name}" 2>/dev/null || {
                    log_error "  Failed to create vdisk ${vdisk_name}"
                    continue
                }
                log_success "  vdisk ${vdisk_name} created (${LUN_SIZE})"
            fi
        fi
    done

    # --- Sub-stage C: Hosts ---
    log "  [C] Creating host objects..."
    for pair in "${iqn_pairs[@]}"; do
        local worker_name="${pair%%:*}"
        local iqn="${pair#*:}"
        local host_name="${cloud_name}_${worker_name}"

        local host_check
        host_check=$(storage_ssh ibm "svcinfo lshost ${host_name}" 2>/dev/null | grep -c "${host_name}" || true)
        if [[ "$host_check" -gt 0 ]]; then
            log_success "  Host ${host_name} already exists"
            # Ensure host is in the correct portset (may differ if created by a prior run)
            if [[ "$DRY_RUN" != "true" ]]; then
                local cur_portset
                cur_portset=$(storage_ssh ibm "svcinfo lshost ${host_name}" 2>/dev/null | awk '/^portset_name /{print $2}')
                if [[ "$cur_portset" != "${portset_name}" ]]; then
                    storage_ssh ibm "svctask chhost -portset ${portset_name} ${host_name}" 2>/dev/null || true
                    log "    Moved ${host_name} from portset '${cur_portset}' → '${portset_name}'"
                fi
            fi
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: svctask mkhost -name ${host_name} -iscsiname ${iqn} -iogrp io_grp0 -type generic -portset ${portset_name}"
            else
                storage_ssh ibm "svctask mkhost -name ${host_name} -iscsiname ${iqn} -iogrp io_grp0 -type generic -portset ${portset_name}" 2>/dev/null || {
                    log_error "  Failed to create host ${host_name}"
                    continue
                }
                log_success "  Host ${host_name} created (IQN: ${iqn})"
            fi
        fi
    done

    # --- Sub-stage D: LUN mapping ---
    log "  [D] Mapping vdisk(s) to hosts..."
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vdisk_name
        vdisk_name=$(printf "${cloud_name}_iscsi_lta_ibm_vdisk%02d" "$i")
        local scsi_id=$(( i - 1 ))

        for pair in "${iqn_pairs[@]}"; do
            local worker_name="${pair%%:*}"
            local host_name="${cloud_name}_${worker_name}"

            local map_check
            map_check=$(storage_ssh ibm "svcinfo lshostvdiskmap ${host_name}" 2>/dev/null | grep -c "${vdisk_name}" || true)
            if [[ "$map_check" -gt 0 ]]; then
                log_success "  vdisk ${vdisk_name} already mapped to ${host_name}"
            else
                if [[ "$DRY_RUN" == "true" ]]; then
                    log "[DRY-RUN] Would map: svctask mkvdiskhostmap -host ${host_name} -force -scsi ${scsi_id} ${vdisk_name}"
                else
                    storage_ssh ibm "svctask mkvdiskhostmap -host ${host_name} -force -scsi ${scsi_id} ${vdisk_name}" 2>/dev/null || {
                        log_error "  Failed to map ${vdisk_name} to ${host_name}"
                        continue
                    }
                    log_success "  vdisk ${vdisk_name} mapped to ${host_name} (scsi ${scsi_id})"
                fi
            fi
        done
    done

    # Verify final state
    log "  Verifying final state..."
    local verify_ps verify_ip
    verify_ps=$(storage_ssh ibm "svcinfo lsportset -delim :" 2>/dev/null | grep "${portset_name}" || true)
    [[ -n "$verify_ps" ]] && log "    Portset: ${verify_ps}"
    verify_ip=$(storage_ssh ibm "svcinfo lsip -delim :" 2>/dev/null | grep -E "$(IFS='|'; echo "${portal_ips[*]}")" || true)
    echo "$verify_ip" | while IFS= read -r line; do [[ -n "$line" ]] && log "    IP: $line"; done || true

    log_success "  IBM storage-setup complete for ${cloud_name}"
}

# =============================================================================
# STORAGE-SETUP: NetApp AFF A300
# =============================================================================
storage_setup_netapp_aff() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- NetApp AFF A300: storage-setup for ${cloud_name} ---"

    local svm="svm_${cloud_name}"
    local ipspace="ipspace_${cloud_name}"

    # Derive VLAN layout for netapp-aff
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "netapp-aff" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No netapp-aff entries in VLAN layout. Skipping."
        return 0
    fi

    # Nodes on the A300
    local node1="b02-h37-ntap-a300-01"
    local node2="b02-h37-ntap-a300-02"
    # Data ports — e0g and e0h are the 10GbE data ports on this A300
    local port_a="e0g"
    local port_b="e0h"

    # --- Sub-stage A: verify or create IPspace, SVM, LIFs ---
    log "  [A] Checking IPspace, SVM, iSCSI service, and LIFs..."

    local vlanA="${vlan_ids[0]}"
    local vlanB="${vlan_ids[1]}"
    local subA="${subnet_bases[0]}"
    local subB="${subnet_bases[1]}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would ensure: ipspace ${ipspace}, broadcast domains, VLAN ports, SVM ${svm}, iSCSI service, 4 LIFs"
    else
        # Step 1: IPspace
        local ipspace_check
        ipspace_check=$(storage_ssh netapp-aff "ipspace show -ipspace ${ipspace}" 2>/dev/null | grep -c "${ipspace}" || true)
        if [[ "$ipspace_check" -gt 0 ]]; then
            log_success "  IPspace ${ipspace} already exists"
        else
            storage_ssh netapp-aff "ipspace create -ipspace ${ipspace}" 2>/dev/null || log_warn "  IPspace creation failed (may already exist)"
            log_success "  IPspace ${ipspace} created"
        fi

        # Step 2: Broadcast domains (checked independently — no duplicate-entry noise on re-runs)
        local bd_a="bd_${cloud_name}_a"
        local bd_b="bd_${cloud_name}_b"
        local bd
        for bd in "$bd_a" "$bd_b"; do
            local bd_check
            bd_check=$(storage_ssh netapp-aff "network port broadcast-domain show -broadcast-domain ${bd}" 2>/dev/null | grep -c "${bd}" || true)
            if [[ "$bd_check" -gt 0 ]]; then
                log_success "  Broadcast domain ${bd} already exists"
            else
                storage_ssh netapp-aff "network port broadcast-domain create -broadcast-domain ${bd} -mtu 9000 -ipspace ${ipspace}" 2>/dev/null || log_warn "  Broadcast domain ${bd} creation failed"
                log_success "  Broadcast domain ${bd} created"
            fi
        done

        # Step 3: VLAN ports + broadcast-domain membership (reconciled on every run;
        # one port query drives create-if-missing, remove-from-wrong-domain, add-to-target)
        local -a add_a=() add_b=()
        local node vp cur_bd target_bd
        for node in "$node1" "$node2"; do
            for vp in "${port_a}-${vlanA}" "${port_b}-${vlanB}"; do
                if [[ "$vp" == "${port_b}-${vlanB}" ]]; then
                    target_bd="$bd_b"
                else
                    target_bd="$bd_a"
                fi
                cur_bd=$(storage_ssh netapp-aff "network port show -node ${node} -port ${vp} -fields broadcast-domain" 2>/dev/null | grep "${vp}" | awk '{print $3}' || true)
                if [[ -z "$cur_bd" ]]; then
                    # VLAN port doesn't exist yet — create it (auto-assigned to a Default-ipspace domain)
                    storage_ssh netapp-aff "network port vlan create -node ${node} -vlan-name ${vp}" 2>/dev/null || log_warn "  VLAN port ${node}:${vp} creation failed"
                    log_success "  VLAN port ${node}:${vp} created"
                elif [[ "$cur_bd" == "$target_bd" ]]; then
                    log_verbose "  ${node}:${vp} already in ${target_bd}"
                    continue
                elif [[ "$cur_bd" != "-" ]]; then
                    log "  Moving ${node}:${vp} from ${cur_bd} to ${target_bd}"
                    storage_ssh netapp-aff "network port broadcast-domain remove-ports -ipspace Default -broadcast-domain ${cur_bd} -ports ${node}:${vp}" 2>/dev/null || true
                fi
                if [[ "$target_bd" == "$bd_a" ]]; then
                    add_a+=("${node}:${vp}")
                else
                    add_b+=("${node}:${vp}")
                fi
            done
        done

        if (( ${#add_a[@]} > 0 )); then
            storage_ssh netapp-aff "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_a} -ports $(IFS=,; echo "${add_a[*]}")" 2>/dev/null || log_warn "  Failed to add ports to ${bd_a}"
            log_success "  Ports added to ${bd_a}"
        else
            log_success "  Path-A ports already homed in ${bd_a}"
        fi
        if (( ${#add_b[@]} > 0 )); then
            storage_ssh netapp-aff "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_b} -ports $(IFS=,; echo "${add_b[*]}")" 2>/dev/null || log_warn "  Failed to add ports to ${bd_b}"
            log_success "  Ports added to ${bd_b}"
        else
            log_success "  Path-B ports already homed in ${bd_b}"
        fi

        # Step 4: SVM
        local svm_exists
        svm_exists=$(storage_ssh netapp-aff "vserver show -vserver ${svm} -fields vserver" 2>/dev/null | grep -c "${svm}" || true)
        if [[ "$svm_exists" -gt 0 ]]; then
            log_success "  SVM ${svm} already exists"
        else
            storage_ssh netapp-aff "vserver create -vserver ${svm} -ipspace ${ipspace} -rootvolume ${svm}_root -rootvolume-security-style unix" 2>/dev/null || true
            log_success "  SVM ${svm} created"
        fi

        # Step 5: iSCSI service (check independently — may be missing even if SVM exists)
        local iscsi_check
        iscsi_check=$(storage_ssh netapp-aff "vserver iscsi show -vserver ${svm}" 2>/dev/null | grep -c "${svm}" || true)
        if [[ "$iscsi_check" -gt 0 ]]; then
            log_success "  iSCSI service already enabled on ${svm}"
        else
            storage_ssh netapp-aff "vserver iscsi create -vserver ${svm}" 2>/dev/null || log_warn "  iSCSI service creation failed"
            log "  iSCSI service enabled on ${svm}"
        fi

        # Step 6: LIFs (check each independently)
        local lif_count
        lif_count=$(storage_ssh netapp-aff "network interface show -vserver ${svm} -fields address" 2>/dev/null | grep -c "iscsi_${cloud_name}" || true)
        if [[ "$lif_count" -ge 4 ]]; then
            log_success "  All 4 LIFs already exist"
            local lif_output
            lif_output=$(storage_ssh netapp-aff "network interface show -vserver ${svm} -fields address,status-oper" 2>/dev/null) || true
            log "  LIF status:"
            echo "$lif_output" | grep -E "iscsi|${cloud_name}" | while IFS= read -r line; do
                log "    $line"
            done || true
        else
            log "  Creating LIFs (found ${lif_count}/4)..."
            storage_ssh netapp-aff "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_a -data-protocol iscsi -home-node ${node1} -home-port ${port_a}-${vlanA} -address ${subA}.2 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            storage_ssh netapp-aff "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_a -data-protocol iscsi -home-node ${node2} -home-port ${port_a}-${vlanA} -address ${subA}.3 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            storage_ssh netapp-aff "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_b -data-protocol iscsi -home-node ${node1} -home-port ${port_b}-${vlanB} -address ${subB}.2 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            storage_ssh netapp-aff "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_b -data-protocol iscsi -home-node ${node2} -home-port ${port_b}-${vlanB} -address ${subB}.3 -netmask 255.255.255.0 -status-admin up" 2>/dev/null || true
            log_success "  LIF creation commands issued"
        fi
    fi

    # --- Sub-stage B: Volumes + LUNs (standard ONTAP has both) ---
    log "  [B] Creating volume(s) and LUN(s)..."
    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name lun_name
        vol_name=$(printf "${cloud_name}_iscsi_lta_ntapaff_vol%02d" "$i")
        lun_name=$(printf "${cloud_name}_lta_ntapaff_lun%02d" "$i")

        local vol_check
        vol_check=$(storage_ssh netapp-aff "volume show -vserver ${svm} -volume ${vol_name} -fields volume" 2>/dev/null | grep -c "${vol_name}" || true)
        if [[ "$vol_check" -gt 0 ]]; then
            log_success "  Volume ${vol_name} already exists"
            # Ensure snapshot reserve is 0 for LUN volumes (may have been created with default 5%)
            if [[ "$DRY_RUN" != "true" ]]; then
                storage_ssh netapp-aff "volume modify -vserver ${svm} -volume ${vol_name} -percent-snapshot-space 0" 2>/dev/null || true
            fi
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create volume: volume create -vserver ${svm} -volume ${vol_name} -aggregate eng_data_aggr01 -size ${LUN_SIZE} -space-guarantee none -percent-snapshot-space 0"
            else
                storage_ssh netapp-aff "volume create -vserver ${svm} -volume ${vol_name} -aggregate eng_data_aggr01 -size ${LUN_SIZE} -space-guarantee none -percent-snapshot-space 0" 2>/dev/null || {
                    log_error "  Failed to create volume ${vol_name}"
                    continue
                }
                log_success "  Volume ${vol_name} created"
            fi
        fi

        local lun_check
        lun_check=$(storage_ssh netapp-aff "lun show -vserver ${svm} -volume ${vol_name} -lun ${lun_name} -fields lun" 2>/dev/null | grep -c "${lun_name}" || true)
        if [[ "$lun_check" -gt 0 ]]; then
            log_success "  LUN ${lun_name} already exists"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create LUN: lun create -vserver ${svm} -volume ${vol_name} -lun ${lun_name} -size ${LUN_SIZE} -ostype linux -space-reserve disabled"
            else
                storage_ssh netapp-aff "lun create -vserver ${svm} -volume ${vol_name} -lun ${lun_name} -size ${LUN_SIZE} -ostype linux -space-reserve disabled" 2>/dev/null || {
                    log_error "  Failed to create LUN ${lun_name}"
                    continue
                }
                log_success "  LUN ${lun_name} created (${LUN_SIZE})"
            fi
        fi
    done

    # --- Sub-stage C: igroup ---
    log "  [C] Creating igroup..."
    local ig_name="${cloud_name}_iscsi_ig"
    local ig_check
    ig_check=$(storage_ssh netapp-aff "lun igroup show -vserver ${svm} -igroup ${ig_name}" 2>/dev/null | grep -c "${ig_name}" || true)

    local iqn_list=""
    for pair in "${iqn_pairs[@]}"; do
        local iqn="${pair#*:}"
        [[ -n "$iqn_list" ]] && iqn_list+=","
        iqn_list+="$iqn"
    done

    if [[ "$ig_check" -gt 0 ]]; then
        log_success "  igroup ${ig_name} already exists"
        for pair in "${iqn_pairs[@]}"; do
            local iqn="${pair#*:}"
            local already
            already=$(storage_ssh netapp-aff "lun igroup show -vserver ${svm} -igroup ${ig_name} -fields initiator" 2>/dev/null | grep -c "$iqn" || true)
            if [[ "$already" -eq 0 && "$DRY_RUN" != "true" ]]; then
                storage_ssh netapp-aff "lun igroup add -vserver ${svm} -igroup ${ig_name} -initiator ${iqn}" 2>/dev/null || true
                log "  Added initiator ${iqn} to ${ig_name}"
            fi
        done
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create igroup ${ig_name} with initiators: ${iqn_list}"
        elif [[ -n "$iqn_list" ]]; then
            storage_ssh netapp-aff "lun igroup create -vserver ${svm} -igroup ${ig_name} -protocol iscsi -ostype linux -initiator ${iqn_list}" 2>/dev/null || {
                log_error "  Failed to create igroup ${ig_name}"
                return 1
            }
            log_success "  igroup ${ig_name} created with ${#iqn_pairs[@]} initiators"
        else
            log_warn "  No IQNs collected — skipping igroup creation"
        fi
    fi

    # --- Sub-stage D: LUN mapping ---
    log "  [D] Mapping LUN(s) to igroup..."
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name lun_name lun_path
        vol_name=$(printf "${cloud_name}_iscsi_lta_ntapaff_vol%02d" "$i")
        lun_name=$(printf "${cloud_name}_lta_ntapaff_lun%02d" "$i")
        lun_path="/vol/${vol_name}/${lun_name}"
        local lun_id=$(( i - 1 ))

        local map_check
        map_check=$(storage_ssh netapp-aff "lun mapping show -vserver ${svm} -path ${lun_path} -fields igroup" 2>/dev/null | grep -c "${ig_name}" || true)
        if [[ "$map_check" -gt 0 ]]; then
            log_success "  LUN ${lun_path} already mapped to ${ig_name}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would map: lun mapping create -vserver ${svm} -path ${lun_path} -igroup ${ig_name} -lun-id ${lun_id}"
            else
                storage_ssh netapp-aff "lun mapping create -vserver ${svm} -path ${lun_path} -igroup ${ig_name} -lun-id ${lun_id}" 2>/dev/null || {
                    log_error "  Failed to map LUN ${lun_path}"
                    continue
                }
                log_success "  LUN ${lun_path} mapped to ${ig_name} (lun-id ${lun_id})"
            fi
        fi
    done

    log_success "  NetApp AFF A300 storage-setup complete for ${cloud_name}"
}

# =============================================================================
# STORAGE-SETUP: iSCSI Discovery + Login + Validation (Sub-stage E)
# =============================================================================
storage_discovery_and_verify() {
    local cloud_name="$1"
    shift
    local -a vendors_to_discover=("$@")

    log ""
    log "--- Sub-stage E: iSCSI discovery + login + verification ---"

    # Collect portal IPs per vendor (.2 and .3 for dual-controller arrays like IBM)
    declare -A vendor_portals
    while read -r _nic vlan_id subnet_base vendor path; do
        for last_octet in 2 3; do
            local portal_ip="${subnet_base}.${last_octet}"
            if [[ -n "${vendor_portals[$vendor]:-}" ]]; then
                # Avoid duplicates (same IP from different layout entries)
                [[ " ${vendor_portals[$vendor]} " == *" ${portal_ip} "* ]] && continue
                vendor_portals[$vendor]+=" ${portal_ip}"
            else
                vendor_portals[$vendor]="$portal_ip"
            fi
        done
    done < <(compute_vlan_layout)

    # Get OCP worker list
    local -a workers=()
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        if command -v oc &>/dev/null; then
            mapfile -t workers < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi
    fi

    if (( ${#workers[@]} == 0 )); then
        log_warn "  No workers found for discovery. Skipping Sub-stage E."
        return 0
    fi

    # Run discovery on each worker for each vendor's portals
    for node in "${workers[@]}"; do
        if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
            continue
        fi

        log ""
        log "  === Discovery on ${node} ==="

        for vendor in "${vendors_to_discover[@]}"; do
            local portals="${vendor_portals[$vendor]:-}"
            if [[ -z "$portals" ]]; then
                continue
            fi

            local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
            log "    ${vendor_name} portals: ${portals}"

            for portal_ip in $portals; do
                if [[ "$DRY_RUN" == "true" ]]; then
                    log "    [DRY-RUN] Would discover: iscsiadm -m discovery -t st -p ${portal_ip}"
                    continue
                fi

                local disc_out
                disc_out=$(run_on_host "$node" "iscsiadm -m discovery -t st -p ${portal_ip} 2>&1" 2>/dev/null) || true
                if [[ -n "$disc_out" && "$disc_out" != *"error"* && "$disc_out" != *"No portals"* ]]; then
                    log_success "    Discovery on ${portal_ip}: targets found"
                    echo "$disc_out" | head -5 | while IFS= read -r line; do
                        log "      $line"
                    done
                else
                    log_warn "    Discovery on ${portal_ip}: no targets (portals may not be ready)"
                fi
            done
        done

        # Login to all discovered targets
        if [[ "$DRY_RUN" != "true" ]]; then
            log "    Logging in to all discovered targets..."
            run_on_host "$node" "iscsiadm -m node --login 2>/dev/null || true" 2>/dev/null || true
            log "    Waiting 10s for paths to settle..."
            sleep 10
        fi
    done

    # Verification: multipath
    log ""
    log "  === Multipath Verification ==="
    log ""
    printf "  %-25s %-15s %-40s %-8s %-8s\n" "Worker" "Vendor" "LUN" "Paths" "Status"
    printf "  %-25s %-15s %-40s %-8s %-8s\n" "-------------------------" "---------------" "----------------------------------------" "--------" "--------"

    for node in "${workers[@]}"; do
        if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            for vendor in "${vendors_to_discover[@]}"; do
                printf "  %-25s %-15s %-40s %-8s %-8s\n" "$node" "$vendor" "(dry-run)" "N/A" "DRY-RUN"
            done
            continue
        fi

        local mpath_out
        mpath_out=$(run_on_host "$node" "multipath -ll 2>/dev/null" 2>/dev/null) || mpath_out=""

        for vendor in "${vendors_to_discover[@]}"; do
            local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
            local vendor_pattern=""
            case "$vendor" in
                ibm)        vendor_pattern="IBM,2145" ;;
                pure)       vendor_pattern="PURE,FlashArray" ;;
                netapp-asa) vendor_pattern="NETAPP,LUN" ;;
                netapp-aff) vendor_pattern="NETAPP,LUN" ;;
            esac

            local path_count
            path_count=$(echo "$mpath_out" | grep -c "${vendor_pattern}" 2>/dev/null || true)
            local lun_count
            lun_count=$(echo "$mpath_out" | grep -cP "^[0-9a-f].*${vendor_pattern}" 2>/dev/null || true)

            local status="OK"
            if [[ "$path_count" -eq 0 ]]; then
                status="NO_PATHS"
            fi

            printf "  %-25s %-15s %-40s %-8s %-8s\n" "$node" "$vendor_name" "${lun_count} LUN(s)" "${path_count}" "$status"
        done
    done
    log ""
}

# =============================================================================
# STAGE: storage-setup (orchestrator)
# =============================================================================
do_storage_setup() {
    log "=== STAGE: storage-setup ==="

    if [[ -z "$STORAGE_ARRAYS" ]]; then
        log_error "STORAGE_ARRAYS not set. Cannot configure storage."
        return 1
    fi

    # Pre-populate bws credential cache so $() subshells inherit it
    if [[ "$DRY_RUN" != "true" ]]; then
        bws_load_cache || return 1
        log "Credential cache loaded (${#_BWS_CACHE} bytes, storage credentials only)"
    fi

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local cloud_nn=$(printf '%02d' "$CLOUD_ID")

    log "Volume/LUN configuration: size=${LUN_SIZE}, count=${LUN_COUNT}"
    log ""

    # Collect IQNs from workers
    log "Collecting iSCSI initiator IQNs from workers..."
    local -a iqn_pairs=()
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would collect IQNs from workers via oc debug"
        iqn_pairs=("worker-dry-run:iqn.2026-01.com.example:dry-run")
    else
        mapfile -t iqn_pairs < <(collect_worker_iqns)
    fi
    log "Collected ${#iqn_pairs[@]} IQN(s)"
    log ""

    local -a vendors_arr
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"

    # Run per-vendor storage setup
    for vendor in "${vendors_arr[@]}"; do
        case "$vendor" in
            netapp-asa)  storage_setup_netapp_asa  "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" ;;
            pure)        storage_setup_pure         "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" ;;
            ibm)         storage_setup_ibm          "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" ;;
            netapp-aff) storage_setup_netapp_aff  "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" ;;
            *)           log_warn "Unknown vendor '${vendor}' — skipping storage-setup" ;;
        esac
    done

    # Sub-stage E: Discovery + verification
    storage_discovery_and_verify "$cloud_name" "${vendors_arr[@]}"

    log ""
    log_success "=== storage-setup complete ==="
}

# =============================================================================
# STAGE: check
# =============================================================================
do_check() {
    log "=== STAGE: check ==="

    if [[ -z "$STORAGE_ARRAYS" ]]; then
        log_error "STORAGE_ARRAYS not set. Cannot determine portal IPs to check."
        return 1
    fi

    local json
    json=$(quads_query_hosts) || return 1

    # Build list of portal IPs to check (first portal IP per path: .2)
    local -a portal_ips=()
    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        echo "${subnet_base}.2"
    done | sort -u > /tmp/_portal_ips_$$
    mapfile -t portal_ips < /tmp/_portal_ips_$$
    rm -f /tmp/_portal_ips_$$

    log "Portal IPs to check: ${portal_ips[*]}"

    # For OCP, iterate over actual OCP worker node names
    # For bare-metal, iterate over QUADS hosts
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        local -a check_nodes=()
        if command -v oc &>/dev/null; then
            mapfile -t check_nodes < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi

        # Determine model for interface name resolution (use first model from QUADS)
        local check_model
        check_model=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    m = h.get('model', 'UNKNOWN')
    if m != 'UNKNOWN':
        print(m)
        break
" 2>/dev/null) || check_model="UNKNOWN"

        for node in "${check_nodes[@]}"; do
            if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi
            log "  Checking OCP node: ${node}..."

            for portal_ip in "${portal_ips[@]}"; do
                local result
                result=$(run_on_host "$node" "ping -c 2 -W 3 ${portal_ip} &>/dev/null && echo PASS || echo FAIL" 2>/dev/null) || result="UNREACHABLE"

                if [[ "$DRY_RUN" == "true" ]]; then
                    log "    [DRY-RUN] Would ping ${portal_ip}"
                elif [[ "$result" == "PASS" ]]; then
                    log_success "    ${portal_ip}: reachable"
                else
                    log_warn "    ${portal_ip}: ${result} (may not be configured on storage side yet)"
                fi
            done

            if [[ "$DRY_RUN" != "true" ]]; then
                log "  VLAN interface status:"
                compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
                    local os_nic
                    os_nic=$(resolve_os_iface "$check_model" "$bios_nic")
                    local iface_name="${os_nic}.${vlan_id}"
                    local ip
                    ip=$(run_on_host "$node" "ip -4 addr show ${iface_name} 2>/dev/null | grep -oP 'inet \K[0-9.]+'" 2>/dev/null) || ip="no-ip"
                    if [[ "$ip" != "no-ip" && -n "$ip" ]]; then
                        log_success "    ${iface_name}: ${ip}"
                    else
                        log_warn "    ${iface_name}: no IPv4 address (DHCP may not be serving this VLAN yet)"
                    fi
                done
            fi
        done
    else
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && continue
            fi

            if [[ -n "$SINGLE_WORKER" && "$hostname" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi

            local worker_id
            worker_id=$(get_worker_id "$hostname")
            log "  Checking ${hostname} (${worker_id})..."

            for portal_ip in "${portal_ips[@]}"; do
                local result
                result=$(run_on_host "$worker_id" "ping -c 2 -W 3 ${portal_ip} &>/dev/null && echo PASS || echo FAIL" 2>/dev/null) || result="UNREACHABLE"

                if [[ "$DRY_RUN" == "true" ]]; then
                    log "    [DRY-RUN] Would ping ${portal_ip}"
                elif [[ "$result" == "PASS" ]]; then
                    log_success "    ${portal_ip}: reachable"
                else
                    log_warn "    ${portal_ip}: ${result} (may not be configured on storage side yet)"
                fi
            done

            if [[ "$DRY_RUN" != "true" ]]; then
                log "  VLAN interface status:"
                compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
                    local os_nic
                    os_nic=$(resolve_os_iface "$model" "$bios_nic")
                    local iface_name="vlan${vlan_id}"
                    local ip
                    ip=$(run_on_host "$worker_id" "ip -4 addr show ${iface_name} 2>/dev/null | grep -oP 'inet \K[0-9.]+'" 2>/dev/null) || ip="no-ip"
                    if [[ "$ip" != "no-ip" && -n "$ip" ]]; then
                        log_success "    ${iface_name}: ${ip}"
                    else
                        log_warn "    ${iface_name}: no IPv4 address (DHCP may not be serving this VLAN yet)"
                    fi
                done
            fi
        done
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    local stage=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e) ENV_FILE="$2"; shift 2 ;;
            -n) DRY_RUN=true; shift ;;
            -v) VERBOSE=true; shift ;;
            -w) SINGLE_WORKER="$2"; shift 2 ;;
            -h|--help) usage ;;
            collect|verify|jira-draft|host-setup|storage-setup|check|all)
                stage="$1"; shift ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                ;;
        esac
    done

    if [[ -z "$ENV_FILE" ]]; then
        echo "Error: -e <env-file> is required." >&2
        usage
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Error: env file not found: ${ENV_FILE}" >&2
        exit 1
    fi

    if [[ -z "$stage" ]]; then
        echo "Error: no stage specified." >&2
        usage
    fi

    # Source the env file
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    # Validate required vars
    if [[ -z "$CLOUD_ID" ]]; then
        echo "Error: CLOUD_ID not set in ${ENV_FILE}" >&2
        exit 1
    fi

    CLOUD_ID=$((10#${CLOUD_ID}))
    if (( CLOUD_ID < 1 || CLOUD_ID > 99 )); then
        echo "Error: CLOUD_ID must be 1-99 (got ${CLOUD_ID})" >&2
        exit 1
    fi

    # Auto-set SSH_USER from TARGET_TYPE if not explicitly set
    if [[ -z "$SSH_USER" ]]; then
        case "$TARGET_TYPE" in
            ocp)     SSH_USER="core" ;;
            vmware)  SSH_USER="root" ;;
            *)       SSH_USER="root" ;;
        esac
    fi

    # Setup logging
    mkdir -p "$LOG_DIR" "$RESULTS_DIR" 2>/dev/null || true
    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    LOG_FILE="${LOG_DIR}/${cloud_name}-$(date '+%Y%m%d_%H%M%S').log"

    log "============================================================================="
    log "  Storage LTA Setup — ${cloud_name} — $(date)"
    log "============================================================================="
    log "  Env file:       ${ENV_FILE}"
    log "  Cloud ID:       ${CLOUD_ID}"
    log "  Storage arrays: ${STORAGE_ARRAYS:-<not set>}"
    log "  Networks:       ${NETWORKS}"
    log "  Target type:    ${TARGET_TYPE}"
    log "  SSH user:       ${SSH_USER}"
    [[ "$DRY_RUN" == "true" ]] && log "  *** DRY-RUN MODE ***"
    log ""

    case "$stage" in
        collect)       do_collect ;;
        verify)        do_verify ;;
        jira-draft)    do_jira_draft ;;
        host-setup)    do_host_setup ;;
        storage-setup) do_storage_setup ;;
        check)         do_check ;;
        all)
            do_collect
            do_verify
            do_jira_draft
            log ""
            log "===================================================================="
            log "  Stages collect, verify, jira-draft complete."
            log "  Review the Jira draft at: ${RESULTS_DIR}/${cloud_name}-jira-draft.txt"
            log "  After the VLAN change is applied by ScaleLab ops, run:"
            log "    ${PROG} -e ${ENV_FILE} host-setup"
            log "    ${PROG} -e ${ENV_FILE} check"
            log "===================================================================="
            ;;
    esac

    log ""
    log "Log saved to: ${LOG_FILE}"
}

main "$@"
