# =============================================================================
# tf-provider-mirror — a terraform image with the realm module's providers
# baked in as a FILESYSTEM MIRROR, so the keycloak-config Job's `terraform
# init` runs FULLY OFFLINE (no registry.terraform.io fetch → no proxy needed
# at apply time). Solves the provider-download proxy problem.
#
# Build on an amd64 host (context = repo ROOT — needs terraform/ AND this
# folder). On a non-amd64 build host, add --platform=linux/amd64.
#   docker build -f tf-provider-mirror/Dockerfile \
#     -t harbor-registry.io.usz.ch/prj-0011608-umzhc/tf-provider-mirror:1.15-mirror .
#
# BUILD-TIME needs registry egress (the download happens once, here, on a
# machine with proxy access). RUNTIME (in-cluster) needs none. Rebuild only
# when the providers pinned in terraform/.terraform.lock.hcl change.
# =============================================================================

# ---- Stage 1: download providers into a filesystem mirror (linux/amd64) ------
FROM hashicorp/terraform:1.15 AS mirror

# If your corporate proxy inspects TLS (MITM — e.g. fproxy.usz.ch), drop its
# CA PEM(s) into tf-provider-mirror/certs/ before building, so the provider
# downloads verify. Leave the dir empty otherwise (the .gitkeep keeps COPY happy).
COPY tf-provider-mirror/certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates 2>/dev/null || true

WORKDIR /module
# Only the provider requirements + lock are needed to mirror. Copying the whole
# module would drag in its fileset() calls that reference ../keycloak-config,
# which isn't present here. With the lock file present, `terraform providers
# mirror` pins EXACTLY the locked versions (keycloak 5.8.0, vault 4.8.0).
COPY terraform/versions.tf terraform/.terraform.lock.hcl ./
RUN terraform providers mirror -platform=linux_amd64 /providers

# ---- Stage 2: terraform image with the mirror + offline CLI config -----------
FROM hashicorp/terraform:1.15
# No `apk upgrade` here: the terraform:1.15 base is already nearly clean (only
# ~1 residual OS-package CVE), and an in-build apk fetch needs alpine-repo egress
# PLUS the MITM proxy CA — which fails (apk exit 99) behind a TLS-inspecting
# proxy. Keeping stage 2 network-free makes the build robust. To also clear that
# last OS CVE, add the CA before an upgrade:
#   COPY tf-provider-mirror/certs/ /usr/local/share/ca-certificates/
#   RUN update-ca-certificates 2>/dev/null || true; apk --no-cache upgrade
COPY --from=mirror /providers /providers
COPY tf-provider-mirror/terraformrc /etc/terraformrc
# Every terraform invocation now installs providers ONLY from /providers.
ENV TF_CLI_CONFIG_FILE=/etc/terraformrc
