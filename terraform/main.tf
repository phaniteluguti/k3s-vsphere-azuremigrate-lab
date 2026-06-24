terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = ">= 2.6.0"
    }
  }
}

provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = var.allow_unverified_ssl
}

# ---------------------------------------------------------------------------
# Data sources: locate the existing vSphere objects the VMs are created on.
# ---------------------------------------------------------------------------
data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "datastore" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_resource_pool" "pool" {
  name          = var.resource_pool
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

# Existing Ubuntu 24.04 cloud-init template to clone from.
data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

# ---------------------------------------------------------------------------
# Node definitions: 1 k3s server + N agents (default 2).
# ---------------------------------------------------------------------------
locals {
  nodes = merge(
    {
      "${var.cluster_name}-server" = {
        role    = "server"
        cpu     = var.server_cpu
        memory  = var.server_memory
        disk_gb = var.server_disk_gb
      }
    },
    {
      for i in range(var.agent_count) :
      "${var.cluster_name}-agent-${i + 1}" => {
        role    = "agent"
        cpu     = var.agent_cpu
        memory  = var.agent_memory
        disk_gb = var.agent_disk_gb
      }
    }
  )
}

# ---------------------------------------------------------------------------
# IP allocation: DHCP (default) or static addresses from node_subnet_cidr.
# Static IPs are assigned in a stable order: server first, then agents.
# ---------------------------------------------------------------------------
locals {
  static = var.ip_allocation == "static"

  node_order = concat(
    ["${var.cluster_name}-server"],
    [for i in range(var.agent_count) : "${var.cluster_name}-agent-${i + 1}"]
  )

  node_ip = local.static ? {
    for idx, name in local.node_order :
    name => cidrhost(var.node_subnet_cidr, var.node_ip_start + idx)
  } : {}

  prefix  = local.static ? tonumber(split("/", var.node_subnet_cidr)[1]) : 0
  gateway = local.static ? (var.node_gateway != "" ? var.node_gateway : cidrhost(var.node_subnet_cidr, 1)) : ""
}

resource "vsphere_virtual_machine" "node" {
  for_each = local.nodes

  name             = each.key
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id
  folder           = var.vm_folder

  num_cpus = each.value.cpu
  memory   = each.value.memory
  guest_id = data.vsphere_virtual_machine.template.guest_id

  # Match the template's firmware (BIOS vs EFI). Cloning an EFI template into a
  # BIOS VM fails to power on with "ACPI motherboard layout requires EFI".
  firmware                = data.vsphere_virtual_machine.template.firmware
  efi_secure_boot_enabled = data.vsphere_virtual_machine.template.efi_secure_boot_enabled

  scsi_type = data.vsphere_virtual_machine.template.scsi_type

  network_interface {
    network_id   = data.vsphere_network.network.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label = "disk0"
    # A clone can never shrink the source disk, so never request less than the
    # template's disk size. This makes the lab work with any template regardless
    # of how large its base image is.
    size             = max(each.value.disk_gb, data.vsphere_virtual_machine.template.disks[0].size)
    eagerly_scrub    = data.vsphere_virtual_machine.template.disks[0].eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  # cloud-init via vApp/guestinfo properties. user-data installs the SSH key and
  # base packages; meta-data carries the hostname and the network config
  # (static IP or DHCP) so the nodes come up with predictable addresses.
  extra_config = {
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/cloud-init.yaml.tpl", {
      hostname       = each.key
      ssh_public_key = var.ssh_public_key
    }))
    "guestinfo.userdata.encoding" = "base64"
    "guestinfo.metadata" = base64encode(templatefile("${path.module}/metadata.yaml.tpl", {
      hostname = each.key
      dhcp4    = local.static ? "false" : "true"
      ip       = local.static ? local.node_ip[each.key] : ""
      prefix   = local.prefix
      gateway  = local.gateway
      dns      = join(", ", var.node_dns)
    }))
    "guestinfo.metadata.encoding" = "base64"
  }

  lifecycle {
    ignore_changes = [extra_config]

    precondition {
      condition     = var.ip_allocation != "static" || can(cidrhost(var.node_subnet_cidr, var.node_ip_start))
      error_message = "ip_allocation = static requires a valid node_subnet_cidr (e.g. \"10.35.1.0/24\")."
    }
  }
}
