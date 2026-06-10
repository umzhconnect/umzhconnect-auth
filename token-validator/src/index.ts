// Mock resource server for the UMZH Connect IG.
//
// Two faces:
//   POST /validate          detailed per-check validation report for any token
//   GET  /fhir/*            sample protected endpoints enforcing the IG rules
//                           (bearer JWT, SMART system scope, fhirContext gate)
//
// Dev/test aid only - NOT a production artifact.

import express, { type NextFunction, type Request, type Response } from 'express';
import type { JWTPayload } from 'jose';
import { loadConfig } from './config.js';
import { fhirContextOf, hasSystemScope, validateToken } from './validator.js';

const config = loadConfig();
const app = express();
app.use(express.json());

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      claims?: JWTPayload;
    }
  }
}

function bearerToken(req: Request): string | undefined {
  const header = req.headers.authorization;
  return header?.startsWith('Bearer ') ? header.slice('Bearer '.length) : undefined;
}

/** Verifies the bearer token and attaches its claims to the request. */
async function requireAuth(req: Request, res: Response, next: NextFunction): Promise<void> {
  const token = bearerToken(req);
  if (!token) {
    res.status(401).json({ error: 'missing bearer token' });
    return;
  }
  const report = await validateToken(token, config);
  if (!report.valid) {
    res.status(401).json({ error: 'token validation failed', report });
    return;
  }
  req.claims = report.claims;
  next();
}

/** IG scope check: token must grant `perm` on `resource` via a system scope. */
function requireSystemScope(resource: string, perm: string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    if (!hasSystemScope(req.claims!, resource, perm)) {
      res.status(403).json({
        error: `insufficient scope: system/${resource}.${perm} required`,
        scope: req.claims!.scope ?? '',
      });
      return;
    }
    next();
  };
}

/**
 * IG context gate: the requested resource must be (the root of) the workflow
 * context in the token's fhirContext claim. A real resource server walks the
 * full FHIR reference graph; this mock only matches the root reference.
 */
function requireFhirContext(referenceOf: (req: Request) => string) {
  return (req: Request, res: Response, next: NextFunction): void => {
    const wanted = referenceOf(req);
    const context = fhirContextOf(req.claims!);
    if (!context.some((c) => c.reference === wanted)) {
      res.status(403).json({
        error: `resource not in workflow context: token fhirContext does not cover ${wanted}`,
        fhirContext: context,
      });
      return;
    }
    next();
  };
}

// --- Routes -------------------------------------------------------------------

app.get('/healthz', (_req, res) => {
  res.json({ status: 'ok', issuer: config.issuer });
});

// Validation oracle: accepts the token via Authorization header or JSON body.
app.post('/validate', async (req, res) => {
  const token = bearerToken(req) ?? (typeof req.body?.token === 'string' ? req.body.token : undefined);
  if (!token) {
    res.status(400).json({ error: 'provide a token via Authorization: Bearer or {"token": "..."}' });
    return;
  }
  const report = await validateToken(token, config);
  res.status(report.valid ? 200 : 422).json(report);
});

// Non-context-gated read (IG: directory/definitional resources).
app.get('/fhir/Organization/:id', requireAuth, requireSystemScope('Organization', 'r'), (req, res) => {
  res.json({ resourceType: 'Organization', id: req.params.id, name: `Mock Organization ${req.params.id}` });
});

// Patient read: scope-gated only in this mock (real servers also enforce
// graph membership from the fhirContext root).
app.get('/fhir/Patient/:id', requireAuth, requireSystemScope('Patient', 'r'), (req, res) => {
  res.json({ resourceType: 'Patient', id: req.params.id, name: [{ family: 'Mock', given: ['Patient'] }] });
});

// ServiceRequest read: scope + context gate (the workflow root itself).
app.get(
  '/fhir/ServiceRequest/:id',
  requireAuth,
  requireSystemScope('ServiceRequest', 'r'),
  requireFhirContext((req) => `ServiceRequest/${req.params.id}`),
  (req, res) => {
    res.json({ resourceType: 'ServiceRequest', id: req.params.id, status: 'active', intent: 'order' });
  },
);

// Task create: requires the create permission.
app.post('/fhir/Task', requireAuth, requireSystemScope('Task', 'c'), (req, res) => {
  res.status(201).json({ resourceType: 'Task', id: 'mock-task-1', status: 'requested', ...req.body });
});

app.listen(config.port, () => {
  console.log(`token-validator listening on :${config.port}`);
  console.log(`  expected issuer: ${config.issuer}`);
  console.log(`  jwks uri:        ${config.jwksUri}`);
  console.log(`  audience check:  ${config.expectedAudience ?? 'reported only (EXPECTED_AUDIENCE unset)'}`);
});
