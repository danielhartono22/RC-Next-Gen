ampil/*
 * Public browser configuration for the Resource Collection frontend.
 *
 * Only the project URL and a publishable/anon key belong here. A service_role or secret key
 * in this file would be readable by every visitor. Nothing in this file is a secret, so it
 * is committed and deployed as a static asset.
 *
 * dataBackend is the rollback switch from section 13 of the migration instruction:
 *   'supabase'    -- read and write through Supabase (target state)
 *   'apps_script' -- fall back to the existing Apps Script deployment, unchanged
 * Flip it, redeploy, and the application is back on the old backend. Never run a mixed
 * state where the same action writes to both.
 */
window.RC_ENV = {
  dataBackend: 'supabase',
  supabaseUrl: 'https://vvojshgcduqlugngpzkj.supabase.co',
  supabasePublishableKey: 'sb_publishable_CO-7bzo2xZnUg3LQEjWP5Q_zEqvAVLd',
  appsScriptUrl: '', // diisi saat deploy bila fallback Apps Script dibutuhkan
  environment: 'dev'
};
