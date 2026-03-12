terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.98.1"
    }
    netbox = {
      source  = "e-breuninger/netbox"
      version = "~> 5.1.0"
    }
  }
}

locals {
  cluster_name                 = var.cluster_name != null ? var.cluster_name : var.defaults.cluster_name
  node_name                    = var.node_name != null ? var.node_name : var.defaults.node_name
  ct_os                        = var.ct_os != null ? var.ct_os : var.defaults.ct_os
  os_template_file_id          = var.os_template_file_id != null ? var.os_template_file_id : try(var.defaults.os_template_file_ids[local.ct_os], var.defaults.os_template_file_id)
  os_type                      = var.os_type != null ? var.os_type : try(var.defaults.os_type, "unmanaged")
  enable_netbox                = var.enable_netbox != null ? var.enable_netbox : try(var.defaults.enable_netbox, true)
  disk_datastore_id            = var.disk_datastore_id != null ? var.disk_datastore_id : try(var.defaults.disk_datastore_id, "local")
  initialization_dns_domain    = var.initialization_dns_domain != null ? var.initialization_dns_domain : var.defaults.initialization_dns_domain
  initialization_dns_servers   = var.initialization_dns_servers != null ? var.initialization_dns_servers : var.defaults.initialization_dns_servers
  initialization_ipv4_gateway  = var.initialization_ipv4_gateway != null ? var.initialization_ipv4_gateway : var.defaults.initialization_ipv4_gateway
  initialization_user_keys     = var.initialization_user_keys != null ? var.initialization_user_keys : try(var.defaults.initialization_user_keys, null)
  initialization_user_password = var.initialization_user_password != null ? var.initialization_user_password : try(var.defaults.initialization_user_password, null)
}

data "netbox_cluster" "cluster" {
  count = local.enable_netbox ? 1 : 0
  name  = local.cluster_name
}

data "netbox_tag" "terraform" {
  count = local.enable_netbox ? 1 : 0
  name  = "Terraform"
}

resource "proxmox_virtual_environment_container" "ct" {
  description  = "Managed by Terraform"
  tags         = ["terraform", local.ct_os]
  node_name    = local.node_name
  vm_id        = var.ct_id
  unprivileged = var.unprivileged

  dynamic "features" {
    for_each = var.features != null ? [var.features] : []
    content {
      nesting = features.value.nesting
      fuse    = features.value.fuse
      keyctl  = features.value.keyctl
      mount   = features.value.mount
    }
  }

  cpu {
    cores        = var.cpu_cores
    architecture = var.cpu_architecture
  }

  memory {
    dedicated = var.memory_size
    swap      = var.swap_size
  }

  operating_system {
    template_file_id = local.os_template_file_id
    type             = local.os_type
  }

  disk {
    datastore_id = local.disk_datastore_id
    size         = var.disk_size
  }

  dynamic "network_interface" {
    for_each = var.network_interfaces
    content {
      name     = network_interface.value.name
      bridge   = network_interface.value.bridge
      firewall = network_interface.value.firewall
      vlan_id  = network_interface.value.vlan_id
    }
  }

  initialization {
    hostname = split(".", var.ct_name)[0]

    dns {
      domain  = local.initialization_dns_domain
      servers = local.initialization_dns_servers
    }

    ip_config {
      ipv4 {
        address = var.network_interfaces[0].ipv4_address
        gateway = local.initialization_ipv4_gateway
      }
    }

    dynamic "user_account" {
      for_each = local.initialization_user_keys != null || local.initialization_user_password != null ? [1] : []
      content {
        keys     = local.initialization_user_keys
        password = local.initialization_user_password
      }
    }
  }

  dynamic "mount_point" {
    for_each = var.mount_points
    content {
      volume    = mount_point.value.volume
      path      = mount_point.value.path
      size      = mount_point.value.size
      backup    = mount_point.value.backup
      read_only = mount_point.value.read_only
      shared    = mount_point.value.shared
      replicate = mount_point.value.replicate
      acl       = mount_point.value.acl
    }
  }

  startup {
    order      = "3"
    up_delay   = "60"
    down_delay = "60"
  }

  start_on_boot = true

  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
    ]
  }

  connection {
    type = "ssh"
    user = "root"
    host = var.ct_name
  }

  provisioner "remote-exec" {
    inline = concat([
      "echo '${split("/", var.network_interfaces[0].ipv4_address)[0]} ${var.ct_name} ${split(".", var.ct_name)[0]}' >> /etc/hosts",
    ], var.provisioner_extra_commands)
  }
}

resource "netbox_virtual_machine" "vm" {
  count = local.enable_netbox ? 1 : 0

  cluster_id = data.netbox_cluster.cluster[0].id
  site_id    = data.netbox_cluster.cluster[0].site_id

  name      = var.ct_name
  memory_mb = var.memory_size
  disk_size_mb = (var.disk_size + sum([
    for mp in var.mount_points : try(tonumber(replace(mp.size, "G", "")), 0) if mp.size != null
  ])) * 1024

  vcpus = var.cpu_cores
  local_context_data = jsonencode({
    "ct_id" = proxmox_virtual_environment_container.ct.id
  })
  tags       = [data.netbox_tag.terraform[0].name]
  depends_on = [proxmox_virtual_environment_container.ct]
}

locals {
  interfaces = {
    for i, iface in var.network_interfaces :
    i => {
      "idx"          = i
      "conf"         = iface
      "name"         = iface.name
      "ipv4_address" = try(proxmox_virtual_environment_container.ct.ipv4[iface.name], null)
      "ipv6_address" = try(proxmox_virtual_environment_container.ct.ipv6[iface.name], null)
    }
  }
  root_disk = {
    "datastore_id" = local.disk_datastore_id
    "size"         = var.disk_size
  }
}

resource "netbox_interface" "iface" {
  for_each = local.enable_netbox ? local.interfaces : {}

  virtual_machine_id = netbox_virtual_machine.vm[0].id
  name               = each.value.name
  tags               = [data.netbox_tag.terraform[0].name]
  depends_on         = [netbox_virtual_machine.vm]
}

resource "netbox_ip_address" "ipv4" {
  for_each = local.enable_netbox ? { for k, v in local.interfaces : k => v if v.conf.ipv4_address != null } : {}

  ip_address                   = each.value.conf.ipv4_address
  status                       = "active"
  virtual_machine_interface_id = netbox_interface.iface[each.key].id
  dns_name                     = each.value.name == "eth0" ? var.ct_name : null
  description                  = "${var.ct_name} (${each.value.name})"
  tags                         = [data.netbox_tag.terraform[0].name]
}

resource "netbox_primary_ip" "primary_ip4" {
  count = local.enable_netbox ? 1 : 0

  ip_address_id      = netbox_ip_address.ipv4["0"].id
  virtual_machine_id = netbox_virtual_machine.vm[0].id
}

resource "netbox_virtual_disk" "root" {
  count = local.enable_netbox ? 1 : 0

  name               = "rootfs"
  size_mb            = var.disk_size * 1024
  virtual_machine_id = netbox_virtual_machine.vm[0].id
  tags               = [data.netbox_tag.terraform[0].name]
}

resource "netbox_virtual_disk" "mount_point" {
  for_each = local.enable_netbox ? { for i, mp in var.mount_points : mp.path => mp if mp.size != null } : {}

  name               = each.key
  description        = each.value.volume
  size_mb            = try(tonumber(replace(each.value.size, "G", "")) * 1024, 0)
  virtual_machine_id = netbox_virtual_machine.vm[0].id
  tags               = [data.netbox_tag.terraform[0].name]
}
