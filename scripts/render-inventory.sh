#!/usr/bin/env bash
# Render ansible/inventory from Terraform outputs.
# Usage: scripts/render-inventory.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
ANSIBLE_DIR="${ROOT_DIR}/ansible"
TEMPLATE="${ANSIBLE_DIR}/inventory.tmpl"
OUTPUT="${ANSIBLE_DIR}/inventory"

cd "${TF_DIR}"

# Pull node maps as JSON from Terraform outputs.
server_json="$(terraform output -json server_node)"
agent_json="$(terraform output -json agent_nodes)"

# Build indented "name:\n  ansible_host: ip" blocks.
to_hosts() {
  echo "$1" | jq -r 'to_entries[] | "      \(.key):\n        ansible_host: \(.value)"'
}

server_hosts="$(to_hosts "${server_json}")"
agent_hosts="$(to_hosts "${agent_json}")"

export server_hosts agent_hosts
# Substitute into the template (preserving multiline blocks).
awk -v s="${server_hosts}" -v a="${agent_hosts}" '
  { gsub(/\$\{server_hosts\}/, s); gsub(/\$\{agent_hosts\}/, a); print }
' "${TEMPLATE}" > "${OUTPUT}"

echo "Wrote ${OUTPUT}"
