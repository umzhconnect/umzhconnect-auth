# Machine-to-machine clients — grant-driven, L2 (private_key_jwt) only.
#
# App identity lives in keycloak/config/apps/{org_id}--{app_id}.yaml.
# Access rights live in keycloak/config/grants/{target_org_id}.yaml.
#
# One KC client is generated per grant entry (one per app × target FHIR server).
# KC client_id convention: {org_id}--{app_id}--fhir-{target_org_id}
#
# A registered app with no grant entries produces no KC clients — registration
# does not imply access anywhere.
#
# See audience_architecture.md for the full design rationale and D3 migration path.

locals {
  _app_files = fileset("${path.module}/../config/apps", "*.yaml")
  apps = {
    for f in local._app_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/apps/${f}"))
  }

  _grant_files = fileset("${path.module}/../config/grants", "*.yaml")
  _grants = {
    for f in local._grant_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/grants/${f}"))
  }

  # Flatten grants into a map keyed by KC client_id.
  # Grant files are named after the FHIR server key (e.g. fhir-hospital-a-lab.yaml),
  # so the map key IS the server_key — no derivation needed.
  # App metadata is looked up from local.apps by app_key.
  m2m_clients = {
    for triple in flatten([
      for server_key, grant_cfg in local._grants : [
        for app_key, app_grant in grant_cfg.grants : {
          client_id     = "${app_key}--${server_key}"
          name          = "${local.apps[app_key].org_display_name} / ${local.apps[app_key].app_display_name} → ${server_key}"
          description   = "L2 M2M: ${local.apps[app_key].org_display_name} ${local.apps[app_key].app_display_name} calling ${server_key}"
          jwks_url      = local.apps[app_key].jwks_url
          tenant        = local.apps[app_key].tenant
          role          = local.apps[app_key].role
          org_reference = local.apps[app_key].org_reference
          server_key    = server_key
          scopes        = app_grant.scopes
        }
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

  # Granted SMART scopes + the aud: scope for this client's target FHIR server.
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
