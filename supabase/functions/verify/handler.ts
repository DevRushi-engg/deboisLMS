import { createHash, timingSafeEqual } from 'node:crypto';
import { isIP } from 'node:net';

// Free of Deno globals on purpose, so the same file runs under the edge runtime and under node --test

export interface BadgeHit {
  status: 'valid' | 'revoked';
  issueDate: string;
  holderName: string;
}

export interface VerifyDeps {
  // VERIFY_API_KEY, and VERIFY_API_KEY_PREVIOUS while a rotation is in flight
  keys: string[];
  // A null ref is input that failed validation: still counted against the IP, never looked up
  lookup: (ref: string | null, ip: string) => Promise<BadgeHit | null>;
  log: (line: string) => void;
  // Every answer to a keyed caller takes at least this long, so a hit, a miss and a bad body look alike
  floorMs?: number;
}

// DBT<batch code>-<YY><number>-<5 chars>; a batch code can hold hyphens
const REF = /^DBT[A-Z0-9-]{1,40}-\d{6,}-[A-Z0-9]{5}$/;
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

// The ref as typed (for the log) and the ref if it is well formed
async function readRef(req: Request): Promise<{ typed: string; ref: string | null }> {
  if (req.method !== 'POST') return { typed: '', ref: null };
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) return { typed: '', ref: null };
    const body: unknown = JSON.parse(text);
    const value = typeof body === 'object' && body !== null ? (body as { ref?: unknown }).ref : undefined;
    if (typeof value !== 'string') return { typed: '', ref: null };
    const ref = value.trim().toUpperCase();
    return { typed: ref, ref: REF.test(ref) ? ref : null };
  } catch {
    return { typed: '', ref: null };
  }
}

export async function handleVerify(req: Request, deps: VerifyDeps): Promise<Response> {
  const given = req.headers.get('x-api-key') ?? '';
  if (!given || !keyOk(given, deps.keys)) return reply(JSON.stringify({ error: 'unauthorized' }), 401);

  const started = Date.now();
  const ip = clientIp(req.headers.get('x-client-ip'));
  const { typed, ref } = await readRef(req);

  let hit: BadgeHit | null = null;
  try {
    hit = await deps.lookup(ref, ip);
  } catch (err) {
    // A broken lookup answers like a miss; only the log knows
    deps.log(JSON.stringify({ evt: 'verify_error', at: new Date().toISOString(), error: String(err).slice(0, 200) }));
  }

  if (!hit) {
    // Letters, digits and hyphens only, capped: the log line cannot be forged from here
    const shown = typed.replace(/[^A-Z0-9-]/g, '').slice(0, 60);
    deps.log(JSON.stringify({ evt: 'verify_failed', at: new Date().toISOString(), ip, ref: shown }));
  }

  const wait = (deps.floorMs ?? 250) - (Date.now() - started);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));

  if (!hit) return reply(FAILED, 404);
  return reply(JSON.stringify({ docType: 'badge', status: hit.status, issueDate: hit.issueDate, holderName: hit.holderName }), 200);
}
