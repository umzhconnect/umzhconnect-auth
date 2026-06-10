# Client scopes
#
# Two families, both taken verbatim from the sandbox realm:
#  - system/<Resource>.<perms>  SMART on FHIR v2 system scopes (M2M), the
#    normative scope syntax of the IG
#  - smart-*                    coarse-grained user-facing scopes used by the
#    sandbox web app's consent screen

locals {
  # SMART system scopes (scope name only; permissions encoded in the name)
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

  smart_scopes = {
    "smart-patient-read" = {
      description  = "SMART on FHIR: Read patient data"
      consent_text = "Read patient demographic data"
    }
    "smart-task-write" = {
      description  = "SMART on FHIR: Create/update tasks"
      consent_text = "Create and update task resources"
    }
    "smart-servicerequest-read" = {
      description  = "SMART on FHIR: Read service requests"
      consent_text = "Read service request data"
    }
    "smart-clinical-read" = {
      description  = "SMART on FHIR: Read clinical resources (conditions, medications, allergies, etc.)"
      consent_text = "Read clinical data (conditions, medications, allergies)"
    }
    "smart-questionnaire-write" = {
      description  = "SMART on FHIR: Create/update questionnaire responses"
      consent_text = "Create and update questionnaire responses"
    }
  }
}

resource "keycloak_openid_client_scope" "system" {
  for_each = toset(local.system_scopes)

  realm_id               = keycloak_realm.umzh_connect.id
  name                   = each.value
  include_in_token_scope = true
}

resource "keycloak_openid_client_scope" "smart" {
  for_each = local.smart_scopes

  realm_id               = keycloak_realm.umzh_connect.id
  name                   = each.key
  description            = each.value.description
  consent_screen_text    = each.value.consent_text
  include_in_token_scope = true
}
