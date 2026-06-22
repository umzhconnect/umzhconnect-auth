variable "keycloak_url" {
  description = "Base URL of the Keycloak instance (backchannel URL when run inside docker-compose)."
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
