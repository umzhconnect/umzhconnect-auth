# =============================================================================
# UMZH Connect Authorization Server image
#
# Keycloak + the FhirContextMapper provider (RFC 9396 authorization_details
# -> SMART v2 fhirContext claim). This is the production-bound artifact;
# realm configuration is applied separately via Terraform (local dev) or a
# config snapshot (deployment, later).
#
# Mapper source ported from umzhconnect/umzhconnect-sandbox (Apache-2.0).
# =============================================================================

# ---- Stage 1: build the FhirContextMapper provider JAR ----------------------
FROM maven:3.9-eclipse-temurin-17 AS mapper-build
WORKDIR /build
COPY mapper/pom.xml ./
RUN mvn -B -q dependency:go-offline
COPY mapper/src ./src
RUN mvn -B -q package -DskipTests

# ---- Stage 2: augment Keycloak with the provider and pre-build --------------
FROM quay.io/keycloak/keycloak:26.6.3 AS builder
COPY --from=mapper-build /build/target/umzh-fhir-context-mapper-*.jar /opt/keycloak/providers/
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true
RUN /opt/keycloak/bin/kc.sh build

# ---- Final image -------------------------------------------------------------
FROM quay.io/keycloak/keycloak:26.6.3 AS prodimage
COPY --from=builder /opt/keycloak /opt/keycloak
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
# Local dev (docker-compose) overrides this with `start-dev`.
CMD ["start", "--optimized"]
