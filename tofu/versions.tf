# OpenSASE -- infrastructure provisioning (OpenTofu).
#
# Tofu provisions the VM/instance; deployment stays Nix-native
# (nixos-rebuild --target-host). Wrap, don't convert -- the HCL is
# deliberately static and readable.
#
# Usage:
#   nix run .#tofu -- -chdir=tofu init -backend=false
#   nix run .#tofu -- -chdir=tofu plan
#   nix run .#tofu -- -chdir=tofu apply
#
# Providers are pinned in tofu.lock (terraform.lock.hcl equivalent) and
# must be committed.

terraform {
  required_version = ">= 1.6.0"
}

variable "provider" {
  description = "Which cloud shape to use: hcloud|aws|none (local testing only)"
  type        = string
  default     = "none"
}
