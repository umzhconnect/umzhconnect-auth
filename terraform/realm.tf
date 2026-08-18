# Realm contract mirrors the umzhconnect-sandbox realm-export.json so this
# Keycloak is a drop-in replacement for the sandbox's `keycloak` service.

resource "keycloak_realm" "umzh_connect" {
  realm        = "umzh-connect"
  display_name = "UMZH Connect"
  enabled      = true

  # Local/dev only; the production snapshot enforces TLS at the edge.
  ssl_required = "none"

  # IG / SMART Backend Services: short-lived access tokens (5 minutes).
  access_token_lifespan    = "5m0s"
  sso_session_idle_timeout = "30m0s"
  sso_session_max_lifespan = "10h0m0s"
}

resource "keycloak_role" "admin" {
  realm_id    = keycloak_realm.umzh_connect.id
  name        = "admin"
  description = "Sandbox administrator"
}
