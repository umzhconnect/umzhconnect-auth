# Machine-to-machine clients
#
# Four clients, mirroring the sandbox realm:
#   placer-client / fulfiller-client          Level 1 (client_secret) - sandbox/PoC
#   placer-client-l2 / fulfiller-client-l2    Level 2 (private_key_jwt) - production baseline
#
# Every M2M client carries the same mapper set:
#   - org-reference-mapper  hardcoded extensions.umzhconnect.organization_reference
#                           (IG: set by the AS from the onboarding record)
#   - fhir-context-mapper   custom provider: RFC 9396 authorization_details
#                           (type umzh-connect-context) -> fhirContext claim
#   - tenant-mapper         sandbox routing hint (placer | fulfiller)
#   - realm-roles           service-account realm roles -> realm_roles claim

locals {
  # Scope sets per party (verbatim from the sandbox realm-export.json).
  placer_default_scopes = [
    "system/Task.cru",
    "system/ServiceRequest.rs",
    "system/Patient.r",
    "system/Condition.r",
    "system/MedicationStatement.r",
    "system/AllergyIntolerance.r",
    "system/Coverage.r",
    "system/Observation.r",
    "system/Procedure.r",
    "system/Immunization.r",
    "system/DiagnosticReport.r",
    "system/QuestionnaireResponse.cru",
    "system/ImagingStudy.r",
  ]

  fulfiller_default_scopes = [
    "system/Task.cru",
    "system/ServiceRequest.r",
    "system/Patient.r",
    "system/Condition.r",
    "system/MedicationStatement.r",
    "system/AllergyIntolerance.r",
    "system/Coverage.r",
    "system/Observation.r",
    "system/Procedure.r",
    "system/Immunization.r",
    "system/DiagnosticReport.r",
    "system/QuestionnaireResponse.cru",
    "system/ImagingStudy.r",
    "system/Organization.r",
    "system/Practitioner.r",
    "system/PractitionerRole.r",
  ]

  placer_optional_scopes = [
    "smart-task-write",
    "smart-servicerequest-read",
    "smart-clinical-read",
    "smart-questionnaire-write",
  ]

  fulfiller_optional_scopes = [
    "smart-task-write",
    "smart-servicerequest-read",
    "smart-clinical-read",
    "smart-patient-read",
    "smart-questionnaire-write",
  ]

  m2m_clients = {
    "placer-client" = {
      name            = "Placer (HospitalP) Machine Client"
      description     = "M2M client for HospitalP - Level 1 client credentials"
      level           = 1
      secret          = var.placer_client_secret
      jwks_url        = null
      tenant          = "placer"
      org_reference   = var.placer_org_reference
      role            = "placer"
      default_scopes  = local.placer_default_scopes
      optional_scopes = local.placer_optional_scopes
    }
    "fulfiller-client" = {
      name            = "Fulfiller (HospitalF) Machine Client"
      description     = "M2M client for HospitalF - Level 1 client credentials"
      level           = 1
      secret          = var.fulfiller_client_secret
      jwks_url        = null
      tenant          = "fulfiller"
      org_reference   = var.fulfiller_org_reference
      role            = "fulfiller"
      default_scopes  = local.fulfiller_default_scopes
      optional_scopes = local.fulfiller_optional_scopes
    }
    "placer-client-l2" = {
      name            = "Placer (HospitalP) Machine Client - Level 2"
      description     = "M2M client for HospitalP - private_key_jwt baseline"
      level           = 2
      secret          = null
      jwks_url        = var.placer_l2_jwks_url
      tenant          = "placer"
      org_reference   = var.placer_org_reference
      role            = "placer"
      default_scopes  = local.placer_default_scopes
      optional_scopes = local.placer_optional_scopes
    }
    "fulfiller-client-l2" = {
      name            = "Fulfiller (HospitalF) Machine Client - Level 2"
      description     = "M2M client for HospitalF - private_key_jwt baseline"
      level           = 2
      secret          = null
      jwks_url        = var.fulfiller_l2_jwks_url
      tenant          = "fulfiller"
      org_reference   = var.fulfiller_org_reference
      role            = "fulfiller"
      default_scopes  = local.fulfiller_default_scopes
      optional_scopes = local.fulfiller_optional_scopes
    }
  }
}

resource "keycloak_openid_client" "m2m" {
  for_each = local.m2m_clients

  realm_id    = keycloak_realm.umzh_connect.id
  client_id   = each.key
  name        = each.value.name
  description = each.value.description
  enabled     = true

  access_type                  = "CONFIDENTIAL"
  service_accounts_enabled     = true
  standard_flow_enabled        = false
  direct_access_grants_enabled = false

  # Level 1: client-secret | Level 2: client-jwt with keys fetched from the
  # party's published JWKS (SMART Backend Services discovery shape).
  client_authenticator_type = each.value.level == 2 ? "client-jwt" : "client-secret"
  client_secret             = each.value.secret

  extra_config = each.value.level == 2 ? {
    "use.jwks.url" = "true"
    "jwks.url"     = each.value.jwks_url
  } : {}
}

resource "keycloak_openid_client_default_scopes" "m2m" {
  for_each = local.m2m_clients

  realm_id       = keycloak_realm.umzh_connect.id
  client_id      = keycloak_openid_client.m2m[each.key].id
  default_scopes = each.value.default_scopes

  depends_on = [keycloak_openid_client_scope.system]
}

resource "keycloak_openid_client_optional_scopes" "m2m" {
  for_each = local.m2m_clients

  realm_id        = keycloak_realm.umzh_connect.id
  client_id       = keycloak_openid_client.m2m[each.key].id
  optional_scopes = each.value.optional_scopes

  depends_on = [keycloak_openid_client_scope.smart]
}

# Party realm role on the service account (drives the realm_roles claim).
resource "keycloak_openid_client_service_account_realm_role" "m2m" {
  for_each = local.m2m_clients

  realm_id                = keycloak_realm.umzh_connect.id
  service_account_user_id = keycloak_openid_client.m2m[each.key].service_account_user_id
  role                    = each.value.role

  depends_on = [keycloak_role.placer, keycloak_role.fulfiller]
}

# --- Protocol mappers ----------------------------------------------------------

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "org_reference" {
  for_each = local.m2m_clients

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

resource "keycloak_openid_hardcoded_claim_protocol_mapper" "tenant" {
  for_each = local.m2m_clients

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "tenant-mapper"

  claim_name       = "tenant"
  claim_value      = each.value.tenant
  claim_value_type = "String"

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

resource "keycloak_openid_user_realm_role_protocol_mapper" "realm_roles" {
  for_each = local.m2m_clients

  realm_id  = keycloak_realm.umzh_connect.id
  client_id = keycloak_openid_client.m2m[each.key].id
  name      = "realm-roles"

  claim_name       = "realm_roles"
  claim_value_type = "String"
  multivalued      = true

  add_to_id_token     = false
  add_to_access_token = true
  add_to_userinfo     = false
}

# Custom provider shipped in the Keycloak image (keycloak/mapper):
# maps RFC 9396 authorization_details of type "umzh-connect-context" to the
# SMART v2 fhirContext claim.
resource "keycloak_generic_protocol_mapper" "fhir_context" {
  for_each = local.m2m_clients

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
