# Packages the Terraform realm config so the k8s PostSync Job (in
# tch-umzh-connect-gitops) doesn't need read access to this repo's raw
# files. Baked-in files land under /src; the Job copies them onto its
# tfstate-persisting PVC before running terraform, so this image can be
# treated as read-only/immutable at every sync.
#
# Only the Terraform module is baked in. keycloak-config/ (scopes.yaml and
# clients/) is deployment config, owned and supplied solely by the
# deployment repo's configurator image layered on top of this one. This
# repo's clients are demo clients (some with committed private keys), and a
# baked default would silently survive the configurator's COPY, which merges
# rather than replaces. Without the configurator's scopes.yaml the apply
# fails loudly in scopes.tf instead of falling back to a default.
FROM hashicorp/terraform:1.15
COPY terraform /src/terraform
