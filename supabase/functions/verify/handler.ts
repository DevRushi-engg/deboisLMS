import { createHash, timingSafeEqual } from 'node:crypto';
import { isIP } from 'node:net';

// Free of Deno globals on purpose, so the same file runs under the edge runtime and under node --test

export type DocType = 'badge' | 'certificate' | 'offer_letter';

export interface DocHit {
  docType: DocType;
  status: 'valid' | 'revoked';
  holderName: string;
  issueDate: string;
  // The badge's name, or the document's own title
  badgeName: string;
  // Public https URL of the badge art; certificates and offer letters have none
  badgeImageUrl?: string;
}

export interface VerifyDeps {
  // VERIFY_API_KEY, and VERIFY_API_KEY_PREVIOUS while a rotation is in flight
  keys: string[];
  // A null ref is input that failed validation: still counted against the IP, never looked up
  lookup: (ref: string | null, docType: DocType | null, ip: string) => Promise<DocHit | null>;
  log: (line: string) => void;
  // Every answer to a keyed caller takes at least this long, so a hit, a miss and a bad body look alike
  floorMs?: number;
}

// A badge: DBT<batch code>-<YY><number>-<5 chars>; a batch code can hold hyphens
const BADGE_REF = /^DBT[A-Z0-9-]{1,40}-\d{6,}-[A-Z0-9]{5}$/;
// A certificate or offer letter: the student's ID, DBT-INT-<year>-<number>
const STUDENT_REF = /^DBT-INT-\d{4}-\d{3,}$/;
const DOC_TYPES: readonly string[] = ['badge', 'certificate', 'offer_letter'];
const MAX_BODY = 512;

const HEADERS = { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' };
const FAILED = JSON.stringify({ error: 'not_found' });

const reply = (body: string, status: number) => new Response(body, { status, headers: HEADERS });

const digest = (value: string) => createHash('sha256').update(value).digest();

// Hashed first so the lengths match; every key is checked, none short-circuits
const keyOk = (given: string, keys: string[]) => {
  const wanted = digest(given);
  return keys.map((key) => timingSafeEqual(wanted, digest(key))).some(Boolean);
};

// Trusted only because the caller already passed the key check
const clientIp = (header: string | null) => {
  const ip = header?.trim().toLowerCase() ?? '';
  return isIP(ip) ? ip : 'unknown';
};

// A badge ref needs no docType; a student ID needs certificate or offer_letter. Anything else is not well formed.
function pick(ref: string, typed: unknown): DocType | null {
  const type = typeof typed === 'string' ? typed.trim().toLowerCase() : undefined;
  if (BADGE_REF.test(ref)) return type === undefined || type === 'badge' ? 'badge' : null;
  if (STUDENT_REF.test(ref)) return type === 'certificate' || type === 'offer_letter' ? type : null;
  return null;
}

// What was typed (for the log) and, if it is well formed, the ref and the document type
async function readInput(req: Request): Promise<{ typed: string; ref: string | null; docType: DocType | null }> {
  const none = { typed: '', ref: null, docType: null };
  if (req.method !== 'POST') return none;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) return none;
    const body: unknown = JSON.parse(text);
    const input = typeof body === 'object' && body !== null ? (body as { ref?: unknown; docType?: unknown }) : {};
    if (typeof input.ref !== 'string') return none;
    const ref = input.ref.trim().toUpperCase();
    const docType = pick(ref, input.docType);
    return { typed: ref, ref: docType ? ref : null, docType };
  } catch {
    return none;
  }
}

export async function handleVerify(req: Request, deps: VerifyDeps): Promise<Response> {
  const given = req.headers.get('x-api-key') ?? '';
  if (!given || !keyOk(given, deps.keys)) return reply(JSON.stringify({ error: 'unauthorized' }), 401);

  const started = Date.now();
  const ip = clientIp(req.headers.get('x-client-ip'));
  const { typed, ref, docType } = await readInput(req);

  let hit: DocHit | null = null;
  try {
    hit = await deps.lookup(ref, docType, ip);
  } catch (err) {
    // A broken lookup answers like a miss; only the log knows
    deps.log(JSON.stringify({ evt: 'verify_error', at: new Date().toISOString(), error: String(err).slice(0, 200) }));
  }
  // The type came back from the database, so check it before it goes out
  if (hit && !DOC_TYPES.includes(hit.docType)) hit = null;

  if (!hit) {
    // Letters, digits and hyphens only, capped: the log line cannot be forged from here
    const shown = typed.replace(/[^A-Z0-9-]/g, '').slice(0, 60);
    deps.log(JSON.stringify({ evt: 'verify_failed', at: new Date().toISOString(), ip, ref: shown }));
  }

  const wait = (deps.floorMs ?? 250) - (Date.now() - started);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));

  if (!hit) return reply(FAILED, 404);
  const { docType: type, status, holderName, issueDate, badgeName, badgeImageUrl } = hit;
  // Exactly these fields and no others; the image only when it is a real https URL
  return reply(JSON.stringify({
    docType: type, status, holderName, issueDate, badgeName,
    ...(badgeImageUrl?.startsWith('https://') ? { badgeImageUrl } : {}),
  }), 200);
}
