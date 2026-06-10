export interface Config {
  port: number;
  /** Expected `iss` claim — the published (frontend) issuer URI. */
  issuer: string;
  /** Where to fetch the AS signature keys (backchannel URL inside compose). */
  jwksUri: string;
  /**
   * Expected `aud` claim (the protected FHIR API base URL per the IG).
   * When unset the audience check is reported but not enforced, because
   * Keycloak's default client_credentials audience is not the resource server.
   */
  expectedAudience?: string;
}

export function loadConfig(): Config {
  const issuer = process.env.ISSUER;
  if (!issuer) {
    throw new Error('ISSUER environment variable is required');
  }
  return {
    port: Number(process.env.PORT ?? 8086),
    issuer,
    jwksUri: process.env.JWKS_URI ?? `${issuer}/protocol/openid-connect/certs`,
    expectedAudience: process.env.EXPECTED_AUDIENCE || undefined,
  };
}
