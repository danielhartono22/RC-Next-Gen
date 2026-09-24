import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
const $ = (id) => document.getElementById(id);
const config = window.RC_AUTH_CONFIG;
let client;
const message = (text) => { $('message').textContent = text; };
export async function loginEmail(code) {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(code.trim()));
  return [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, '0')).join('') + '@rc-login.invalid';
}
async function renderAccount() {
  const { data: { user }, error } = await client.auth.getUser();
  if (error || !user) throw new Error('Sesi tidak tersedia. Silakan login kembali.');
  const { data: profile, error: profileError } = await client.from('profiles')
    .select('user_code,full_name,must_change_password').eq('id', user.id).single();
  if (profileError || !profile) { await client.auth.signOut(); throw new Error('Akun belum aktif atau belum mendapat profil RC.'); }
  $('login').hidden = true; $('logout').hidden = false;
  $('change').hidden = !profile.must_change_password;
  $('account').hidden = profile.must_change_password;
  if (profile.must_change_password) { message('Login berhasil. Ganti password untuk melanjutkan.'); return; }
  $('name').textContent = `${profile.full_name} (${profile.user_code})`;
  const { data, error: depotError } = await client.from('depots').select('depot_code,depot_name').order('depot_code').limit(100);
  if (depotError) throw new Error('Gagal membaca depot.');
  $('depots').replaceChildren(...data.map(d => {
    const li = document.createElement('li'); li.textContent = `${d.depot_code} — ${d.depot_name}`; return li;
  }));
  message(data.length ? 'Login dan akses depot berhasil.' : 'Login berhasil. Belum ada depot yang ditetapkan.');
}
async function submit(form, action) {
  const button = form.querySelector('button'); button.disabled = true;
  try { await action(); } catch (e) { message(e.message || 'Proses gagal.'); }
  finally { button.disabled = false; }
}
if (!config?.publishableKey) {
  message('Konfigurasi publishable key DEV belum tersedia.');
  $('login').querySelector('button').disabled = true;
} else {
  client = createClient(config.url, config.publishableKey, { auth: { persistSession: false, detectSessionInUrl: false } });
}
$('login').addEventListener('submit', event => {
  event.preventDefault(); if (!client) return;
  submit($('login'), async () => {
    const password = $('password').value;
    try {
      const { error } = await client.auth.signInWithPassword({ email: await loginEmail($('userid').value), password });
      if (error) throw new Error('Login gagal. Periksa user ID/password atau coba kembali nanti.');
      await renderAccount();
    } finally { $('password').value = ''; }
  });
});
$('change').addEventListener('submit', event => {
  event.preventDefault(); submit($('change'), async () => {
    const password = $('newPassword').value;
    if (password.length < 8 || password !== $('confirmPassword').value) throw new Error('Password minimal 8 karakter dan kedua isian harus sama.');
    const { error } = await client.auth.updateUser({ password });
    if (error) throw new Error('Password belum dapat diubah. Coba password lain atau login kembali.');
    $('newPassword').value = ''; $('confirmPassword').value = '';
    await renderAccount();
  });
});
$('logout').addEventListener('click', async () => {
  await client.auth.signOut(); location.reload();
});
