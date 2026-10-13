import { createClient } from 'jsr:@supabase/supabase-js@2';
import { handleVerify, type DocType } from './handler.ts';

// Public badge, certificate and offer letter check for the office website, called server to server
// Deploy without JWT verification, the caller proves itself with x-api-key:
//   supabase functions deploy verify --no-verify-jwt --project-ref <ref>
// No CORS headers on purpose: a browser has no business calling this

const keys = [Deno.env.get('VERIFY_API_KEY'), Deno.env.get('VERIFY_API_KEY_PREVIOUS')].filter((key): key is string => Boolean(key));
if (keys.length === 0) console.error('[verify] VERIFY_API_KEY is not set: every request will be refused');

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const db = createClient(SUPABASE_URL, Deno.env.get('SECRET_SERVICE_ROLE_KEY')!);

type Row = { doc_type: DocType; status: 'valid' | 'revoked'; holder_name: string; issue_date: string; doc_name: string; image_path: string | null };

Deno.serve((req) =>
  handleVerify(req, {
    keys,
    log: (line) => console.error(line),
    lookup: async (ref, docType, ip) => {
      const { data, error } = await db.rpc('verify_document', { p_ref: ref, p_doc_type: docType, p_ip: ip });
      if (error) throw error;
      const row = (data as Row[] | null)?.[0];
      if (!row) return null;
      return {
        docType: row.doc_type,
        status: row.status,
        holderName: row.holder_name,
        issueDate: row.issue_date,
        badgeName: row.doc_name,
        // The assets bucket is public; the URL is built here, nothing is signed
        ...(row.image_path ? { badgeImageUrl: `${SUPABASE_URL}/storage/v1/object/public/assets/${row.image_path}` } : {}),
      };
    },
  }),
);
