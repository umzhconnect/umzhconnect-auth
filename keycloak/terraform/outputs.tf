output "issuer" {
  description = "Published issuer URI (token `iss` claim)."
  value       = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}"
}

output "token_endpoint" {
  description = "OAuth 2.0 token endpoint."
  value       = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}/protocol/openid-connect/token"
}

output "discovery_endpoint" {
  description = "OIDC discovery document."
  value       = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}/.well-known/openid-configuration"
}

output "jwks_endpoint" {
  description = "Authorization Server JWKS (token signature keys)."
  value       = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}/protocol/openid-connect/certs"
}

output "m2m_client_ids" {
  description = "Registered machine-to-machine client IDs."
  value       = keys(local.hospitals)
}
