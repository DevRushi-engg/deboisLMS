// Run: npm test. Loads schema.sql into an in-memory Postgres and exercises verify_badge.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { after, before, test } from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
const rows = async (sql) => (await db.query(sql)).rows;
const check = (ref, ip = '1.1.1.1') => rows(`select * from verify_badge(${ref === null ? 'null' : `'${ref}'`}, '${ip}')`);
const block = (ip) => rows(`select * from verify_blocks where ip = '${ip}'`).then((r) => r[0]);

const BATCH = 'b0000000-0000-0000-0000-0000000000b1';
const BADGE = '20000000-0000-0000-0000-000000000001';
const ASHA = '50000000-0000-0000-0000-0000000000a1';
const MADONNA = '50000000-0000-0000-0000-0000000000a2';
const TESTER = '50000000-0000-0000-0000-0000000000a3';
let asha;
let madonna;

before(async () => {
  await db.exec(`
    create role anon nologin; create role authenticated nologin; create role service_role nologin;
    create schema auth; create schema storage; create schema extensions;
    create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_app_meta_data jsonb default '{}'::jsonb);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
    create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
    create table storage.objects (id uuid default gen_random_uuid(), bucket_id text, name text, owner uuid);
    alter table storage.objects enable row level security;
    create function storage.extension(name text) returns text language sql as $$ select split_part(name, '.', 2) $$;
  `);
  await db.exec(fs.readFileSync(new URL('../schema.sql', import.meta.url), 'utf8'));
  await db.exec(`
    grant usage on schema public to anon, authenticated, service_role;
    insert into batch_programs (code, name, sort_order) values ('TST', 'Test', 1) on conflict do nothing;
    insert into batches (id, name, program, start_date, base_fee, status, batch_code) values ('${BATCH}', 'Real', 'TST', current_date - 5, 8000, 'ongoing', 'PHR');
    insert into batch_badges (id, batch_id, name, image_path) values ('${BADGE}', '${BATCH}', 'Docker Pro', 'p/1.png');
    insert into students (id, name, phone, email, date_of_birth, student_code) values
      ('${ASHA}', '  Asha  Bankar ', '9000000001', 'a@x.in', '2000-01-01', 'DBT-INT-2026-012'),
      ('${MADONNA}', 'Madonna', '9000000002', 'm@x.in', '2000-01-01', 'DBT-INT-2026-013'),
      ('${TESTER}', 'Dummy Tester', '9000000003', 'd@x.in', '2000-01-01', 'DBT-INT-2026-014');
    insert into student_badges (student_id, badge_id) values ('${ASHA}', '${BADGE}'), ('${MADONNA}', '${BADGE}'), ('${TESTER}', '${BADGE}');
    update students set is_test = true where id = '${TESTER}';
  `);
  asha = (await rows(`select code from badge_codes where student_id = '${ASHA}'`))[0].code;
  madonna = (await rows(`select code from badge_codes where student_id = '${MADONNA}'`))[0].code;
});

after(() => db.close());

const reset = () => db.exec(`delete from verify_blocks`);

test('a held badge: valid, first name and last initial, Indian-time date', async () => {
  await reset();
  assert.match(asha, /^DBTPHR-260012-[A-Z0-9]{5}$/);
  const [hit, ...more] = await check(asha);
  assert.equal(more.length, 0);
  assert.deepEqual(Object.keys(hit), ['status', 'issue_date', 'holder_name']);
  assert.equal(hit.status, 'valid');
  assert.equal(hit.holder_name, 'Asha B.');
  assert.ok(hit.issue_date instanceof Date || typeof hit.issue_date === 'string');
});

test('a single name stays as it is', async () => {
  await reset();
  assert.equal((await check(madonna))[0].holder_name, 'Madonna');
});

test('a badge taken back is revoked, and valid again with the same code when given again', async () => {
  await reset();
  await db.exec(`delete from student_badges where student_id = '${ASHA}'`);
  assert.equal((await check(asha))[0].status, 'revoked');
  await db.exec(`insert into student_badges (student_id, badge_id) values ('${ASHA}', '${BADGE}')`);
  const [hit] = await check(asha);
  assert.equal(hit.status, 'valid');
  assert.equal((await rows(`select code from badge_codes where student_id = '${ASHA}'`))[0].code, asha);
});

test('unknown refs, null and a test student give nothing', async () => {
  await reset();
  assert.equal((await check('DBTPHR-260012-ZZZZZ')).length, 0);
  assert.equal((await check(null)).length, 0);
  const tester = (await rows(`select code from badge_codes where student_id = '${TESTER}'`))[0].code;
  assert.equal((await check(tester)).length, 0);
});

test('ten misses block the IP for an hour, a valid ref included; other IPs are untouched', async () => {
  await reset();
  for (let i = 0; i < 10; i++) assert.equal((await check('DBTPHR-260012-ZZZZZ', '9.9.9.9')).length, 0);
  const row = await block('9.9.9.9');
  assert.equal(row.failures, 10);
  assert.ok(row.blocked_until > new Date(Date.now() + 50 * 60_000));
  assert.equal((await check(asha, '9.9.9.9')).length, 0);
  assert.equal((await check(asha, '8.8.8.8')).length, 1);
});

test('nine misses do not block', async () => {
  await reset();
  for (let i = 0; i < 9; i++) await check(null, '7.7.7.7');
  assert.equal((await check(asha, '7.7.7.7')).length, 1);
});

test('the block lifts once it has run out', async () => {
  await reset();
  for (let i = 0; i < 10; i++) await check(null, '6.6.6.6');
  assert.equal((await check(asha, '6.6.6.6')).length, 0);
  await db.exec(`update verify_blocks set blocked_until = now() - interval '1 minute', window_start = now() - interval '2 hours' where ip = '6.6.6.6'`);
  assert.equal((await check(asha, '6.6.6.6')).length, 1);
  const row = await block('6.6.6.6');
  assert.equal(row.failures, 0);
  assert.equal(row.blocked_until, null);
});

test('misses spread over more than 15 minutes do not add up', async () => {
  await reset();
  for (let i = 0; i < 9; i++) await check(null, '5.5.5.5');
  await db.exec(`update verify_blocks set window_start = now() - interval '16 minutes' where ip = '5.5.5.5'`);
  await check(null, '5.5.5.5');
  assert.equal((await block('5.5.5.5')).failures, 1);
  assert.equal((await block('5.5.5.5')).blocked_until, null);
});

test('sixty lookups block even when every one was a hit', async () => {
  await reset();
  for (let i = 0; i < 59; i++) assert.equal((await check(asha, '4.4.4.4')).length, 1);
  assert.equal((await check(asha, '4.4.4.4')).length, 1);
  assert.equal((await check(asha, '4.4.4.4')).length, 0);
});

test('old quiet rows are cleaned up on the next call', async () => {
  await reset();
  await db.exec(`insert into verify_blocks (ip, failures, window_start) values ('3.3.3.3', 2, now() - interval '1 day')`);
  await check(null, '2.2.2.2');
  assert.equal(await block('3.3.3.3'), undefined);
});

test('only the service role can call it or read the store', async () => {
  await db.exec(`reset role`);
  for (const role of ['anon', 'authenticated']) {
    await db.exec(`set role ${role}`);
    await assert.rejects(() => db.query(`select * from verify_badge('${asha}', '1.1.1.1')`), /permission denied/);
    await assert.rejects(() => db.query(`select * from verify_blocks`), /permission denied/);
    await db.exec(`reset role`);
  }
  await db.exec(`set role service_role`);
  assert.equal((await db.query(`select * from verify_badge('${asha}', '1.1.1.1')`)).rows.length, 1);
  await db.exec(`reset role`);
});
