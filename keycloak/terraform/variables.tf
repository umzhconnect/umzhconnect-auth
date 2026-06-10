variable "keycloak_url" {
  description = "Base URL of the Keycloak instance to configure (backchannel URL when run inside docker-compose)."
  type        = string
  default     = "http://localhost:8180"
}

variable "keycloak_admin_username" {
  description = "Keycloak bootstrap admin username."
  type        = string
  default     = "admin"
}

variable "keycloak_admin_password" {
  description = "Keycloak bootstrap admin password."
  type        = string
  default     = "admin"
  sensitive   = true
}

# --- Level 1 (client_secret) demo credentials --------------------------------
# Identical to the umzhconnect-sandbox so the realm is a drop-in replacement.

variable "placer_client_secret" {
  description = "Level 1 shared secret for the placer M2M client (demo value, sandbox parity)."
  type        = string
  default     = "placer-secret-2025"
  sensitive   = true
}

variable "fulfiller_client_secret" {
  description = "Level 1 shared secret for the fulfiller M2M client (demo value, sandbox parity)."
  type        = string
  default     = "fulfiller-secret-2025"
  sensitive   = true
}

# --- Level 2 (private_key_jwt) JWKS locations --------------------------------
# Where Keycloak fetches each client's public keys to verify client assertions.
# Local stack default: the jwks-server compose service.
# Sandbox drop-in:     http://apisix-placer-external:9080/jwks.json and
#                      http://apisix-fulfiller-external:9080/jwks.json

variable "placer_l2_jwks_url" {
  description = "JWKS URL for the placer Level 2 client (private_key_jwt)."
  type        = string
  default     = "http://jwks-server/placer-l2.jwks.json"
}

variable "fulfiller_l2_jwks_url" {
  description = "JWKS URL for the fulfiller Level 2 client (private_key_jwt)."
  type        = string
  default     = "http://jwks-server/fulfiller-l2.jwks.json"
}

# --- Organization references --------------------------------------------------
# Registry URLs embedded by the AS into every token as
# extensions.umzhconnect.organization_reference (IG: set from the onboarding
# record, never client-supplied). Defaults mirror the sandbox registry.

variable "placer_org_reference" {
  description = "Canonical Organization URL for the placer (HospitalP)."
  type        = string
  default     = "http://localhost:8084/fhir/Organization/HospitalP"
}

variable "fulfiller_org_reference" {
  description = "Canonical Organization URL for the fulfiller (HospitalF)."
  type        = string
  default     = "http://localhost:8084/fhir/Organization/HospitalF"
}

# --- Web app (sandbox drop-in parity only) ------------------------------------

variable "web_app_url" {
  description = "Base URL of the sandbox web app (PKCE client redirect target)."
  type        = string
  default     = "http://localhost:3000"
}
