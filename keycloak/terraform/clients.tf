# Machine-to-machine clients — one per hospital, L2 (private_key_jwt) only.
#
# Hospital identity lives in keycloak/config/hospitals/{org_id}.yaml.
# A hospital with no YAML file has no KC client and cannot obtain tokens.
#
# See docs/adr/0002-one-client-per-hospital.md and
#     docs/adr/0003-defer-scope-and-audience-enforcement.md.

locals {
  _hospital_files = fileset("${path.module}/../config/hospitals", "*.yaml")
  hospitals = {
    for f in local._hospital_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/hospitals/${f}"))
  }
}

resource "keycloak_openid_client" "m2m" {
  for_each = local.hospitals

  realm_id    = keycloak_realm.umzh_connect.id
  client_id   = each.key
  name        = each.value.org_display_name
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

# --- Protocol mappers -----------------------------------------------------------

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "org_reference" {
  for_each = local.hospitals

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

resource "keycloak_generic_protocol_mapper" "fhir_context" {
  for_each = local.hospitals

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
