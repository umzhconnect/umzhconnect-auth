# SMART Backend Services client scopes — sourced from config/scopes.yaml.
#
# All custom scope definitions live in the YAML; this file is pure plumbing.
# To add, remove, or rename a scope, edit config/scopes.yaml and re-apply.

locals {
  _scopes_config = yamldecode(file("${path.module}/../config/scopes.yaml"))

  # Flat map of all scope definitions (default + optional) by name.
  all_scope_defs = {
    for s in concat(
      local._scopes_config.default_scopes,
      local._scopes_config.optional_scopes
    ) : s.name => s
  }
}

resource "keycloak_openid_client_scope" "smart" {
  for_each = local.all_scope_defs

  realm_id    = keycloak_realm.umzh_connect.id
  name        = each.key
  description = each.value.description

  # Scope name appears in the token's `scope` claim — required for SMART
  # resource servers to enforce per-resource permissions.
  include_in_token_scope = true
  gui_order              = 1
  consent_screen_text    = ""
}

# Assign default scopes to every M2M hospital client.
# These scopes are always present in issued tokens regardless of what the
# caller requests. Optional scopes are registered in KC but not auto-assigned.

resource "keycloak_openid_client_default_scopes" "m2m" {
  for_each = local.hospitals

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id

  default_scopes = [for s in local._scopes_config.default_scopes : s.name]

  depends_on = [keycloak_openid_client_scope.smart]
}

resource "keycloak_openid_client_optional_scopes" "m2m" {
  for_each = local.hospitals

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id

  # SMART optional scopes (from scopes.yaml). A scope not in this list cannot
  # be requested.
  optional_scopes = [for s in local._scopes_config.optional_scopes : s.name]

  depends_on = [keycloak_openid_client_scope.smart]
}

# Same default/optional scope assignment for L1 debug clients (ADR 0004) —
# a debug client should be a faithful stand-in for the real integration.

resource "keycloak_openid_client_default_scopes" "m2m_l1" {
  for_each = local.hospitals_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id

  default_scopes = [for s in local._scopes_config.default_scopes : s.name]

  depends_on = [keycloak_openid_client_scope.smart]
}

resource "keycloak_openid_client_optional_scopes" "m2m_l1" {
  for_each = local.hospitals_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id

  optional_scopes = [for s in local._scopes_config.optional_scopes : s.name]

  depends_on = [keycloak_openid_client_scope.smart]
}
