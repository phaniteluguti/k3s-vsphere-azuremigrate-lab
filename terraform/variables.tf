# ---------------------------------------------------------------------------
# vCenter connection
# ---------------------------------------------------------------------------
variable "vsphere_server" {
  description = "vCenter server FQDN or IP."
  type        = string
}

variable "vsphere_user" {
  description = "vCenter username (e.g. administrator@vsphere.local)."
  type        = string
}

variable "vsphere_password" {
  description = "vCenter password."
  type        = string
  sensitive   = true
}

variable "allow_unverified_ssl" {
  description = "Allow self-signed vCenter certificates (common in labs)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# vSphere placement
# ---------------------------------------------------------------------------
variable "datacenter" {
  description = "vSphere datacenter name."
  type        = string
}

variable "cluster" {
  description = "vSphere compute cluster name."
  type        = string
}

variable "resource_pool" {
  description = "Resource pool name. Use '<cluster>/Resources' for the cluster root pool."
  type        = string
}

variable "datastore" {
  description = "Datastore name where node disks are placed."
  type        = string
}

variable "network" {
  description = "Port group / network name the nodes attach to."
  type        = string
}

variable "vm_folder" {
  description = "Optional VM folder path. Empty places VMs at the datacenter root."
  type        = string
  default     = ""
}

variable "template_name" {
  description = "Name of the existing Ubuntu 24.04 cloud-init template to clone."
  type        = string
  default     = "ubuntu-24.04-template"
}

# ---------------------------------------------------------------------------
# Cluster shape
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Prefix for node VM names (e.g. k3s-lab -> k3s-lab-server)."
  type        = string
  default     = "k3s-lab"
}

variable "agent_count" {
  description = "Number of k3s agent (worker) nodes."
  type        = number
  default     = 2
}

# Server node specs
variable "server_cpu" {
  type    = number
  default = 4
}
variable "server_memory" {
  description = "Server memory in MB."
  type        = number
  default     = 8192
}
variable "server_disk_gb" {
  type    = number
  default = 40
}

# Agent node specs
variable "agent_cpu" {
  type    = number
  default = 4
}
variable "agent_memory" {
  description = "Agent memory in MB."
  type        = number
  default     = 8192
}
variable "agent_disk_gb" {
  type    = number
  default = 40
}

# ---------------------------------------------------------------------------
# Guest access
# ---------------------------------------------------------------------------
variable "ssh_public_key" {
  description = "SSH public key injected into the 'ubuntu' user via cloud-init."
  type        = string
}

# ---------------------------------------------------------------------------
# Node IP allocation
# ---------------------------------------------------------------------------
variable "ip_allocation" {
  description = "How node IPs are assigned: \"dhcp\" (let the network assign) or \"static\" (assign from node_subnet_cidr)."
  type        = string
  default     = "dhcp"
  validation {
    condition     = contains(["dhcp", "static"], var.ip_allocation)
    error_message = "ip_allocation must be \"dhcp\" or \"static\"."
  }
}

variable "node_subnet_cidr" {
  description = "Subnet CIDR used for static IPs, e.g. \"10.35.1.0/24\". Required when ip_allocation = static."
  type        = string
  default     = ""
}

variable "node_ip_start" {
  description = "Starting host number within node_subnet_cidr for the server node; agents follow sequentially (e.g. 20 -> server .20, agent-1 .21, agent-2 .22)."
  type        = number
  default     = 20
}

variable "node_gateway" {
  description = "Default gateway for static IPs. Empty = first host of node_subnet_cidr."
  type        = string
  default     = ""
}

variable "node_dns" {
  description = "DNS servers for static IPs."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}
