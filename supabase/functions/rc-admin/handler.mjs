const cors = { 'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization,x-client-info,apikey,content-type',
  'Access-Control-Allow-Methods': 'POST,OPTIONS' };
const out = (data, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }
});
const result = (plan, id) => ({ status: 'success', id, user_code: plan.user_code,
  source: plan.source || 'manual', activation: plan.activation || (plan.source === 'upload' ? 'pending' : 'active'),
  message: plan.source === 'upload'
    ? 'User upload tersimpan. Status dan keputusan dapat dilihat pada Approval Request; akses berlaku setelah disetujui.'
    : 'Akun berhasil dibuat. PIN awal wajib diganti saat login; lengkapi hak modul melalui Edit Akses.' });

export function createRegistrationHandler({ createClient, url, serviceKey, apiKey,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) }) {
  return async function registration(req) {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
    if (req.method !== 'POST') return out({ error: 'Method not allowed' }, 405);
    const authorization = req.headers.get('Authorization') || '';
    if (!/^Bearer \S+$/i.test(authorization)) return out({ error: 'Unauthorized' }, 401);
    try {
      const token = authorization.replace(/^Bearer /i, '');
      const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
      const { data, error: authError } = await admin.auth.getUser(token);
      if (authError || !data?.user) return out({ error: 'Unauthorized' }, 401);
      const text = await req.text();
      if (new TextEncoder().encode(text).length > 12000) return out({ error: 'Request too large' }, 413);
      const input = JSON.parse(text);
      if (!['create','submit_upload'].includes(input.action)) return out({ error: 'Unknown action' }, 400);
      const password = String(input.password || '');
      if (password.length < 8 || new TextEncoder().encode(password).length > 72) {
        return out({ error: 'PIN minimal 8 karakter dan maksimal 72 byte.' }, 400);
      }
      // Only the caller's JWT authorizes the proposed role and assignments.
      const caller = createClient(url, apiKey, { global: { headers: { Authorization: authorization } },
        auth: { persistSession: false, autoRefreshToken: false } });
      const payload = { request_id: input.request_id, user_code: input.user_code, full_name: input.full_name,
        business_email: input.business_email, role: input.role, department: input.department || '',
        home_depot: input.home_depot, depot_codes: input.depot_codes || [],
        osc_codes: input.osc_codes || [], regions: input.regions || [] };
      // This endpoint mode always goes through approval, even if the caller submits an
      // activation flag or attempts to replace the source.
      if (input.action === 'submit_upload') payload.source = 'upload';
      const prepare = () => caller.rpc('rc_prepare_registration', { p_payload: payload });
      const { data: plan, error: planError } = await prepare();
      if (planError) return out({ error: planError.message }, planError.code === '42501' ? 403 : 400);
      if (plan.completed_id) return out(result(plan, plan.completed_id));
      const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(plan.user_code));
      const email = Array.from(new Uint8Array(digest)).map(x => x.toString(16).padStart(2, '0')).join('') + '@rc-login.invalid';
      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
        user_metadata: { user_code: plan.user_code, full_name: plan.full_name,
          business_email: plan.business_email, requested_role: plan.role, requested_depot: plan.home_depot },
        app_metadata: { rc_managed_registration: { actor_id: data.user.id, payload: plan } }
      });
      if (createError || !created?.user) {
        // A concurrent retry may have committed. Never reset that account's password.
        for (const delay of [0, 150, 350, 750]) {
          if (delay) await sleep(delay);
          const replay = await prepare();
          if (!replay.error && replay.data?.completed_id) return out(result(replay.data, replay.data.completed_id));
        }
        return out({ error: 'Akun belum dibuat. Muat ulang pilihan role/depot dan periksa apakah User ID sudah digunakan.' }, 409);
      }
      // Auth, profile, assignments and audit commit atomically in the Auth insert trigger.
      return out(result(plan, created.user.id), 201);
    } catch (error) {
      if (error instanceof SyntaxError) return out({ error: 'Invalid JSON' }, 400);
      return out({ error: 'Registrasi belum dapat dikonfirmasi. Ulangi dengan data yang sama.' }, 503);
    }
  };
}
