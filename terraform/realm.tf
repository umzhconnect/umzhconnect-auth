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

# IG: "A token request carries at most one workflow context; otherwise the AS
# MUST reject it with invalid_authorization_details" (RFC 9396 §5). A protocol
# mapper cannot fail a token request, so the check runs as a client policy
# executor (umzh-context-executor, keycloak/mapper) on every client_credentials
# token request. It also rejects malformed JSON, unknown types and a missing
# identifier. See docs/adr/0005-context-authorization-details-claim.md.
resource "keycloak_realm_client_policy_profile" "umzh_context" {
  realm_id    = keycloak_realm.umzh_connect.id
  name        = "umzh-context"
  description = "Reject invalid RFC 9396 authorization_details (UMZH Connect context)"

  executor {
    name = "umzh-context-executor"
  }
}

resource "keycloak_realm_client_policy_profile_policy" "umzh_context" {
  realm_id    = keycloak_realm.umzh_connect.id
  name        = "umzh-context"
  description = "Applies the umzh-context profile to every client"
  enabled     = true
  profiles    = [keycloak_realm_client_policy_profile.umzh_context.name]

  condition {
    name = "any-client"
  }
}

resource "keycloak_role" "admin" {
  realm_id    = keycloak_realm.umzh_connect.id
  name        = "admin"
  description = "Sandbox administrator"
}
