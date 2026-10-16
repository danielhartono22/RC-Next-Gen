-- ==========================================================================================
-- Email pengajuan tidak melampirkan PDF
-- ==========================================================================================
-- Aturan lampiran yang berlaku sebelumnya adalah "semua jenis kecuali weekly". Aturan itu
-- lahir ketika jenis yang ada hanyalah laporan berkala, dan untuk laporan memang masuk akal.
--
-- Email pengajuan bukan laporan. Ia pemberitahuan pendek tentang SATU batch, dan isinya sudah
-- lengkap di badan surat: No Batch, Nama Campaign, Jumlah Toko, Total CB dan Grand Total.
-- Melampirkan laporan penuh 100+ KB pada tiap Submitted, On Hold, Expired, Approval dan
-- Clearing hanya memperberat kotak masuk penerimanya, dan membuat satu PDF dibangkitkan setiap
-- kali depot menekan Posting.
--
-- Weekly tetap seperti semula. Yang ditambahkan hanya satu pengecualian.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.email_perlu_pdf(p_jenis text)
returns boolean language sql immutable set search_path to '' as $fn$
  -- Weekly sudah menautkan dashboard publik yang memuat detail yang sama, jadi lampirannya
  -- tidak menambah apa pun.
  --
  -- Pengajuan adalah pemberitahuan satu batch, bukan laporan: seluruh angkanya sudah ada di
  -- badan surat.
  select lower(coalesce(p_jenis,'')) not in ('weekly','pengajuan');
$fn$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
begin
  if rc_private.email_perlu_pdf('pengajuan') then
    raise exception 'GAGAL: email pengajuan masih meminta lampiran PDF.'; end if;
  if rc_private.email_perlu_pdf('weekly') then
    raise exception 'GAGAL: weekly berubah perilakunya.'; end if;

  -- Yang lain HARUS tetap melampirkan. Tanpa pemeriksaan ini, satu salah ketik pada daftar
  -- pengecualian akan diam-diam mencabut lampiran dari laporan harian juga.
  if not rc_private.email_perlu_pdf('daily') then
    raise exception 'GAGAL: daily kehilangan lampirannya.'; end if;
  if not rc_private.email_perlu_pdf('timetable') then
    raise exception 'GAGAL: timetable kehilangan lampirannya.'; end if;

  raise notice 'Pemeriksaan lolos: pengajuan dan weekly tanpa PDF, daily dan timetable tetap dengan PDF.';
end
$periksa$;
