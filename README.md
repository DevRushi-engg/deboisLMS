# deboistech LMS

Admin dashboard for running training batches — students, tutors, attendance, fees, assignments and
study material — plus a read-only student portal and a batch-scoped tutor dashboard.

Built with Vite 6 + React 19 + TypeScript, Tailwind CSS 4, and Supabase (Postgres, Auth, Storage,
Edge Functions).

## Who logs in

- **Admins** run everything from the dashboard at `/`.
- **Students** get a read-only portal at `/portal`. Their logins are **created by an admin**, not by
  self-signup — there is no public registration and no class-join code.
- **Tutors** get a dashboard at `/tutor`, scoped to whichever batch(es) an admin assigns them via
  `tutor_batch_mapping`: their students' profiles (never fees), lectures and attendance, assignments
  and grading, and study material. Like students, their login is created by an admin, not by
  self-signup. They cannot see finance anywhere, create logins, or edit batch/student rosters.

Roles come from `app_metadata.role` on the auth user, and access is enforced by row-level security
in Postgres rather than by the client.

## Setup

```bash
npm install
cp .env.example .env    # fill in your Supabase URL and anon key
npm run dev
```

### Database

`supabase/schema.sql` is the whole database — tables, enums, views, functions, storage buckets
and row-level security. Paste it into the Supabase SQL editor and run it. It is idempotent, so
running it again on a live project is safe and changes nothing.

Before running it on a new project, edit the admin email in section 8 — that `update auth.users`
block is what tags your account as an admin, and the account must already exist in Supabase Auth.

### Edge functions

Anything needing a secret runs server-side. Deploy each with
`supabase functions deploy <name> --project-ref <ref>`:

| Function | Purpose | Secret |
|---|---|---|
| `create-student-login` | Creates/resets a student's portal login | `SECRET_SERVICE_ROLE_KEY` |
| `create-tutor-login` | Creates/resets a tutor's dashboard login | `SECRET_SERVICE_ROLE_KEY` |
| `match-name` | Gemini fuzzy name matching for attendance | `GEMINI_API_KEY` |
| `lms-assistant` | Authenticated, role-aware LMS help using Gemini and caller-scoped RLS queries | `GEMINI_API_KEY` |
| `send-credentials` | Emails a student their portal login, one or a whole import | `RESEND_API_KEY` |
| `send-document` | Emails a shared offer letter or certificate | `RESEND_API_KEY`, `CREDENTIALS_FROM_EMAIL` |
| `verify` | Public badge, certificate and offer letter check for the office website | `VERIFY_API_KEY`, `SECRET_SERVICE_ROLE_KEY` |

```bash
supabase functions deploy lms-assistant --project-ref <ref>

supabase secrets set SECRET_SERVICE_ROLE_KEY=... --project-ref <ref>
supabase secrets set GEMINI_API_KEY=...          --project-ref <ref>

# send-credentials. Refuses to send until all three are set, and names the missing one.
supabase secrets set \
  RESEND_API_KEY=re_xxx \
  CREDENTIALS_FROM_EMAIL="Deboistech <no-reply@deboistech.in>" \
  PORTAL_URL=https://lms.deboistech.in/auth/login/user \
  CREDENTIALS_REPLY_TO=connect@deboistech.in \
  --project-ref <ref>
```

`CREDENTIALS_FROM_EMAIL` must be on a domain verified in Resend. `PORTAL_URL` is the student
sign-in page, not `/portal` — an unauthenticated visitor to `/portal` lands on the admin/student
choice screen. `CREDENTIALS_REPLY_TO` is optional; without it, replies to a noreply address bounce.

The `\` above is bash. On PowerShell put the whole command on one line — a backslash there is read
as a literal and the next line fails with `Missing expression after unary operator '--'`.

Every function also reads `ALLOWED_ORIGINS`. Unset means any origin may call them:

```bash
supabase secrets set ALLOWED_ORIGINS=https://lms.deboistech.in --project-ref <ref>
```

Without `GEMINI_API_KEY`, attendance still works — it falls back to deterministic name matching and
flags the rest for manual review.

### Document verification (for the office website)

`verify` lets the office site check a badge, a certificate or an offer letter, server to server. Run `supabase/migration_2026_10_13b.sql` once (it is also in `schema.sql`), then:

```bash
supabase secrets set VERIFY_API_KEY=<long random string> --project-ref <ref>
supabase functions deploy verify --no-verify-jwt --project-ref <ref>
```

`--no-verify-jwt` is required: the caller has no Supabase login, it proves itself with `x-api-key`. The function reuses `SECRET_SERVICE_ROLE_KEY`. It sends no CORS headers; call it from the office site's server, never from a browser.

**Request:** `POST https://<ref>.supabase.co/functions/v1/verify`

| Header | |
|---|---|
| `x-api-key` | Must equal `VERIFY_API_KEY`. Missing or wrong: `401` |
| `x-client-ip` | The visitor's IP, for the lockout. Read only when the key is right. Missing or not an IP: counted under one shared `unknown` bucket |
| `Content-Type` | `application/json` |

Body `{ "ref": "...", "docType": "..." }`:

| What | `ref` format | `docType` |
|---|---|---|
| Badge | `DBT<batch code>-<YY><number>-<5 letters or digits>`, e.g. `DBTPHR-260012-1A3BC` | `badge`, or leave it out |
| Internship completion certificate | The student's ID, `DBT-INT-<year>-<number>`, e.g. `DBT-INT-2026-012` | `certificate` (required) |
| Offer letter | The same student's ID | `offer_letter` (required) |

A student's certificate and offer letter share one ref, so the type must be sent. The ref is trimmed and uppercased; the type is trimmed and lowercased.

**Response, found:** `200`, `Cache-Control: no-store`

```json
{ "docType": "certificate", "status": "valid", "holderName": "Asha Bankar", "issueDate": "2026-10-02", "badgeName": "Internship Completion Certificate" }
```

A badge reply also carries `"badgeImageUrl": "https://.../storage/v1/object/public/assets/badges/..."` (a public URL; omitted when there is none). Certificates and offer letters have no image. There is no `expiryDate`: none of the three has an end date stored. Nothing else is ever sent.

- **Badge:** `valid` while the student holds it, `revoked` after it was taken back (re-awarding makes it valid again under the same ref). `issueDate` is the day it was awarded; `badgeName` is the badge's name.
- **Certificate and offer letter:** found once the document was shared with the student at least once, and the row alone counts, so it still verifies after the 90-day clean-up deleted the file. It is never revoked: unsharing, deleting or archiving does not change the answer. `issueDate` is the day it was first shared (the latest, if the student has several batches). `badgeName` is "Internship Completion Certificate" or "Offer of Internship".
- `holderName` is the student's full name. Certificate refs are sequential, so anyone who can call this API can step through them; the only brakes are the lockout below and keeping the key private.
- Students in test batches never match.

**Response, anything else:** `404` with `{ "error": "not_found" }`, the same for an unknown ref, a ref that does not fit the type, a missing type on a student ID, a bad body, a wrong method and a blocked IP. Every answer takes at least 250 ms.

**Lockout:** per IP, 10 misses or 60 lookups in 15 minutes block that IP for an hour. A blocked IP gets the same `404` for every ref. A malformed request counts as a miss. Rows in `verify_blocks` clear themselves.

**Log:** each failure is one JSON line in the function logs (Supabase dashboard, Edge Functions, verify): time, IP and the ref as typed, cleaned to letters, digits and hyphens and cut at 60 characters.

**Rotate the key** with no downtime:

1. Move the live key aside: `supabase secrets set VERIFY_API_KEY_PREVIOUS=<old key> VERIFY_API_KEY=<new key> --project-ref <ref>`
2. Put the new key in the office site's environment and redeploy it.
3. Remove the old one: `supabase secrets unset VERIFY_API_KEY_PREVIOUS --project-ref <ref>`

Secrets are read when the function starts, so redeploy `verify` after changing them.

`npm test` runs the checks for it.

## Commands

```bash
npm run dev       # dev server
npm run build     # tsc -b && vite build (type-checks before bundling)
npm run preview   # preview the production build
npm run lint      # eslint
npm test          # node --test: the verify endpoint and its Postgres lookup and lockout
```

## How the main pieces work

**Attendance** is a three-stage pipeline: a Google Meet CSV is ingested as-is, then processed per
lecture (reconnect rows merged, names matched to the roster, minutes compared against the scheduled
duration), then written as one row per student per lecture with `approved: false`. Nothing counts
towards a dashboard or a student's portal until an admin approves it — the AI matching step is not
treated as trustworthy on its own.

**Study material** accepts any file, and what happens to it depends on what it is. PDFs and images
are watermarked and paged in the in-app reader — an image is wrapped into a one-page PDF first, so
it takes the same path. Word files are converted to PDF in the browser before upload, which keeps
the text but not the layout. Markdown and plain text are shown as written. Everything else — sheets,
decks, archives — is handed over directly, because no browser renders them. Every kind can be
downloaded.

The watermark is stamped once, client-side, at upload — the stored file is the final copy, not
something rebuilt on every open. A read is a plain storage fetch: the bucket is private, but a
storage policy lets an enrolled student read a material's bytes directly, gated by the same
enrolment rule as the `materials` table row itself. The view log, written for every kind including
downloads, still says who opened what and when. Assignment handouts are the same table with an
`assignment_id`, so they inherit the reader, the log and the enrolment rule.

**Portal logins** use a password derived from the student's phone (`Debois@<last4>`). Supabase Auth
stores only a hash and this app stores no plaintext copy; the dashboard shows the current password
by recomputing it from the same rule.

## Docs

- `supabase/schema.sql` — the data model, commented where a choice is not obvious
- `src/globals.css` — design tokens and every shared component class
- `src/components/portal/README.md` — the portal widget kit and the rules that keep it consistent
