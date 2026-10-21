terraform {
  required_version = ">= 1.5"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# Local dev: admin password supplied directly via var.keycloak_admin_password
# (set in .env, never committed).
#
# Production: set var.vault_address and let Vault supply the password.
# CI/CD authenticates to Vault via JWT/OIDC — no long-lived credentials.
#
#   data "vault_kv_secret_v2" "keycloak" {
#     mount = "secret"
#     name  = "umzh-connect/${var.environment}/keycloak"
#   }
#   # then reference: data.vault_kv_secret_v2.keycloak.data["admin_password"]

provider "keycloak" {
  client_id = "admin-cli"
  username  = var.keycloak_admin_username
  password  = var.keycloak_admin_password
  url       = var.keycloak_url
}
