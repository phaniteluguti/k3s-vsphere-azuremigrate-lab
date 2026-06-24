# k3s-on-vSphere Lab for Azure Migrate

A repeatable on-premises lab that stands up a **3-node k3s Kubernetes cluster** on
**VMware vSphere/vCenter** and deploys a multi-tier sample app. The cluster nodes
are ordinary Ubuntu VMs, so they become a realistic **VM-level discovery and
migration source** for an existing **Azure Migrate** appliance.

Every run produces a clean, identical environment:

```
make rebuild   # destroy -> apply -> configure -> deploy
```

> **Scope:** This repo is *scaffolding only*. It does not provision anything until
> **you** run `make up`. No vCenter is contacted during checkout.

---

## Architecture

```
vCenter (on-prem)
└── k3s cluster (cloned from your Ubuntu 24.04 template)
    ├── k3s-lab-server     (control-plane)  4 vCPU / 8 GB
    ├── k3s-lab-agent-1    (worker)         4 vCPU / 8 GB
    └── k3s-lab-agent-2    (worker)         4 vCPU / 8 GB
        └── sample "voting app": vote -> redis -> worker -> db -> result

Azure Migrate appliance (already deployed) -> discovers the 3 node VMs
```

The **voting app** (Docker's classic example) creates clear inter-service network
flows (`vote → redis → worker → db → result`), which makes Azure Migrate
**dependency mapping** meaningful.

---

## Repository layout

```
containers/
├── Makefile                      # up / down / rebuild entrypoints
├── terraform/                    # provisions the 3 VMs from your template
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── cloud-init.yaml.tpl
│   └── terraform.tfvars.example  # copy -> terraform.tfvars and fill in
├── ansible/                      # builds the cluster + deploys the app
│   ├── ansible.cfg
│   ├── site.yml
│   ├── inventory.tmpl            # rendered -> ansible/inventory (gitignored)
│   ├── group_vars/all.yml        # install_dependency_agent toggle lives here
│   └── roles/{common,k3s_server,k3s_agent,sample_app,dependency_agent}
├── apps/voting-app/              # Kubernetes manifests for the sample app
└── scripts/
    ├── install-prereqs.sh        # install/upgrade controller tooling
    ├── setup.sh                  # interactive input collection -> tfvars
    ├── tf.sh                     # terraform wrapper; prompts for vCenter pw
    └── render-inventory.sh       # terraform outputs -> ansible inventory
```

---

## Quick start (TL;DR)

Run these three commands on your **controller** (a Linux/WSL machine):

```bash
make install-prereqs   # install terraform, ansible, jq, git (Debian/Ubuntu)
make setup             # interactive prompts -> writes terraform.tfvars
make up                # provision VMs, build k3s, deploy the voting app
```

The rest of this section explains each step and the manual alternatives.

---

## The controller

The **controller** is the machine you run `make` from. It must be
**Linux, macOS, or Windows + WSL** because the helper scripts and Ansible
control steps use bash. On Windows, open an **Ubuntu WSL** shell and clone the
repo there (or use a Linux jump host).

The controller needs these tools:

| Tool       | Purpose                                  | Min version |
|------------|------------------------------------------|-------------|
| Terraform  | provision VMs (vsphere provider)         | 1.5+        |
| Ansible    | configure cluster + deploy app           | 2.15+       |
| jq         | parse Terraform outputs for the inventory| any         |
| git        | clone / version control                  | any         |
| ssh        | Ansible transport to the nodes           | any         |
| make       | run the lifecycle targets                | any         |

### Install the prerequisites

You have two options — use the **script** (recommended), or run the **manual
steps** for your OS. Both do the same thing; pick one.

#### Option A — automated script (Debian/Ubuntu/WSL)

```bash
make install-prereqs        # or: scripts/install-prereqs.sh
```

`scripts/install-prereqs.sh` is **idempotent** — it checks what is already
present and only installs what is missing or below the minimum version:

- installs missing base tools (`git`, `jq`, `make`, `openssh-client`, `curl`,
  `gnupg`, `lsb-release`),
- installs/upgrades **Terraform** via the HashiCorp apt repo only if it's
  missing or older than 1.5.0,
- installs/upgrades **Ansible** via **pipx** (isolated venv, HTTPS-only — no
  apt PPA or keyserver) only if it's missing or older than 2.15.0,
- installs the required Ansible collections (`community.general`,
  `ansible.posix`) only if not already present.

Re-run it any time to upgrade — already-satisfied tools are skipped. For
RHEL/macOS the script isn't supported; use the manual steps below.

#### Option B — manual steps

Use these if you prefer not to run the script, or you're on RHEL/macOS. They
are exactly what Option A automates.

**Ubuntu / Debian / WSL:**

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release \
  git jq openssh-client make

# Terraform (HashiCorp apt repo)
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# Ansible (via pipx — isolated venv, no PPA/keyserver needed)
sudo apt-get install -y pipx || \
  { sudo apt-get install -y python3-pip python3-venv; python3 -m pip install --user pipx; }
pipx ensurepath          # then restart your shell, or: export PATH="$HOME/.local/bin:$PATH"
pipx install ansible

# Required Ansible collections
ansible-galaxy collection install community.general ansible.posix
```

**RHEL / Rocky / Fedora:**

```bash
sudo dnf install -y git jq openssh-clients make
sudo dnf config-manager --add-repo \
  https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform ansible
ansible-galaxy collection install community.general ansible.posix
```

**macOS (Homebrew):**

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform ansible jq git make
ansible-galaxy collection install community.general ansible.posix
```

**Upgrading later:** re-run `make install-prereqs` (Option A), or on apt:
`sudo apt-get update && sudo apt-get install --only-upgrade terraform ansible`.

**Verify (either option):**

```bash
terraform version && ansible --version && jq --version
```

### vCenter requirements

- An existing **Ubuntu 24.04 cloud-init template** (with `cloud-init` and
  `open-vm-tools`). Its name is requested during `make setup`.
- A service account with clone / network / datastore permissions.
- A reachable network/port group (DHCP is assumed by default).

---

## Configuration

### Interactive (recommended)

```bash
make setup            # or: scripts/setup.sh
```

`setup` prompts for every value (vCenter connection, placement, cluster shape,
SSH key, and the dependency-agent toggle), shows a review summary, then writes
`terraform/terraform.tfvars` and updates
`ansible/group_vars/all.yml`. It can:

- detect an existing SSH key (`~/.ssh/id_ed25519.pub` / `id_rsa.pub`) or
  generate a new one,
- remember previous answers as defaults on re-runs,
- optionally run `make up` for you at the end.

> **The vCenter password is never collected or stored.** It is supplied at
> Terraform runtime via the `TF_VAR_vsphere_password` environment variable —
> `make up` / `make down` prompt for it (input hidden) on every run, so it
> only ever lives in memory for that single command. The generated
> `terraform.tfvars` (which holds no password) is also **gitignored**.
>
> To run non-interactively (CI), export it yourself:
> `export TF_VAR_vsphere_password='...'` before `make up`.

### Manual (alternative)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform/terraform.tfvars
```

Key values: `vsphere_server`, `vsphere_user`,
`datacenter`, `cluster`, `resource_pool`, `datastore`, `network`,
`template_name`, and your `ssh_public_key`. Cluster shape lives in the same
file: `agent_count`, `*_cpu`, `*_memory`, `*_disk_gb`.

> Do **not** add `vsphere_password` to the file. Terraform reads it from the
> `TF_VAR_vsphere_password` environment variable at runtime (you are prompted
> automatically by `make up` / `make down`).

---

## Usage

```bash
make install-prereqs   # one-time: install tooling on the controller
make setup             # interactive: write terraform.tfvars
make up                # provision VMs, build k3s, deploy the voting app
make down              # destroy all VMs
make rebuild           # down + up = a brand-new clean environment
make clean             # remove generated inventory/kubeconfig
make validate          # terraform validate (no infra changes)
```

After `make up`:

- A kubeconfig is written to `ansible/kubeconfig` (gitignored).

  ```bash
  export KUBECONFIG=$(pwd)/ansible/kubeconfig
  kubectl get nodes -o wide          # expect 3 Ready nodes
  kubectl -n vote get pods
  ```

- The app is exposed via NodePort on every node IP:
  - Vote UI:   `http://<any-node-ip>:31000`
  - Result UI: `http://<any-node-ip>:31001`

---

## Azure Migrate integration

Discovery is handled by your **already-deployed Azure Migrate appliance** — this
repo does not configure the appliance. The three node VMs simply appear in your
Azure Migrate project once the appliance's next discovery cycle runs.

### Dependency mapping toggle

`ansible/group_vars/all.yml` controls whether the Microsoft **Dependency Agent**
is installed on the nodes:

```yaml
install_dependency_agent: false   # default: agentless (appliance handles it)
```

- **`false`** (default) — nothing extra is installed; rely on the appliance's
  agentless dependency analysis.
- **`true`** — the `dependency_agent` role installs the Linux Dependency Agent on
  all nodes for agent-based dependency mapping.

Change the value (or pass `-e install_dependency_agent=true` to `ansible-playbook`)
and re-run `make configure`.

---

## Future expansion

The k3s roles are intentionally swappable. Documented next steps (not yet built):

- Swap k3s → **RKE2** (HA, 3 servers) behind a variable.
- Add **OpenShift/OKD** or **VMware Tanzu (TKG)** provisioning profiles reusing
  the same Makefile UX.
- Add **static IP** support (currently DHCP) and a Packer template build step.
