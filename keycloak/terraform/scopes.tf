# SMART Backend Services client scopes — sourced from config/scopes.yaml.
#
# All custom scope definitions live in the YAML; this file is pure plumbing.
# To add, remove, or rename a scope, edit config/scopes.yaml and re-apply.

locals {
  _scopes_config = yamldecode(file("${path.module}/../config/scopes.yaml"))

  # Flat map of all scope definitions by name.
  all_scope_defs = { for s in local._scopes_config.scopes : s.name => s }
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

# No scope is ever included by default. Every scope is registered as
# optional on every hospital M2M client, so a caller only receives the
# scopes it explicitly requests via the token request's `scope` parameter —
# least privilege per request, not per client. default_scopes is pinned to
# an empty list (rather than omitting the resource) so Terraform actively
# clears any default-scope assignment Keycloak would otherwise leave on the
# client (its own realm-level defaults, or a stale assignment from before
# this scope model existed).

resource "keycloak_openid_client_default_scopes" "m2m" {
  for_each = local.clients_l2

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id

  default_scopes = []

  depends_on = [keycloak_openid_client_scope.smart]
}

resource "keycloak_openid_client_optional_scopes" "m2m" {
  for_each = local.clients_l2

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id

  # SMART optional scopes (from scopes.yaml). A scope not in this list cannot
  # be requested.
  optional_scopes = [for s in local._scopes_config.scopes : s.name]

  # Must apply after default_scopes clears — Keycloak rejects assigning a
  # scope as optional while it's still attached as a default scope, so the
  # two updates can't land in either order.
  depends_on = [keycloak_openid_client_scope.smart, keycloak_openid_client_default_scopes.m2m]
}

# Same scope assignment for L1 debug clients (ADR 0004) — a debug client
# should be a faithful stand-in for the real integration.

resource "keycloak_openid_client_default_scopes" "m2m_l1" {
  for_each = local.clients_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id

  default_scopes = []

  depends_on = [keycloak_openid_client_scope.smart]
}

resource "keycloak_openid_client_optional_scopes" "m2m_l1" {
  for_each = local.clients_l1

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m_l1[each.key].id

  optional_scopes = [for s in local._scopes_config.scopes : s.name]

  depends_on = [keycloak_openid_client_scope.smart, keycloak_openid_client_default_scopes.m2m_l1]
}
