#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Interactive setup for the k3s-on-vSphere lab.
#
# Collects vCenter connection details, placement, cluster shape and SSH access,
# then writes terraform/terraform.tfvars and sets the Azure Migrate dependency
# agent toggle in ansible/group_vars/all.yml.
#
# Usage:   scripts/setup.sh
#          make setup
#
# Re-runnable: prompts show current/previous values as defaults.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
TFVARS="${TF_DIR}/terraform.tfvars"
GROUP_VARS="${ROOT_DIR}/ansible/group_vars/all.yml"

# --- Optional quick (non-interactive) mode ---
# QUICK=1 (or --quick / -q) reuses the previously saved terraform.tfvars
# without asking anything. Without it, setup is interactive and shows the
# saved values as editable defaults.
QUICK="${QUICK:-}"
for _arg in "$@"; do
  case "${_arg}" in
    --quick|-q) QUICK=1 ;;
  esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Read an existing value from terraform.tfvars (so re-runs keep prior answers).
prev() {
  local key="$1"
  [[ -f "${TFVARS}" ]] || return 0
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS}" 2>/dev/null \
    | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//; s/^"(.*)"$/\1/' || true
}

# prev_or KEY DEFAULT -> previous tfvars value if present, else DEFAULT.
prev_or() {
  local v
  v="$(prev "$1")"
  [[ -n "${v}" ]] && printf '%s' "${v}" || printf '%s' "$2"
}

# ask VAR_NAME "Prompt text" "default"
ask() {
  local __var="$1" prompt="$2" default="${3:-}" input
  if [[ -n "${default}" ]]; then
    read -r -p "$(printf '%s [%s]: ' "${prompt}" "${default}")" input
    input="${input:-${default}}"
  else
    read -r -p "$(printf '%s: ' "${prompt}")" input
    while [[ -z "${input}" ]]; do
      read -r -p "$(printf '  (required) %s: ' "${prompt}")" input
    done
  fi
  printf -v "${__var}" '%s' "${input}"
}

# ask_secret VAR_NAME "Prompt text" (no echo)
ask_secret() {
  local __var="$1" prompt="$2" input
  read -r -s -p "$(printf '%s: ' "${prompt}")" input
  echo
  while [[ -z "${input}" ]]; do
    read -r -s -p "$(printf '  (required) %s: ' "${prompt}")" input
    echo
  done
  printf -v "${__var}" '%s' "${input}"
}

# ask_yesno VAR_NAME "Prompt text" "default(y/n)"
ask_yesno() {
  local __var="$1" prompt="$2" default="${3:-n}" input
  read -r -p "$(printf '%s (y/n) [%s]: ' "${prompt}" "${default}")" input
  input="${input:-${default}}"
  case "${input,,}" in
    y|yes) printf -v "${__var}" 'true'  ;;
    *)     printf -v "${__var}" 'false' ;;
  esac
}

bold "=== k3s-on-vSphere lab :: interactive setup ==="

# --- Quick mode: reuse saved values, no prompts ---
if [[ -n "${QUICK}" ]]; then
  if [[ ! -f "${TFVARS}" ]]; then
    red "Quick mode needs a saved configuration, but none was found at:"
    red "  ${TFVARS}"
    red "Run 'make setup' once (without --quick) to create it."
    exit 1
  fi
  green "Quick mode: reusing saved values from ${TFVARS} (no prompts)."
  echo
  bold "--- Saved configuration ---"
  grep -E '^(vsphere_server|vsphere_user|allow_unverified_ssl|datacenter|cluster|resource_pool|datastore|network|vm_folder|template_name|cluster_name|agent_count)[[:space:]]*=' "${TFVARS}" | sed 's/^/  /'
  echo "  vsphere_password : (prompted at apply time; never stored)"
  echo
  green "Setup complete (quick)."
  if [[ -z "${SETUP_SKIP_RUN:-}" ]]; then
    ask_yesno RUN_NOW "Provision now with these values?" "n"
    if [[ "${RUN_NOW}" == "true" ]]; then
      ( cd "${ROOT_DIR}" && make provision configure )
    fi
  fi
  exit 0
fi

echo "Press Enter to accept the [default] shown in brackets."
echo

# --- Tooling sanity check (warn only) ---
missing=()
for t in terraform ansible-playbook jq ssh; do
  command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
done
if (( ${#missing[@]} )); then
  yellow "Warning: missing tools on this controller: ${missing[*]}"
  yellow "Run 'make install-prereqs' (or scripts/install-prereqs.sh) first."
  ask_yesno CONTINUE_ANYWAY "Continue collecting inputs anyway?" "y"
  [[ "${CONTINUE_ANYWAY}" == "true" ]] || { red "Aborting."; exit 1; }
  echo
fi

# --- vCenter connection ---
bold "--- vCenter connection ---"
ask        VSPHERE_SERVER   "vCenter server FQDN or IP"        "$(prev vsphere_server)"
ask        VSPHERE_USER     "vCenter username"                 "$(prev_or vsphere_user administrator@vsphere.local)"
ask_yesno  ALLOW_SSL        "Allow self-signed vCenter certs?" "y"
echo
yellow "Note: the vCenter password is NOT collected or stored here."
yellow "You will be prompted for it each time you run 'make up' / 'make down'."
echo

# --- vSphere placement ---
bold "--- vSphere placement ---"
ask DATACENTER    "Datacenter name"                          "$(prev datacenter)"
ask CLUSTER       "Compute cluster name"                     "$(prev cluster)"
# Default the resource pool to <cluster>/Resources. If the previously stored
# pool was just the old cluster's default, follow the (now possibly changed)
# cluster name instead of keeping a stale value.
_prev_pool="$(prev resource_pool)"
_prev_cluster="$(prev cluster)"
if [[ -z "${_prev_pool}" || "${_prev_pool}" == "${_prev_cluster}/Resources" ]]; then
  _default_pool="${CLUSTER}/Resources"
else
  _default_pool="${_prev_pool}"
fi
ask RESOURCE_POOL "Resource pool (e.g. <cluster>/Resources)" "${_default_pool}"
ask DATASTORE     "Datastore name"                           "$(prev datastore)"
ask NETWORK       "Network / port group name"                "$(prev_or network "VM Network")"
ask VM_FOLDER     "VM folder (blank = datacenter root)"      "$(prev vm_folder)"
ask TEMPLATE_NAME "Ubuntu 24.04 template name"               "$(prev_or template_name ubuntu-24.04-template)"
echo

# --- Cluster shape ---
bold "--- Cluster shape ---"
ask CLUSTER_NAME "Node name prefix"           "$(prev_or cluster_name k3s-lab)"
ask AGENT_COUNT  "Number of agent (worker) nodes" "$(prev_or agent_count 2)"
echo

# --- Node IP allocation ---
bold "--- Node IP allocation ---"
echo "Static is recommended unless the port group has working DHCP."
_prev_alloc="$(prev ip_allocation)"
_default_static="y"; [[ "${_prev_alloc}" == "dhcp" ]] && _default_static="n"
ask_yesno USE_STATIC "Assign static IPs to the nodes? (n = use DHCP)" "${_default_static}"
# Sensible defaults so the values are always written (ignored in DHCP mode).
IP_ALLOCATION="dhcp"
NODE_SUBNET_CIDR=""
NODE_IP_START="20"
NODE_GATEWAY=""
NODE_DNS_CSV="1.1.1.1,8.8.8.8"
if [[ "${USE_STATIC}" == "true" ]]; then
  IP_ALLOCATION="static"
  ask NODE_SUBNET_CIDR "Subnet CIDR (e.g. 10.35.1.0/24)"                 "$(prev node_subnet_cidr)"
  ask NODE_IP_START    "Server host number in the subnet, agents continue from it (e.g. 31 -> server .31, agent-1 .32, agent-2 .33)" "$(prev_or node_ip_start 20)"
  ask NODE_GATEWAY     "Gateway IP (blank = first host of the subnet)"   "$(prev node_gateway)"
  _prev_dns_csv="$(prev node_dns | tr -d '[]" ')"
  ask NODE_DNS_CSV     "DNS servers (comma-separated)"                   "${_prev_dns_csv:-1.1.1.1,8.8.8.8}"
fi
# Build an HCL list literal from the comma-separated DNS entries.
NODE_DNS_HCL="$(printf '%s' "${NODE_DNS_CSV}" | awk -F, '{o="";for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i!=""){o=o (o==""?"":", ") "\"" $i "\""}} print o}')"
echo

# --- SSH access ---
bold "--- SSH access ---"
default_pub=""
for k in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub"; do
  [[ -f "${k}" ]] && { default_pub="$(<"${k}")"; break; }
done
if [[ -n "${default_pub}" ]]; then
  green "Found existing public key on this controller."
  ask_yesno USE_FOUND "Use it for the cluster nodes?" "y"
  if [[ "${USE_FOUND}" == "true" ]]; then
    SSH_PUBLIC_KEY="${default_pub}"
  fi
fi
if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
  ask_yesno GEN_KEY "No key chosen. Generate a new ed25519 keypair now?" "y"
  if [[ "${GEN_KEY}" == "true" ]]; then
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" <<< y >/dev/null 2>&1 || true
    SSH_PUBLIC_KEY="$(<"${HOME}/.ssh/id_ed25519.pub")"
    green "Generated ${HOME}/.ssh/id_ed25519(.pub)."
  else
    ask SSH_PUBLIC_KEY "Paste your SSH public key" ""
  fi
fi
echo

# --- Azure Migrate dependency agent ---
bold "--- Azure Migrate dependency mapping ---"
echo "The appliance already does agentless discovery. Install the in-guest"
echo "Dependency Agent only if you want agent-based dependency mapping."
ask_yesno INSTALL_DEP_AGENT "Install the dependency agent on the nodes?" "n"
echo

# --- Summary ---
bold "--- Review ---"
cat <<SUMMARY
  vCenter server : ${VSPHERE_SERVER}
  vCenter user   : ${VSPHERE_USER}
  vCenter pass   : (prompted at apply time; never stored)
  allow self-SSL : ${ALLOW_SSL}
  datacenter     : ${DATACENTER}
  cluster        : ${CLUSTER}
  resource pool  : ${RESOURCE_POOL}
  datastore      : ${DATASTORE}
  network        : ${NETWORK}
  vm folder      : ${VM_FOLDER:-<root>}
  template       : ${TEMPLATE_NAME}
  node prefix    : ${CLUSTER_NAME}
  agent count    : ${AGENT_COUNT}
  ip allocation  : ${IP_ALLOCATION}$( [[ "${IP_ALLOCATION}" == "static" ]] && printf ' (%s from host .%s, gw %s, dns %s)' "${NODE_SUBNET_CIDR}" "${NODE_IP_START}" "${NODE_GATEWAY:-<auto .1>}" "${NODE_DNS_CSV}" )
  dep. agent     : ${INSTALL_DEP_AGENT}
SUMMARY
ask_yesno CONFIRM "Write this configuration?" "y"
[[ "${CONFIRM}" == "true" ]] || { red "Aborted; nothing written."; exit 1; }

# --- Write terraform.tfvars ---
umask 077
cat > "${TFVARS}" <<EOF
# Generated by scripts/setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# This file is gitignored. Do not commit it.

# --- vCenter connection ---
# vsphere_password is intentionally NOT stored here. It is supplied at
# terraform runtime via TF_VAR_vsphere_password (you are prompted by make up).
vsphere_server       = "${VSPHERE_SERVER}"
vsphere_user         = "${VSPHERE_USER}"
allow_unverified_ssl = ${ALLOW_SSL}

# --- vSphere placement ---
datacenter    = "${DATACENTER}"
cluster       = "${CLUSTER}"
resource_pool = "${RESOURCE_POOL}"
datastore     = "${DATASTORE}"
network       = "${NETWORK}"
vm_folder     = "${VM_FOLDER}"
template_name = "${TEMPLATE_NAME}"

# --- Cluster shape ---
cluster_name = "${CLUSTER_NAME}"
agent_count  = ${AGENT_COUNT}

# --- Node IP allocation ---
# ip_allocation = "dhcp" or "static". The node_* values below are only used
# when ip_allocation = "static".
ip_allocation    = "${IP_ALLOCATION}"
node_subnet_cidr = "${NODE_SUBNET_CIDR}"
node_ip_start    = ${NODE_IP_START}
node_gateway     = "${NODE_GATEWAY}"
node_dns         = [${NODE_DNS_HCL}]

# --- Guest SSH access ---
ssh_public_key = "${SSH_PUBLIC_KEY}"
EOF
green "Wrote ${TFVARS}"

# --- Update dependency agent toggle ---
if [[ -f "${GROUP_VARS}" ]]; then
  if grep -qE '^install_dependency_agent:' "${GROUP_VARS}"; then
    sed -i -E "s/^install_dependency_agent:.*/install_dependency_agent: ${INSTALL_DEP_AGENT}/" "${GROUP_VARS}"
  else
    printf '\ninstall_dependency_agent: %s\n' "${INSTALL_DEP_AGENT}" >> "${GROUP_VARS}"
  fi
  green "Set install_dependency_agent: ${INSTALL_DEP_AGENT} in ${GROUP_VARS}"
fi

echo
green "Setup complete."
echo "Next steps:"
echo "  make validate   # check the Terraform config"
echo "  make up         # provision VMs, build k3s, deploy the app"
echo
if [[ -z "${SETUP_SKIP_RUN:-}" ]]; then
  ask_yesno RUN_NOW "Provision now with these values?" "n"
  if [[ "${RUN_NOW}" == "true" ]]; then
    ( cd "${ROOT_DIR}" && make provision configure )
  fi
fi
