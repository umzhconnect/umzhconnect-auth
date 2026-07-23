# Machine-to-machine clients — one per hospital, L2 (private_key_jwt) by
# default, plus an optional L1 (client_secret) debug client per hospital.
#
# Every client file carries its own client_id and auth_level — Terraform
# never derives either from a filename. Filenames are a documentation
# convention only (recommended: name the file after client_id).
#
# L2 clients live in keycloak/config/clients-l2/*.yaml. A hospital with no
# such file has no L2 KC client and cannot obtain tokens via the standard
# path.
#
# L1 debug clients live in keycloak/config/clients-l1/*.yaml and are
# entirely independent of the L2 client for the same hospital — a hospital
# may have an L1 file, an L2 file, both, or neither. L1 exists for hospitals
# to debug connectivity (firewalls, routing, JWKS reachability) before or
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
  _clients_l2_files = fileset("${path.module}/../config/clients-l2", "*.yaml")
  _clients_l2_list  = [for f in local._clients_l2_files : yamldecode(file("${path.module}/../config/clients-l2/${f}"))]
  clients_l2        = { for c in local._clients_l2_list : c.client_id => c }

  _clients_l1_files = fileset("${path.module}/../config/clients-l1", "*.yaml")
  _clients_l1_list  = [for f in local._clients_l1_files : yamldecode(file("${path.module}/../config/clients-l1/${f}"))]
  # Raw contents of every config/clients-l1/*.yaml file, regardless of
  # allow_l1_debug_clients — used by the check block below to warn about
  # files that exist but are being ignored.
  clients_l1_all = { for c in local._clients_l1_list : c.client_id => c }
  # Actually provisioned L1 clients — empty unless allow_l1_debug_clients is
  # explicitly true, so a clients-l1/*.yaml file present without that
  # opt-in is silently ignored (with a warning) rather than provisioned or
  # failing the apply. See the "L1 debug clients" section below.
  clients_l1 = var.allow_l1_debug_clients ? local.clients_l1_all : {}
}

# Warns (does not fail apply) when config/clients-l1/ has file(s) but
# allow_l1_debug_clients is false — those files are being ignored, not
# provisioned. Set allow_l1_debug_clients=true to enable them (see ADR 0004).
check "l1_debug_clients_ignored" {
  assert {
    condition     = var.allow_l1_debug_clients || length(local.clients_l1_all) == 0
    error_message = "config/clients-l1/ contains ${length(local.clients_l1_all)} file(s) (${join(", ", keys(local.clients_l1_all))}) but allow_l1_debug_clients=false — these L1 debug clients are being ignored, not provisioned. Set allow_l1_debug_clients=true to enable them (see ADR 0004, docs/adr/0004-reinstate-l1-debug-client.md)."
  }
}

# ---------------------------------------------------------------------------
# M2M clients — one per hospital, L2 (private_key_jwt)
# ---------------------------------------------------------------------------

resource "keycloak_openid_client" "m2m" {
  for_each = local.clients_l2

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = each.key
  name      = each.value.client_name
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

  lifecycle {
    precondition {
      condition     = each.value.auth_level == "L2"
      error_message = "config/clients-l2/ file for client_id \"${each.key}\" has auth_level=\"${each.value.auth_level}\", expected \"L2\"."
    }
  }
}

# ---------------------------------------------------------------------------
# Protocol mappers — org reference, FHIR context, and client_id (RFC 9068)
# ---------------------------------------------------------------------------

# RFC 9068 §2.2 requires a "client_id" claim distinct from "azp". Keycloak's
# built-in Client ID mapper names the claim "clientId" (camelCase), not
# "client_id" (see keycloak/keycloak#16329), so it's hardcoded here instead.
resource "keycloak_openid_hardcoded_claim_protocol_mapper" "client_id" {
  for_each = local.clients_l2

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
  for_each = local.clients_l2

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "org-reference-mapper"

  claim_name       = "extensions.umzhconnect.organization_reference"
  claim_value      = each.value.organization_reference
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

# auth_level is a required claim on every M2M client — see ADR 0004. Explicit
# on both L1 and L2 (rather than "absence implies L2") so resource servers
# always have a claim to check, with no ambiguity if a token is missing it
# for an unrelated reason. Any future L3 client must stamp "L3" here too.
resource "keycloak_openid_hardcoded_claim_protocol_mapper" "auth_level" {
  for_each = local.clients_l2

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "auth-level-mapper"

  claim_name       = "extensions.umzhconnect.auth_level"
  claim_value      = each.value.auth_level
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_generic_protocol_mapper" "fhir_context" {
  for_each = local.clients_l2

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
  for_each = local.clients_l2

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "ecosystem-audience-mapper"

  included_custom_audience = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}"

  add_to_id_token     = false
  add_to_access_token = true
}

# ---------------------------------------------------------------------------
# L1 debug clients — one per keycloak/config/clients-l1/*.yaml (ADR 0004).
# Independent of the L2 client for the same hospital. Client secret is
# Keycloak-generated (not set here); see outputs.tf for how it's surfaced.
# Secret handling for these is deliberately relaxed (see ADR 0004) since L1
# is a debug-only path, not the production integration path.
#
# local.clients_l1 above is already gated on var.allow_l1_debug_clients
# (empty unless true), so these resources simply have zero instances — and
# thus create nothing — when the flag is off. A clients-l1/*.yaml file
# present without the opt-in is ignored, not applied and not a hard failure;
# see the "l1_debug_clients_ignored" check block above for the warning.
# ---------------------------------------------------------------------------

resource "keycloak_openid_client" "m2m_l1" {
  for_each = local.clients_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = each.key
  name      = "${each.value.client_name} (L1 debug)"
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

  lifecycle {
    precondition {
      condition     = each.value.auth_level == "L1"
      error_message = "config/clients-l1/ file for client_id \"${each.key}\" has auth_level=\"${each.value.auth_level}\", expected \"L1\"."
    }
  }
}

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "client_id_l1" {
  for_each = local.clients_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "client-id-mapper"

  claim_name       = "client_id"
  claim_value      = each.key
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "org_reference_l1" {
  for_each = local.clients_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "org-reference-mapper"

  claim_name       = "extensions.umzhconnect.organization_reference"
  claim_value      = each.value.organization_reference
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "auth_level_l1" {
  for_each = local.clients_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "auth-level-mapper"

  claim_name       = "extensions.umzhconnect.auth_level"
  claim_value      = each.value.auth_level
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_generic_protocol_mapper" "fhir_context_l1" {
  for_each = local.clients_l1

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
  for_each = local.clients_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id
  name      = "ecosystem-audience-mapper"

  included_custom_audience = "${var.keycloak_url}/realms/${keycloak_realm.umzh_connect.realm}"

  add_to_id_token     = false
  add_to_access_token = true
}
