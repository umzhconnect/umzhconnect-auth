# Audience scopes — one per FHIR server in the network.
#
# Each scope (aud:<key>) carries an audience protocol mapper that injects
# aud = <url> into the access token. It is assigned as a DEFAULT scope on
# each per-audience KC client, so the correct aud is always present without
# the client needing to request it explicitly.
#
# include_in_token_scope = false suppresses "aud:fhir-hospitalp" from the
# scope claim — the audience mapper still fires independently.

locals {
  fhir_servers = yamldecode(file("${path.module}/../config/fhir-servers.yaml")).servers
}

resource "keycloak_openid_client_scope" "aud" {
  for_each = local.fhir_servers

  realm_id               = keycloak_realm.umzh_connect.id
  name                   = "aud:${each.key}"
  description            = each.value.description
  include_in_token_scope = false
}

resource "keycloak_openid_audience_protocol_mapper" "aud" {
  for_each = local.fhir_servers

  realm_id                 = keycloak_realm.umzh_connect.id
  client_scope_id          = keycloak_openid_client_scope.aud[each.key].id
  name                     = "audience-mapper"
  included_custom_audience = each.value.url
  add_to_id_token          = false
  add_to_access_token      = true
}
