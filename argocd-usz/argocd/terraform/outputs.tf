output "issuer" {
  description = "Published issuer URI (token `iss` claim)."
  value       = "${var.keycloak_public_url}/realms/${keycloak_realm.umzh_connect.realm}"
}

output "token_endpoint" {
  description = "OAuth 2.0 token endpoint."
  value       = "${var.keycloak_public_url}/realms/${keycloak_realm.umzh_connect.realm}/protocol/openid-connect/token"
}

output "discovery_endpoint" {
  description = "OIDC discovery document."
  value       = "${var.keycloak_public_url}/realms/${keycloak_realm.umzh_connect.realm}/.well-known/openid-configuration"
}

output "jwks_endpoint" {
  description = "Authorization Server JWKS (token signature keys)."
  value       = "${var.keycloak_public_url}/realms/${keycloak_realm.umzh_connect.realm}/protocol/openid-connect/certs"
}

output "m2m_client_ids" {
  description = "Registered machine-to-machine client IDs (L2, private_key_jwt)."
  value       = keys(local.clients_l2)
}

output "m2m_l1_client_ids" {
  description = "Registered L1 debug client IDs (client_secret). See ADR 0004."
  value       = keys(local.clients_l1)
}

output "m2m_l1_client_secrets" {
  description = <<-EOT
    Keycloak-generated client secrets for L1 debug clients, keyed by
    client_id. L1 is a debug-only path (ADR 0004) — secret handling is
    deliberately relaxed relative to real production secrets: these may be
    copied into a plain committed Secret manifest in tch-umzh-connect-gitops
    (same pattern as keycloak-admin-secret.yaml) rather than routed through
    Vault.
  EOT
  value       = { for k, c in keycloak_openid_client.m2m_l1 : k => c.client_secret }
  sensitive   = true
}
