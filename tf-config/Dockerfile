# Packages the Terraform realm config so the k8s PostSync Job (in
# tch-umzh-connect-gitops) doesn't need read access to this repo's raw
# files. Baked-in files land under /src; the Job copies them onto its
# tfstate-persisting PVC before running terraform, so this image can be
# treated as read-only/immutable at every sync.
FROM hashicorp/terraform:1.9
COPY terraform /src/terraform
COPY keycloak-config /src/keycloak-config
