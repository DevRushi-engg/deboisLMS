// Run: npm test
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { handleVerify, type BadgeHit, type VerifyDeps } from './handler.ts';

const KEY = 'secret-key';
const REF = 'DBTPHR-260012-1A3BC';
const VALID: BadgeHit = { status: 'valid', issueDate: '2026-10-01', holderName: 'Asha B.' };

const calls: { ref: string | null; ip: string }[] = [];
const logs: string[] = [];

const deps = (over: Partial<VerifyDeps> = {}): VerifyDeps => ({
  keys: [KEY],
  floorMs: 0,
  log: (line) => logs.push(line),
  lookup: async (ref, ip) => {
    calls.push({ ref, ip });
    return ref === REF ? VALID : null;
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

test('a held badge verifies with exactly four fields', async () => {
  calls.length = 0;
  const res = await handleVerify(post({ ref: REF }), deps());
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await res.json(), { docType: 'badge', status: 'valid', issueDate: '2026-10-01', holderName: 'Asha B.' });
  assert.deepEqual(calls, [{ ref: REF, ip: '203.0.113.7' }]);
});

test('a revoked badge says revoked', async () => {
  const res = await handleVerify(post({ ref: REF }), deps({ lookup: async () => ({ ...VALID, status: 'revoked' }) }));
  assert.equal((await res.json()).status, 'revoked');
});

test('the ref is trimmed and uppercased before the lookup', async () => {
  calls.length = 0;
  await handleVerify(post({ ref: `  ${REF.toLowerCase()} ` }), deps());
  assert.equal(calls[0].ref, REF);
});

test('every failure looks the same: body, status and headers', async () => {
  const cases: Request[] = [
    post({ ref: 'DBTPHR-260012-ZZZZZ' }),
    post({ ref: 'nope' }),
    post({ ref: 42 }),
    post({ ref: `${REF}'; drop table students;--` }),
    post({ ref: 'D'.repeat(5000) }),
    post({}),
    post('not json'),
    post('', {}, 'GET'),
    post({ ref: REF }, {}, 'PUT'),
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
  const broken = await text(await handleVerify(post({ ref: REF }), deps({ lookup: async () => { throw new Error('db down'); } })));
  assert.deepEqual(broken, miss);
});

test('malformed input is still counted: the lookup gets a null ref', async () => {
  calls.length = 0;
  await handleVerify(post({ ref: 'nope' }), deps());
  await handleVerify(post('not json'), deps());
  assert.deepEqual(calls.map((c) => c.ref), [null, null]);
});

test('no key or a wrong key is a 401 and never reaches the lookup', async () => {
  calls.length = 0;
  for (const headers of [{ 'x-api-key': '' }, { 'x-api-key': 'wrong' }, { 'x-api-key': KEY + 'x' }]) {
    const res = await handleVerify(post({ ref: REF }, headers), deps());
    assert.equal(res.status, 401);
    assert.equal(res.headers.get('access-control-allow-origin'), null);
  }
  const bare = await handleVerify(new Request('https://x.test/verify', { method: 'POST', body: JSON.stringify({ ref: REF }) }), deps());
  assert.equal(bare.status, 401);
  assert.equal(calls.length, 0);
});

test('no key configured refuses everything', async () => {
  assert.equal((await handleVerify(post({ ref: REF }), deps({ keys: [] }))).status, 401);
});

test('the previous key still works during a rotation', async () => {
  const res = await handleVerify(post({ ref: REF }, { 'x-api-key': 'old-key' }), deps({ keys: ['new-key', 'old-key'] }));
  assert.equal(res.status, 200);
});

test('x-client-ip is used only when it is an IP', async () => {
  calls.length = 0;
  await handleVerify(post({ ref: REF }, { 'x-client-ip': '2001:DB8::1' }), deps());
  await handleVerify(post({ ref: REF }, { 'x-client-ip': 'not an ip' }), deps());
  await handleVerify(post({ ref: REF }, { 'x-client-ip': '' }), deps());
  assert.deepEqual(calls.map((c) => c.ip), ['2001:db8::1', 'unknown', 'unknown']);
});

test('a failure is logged with time, ip and a cleaned ref, a hit is not', async () => {
  logs.length = 0;
  await handleVerify(post({ ref: REF }), deps());
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
  await handleVerify(post({ ref: REF }), deps({ floorMs: 60 }));
  assert.ok(Date.now() - started >= 110);
});
