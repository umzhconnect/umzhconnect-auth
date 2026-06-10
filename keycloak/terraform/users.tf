# Sandbox drop-in parity only: the umzhconnect-sandbox web app (React SPA,
# PKCE) and its demo users. Not part of the M2M authorization model the IG
# defines - safe to drop for a pure auth-server deployment.

resource "keycloak_openid_client" "web_app" {
  realm_id    = keycloak_realm.umzh_connect.id
  client_id   = "web-app"
  name        = "UMZH Connect Sandbox Web App"
  description = "React SPA for the sandbox UI"
  enabled     = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  direct_access_grants_enabled = true
  service_accounts_enabled     = false

  root_url            = var.web_app_url
  base_url            = "/"
  valid_redirect_uris = ["${var.web_app_url}/*"]
  web_origins         = [var.web_app_url, "http://localhost:8080"]
}

resource "keycloak_openid_client_optional_scopes" "web_app" {
  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.web_app.id

  optional_scopes = [
    "smart-patient-read",
    "smart-task-write",
    "smart-servicerequest-read",
    "smart-clinical-read",
    "smart-questionnaire-write",
  ]

  depends_on = [keycloak_openid_client_scope.smart]
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "web_app_realm_roles" {
  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.web_app.id
  name      = "realm-roles"

  claim_name       = "realm_roles"
  claim_value_type = "String"
  multivalued      = true

  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

# --- Demo users -----------------------------------------------------------------

locals {
  demo_users = {
    "placer-user" = {
      email      = "placer@hospitalp.example.org"
      first_name = "Hans"
      last_name  = "Muster"
      password   = "placer123"
      roles      = ["placer"]
    }
    "fulfiller-user" = {
      email      = "fulfiller@hospitalf.example.org"
      first_name = "Anna"
      last_name  = "Schmidt"
      password   = "fulfiller123"
      roles      = ["fulfiller"]
    }
    "admin-user" = {
      email      = "admin@umzh.example.org"
      first_name = "Admin"
      last_name  = "User"
      password   = "admin123"
      roles      = ["admin", "placer", "fulfiller"]
    }
  }
}

resource "keycloak_user" "demo" {
  for_each = local.demo_users

  realm_id       = keycloak_realm.umzh_connect.id
  username       = each.key
  email          = each.value.email
  first_name     = each.value.first_name
  last_name      = each.value.last_name
  enabled        = true
  email_verified = true

  initial_password {
    value     = each.value.password
    temporary = false
  }
}

resource "keycloak_user_roles" "demo" {
  for_each = local.demo_users

  realm_id = keycloak_realm.umzh_connect.id
  user_id  = keycloak_user.demo[each.key].id
  role_ids = [for r in each.value.roles : {
    "placer"    = keycloak_role.placer.id
    "fulfiller" = keycloak_role.fulfiller.id
    "admin"     = keycloak_role.admin.id
  }[r]]
}
