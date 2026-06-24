#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install / upgrade controller prerequisites for the k3s-on-vSphere lab.
#
# Controller = the Linux/WSL machine you run `make` from. Ensures:
#   terraform, ansible, jq, git, openssh-client, make
#   + ansible collections: community.general, ansible.posix
#
# Idempotent: checks what is already installed and only installs/upgrades
# what is missing or below the required minimum version.
#
# Supported: Debian/Ubuntu (apt). Other distros: see README for manual steps.
#
# Usage:   scripts/install-prereqs.sh
#          make install-prereqs
# ---------------------------------------------------------------------------
set -euo pipefail

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Minimum versions required by this lab.
TERRAFORM_MIN="1.5.0"
ANSIBLE_MIN="2.15.0"

# Return 0 if $1 (have) >= $2 (need) using version sort.
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { red "Run as root or install sudo."; exit 1; }
fi

if ! command -v apt-get >/dev/null 2>&1; then
  red "This installer supports Debian/Ubuntu (apt) only."
  red "For RHEL/macOS, follow the manual steps in README.md > Prerequisites."
  exit 1
fi

APT_UPDATED=0
apt_update_once() {
  if [[ "${APT_UPDATED}" -eq 0 ]]; then
    ${SUDO} apt-get update -y
    APT_UPDATED=1
  fi
}

# Fallback Ansible install via pip (used when the PPA/apt path is unavailable,
# e.g. keyserver blocked or non-Ubuntu). Installs into the user's ~/.local.
install_ansible_via_pip() {
  yellow "    Falling back to a pip user install for Ansible"
  apt_update_once
  ${SUDO} apt-get install -y python3-pip
  python3 -m pip install --user --upgrade ansible
  if ! command -v ansible >/dev/null 2>&1; then
    yellow "    Installed to ~/.local/bin — add it to PATH (restart your shell):"
    yellow '      export PATH="$HOME/.local/bin:$PATH"'
  fi
}

# ---------------------------------------------------------------------------
# Base CLI tools — install only the ones that are missing.
# ---------------------------------------------------------------------------
declare -A BASE_PKGS=(
  [git]=git
  [jq]=jq
  [make]=make
  [ssh]=openssh-client
  [curl]=curl
  [gpg]=gnupg
  [lsb_release]=lsb-release
)
MISSING_PKGS=()
for cmd in "${!BASE_PKGS[@]}"; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    green "==> ${cmd} already present — skipping"
  else
    MISSING_PKGS+=("${BASE_PKGS[$cmd]}")
  fi
done
# add-apt-repository helper is needed for the Ansible PPA step.
command -v add-apt-repository >/dev/null 2>&1 || MISSING_PKGS+=(software-properties-common)
command -v update-ca-certificates >/dev/null 2>&1 || MISSING_PKGS+=(ca-certificates)

if [[ "${#MISSING_PKGS[@]}" -gt 0 ]]; then
  # de-duplicate
  readarray -t MISSING_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)
  yellow "==> Installing missing base packages: ${MISSING_PKGS[*]}"
  apt_update_once
  ${SUDO} apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
else
  green "==> All base CLI tools present"
fi

# ---------------------------------------------------------------------------
# Terraform — install/upgrade only if missing or below minimum.
# ---------------------------------------------------------------------------
TF_HAVE=""
command -v terraform >/dev/null 2>&1 && \
  TF_HAVE="$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || true)"
[[ -z "${TF_HAVE}" ]] && command -v terraform >/dev/null 2>&1 && \
  TF_HAVE="$(terraform version | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"

if [[ -n "${TF_HAVE}" ]] && version_ge "${TF_HAVE}" "${TERRAFORM_MIN}"; then
  green "==> Terraform ${TF_HAVE} already satisfies >= ${TERRAFORM_MIN} — skipping"
else
  if [[ -n "${TF_HAVE}" ]]; then
    yellow "==> Terraform ${TF_HAVE} is below ${TERRAFORM_MIN} — upgrading"
  else
    yellow "==> Terraform not found — installing"
  fi
  if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
    green "    Configuring HashiCorp apt repo"
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
      | ${SUDO} gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    ${SUDO} chmod 0644 /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | ${SUDO} tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    APT_UPDATED=0
  fi
  apt_update_once
  ${SUDO} apt-get install -y terraform
fi

# ---------------------------------------------------------------------------
# Ansible — install/upgrade only if missing or below minimum.
# ---------------------------------------------------------------------------
ANS_HAVE=""
command -v ansible >/dev/null 2>&1 && \
  ANS_HAVE="$(ansible --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"

if [[ -n "${ANS_HAVE}" ]] && version_ge "${ANS_HAVE}" "${ANSIBLE_MIN}"; then
  green "==> Ansible ${ANS_HAVE} already satisfies >= ${ANSIBLE_MIN} — skipping"
else
  if [[ -n "${ANS_HAVE}" ]]; then
    yellow "==> Ansible ${ANS_HAVE} is below ${ANSIBLE_MIN} — upgrading"
  else
    yellow "==> Ansible not found — installing"
  fi
  if lsb_release -is | grep -qi ubuntu; then
    # Add the Ansible PPA WITHOUT add-apt-repository: its default key fetch uses
    # the legacy hkp keyserver protocol, which often times out behind firewalls.
    # Fetch the signing key over HTTPS (443) instead, then add the repo manually.
    green "    Adding Ansible PPA (HTTPS key fetch)"
    ANSIBLE_PPA_KEY="6125E2A8C77F2818FB7BD15B93C4A3FD7BB9C367"
    ANSIBLE_KEYRING="/usr/share/keyrings/ansible-archive-keyring.gpg"
    if curl -fsSL --retry 3 --max-time 30 \
         "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${ANSIBLE_PPA_KEY}" \
         | ${SUDO} gpg --dearmor -o "${ANSIBLE_KEYRING}" 2>/dev/null \
       && [[ -s "${ANSIBLE_KEYRING}" ]]; then
      ${SUDO} chmod 0644 "${ANSIBLE_KEYRING}"
      echo "deb [signed-by=${ANSIBLE_KEYRING}] \
https://ppa.launchpadcontent.net/ansible/ansible/ubuntu $(lsb_release -cs) main" \
        | ${SUDO} tee /etc/apt/sources.list.d/ansible.list >/dev/null
      ${SUDO} apt-get update -y
      ${SUDO} apt-get install -y ansible || install_ansible_via_pip
    else
      yellow "    Could not fetch the Ansible PPA key (network/firewall)."
      install_ansible_via_pip
    fi
  else
    install_ansible_via_pip
  fi
fi

# ---------------------------------------------------------------------------
# Required Ansible collections — install only if not already present.
# ---------------------------------------------------------------------------
ensure_collection() {
  local coll="$1"
  if ansible-galaxy collection list 2>/dev/null | grep -q "^${coll} "; then
    green "==> Ansible collection ${coll} already present — skipping"
  else
    yellow "==> Installing Ansible collection ${coll}"
    ansible-galaxy collection install "${coll}"
  fi
}
ensure_collection community.general
ensure_collection ansible.posix

# ---------------------------------------------------------------------------
green ""
green "==> Versions in use:"
terraform version | head -n1
ansible --version | head -n1
jq --version
git --version
echo
green "Prerequisites ready. Next: run 'make setup' to configure your environment."
