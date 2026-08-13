variable "keycloak_url" {
  description = "Admin REST API URL the Terraform keycloak provider connects to (backchannel — e.g. the in-cluster Service DNS when run against k8s, or the container network name in docker-compose). Not necessarily reachable by anything outside the cluster/compose network."
  type        = string
  default     = "http://localhost:8180"
}

variable "keycloak_public_url" {
  description = "Publicly-reachable issuer URL — what ends up in the `aud` claim (ecosystem_audience mappers) and the informational outputs. Must match Keycloak's own KC_HOSTNAME so tokens' aud lines up with the iss every client already sees via discovery. Defaults to keycloak_url's default since local docker-compose exposes the same host for both; set explicitly wherever the admin API and public issuer diverge (e.g. k8s, where keycloak_url stays the in-cluster Service address)."
  type        = string
  default     = "http://localhost:8180"
}

variable "keycloak_admin_username" {
  description = "Keycloak bootstrap admin username."
  type        = string
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Keycloak bootstrap admin password. In production, supply via Vault (see versions.tf)."
  type        = string
  sensitive   = true
}

variable "vault_address" {
  description = "HashiCorp Vault address. Set to enable Vault-backed secret retrieval in production. Leave empty for local dev (keycloak_admin_password is supplied directly)."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Deployment environment name (used as Vault path segment: secret/umzh-connect/<environment>/keycloak)."
  type        = string
  default     = "dev"
}

# Gates local.clients_l1 in clients.tf: when false (the default), any
# keycloak-config/clients/*.yaml file with auth_level: "L1" is ignored — no L1
# client is created for it, and a "l1_debug_clients_ignored" check block
# emits a warning (terraform apply still succeeds) naming the ignored
# file(s). Defaults to false so provisioning an L1 (client_secret) debug
# client always requires a deliberate override, never just the presence of
# a leftover YAML file baked into a reused tf-config image. Set via
# TF_VAR_allow_l1_debug_clients (or an environment-specific tfvars file) at
# apply time — this is a plain input variable, not baked into the image, so
# each environment's Job can set it independently from the same image tag.
# See ADR 0004 (docs/adr/0004-reinstate-l1-debug-client.md) and CLAUDE.md's
# "L1 only as an explicit opt-in debug client" rule.
variable "allow_l1_debug_clients" {
  description = "Explicit opt-in permitting L1 (client_secret) debug clients to be provisioned. False (default) silently ignores keycloak-config/clients/*.yaml files with auth_level: \"L1\" (with a warning), in every environment including local dev — set to true via TF_VAR_allow_l1_debug_clients or tfvars to enable them."
  type        = bool
  default     = false
}
