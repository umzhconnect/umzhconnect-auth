# Machine-to-machine clients — YAML-driven, L2 (private_key_jwt) only.
#
# Config lives in keycloak/config/clients/<hospital>.yaml.
# One KC client is generated per (org, app, audience) triple.
# KC client_id convention: {org_id}--{app_id}--{server_key}
#
# Each KC client has exactly one audience (its aud: scope is assigned as a
# default scope), so the AS enforces the audience-scope binding at the client
# level. No optional scopes — the per-audience scope set in the YAML is the
# complete grant.
#
# See audience_architecture.md for the full design rationale and D3 migration path.

locals {
  _org_files = fileset("${path.module}/../config/clients", "*.yaml")
  _orgs = {
    for f in local._org_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/clients/${f}"))
  }

  # Flatten org → apps → audiences into a flat map keyed by KC client_id.
  m2m_clients = {
    for triple in flatten([
      for _org_key, org in local._orgs : [
        for app_id, app in org.apps : [
          for server_key, aud_cfg in app.audiences : {
            client_id     = "${org.org_id}--${app_id}--${server_key}"
            name          = "${org.display_name} / ${app.display_name} → ${server_key}"
            description   = "L2 M2M: ${org.display_name} ${app.display_name} calling ${server_key}"
            jwks_url      = app.jwks_url
            tenant        = org.tenant
            role          = org.role
            org_reference = org.org_reference
            server_key    = server_key
            scopes        = aud_cfg.scopes
          }
        ]
      ]
    ]) : triple.client_id => triple
  }
}

resource "keycloak_openid_client" "m2m" {
  for_each = local.m2m_clients

  realm_id    = keycloak_realm.umzh_connect.id
  client_id   = each.key
  name        = each.value.name
  description = each.value.description
  enabled     = true

  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false

  client_authenticator_type = "client-jwt"

  extra_config = {
    "use.jwks.url" = "true"
    "jwks.url"     = each.value.jwks_url
  }
}

resource "keycloak_openid_client_default_scopes" "m2m" {
  for_each = local.m2m_clients

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id

  # Audience-specific SMART scopes + the aud: scope for this client's one target.
  # The aud: scope carries the audience mapper that sets aud = FHIR server URL.
  default_scopes = concat(
    each.value.scopes,
    ["aud:${each.value.server_key}"]
  )

  depends_on = [
    keycloak_openid_client_scope.system,
    keycloak_openid_client_scope.aud,
  ]
}

# Party realm role on the service account (drives the realm_roles claim).
resource "keycloak_openid_client_service_account_realm_role" "m2m" {
  for_each = local.m2m_clients

  realm_id                = keycloak_realm.umzh_connect.id
  service_account_user_id = keycloak_openid_client.m2m[each.key].service_account_user_id
  role                    = each.value.role

  depends_on = [keycloak_role.placer, keycloak_role.fulfiller]
}

# --- Protocol mappers -----------------------------------------------------------

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "org_reference" {
  for_each = local.m2m_clients

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "org-reference-mapper"

  claim_name       = "extensions.umzhconnect.organization_reference"
  claim_value      = each.value.org_reference
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "tenant" {
  for_each = local.m2m_clients

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "tenant-mapper"

  claim_name       = "tenant"
  claim_value      = each.value.tenant
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "realm_roles" {
  for_each = local.m2m_clients

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "realm-roles"

  claim_name       = "realm_roles"
  claim_value_type = "String"
  multivalued      = true

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_generic_protocol_mapper" "fhir_context" {
  for_each = local.m2m_clients

  realm_id        = keycloak_realm.umzh_connect.id
  client_id       = keycloak_openid_client.m2m[each.key].id
  name            = "fhir-context-mapper"
  protocol        = "openid-connect"
  protocol_mapper = "umzh-fhir-context-mapper"

  config = {
    "id.token.claim"       = "false"
    "access.token.claim"   = "true"
    "userinfo.token.claim" = "false"
  }
}
