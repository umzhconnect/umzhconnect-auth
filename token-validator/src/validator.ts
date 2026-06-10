import {
  createRemoteJWKSet,
  decodeJwt,
  decodeProtectedHeader,
  jwtVerify,
  type JWTPayload,
} from 'jose';
import type { Config } from './config.js';

export type CheckStatus = 'pass' | 'fail' | 'warn' | 'skipped';

export interface Check {
  name: string;
  status: CheckStatus;
  detail: string;
}

export interface ValidationReport {
  valid: boolean;
  checks: Check[];
  claims?: JWTPayload;
}

const ALLOWED_ALGS = ['RS256', 'ES256'];

/** SMART access tokens per the IG should be short-lived (~5 minutes). */
const MAX_LIFETIME_SECONDS = 360;

export interface FhirContextEntry {
  reference?: string;
}

export function scopesOf(claims: JWTPayload): string[] {
  return typeof claims.scope === 'string' ? claims.scope.split(' ').filter(Boolean) : [];
}

/**
 * SMART v2 system scope check: `system/<Resource>.<perms>` grants `perm`
 * (one of c/r/u/d/s) on `resource` if the perms string contains it.
 */
export function hasSystemScope(claims: JWTPayload, resource: string, perm: string): boolean {
  return scopesOf(claims).some((s) => {
    const match = /^system\/([A-Za-z]+)\.([cruds]+)$/.exec(s);
    return match !== null && match[1] === resource && match[2].includes(perm);
  });
}

export function fhirContextOf(claims: JWTPayload): FhirContextEntry[] {
  return Array.isArray(claims.fhirContext) ? (claims.fhirContext as FhirContextEntry[]) : [];
}

export function organizationReferenceOf(claims: JWTPayload): string | undefined {
  const extensions = claims.extensions as
    | { umzhconnect?: { organization_reference?: string } }
    | undefined;
  return extensions?.umzhconnect?.organization_reference;
}

/**
 * Validates an access token against the UMZH Connect IG security spec and
 * returns a detailed per-check report (useful as a correctness oracle while
 * developing clients and the Keycloak configuration).
 */
export async function validateToken(token: string, config: Config): Promise<ValidationReport> {
  const checks: Check[] = [];
  const jwks = createRemoteJWKSet(new URL(config.jwksUri));

  let claims: JWTPayload;
  try {
    claims = decodeJwt(token);
    const header = decodeProtectedHeader(token);
    checks.push({ name: 'format', status: 'pass', detail: 'well-formed JWT' });
    if (header.alg && ALLOWED_ALGS.includes(header.alg)) {
      checks.push({ name: 'algorithm', status: 'pass', detail: `alg=${header.alg}` });
    } else {
      checks.push({
        name: 'algorithm',
        status: 'fail',
        detail: `alg=${header.alg ?? 'none'}; IG requires RS256 or ES256`,
      });
    }
  } catch (err) {
    checks.push({ name: 'format', status: 'fail', detail: `not a decodable JWT: ${String(err)}` });
    return { valid: false, checks };
  }

  // Signature, issuer, expiry (and audience when configured) in one pass.
  try {
    await jwtVerify(token, jwks, {
      issuer: config.issuer,
      algorithms: ALLOWED_ALGS,
      ...(config.expectedAudience ? { audience: config.expectedAudience } : {}),
    });
    checks.push({ name: 'signature', status: 'pass', detail: `verified against ${config.jwksUri}` });
    checks.push({ name: 'issuer', status: 'pass', detail: `iss=${claims.iss}` });
    checks.push({ name: 'expiry', status: 'pass', detail: `exp=${claims.exp}` });
  } catch (err) {
    checks.push({
      name: 'verification',
      status: 'fail',
      detail: `signature/issuer/expiry/audience verification failed: ${String(err)}`,
    });
    return { valid: false, checks, claims };
  }

  if (config.expectedAudience) {
    checks.push({ name: 'audience', status: 'pass', detail: `aud=${JSON.stringify(claims.aud)}` });
  } else {
    checks.push({
      name: 'audience',
      status: 'skipped',
      detail: `aud=${JSON.stringify(claims.aud)}; set EXPECTED_AUDIENCE to enforce (IG: aud must be the target FHIR API base URL)`,
    });
  }

  // Token lifetime: IG/SMART Backend Services recommend short-lived tokens.
  if (typeof claims.exp === 'number' && typeof claims.iat === 'number') {
    const lifetime = claims.exp - claims.iat;
    checks.push({
      name: 'lifetime',
      status: lifetime <= MAX_LIFETIME_SECONDS ? 'pass' : 'warn',
      detail: `${lifetime}s (recommended <= 300s)`,
    });
  }

  // SMART system scopes
  const scopes = scopesOf(claims);
  const systemScopes = scopes.filter((s) => s.startsWith('system/'));
  checks.push({
    name: 'scope',
    status: systemScopes.length > 0 ? 'pass' : 'warn',
    detail:
      systemScopes.length > 0
        ? `system scopes: ${systemScopes.join(' ')}`
        : `no system/* scopes present (scope="${claims.scope ?? ''}")`,
  });

  // extensions.umzhconnect.organization_reference (IG: set by the AS from the
  // onboarding record; resource servers use it for counter-party entitlement)
  const orgRef = organizationReferenceOf(claims);
  checks.push({
    name: 'organization_reference',
    status: orgRef ? 'pass' : 'warn',
    detail: orgRef ?? 'extensions.umzhconnect.organization_reference missing',
  });

  // fhirContext (RFC 9396 authorization_details -> workflow context binding).
  // Optional at token level: tokens without context can only reach
  // non-context-gated resources.
  const context = fhirContextOf(claims);
  checks.push({
    name: 'fhirContext',
    status: context.length > 0 ? 'pass' : 'skipped',
    detail:
      context.length > 0
        ? `context roots: ${context.map((c) => c.reference).join(', ')}`
        : 'no fhirContext claim (token not bound to a workflow context)',
  });

  // realm_roles (sandbox parity: placer | fulfiller drives gateway routing)
  const roles = Array.isArray(claims.realm_roles) ? (claims.realm_roles as string[]) : [];
  const partyRoles = roles.filter((r) => r === 'placer' || r === 'fulfiller');
  checks.push({
    name: 'realm_roles',
    status: partyRoles.length > 0 ? 'pass' : 'warn',
    detail: partyRoles.length > 0 ? `party roles: ${partyRoles.join(', ')}` : 'no placer/fulfiller role',
  });

  const valid = checks.every((c) => c.status !== 'fail');
  return { valid, checks, claims };
}
