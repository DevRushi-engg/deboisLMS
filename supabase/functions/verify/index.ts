import { createClient } from 'jsr:@supabase/supabase-js@2';
import { handleVerify } from './handler.ts';

// Public badge check for the office website, called server to server
// Deploy without JWT verification, the caller proves itself with x-api-key:
//   supabase functions deploy verify --no-verify-jwt --project-ref <ref>
// No CORS headers on purpose: a browser has no business calling this

const keys = [Deno.env.get('VERIFY_API_KEY'), Deno.env.get('VERIFY_API_KEY_PREVIOUS')].filter((key): key is string => Boolean(key));
if (keys.length === 0) console.error('[verify] VERIFY_API_KEY is not set: every request will be refused');

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SECRET_SERVICE_ROLE_KEY')!);

Deno.serve((req) =>
  handleVerify(req, {
    keys,
    log: (line) => console.error(line),
    lookup: async (ref, ip) => {
      const { data, error } = await db.rpc('verify_badge', { p_ref: ref, p_ip: ip });
      if (error) throw error;
      const row = (data as { status: 'valid' | 'revoked'; issue_date: string; holder_name: string }[] | null)?.[0];
      return row ? { status: row.status, issueDate: row.issue_date, holderName: row.holder_name } : null;
    },
  }),
);
