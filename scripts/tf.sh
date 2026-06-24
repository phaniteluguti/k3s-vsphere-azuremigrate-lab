#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Terraform wrapper that supplies the vCenter password at runtime.
#
# The password is NEVER stored on disk. Terraform reads it from the
# TF_VAR_vsphere_password environment variable (the vsphere provider needs it).
# If that variable is not already set, you are prompted for it (input hidden),
# and it lives only in this process's environment for the single command.
#
# Usage:   scripts/tf.sh apply -auto-approve
#          scripts/tf.sh destroy -auto-approve
#          TF_VAR_vsphere_password=... scripts/tf.sh apply   # non-interactive
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

if [[ -z "${TF_VAR_vsphere_password:-}" ]]; then
  read -r -s -p "vCenter password (input hidden): " TF_VAR_vsphere_password
  echo
  if [[ -z "${TF_VAR_vsphere_password}" ]]; then
    printf '\033[31m%s\033[0m\n' "No password entered; aborting." >&2
    exit 1
  fi
  export TF_VAR_vsphere_password
fi

cd "${TF_DIR}"
exec terraform "$@"
