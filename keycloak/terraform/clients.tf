# Machine-to-machine clients — one per hospital, L2 (private_key_jwt) only.
#
# Hospital identity lives in keycloak/config/hospitals/{org_id}.yaml.
# A hospital with no YAML file has no KC client and cannot obtain tokens.
#
# RFC 8707 resource indicators (KC experimental feature `resource-indicators`):
# - Each hospital also gets a lightweight fhir-server client whose only purpose
#   is to register that hospital's FHIR base URL as a known resource_url.
# - allowed_targets in the YAML controls which cross-hospital audience mappers
#   are created (explicit allow-list; no implicit access).
# - Callers include resource=<fhir_url> in token requests to bind aud to that
#   specific FHIR server.
#
# See docs/adr/0002-one-client-per-hospital.md
#     docs/adr/0004-rfc8707-resource-indicators.md

locals {
  _hospital_files = fileset("${path.module}/../config/hospitals", "*.yaml")
  hospitals = {
    for f in local._hospital_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/../config/hospitals/${f}"))
  }

  # All (source, target) pairs declared in allowed_targets — explicit allow-list.
  audience_pairs = {
    for pair in flatten([
      for source_key, source in local.hospitals : [
        for target_key in lookup(source, "allowed_targets", []) : {
          source = source_key
          target = target_key
        }
      ]
    ]) : "${pair.source}->${pair.target}" => pair
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
    "use.jwks.url"                         = "true"
    "jwks.url"                             = each.value.jwks_url
    # Workaround for KC bug keycloak/keycloak#50251: client_credentials flow
    # throws an NPE when resource-indicators is enabled unless this is set.
    "client_credentials.use_refresh_token" = "true"
  }
}

# ---------------------------------------------------------------------------
# FHIR resource-server registrations (RFC 8707)
#
# These are not OAuth clients in the traditional sense — they carry no flows
# and no service account. Their sole purpose is to register each hospital's
# FHIR base URL as a known resource_url so KC can match the `resource=`
# parameter in token requests and validate unknown targets with invalid_target.
# ---------------------------------------------------------------------------

resource "keycloak_openid_client" "fhir_resource_server" {
  for_each = local.hospitals

  realm_id    = keycloak_realm.umzh_connect.id
  client_id   = "${each.key}-fhir-server"
  name        = "${each.value.org_display_name} FHIR Resource Server"
  description = "RFC 8707 resource-server registration — not an OAuth client"
  enabled     = true

  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = false
  standard_flow_enabled        = false
  direct_access_grants_enabled = false

  extra_config = {
    "resource_url" = each.value.fhir_url
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
# Cross-hospital audience mappers (RFC 8707 explicit allow-list)
#
# Each pair declared in allowed_targets gets an oidc-audience-mapper that
# adds the target's fhir-server client ID to the token aud when the caller
# sends resource=<target fhir_url>. Without this mapper the resource-
# indicators post-processor rejects the request with invalid_target even
# if the resource_url is registered.
# ---------------------------------------------------------------------------

resource "keycloak_openid_audience_protocol_mapper" "cross_hospital" {
  for_each = local.audience_pairs

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.value.source].id
  name      = "aud-${each.value.target}-fhir-server"

  included_client_audience = "${each.value.target}-fhir-server"

  add_to_id_token     = false
  add_to_access_token = true

  # fhir_resource_server clients must exist before the provider validates
  # included_client_audience against the live KC API. The bare string
  # "${each.value.target}-fhir-server" creates no implicit dependency edge.
  depends_on = [keycloak_openid_client.fhir_resource_server]
}
