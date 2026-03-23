# proxmox-lxc

OpenTofu module for creating Proxmox VE LXC containers from OS templates
with optional Netbox inventory registration.

## Overview

This module:

- Creates an LXC container from a Proxmox OS template (vztmpl)
- Configures networking, root disk, CPU, memory, and mount points
- Optionally registers the container in Netbox (interfaces, IP addresses, disks)
- Supports a `defaults` parameter to eliminate repetition across many containers

## Requirements

| Provider | Version |
| -------- | ------- |
| [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox) | ~> 0.98 |
| [e-breuninger/netbox](https://registry.terraform.io/providers/e-breuninger/netbox) | ~> 5.1 |

## Obtaining LXC templates

This module creates containers from Proxmox OS templates (vztmpl). Templates
can be obtained in two ways.

### Declarative download with OpenTofu (recommended)

Use the `proxmox_virtual_environment_download_file` resource to download
templates as part of your infrastructure code:

```hcl
resource "proxmox_virtual_environment_download_file" "debian_13_lxc" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = "pve1"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.0-1_amd64.tar.zst"
}
```

The resulting resource ID can then be referenced in `os_template_file_id` or
the `defaults.os_template_file_ids` map:

```hcl
locals {
  cluster_defaults = {
    # ...
    os_template_file_ids = {
      "debian13" = proxmox_virtual_environment_download_file.debian_13_lxc.id
    }
  }
}
```

### Discovering templates automatically

Instead of hardcoding template IDs, you can query Proxmox for available
templates and build the map dynamically. The example below lists vztmpl files
and builds a map by OS identifier:

```hcl
data "proxmox_virtual_environment_datastores" "local" {
  node_name = "pve1"
}

# After downloading templates (via proxmox_virtual_environment_download_file
# or pveam), reference them by their volume ID:
locals {
  cluster_defaults = {
    os_template_file_ids = {
      "debian13" = "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
      "debian12" = "local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
    }
  }
}
```

When a new template is downloaded, update the map entry — `ct_os` on each
container automatically selects the matching template.

### Manual download with pveam

Alternatively, download templates manually using the Proxmox VE Appliance
Manager CLI:

```bash
# Update the template catalog
pveam update

# List available system templates
pveam available --section system

# Download a specific template to the "local" storage
pveam download local debian-13-standard_13.0-1_amd64.tar.zst
```

After manual download, reference the template by its volume ID:

```hcl
os_template_file_id = "local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst"
```

## Supporting resources

### SSH keys

Unlike the VM module which uses a cloud-init user data file, LXC containers
configure user accounts directly through the `initialization.user_account`
block. Pass SSH keys via `defaults.initialization_user_keys`:

```hcl
locals {
  cluster_defaults = {
    # ...
    initialization_user_keys = [
      "ssh-ed25519 AAAA... admin@example.com"
    ]
  }
}
```

## Usage

### Basic — single cluster with `for_each`

Define cluster-wide defaults once, then describe each container with only its
unique parameters.

```hcl
locals {
  cluster_defaults = {
    cluster_name = "pve1"
    node_name    = "pve1"
    ct_os        = "debian13"
    os_template_file_ids = {
      "debian12" = proxmox_virtual_environment_download_file.debian_12_lxc.id
      "debian13" = proxmox_virtual_environment_download_file.debian_13_lxc.id
    }
    os_type                     = "debian"
    disk_datastore_id           = "local-zfs"
    initialization_dns_domain   = "example.com"
    initialization_dns_servers  = ["10.0.0.1"]
    initialization_ipv4_gateway = "10.0.0.1"
    initialization_user_keys    = [file("~/.ssh/id_ed25519.pub")]
    enable_netbox               = true
  }

  containers = {
    pihole = {
      ct_name      = "pihole.example.com"
      ct_id        = 200
      cpu_cores    = 1
      memory_size  = 512
      ipv4_address = "10.0.0.20/24"
      disk_size    = 8
    }
    nginx = {
      ct_name      = "nginx.example.com"
      ct_id        = 201
      cpu_cores    = 2
      memory_size  = 1024
      ipv4_address = "10.0.0.21/24"
      disk_size    = 10
    }
  }
}

module "ct" {
  for_each  = local.containers
  source    = "./modules/proxmox-lxc"
  providers = { proxmox = proxmox.pve1 }

  defaults    = local.cluster_defaults
  ct_name     = each.value.ct_name
  ct_id       = each.value.ct_id
  cpu_cores   = each.value.cpu_cores
  memory_size = each.value.memory_size
  disk_size   = each.value.disk_size

  unprivileged = true
  features     = { nesting = true }

  network_interfaces = [{
    name         = "eth0"
    bridge       = "vmbr0"
    ipv4_address = each.value.ipv4_address
  }]
}
```

Key points:

- `defaults` carries all cluster-level settings in a single assignment
- `os_template_file_ids` maps OS identifiers to template IDs — the module
  automatically picks the right template based on `ct_os`
- `network_interfaces` requires a `name` field (e.g. `eth0`) unlike VM's
  `network_device`

### Advanced — with mount points

Containers can have additional storage through mount points:

```hcl
module "fileserver" {
  source    = "./modules/proxmox-lxc"
  providers = { proxmox = proxmox.pve1 }

  defaults    = local.cluster_defaults
  ct_name     = "files.example.com"
  ct_id       = 210
  cpu_cores   = 2
  memory_size = 2048
  disk_size   = 20

  unprivileged = true
  features     = { nesting = true }

  network_interfaces = [{
    name         = "eth0"
    bridge       = "vmbr0"
    ipv4_address = "10.0.0.30/24"
  }]

  mount_points = [
    {
      volume = "local-zfs"
      size   = "50G"
      path   = "/mnt/data"
      backup = true
    },
    {
      volume = "/mnt/bindmounts/shared"
      path   = "/mnt/shared"
    }
  ]
}
```

Mount point types:

- **Volume mount** — set `volume` to a storage ID (e.g. `local-zfs`) and
  `size` to create a new volume managed by Proxmox
- **Bind mount** — set `volume` to a host path; requires `root@pam`
  authentication

### Advanced — Jellyfin with GPU passthrough

Media server container with AMD iGPU passthrough for hardware transcoding
and an NFS bind mount for media files from a NAS:

```hcl
module "jellyfin" {
  source    = "./modules/proxmox-lxc"
  providers = { proxmox = proxmox.pve1 }

  defaults    = local.cluster_defaults
  ct_name     = "jellyfin.example.com"
  ct_id       = 300
  cpu_cores   = 4
  memory_size = 4096
  disk_size   = 8

  unprivileged = true
  features     = { nesting = true, keyctl = true }

  network_interfaces = [{
    name         = "eth0"
    bridge       = "vmbr0"
    ipv4_address = "10.0.0.50/24"
  }]

  # NFS share from NAS, pre-mounted on the Proxmox host at /mnt/pve/nas-media
  mount_points = [
    {
      volume = "/mnt/pve/nas-media"
      path   = "/mnt/media"
    }
  ]

  # AMD Radeon iGPU (VAAPI) — gid 44 = video, gid 104 = render on Debian
  device_passthrough = [
    { path = "/dev/dri/card0", mode = "0666", gid = 44 },
    { path = "/dev/dri/renderD128", mode = "0666", gid = 104 },
  ]
}
```

Prerequisites on the Proxmox host:

- The NFS share must be mounted (e.g. via `/etc/fstab` or Proxmox storage
  configuration) before creating the container
- The `amdgpu` (or `i915` for Intel) kernel module must be loaded so that
  `/dev/dri/card0` and `/dev/dri/renderD128` exist on the host
- Inside the container, install Mesa drivers (`mesa-vulkan-drivers`,
  `libgl1-mesa-dri`) and add the `jellyfin` user to the `video` and `render`
  groups

### Advanced — multiple clusters with `count`

When you need index arithmetic for node placement and IP calculation:

```hcl
module "worker_ct" {
  source    = "./modules/proxmox-lxc"
  count     = 3
  providers = { proxmox = proxmox.dc1 }

  defaults    = local.dc1_defaults
  ct_name     = "worker${count.index + 1}.internal.example.com"
  node_name   = format("dc1-node%02d", count.index % 3 + 1)
  ct_id       = 5000 + count.index
  cpu_cores   = 2
  memory_size = 2048
  disk_size   = 20

  unprivileged = true
  features     = { nesting = true }

  network_interfaces = [{
    name         = "eth0"
    bridge       = "vmbr0"
    vlan_id      = 100
    ipv4_address = "10.1.100.${10 + count.index}/24"
  }]

  initialization_ipv4_gateway = "10.1.100.1"
}
```

## The `defaults` parameter

The `defaults` object carries cluster-level or project-level settings. Every
field in `defaults` has a corresponding module variable. Resolution order:

1. **Explicit parameter** — always wins when non-null
2. **`defaults.os_template_file_ids[ct_os]`** — automatic template lookup
   (for `os_template_file_id` only)
3. **`defaults.<field>`** — fallback from the defaults object

Special behaviors:

- `os_template_file_id`: if not set explicitly, looked up from
  `defaults.os_template_file_ids` using the effective `ct_os` as key. This
  means changing just `ct_os` on a container automatically selects the matching
  template.
- `enable_netbox`: ultimate fallback is `true` if not set anywhere.
- `disk_datastore_id`: fallback is `"local"` if not set anywhere.

### `defaults` fields

| Field | Type | Description |
| ------ | ---- | ----------- |
| `cluster_name` | `string` | Proxmox cluster name (for Netbox registration) |
| `node_name` | `string` | Default Proxmox node for container placement |
| `ct_os` | `string` | Default OS identifier (e.g. `debian13`) |
| `os_template_file_id` | `string` | Default OS template file ID |
| `os_template_file_ids` | `map(string)` | Map of `ct_os` → template file ID for auto-lookup |
| `os_type` | `string` | OS type for Proxmox (debian, ubuntu, etc.) |
| `disk_datastore_id` | `string` | Default datastore for root filesystem |
| `initialization_dns_domain` | `string` | DNS domain |
| `initialization_dns_servers` | `list(string)` | DNS servers |
| `initialization_ipv4_gateway` | `string` | Default IPv4 gateway |
| `initialization_user_keys` | `list(string)` | SSH public keys for root |
| `initialization_user_password` | `string` | Password for root |
| `enable_netbox` | `bool` | Whether to create Netbox resources |

## Inputs

| Name | Type | Default | Required | Description |
| ---- | ---- | ------- | -------- | ----------- |
| `defaults` | `object(...)` | `{}` | no | Default values (see above) |
| `ct_name` | `string` | — | **yes** | Container name (FQDN) |
| `ct_id` | `number` | — | **yes** | Proxmox container ID |
| `network_interfaces` | `list(object)` | — | **yes** | Network interfaces (see below) |
| `cluster_name` | `string` | `null` | no | Proxmox cluster name |
| `node_name` | `string` | `null` | no | Proxmox node name |
| `ct_os` | `string` | `null` | no | OS identifier for tagging and template lookup |
| `os_template_file_id` | `string` | `null` | no | OS template file ID |
| `os_type` | `string` | `null` | no | OS type (debian, ubuntu, etc.) |
| `memory_size` | `number` | `512` | no | RAM in MB |
| `swap_size` | `number` | `512` | no | Swap in MB |
| `cpu_cores` | `number` | `1` | no | Number of CPU cores |
| `cpu_architecture` | `string` | `"amd64"` | no | CPU architecture |
| `unprivileged` | `bool` | `true` | no | Run as unprivileged container |
| `features` | `object` | `null` | no | Container features (nesting, fuse, keyctl, mount) |
| `disk_datastore_id` | `string` | `null` | no | Datastore for root filesystem |
| `disk_size` | `number` | `4` | no | Root filesystem size in GB |
| `mount_points` | `list(object)` | `[]` | no | Mount points (see below) |
| `device_passthrough` | `list(object)` | `[]` | no | Device passthrough (see below) |
| `initialization_dns_domain` | `string` | `null` | no | DNS domain |
| `initialization_dns_servers` | `list(string)` | `null` | no | DNS servers |
| `initialization_ipv4_gateway` | `string` | `null` | no | IPv4 gateway |
| `initialization_user_keys` | `list(string)` | `null` | no | SSH public keys for root |
| `initialization_user_password` | `string` | `null` | no | Password for root |
| `enable_netbox` | `bool` | `null` | no | Create Netbox resources (fallback: `true`) |
| `provisioner_extra_commands` | `list(string)` | `[]` | no | Additional shell commands run via remote-exec after creation |

### `network_interfaces` object

| Field | Type | Default | Description |
| ------ | ---- | ------- | ----------- |
| `name` | `string` | — | Interface name (e.g. `eth0`) |
| `bridge` | `string` | `"vmbr0"` | Bridge name |
| `firewall` | `bool` | `false` | Enable Proxmox firewall |
| `vlan_id` | `number` | `null` | VLAN tag |
| `ipv4_address` | `string` | `null` | IPv4 address with CIDR (e.g. `10.0.0.1/24`) |
| `ipv6_address` | `string` | `null` | IPv6 address with prefix |

### `mount_points` object

| Field | Type | Default | Description |
| ------ | ---- | ------- | ----------- |
| `volume` | `string` | — | Storage ID (volume mount) or host path (bind mount) |
| `path` | `string` | — | Mount path inside the container |
| `size` | `string` | `null` | Volume size with unit (e.g. `10G`), only for volume mounts |
| `backup` | `bool` | `false` | Include in backups (volume mounts only) |
| `read_only` | `bool` | `false` | Mount as read-only |
| `shared` | `bool` | `false` | Mark as available on all nodes |
| `replicate` | `bool` | `null` | Include in storage replica jobs |
| `acl` | `bool` | `null` | Enable or disable ACL support |

### `device_passthrough` object

| Field | Type | Default | Description |
| ------ | ---- | ------- | ----------- |
| `path` | `string` | — | Device path on the host (e.g. `/dev/dri/card0`) |
| `deny_write` | `bool` | `false` | Deny write access to the device |
| `gid` | `number` | `null` | Group ID for the device inside the container |
| `uid` | `number` | `null` | User ID for the device inside the container |
| `mode` | `string` | `null` | File mode for the device (e.g. `0666`) |

## Outputs

| Name | Description |
| ---- | ----------- |
| `ct` | The `proxmox_virtual_environment_container` resource |
| `netbox_vm` | The `netbox_virtual_machine` resource (or `null` if Netbox disabled) |
| `ifaces` | Map of network interfaces with runtime data (IPs) |
| `root_disk` | Root disk configuration |

## Notes

### State migration when switching to `for_each`

When converting individual module blocks to a single `for_each` block, existing
state must be moved to prevent recreation:

```bash
tofu state mv 'module.myct' 'module.cluster_ct["myct"]'
```

Always run `tofu plan` after migration to verify zero changes.

### Lifecycle

The module ignores changes to `initialization[0].user_account` to prevent
unnecessary updates after initial provisioning.

<!-- markdownlint-configure-file {
  "MD013": { "tables": false, "line_length": 100 },
} -->
