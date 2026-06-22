# SMART on FHIR v2 system scopes — the full vocabulary for this network.
#
# These are realm-level client scope definitions. KC client default_scopes
# reference them by name; clients only receive the subset listed in their
# YAML config (keycloak/config/clients/<hospital>.yaml).
#
# smart-* user-facing consent screen scopes are removed — this is a pure
# M2M realm with no user flows.

locals {
  system_scopes = [
    "system/Task.cru",
    "system/ServiceRequest.rs",
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
}

resource "keycloak_openid_client_scope" "system" {
  for_each = toset(local.system_scopes)

  realm_id               = keycloak_realm.umzh_connect.id
  name                   = each.value
  include_in_token_scope = true
}
