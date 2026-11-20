/*
 * Contoh konfigurasi peramban. Salin menjadi config/rc-env.js (prod) atau config/rc-env.dev.js
 * (dev) lalu isi nilainya secara lokal. Berkas aslinya tidak masuk git.
 * Hanya URL project dan publishable key yang boleh ada di sini - jangan pernah service_role.
 */
window.RC_ENV = {
  dataBackend: 'supabase',
  supabaseUrl: 'https://<project-ref>.supabase.co',
  supabasePublishableKey: '<publishable-key>',
  environment: 'prod'
};
