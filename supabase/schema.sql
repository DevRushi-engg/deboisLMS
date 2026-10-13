-- deboistech LMS — schema
-- The whole database in one file: run it on a fresh project and nothing else.
-- Assumes an admin user already exists in Supabase Auth — edit the email in §8.
-- Re-runnable: every statement is guarded and nothing rewrites issued data.
  

-- 1. TYPES
do $$ begin create type batch_status       as enum ('upcoming', 'ongoing', 'completed');      exception when duplicate_object then null; end $$;
do $$ begin create type session_type       as enum ('online', 'offline');                     exception when duplicate_object then null; end $$;
do $$ begin create type attendance_status  as enum ('present', 'partial', 'absent');          exception when duplicate_object then null; end $$;
do $$ begin create type attendance_source  as enum ('manual', 'automated');                   exception when duplicate_object then null; end $$;
do $$ begin create type mapping_status     as enum ('active', 'archived', 'terminated', 'transferred');       exception when duplicate_object then null; end $$;
do $$ begin create type fee_status         as enum ('due', 'paid', 'terminated');             exception when duplicate_object then null; end $$;
do $$ begin create type payment_method     as enum ('cash', 'upi', 'bank_transfer', 'other'); exception when duplicate_object then null; end $$;
do $$ begin create type claim_status       as enum ('pending', 'approved', 'dismissed');      exception when duplicate_object then null; end $$;

-- Work is handed in as a GitHub repo and nothing else, always by the student
-- themselves — 'portal' is the only channel.
do $$ begin create type submission_channel as enum ('portal');                                exception when duplicate_object then null; end $$;
do $$ begin create type discount_type      as enum ('percentage', 'amount');                  exception when duplicate_object then null; end $$;
do $$ begin create type feedback_kind      as enum ('bug', 'request');                        exception when duplicate_object then null; end $$;
do $$ begin create type feedback_status    as enum ('open', 'resolved');                      exception when duplicate_object then null; end $$;

-- Programmes are NOT an enum — see the batch_programs table below for why.


-- 2. STUDENT CODES
-- One permanent ID per student, independent of every batch. Postgres issues it,
-- not the app: students are created from a form, from two CSV importers that
-- insert every row at once, and by hand in SQL. Anything app-side that reads the
-- highest number and adds one hands out duplicates under that burst; nextval()
-- cannot.

-- Seeded once, never replaced: re-running this file after the year has been
-- rolled must not drag it back to 2026 and re-issue codes that already exist.
do $$
begin
  if to_regprocedure('student_code_year()') is null then
    execute 'create function student_code_year() returns text language sql stable set search_path = public as $f$ select ''2026''::text $f$';
  end if;
end $$;

create or replace function student_code_prefix() returns text
  language sql stable
  set search_path = public
  as $$ select 'DBT-INT-' || student_code_year() || '-' $$;

-- Rolling the year, when the 2027 intake starts:
--
--   select set_student_code_year(2027);
--
-- Both halves in one call, because doing one without the other is the bug: a new
-- year without the restart keeps counting from 057, and a restart without a new
-- year re-issues codes that already exist. The guard below refuses the second
-- case outright, and the whole thing is one transaction.
create or replace function set_student_code_year(new_year int) returns text
  language plpgsql
  security definer
  set search_path = public
  as $$
begin
  -- The SQL editor carries no JWT, so "no caller" is allowed. A signed-in caller must be an admin.
  if auth.uid() is not null and not is_admin() then
    raise exception 'Admin only';
  end if;

  execute format(
    'create or replace function student_code_year() returns text language sql stable set search_path = public as $f$ select %L::text $f$',
    new_year::text
  );

  if exists (select 1 from students where student_code like student_code_prefix() || '%') then
    raise exception 'Codes already issued under %, refusing to restart the counter',
      student_code_prefix();
  end if;

  alter sequence student_code_seq restart 1;
  alter sequence student_test_code_seq restart 1;
  return student_code_prefix();
end $$;

-- The dashboard's Roll button: the year after the current one.
create or replace function roll_student_code_year() returns text
  language sql
  security definer
  set search_path = public
  as $$ select set_student_code_year(student_code_year()::int + 1) $$;

revoke all on function set_student_code_year(int), roll_student_code_year() from public, anon;
grant execute on function set_student_code_year(int), roll_student_code_year() to authenticated;

create sequence if not exists student_code_seq as bigint start 1;

-- DBT-INT-2026-001. lpad pads but never truncates, so the 1000th student widens
-- to -1000 rather than losing a digit.
create or replace function next_student_code() returns text
  language sql volatile
  set search_path = public
  as $$ select student_code_prefix() || lpad(nextval('student_code_seq')::text, 3, '0') $$;

-- Students in a test batch: DBT-TEST-2026-001. Its own counter, so test students never move the live one.
create sequence if not exists student_test_code_seq as bigint start 1;

create or replace function next_test_student_code() returns text
  language sql volatile
  set search_path = public
  as $$ select 'DBT-TEST-' || student_code_year() || '-' || lpad(nextval('student_test_code_seq')::text, 3, '0') $$;


-- 3. CORE TABLES
create table if not exists tutors (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  email      text,
  phone      text,
  -- Set once a portal login exists for this tutor. Same shape as students.auth_user_id.
  auth_user_id     uuid references auth.users(id) unique,
  password_rotated boolean not null default false,
  created_at timestamptz default now()
);

-- Re-running this file on a database created before tutor logins existed.
alter table tutors add column if not exists auth_user_id uuid references auth.users(id) unique;
alter table tutors add column if not exists password_rotated boolean not null default false;

-- Abbreviation to display name. A table rather than a hardcoded list in the app,
-- so the import validator and the batch form read the same rows.
--
-- Deliberately not a Postgres enum. An enum is fixed at migration time: adding a
-- value is DDL, which the browser client cannot run and which cannot be done in
-- the same transaction that then uses the value. The batch form mints a new
-- abbreviation on the spot, so the valid set has to be rows. The CHECK keeps the
-- codes enum-shaped and the foreign key on batches.program gives the same
-- guarantee an enum would.
create table if not exists batch_programs (
  -- Enum-shaped by constraint: 2–6 capitals, e.g. PHR, AML, MCL.
  code       text primary key check (code ~ '^[A-Z]{2,6}$'),
  name       text not null check (length(btrim(name)) > 0),
  sort_order int  not null default 0
);

insert into batch_programs (code, name, sort_order) values
  ('PHR', 'DevOps Prahar',           1),
  ('AML', 'AI/ML Engineering',       2),
  ('MCL', 'Multi-Cloud Engineering', 3)
on conflict (code) do update set name = excluded.name, sort_order = excluded.sort_order;

create table if not exists batches (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  -- Which programme this batch runs. Replaces the old free-text `track`, which
  -- allowed any spelling and could not be validated. No cascade delete: a
  -- programme still carrying batches must not vanish under them.
  -- Not null: a batch with no programme is invisible to the CSV importer.
  program    text not null references batch_programs(code),
  status     batch_status default 'upcoming',
  start_date date,
  -- Filename prefix for this batch's study material, e.g. DBT-TEPC-2026-D.
  -- Material titles are this plus an admin-entered suffix: DBT-TEPC-2026-D01.
  batch_code text,
  -- The batch's full fee before any discount. Student imports carry a Discount
  -- amount in rupees per row and write base_fee - discount into
  -- student_fees.total_fee, with the discount kept on the fee row as an 'amount'.
  base_fee   numeric not null check (base_fee >= 0),
  -- Set by end_batch(). Null while the batch is still running.
  ended_at   date,
  -- A test batch: kept out of every total, and its students draw refs from their own series.
  -- One way: set by convert_batch_to_test(), never cleared.
  is_test    boolean not null default false,
  created_at timestamptz default now()
);

create index if not exists idx_batches_program on batches(program);

create table if not exists students (
  id              uuid primary key default gen_random_uuid(),
  student_code    text unique not null default next_student_code(),
  name            text not null,
  -- WhatsApp number. Also the source of the portal password suffix.
  phone           text not null check (btrim(phone) <> ''),
  email           text not null,
  date_of_birth   date not null,
  gender          text,
  college         text,
  course          text,
  branch          text,
  -- Free text, not an int: "3rd", "Final year" and "2" all turn up in the sheets.
  current_year    text,
  graduation_year int,
  github_url      text,
  linkedin_url    text,
  -- True once the portal password has been reset to a random one: the derived
  -- Debois@<last4> rule no longer applies and the password is shown only at reset.
  password_rotated boolean not null default false,
  -- Set once a portal login exists for this student.
  auth_user_id    uuid references auth.users(id) on delete set null unique,
  -- The day they lost their last batch, for the 90-day clean-up. Null while they have one.
  no_batch_since  date,
  -- In a test batch (see batches.is_test). Set by the enrolment trigger; a student is never both kinds.
  is_test         boolean not null default false,
  created_at      timestamptz default now()
);

comment on column students.student_code is
  'Permanent institution-wide student ID. Assigned once on insert and never '
  'rewritten — batches, drops and re-enrolments do not touch it. The one exception '
  'is a student entering a test batch, who moves to the DBT-TEST series.';

create table if not exists batch_student_mapping (
  id         uuid primary key default gen_random_uuid(),
  batch_id   uuid references batches(id) on delete cascade not null,
  student_id uuid references students(id) on delete cascade not null,
  -- Filled from the batch's start date by the trigger below when left blank. No
  -- default: a default cannot read another table, and current_date would make an
  -- omitted value indistinguishable from one deliberately set to today.
  joined_at  date,
  -- Set by terminate_enrolment(). Null until the student leaves.
  left_on    date,
  status     mapping_status default 'active',
  -- Off for a late joiner whose lectures and assignments from before they joined should not count against them
  count_earlier_work boolean not null default true,
  unique (batch_id, student_id)
);

create index if not exists idx_bsm_batch   on batch_student_mapping(batch_id);
create index if not exists idx_bsm_student on batch_student_mapping(student_id);

-- Joining in the batch's first week counts from its start date, later from the day they join (India time).
-- An explicit joined_at is left alone.
create or replace function set_join_date_from_batch()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  batch_start date;
  today       date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if new.joined_at is not null then
    return new;
  end if;

  select b.start_date into batch_start from batches b where b.id = new.batch_id;
  new.joined_at := case when batch_start is not null and today < batch_start + 7 then batch_start else today end;

  return new;
end;
$$;

drop trigger if exists bsm_join_date_from_batch on batch_student_mapping;
create trigger bsm_join_date_from_batch
  before insert on batch_student_mapping
  for each row execute function set_join_date_from_batch();

-- Re-running this file on a database created before the trigger existed.
alter table batch_student_mapping alter column joined_at drop default;

-- Remembers when a student lost their last batch, for the 90-day clean-up
create or replace function track_no_batch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update students set no_batch_since = null where id = new.student_id and no_batch_since is not null;
  elsif not exists (select 1 from batch_student_mapping where student_id = old.student_id) then
    update students set no_batch_since = (now() at time zone 'Asia/Kolkata')::date where id = old.student_id;
  end if;
  return null;
end $$;

drop trigger if exists bsm_track_no_batch on batch_student_mapping;
create trigger bsm_track_no_batch
  after insert or delete on batch_student_mapping
  for each row execute function track_no_batch();

-- A student is test or live, never both: the first batch decides which ref series they draw from, every
-- later one has to match. The live ref taken when the student row was created goes back to the counter.
create or replace function enforce_batch_kind()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  batch_test   boolean;
  student_test boolean;
begin
  select is_test into batch_test from batches where id = new.batch_id;
  select is_test into student_test from students where id = new.student_id;

  if batch_test is not distinct from student_test then
    return new;
  end if;

  if exists (select 1 from batch_student_mapping where student_id = new.student_id) then
    raise exception 'A student cannot be in both a test batch and a live batch';
  end if;

  -- Only a student made a moment ago takes the batch's kind. An older one keeps the ref they were issued.
  if (select created_at from students where id = new.student_id) < now() - interval '5 minutes' then
    raise exception 'Only a new student can join a % batch', case when batch_test then 'test' else 'live' end;
  end if;

  update students
  set is_test = batch_test,
      student_code = case when batch_test then next_test_student_code() else next_student_code() end
  where id = new.student_id;

  if batch_test then
    perform resync_student_code_seq();
  end if;
  return new;
end $$;

drop trigger if exists bsm_kind_guard on batch_student_mapping;
create trigger bsm_kind_guard
  before insert on batch_student_mapping
  for each row execute function enforce_batch_kind();

create table if not exists tutor_batch_mapping (
  id          uuid primary key default gen_random_uuid(),
  tutor_id    uuid references tutors(id) on delete cascade not null,
  batch_id    uuid references batches(id) on delete cascade not null,
  assigned_at date default current_date,
  unique (tutor_id, batch_id)
);

create index if not exists idx_tbm_tutor on tutor_batch_mapping(tutor_id);
create index if not exists idx_tbm_batch on tutor_batch_mapping(batch_id);


-- 4. ATTENDANCE
create table if not exists lectures (
  id                         uuid primary key default gen_random_uuid(),
  batch_id                   uuid references batches(id) on delete cascade not null,
  -- The day the session ran, entered by hand. Never defaulted from the insert time.
  lecture_date               date not null,
  session_type               session_type not null default 'online',
  meeting_code               text,
  scheduled_duration_minutes int not null default 120,
  note                       text,
  -- Session start, entered by hand as a local date and time. Not the insert time.
  start_at                   timestamptz not null,
  -- Computed from start_at plus scheduled_duration_minutes.
  end_at                     timestamptz check (end_at is null or end_at > start_at),
  -- The only clock-driven column on this table.
  created_at                 timestamptz default now()
);

comment on column lectures.scheduled_duration_minutes is
  'Scheduled session length. Attendance bands are a percentage of this: '
  '>=90% present, >=65% partial, below that absent.';

create index if not exists idx_lectures_batch on lectures(batch_id);

-- Raw Meet CSV uploads, one row per CSV row. Cleared after every process run.
create table if not exists uploads (
  id                    uuid primary key default gen_random_uuid(),
  lecture_id            uuid references lectures(id) on delete set null,
  sno                   int,
  participant_name_raw  text not null,
  -- Naive wall-clock times: the Meet CSV exports "9:30:00 AM" with no zone, and
  -- the calendar date always comes from the lecture. A timestamptz column would
  -- silently apply the session's zone.
  attendance_started    timestamp,
  joined_at             timestamp,
  attendance_stopped    timestamp,
  attended_duration_raw text,
  attended_minutes      numeric,
  meeting_code          text,
  matched_student_id    uuid references students(id) on delete set null,
  processed             boolean default false,
  uploaded_at           timestamptz default now()
);

create index if not exists idx_uploads_lecture   on uploads(lecture_id);
create index if not exists idx_uploads_meeting   on uploads(meeting_code);
create index if not exists idx_uploads_processed on uploads(processed);

create table if not exists attendance (
  id                     uuid primary key default gen_random_uuid(),
  student_id             uuid references students(id) on delete cascade not null,
  batch_id               uuid references batches(id) on delete cascade not null,
  lecture_id             uuid references lectures(id) on delete cascade not null,
  status                 attendance_status default 'absent',
  total_attended_minutes numeric,
  raw_upload_ids         uuid[],
  source                 attendance_source default 'manual',
  approved               boolean default false,
  approved_at            timestamptz,
  created_at             timestamptz default now(),
  unique (student_id, lecture_id)
);

create index if not exists idx_attendance_batch   on attendance(batch_id);
create index if not exists idx_attendance_lecture on attendance(lecture_id);
create index if not exists idx_attendance_student on attendance(student_id);


-- 5. FEES
create table if not exists student_fees (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid references students(id) on delete cascade not null,
  batch_id    uuid references batches(id) on delete cascade not null,
  total_fee   numeric not null,
  paid_amount numeric not null default 0,
  -- What the fee rule said was owed the day the student left, frozen. Null while
  -- enrolled. The unpaid remainder is void: recorded, never counted as a due.
  -- Also the ceiling on any later payment.
  expected_on_exit numeric,
  -- What they had paid that day. Anything above it since is recovered void.
  paid_at_exit     numeric,
  -- Set once by transfer_student(); makes student_fee_dues judge instalments by payment logs.
  transferred      boolean not null default false,
  discount_type    discount_type not null default 'percentage',
  discount_value   numeric not null default 0 check (discount_value >= 0),
  -- 'terminated' wins over paid/due: expected_on_exit is set only by terminate_enrolment().
  status      fee_status generated always as (
    case
      when expected_on_exit is not null then 'terminated'::fee_status
      when paid_amount >= total_fee then 'paid'::fee_status
      else 'due'::fee_status
    end
  ) stored,
  updated_at  timestamptz default now(),
  unique (student_id, batch_id)
);

-- Re-running this file on a database created before transferred existed.
alter table student_fees add column if not exists transferred boolean not null default false;

create index if not exists idx_fees_student on student_fees(student_id);
create index if not exists idx_fees_batch   on student_fees(batch_id);

-- Individual payment history. student_fees.paid_amount stays the running total.
create table if not exists fee_payment_logs (
  id             uuid primary key default gen_random_uuid(),
  student_fee_id uuid references student_fees(id) on delete cascade not null,
  student_id     uuid references students(id) on delete cascade not null,
  batch_id       uuid references batches(id) on delete cascade not null,
  amount         numeric not null check (amount > 0),
  payment_date   date not null default current_date,
  payment_method payment_method default 'other',
  notes          text,
  created_at     timestamptz default now()
);

create index if not exists idx_fee_logs_fee   on fee_payment_logs(student_fee_id);
create index if not exists idx_fee_logs_batch on fee_payment_logs(batch_id);

-- Payment log and running balance in one transaction.
--
-- SECURITY INVOKER on purpose. It is granted to `authenticated`, which includes
-- students, and it is safe only because RLS still applies to the INSERT and the
-- UPDATE inside it — a student's call fails on the policies. Do not add
-- SECURITY DEFINER.
create or replace function public.record_fee_payment(
  p_student_fee_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_payment_method payment_method default 'other',
  p_notes text default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  fee_row     student_fees%rowtype;
  log_row     fee_payment_logs%rowtype;
  updated_fee student_fees%rowtype;
  ceiling     numeric;
begin
  if p_amount is null or p_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  -- Lock the fee row. Concurrent payments serialize on this student/batch.
  select * into fee_row from student_fees where id = p_student_fee_id for update;

  if not found then
    raise exception 'Could not find the fee record';
  end if;

  ceiling := case when fee_row.status = 'terminated' then fee_row.expected_on_exit else fee_row.total_fee end;
  if fee_row.paid_amount + p_amount > ceiling then
    raise exception 'That is more than is owed. At most % can be logged.',
      greatest(ceiling - fee_row.paid_amount, 0);
  end if;

  insert into fee_payment_logs (
    student_fee_id, student_id, batch_id, amount,
    payment_date, payment_method, notes
  ) values (
    fee_row.id, fee_row.student_id, fee_row.batch_id, p_amount,
    p_payment_date, p_payment_method, p_notes
  )
  returning * into log_row;

  update student_fees
  set paid_amount = fee_row.paid_amount + p_amount,
      updated_at = now()
  where id = fee_row.id
  returning * into updated_fee;

  return jsonb_build_object('log', to_jsonb(log_row), 'fee', to_jsonb(updated_fee));
end;
$$;
revoke all on function public.record_fee_payment(uuid, numeric, date, payment_method, text) from public;
grant execute on function public.record_fee_payment(uuid, numeric, date, payment_method, text) to authenticated;


-- Every student pays 1000 on joining a batch. Booked as a payment against the fee,
-- not subtracted from the total, so the log and the balance agree.
-- Fires on insert only: re-adding a student reuses its fee row.
--
-- Nothing is logged for a student charged nothing — a 100% discount produces a
-- total_fee of 0, and a registration payment against 0 is not a fact. A fee
-- under 1000 logs only what was charged, so the log never exceeds the total.
--
-- Dated the day the student started (see set_join_date_from_batch), not the day the row was inserted.
create or replace function log_registration_fee()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  amount numeric;
  paid_on date;
begin
  -- A transfer that carries payments brings its own registration fee
  if current_setting('app.skip_registration', true) = 'on' then
    return new;
  end if;

  if new.total_fee is null or new.total_fee <= 0 then
    return new;
  end if;

  amount := least(1000, new.total_fee);

  -- Dated the day they started, which the join rule already worked out
  select m.joined_at into paid_on from batch_student_mapping m where m.batch_id = new.batch_id and m.student_id = new.student_id;
  paid_on := coalesce(paid_on, current_date);

  insert into fee_payment_logs (
    student_fee_id, student_id, batch_id, amount, payment_date, payment_method, notes
  ) values (
    new.id, new.student_id, new.batch_id, amount, paid_on, 'upi', 'Registration fee'
  );

  update student_fees
  set paid_amount = paid_amount + amount, updated_at = now()
  where id = new.id;

  return new;
end;
$$;

drop trigger if exists student_fees_registration_fee on student_fees;
create trigger student_fees_registration_fee
  after insert on student_fees
  for each row execute function log_registration_fee();


-- 6. ASSIGNMENTS
-- assigned_date is when the work was handed out; due_at is the deadline.
create table if not exists assignments (
  id            uuid primary key default gen_random_uuid(),
  batch_id      uuid references batches(id) on delete cascade not null,
  title         text not null,
  description   text,
  assigned_date date default current_date,
  due_at        timestamptz,
  created_at    timestamptz default now()
);

comment on column assignments.due_at is
  'Deadline as an absolute instant. Null = no deadline. A submission after it is still '
  'accepted — the client flags it late by comparing it against submitted_at.';

create index if not exists idx_assignments_batch on assignments(batch_id);

create table if not exists assignment_completions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid references assignments(id) on delete cascade not null,
  student_id    uuid references students(id) on delete cascade not null,
  submitted     boolean default false,
  submitted_via submission_channel default 'portal',
  submitted_at  timestamptz,
  mark          boolean default false not null,
  unique (assignment_id, student_id)
);

create index if not exists idx_ac_assignment on assignment_completions(assignment_id);
create index if not exists idx_ac_student    on assignment_completions(student_id);

-- One repo per student, not one per submission: editing the link from any
-- assignment's dialog re-points every past and future submission. Intentional.
-- The row belongs to the student, but the columns do not. RLS decides which row
-- a student may write; this decides what the values may be, so a hand-written
-- API call carrying submitted_at or submitted_via achieves nothing.
create or replace function guard_assignment_completion()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if is_admin() or is_tutor() then
    -- Admin/tutor can only set the manual mark — submission status is student-driven.
    if tg_op = 'UPDATE' then
      new.submitted     := old.submitted;
      new.submitted_via := old.submitted_via;
      new.submitted_at  := old.submitted_at;
    else
      new.submitted     := false;
      new.submitted_via := null;
      new.submitted_at  := null;
    end if;
    return new;
  end if;

  -- Students hand work in, and can't take it back or redo it.
  if new.submitted is not true then
    raise exception 'Submission status is set by the student';
  end if;
  if tg_op = 'UPDATE' and old.submitted then
    raise exception 'This assignment has already been handed in';
  end if;

  -- Server owns both, whatever the client sent.
  new.submitted_via := 'portal';
  new.submitted_at  := now();
  return new;
end;
$$;

drop trigger if exists assignment_completions_guard on assignment_completions;
create trigger assignment_completions_guard
  before insert or update on assignment_completions
  for each row execute function guard_assignment_completion();

-- One repo link per student per batch, so a second batch never shows the first one's
create table if not exists student_repos (
  student_id uuid references students(id) on delete cascade,
  batch_id   uuid references batches(id) on delete cascade,
  repo_url   text not null,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  primary key (student_id, batch_id)
);

-- The submit dialog already refuses a non-GitHub link, but that check lives in
-- the browser and the browser is not a lock: a student can PATCH this table
-- through the REST API directly. The value is rendered as a clickable link in
-- the admin's submission table, so it is constrained where it is written.
alter table student_repos drop constraint if exists student_repos_repo_url_github;
alter table student_repos add constraint student_repos_repo_url_github
  check (
    repo_url ~ '^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
    and length(repo_url) <= 200
  );

create or replace function touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists student_repos_touch_updated_at on student_repos;
create trigger student_repos_touch_updated_at
  before update on student_repos
  for each row execute function touch_updated_at();


-- 7. STUDY MATERIAL
-- The file itself lives in the private `materials` bucket, already permanently
-- watermarked at upload (client-side, before the bytes ever leave the browser).
-- A read is a plain storage fetch, gated by the storage policy in §10 — nothing
-- stamps it again, or even touches it, on the way out.
create table if not exists materials (
  id            uuid primary key default gen_random_uuid(),
  -- NULL means the material is for every student, not one batch.
  batch_id      uuid references batches(id) on delete cascade,
  -- Set when the file is an assignment handout rather than study material.
  -- batch_id is still set, so access follows the same enrolment rule.
  assignment_id uuid references assignments(id) on delete cascade,
  -- Who the material came from, for the listings. Not part of the watermark.
  tutor_id      uuid references tutors(id) on delete set null,
  title         text not null,
  description   text,
  -- Folder name when this came from a folder upload; NULL for a single file.
  -- One row per file either way — this only groups them in listings.
  folder        text,
  storage_path  text not null unique,   -- <batch|all>/materials/<uuid>.<ext> or <batch|all>/assignments/<assignment>/<uuid>.<ext>
  mime_type     text not null default 'application/pdf',
  size_bytes    bigint,
  page_count    int,
  uploaded_by   uuid,
  -- Null on a pageable file (PDF or image) means it predates client-side
  -- upload-time stamping and still needs a backfill. Every upload sets this
  -- from here on; never null for a kind that was never watermarked to begin with.
  watermarked_at timestamptz,
  created_at    timestamptz default now()
);

-- Re-running this file on a database created before watermarked_at existed.
alter table materials add column if not exists watermarked_at timestamptz;

comment on column materials.mime_type is
  'Decides how the file is delivered: PDFs and images are watermarked and paged, '
  'markdown and text are shown as-is, everything else is downloaded.';

create index if not exists idx_materials_batch      on materials(batch_id);
create index if not exists materials_assignment_id_idx on materials(assignment_id);
create index if not exists materials_tutor_id_idx   on materials(tutor_id);
create index if not exists materials_folder_idx     on materials(batch_id, folder);
create index if not exists materials_created_at_idx on materials(created_at desc);

-- Who opened what. A watermarked leak identifies the student; this says when.
create table if not exists material_views (
  id          uuid primary key default gen_random_uuid(),
  material_id uuid not null references materials(id) on delete cascade,
  student_id  uuid not null references students(id) on delete cascade,
  viewed_at   timestamptz not null default now()
);

create index if not exists idx_material_views_material on material_views(material_id);
create index if not exists idx_material_views_student  on material_views(student_id);

-- .docx is absent on purpose: it is converted to a PDF in the browser before
-- upload, so it never reaches storage as Word. 50 MB per file is what the
-- browser can hold in memory while stamping the watermark on the way in.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'materials', 'materials', false, 52428800,
  array[
    'application/pdf',
    'image/png', 'image/jpeg',
    'text/markdown', 'text/x-markdown', 'text/plain', 'text/csv',
    'application/json', 'application/zip',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/octet-stream'
  ]
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Public bucket for static app images (the payment QR, etc.) so they never
-- have to live in the git repo. Public = served straight off a CDN URL, no
-- signed URL needed — fine for an image with nothing sensitive in it.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('assets', 'assets', true, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;


-- 8. AUTH HELPERS
-- Policies trust app_metadata.role, which only the service role can write.
-- EDIT the email before running on a new project.
update auth.users
set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('role', 'admin')
where email = 'adminuser@deboistech.in';

create or replace function is_admin()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

create or replace function current_student_id()
returns uuid
language sql
stable
set search_path = public
as $$
  select id from students where auth_user_id = auth.uid();
$$;

create or replace function is_tutor()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'tutor', false);
$$;

create or replace function current_tutor_id()
returns uuid
language sql
stable
set search_path = public
as $$
  select id from tutors where auth_user_id = auth.uid();
$$;

-- security definer on purpose: a tutor's own RLS on `students`/`student_repos`
-- needs this, and batch_student_mapping already carries a student policy that
-- calls current_student_id() — which queries students. Evaluated as invoker,
-- that closes a cycle (students -> batch_student_mapping -> students) and
-- Postgres aborts with "stack depth limit exceeded". Running as the owner
-- here means this lookup never re-enters RLS, so it can never join that cycle.
create or replace function tutor_can_see_student(target_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from batch_student_mapping bsm
    join tutor_batch_mapping tbm on tbm.batch_id = bsm.batch_id
    join tutors t on t.id = tbm.tutor_id
    where t.auth_user_id = auth.uid()
      and bsm.student_id = target_student_id
  );
$$;

-- text::uuid raises rather than returning null, and the materials storage path's
-- first segment is "all" for everyone-facing files — casting that would error
-- out the whole policy check instead of just failing to match.
create or replace function safe_uuid(value text)
returns uuid
language sql
immutable
as $$
  select case when value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then value::uuid else null end;
$$;


-- 9. VIEWS
-- current_student_id() is defined above (§8): the student_fee_dues view below
-- resolves it at CREATE VIEW time, unlike a plpgsql function body, which only
-- resolves calls at execution. Views must come after the functions they use.
create or replace view batch_fee_summary as
select
  b.id as batch_id,
  b.name as batch_name,
  count(distinct bsm.student_id) filter (where bsm.status::text not in ('terminated', 'transferred')) as total_students,
  coalesce(sum(sf.total_fee) filter (where bsm.status::text not in ('terminated', 'transferred')), 0) as total_fees,
  coalesce(sum(sf.paid_amount), 0) as total_collected,
  coalesce(sum(greatest(sf.total_fee - sf.paid_amount, 0)) filter (where bsm.status::text not in ('terminated', 'transferred')), 0) as total_outstanding,
  b.is_test
from batches b
left join batch_student_mapping bsm on bsm.batch_id = b.id
left join student_fees sf on sf.batch_id = b.id and sf.student_id = bsm.student_id
group by b.id, b.name;

create or replace view batch_attendance_summary as
select
  b.id as batch_id,
  b.name as batch_name,
  count(distinct l.id) as total_lectures,
  count(distinct a.id) filter (where a.status = 'present' and a.approved) as present_count,
  count(distinct a.id) filter (where a.status = 'partial' and a.approved) as partial_count,
  count(distinct a.id) filter (where a.status = 'absent' and a.approved) as absent_count,
  count(distinct a.id) filter (where a.approved = false) as pending_approval
from batches b
left join lectures l on l.batch_id = b.id
left join attendance a on a.lecture_id = l.id
group by b.id, b.name;

create or replace view earning_breakdown as
select
  b.id   as batch_id,
  b.name as batch_name,
  count(bsm.id) filter (where bsm.status::text not in ('terminated', 'transferred')) as active_students,
  count(bsm.id) filter (where bsm.status =  'terminated') as terminated_students,

  -- Everything banked, whoever paid it.
  coalesce(sum(sf.paid_amount), 0) as collected,
  coalesce(sum(sf.paid_amount) filter (where bsm.status::text not in ('terminated', 'transferred')), 0) as collected_active,
  coalesce(sum(sf.paid_amount) filter (where bsm.status =  'terminated'), 0) as collected_terminated,

  -- Still expected from students who have not left.
  coalesce(sum(greatest(sf.total_fee - sf.paid_amount, 0))
    filter (where bsm.status::text not in ('terminated', 'transferred')), 0) as pending,

  -- Owed on the day they left and never paid. Recorded, never expected.
  coalesce(sum(greatest(coalesce(sf.expected_on_exit, 0) - sf.paid_amount, 0))
    filter (where bsm.status = 'terminated'), 0) as void_amount,

  -- The rest of their course fee, which never became due at all.
  coalesce(sum(greatest(sf.total_fee - coalesce(sf.expected_on_exit, 0), 0))
    filter (where bsm.status = 'terminated'), 0) as never_due,

  -- Void that came in after they left. Never more than the void itself.
  coalesce(sum(greatest(sf.paid_amount - coalesce(sf.paid_at_exit, sf.paid_amount), 0))
    filter (where bsm.status = 'terminated'), 0) as recovered,
  b.is_test
from batches b
left join batch_student_mapping bsm on bsm.batch_id = b.id
left join student_fees sf on sf.batch_id = b.id and sf.student_id = bsm.student_id
group by b.id, b.name;

alter view earning_breakdown set (security_invoker = on);
comment on view earning_breakdown is
  'Per-batch earnings. pending is what active students still owe; void_amount is what '
  'terminated students owed at exit and never paid. The two never mix.';

-- Views run with the owner's rights by default, which would bypass every policy
-- below. This makes them run as the caller instead.
alter view batch_fee_summary        set (security_invoker = on);
alter view batch_attendance_summary set (security_invoker = on);

-- This one is the exception, and deliberately keeps owner rights: it exists to
-- show a student their balance WITHOUT showing them total_fee or paid_amount.
-- Column-level grants cannot express that, because admins and students are both
-- the `authenticated` role. Reaching past RLS is the point, so it carries its own
-- `where` on current_student_id() instead.
create or replace view student_fee_dues as
select
  sf.id,
  sf.student_id,
  sf.batch_id,
  greatest(sf.total_fee - sf.paid_amount, 0) as amount_due,
  sf.status,
  sf.updated_at,
  case
    when sf.total_fee <= 0 then 2
    when sf.paid_amount >= sf.total_fee then 2
    -- Moved fee: any payment besides the registration fee counts as the 1st instalment.
    when sf.transferred then
      case when exists (
        select 1 from fee_payment_logs l
        where l.student_fee_id = sf.id and l.notes is distinct from 'Registration fee'
      ) then 1 else 0 end
    when sf.paid_amount >= least(1000, sf.total_fee)
                         + round(greatest(sf.total_fee - 1000, 0) / 2.0) then 1
    else 0
  end as paid_through
from student_fees sf
where sf.student_id = current_student_id()
  and exists (
    select 1 from batch_student_mapping m
    where m.student_id = sf.student_id and m.batch_id = sf.batch_id and m.status::text <> 'transferred'
  );

grant select on student_fee_dues to authenticated;

comment on view student_fee_dues is
  'Portal-facing fee row: the outstanding balance only. total_fee and paid_amount '
  'never leave the database for a student. Admin reads student_fees directly.';


-- 10. ROW LEVEL SECURITY
alter table tutors                 enable row level security;
alter table batches                enable row level security;
alter table students               enable row level security;
alter table batch_student_mapping  enable row level security;
alter table tutor_batch_mapping    enable row level security;
alter table lectures               enable row level security;
alter table uploads                enable row level security;
alter table attendance             enable row level security;
alter table student_fees           enable row level security;
alter table fee_payment_logs       enable row level security;
alter table assignments            enable row level security;
alter table assignment_completions enable row level security;
alter table student_repos          enable row level security;
alter table materials              enable row level security;
alter table material_views         enable row level security;
alter table batch_programs         enable row level security;

-- Reference data, no secrets: every signed-in user reads the three rows, only an
-- admin changes them.
drop policy if exists read_programs on batch_programs;
create policy read_programs on batch_programs for select to authenticated using (true);

-- ── Admin — full access everywhere ──────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array[
    'tutors', 'batches', 'students', 'batch_student_mapping', 'tutor_batch_mapping',
    'lectures', 'uploads', 'attendance', 'student_fees', 'fee_payment_logs',
    'assignments', 'assignment_completions', 'student_repos', 'materials', 'material_views',
    'batch_programs'
  ] loop
    execute format('drop policy if exists admin_full_access on %I', t);
    execute format(
      'create policy admin_full_access on %I for all using (is_admin()) with check (is_admin())', t
    );
  end loop;
end $$;

-- ── Student — read-only, scoped to their own data ───────────────────────────
drop policy if exists student_read_own on students;
create policy student_read_own on students
  for select using (auth_user_id = auth.uid());

drop policy if exists student_read_own on batch_student_mapping;
create policy student_read_own on batch_student_mapping
  for select using (student_id = current_student_id() and status::text <> 'transferred');

drop policy if exists student_read_own on batches;
create policy student_read_own on batches
  for select using (
    id in (select batch_id from batch_student_mapping where student_id = current_student_id() and status::text <> 'transferred')
  );

drop policy if exists student_read_own on lectures;
create policy student_read_own on lectures
  for select using (
    batch_id in (select batch_id from batch_student_mapping where student_id = current_student_id() and status::text <> 'transferred')
  );

-- Approved rows only: unapproved attendance is pending review, not fact.
drop policy if exists student_read_own on attendance;
create policy student_read_own on attendance
  for select using (student_id = current_student_id() and approved = true);

-- No student policy on student_fees: the portal reads student_fee_dues instead,
-- which exposes the balance without total_fee or paid_amount. See section 9.

drop policy if exists student_read_own on fee_payment_logs;
create policy student_read_own on fee_payment_logs
  for select using (
    student_id = current_student_id()
    and batch_id in (select batch_id from batch_student_mapping where student_id = current_student_id() and status::text <> 'transferred')
  );

drop policy if exists student_read_own on assignments;
create policy student_read_own on assignments
  for select using (
    batch_id in (select batch_id from batch_student_mapping where student_id = current_student_id() and status::text <> 'transferred')
  );

drop policy if exists student_read_own on assignment_completions;
create policy student_read_own on assignment_completions
  for select using (student_id = current_student_id());

drop policy if exists student_read_own on student_repos;
create policy student_read_own on student_repos
  for select using (student_id = current_student_id());

drop policy if exists student_read_own on material_views;
create policy student_read_own on material_views
  for select using (student_id = current_student_id());

-- The client logs its own open now that there is no service-role function in the
-- loop. student_id is never sent by the client — it comes from the column
-- default below, so an admin's open (current_student_id() is null there) fails
-- the not-null constraint and is simply never logged, same as before.
alter table material_views alter column student_id set default current_student_id();

drop policy if exists student_insert_own on material_views;
create policy student_insert_own on material_views
  for insert with check (student_id = current_student_id());

-- Metadata only; the storage policy in this section gates the bytes directly.
-- The `batch_id is null` branch is deliberately absent: a material for everyone
-- is still only for enrolled students, and every student now has a batch.
drop policy if exists student_read_own on materials;
create policy student_read_own on materials
  for select using (
    batch_id in (
      select batch_id from batch_student_mapping
      where student_id = current_student_id() and status = 'active'
    )
  );

-- ── Student — the two tables they may write ─────────────────────────────────
drop policy if exists student_insert_own on student_repos;
create policy student_insert_own on student_repos
  for insert with check (
    student_id = current_student_id()
    and batch_id in (select batch_id from batch_student_mapping where student_id = current_student_id())
  );

drop policy if exists student_update_own on student_repos;
create policy student_update_own on student_repos
  for update using (student_id = current_student_id())
  with check (
    student_id = current_student_id()
    and batch_id in (select batch_id from batch_student_mapping where student_id = current_student_id())
  );

-- Enrolment gate, and closed once the batch has ended. A late submission is still accepted, just flagged
-- client-side by comparing submitted_at against the assignment's due_at.
drop policy if exists student_insert_own on assignment_completions;
create policy student_insert_own on assignment_completions
  for insert with check (
    student_id = current_student_id()
    and assignment_id in (
      select a.id
      from assignments a
      join batch_student_mapping m on m.batch_id = a.batch_id
      join batches b on b.id = a.batch_id
      where m.student_id = current_student_id()
        and m.status = 'active'
        and b.ended_at is null
    )
  );

-- `submitted = false` in USING freezes a row the moment it is handed in, so a
-- student can move work from unsubmitted to submitted exactly once and can never
-- touch a row a coordinator has already marked.
drop policy if exists student_update_own on assignment_completions;
create policy student_update_own on assignment_completions
  for update using (
    student_id = current_student_id()
    and submitted = false
    and assignment_id in (
      select a.id
      from assignments a
      join batch_student_mapping m on m.batch_id = a.batch_id
      join batches b on b.id = a.batch_id
      where m.student_id = current_student_id()
        and m.status = 'active'
        and b.ended_at is null
    )
  )
  with check (
    student_id = current_student_id()
    and assignment_id in (
      select a.id
      from assignments a
      join batch_student_mapping m on m.batch_id = a.batch_id
      join batches b on b.id = a.batch_id
      where m.student_id = current_student_id()
        and m.status = 'active'
        and b.ended_at is null
    )
  );

-- No student policy on tutors / tutor_batch_mapping / uploads: RLS default-denies.

-- ── Tutor — read-only, scoped to their assigned batches ─────────────────────
-- No policy on student_fees / fee_payment_logs / payment_claims / feedback for
-- a tutor: finance and feedback are admin/student only, RLS default-denies.
drop policy if exists tutor_read_own on tutors;
create policy tutor_read_own on tutors
  for select using (auth_user_id = auth.uid());

drop policy if exists tutor_read_own on tutor_batch_mapping;
create policy tutor_read_own on tutor_batch_mapping
  for select using (tutor_id = (select current_tutor_id()));

drop policy if exists tutor_read_own on batches;
create policy tutor_read_own on batches
  for select using (id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())));

drop policy if exists tutor_read_own on batch_student_mapping;
create policy tutor_read_own on batch_student_mapping
  for select using (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())));

-- Profile fields only — the students table carries no fee data, so a plain
-- select never leaks anything financial.
drop policy if exists tutor_read_own on students;
create policy tutor_read_own on students
  for select using (tutor_can_see_student(id));

drop policy if exists tutor_read_own on student_repos;
create policy tutor_read_own on student_repos
  for select using (tutor_can_see_student(student_id));

-- ── Tutor — manage their own batches' lectures, attendance and materials ────
do $$
declare t text;
begin
  foreach t in array array['lectures', 'attendance', 'assignments', 'materials'] loop
    execute format('drop policy if exists tutor_manage_own on %I', t);
    execute format(
      'create policy tutor_manage_own on %I for all using (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id()))) with check (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))', t
    );
  end loop;
end $$;

drop policy if exists tutor_manage_own on uploads;
create policy tutor_manage_own on uploads
  for all using (
    lecture_id in (select id from lectures where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  )
  with check (
    lecture_id in (select id from lectures where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  );

-- Grading only: the guard trigger already limits a tutor's write to the `mark`
-- column, same as admin. No delete — a tutor cannot take back a submission.
drop policy if exists tutor_read_own on assignment_completions;
create policy tutor_read_own on assignment_completions
  for select using (
    assignment_id in (select id from assignments where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  );

drop policy if exists tutor_insert_own on assignment_completions;
create policy tutor_insert_own on assignment_completions
  for insert with check (
    assignment_id in (select id from assignments where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  );

drop policy if exists tutor_update_own on assignment_completions;
create policy tutor_update_own on assignment_completions
  for update using (
    assignment_id in (select id from assignments where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  )
  with check (
    assignment_id in (select id from assignments where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  );

drop policy if exists tutor_read_own on material_views;
create policy tutor_read_own on material_views
  for select using (
    material_id in (select id from materials where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  );

-- ── Storage ─────────────────────────────────────────────────────────────────
-- Every stored file is already the final, watermarked copy, so a student reads
-- it straight from the bucket — gated by the same enrolment rule as the
-- `materials` row itself, just re-expressed against storage.objects.name since
-- a storage policy cannot reference the students' own RLS-filtered view.
drop policy if exists "student reads own material files" on storage.objects;
create policy "student reads own material files" on storage.objects
  for select
  using (
    bucket_id = 'materials'
    and exists (
      select 1 from materials m
      where m.storage_path = storage.objects.name
        and m.batch_id in (
          select batch_id from batch_student_mapping
          where student_id = current_student_id() and status = 'active'
        )
    )
  );

drop policy if exists "admin manages material files" on storage.objects;
create policy "admin manages material files" on storage.objects
  for all
  using (bucket_id = 'materials' and is_admin())
  with check (bucket_id = 'materials' and is_admin());

-- Keyed off the path itself (<batchId>/materials/... or <batchId>/assignments/...),
-- not the materials row: uploadMaterial() writes the file before the row exists,
-- so a join through materials would reject the upload that creates it.
drop policy if exists "tutor manages own batch material files" on storage.objects;
create policy "tutor manages own batch material files" on storage.objects
  for all
  using (
    bucket_id = 'materials'
    and safe_uuid(split_part(storage.objects.name, '/', 1)) in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id()))
  )
  with check (
    bucket_id = 'materials'
    and safe_uuid(split_part(storage.objects.name, '/', 1)) in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id()))
  );

-- Public bucket means anyone can already read; this only gates who can write.
drop policy if exists "admin manages asset files" on storage.objects;
create policy "admin manages asset files" on storage.objects
  for all
  using (bucket_id = 'assets' and is_admin())
  with check (bucket_id = 'assets' and is_admin());


-- 11. BATCH LIFECYCLE AND LEAVERS
-- The old one-argument version would make a bare call ambiguous.
drop function if exists end_batch(uuid);
create or replace function end_batch(p_batch_id uuid, p_ended_on date default current_date)
returns batches
language plpgsql
security definer
set search_path = public
as $$
declare updated batches;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;
  if exists (select 1 from batches where id = p_batch_id and start_date > p_ended_on) then
    raise exception 'A batch cannot end before it starts';
  end if;

  update batches
  set status = 'completed', ended_at = p_ended_on
  where id = p_batch_id
  returning * into updated;

  if not found then
    raise exception 'Batch not found';
  end if;

  return updated;
end $$;

revoke all on function end_batch(uuid, date) from public;
grant execute on function end_batch(uuid, date) to authenticated;

create or replace function terminate_enrolment(p_mapping_id uuid, p_left_on date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m            batch_student_mapping%rowtype;
  batch_start  date;
  fee_row      student_fees%rowtype;
  instalment   numeric;
  due_count    int := 0;
  expected     numeric := 0;
  void_amount  numeric := 0;
  auth_id      uuid;
  still_active boolean;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  select * into m from batch_student_mapping where id = p_mapping_id;
  if not found then
    raise exception 'Enrolment not found';
  end if;

  -- Instalments count from the day the student started, not the batch start
  batch_start := m.joined_at;
  select * into fee_row from student_fees
  where student_id = m.student_id and batch_id = m.batch_id
  for update;

  -- Also for a zero fee (expected 0), so every leaver's fee row reads 'terminated'.
  if found then
    instalment := round(greatest(fee_row.total_fee - 1000, 0) / 2.0);

    -- Due on the day itself, so `>=`, not `>`.
    if batch_start is not null then
      if p_left_on >= batch_start + 15 then due_count := 1; end if;
      if p_left_on >= batch_start + 30 then due_count := 2; end if;
    end if;

    -- Registration is collected at sign-up and always owed; instalments only
    -- once their date has been reached.
    expected := least(fee_row.total_fee, least(1000, fee_row.total_fee) + instalment * due_count);
    void_amount := greatest(expected - fee_row.paid_amount, 0);

    update student_fees
    set expected_on_exit = expected,
        paid_at_exit = fee_row.paid_amount,
        updated_at = now()
    where id = fee_row.id;
  end if;

  -- Their documents go with them
  insert into document_cleanup (path)
  select p from unnest(array[m.offer_letter_path, m.cert_path]) as p where p is not null
  on conflict do nothing;

  update batch_student_mapping
  set status = 'terminated', left_on = p_left_on,
      offer_letter_path = null, cert_path = null, offer_letter_shared = false, cert_shared = false
  where id = p_mapping_id;

  -- Checked after the update, so this enrolment is already out of the running.
  select exists (
    select 1 from batch_student_mapping m2
    join batches b2 on b2.id = m2.batch_id
    where m2.student_id = m.student_id
      and m2.status = 'active'
      and b2.ended_at is null
  ) into still_active;

  select auth_user_id into auth_id from students where id = m.student_id;

  if auth_id is not null and not still_active then
    -- Unlinked first, so this works whatever the foreign key does on delete
    update students set auth_user_id = null, password_rotated = false where id = m.student_id;
    delete from auth.users where id = auth_id;
  end if;

  return jsonb_build_object(
    'instalments_due', due_count,
    'expected_on_exit', expected,
    'void_amount', void_amount,
    'login_revoked', auth_id is not null and not still_active
  );
end $$;

revoke all on function terminate_enrolment(uuid, date) from public;
grant execute on function terminate_enrolment(uuid, date) to authenticated;

-- Moves one student to another running batch. The old enrolment stays as Transferred with its data, read-only;
-- its documents are dropped. With p_carry the payments are copied to the new batch and stop counting in the old one.
create or replace function transfer_student(
  p_mapping_id uuid, p_to_batch uuid, p_fee numeric, p_carry boolean, p_joined_on date default null, p_count_earlier boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  m       batch_student_mapping%rowtype;
  source  batches%rowtype;
  target  batches%rowtype;
  old_fee student_fees%rowtype;
  new_fee student_fees%rowtype;
  who     text;
  pending int;
  new_map uuid;
  carried numeric := 0;
  today   date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  select * into m from batch_student_mapping where id = p_mapping_id for update;
  if not found then
    raise exception 'Enrolment not found';
  end if;
  select name into who from students where id = m.student_id;

  if m.status <> 'active' then
    raise exception '% is not active in this batch', who;
  end if;

  select * into source from batches where id = m.batch_id;
  if source.ended_at is not null then
    raise exception '% is in a finished batch: add them to the new batch instead of transferring', who;
  end if;

  select * into target from batches where id = p_to_batch;
  if not found then
    raise exception 'Target batch not found';
  end if;
  if target.ended_at is not null or target.status = 'completed' then
    raise exception 'The target batch has ended';
  end if;
  if exists (select 1 from batch_student_mapping where batch_id = p_to_batch and student_id = m.student_id) then
    raise exception '% is already in the target batch', who;
  end if;

  select count(*) into pending from payment_claims
  where student_id = m.student_id and batch_id = m.batch_id and status = 'pending';
  if pending > 0 then
    raise exception 'Clear % payment claims for % first', pending, who;
  end if;

  if p_fee is null or p_fee < 0 then
    raise exception 'Fee must be 0 or more';
  end if;
  if target.base_fee is not null and p_fee > target.base_fee then
    raise exception 'Fee is above the base fee of %', target.base_fee;
  end if;

  select * into old_fee from student_fees where student_id = m.student_id and batch_id = m.batch_id for update;
  if p_carry then
    if not found then
      raise exception '% has no fee to carry over', who;
    end if;
    if p_fee < old_fee.paid_amount then
      raise exception 'Fee is below the % already paid by %', old_fee.paid_amount, who;
    end if;
  end if;

  -- The join date rule runs unless a date was given
  insert into batch_student_mapping (batch_id, student_id, joined_at, count_earlier_work)
  values (p_to_batch, m.student_id, p_joined_on, p_count_earlier)
  returning id into new_map;

  if p_carry then
    -- The carried payments already include the registration fee
    perform set_config('app.skip_registration', 'on', true);
    insert into student_fees (student_id, batch_id, total_fee, paid_amount, transferred, discount_type, discount_value)
    values (m.student_id, p_to_batch, p_fee, 0, true, 'amount', greatest(coalesce(target.base_fee, p_fee) - p_fee, 0))
    returning * into new_fee;
    perform set_config('app.skip_registration', 'off', true);

    insert into fee_payment_logs (student_fee_id, student_id, batch_id, amount, payment_date, payment_method, notes)
    select new_fee.id, l.student_id, p_to_batch, l.amount, l.payment_date, l.payment_method,
           concat_ws(' · ', l.notes, 'Transferred from ' || source.name || ', counted for this batch')
    from fee_payment_logs l
    where l.student_fee_id = old_fee.id;

    carried := old_fee.paid_amount;
    update student_fees set paid_amount = carried where id = new_fee.id;

    update fee_payment_logs
    set notes = concat_ws(' · ', notes, 'Transferred to ' || target.name || ', not counted here')
    where student_fee_id = old_fee.id;

    -- Nothing left to count or collect in the old batch
    update student_fees
    set paid_at_exit = old_fee.paid_amount, expected_on_exit = 0, paid_amount = 0, updated_at = now()
    where id = old_fee.id;
  else
    -- The registration fee trigger books the Rs 1,000 on the new fee
    insert into student_fees (student_id, batch_id, total_fee, paid_amount, discount_type, discount_value)
    values (m.student_id, p_to_batch, p_fee, 0, 'amount', greatest(coalesce(target.base_fee, p_fee) - p_fee, 0));

    -- The old fee stays as it is, frozen at what was paid: no more payments
    update student_fees
    set paid_at_exit = paid_amount, expected_on_exit = paid_amount, updated_at = now()
    where student_id = m.student_id and batch_id = m.batch_id;
  end if;

  insert into document_cleanup (path)
  select p from unnest(array[m.offer_letter_path, m.cert_path]) as p where p is not null
  on conflict do nothing;

  update batch_student_mapping
  set status = 'transferred', left_on = today,
      offer_letter_path = null, cert_path = null, offer_letter_shared = false, cert_shared = false
  where id = p_mapping_id;

  return jsonb_build_object('mapping_id', new_map, 'carried', carried);
end $$;

revoke all on function transfer_student(uuid, uuid, numeric, boolean, date, boolean) from public;
grant execute on function transfer_student(uuid, uuid, numeric, boolean, date, boolean) to authenticated;

-- The client has no rights on auth.users, so the login goes here, unlinked first. Everything else cascades off students.id.
create or replace function delete_student(p_student_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare auth_id uuid;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  select auth_user_id into auth_id from students where id = p_student_id;
  if not found then
    raise exception 'Student not found';
  end if;

  if auth_id is not null then
    update students set auth_user_id = null where id = p_student_id;
    delete from auth.users where id = auth_id;
  end if;

  delete from students where id = p_student_id;

  -- Hand the freed ref back: without this the next student skips it and the dashboard shows a hole.
  perform resync_student_code_seq();
end $$;

revoke all on function delete_student(uuid) from public;
grant execute on function delete_student(uuid) to authenticated;

-- One way: the batch and everyone in it leave the live numbers for good. Their refs are re-issued from the test
-- series and the live counter is resynced, so refs at the top of the stack come back and refs in the middle leave a gap.
create or replace function convert_batch_to_test(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  shared text;
  moved  int;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  if not exists (select 1 from batches where id = p_batch_id) then
    raise exception 'Batch not found';
  end if;
  if exists (select 1 from batches where id = p_batch_id and is_test) then
    raise exception 'Already a test batch';
  end if;

  -- A student in a live batch as well would be both kinds.
  select string_agg(s.name, ', ') into shared
  from batch_student_mapping m
  join students s on s.id = m.student_id
  where m.batch_id = p_batch_id
    and exists (select 1 from batch_student_mapping o where o.student_id = m.student_id and o.batch_id <> p_batch_id);
  if shared is not null then
    raise exception 'Also in other batches: %', shared;
  end if;

  update batches set is_test = true where id = p_batch_id;

  with moved_rows as (
    update students
    set is_test = true, student_code = next_test_student_code()
    where id in (select student_id from batch_student_mapping where batch_id = p_batch_id)
    returning 1
  )
  select count(*) into moved from moved_rows;

  perform resync_student_code_seq();
  return jsonb_build_object('converted', moved);
end $$;

revoke all on function convert_batch_to_test(uuid) from public;
grant execute on function convert_batch_to_test(uuid) to authenticated;

-- Tutor row first (assignments cascade): tutors.auth_user_id -> auth.users has no cascade. Authored rows keep, author nulled.
create or replace function delete_tutor(p_tutor_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare auth_id uuid;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  select auth_user_id into auth_id from tutors where id = p_tutor_id;
  if not found then
    raise exception 'Tutor not found';
  end if;

  delete from tutors where id = p_tutor_id;

  -- A login shared with a student account is theirs too: keep it.
  if auth_id is not null and not exists (select 1 from students where auth_user_id = auth_id) then
    delete from auth.users where id = auth_id;
  end if;
end $$;

revoke all on function delete_tutor(uuid) from public;
grant execute on function delete_tutor(uuid) to authenticated;

-- Files cannot be removed from SQL, so their paths wait here until an admin opens the dashboard
create table if not exists document_cleanup (
  path text primary key
);

alter table document_cleanup enable row level security;
drop policy if exists admin_full_access on document_cleanup;
create policy admin_full_access on document_cleanup
  for all using (is_admin()) with check (is_admin());

-- Things that went wrong in the background or in bulk, shown in the admin notices until cleared
do $$ begin create type failure_kind as enum ('cleanup', 'document_email', 'csv_import', 'login_create'); exception when duplicate_object then null; end $$;

create table if not exists action_failures (
  id         uuid primary key default gen_random_uuid(),
  kind       failure_kind not null,
  detail     text not null,
  created_at timestamptz not null default now()
);

alter table action_failures enable row level security;
drop policy if exists admin_full_access on action_failures;
create policy admin_full_access on action_failures
  for all using (is_admin()) with check (is_admin());

-- Students whose login and documents go within p_days, with what the admin may want to settle first
create or replace function expiring_students(p_days int default 14)
returns table (
  student_id uuid, student_name text, student_code text, batch_name text,
  ended_on date, delete_on date, owed numeric, docs_made int, docs_shared int
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  return query
  select s.id, s.name, s.student_code, b.name,
         b.ended_at, coalesce(b.ended_at, s.no_batch_since) + 90,
         greatest(coalesce(sf.total_fee, 0) - coalesce(sf.paid_amount, 0), 0),
         (m.offer_letter_path is not null)::int + (m.cert_path is not null)::int,
         m.offer_letter_shared::int + m.cert_shared::int
  from students s
  left join lateral (
    select m2.* from batch_student_mapping m2
    join batches b2 on b2.id = m2.batch_id
    where m2.student_id = s.id
    order by b2.ended_at desc nulls last
    limit 1
  ) m on true
  left join batches b on b.id = m.batch_id
  left join student_fees sf on sf.student_id = s.id and sf.batch_id = m.batch_id
  where s.auth_user_id is not null
    and not s.is_test
    and not exists (
      select 1 from batch_student_mapping m3
      join batches b3 on b3.id = m3.batch_id
      where m3.student_id = s.id and m3.status = 'active' and b3.ended_at is null
    )
    and coalesce(b.ended_at, s.no_batch_since) is not null
    and coalesce(b.ended_at, s.no_batch_since) + 90 <= current_date + p_days
  order by 6;
end $$;

revoke all on function expiring_students(int) from public;
grant execute on function expiring_students(int) to authenticated;

-- 90 days after a batch ends, with nothing running, the login and documents go; every other record stays
create or replace function expire_students()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  expired record;
  removed int := 0;
begin
  -- cron runs this with no JWT; a signed-in caller must be an admin
  if auth.uid() is not null and not is_admin() then
    raise exception 'Admin only';
  end if;

  -- Read notifications are kept 30 days
  delete from notifications where read_at < now() - interval '30 days';

  for expired in
    select s.id as student_id, s.auth_user_id
    from students s
    where not s.is_test
      -- a login to remove, or documents and an open enrolment still to close
      and (
        s.auth_user_id is not null
        or exists (
          select 1 from batch_student_mapping x
          where x.student_id = s.id and (x.status = 'active' or x.offer_letter_path is not null or x.cert_path is not null)
        )
      )
      and (
        -- has had a batch, and none is running or inside its 90 days
        (
          exists (select 1 from batch_student_mapping m where m.student_id = s.id)
          and not exists (
            select 1 from batch_student_mapping m2
            join batches b2 on b2.id = m2.batch_id
            where m2.student_id = s.id
              and m2.status = 'active'
              and (b2.ended_at is null or b2.ended_at + 90 > current_date)
          )
        )
        -- or has had no batch for 90 days
        or (
          not exists (select 1 from batch_student_mapping m3 where m3.student_id = s.id)
          and s.no_batch_since is not null
          and s.no_batch_since + 90 <= current_date
        )
      )
  loop
    -- One student failing must not stop the rest; it is reported in the admin notices
    begin
      insert into document_cleanup (path)
      select p from batch_student_mapping m, unnest(array[m.offer_letter_path, m.cert_path]) as p
      where m.student_id = expired.student_id and p is not null
      on conflict do nothing;

      update batch_student_mapping
      set status = case when status = 'active' then 'archived'::mapping_status else status end,
          offer_letter_path = null, cert_path = null, offer_letter_shared = false, cert_shared = false
      where student_id = expired.student_id;

      -- Unlinked first, so this works whatever the foreign key does on delete
      update students set auth_user_id = null, password_rotated = false, no_batch_since = null where id = expired.student_id;
      if expired.auth_user_id is not null then
        delete from auth.users where id = expired.auth_user_id;
      end if;
      removed := removed + 1;
    exception when others then
      insert into action_failures (kind, detail)
      values ('cleanup', 'Clean-up failed for ' || (select name from students where id = expired.student_id) || ': ' || sqlerrm);
    end;
  end loop;

  return removed;
end $$;

revoke all on function expire_students() from public, anon;
grant execute on function expire_students() to authenticated;

-- Daily at 02:00 India time. Needs pg_cron; if it is not enabled, run expire_students() by hand
do $$ begin
  create extension if not exists pg_cron;
  perform cron.schedule('expire-students', '30 20 * * *', 'select public.expire_students()');
exception when others then
  raise notice 'pg_cron not available (%), schedule expire_students() by hand', sqlerrm;
end $$;

create or replace function delete_fee_payment(p_log_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  log_row fee_payment_logs%rowtype;
  fee_row student_fees%rowtype;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  select * into log_row from fee_payment_logs where id = p_log_id;
  if not found then
    raise exception 'Payment not found';
  end if;

  if log_row.notes = 'Registration fee' then
    raise exception 'The registration fee cannot be deleted';
  end if;

  -- Locked before the delete, so a concurrent payment cannot read a stale total.
  select * into fee_row from student_fees where id = log_row.student_fee_id for update;
  if not found then
    raise exception 'Could not find the fee record';
  end if;

  delete from fee_payment_logs where id = p_log_id;

  update student_fees
  set paid_amount = greatest(coalesce(fee_row.paid_amount, 0) - log_row.amount, 0),
      updated_at = now()
  where id = fee_row.id
  returning * into fee_row;

  return to_jsonb(fee_row);
end $$;

revoke all on function delete_fee_payment(uuid) from public;
grant execute on function delete_fee_payment(uuid) to authenticated;

create or replace function resync_student_code_seq()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  prefix       text := student_code_prefix();
  test_prefix  text := 'DBT-TEST-' || student_code_year() || '-';
  highest      bigint;
  highest_test bigint;
begin
  -- The SQL editor carries no JWT, so "no caller" is allowed — that is where this
  -- gets run. A signed-in caller must be an admin.
  if auth.uid() is not null and not is_admin() then
    raise exception 'Admin only';
  end if;

  -- Digits after the prefix. Other years carry a different prefix and a
  -- different string, so they can never collide with this one.
  select max(nullif(regexp_replace(substring(student_code from length(prefix) + 1), '\D', '', 'g'), '')::bigint)
  into highest
  from students
  where student_code like prefix || '%';

  if highest is null then
    -- Nobody left under this prefix: the next call starts at 1.
    perform setval('student_code_seq', 1, false);
  else
    perform setval('student_code_seq', highest);
  end if;

  -- The test series rewinds the same way.
  select max(nullif(regexp_replace(substring(student_code from length(test_prefix) + 1), '\D', '', 'g'), '')::bigint)
  into highest_test
  from students
  where student_code like test_prefix || '%';

  if highest_test is null then
    perform setval('student_test_code_seq', 1, false);
  else
    perform setval('student_test_code_seq', highest_test);
  end if;

  -- The code the next student will get. Worked out, not consumed.
  return prefix || lpad((coalesce(highest, 0) + 1)::text, 3, '0');
end $$;

revoke all on function resync_student_code_seq() from public, anon;
grant execute on function resync_student_code_seq() to authenticated;


-- 12. FEEDBACK
create table if not exists feedback (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid references students(id) on delete cascade not null,
  kind        feedback_kind not null default 'bug',
  message     text not null check (length(btrim(message)) > 0),
  -- Captured, not typed: the page and browser are what make a bug report usable.
  page        text,
  user_agent  text,
  status      feedback_status not null default 'open',
  created_at  timestamptz default now(),
  resolved_at timestamptz
);

create index if not exists idx_feedback_student on feedback(student_id);
create index if not exists idx_feedback_status  on feedback(status);

alter table feedback enable row level security;

drop policy if exists admin_full_access on feedback;
create policy admin_full_access on feedback
  for all using (is_admin()) with check (is_admin());

drop policy if exists student_read_own on feedback;
create policy student_read_own on feedback
  for select using (student_id = current_student_id());

-- Insert only, and only as themselves. No update policy on purpose: a student
-- must not be able to mark their own report resolved or edit it after the fact.
drop policy if exists student_insert_own on feedback;
create policy student_insert_own on feedback
  for insert with check (student_id = current_student_id());

-- resolved_at follows status rather than being set by hand in two places.
create or replace function stamp_feedback_resolved()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'resolved' and coalesce(old.status, 'open') <> 'resolved' then
    new.resolved_at := now();
  elsif new.status = 'open' then
    new.resolved_at := null;
  end if;
  return new;
end $$;

drop trigger if exists feedback_resolved_stamp on feedback;
create trigger feedback_resolved_stamp
  before insert or update on feedback
  for each row execute function stamp_feedback_resolved();


-- 13. APP SETTINGS
-- One row, admin-toggled. Every signed-in user reads it; only an admin writes it.
create table if not exists app_settings (
  id               uuid primary key default gen_random_uuid(),
  maintenance_mode boolean not null default false,
  updated_at       timestamptz default now()
);

insert into app_settings (maintenance_mode)
select false
where not exists (select 1 from app_settings);

alter table app_settings enable row level security;

drop policy if exists read_settings on app_settings;
create policy read_settings on app_settings for select to authenticated using (true);

drop policy if exists admin_full_access on app_settings;
create policy admin_full_access on app_settings
  for all using (is_admin()) with check (is_admin());


-- 14. PAYMENT CLAIMS
-- A student saying "I paid, here's the transaction id and amount" — pure
-- self-reported intimation so they stop having to call/message for the QR.
-- It does not touch student_fees or fee_payment_logs; the admin still logs
-- the real payment by hand after checking the bank statement, same as always.
create table if not exists payment_claims (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid references students(id) on delete cascade not null,
  batch_id       uuid references batches(id) on delete cascade,
  transaction_id text not null check (length(btrim(transaction_id)) > 0),
  amount         numeric not null check (amount > 0),
  created_at     timestamptz default now()
);

-- pending until an admin approves (logs the payment) or dismisses it. Claims from
-- before approval existed were logged by hand, so they backfill as dismissed; the
-- default flips straight after so new ones start pending.
alter table payment_claims add column if not exists status claim_status not null default 'dismissed';
alter table payment_claims alter column status set default 'pending';

create index if not exists idx_payment_claims_student on payment_claims(student_id);

alter table payment_claims enable row level security;

drop policy if exists admin_full_access on payment_claims;
create policy admin_full_access on payment_claims
  for all using (is_admin()) with check (is_admin());

-- Insert only, and only as themselves. No update/delete on purpose: once
-- sent, a claim is fixed — same as a feedback report.
drop policy if exists student_insert_own on payment_claims;
create policy student_insert_own on payment_claims
  for insert with check (student_id = current_student_id() and status = 'pending');

-- Logs the claimed amount as a UPI payment on the student's fee for that batch and
-- marks the claim approved, in one transaction. INVOKER, like record_fee_payment:
-- RLS still applies, and the is_admin() check makes the intent explicit.
create or replace function approve_payment_claim(p_claim_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  c      payment_claims%rowtype;
  fee_id uuid;
  result jsonb;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;

  select * into c from payment_claims where id = p_claim_id and status = 'pending' for update;
  if not found then
    raise exception 'This claim was not found or has already been handled';
  end if;

  select id into fee_id from student_fees where student_id = c.student_id and batch_id = c.batch_id;
  if fee_id is null then
    raise exception 'No fee record for this claim';
  end if;

  result := record_fee_payment(fee_id, c.amount, current_date, 'upi', 'Claim ' || c.transaction_id);
  update payment_claims set status = 'approved' where id = c.id;
  return result;
end $$;

revoke all on function approve_payment_claim(uuid) from public;
grant execute on function approve_payment_claim(uuid) to authenticated;


-- 15. CURRICULUM
-- The batch's table of contents: module > topic > subtopic, no dates. A node is
-- ticked done, or skipped (never taught); the calendar reads done_on. curriculum_nodes
-- is always the approved, live tree. Structure changes reach it only through
-- save_curriculum (admin) or an approved curriculum_requests row (tutor proposal).
do $$ begin create type curriculum_kind           as enum ('module', 'topic', 'subtopic');   exception when duplicate_object then null; end $$;
do $$ begin create type curriculum_status         as enum ('todo', 'done', 'skipped');       exception when duplicate_object then null; end $$;
do $$ begin create type curriculum_request_status as enum ('pending', 'approved', 'denied'); exception when duplicate_object then null; end $$;

create table if not exists curriculum_nodes (
  id         uuid primary key default gen_random_uuid(),
  batch_id   uuid references batches(id) on delete cascade not null,
  parent_id  uuid references curriculum_nodes(id) on delete cascade,
  kind       curriculum_kind not null,
  title      text not null check (length(btrim(title)) > 0),
  -- Order among siblings, set from the draft's order on save.
  position   int not null default 0,
  status     curriculum_status not null default 'todo',
  -- The day it was taught, a plain date so no timezone can shift it. Set only while done.
  done_on    date,
  created_at timestamptz default now(),
  check ((kind = 'module') = (parent_id is null)),
  check (status = 'done' or done_on is null)
);

create index if not exists idx_curriculum_nodes_batch  on curriculum_nodes(batch_id);
create index if not exists idx_curriculum_nodes_parent on curriculum_nodes(parent_id);

-- A tutor's proposed tree: the whole draft as [{id, parent_id, kind, title, position}].
-- One pending request per batch.
create table if not exists curriculum_requests (
  id          uuid primary key default gen_random_uuid(),
  batch_id    uuid references batches(id) on delete cascade not null,
  proposed_by uuid references tutors(id) on delete set null,
  nodes       jsonb not null,
  status      curriculum_request_status not null default 'pending',
  created_at  timestamptz default now(),
  decided_at  timestamptz
);

create unique index if not exists idx_curriculum_requests_pending
  on curriculum_requests(batch_id) where status = 'pending';

alter table curriculum_nodes    enable row level security;
alter table curriculum_requests enable row level security;

drop policy if exists admin_full_access on curriculum_nodes;
create policy admin_full_access on curriculum_nodes
  for all using (is_admin()) with check (is_admin());
drop policy if exists admin_full_access on curriculum_requests;
create policy admin_full_access on curriculum_requests
  for all using (is_admin()) with check (is_admin());

-- Tutors and students only read. Every write goes through the functions below.
drop policy if exists tutor_read_own on curriculum_nodes;
create policy tutor_read_own on curriculum_nodes
  for select using (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())));
drop policy if exists tutor_read_own on curriculum_requests;
create policy tutor_read_own on curriculum_requests
  for select using (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())));

drop policy if exists student_read_own on curriculum_nodes;
create policy student_read_own on curriculum_nodes
  for select using (
    batch_id in (select batch_id from batch_student_mapping where student_id = (select current_student_id()) and status::text <> 'transferred')
  );

-- Makes the live tree equal p_nodes: upserts by id (a kept node keeps its status),
-- deletes the rest. Not granted to anyone; only the functions below call it.
create or replace function apply_curriculum_nodes(p_batch uuid, p_nodes jsonb)
returns void
language plpgsql
set search_path = public
as $$
begin
  if jsonb_typeof(p_nodes) <> 'array' then
    raise exception 'Invalid curriculum';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_nodes) as x(id uuid, parent_id uuid, kind curriculum_kind)
    left join jsonb_to_recordset(p_nodes) as p(id uuid, kind curriculum_kind) on p.id = x.parent_id
    where (x.kind = 'module'   and x.parent_id is not null)
       or (x.kind = 'topic'    and p.kind is distinct from 'module')
       or (x.kind = 'subtopic' and p.kind is distinct from 'topic')
  ) then
    raise exception 'Invalid curriculum structure';
  end if;

  if exists (
    select 1 from curriculum_nodes
    where batch_id <> p_batch and id in (select id from jsonb_to_recordset(p_nodes) as x(id uuid))
  ) then
    raise exception 'Invalid curriculum';
  end if;

  delete from curriculum_nodes
  where batch_id = p_batch
    and id not in (select id from jsonb_to_recordset(p_nodes) as x(id uuid));

  insert into curriculum_nodes (id, batch_id, parent_id, kind, title, position)
  select id, p_batch, parent_id, kind, btrim(title), coalesce(position, 0)
  from jsonb_to_recordset(p_nodes) as x(id uuid, parent_id uuid, kind curriculum_kind, title text, position int)
  on conflict (id) do update
    set parent_id = excluded.parent_id, kind = excluded.kind,
        title = excluded.title, position = excluded.position;
end $$;

revoke all on function apply_curriculum_nodes(uuid, jsonb) from public;

-- Admin's own edits go live at once; a tutor proposal still pending is now stale.
create or replace function save_curriculum(p_batch uuid, p_nodes jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;
  perform apply_curriculum_nodes(p_batch, p_nodes);
  update curriculum_requests set status = 'denied', decided_at = now()
  where batch_id = p_batch and status = 'pending';
end $$;

revoke all on function save_curriculum(uuid, jsonb) from public;
grant execute on function save_curriculum(uuid, jsonb) to authenticated;

create or replace function propose_curriculum(p_batch uuid, p_nodes jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from tutor_batch_mapping where tutor_id = current_tutor_id() and batch_id = p_batch
  ) then
    raise exception 'Not your batch';
  end if;
  if jsonb_typeof(p_nodes) <> 'array' then
    raise exception 'Invalid curriculum';
  end if;
  if exists (select 1 from curriculum_requests where batch_id = p_batch and status = 'pending') then
    raise exception 'A submission is already waiting for approval';
  end if;
  insert into curriculum_requests (batch_id, proposed_by, nodes)
  values (p_batch, current_tutor_id(), p_nodes);
end $$;

revoke all on function propose_curriculum(uuid, jsonb) from public;
grant execute on function propose_curriculum(uuid, jsonb) to authenticated;

create or replace function review_curriculum(p_request uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r curriculum_requests%rowtype;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;
  select * into r from curriculum_requests where id = p_request and status = 'pending' for update;
  if not found then
    raise exception 'This submission was not found or has already been handled';
  end if;
  if p_approve then
    perform apply_curriculum_nodes(r.batch_id, r.nodes);
  end if;
  update curriculum_requests
  set status = case when p_approve then 'approved'::curriculum_request_status else 'denied'::curriculum_request_status end,
      decided_at = now()
  where id = r.id;
end $$;

revoke all on function review_curriculum(uuid, boolean) from public;
grant execute on function review_curriculum(uuid, boolean) to authenticated;

-- Ticking is not an edit: admin and the batch's tutors do it directly. Sending
-- 'done' again with a new date moves the day.
create or replace function set_curriculum_status(p_node uuid, p_status curriculum_status, p_done_on date default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare b uuid;
begin
  select batch_id into b from curriculum_nodes where id = p_node;
  if b is null then
    raise exception 'Not found';
  end if;
  if not (is_admin() or exists (
    select 1 from tutor_batch_mapping where tutor_id = current_tutor_id() and batch_id = b
  )) then
    raise exception 'Not your batch';
  end if;
  update curriculum_nodes
  set status = p_status,
      done_on = case when p_status = 'done' then coalesce(p_done_on, current_date) else null end
  where id = p_node;
end $$;

revoke all on function set_curriculum_status(uuid, curriculum_status, date) from public;
grant execute on function set_curriculum_status(uuid, curriculum_status, date) to authenticated;


-- 16. BADGES
-- A badge is artwork a tutor or admin uploads for one batch. Giving it to a student is a
-- student_badges row; taking it away deletes the row. The artwork is a public file in the
-- assets bucket at badges/<batch_id>/<file>, so the image needs no signed URL.
create table if not exists batch_badges (
  id          uuid primary key default gen_random_uuid(),
  batch_id    uuid references batches(id) on delete cascade not null,
  name        text not null check (length(btrim(name)) > 0),
  description text,
  image_path  text not null,
  created_at  timestamptz default now()
);

create index if not exists idx_batch_badges_batch on batch_badges(batch_id);

create table if not exists student_badges (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid references students(id) on delete cascade not null,
  badge_id   uuid references batch_badges(id) on delete cascade not null,
  -- The tutor who gave it. Null when an admin did.
  issued_by  uuid references tutors(id) on delete set null default current_tutor_id(),
  issued_at  timestamptz not null default now(),
  unique (student_id, badge_id)
);

create index if not exists idx_student_badges_student on student_badges(student_id);
create index if not exists idx_student_badges_badge   on student_badges(badge_id);

-- Each student's ID on each badge: DBT<batch code>-<YY><4-digit ref number>-<5 random>, e.g. DBTPHR-260012-1A3BC.
-- Made when the badge is given and kept for good, so the same ID returns if it is taken back and given again.
-- The artwork in storage never carries it: the app stamps it onto the student's copy when they view, download or share.
create table if not exists badge_codes (
  student_id uuid references students(id) on delete cascade not null,
  badge_id   uuid references batch_badges(id) on delete cascade not null,
  -- The 5 random characters, unique across every badge: at least 2 letters and 2 digits, in any order.
  suffix     text not null unique check (
    suffix ~ '^[A-Z0-9]{5}$'
    and length(regexp_replace(suffix, '[^A-Z]', '', 'g')) >= 2
    and length(regexp_replace(suffix, '[^0-9]', '', 'g')) >= 2
  ),
  -- The whole ID as it was when made, so a later batch code edit or year roll never rewrites it.
  code       text not null unique,
  created_at timestamptz not null default now(),
  primary key (student_id, badge_id)
);

create or replace function new_badge_suffix() returns text
language plpgsql
volatile
set search_path = public
as $$
declare
  chars text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  pick  text;
begin
  loop
    select string_agg(substr(chars, 1 + floor(random() * 36)::int, 1), '') into pick from generate_series(1, 5);
    if length(regexp_replace(pick, '[^A-Z]', '', 'g')) >= 2
       and length(regexp_replace(pick, '[^0-9]', '', 'g')) >= 2
       and not exists (select 1 from badge_codes where suffix = pick) then
      return pick;
    end if;
  end loop;
end $$;

-- Returns the ID, making it first if the student has none for this badge yet.
create or replace function issue_badge_code(p_student uuid, p_badge uuid) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  found_code text;
  ref        text;
  bcode      text;
  head       text;
  pick       text;
begin
  select code into found_code from badge_codes where student_id = p_student and badge_id = p_badge;
  if found then return found_code; end if;

  select s.student_code, upper(btrim(b.batch_code)) into ref, bcode
  from students s, batch_badges bb join batches b on b.id = bb.batch_id
  where s.id = p_student and bb.id = p_badge;

  if coalesce(bcode, '') = '' then
    raise exception 'Set the batch code on the batch first';
  end if;
  if ref is null or ref !~ '^DBT-INT-[0-9]{4}-[0-9]+$' then
    raise exception 'Student ref % is not in the DBT-INT-YYYY-NNN form', ref;
  end if;

  -- Year from the student's own ref, number padded to 4 digits and never cut: 12 -> 0012, 1536 -> 1536.
  head := 'DBT' || bcode || '-' || right(split_part(ref, '-', 3), 2) || lpad(split_part(ref, '-', 4), 4, '0') || '-';

  loop
    pick := new_badge_suffix();
    begin
      insert into badge_codes (student_id, badge_id, suffix, code) values (p_student, p_badge, pick, head || pick);
      return head || pick;
    exception when unique_violation then
      -- Two gives at once, or two students drawing the same suffix: keep ours if it landed, else draw again.
      select code into found_code from badge_codes where student_id = p_student and badge_id = p_badge;
      if found then return found_code; end if;
    end;
  end loop;
end $$;

revoke all on function new_badge_suffix(), issue_badge_code(uuid, uuid) from public;

create or replace function student_badges_issue_code() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform issue_badge_code(new.student_id, new.badge_id);
  return new;
end $$;

drop trigger if exists student_badges_code on student_badges;
create trigger student_badges_code
  after insert on student_badges
  for each row execute function student_badges_issue_code();

alter table badge_codes enable row level security;

drop policy if exists admin_full_access on badge_codes;
create policy admin_full_access on badge_codes
  for all using (is_admin()) with check (is_admin());

-- A student reads only their own IDs; tutors never read them.
drop policy if exists student_read_own on badge_codes;
create policy student_read_own on badge_codes
  for select using (student_id = (select current_student_id()));

alter table batch_badges   enable row level security;
alter table student_badges enable row level security;

drop policy if exists admin_full_access on batch_badges;
create policy admin_full_access on batch_badges
  for all using (is_admin()) with check (is_admin());
drop policy if exists admin_full_access on student_badges;
create policy admin_full_access on student_badges
  for all using (is_admin()) with check (is_admin());

-- Tutors manage the badges of their own batches.
drop policy if exists tutor_manage_own on batch_badges;
create policy tutor_manage_own on batch_badges
  for all
  using (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())))
  with check (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())));

-- Students see every badge of a batch they are in, so unearned ones can show as locked.
drop policy if exists student_read_own on batch_badges;
create policy student_read_own on batch_badges
  for select using (
    batch_id in (select batch_id from batch_student_mapping where student_id = (select current_student_id()) and status::text <> 'transferred')
  );

drop policy if exists student_read_own on student_badges;
create policy student_read_own on student_badges
  for select using (student_id = (select current_student_id()));

-- A tutor sees, gives and takes back the badges of their own batches. Giving is only
-- allowed to a student who is active in the badge's batch.
drop policy if exists tutor_read_own on student_badges;
create policy tutor_read_own on student_badges
  for select using (
    badge_id in (
      select id from batch_badges
      where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id()))
    )
  );

drop policy if exists tutor_give_own on student_badges;
create policy tutor_give_own on student_badges
  for insert with check (
    exists (
      select 1
      from batch_badges bb
      join batch_student_mapping m on m.batch_id = bb.batch_id
      where bb.id = student_badges.badge_id
        and m.student_id = student_badges.student_id
        and m.status = 'active'
        and bb.batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id()))
    )
  );

drop policy if exists tutor_take_own on student_badges;
create policy tutor_take_own on student_badges
  for delete using (
    badge_id in (
      select id from batch_badges
      where batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id()))
    )
  );

-- A tutor uploads badge art for their own batches only, and only as png, jpeg or webp:
-- the assets bucket also accepts svg, which can carry script once it is served publicly.
-- Admin already manages every file in the bucket through "admin manages asset files".
drop policy if exists "tutor manages badge files" on storage.objects;
create policy "tutor manages badge files" on storage.objects
  for all
  using (
    bucket_id = 'assets'
    and split_part(storage.objects.name, '/', 1) = 'badges'
    and safe_uuid(split_part(storage.objects.name, '/', 2)) in (
      select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())
    )
  )
  with check (
    bucket_id = 'assets'
    and split_part(storage.objects.name, '/', 1) = 'badges'
    and safe_uuid(split_part(storage.objects.name, '/', 2)) in (
      select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())
    )
    and lower(storage.extension(storage.objects.name)) in ('png', 'jpg', 'jpeg', 'webp')
  );

-- 17. DOCUMENTS (experimental v1)
-- Each document is generated on an admin's click from /documents (pdf-lib, filled from the student's role
-- and the batch's dates), and stored in the private `documents` bucket at
-- <mapping_id>/<offer_letter|cert>.pdf. A student can only view/download/be emailed a doc once the
-- admin flips its "shared" flag on /documents — enforced both in the storage policy below and again
-- server-side in the send-document edge function.
alter table batch_student_mapping add column if not exists offer_letter_path      text;
alter table batch_student_mapping add column if not exists cert_path              text;
alter table batch_student_mapping add column if not exists offer_letter_shared    boolean not null default false;
alter table batch_student_mapping add column if not exists cert_shared            boolean not null default false;
-- Set only when a share flag flips to true (see setDocumentShared) — drives the portal's
-- "ready" focus card, the same 7-day-recency rule the badge card uses off issued_at.
alter table batch_student_mapping add column if not exists offer_letter_shared_at timestamptz;
alter table batch_student_mapping add column if not exists cert_shared_at         timestamptz;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 5242880, array['application/pdf'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "admin manages document files" on storage.objects;
create policy "admin manages document files" on storage.objects
  for all
  using (bucket_id = 'documents' and is_admin())
  with check (bucket_id = 'documents' and is_admin());

drop policy if exists "student reads own shared documents" on storage.objects;
create policy "student reads own shared documents" on storage.objects
  for select using (
    bucket_id = 'documents'
    and exists (
      select 1 from batch_student_mapping m
      where m.id = safe_uuid(split_part(storage.objects.name, '/', 1))
        and m.student_id = (select current_student_id())
        and (
          (split_part(storage.objects.name, '/', 2) = 'offer_letter.pdf' and m.offer_letter_shared)
          or (split_part(storage.objects.name, '/', 2) = 'cert.pdf' and m.cert_shared)
        )
    )
  );

-- 18. LIVE QUIZ
-- A tutor (or an admin, for everyone) builds an MCQ quiz, opens a lobby, then steps through the questions
-- while students answer on their own screens. Students never read quiz tables: they call quiz_state() and
-- quiz_answer(), so the answer key stays server-side until a question closes. A quiz is one run:
-- draft -> lobby -> live -> ended. "Play again" is a duplicate on the client.
do $$ begin create type quiz_status as enum ('draft', 'lobby', 'live', 'ended');  exception when duplicate_object then null; end $$;
do $$ begin create type quiz_phase  as enum ('answering', 'closed');              exception when duplicate_object then null; end $$;

create table if not exists quizzes (
  id                 uuid primary key default gen_random_uuid(),
  title              text not null check (length(btrim(title)) > 0),
  -- Null means everyone; only an admin can create one of those.
  batch_id           uuid references batches(id) on delete cascade,
  created_by         uuid references tutors(id) on delete set null default current_tutor_id(),
  status             quiz_status not null default 'draft',
  seconds_per_question int not null default 20 check (seconds_per_question between 5 and 300),
  show_answer        boolean not null default true,
  live_leaderboard   boolean not null default false,
  student_review     boolean not null default true,
  -- Which question the students are looking at, the furthest one ever opened, and whether it takes answers.
  current_position   int not null default -1,
  furthest           int not null default -1,
  phase              quiz_phase not null default 'closed',
  started_at         timestamptz,
  ended_at           timestamptz,
  created_at         timestamptz not null default now()
);

create table if not exists quiz_questions (
  id         uuid primary key default gen_random_uuid(),
  quiz_id    uuid references quizzes(id) on delete cascade not null,
  position   int not null,
  body       text not null default '',
  image_path text,
  -- Null uses the quiz's default.
  seconds    int check (seconds between 5 and 300),
  opened_at  timestamptz,
  closes_at  timestamptz,
  unique (quiz_id, position)
);

create table if not exists quiz_options (
  id          uuid primary key default gen_random_uuid(),
  question_id uuid references quiz_questions(id) on delete cascade not null,
  position    int not null,
  label       text not null default '',
  is_correct  boolean not null default false,
  unique (question_id, position)
);

create table if not exists quiz_participants (
  quiz_id    uuid references quizzes(id) on delete cascade not null,
  student_id uuid references students(id) on delete cascade not null,
  joined_at  timestamptz not null default now(),
  primary key (quiz_id, student_id)
);

-- One row per student per question. Each change rewrites it: the last change is the answer, and its
-- time since the question opened is the speed, so dithering between options costs points.
create table if not exists quiz_answers (
  id          uuid primary key default gen_random_uuid(),
  quiz_id     uuid references quizzes(id) on delete cascade not null,
  question_id uuid references quiz_questions(id) on delete cascade not null,
  student_id  uuid references students(id) on delete cascade not null,
  option_ids  uuid[] not null,
  is_correct  boolean not null,
  points      int not null default 0,
  elapsed_ms  int not null,
  answered_at timestamptz not null default now(),
  unique (question_id, student_id)
);

create index if not exists idx_quizzes_batch       on quizzes(batch_id);
create index if not exists idx_quiz_questions_quiz on quiz_questions(quiz_id);
create index if not exists idx_quiz_options_q      on quiz_options(question_id);
create index if not exists idx_quiz_answers_quiz   on quiz_answers(quiz_id);
create index if not exists idx_quiz_answers_student on quiz_answers(student_id);

alter table quizzes           enable row level security;
alter table quiz_questions    enable row level security;
alter table quiz_options      enable row level security;
alter table quiz_participants enable row level security;
alter table quiz_answers      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['quizzes', 'quiz_questions', 'quiz_options', 'quiz_participants', 'quiz_answers'] loop
    execute format('drop policy if exists admin_full_access on %I', t);
    execute format('create policy admin_full_access on %I for all using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;

-- A tutor reads (and deletes) their batches' quizzes; every write goes through the functions below.
drop policy if exists tutor_read_own on quizzes;
create policy tutor_read_own on quizzes
  for select using (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())));

drop policy if exists tutor_delete_own on quizzes;
create policy tutor_delete_own on quizzes
  for delete using (batch_id in (select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())));

drop policy if exists tutor_read_own on quiz_questions;
create policy tutor_read_own on quiz_questions
  for select using ((select is_tutor()) and quiz_id in (select id from quizzes));

drop policy if exists tutor_read_own on quiz_options;
create policy tutor_read_own on quiz_options
  for select using ((select is_tutor()) and question_id in (select id from quiz_questions));

drop policy if exists tutor_read_own on quiz_participants;
create policy tutor_read_own on quiz_participants
  for select using ((select is_tutor()) and quiz_id in (select id from quizzes));

drop policy if exists tutor_read_own on quiz_answers;
create policy tutor_read_own on quiz_answers
  for select using ((select is_tutor()) and quiz_id in (select id from quizzes));

-- A student sees the row (title, status, position: no secrets) of a quiz they may join, which is also
-- what lets Realtime push its changes to them. Everything else about a quiz comes through quiz_state().
drop policy if exists student_read_open on quizzes;
create policy student_read_open on quizzes
  for select using (
    status <> 'draft'
    and (select current_student_id()) is not null
    and (
      batch_id is null
      or batch_id in (
        select batch_id from batch_student_mapping
        where student_id = (select current_student_id()) and status = 'active'
      )
    )
  );

-- Quiz images live at quizzes/<batch_id or 'all'>/<file> in the public assets bucket.
drop policy if exists "tutor manages quiz files" on storage.objects;
create policy "tutor manages quiz files" on storage.objects
  for all
  using (
    bucket_id = 'assets'
    and split_part(storage.objects.name, '/', 1) = 'quizzes'
    and safe_uuid(split_part(storage.objects.name, '/', 2)) in (
      select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())
    )
  )
  with check (
    bucket_id = 'assets'
    and split_part(storage.objects.name, '/', 1) = 'quizzes'
    and safe_uuid(split_part(storage.objects.name, '/', 2)) in (
      select batch_id from tutor_batch_mapping where tutor_id = (select current_tutor_id())
    )
    and lower(storage.extension(storage.objects.name)) in ('png', 'jpg', 'jpeg', 'webp')
  );

-- Live updates: the host watches answers and joins, everyone watches the quiz row.
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['quizzes', 'quiz_participants', 'quiz_answers'] loop
      begin
        execute format('alter publication supabase_realtime add table %I', t);
      exception when duplicate_object then null;
      end;
    end loop;
  end if;
end $$;

-- Helpers. Not granted to anyone: only the functions below call them.
create or replace function quiz_host_ok(p_quiz uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select is_admin() or exists (
    select 1
    from quizzes z
    join tutor_batch_mapping m on m.batch_id = z.batch_id
    where z.id = p_quiz and m.tutor_id = current_tutor_id()
  );
$$;

create or replace function quiz_student_ok(p_quiz uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select current_student_id() is not null and exists (
    select 1 from quizzes z
    where z.id = p_quiz
      and z.status <> 'draft'
      and (
        z.batch_id is null
        or exists (
          select 1 from batch_student_mapping m
          where m.batch_id = z.batch_id and m.student_id = current_student_id() and m.status = 'active'
        )
      )
  );
$$;

-- Points, then total time of the correct answers, decide the rank. Ties share a rank.
create or replace function quiz_scores(p_quiz uuid)
returns table (student_id uuid, name text, code text, points bigint, correct bigint, answered bigint, time_ms bigint, rank bigint)
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select p.student_id, s.name, s.student_code as code,
      coalesce(sum(a.points), 0)::bigint as points,
      (count(*) filter (where a.is_correct))::bigint as correct,
      count(a.id)::bigint as answered,
      coalesce(sum(a.elapsed_ms) filter (where a.is_correct), 0)::bigint as time_ms
    from quiz_participants p
    join students s on s.id = p.student_id
    left join quiz_answers a on a.quiz_id = p.quiz_id and a.student_id = p.student_id
    where p.quiz_id = p_quiz
    group by p.student_id, s.name, s.student_code
  )
  select t.student_id, t.name, t.code, t.points, t.correct, t.answered, t.time_ms,
         rank() over (order by t.points desc, t.time_ms asc)
  from t;
$$;

-- The rules a quiz has to meet before students can see it: shared by opening the lobby and by editing while it is open.
create or replace function quiz_validate(p_quiz uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  q record;
begin
  if not exists (select 1 from quiz_questions where quiz_id = p_quiz) then raise exception 'Add at least one question'; end if;

  for q in select id, position, body from quiz_questions where quiz_id = p_quiz order by position loop
    if length(btrim(q.body)) = 0 then raise exception 'Question % has no text', q.position + 1; end if;
    if (select count(*) from quiz_options where question_id = q.id and length(btrim(label)) > 0) < 2 then
      raise exception 'Question % needs at least two options', q.position + 1;
    end if;
    if exists (select 1 from quiz_options where question_id = q.id and length(btrim(label)) = 0) then
      raise exception 'Question % has an empty option', q.position + 1;
    end if;
    if not exists (select 1 from quiz_options where question_id = q.id and is_correct) then
      raise exception 'Question % needs a correct answer', q.position + 1;
    end if;
  end loop;
end;
$$;

-- Builder: the whole quiz in one call, replacing its questions. A draft can change, and so can a quiz whose lobby is open
-- but has not started.
-- p_quiz = {id, title, batch_id, seconds_per_question, show_answer, live_leaderboard, student_review,
--           questions: [{body, image_path, seconds, options: [{label, correct}]}]}
create or replace function quiz_save(p_quiz jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id    uuid := (p_quiz ->> 'id')::uuid;
  v_batch uuid := nullif(p_quiz ->> 'batch_id', '')::uuid;
  v_q     jsonb;
  v_o     jsonb;
  v_qid   uuid;
  v_qpos  int := 0;
  v_opos  int;
  v_status quiz_status;
  v_was   uuid;
begin
  if v_id is null then raise exception 'The quiz has no id'; end if;

  if v_batch is null then
    if not is_admin() then raise exception 'Only an admin can run a quiz for everyone'; end if;
  elsif not (is_admin() or exists (
    select 1 from tutor_batch_mapping where batch_id = v_batch and tutor_id = current_tutor_id()
  )) then
    raise exception 'You are not assigned to that batch';
  end if;

  select status, batch_id into v_status, v_was from quizzes where id = v_id;
  if found then
    if not quiz_host_ok(v_id) then raise exception 'Not allowed'; end if;
    -- A draft, or a quiz whose lobby is open but whose first question has not been shown yet.
    if v_status not in ('draft', 'lobby') then
      raise exception 'A quiz that has started can no longer be edited';
    end if;
    if v_status = 'lobby' and v_was is distinct from v_batch then
      raise exception 'Who can join cannot change once the lobby is open';
    end if;
    update quizzes set
      title = btrim(p_quiz ->> 'title'),
      batch_id = v_batch,
      seconds_per_question = (p_quiz ->> 'seconds_per_question')::int,
      show_answer = (p_quiz ->> 'show_answer')::boolean,
      live_leaderboard = (p_quiz ->> 'live_leaderboard')::boolean,
      student_review = (p_quiz ->> 'student_review')::boolean
    where id = v_id;
  else
    insert into quizzes (id, title, batch_id, seconds_per_question, show_answer, live_leaderboard, student_review)
    values (
      v_id, btrim(p_quiz ->> 'title'), v_batch,
      (p_quiz ->> 'seconds_per_question')::int,
      (p_quiz ->> 'show_answer')::boolean,
      (p_quiz ->> 'live_leaderboard')::boolean,
      (p_quiz ->> 'student_review')::boolean
    );
  end if;

  delete from quiz_questions where quiz_id = v_id;

  for v_q in select * from jsonb_array_elements(coalesce(p_quiz -> 'questions', '[]'::jsonb)) loop
    insert into quiz_questions (quiz_id, position, body, image_path, seconds)
    values (
      v_id, v_qpos, btrim(coalesce(v_q ->> 'body', '')),
      nullif(v_q ->> 'image_path', ''), nullif(v_q ->> 'seconds', '')::int
    )
    returning id into v_qid;

    v_opos := 0;
    for v_o in select * from jsonb_array_elements(coalesce(v_q -> 'options', '[]'::jsonb)) loop
      insert into quiz_options (question_id, position, label, is_correct)
      values (v_qid, v_opos, btrim(coalesce(v_o ->> 'label', '')), coalesce((v_o ->> 'correct')::boolean, false));
      v_opos := v_opos + 1;
    end loop;

    v_qpos := v_qpos + 1;
  end loop;

  -- Students are already waiting: the edited quiz must still be runnable, or the whole edit is undone.
  if v_status = 'lobby' then perform quiz_validate(v_id); end if;

  return v_id;
end;
$$;

-- Draft -> lobby, once every question is answerable.
create or replace function quiz_open_lobby(p_quiz uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not quiz_host_ok(p_quiz) then raise exception 'Not allowed'; end if;
  if (select status from quizzes where id = p_quiz) <> 'draft' then raise exception 'This quiz is already open'; end if;
  perform quiz_validate(p_quiz);
  update quizzes set status = 'lobby' where id = p_quiz;
end;
$$;

-- Host navigation. The next unopened question starts its timer; anything earlier replays, closed.
create or replace function quiz_go(p_quiz uuid, p_position int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  z quizzes;
  n int;
begin
  if not quiz_host_ok(p_quiz) then raise exception 'Not allowed'; end if;
  select * into z from quizzes where id = p_quiz for update;
  if z.status not in ('lobby', 'live') then raise exception 'The quiz is not running'; end if;

  select count(*) into n from quiz_questions where quiz_id = p_quiz;
  if p_position < 0 or p_position >= n then raise exception 'No such question'; end if;
  if p_position = z.current_position then return; end if;

  if z.phase = 'answering' then
    update quiz_questions set closes_at = least(closes_at, now())
    where quiz_id = p_quiz and position = z.current_position;
  end if;

  if p_position <= z.furthest then
    update quizzes set current_position = p_position, phase = 'closed' where id = p_quiz;
  elsif p_position = z.furthest + 1 then
    update quiz_questions
    set opened_at = now(), closes_at = now() + make_interval(secs => coalesce(seconds, z.seconds_per_question))
    where quiz_id = p_quiz and position = p_position;
    update quizzes
    set status = 'live', current_position = p_position, furthest = p_position, phase = 'answering',
        started_at = coalesce(started_at, now())
    where id = p_quiz;
  else
    raise exception 'Questions run in order';
  end if;
end;
$$;

create or replace function quiz_close(p_quiz uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  z quizzes;
begin
  if not quiz_host_ok(p_quiz) then raise exception 'Not allowed'; end if;
  select * into z from quizzes where id = p_quiz for update;
  if z.status <> 'live' or z.phase <> 'answering' then return; end if;
  update quiz_questions set closes_at = least(closes_at, now()) where quiz_id = p_quiz and position = z.current_position;
  update quizzes set phase = 'closed' where id = p_quiz;
end;
$$;

create or replace function quiz_extend(p_quiz uuid, p_seconds int)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  z quizzes;
begin
  if not quiz_host_ok(p_quiz) then raise exception 'Not allowed'; end if;
  select * into z from quizzes where id = p_quiz for update;
  if z.status <> 'live' or z.phase <> 'answering' then raise exception 'No question is open'; end if;
  update quiz_questions
  set closes_at = closes_at + make_interval(secs => greatest(least(p_seconds, 60), 1))
  where quiz_id = p_quiz and position = z.current_position and closes_at > now();
end;
$$;

create or replace function quiz_end(p_quiz uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  z quizzes;
begin
  if not quiz_host_ok(p_quiz) then raise exception 'Not allowed'; end if;
  select * into z from quizzes where id = p_quiz for update;
  if z.status not in ('lobby', 'live') then return; end if;
  if z.phase = 'answering' then
    update quiz_questions set closes_at = least(closes_at, now()) where quiz_id = p_quiz and position = z.current_position;
  end if;
  update quizzes set status = 'ended', phase = 'closed', ended_at = now() where id = p_quiz;
end;
$$;

create or replace function quiz_join(p_quiz uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not quiz_student_ok(p_quiz) then raise exception 'This quiz is not available to you'; end if;
  if (select status from quizzes where id = p_quiz) not in ('lobby', 'live') then raise exception 'This quiz is over'; end if;
  insert into quiz_participants (quiz_id, student_id) values (p_quiz, current_student_id()) on conflict do nothing;
end;
$$;

-- Kahoot-style: a right answer earns 1000 down to 500 as the time it was last changed nears the limit.
create or replace function quiz_answer(p_question uuid, p_options uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me      uuid := current_student_id();
  q       quiz_questions;
  z       quizzes;
  picked  uuid[];
  want    uuid[];
  is_right boolean;
  spent   numeric;
  span    numeric;
  earned  int;
begin
  if me is null then raise exception 'Only students answer'; end if;
  select * into q from quiz_questions where id = p_question;
  if q.id is null or not quiz_student_ok(q.quiz_id) then raise exception 'This quiz is not available to you'; end if;

  select * into z from quizzes where id = q.quiz_id;
  if z.status <> 'live' or z.current_position <> q.position or z.phase <> 'answering' or now() >= q.closes_at then
    raise exception 'Time is up for this question';
  end if;

  select coalesce(array_agg(distinct x), '{}') into picked from unnest(p_options) x;
  if cardinality(picked) = 0 then raise exception 'Pick an answer'; end if;
  if exists (select 1 from unnest(picked) x where x not in (select id from quiz_options where question_id = q.id)) then
    raise exception 'That is not one of the options';
  end if;

  select coalesce(array_agg(id), '{}') into want from quiz_options where question_id = q.id and is_correct;
  is_right := picked <@ want and want <@ picked;

  spent := extract(epoch from now() - q.opened_at);
  span := greatest(extract(epoch from q.closes_at - q.opened_at), 1);
  earned := case when is_right then round(1000 * (1 - least(spent / span, 1) / 2))::int else 0 end;

  insert into quiz_participants (quiz_id, student_id) values (q.quiz_id, me) on conflict do nothing;

  insert into quiz_answers (quiz_id, question_id, student_id, option_ids, is_correct, points, elapsed_ms, answered_at)
  values (q.quiz_id, q.id, me, picked, is_right, earned, round(spent * 1000)::int, now())
  on conflict (question_id, student_id) do update
    set option_ids = excluded.option_ids, is_correct = excluded.is_correct, points = excluded.points,
        elapsed_ms = excluded.elapsed_ms, answered_at = excluded.answered_at;
end;
$$;

-- Everything a student's screen needs, and nothing it must not know yet.
create or replace function quiz_state(p_quiz uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me      uuid := current_student_id();
  z       quizzes;
  q       quiz_questions;
  a       quiz_answers;
  shut    boolean;
  total   int;
  seen    int;
  result  jsonb;
  extra   jsonb;
  top     jsonb;
  mine    record;
begin
  if not quiz_student_ok(p_quiz) then raise exception 'This quiz is not available to you'; end if;
  select * into z from quizzes where id = p_quiz;
  select count(*) into total from quiz_questions where quiz_id = p_quiz;
  select count(*) into seen from quiz_participants where quiz_id = p_quiz;

  result := jsonb_build_object(
    'server_now', now(), 'title', z.title, 'status', z.status, 'position', z.current_position,
    'total', total, 'participants', seen,
    'joined', exists (select 1 from quiz_participants where quiz_id = p_quiz and student_id = me),
    'show_answer', z.show_answer, 'live_leaderboard', z.live_leaderboard
  );

  if z.status <> 'live' or z.current_position < 0 then return result; end if;

  select * into q from quiz_questions where quiz_id = p_quiz and position = z.current_position;
  shut := z.phase = 'closed' or now() >= q.closes_at;
  select * into a from quiz_answers where question_id = q.id and student_id = me;

  result := result || jsonb_build_object(
    'closed', shut,
    'mine', case when a.id is null then null else to_jsonb(a.option_ids) end,
    'question', jsonb_build_object(
      'id', q.id, 'body', q.body, 'image_path', q.image_path,
      'multi', (select count(*) from quiz_options where question_id = q.id and is_correct) > 1,
      'opened_at', q.opened_at, 'closes_at', q.closes_at,
      'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label) order by o.position)
                  from quiz_options o where o.question_id = q.id)
    )
  );

  if not shut then return result; end if;

  extra := jsonb_build_object(
    'answered', (select count(*) from quiz_answers where question_id = q.id),
    'counts', (select coalesce(jsonb_object_agg(o.id, coalesce(c.n, 0)), '{}'::jsonb)
               from quiz_options o
               left join (select unnest(option_ids) as oid, count(*) as n from quiz_answers where question_id = q.id group by 1) c
                 on c.oid = o.id
               where o.question_id = q.id)
  );
  if z.show_answer then
    extra := extra || jsonb_build_object(
      'correct_ids', (select coalesce(jsonb_agg(id), '[]'::jsonb) from quiz_options where question_id = q.id and is_correct),
      'is_correct', a.is_correct,
      'points', coalesce(a.points, 0)
    );
  end if;
  result := result || jsonb_build_object('reveal', extra);

  if z.live_leaderboard then
    select s.rank, s.points into mine from quiz_scores(p_quiz) s where s.student_id = me;
    select coalesce(jsonb_agg(jsonb_build_object('rank', r.rank, 'name', r.name, 'points', r.points, 'me', r.student_id = me) order by r.rank, r.name), '[]'::jsonb)
      into top
      from (select * from quiz_scores(p_quiz) s order by s.rank, s.name limit 5) r;
    result := result || jsonb_build_object('standing', jsonb_build_object(
      'rank', mine.rank, 'points', mine.points, 'top', top
    ));
  end if;

  return result;
end;
$$;

-- Full ranking. A host any time; a student only once the quiz has ended.
create or replace function quiz_scoreboard(p_quiz uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := current_student_id();
begin
  if not quiz_host_ok(p_quiz) then
    if not quiz_student_ok(p_quiz) or (select status from quizzes where id = p_quiz) <> 'ended' then
      raise exception 'Not allowed';
    end if;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'student_id', s.student_id, 'rank', s.rank, 'name', s.name, 'code', s.code, 'points', s.points,
      'correct', s.correct, 'answered', s.answered, 'time_ms', s.time_ms, 'me', s.student_id = me
    ) order by s.rank, s.name)
    from quiz_scores(p_quiz) s
  ), '[]'::jsonb);
end;
$$;

-- A student's finished quiz: their standing against the class, and a review if the host allows one.
create or replace function quiz_my_result(p_quiz uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me     uuid := current_student_id();
  z      quizzes;
  mine   record;
  review jsonb;
begin
  if not quiz_student_ok(p_quiz) then raise exception 'This quiz is not available to you'; end if;
  select * into z from quizzes where id = p_quiz;
  if z.status <> 'ended' then raise exception 'This quiz has not finished'; end if;

  select * into mine from quiz_scores(p_quiz) s where s.student_id = me;
  if mine.student_id is null then raise exception 'You did not take part in this quiz'; end if;

  if z.student_review then
    select coalesce(jsonb_agg(jsonb_build_object(
      'position', q.position, 'body', q.body, 'image_path', q.image_path,
      'answered', (select count(*) from quiz_answers x where x.question_id = q.id),
      'mine', a.option_ids, 'is_correct', a.is_correct, 'points', coalesce(a.points, 0), 'elapsed_ms', a.elapsed_ms,
      'options', (
        select jsonb_agg(jsonb_build_object(
          'id', o.id, 'label', o.label, 'correct', o.is_correct,
          'count', (select count(*) from quiz_answers x where x.question_id = q.id and o.id = any (x.option_ids))
        ) order by o.position)
        from quiz_options o where o.question_id = q.id
      )
    ) order by q.position), '[]'::jsonb)
    into review
    from quiz_questions q
    left join quiz_answers a on a.question_id = q.id and a.student_id = me
    where q.quiz_id = p_quiz and q.opened_at is not null;
  end if;

  return jsonb_build_object(
    'title', z.title, 'ended_at', z.ended_at,
    'rank', mine.rank, 'points', mine.points, 'correct', mine.correct, 'answered', mine.answered, 'time_ms', mine.time_ms,
    'questions', (select count(*) from quiz_questions where quiz_id = p_quiz and opened_at is not null),
    'participants', (select count(*) from quiz_participants where quiz_id = p_quiz),
    'avg_points', (select coalesce(round(avg(s.points)), 0) from quiz_scores(p_quiz) s),
    'avg_correct', (select coalesce(round(avg(s.correct), 1), 0) from quiz_scores(p_quiz) s),
    'review', review
  );
end;
$$;

create or replace function quiz_my_history()
returns table (quiz_id uuid, batch_id uuid, title text, ended_at timestamptz, rank bigint, participants bigint, points bigint, correct bigint, questions bigint)
language sql
stable
security definer
set search_path = public
as $$
  select z.id, z.batch_id, z.title, z.ended_at, s.rank,
         (select count(*) from quiz_participants x where x.quiz_id = z.id),
         s.points, s.correct,
         (select count(*) from quiz_questions q where q.quiz_id = z.id and q.opened_at is not null)
  from quizzes z
  join quiz_participants p on p.quiz_id = z.id and p.student_id = current_student_id()
  cross join lateral quiz_scores(z.id) s
  where z.status = 'ended' and s.student_id = p.student_id
  order by z.ended_at desc;
$$;

-- The database's clock, so a host's countdown does not drift with their laptop's.
create or replace function quiz_clock()
returns timestamptz
language sql
stable
as $$ select now(); $$;

revoke all on function quiz_host_ok(uuid), quiz_student_ok(uuid), quiz_scores(uuid), quiz_validate(uuid) from public;
revoke all on function quiz_save(jsonb), quiz_open_lobby(uuid), quiz_go(uuid, int), quiz_close(uuid), quiz_extend(uuid, int),
  quiz_end(uuid), quiz_join(uuid), quiz_answer(uuid, uuid[]), quiz_state(uuid), quiz_scoreboard(uuid),
  quiz_my_result(uuid), quiz_my_history(), quiz_clock() from public;
grant execute on function quiz_save(jsonb), quiz_open_lobby(uuid), quiz_go(uuid, int), quiz_close(uuid), quiz_extend(uuid, int),
  quiz_end(uuid), quiz_join(uuid), quiz_answer(uuid, uuid[]), quiz_state(uuid), quiz_scoreboard(uuid),
  quiz_my_result(uuid), quiz_my_history(), quiz_clock() to authenticated;

-- 19. INTERNSHIP ROLE AND DATES
-- Stamped on the offer letter ("the position of ...", the joining date) and on the certificate (the role, the
-- internship's start and end date). One set per student, edited on the student form.
-- Role: the enum value is the title stamped on the documents. It is set on the batch (New Batch / Edit Batch); a new
-- one is added through add_internship_role(). Generating a document stamps the batch's role and copies it onto the student.
-- Start date: the batch's start date, set when the student is enrolled. End date: the batch's end date, filled by
-- end_batch() when the batch is ended. Both only where still empty, so a date typed by hand is kept, and both stay editable.
do $$ begin
  create type internship_role as enum ('Devops Engineering Intern', 'AI/ML Engineering Intern', 'Cloud Engineering Intern');
exception when duplicate_object then null; end $$;

alter table students add column if not exists internship_role       internship_role;
alter table batches  add column if not exists internship_role       internship_role;
alter table students add column if not exists internship_start_date date;
alter table students add column if not exists internship_end_date   date;
-- No default: an earlier version of this migration set one (today). Dropping it is harmless if it never ran.
alter table students alter column internship_start_date drop default;

do $$ begin
  alter table students add constraint students_internship_dates_ordered
    check (internship_end_date is null or internship_start_date is null or internship_end_date >= internship_start_date);
exception when duplicate_object then null; end $$;

create or replace function internship_roles()
returns text[]
language sql
stable
set search_path = public
as $$ select enum_range(null::internship_role)::text[]; $$;

revoke all on function internship_roles() from public;
grant execute on function internship_roles() to authenticated;

-- Enum values cannot be removed, so the name is trimmed and capped before it becomes one.
create or replace function add_internship_role(p_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare clean text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;
  if clean = '' or length(clean) > 60 then
    raise exception 'Role must be 1 to 60 characters';
  end if;

  execute format('alter type internship_role add value if not exists %L', clean);
  return clean;
end $$;

revoke all on function add_internship_role(text) from public;
grant execute on function add_internship_role(text) to authenticated;

-- 20. EDIT A STUDENT'S FEE
-- The decided fee is the number; the discount is kept as base minus fee, in rupees. Instalments are worked out from
-- total_fee wherever they are read, so nothing else needs rewriting. Active enrolments only: a terminated row's owed
-- amount is frozen in expected_on_exit.
create or replace function set_student_fee(p_student_id uuid, p_batch_id uuid, p_fee numeric)
returns student_fees
language plpgsql
security definer
set search_path = public
as $$
declare
  base    numeric;
  fee_row student_fees%rowtype;
  updated student_fees%rowtype;
begin
  if not is_admin() then
    raise exception 'Admin only';
  end if;
  if p_fee is null or p_fee < 0 then
    raise exception 'Fee must be 0 or more';
  end if;

  if not exists (
    select 1 from batch_student_mapping
    where student_id = p_student_id and batch_id = p_batch_id and status = 'active'
  ) then
    raise exception 'Only an active enrolment can change fee';
  end if;

  select base_fee into base from batches where id = p_batch_id;
  select * into fee_row from student_fees
  where student_id = p_student_id and batch_id = p_batch_id
  for update;
  if not found then
    raise exception 'Fee record not found';
  end if;

  if base is not null and p_fee > base then
    raise exception 'Fee is above the base fee of %', base;
  end if;
  if p_fee < fee_row.paid_amount then
    raise exception 'Fee is below the % already paid', fee_row.paid_amount;
  end if;

  update student_fees
  set total_fee = p_fee,
      discount_type = 'amount',
      discount_value = greatest(coalesce(base, p_fee) - p_fee, 0),
      updated_at = now()
  where id = fee_row.id
  returning * into updated;

  return updated;
end $$;

revoke all on function set_student_fee(uuid, uuid, numeric) from public;
grant execute on function set_student_fee(uuid, uuid, numeric) to authenticated;


-- 21. TUTOR LOG
-- Everything a tutor does, for the admin Tutor Log. Written by triggers, so no screen can skip it.
do $$ begin create type tutor_action_op as enum ('created', 'updated', 'deleted'); exception when duplicate_object then null; end $$;

create table if not exists tutor_actions (
  id         uuid primary key default gen_random_uuid(),
  tutor_id   uuid references tutors(id) on delete set null,
  tutor_name text not null,
  op         tutor_action_op not null,
  item       text not null,
  detail     text,
  batch_id   uuid,
  times      int not null default 1,
  created_at timestamptz not null default now()
);

create index if not exists idx_tutor_actions_created on tutor_actions(created_at desc);

alter table tutor_actions enable row level security;
drop policy if exists admin_full_access on tutor_actions;
create policy admin_full_access on tutor_actions
  for all using (is_admin()) with check (is_admin());

create or replace function log_tutor_action()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  tutor     tutors%rowtype;
  doc       jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  action_op tutor_action_op := case tg_op when 'INSERT' then 'created' when 'UPDATE' then 'updated' else 'deleted' end;
  label     text := case tg_table_name
    when 'lectures' then 'Lecture'
    when 'attendance' then 'Attendance'
    when 'uploads' then 'Attendance upload'
    when 'assignments' then 'Assignment'
    when 'assignment_completions' then 'Assignment mark'
    when 'materials' then 'Study material'
    when 'batch_badges' then 'Badge'
    when 'student_badges' then 'Badge given'
    when 'quizzes' then 'Quiz'
    when 'curriculum_nodes' then 'Curriculum'
    else 'Curriculum submission'
  end;
  about     text := coalesce(doc->>'title', doc->>'name');
  batch     uuid;
begin
  if not is_tutor() then
    return null;
  end if;

  select * into tutor from tutors where auth_user_id = auth.uid();
  if not found then
    return null;
  end if;

  batch := coalesce(
    nullif(doc->>'batch_id', '')::uuid,
    (select a.batch_id from assignments a where a.id = nullif(doc->>'assignment_id', '')::uuid),
    (select bb.batch_id from batch_badges bb where bb.id = nullif(doc->>'badge_id', '')::uuid)
  );

  -- A burst of the same action (marking a whole class) folds into one row
  update tutor_actions
  set times = times + 1
  where tutor_id = tutor.id and op = action_op and item = label
    and batch_id is not distinct from batch
    and detail is not distinct from about
    and created_at > now() - interval '1 minute';

  if not found then
    insert into tutor_actions (tutor_id, tutor_name, op, item, detail, batch_id)
    values (tutor.id, tutor.name, action_op, label, about, batch);
  end if;

  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'lectures', 'attendance', 'uploads', 'assignments', 'assignment_completions', 'materials',
    'batch_badges', 'student_badges', 'quizzes', 'curriculum_nodes', 'curriculum_requests'
  ] loop
    execute format('drop trigger if exists log_tutor_action on %I', t);
    execute format('create trigger log_tutor_action after insert or update or delete on %I for each row execute function log_tutor_action()', t);
  end loop;
end $$;

-- A finished batch can be read by its tutors but not changed
create or replace function guard_tutor_ended_batch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  doc   jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  batch uuid;
begin
  if is_tutor() then
    batch := coalesce(
      nullif(doc->>'batch_id', '')::uuid,
      (select a.batch_id from assignments a where a.id = nullif(doc->>'assignment_id', '')::uuid),
      (select bb.batch_id from batch_badges bb where bb.id = nullif(doc->>'badge_id', '')::uuid)
    );
    if exists (select 1 from batches where id = batch and ended_at is not null) then
      raise exception 'This batch has ended';
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'lectures', 'attendance', 'uploads', 'assignments', 'assignment_completions', 'materials',
    'batch_badges', 'student_badges', 'quizzes', 'curriculum_nodes', 'curriculum_requests'
  ] loop
    execute format('drop trigger if exists guard_tutor_ended_batch on %I', t);
    execute format('create trigger guard_tutor_ended_batch before insert or update or delete on %I for each row execute function guard_tutor_ended_batch()', t);
  end loop;
end $$;


-- 22. NOTIFICATIONS
-- One row per event per person, written by triggers so no screen can skip it. Counts that are live data
-- (claims to verify, work to grade, accounts expiring) are not stored here: the app computes those.
do $$ begin create type notification_kind as enum (
  'assignment_new', 'assignment_graded', 'material_new', 'quiz_new', 'quiz_result',
  'document_shared', 'payment_verified', 'feedback_resolved',
  'feedback_new', 'student_transferred', 'batch_ended',
  'curriculum_decided', 'student_joined', 'quiz_finished'
); exception when duplicate_object then null; end $$;

create table if not exists notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       notification_kind not null,
  batch_id   uuid references batches(id) on delete cascade,
  -- What it is about: the assignment, the student, the batch
  title      text not null,
  link       text not null,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_notifications_user on notifications(user_id, created_at desc);

alter table notifications enable row level security;
drop policy if exists read_own on notifications;
create policy read_own on notifications for select using (user_id = auth.uid());
drop policy if exists mark_own on notifications;
create policy mark_own on notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Read state is the only thing a person changes; rows are written by the triggers below
revoke all on notifications from anon, authenticated;
grant select on notifications to authenticated;
grant update (read_at) on notifications to authenticated;

-- Live: a new row shows in the bell and cards at once
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table notifications;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

-- Helpers, called only by the triggers: test batches never notify, finished ones only when told to
create or replace function notification_quiet(p_batch uuid, p_allow_ended boolean default false)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_batch is not null and exists (
    select 1 from batches b
    where b.id = p_batch and (b.is_test or (b.ended_at is not null and not p_allow_ended))
  );
$$;

-- The same event for the same person inside ten minutes is one row, so a folder upload is not fifty
create or replace function notify_users(p_users uuid[], p_kind notification_kind, p_batch uuid, p_title text, p_link text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into notifications (user_id, kind, batch_id, title, link)
  select distinct t.u, p_kind, p_batch, p_title, p_link
  from unnest(p_users) as t(u)
  where t.u is not null
    and not exists (
      select 1 from notifications n
      where n.user_id = t.u and n.kind = p_kind and n.batch_id is not distinct from p_batch
        and n.title = p_title and n.created_at > now() - interval '10 minutes'
    );
$$;

create or replace function batch_student_users(p_batch uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(s.auth_user_id), '{}')
  from batch_student_mapping m
  join students s on s.id = m.student_id
  where m.batch_id = p_batch and m.status = 'active' and s.auth_user_id is not null;
$$;

create or replace function batch_tutor_users(p_batch uuid)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(t.auth_user_id), '{}')
  from tutor_batch_mapping m
  join tutors t on t.id = m.tutor_id
  where m.batch_id = p_batch and t.auth_user_id is not null;
$$;

create or replace function admin_users()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(u.id), '{}') from auth.users u where u.raw_app_meta_data ->> 'role' = 'admin';
$$;

-- A for-everyone item reaches every student with a login in a batch that is running and real
create or replace function everyone_student_users()
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct s.auth_user_id), '{}')
  from students s
  join batch_student_mapping m on m.student_id = s.id and m.status = 'active'
  join batches b on b.id = m.batch_id and not b.is_test and b.ended_at is null
  where s.auth_user_id is not null;
$$;

revoke all on function notification_quiet(uuid, boolean), notify_users(uuid[], notification_kind, uuid, text, text),
  batch_student_users(uuid), batch_tutor_users(uuid), admin_users(), everyone_student_users() from public, anon, authenticated;

create or replace function notify_assignment_new()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not notification_quiet(new.batch_id) then
    perform notify_users(batch_student_users(new.batch_id), 'assignment_new', new.batch_id, new.title, '/portal/assignments');
  end if;
  return null;
end $$;

drop trigger if exists notify_assignment_new on assignments;
create trigger notify_assignment_new after insert on assignments for each row execute function notify_assignment_new();

create or replace function notify_assignment_graded()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  work assignments%rowtype;
begin
  if new.mark and (tg_op = 'INSERT' or not coalesce(old.mark, false)) then
    select * into work from assignments where id = new.assignment_id;
    if found and not notification_quiet(work.batch_id) then
      perform notify_users(
        array(select auth_user_id from students where id = new.student_id),
        'assignment_graded', work.batch_id, work.title, '/portal/assignments'
      );
    end if;
  end if;
  return null;
end $$;

drop trigger if exists notify_assignment_graded on assignment_completions;
create trigger notify_assignment_graded after insert or update of mark on assignment_completions for each row execute function notify_assignment_graded();

create or replace function notify_material_new()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- A handout belongs to its assignment, which already notified
  if new.assignment_id is null and not notification_quiet(new.batch_id) then
    perform notify_users(
      case when new.batch_id is null then everyone_student_users() else batch_student_users(new.batch_id) end,
      'material_new', new.batch_id, coalesce(new.folder, new.title), '/portal/materials'
    );
  end if;
  return null;
end $$;

drop trigger if exists notify_material_new on materials;
create trigger notify_material_new after insert on materials for each row execute function notify_material_new();

create or replace function notify_quiz_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is not distinct from old.status or notification_quiet(new.batch_id) then
    return null;
  end if;

  if new.status = 'lobby' and old.status = 'draft' then
    perform notify_users(
      case when new.batch_id is null then everyone_student_users() else batch_student_users(new.batch_id) end,
      'quiz_new', new.batch_id, new.title, '/portal/quizzes'
    );
  elsif new.status = 'ended' then
    perform notify_users(
      array(select s.auth_user_id from quiz_participants p join students s on s.id = p.student_id where p.quiz_id = new.id),
      'quiz_result', new.batch_id, new.title, '/portal/quizzes'
    );
    if new.batch_id is not null then
      perform notify_users(batch_tutor_users(new.batch_id), 'quiz_finished', new.batch_id, new.title, '/tutor/exams/' || new.id);
    end if;
  end if;
  return null;
end $$;

drop trigger if exists notify_quiz_status on quizzes;
create trigger notify_quiz_status after update of status on quizzes for each row execute function notify_quiz_status();

-- A student joining or leaving a batch, and a document released to them
create or replace function notify_enrolment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  person students%rowtype;
begin
  select * into person from students where id = new.student_id;

  if tg_op = 'INSERT' then
    if new.status = 'active' and not notification_quiet(new.batch_id) then
      perform notify_users(batch_tutor_users(new.batch_id), 'student_joined', new.batch_id, person.name, '/tutor/batches/' || new.batch_id);
    end if;
    return null;
  end if;

  if new.status = 'transferred' and old.status is distinct from new.status and not notification_quiet(new.batch_id) then
    perform notify_users(batch_tutor_users(new.batch_id), 'student_transferred', new.batch_id, person.name, '/tutor/batches/' || new.batch_id);
    perform notify_users(admin_users(), 'student_transferred', new.batch_id, person.name, '/students/' || new.student_id);
  end if;

  -- Released documents are what a finished batch is for, so only a test batch stays silent
  if not notification_quiet(new.batch_id, true) and person.auth_user_id is not null then
    if new.offer_letter_shared and not old.offer_letter_shared then
      perform notify_users(array[person.auth_user_id], 'document_shared', new.batch_id, 'Offer letter', '/portal/profile');
    end if;
    if new.cert_shared and not old.cert_shared then
      perform notify_users(array[person.auth_user_id], 'document_shared', new.batch_id, 'Certificate', '/portal/profile');
    end if;
  end if;
  return null;
end $$;

drop trigger if exists notify_enrolment on batch_student_mapping;
create trigger notify_enrolment after insert or update of status, offer_letter_shared, cert_shared on batch_student_mapping for each row execute function notify_enrolment();

create or replace function notify_batch_ended()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.ended_at is null and new.ended_at is not null and not new.is_test then
    perform notify_users(admin_users(), 'batch_ended', new.id, new.name, '/batches/' || new.id);
    perform notify_users(batch_tutor_users(new.id), 'batch_ended', new.id, new.name, '/tutor/batches/' || new.id);
  end if;
  return null;
end $$;

drop trigger if exists notify_batch_ended on batches;
create trigger notify_batch_ended after update of ended_at on batches for each row execute function notify_batch_ended();

create or replace function notify_claim_verified()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'approved' and old.status is distinct from new.status and not notification_quiet(new.batch_id, true) then
    perform notify_users(
      array(select auth_user_id from students where id = new.student_id),
      'payment_verified', new.batch_id, '₹' || trim_scale(new.amount)::text, '/portal/profile'
    );
  end if;
  return null;
end $$;

drop trigger if exists notify_claim_verified on payment_claims;
create trigger notify_claim_verified after update of status on payment_claims for each row execute function notify_claim_verified();

create or replace function notify_feedback()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  person students%rowtype;
begin
  select * into person from students where id = new.student_id;

  if tg_op = 'INSERT' then
    if not person.is_test then
      perform notify_users(admin_users(), 'feedback_new', null, person.name, '/feedback');
    end if;
  elsif new.status = 'resolved' and old.status is distinct from new.status then
    perform notify_users(array[person.auth_user_id], 'feedback_resolved', null, left(new.message, 60), '/portal/feedback');
  end if;
  return null;
end $$;

drop trigger if exists notify_feedback on feedback;
create trigger notify_feedback after insert or update of status on feedback for each row execute function notify_feedback();

create or replace function notify_curriculum_decided()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status in ('approved', 'denied') and old.status = 'pending' and not notification_quiet(new.batch_id) then
    perform notify_users(
      case when new.proposed_by is null then batch_tutor_users(new.batch_id)
           else array(select auth_user_id from tutors where id = new.proposed_by) end,
      'curriculum_decided', new.batch_id,
      case new.status when 'approved' then 'Approved' else 'Denied' end,
      '/tutor/curriculum/' || new.batch_id
    );
  end if;
  return null;
end $$;

drop trigger if exists notify_curriculum_decided on curriculum_requests;
create trigger notify_curriculum_decided after update of status on curriculum_requests for each row execute function notify_curriculum_decided();


-- 23. CURRICULUM BADGES
-- A card can carry badges. Once the card is done and everything under it is done or skipped, the batch's
-- tutors get a live "award badge" task until that badge is given to at least one student.
create table if not exists curriculum_node_badges (
  node_id  uuid references curriculum_nodes(id) on delete cascade not null,
  badge_id uuid references batch_badges(id) on delete cascade not null,
  primary key (node_id, badge_id)
);

create index if not exists idx_node_badges_badge on curriculum_node_badges(badge_id);

alter table curriculum_node_badges enable row level security;

-- Seen by whoever sees the card: admin, the batch's tutors, the batch's students
drop policy if exists read_with_node on curriculum_node_badges;
create policy read_with_node on curriculum_node_badges
  for select using (node_id in (select id from curriculum_nodes));

-- Every write goes through set_node_badges
revoke all on curriculum_node_badges from anon, authenticated;
grant select on curriculum_node_badges to authenticated;

-- Makes the card's badges equal p_badges; only badges of the card's own batch
create or replace function set_node_badges(p_node uuid, p_badges uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b     uuid;
  ended date;
begin
  select n.batch_id, bt.ended_at into b, ended
  from curriculum_nodes n join batches bt on bt.id = n.batch_id
  where n.id = p_node;
  if b is null then
    raise exception 'Not found';
  end if;
  if not (is_admin() or exists (select 1 from tutor_batch_mapping where tutor_id = current_tutor_id() and batch_id = b)) then
    raise exception 'Not your batch';
  end if;
  if ended is not null and not is_admin() then
    raise exception 'This batch has ended';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_badges, '{}')) as x(id)
    where not exists (select 1 from batch_badges where id = x.id and batch_id = b)
  ) then
    raise exception 'Invalid badge';
  end if;

  delete from curriculum_node_badges where node_id = p_node and badge_id <> all (coalesce(p_badges, '{}'));
  insert into curriculum_node_badges (node_id, badge_id)
  select p_node, x from unnest(coalesce(p_badges, '{}')) as t(x)
  on conflict do nothing;
end $$;

revoke all on function set_node_badges(uuid, uuid[]) from public, anon;
grant execute on function set_node_badges(uuid, uuid[]) to authenticated;

-- The signed-in tutor's open tasks: a done card whose whole subtree is done or skipped, with a badge nobody holds yet
create or replace function badges_to_award()
returns table (batch_id uuid, batch_name text, badge_id uuid, badge_name text, node_title text)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, b.name, bb.id, bb.name, n.title
  from curriculum_nodes n
  join curriculum_node_badges nb on nb.node_id = n.id
  join batch_badges bb on bb.id = nb.badge_id
  join batches b on b.id = n.batch_id
  where n.batch_id in (select m.batch_id from tutor_batch_mapping m where m.tutor_id = current_tutor_id())
    and not b.is_test
    and b.ended_at is null
    and n.status = 'done'
    and not exists (select 1 from curriculum_nodes c where c.parent_id = n.id and c.status = 'todo')
    and not exists (
      select 1 from curriculum_nodes c join curriculum_nodes g on g.parent_id = c.id
      where c.parent_id = n.id and g.status = 'todo'
    )
    and not exists (select 1 from student_badges s where s.badge_id = bb.id)
  order by b.name, n.title;
$$;

revoke all on function badges_to_award() from public, anon;
grant execute on function badges_to_award() to authenticated;


-- 24. DOCUMENT VERIFICATION
-- The public check behind the office site: is this badge, certificate or offer letter real. Called only by the
-- verify edge function with the service role. verify_blocks is the per-IP lockout store.
create table if not exists verify_blocks (
  ip            text primary key,
  failures      int not null default 0,
  lookups       int not null default 0,
  window_start  timestamptz not null default now(),
  blocked_until timestamptz
);

-- No policies at all: only the service role gets through
alter table verify_blocks enable row level security;
revoke all on verify_blocks from anon, authenticated;

-- Replaced by verify_document
drop function if exists verify_badge(text, text);

-- One call does the block check, the lookup and the counting, so two requests cannot both slip under a limit.
-- 10 misses or 60 lookups inside a 15 minute window block the IP for an hour; a blocked IP gets nothing back.
-- A badge is looked up by its code and can be taken back (revoked). A certificate or offer letter is looked up by the
-- student's ID; it counts once it was ever shared, and the row alone is enough, so it still verifies after the 90-day
-- clean-up removed the file. Never revoked.
-- ponytail: fixed window, not sliding; a sliding one needs a row per attempt.
create or replace function verify_document(p_ref text, p_doc_type text, p_ip text)
returns table (doc_type text, status text, holder_name text, issue_date date, doc_name text, image_path text)
language plpgsql
security definer
set search_path = public
as $$
declare
  rec       verify_blocks%rowtype;
  hit       record;
  hit_found boolean := false;
begin
  -- Rows with nothing left to remember
  delete from verify_blocks
  where window_start < now() - interval '15 minutes' and coalesce(blocked_until, '-infinity') < now();

  insert into verify_blocks (ip) values (p_ip) on conflict (ip) do nothing;
  select * into rec from verify_blocks where ip = p_ip for update;

  if rec.blocked_until > now() then
    return;
  end if;

  -- A new window once the last one ran out, or the block ended
  if rec.window_start < now() - interval '15 minutes' or rec.blocked_until is not null then
    rec.failures := 0;
    rec.lookups := 0;
    rec.window_start := now();
    rec.blocked_until := null;
  end if;

  -- A null ref or type (input that failed validation) is a miss that costs the same as a real one
  if p_ref is not null and p_doc_type = 'badge' then
    select
      'badge'::text as doc_type,
      case when sb.id is null then 'revoked' else 'valid' end as status,
      regexp_replace(btrim(s.name), '\s+', ' ', 'g') as holder_name,
      (coalesce(sb.issued_at, bc.created_at) at time zone 'Asia/Kolkata')::date as issue_date,
      bb.name as doc_name,
      bb.image_path as image_path
    into hit
    from badge_codes bc
    join students s on s.id = bc.student_id
    join batch_badges bb on bb.id = bc.badge_id
    left join student_badges sb on sb.student_id = bc.student_id and sb.badge_id = bc.badge_id
    where bc.code = p_ref and not s.is_test;
    hit_found := found;
  elsif p_ref is not null and p_doc_type in ('certificate', 'offer_letter') then
    select
      p_doc_type as doc_type,
      'valid'::text as status,
      regexp_replace(btrim(s.name), '\s+', ' ', 'g') as holder_name,
      (max(case p_doc_type when 'certificate' then m.cert_shared_at else m.offer_letter_shared_at end) at time zone 'Asia/Kolkata')::date as issue_date,
      case p_doc_type when 'certificate' then 'Internship Completion Certificate' else 'Offer of Internship' end as doc_name,
      null::text as image_path
    into hit
    from students s
    join batch_student_mapping m on m.student_id = s.id
    where s.student_code = p_ref and not s.is_test
      and (case p_doc_type when 'certificate' then m.cert_shared_at else m.offer_letter_shared_at end) is not null
    group by s.id, s.name;
    hit_found := found;
  end if;

  rec.lookups := rec.lookups + 1;
  if not hit_found then
    rec.failures := rec.failures + 1;
  end if;
  if rec.failures >= 10 or rec.lookups >= 60 then
    rec.blocked_until := now() + interval '1 hour';
  end if;

  update verify_blocks
  set failures = rec.failures, lookups = rec.lookups, window_start = rec.window_start, blocked_until = rec.blocked_until
  where ip = p_ip;

  if hit_found then
    return query select hit.doc_type, hit.status, hit.holder_name, hit.issue_date, hit.doc_name, hit.image_path;
  end if;
end $$;

revoke all on function verify_document(text, text, text) from public, anon, authenticated;
grant execute on function verify_document(text, text, text) to service_role;
