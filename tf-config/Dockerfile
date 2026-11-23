# Packages the Terraform realm module so the k8s PostSync Job (in
# tch-umzh-connect-gitops) doesn't need read access to this repo's raw
# files. Baked-in files land under /src; the Job copies them onto its
# tfstate-persisting PVC before running terraform, so this image can be
# treated as read-only/immutable at every sync.
#
# Contents: terraform CLI + the locked providers as an offline filesystem
# mirror + the Terraform module. Nothing else:
#
# - Providers are baked in (same mechanism as tf-provider-mirror/), so the
#   Job's `terraform init` runs fully offline — no registry.terraform.io
#   fetch, no proxy needed at apply time.
# - keycloak-config/ (scopes.yaml and clients/) is deployment config, owned
#   and supplied solely by the deployment repo (configurator image layered on
#   top, or mounted). This repo's clients are demo clients (some with
#   committed private keys), and a baked default would silently survive the
#   configurator's COPY, which merges rather than replaces. Without the
#   deployment's scopes.yaml the apply fails loudly in scopes.tf.
#
# Build context = repo ROOT. Built for linux/amd64 (CI default); the mirror
# holds linux_amd64 providers only, so on another host add
# --platform=linux/amd64.

# ---- Stage 1: download the locked providers into a filesystem mirror -------
FROM hashicorp/terraform:1.15 AS mirror
# Behind a TLS-inspecting proxy, drop its CA PEM(s) into
# tf-provider-mirror/certs/ before building (see tf-provider-mirror/Dockerfile).
COPY tf-provider-mirror/certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates 2>/dev/null || true
WORKDIR /module
# The lock file pins EXACTLY the locked provider versions and hashes.
COPY terraform/versions.tf terraform/.terraform.lock.hcl ./
RUN terraform providers mirror -platform=linux_amd64 /providers

# ---- Stage 2: offline terraform + module ----------------------------------
FROM hashicorp/terraform:1.15
COPY --from=mirror /providers /providers
COPY tf-provider-mirror/terraformrc /etc/terraformrc
# Every terraform invocation installs providers ONLY from /providers.
ENV TF_CLI_CONFIG_FILE=/etc/terraformrc
# Module source and lock file only — never a local .terraform/ dir or
# terraform.tfstate (which holds generated L1 client secrets) from the
# build host.
COPY terraform/*.tf terraform/.terraform.lock.hcl /src/terraform/
