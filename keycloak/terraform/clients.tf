# Machine-to-machine clients — one per hospital, L2 (private_key_jwt) by
# default, plus an optional L1 (client_secret) debug client per hospital.
#
# Hospital identity lives in keycloak/config/hospitals/{org_id}.yaml.
# A hospital with no YAML file has no L2 KC client and cannot obtain tokens
# via the standard path.
#
# L1 debug clients live in keycloak/config/hospitals-l1/{org_id}.yaml and are
# entirely independent of the L2 file for the same org_id — a hospital may
# have an L1 file, an L2 file, both, or neither. L1 exists for hospitals to
# debug connectivity (firewalls, routing, JWKS reachability) before or
# instead of standing up the full L2 private_key_jwt flow. See
# docs/adr/0004-reinstate-l1-debug-client.md.
#
# Audience binding (ADR 0003):
# - Every M2M client's tokens carry a constant "aud" identifying the
#   umzh-connect ecosystem as a whole (the realm issuer URL) — see the
#   ecosystem_audience mapper below. Target-specific aud binding via RFC 8707
#   is deferred until Keycloak's resource-indicators support is non-experimental.
# - There is no per-target aud mechanism and no per-hospital allow-list.
#   Any FHIR server in the realm accepts any token; FHIR servers are
#   responsible for their own authorization.
#
# See docs/adr/0002-one-client-per-hospital.md
#     docs/adr/0003-constant-ecosystem-audience.md
#     docs/adr/0004-reinstate-l1-debug-client.md

locals {
  _hospital_files = fileset("${path.module}/../config/hospitals", "*.yaml")
  hospitals = {
    for f in local._hospital_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/hospitals/${f}"))
  }

  _hospital_l1_files = fileset("${path.module}/../config/hospitals-l1", "*.yaml")
  hospitals_l1 = {
    for f in local._hospital_l1_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/hospitals-l1/${f}"))
  }
}

# ---------------------------------------------------------------------------
# M2M clients — one per hospital, L2 (private_key_jwt)
# ---------------------------------------------------------------------------

resource "keycloak_openid_client" "m2m" {
  for_each = local.hospitals

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = each.key
  name      = each.value.org_display_name
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false

  client_authenticator_type = "client-jwt"

  extra_config = {
    "use.jwks.url" = "true"
    "jwks.url"     = each.value.jwks_url
    # RFC 9068 §2.1 — JWT access token header "typ" must be "at+jwt".
    "access.token.header.type.rfc9068" = "true"
  }
}

# ---------------------------------------------------------------------------
# Protocol mappers — org reference, FHIR context, and client_id (RFC 9068)
# ---------------------------------------------------------------------------

# RFC 9068 §2.2 requires a "client_id" claim distinct from "azp". Keycloak's
# built-in Client ID mapper names the claim "clientId" (camelCase), not
# "client_id" (see keycloak/keycloak#16329), so it's hardcoded here instead.
resource "keycloak_openid_hardcoded_claim_protocol_mapper" "client_id" {
  for_each = local.hospitals

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "client-id-mapper"

  claim_name       = "client_id"
  claim_value      = each.key
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

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

# Note: the primary (L2) client intentionally does NOT get an auth_level
# claim. Per ADR 0001 (reinstated by ADR 0004), a missing claim already
# implies "L2" — stamping "L2" explicitly here would be redundant and would
# add a new claim to every existing production token (a sandbox-parity
# divergence with no benefit). Only the L1 debug client below is stamped,
# since its presence is the actual exception to call out.

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
# Constant ecosystem audience (ADR 0003) — applied to every M2M client
#
# Always writes the realm issuer URL into aud, regardless of requested
# scopes. This is the default audience binding until RFC 8707 support in
# Keycloak is non-experimental.
# ---------------------------------------------------------------------------

resource "keycloak_openid_audience_protocol_mapper" "ecosystem_audience" {
  for_each = local.hospitals

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "ecosystem-audience-mapper"

  included_custom_audience = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}"

  add_to_id_token     = false
  add_to_access_token = true
}

# ---------------------------------------------------------------------------
# L1 debug clients — one per keycloak/config/hospitals-l1/{org_id}.yaml
# (ADR 0004). Independent of the L2 client for the same org_id: presence of
# this file is the only gate. Client secret is Keycloak-generated (not set
# here); see outputs.tf for how it's surfaced. Secret handling for these is
# deliberately relaxed (see ADR 0004) since L1 is a debug-only path, not the
# production integration path.
# ---------------------------------------------------------------------------

resource "keycloak_openid_client" "m2m_l1" {
  for_each = local.hospitals_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = "${each.key}--l1"
  name      = "${each.value.org_display_name} (L1 debug)"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false

  client_authenticator_type = "client-secret"

  extra_config = {
    # RFC 9068 §2.1 — JWT access token header "typ" must be "at+jwt".
    "access.token.header.type.rfc9068" = "true"
  }
}

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "client_id_l1" {
  for_each = local.hospitals_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "client-id-mapper"

  claim_name       = "client_id"
  claim_value      = "${each.key}--l1"
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "org_reference_l1" {
  for_each = local.hospitals_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "org-reference-mapper"

  claim_name       = "extensions.umzhconnect.organization_reference"
  claim_value      = each.value.org_reference
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "auth_level_l1" {
  for_each = local.hospitals_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "auth-level-mapper"

  claim_name       = "extensions.umzhconnect.auth_level"
  claim_value      = "L1"
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_generic_protocol_mapper" "fhir_context_l1" {
  for_each = local.hospitals_l1

  realm_id        = keycloak_realm.umzh_connect.id
  client_id       = keycloak_openid_client.m2m_l1[each.key].id
  name            = "fhir-context-mapper"
  protocol        = "openid-connect"
  protocol_mapper = "umzh-fhir-context-mapper"

  config = {
    "id.token.claim"       = "false"
    "access.token.claim"   = "true"
    "userinfo.token.claim" = "false"
  }
}

resource "keycloak_openid_audience_protocol_mapper" "ecosystem_audience_l1" {
  for_each = local.hospitals_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "ecosystem-audience-mapper"

  included_custom_audience = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}"

  add_to_id_token     = false
  add_to_access_token = true
}
