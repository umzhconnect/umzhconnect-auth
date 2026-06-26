# Machine-to-machine clients — one per hospital, L2 (private_key_jwt) only.
#
# Hospital identity lives in keycloak/config/hospitals/{org_id}.yaml.
# A hospital with no YAML file has no KC client and cannot obtain tokens.
#
# D2 audience binding (ADR 0005):
# - Each hospital gets a realm-level client scope "aud:{org_id}" carrying an
#   audience mapper that writes the hospital's FHIR URL into the token aud.
# - allowed_targets in the YAML controls which aud: scopes are assigned as
#   optional on each M2M client (explicit allow-list; no implicit access).
# - Callers include scope=aud:hospital-b in token requests to bind aud to
#   that hospital's FHIR server URL.
#
# See docs/adr/0002-one-client-per-hospital.md
#     docs/adr/0005-d2-named-aud-scopes.md

locals {
  _hospital_files = fileset("${path.module}/../config/hospitals", "*.yaml")
  hospitals = {
    for f in local._hospital_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/hospitals/${f}"))
  }
}

# ---------------------------------------------------------------------------
# M2M clients — one per hospital, L2 (private_key_jwt)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Protocol mappers — org reference and FHIR context
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# D2 audience scopes — one realm-level scope per hospital
#
# include_in_token_scope = false suppresses "aud:hospital-b" from appearing
# in the token's scope claim; the audience mapper fires independently and
# writes the FHIR URL into aud.
# ---------------------------------------------------------------------------

resource "keycloak_openid_client_scope" "aud_scope" {
  for_each = local.hospitals

  realm_id               = keycloak_realm.umzh_connect.id
  name                   = "aud:${each.key}"
  description            = "Audience binding for ${each.value.org_display_name} FHIR server"
  include_in_token_scope = false
  gui_order              = 2
  consent_screen_text    = ""
}

resource "keycloak_openid_audience_protocol_mapper" "aud_scope_mapper" {
  for_each = local.hospitals

  realm_id        = keycloak_realm.umzh_connect.id
  client_scope_id = keycloak_openid_client_scope.aud_scope[each.key].id
  name            = "aud-fhir-url"

  included_custom_audience = each.value.fhir_url

  add_to_id_token     = false
  add_to_access_token = true
}
