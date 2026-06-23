#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install / upgrade controller prerequisites for the k3s-on-vSphere lab.
#
# Controller = the Linux/WSL machine you run `make` from. Installs:
#   terraform, ansible, jq, git, openssh-client, make
#
# Supported: Debian/Ubuntu (apt). Other distros: see README for manual steps.
# Re-runnable: upgrades existing packages to the latest available.
#
# Usage:   scripts/install-prereqs.sh
#          make install-prereqs
# ---------------------------------------------------------------------------
set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo" || { red "Run as root or install sudo."; exit 1; }
fi

if ! command -v apt-get >/dev/null 2>&1; then
  red "This installer supports Debian/Ubuntu (apt) only."
  red "For RHEL/macOS, follow the manual steps in README.md > Prerequisites."
  exit 1
fi

green "==> Updating apt and installing base packages"
${SUDO} apt-get update -y
${SUDO} apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release software-properties-common \
  git jq openssh-client make

# --- Terraform (official HashiCorp apt repo) ---
green "==> Configuring HashiCorp apt repo for Terraform"
install -d -m 0755 /tmp/hashicorp
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | ${SUDO} gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
${SUDO} chmod 0644 /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | ${SUDO} tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
${SUDO} apt-get update -y
green "==> Installing/upgrading Terraform"
${SUDO} apt-get install -y terraform

# --- Ansible (official PPA on Ubuntu; pipx fallback elsewhere) ---
if lsb_release -is | grep -qi ubuntu; then
  green "==> Adding Ansible PPA"
  ${SUDO} add-apt-repository -y --update ppa:ansible/ansible
  green "==> Installing/upgrading Ansible"
  ${SUDO} apt-get install -y ansible
else
  green "==> Installing Ansible via pipx (non-Ubuntu Debian)"
  ${SUDO} apt-get install -y pipx
  pipx ensurepath
  pipx install --force ansible || pipx upgrade ansible
fi

# --- Required Ansible collections ---
green "==> Installing Ansible collections (community.general, ansible.posix)"
ansible-galaxy collection install community.general ansible.posix

green ""
green "==> Versions installed:"
terraform version | head -n1
ansible --version | head -n1
jq --version
git --version
echo
green "Prerequisites ready. Next: run 'make setup' to configure your environment."
