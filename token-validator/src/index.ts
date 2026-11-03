// Mock resource server for the UMZH Connect IG.
//
// Two faces:
//   POST /validate          detailed per-check validation report for any token
//   /fhir/*                 sample protected endpoints enforcing the IG rules
//                           (bearer JWT, SMART system scope, context gate)
//
// Dev/test aid only - NOT a production artifact.

import express, { type NextFunction, type Request, type Response } from 'express';
import type { JWTPayload } from 'jose';
import { loadConfig } from './config.js';
import { contextsOf, hasSystemScope, organizationReferenceOf, validateToken } from './validator.js';

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

// --- Mock workflow records --------------------------------------------------
//
// Stand-ins for the RS's own records. A real RS is either the Placer or the
// Fulfiller; this mock holds one workflow root of each so both directions can
// be exercised. Organization references match keycloak-config/clients/*.yaml.

const HOSPITAL_A = 'https://fhir.hospital_a.example/fhir/Organization/HospitalA'; // Placer
const HOSPITAL_B = 'https://fhir.hospital_b.example/fhir/Organization/HospitalB'; // Fulfiller

/**
 * Per workflow root: the counter-party the RS recorded for it (IG step 2 —
 * ServiceRequest.performer or a Consent on the Placer, Task.requester on the
 * Fulfiller) and the resources in its context graph (IG step 3).
 */
const WORKFLOW_ROOTS: Record<string, { counterParty: string; graph: string[] }> = {
  // On the Placer: the Fulfiller reads the order and what it references.
  'ServiceRequest/sr-123': {
    counterParty: HOSPITAL_B,
    graph: ['ServiceRequest/sr-123', 'Patient/pat-1', 'Condition/cond-1'],
  },
  // On the Fulfiller: the Placer reads the Task's output.
  'Task/task-456': {
    counterParty: HOSPITAL_A,
    graph: ['DiagnosticReport/report-1'],
  },
};

/** Tasks held by the mock Fulfiller (HOSPITAL_B). */
const TASKS: Record<string, { requester: string; owner: string }> = {
  'task-456': { requester: HOSPITAL_A, owner: HOSPITAL_B },
};

/**
 * IG context gate for context-gated resources (every type except Task and
 * Questionnaire). The token must carry exactly one context, the caller must
 * be the counter-party recorded for its root, and the requested resource must
 * be in the root's context graph. A real RS resolves the graph from its FHIR
 * data; this mock uses WORKFLOW_ROOTS.
 */
function requireContext(req: Request, res: Response, next: NextFunction): void {
  const resource = `${req.params.type}/${req.params.id}`;
  const contexts = contextsOf(req.claims!);
  if (contexts.length !== 1) {
    res.status(403).json({
      error: `context-gated resource ${resource} requires exactly one context in authorization_details`,
      contexts,
    });
    return;
  }
  const root = contexts[0].identifier ?? '';
  const record = WORKFLOW_ROOTS[root];
  const caller = organizationReferenceOf(req.claims!);
  if (!record || record.counterParty !== caller) {
    res.status(403).json({
      error: `calling organization is not the recorded counter-party of ${root}`,
      organization_reference: caller,
    });
    return;
  }
  if (!record.graph.includes(resource)) {
    res.status(403).json({ error: `${resource} is not in the context graph of ${root}` });
    return;
  }
  next();
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

// Questionnaire: definitional content, not context-gated — scope only.
app.get('/fhir/Questionnaire/:id', requireAuth, requireSystemScope('Questionnaire', 'r'), (req, res) => {
  res.json({ resourceType: 'Questionnaire', id: req.params.id, status: 'active' });
});

// Task read: not context-gated; the caller must be Task.requester.
app.get('/fhir/Task/:id', requireAuth, requireSystemScope('Task', 'r'), (req, res) => {
  const task = TASKS[req.params.id];
  if (!task) {
    res.status(404).json({ error: `Task/${req.params.id} not found` });
    return;
  }
  if (task.requester !== organizationReferenceOf(req.claims!)) {
    res.status(403).json({ error: 'calling organization is not Task.requester' });
    return;
  }
  res.json({ resourceType: 'Task', id: req.params.id, status: 'requested', intent: 'order',
    requester: { reference: task.requester }, owner: { reference: task.owner } });
});

// Task create: not context-gated; Task.requester must be the caller and
// Task.owner this (Fulfiller) server's own organization.
app.post('/fhir/Task', requireAuth, requireSystemScope('Task', 'c'), (req, res) => {
  if (req.body?.requester?.reference !== organizationReferenceOf(req.claims!)) {
    res.status(403).json({ error: 'Task.requester must be the calling organization' });
    return;
  }
  if (req.body?.owner?.reference !== HOSPITAL_B) {
    res.status(403).json({ error: `Task.owner must be this server's organization (${HOSPITAL_B})` });
    return;
  }
  res.status(201).json({ resourceType: 'Task', id: 'mock-task-1', status: 'requested', ...req.body });
});

// Every other resource type is context-gated: scope + context gate.
app.get('/fhir/:type/:id', requireAuth,
  (req, res, next) => requireSystemScope(req.params.type, 'r')(req, res, next),
  requireContext,
  (req, res) => {
    res.json({ resourceType: req.params.type, id: req.params.id });
  },
);

app.listen(config.port, () => {
  console.log(`token-validator listening on :${config.port}`);
  console.log(`  expected issuer: ${config.issuer}`);
  console.log(`  jwks uri:        ${config.jwksUri}`);
  console.log(`  audience check:  ${config.expectedAudience ?? 'reported only (EXPECTED_AUDIENCE unset)'}`);
});
