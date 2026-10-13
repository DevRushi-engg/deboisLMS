// Run: npm test
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { handleVerify, type DocHit, type DocType, type VerifyDeps } from './handler.ts';

const KEY = 'secret-key';
const BADGE = 'DBTPHR-260012-1A3BC';
const STUDENT = 'DBT-INT-2026-012';
const IMAGE = 'https://x.supabase.co/storage/v1/object/public/assets/badges/b/p.png';

const HITS: Record<DocType, DocHit> = {
  badge: { docType: 'badge', status: 'valid', holderName: 'Asha Bankar', issueDate: '2026-10-01', badgeName: 'Docker Pro', badgeImageUrl: IMAGE },
  certificate: { docType: 'certificate', status: 'valid', holderName: 'Asha Bankar', issueDate: '2026-10-02', badgeName: 'Internship Completion Certificate' },
  offer_letter: { docType: 'offer_letter', status: 'valid', holderName: 'Asha Bankar', issueDate: '2026-09-01', badgeName: 'Offer of Internship' },
};

const calls: { ref: string | null; docType: DocType | null; ip: string }[] = [];
const logs: string[] = [];

// Knows one badge ref and one student ref, which holds both documents
const deps = (over: Partial<VerifyDeps> = {}): VerifyDeps => ({
  keys: [KEY],
  floorMs: 0,
  log: (line) => logs.push(line),
  lookup: async (ref, docType, ip) => {
    calls.push({ ref, docType, ip });
    if (ref === BADGE && docType === 'badge') return HITS.badge;
    if (ref === STUDENT && docType && docType !== 'badge') return HITS[docType];
    return null;
  },
  ...over,
});

const post = (body: unknown, headers: Record<string, string> = {}, method = 'POST') =>
  new Request('https://x.test/verify', {
    method,
    headers: { 'x-api-key': KEY, 'x-client-ip': '203.0.113.7', ...headers },
    body: method === 'POST' ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
  });

const text = async (res: Response) => ({ status: res.status, body: await res.text(), cache: res.headers.get('cache-control'), type: res.headers.get('content-type') });

test('a badge verifies with the badge fields and its image, and nothing else', async () => {
  calls.length = 0;
  const res = await handleVerify(post({ ref: BADGE, docType: 'badge' }), deps());
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await res.json(), {
    docType: 'badge', status: 'valid', holderName: 'Asha Bankar', issueDate: '2026-10-01', badgeName: 'Docker Pro', badgeImageUrl: IMAGE,
  });
  assert.deepEqual(calls, [{ ref: BADGE, docType: 'badge', ip: '203.0.113.7' }]);
});

test('a badge ref without a docType still works', async () => {
  const res = await handleVerify(post({ ref: BADGE }), deps());
  assert.equal((await res.json()).docType, 'badge');
});

test('a certificate and an offer letter verify by the student ID and the chosen type, with no image and no expiry', async () => {
  for (const docType of ['certificate', 'offer_letter'] as const) {
    const res = await handleVerify(post({ ref: STUDENT, docType }), deps());
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body, HITS[docType]);
    assert.equal('badgeImageUrl' in body, false);
    assert.equal('expiryDate' in body, false);
  }
});

test('a revoked badge says revoked', async () => {
  const res = await handleVerify(post({ ref: BADGE }), deps({ lookup: async () => ({ ...HITS.badge, status: 'revoked' }) }));
  assert.equal((await res.json()).status, 'revoked');
});

test('the ref and the type are trimmed and case-folded before the lookup', async () => {
  calls.length = 0;
  await handleVerify(post({ ref: `  ${STUDENT.toLowerCase()} `, docType: ' Offer_Letter ' }), deps());
  assert.deepEqual(calls, [{ ref: STUDENT, docType: 'offer_letter', ip: '203.0.113.7' }]);
});

test('an image URL that is not https never goes out', async () => {
  const insecure = { ...HITS.badge, badgeImageUrl: 'http://x.test/p.png' };
  const body = await (await handleVerify(post({ ref: BADGE }), deps({ lookup: async () => insecure }))).json();
  assert.equal('badgeImageUrl' in body, false);
});

test('extra fields from the lookup never leak', async () => {
  const noisy = { ...HITS.badge, email: 'a@x.in', phone: '900', id: 'uuid' } as DocHit;
  const body = await (await handleVerify(post({ ref: BADGE }), deps({ lookup: async () => noisy }))).json();
  assert.deepEqual(Object.keys(body).sort(), ['badgeImageUrl', 'badgeName', 'docType', 'holderName', 'issueDate', 'status']);
});

test('a type the database invents is a miss', async () => {
  const odd = { ...HITS.badge, docType: 'passport' } as unknown as DocHit;
  assert.equal((await handleVerify(post({ ref: BADGE }), deps({ lookup: async () => odd }))).status, 404);
});

test('every failure looks the same: body, status and headers', async () => {
  const cases: Request[] = [
    post({ ref: 'DBTPHR-260012-ZZZZZ' }),
    post({ ref: 'DBT-INT-2026-999', docType: 'certificate' }),
    post({ ref: STUDENT }),
    post({ ref: STUDENT, docType: 'badge' }),
    post({ ref: STUDENT, docType: 'passport' }),
    post({ ref: BADGE, docType: 'certificate' }),
    post({ ref: 'nope' }),
    post({ ref: 42 }),
    post({ ref: `${BADGE}'; drop table students;--` }),
    post({ ref: 'D'.repeat(5000) }),
    post({}),
    post('not json'),
    post('', {}, 'GET'),
    post({ ref: BADGE }, {}, 'PUT'),
  ];
  const seen = new Set<string>();
  for (const req of cases) seen.add(JSON.stringify(await text(await handleVerify(req, deps()))));
  assert.equal(seen.size, 1);
  const [only] = [...seen].map((s) => JSON.parse(s));
  assert.equal(only.status, 404);
  assert.equal(only.cache, 'no-store');
});

test('a broken lookup answers like a miss', async () => {
  const miss = await text(await handleVerify(post({ ref: 'DBTPHR-260012-ZZZZZ' }), deps()));
  const broken = await text(await handleVerify(post({ ref: BADGE }), deps({ lookup: async () => { throw new Error('db down'); } })));
  assert.deepEqual(broken, miss);
});

test('malformed input is still counted: the lookup gets a null ref and type', async () => {
  calls.length = 0;
  await handleVerify(post({ ref: 'nope' }), deps());
  await handleVerify(post({ ref: STUDENT }), deps());
  await handleVerify(post('not json'), deps());
  assert.deepEqual(calls.map((c) => [c.ref, c.docType]), [[null, null], [null, null], [null, null]]);
});

test('no key or a wrong key is a 401 and never reaches the lookup', async () => {
  calls.length = 0;
  for (const headers of [{ 'x-api-key': '' }, { 'x-api-key': 'wrong' }, { 'x-api-key': KEY + 'x' }]) {
    const res = await handleVerify(post({ ref: BADGE }, headers), deps());
    assert.equal(res.status, 401);
    assert.equal(res.headers.get('access-control-allow-origin'), null);
  }
  const bare = await handleVerify(new Request('https://x.test/verify', { method: 'POST', body: JSON.stringify({ ref: BADGE }) }), deps());
  assert.equal(bare.status, 401);
  assert.equal(calls.length, 0);
});

test('no key configured refuses everything', async () => {
  assert.equal((await handleVerify(post({ ref: BADGE }), deps({ keys: [] }))).status, 401);
});

test('the previous key still works during a rotation', async () => {
  const res = await handleVerify(post({ ref: BADGE }, { 'x-api-key': 'old-key' }), deps({ keys: ['new-key', 'old-key'] }));
  assert.equal(res.status, 200);
});

test('x-client-ip is used only when it is an IP', async () => {
  calls.length = 0;
  await handleVerify(post({ ref: BADGE }, { 'x-client-ip': '2001:DB8::1' }), deps());
  await handleVerify(post({ ref: BADGE }, { 'x-client-ip': 'not an ip' }), deps());
  await handleVerify(post({ ref: BADGE }, { 'x-client-ip': '' }), deps());
  assert.deepEqual(calls.map((c) => c.ip), ['2001:db8::1', 'unknown', 'unknown']);
});

test('a failure is logged with time, ip and a cleaned ref, a hit is not', async () => {
  logs.length = 0;
  await handleVerify(post({ ref: BADGE }), deps());
  assert.equal(logs.length, 0);
  await handleVerify(post({ ref: 'x"},{"evt":"forged\n' }), deps());
  assert.equal(logs.length, 1);
  const line = JSON.parse(logs[0]);
  assert.equal(line.evt, 'verify_failed');
  assert.equal(line.ip, '203.0.113.7');
  assert.match(line.at, /^\d{4}-\d{2}-\d{2}T/);
  assert.match(line.ref, /^[A-Z0-9-]*$/);
});

test('every keyed answer takes at least the floor', async () => {
  const started = Date.now();
  await handleVerify(post({ ref: 'nope' }), deps({ floorMs: 60 }));
  await handleVerify(post({ ref: BADGE }), deps({ floorMs: 60 }));
  assert.ok(Date.now() - started >= 110);
});
