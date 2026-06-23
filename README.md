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

**Automated (Debian/Ubuntu/WSL):**

```bash
make install-prereqs        # or: scripts/install-prereqs.sh
```

This installs/upgrades everything above, adds the **HashiCorp** and **Ansible**
apt repositories, and installs the required Ansible collections
(`community.general`, `ansible.posix`).

**Manual — Ubuntu / Debian / WSL** (exactly what the script runs):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release \
  software-properties-common git jq openssh-client make

# Terraform (HashiCorp apt repo)
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform

# Ansible (official PPA)
sudo add-apt-repository -y --update ppa:ansible/ansible
sudo apt-get install -y ansible

# Required Ansible collections
ansible-galaxy collection install community.general ansible.posix
```

**Manual — RHEL / Rocky / Fedora:**

```bash
sudo dnf install -y git jq openssh-clients make
sudo dnf config-manager --add-repo \
  https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform ansible
ansible-galaxy collection install community.general ansible.posix
```

**Manual — macOS (Homebrew):**

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform ansible jq git make
ansible-galaxy collection install community.general ansible.posix
```

**Upgrading later:** re-run `make install-prereqs`, or on apt:
`sudo apt-get update && sudo apt-get install --only-upgrade terraform ansible`.

Verify:

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
- read the vCenter password **without echoing** it to the screen,
- remember previous answers as defaults on re-runs,
- optionally run `make up` for you at the end.

> The generated `terraform.tfvars` is **gitignored** — secrets never get
> committed.

### Manual (alternative)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform/terraform.tfvars
```

Key values: `vsphere_server`, `vsphere_user`, `vsphere_password`,
`datacenter`, `cluster`, `resource_pool`, `datastore`, `network`,
`template_name`, and your `ssh_public_key`. Cluster shape lives in the same
file: `agent_count`, `*_cpu`, `*_memory`, `*_disk_gb`.

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
