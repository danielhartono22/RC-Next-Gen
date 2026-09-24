-- ==========================================================================================
-- Abbr depot 1A Jakarta (TU) menjadi JKT, dan penjagaan supaya abbr tak terpakai tidak lolos
-- ==========================================================================================
-- Kolom Abbr pada ListCampaign.csv memberi depot 1A nilai "JKT/TU". Garis miring itu bermasalah
-- di dua tempat sekaligus:
--
--  1. rc_private.next_document menolak abbr yang bukan 2-10 huruf atau angka, sehingga depot
--     itu akan gagal menerbitkan No Doc dengan pesan "Abbr depot tidak valid".
--  2. Andai lolos pun, hasilnya NPC/CMP/JKT/TU/CA3222/25029 - enam ruas, bukan lima - sehingga
--     tidak lagi cocok dengan format yang ditetapkan pemilik.
--
-- Pemilik memutuskan singkatannya menjadi JKT.
--
-- Perubahan ini tidak menyentuh dokumen mana pun yang sudah terbit. Diperiksa lebih dulu di
-- project yang berjalan: JKT belum dipakai depot lain, rc_private.document_counters belum
-- memuat baris untuk JKT maupun JKT/TU, tidak ada satu pun no_doc yang memakai JKT, dan depot
-- 1A belum memiliki satu pun claim.
--
-- Bagian kedua berkas ini mencegah kejadian yang sama terulang. Sampai sekarang sebuah abbr
-- yang tidak terpakai baru ketahuan saat seseorang menekan tombol compile dan gagal. Dengan
-- CHECK di bawah, nilai seperti itu ditolak pada saat dimasukkan, di tempat kesalahannya
-- benar-benar terjadi. Syaratnya dibuat sama persis dengan yang dipakai next_document.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

update public.depots set abbr='JKT' where depot_code='1A' and abbr='JKT/TU';

-- Dipasang sesudah perbaikan di atas, supaya tidak ada baris lama yang membuatnya gagal.
alter table public.depots drop constraint if exists depots_abbr_terpakai;
alter table public.depots add constraint depots_abbr_terpakai
  check (abbr is null or abbr ~ '^[A-Z0-9]{2,10}$');

create or replace function rc_private.marker_20261001() returns boolean
language sql immutable set search_path='' as $$select true$$;
revoke all on function rc_private.marker_20261001() from public,anon;
grant execute on function rc_private.marker_20261001() to authenticated;

select 'Abbr Jakarta (TU) menjadi JKT' as hasil,
 (select abbr from public.depots where depot_code='1A') as abbr_1A,
 (select count(*) from public.depots where abbr is not null) as depot_ber_abbr,
 (select count(*) from public.depots
   where abbr is not null and abbr !~ '^[A-Z0-9]{2,10}$') as abbr_masih_tak_terpakai,
 (select count(*) from public.claims where no_doc like 'NPC/%/JKT/TU/%') as no_doc_terdampak;
