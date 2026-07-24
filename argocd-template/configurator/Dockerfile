# Layers this deployment's client/scope config on top of the "tf-config"
# image (Terraform module baked in at /src/terraform by your own
# tf-config/Dockerfile — see this repo's tf-config/Dockerfile for the
# pattern). Overwriting /src/config here means the keycloak-config Job
# never needs a ConfigMap: everything Terraform reads is already in this
# image, and onboarding a client is "add a file here, rebuild" rather than
# a second kustomization.yaml edit.
#
# This is also where deployment-specific clients live that shouldn't be in
# your source repo's own config/ (e.g. a throwaway test client for this
# environment only) — the COPY below fully overwrites /src/config, so this
# image's keycloak-config/ is the final word on what gets provisioned.
FROM ghcr.io/example-org/example-app-tf-config
COPY keycloak-config/. /src/config
