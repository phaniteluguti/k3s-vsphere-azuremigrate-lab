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
└── scripts/render-inventory.sh   # terraform outputs -> ansible inventory
```

---

## Prerequisites

On your workstation (the machine running `make`):

| Tool       | Purpose                                  |
|------------|------------------------------------------|
| Terraform  | provision VMs (vsphere provider)         |
| Ansible    | configure cluster + deploy app           |
| jq         | parse Terraform outputs for the inventory|
| ssh        | Ansible transport to the nodes           |

> The Ansible control steps run on Linux/macOS/WSL. On Windows, run `make`
> targets from **WSL** or a Linux jump host (the `scripts/*.sh` use bash).

In vCenter you need:

- An existing **Ubuntu 24.04 cloud-init template** (with `cloud-init` and
  `open-vm-tools`). The template name goes in `terraform.tfvars`.
- A service account with clone / network / datastore permissions.
- A reachable network/port group (DHCP is assumed by default).

---

## Configuration

1. Copy the example tfvars and fill in your environment:

   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   # edit terraform/terraform.tfvars
   ```

   Key values: `vsphere_server`, `vsphere_user`, `vsphere_password`,
   `datacenter`, `cluster`, `resource_pool`, `datastore`, `network`,
   `template_name`, and your `ssh_public_key`.

   > `terraform.tfvars` is **gitignored** — secrets never get committed.

2. (Optional) Adjust cluster shape in the same file:
   `agent_count`, `*_cpu`, `*_memory`, `*_disk_gb`.

---

## Usage

```bash
make up        # provision VMs, build k3s, deploy the voting app
make down      # destroy all VMs
make rebuild   # down + up = a brand-new clean environment
make clean     # remove generated inventory/kubeconfig
make validate  # terraform validate (no infra changes)
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
