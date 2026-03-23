variable "defaults" {
  description = "Default values for parameters. Explicit parameter values take precedence."
  type = object({
    cluster_name                 = optional(string)
    node_name                    = optional(string)
    ct_os                        = optional(string)
    os_template_file_id          = optional(string)
    os_template_file_ids         = optional(map(string))
    os_type                      = optional(string)
    disk_datastore_id            = optional(string)
    initialization_dns_domain    = optional(string)
    initialization_dns_servers   = optional(list(string))
    initialization_ipv4_gateway  = optional(string)
    initialization_user_keys     = optional(list(string))
    initialization_user_password = optional(string)
    enable_netbox                = optional(bool)
    prevent_destroy              = optional(bool)
    dns_provider                 = optional(string)
    dns_zone                     = optional(string)
    dns_ttl                      = optional(number)
  })
  default = {}
}

variable "cluster_name" {
  type        = string
  description = "Proxmox cluster name"
  default     = null
}

variable "ct_name" {
  type        = string
  description = "Container name (FQDN)"
}

variable "node_name" {
  type        = string
  description = "Proxmox node name"
  default     = null
}

variable "ct_id" {
  type        = number
  description = "Container ID in Proxmox"
}

variable "ct_os" {
  type        = string
  description = "Operating system identifier (e.g. debian13), used for tagging and os_template_file_ids lookup"
  default     = null
}

variable "memory_size" {
  type        = number
  description = "RAM size in MB"
  default     = 512
}

variable "swap_size" {
  type        = number
  description = "Swap size in MB"
  default     = 512
}

variable "cpu_cores" {
  type        = number
  description = "Number of CPU cores"
  default     = 1
}

variable "cpu_architecture" {
  type        = string
  description = "CPU architecture (amd64, arm64, armhf, i386)"
  default     = "amd64"
}

variable "unprivileged" {
  type        = bool
  description = "Whether the container runs as unprivileged on the host"
  default     = true
}

variable "features" {
  type = object({
    nesting = optional(bool, false)
    fuse    = optional(bool, false)
    keyctl  = optional(bool, false)
    mount   = optional(list(string))
  })
  description = "Container feature flags"
  default     = null
}

variable "os_template_file_id" {
  type        = string
  description = "OS template file ID. If null, resolved from defaults.os_template_file_ids[ct_os]."
  default     = null
}

variable "os_type" {
  type        = string
  description = "Operating system type (debian, ubuntu, alpine, centos, fedora, etc.)"
  default     = null
}

variable "network_interfaces" {
  type = list(object({
    name         = string
    bridge       = optional(string, "vmbr0")
    firewall     = optional(bool, false)
    vlan_id      = optional(number)
    ipv4_address = optional(string)
    ipv6_address = optional(string)
  }))
  description = "Network interfaces"
}

variable "disk_datastore_id" {
  type        = string
  description = "Datastore for the root filesystem"
  default     = null
}

variable "disk_size" {
  type        = number
  description = "Root filesystem size in GB"
  default     = 4
}

variable "mount_points" {
  type = list(object({
    volume    = string
    path      = string
    size      = optional(string)
    backup    = optional(bool, false)
    read_only = optional(bool, false)
    shared    = optional(bool, false)
    replicate = optional(bool)
    acl       = optional(bool)
  }))
  description = "Mount points (bind mounts or volume mounts)"
  default     = []
}

variable "device_passthrough" {
  type = list(object({
    path       = string
    deny_write = optional(bool, false)
    gid        = optional(number)
    uid        = optional(number)
    mode       = optional(string)
  }))
  description = "Device passthrough configuration (e.g. /dev/dri for GPU)"
  default     = []
}

variable "initialization_dns_domain" {
  type        = string
  description = "DNS domain"
  default     = null
}

variable "initialization_dns_servers" {
  type        = list(string)
  description = "DNS servers"
  default     = null
}

variable "initialization_ipv4_gateway" {
  type        = string
  description = "IPv4 gateway"
  default     = null
}

variable "initialization_user_keys" {
  type        = list(string)
  description = "SSH public keys for the root account"
  default     = null
}

variable "initialization_user_password" {
  type        = string
  description = "Password for the root account"
  default     = null
  sensitive   = true
}

variable "enable_netbox" {
  type        = bool
  description = "Whether to create Netbox resources"
  default     = null
}

variable "provisioner_extra_commands" {
  type        = list(string)
  description = "Additional shell commands to run via remote-exec after container creation"
  default     = []
}

variable "prevent_destroy" {
  type        = bool
  description = "Prevent accidental container deletion. When true, any plan that would destroy the container (including force-replacement) will be rejected."
  default     = null
}

variable "dns_provider" {
  type        = string
  description = "DNS provider: 'opnsense', 'rfc2136', or null to disable. Use 'rfc2136' for PowerDNS, Bind, Knot, etc."
  default     = null
  validation {
    condition     = var.dns_provider == null || contains(["opnsense", "rfc2136"], var.dns_provider)
    error_message = "dns_provider must be 'opnsense', 'rfc2136', or null"
  }
}

variable "dns_zone" {
  type        = string
  description = "DNS zone with trailing dot, e.g. 'example.com.' (RFC2136). Derived from ct_name if null."
  default     = null
}

variable "dns_ttl" {
  type        = number
  description = "DNS record TTL in seconds (RFC2136, default 3600)"
  default     = null
}
