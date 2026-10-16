-- ==========================================================================================
-- KHUSUS DEV - jangan dijalankan ke prod
-- ==========================================================================================
-- Pemilik, 13 Oktober 2026: "untuk di dev hanya ada email uji."
--
-- Menandai lingkungan ini sebagai hanya-email-uji (rc_private.lingkungan_email, dari migrasi
-- 20261163040000). Sejak tanda ini terpasang, rc_private.kirim_satu_email hanya meneruskan
-- email uji (kirim uji dari layar, atau mode uji Email Pengajuan yang alamatnya alamat uji).
-- Surat untuk penerima sungguhan (alamat depot di Depot Master, CC tambahan) ditandai skipped
-- dengan keterangan, apa pun setelan email dan sakelarnya.
--
-- Di prod tabel itu sengaja kosong. Menjalankan berkas ini ke prod akan menghentikan seluruh
-- email depot, karena itu apply-sql dipanggil dengan --env dev.
-- ==========================================================================================
do $dev$
begin
  if to_regclass('rc_private.lingkungan_email') is null then
    raise exception 'Pasang migrasi 20261163040000 lebih dulu.'; end if;
  insert into rc_private.lingkungan_email(id, hanya_uji, catatan, diubah_pada)
  values (true, true, 'DEV: hanya email uji (13-Okt-2026)', now())
  on conflict (id) do update set hanya_uji = true, catatan = excluded.catatan, diubah_pada = now();
end
$dev$;

select hanya_uji, catatan, rc_private.hanya_email_uji() aktif,
       rc_private.email_ditahan_lingkungan('{"aksi":"submit"}'::jsonb) surat_depot_ditahan,
       rc_private.email_ditahan_lingkungan('{"uji":true}'::jsonb) email_uji_ditahan
  from rc_private.lingkungan_email;
