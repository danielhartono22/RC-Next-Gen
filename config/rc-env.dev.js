/*
 * Konfigurasi peramban untuk lingkungan DEV.
 *
 * Menunjuk project Supabase rc-next-gen-dev, yang berisi DATA REKAYASA - bukan data pelanggan
 * sungguhan. Berkas ini dipasang oleh build hanya ketika dijalankan dengan --env dev, sehingga
 * build produksi tidak mungkin ikut membawanya.
 *
 * Hanya URL project dan kunci publishable yang boleh ada di sini; keduanya memang dirancang
 * untuk dibaca setiap pengunjung.
 */
window.RC_ENV = {
  dataBackend: 'supabase',
  supabaseUrl: 'https://fimjgmjjsplwgmuwzwbx.supabase.co',
  supabasePublishableKey: 'sb_publishable_Nk1_qquNHCeE3l2ZkN_3ZQ_AGSh1y6i',
  environment: 'dev'
};
