-- ==========================================================================================
-- Alamat CC tidak boleh menduplikasi TO
-- ==========================================================================================
-- Aturan pemilik: "jika cc dan to tidak boleh duplikat, jika sudah ada di to dan ada di cc,
-- hapus cc nya". Jadi yang diminta bukan penolakan saat menyimpan, melainkan pembersihan:
-- alamat yang sudah menjadi penerima TO cukup dibuang dari CC.
--
-- MENGAPA TRIGGER, BUKAN PEMERIKSAAN DI FUNGSI PENYIMPAN
-- Kolom email_to dan email_cc ditulis lewat beberapa jalan: rc_depot_save (langsung maupun
-- hasil persetujuan), rc_depot_upsert untuk unggahan massal, dan perbaikan manual sesekali.
-- Memasang pembersihannya di masing-masing berarti satu aturan dipelihara di banyak tempat,
-- dan jalan berikutnya yang ditambahkan akan melewatinya tanpa ada yang menyadari.
--
-- Penting: perbandingannya dilakukan atas BARIS AKHIR, bukan atas nilai yang dikirim. Sebuah
-- penyimpanan dapat mengubah CC saja tanpa menyentuh TO; membandingkannya dengan TO yang
-- dikirim - yang dalam hal itu tidak ada - akan melewatkan bentrokan yang sesungguhnya.
--
-- Perbandingan mengabaikan besar-kecil huruf dan spasi berlebih, karena "Budi@np.co.id" dan
-- "budi@np.co.id " adalah kotak surat yang sama dan mengirim dua kali ke orang yang sama
-- adalah persis yang dihindari aturan ini.
--
-- Keadaan saat berkas ini dibuat: 52 depot, 51 di antaranya punya CC, dan TIDAK ADA satu pun
-- alamat CC yang bentrok dengan TO. Jadi pemasangan ini tidak mengubah data mana pun hari ini;
-- ia menjaga agar keadaan itu bertahan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.rapikan_cc() returns trigger
language plpgsql security definer set search_path='' as $fn$
declare tos text[]; ccs text[];
begin
  tos := rc_private.pecah_email(new.email_to);
  ccs := rc_private.pecah_email(new.email_cc);
  if coalesce(array_length(ccs,1),0) = 0 then return new; end if;

  -- pecah_email() sudah menurunkan huruf, memangkas spasi, membuang yang bukan alamat, dan
  -- menghilangkan kembar di dalam satu kolom. Yang tersisa di sini hanya membuang yang juga
  -- ada di TO, lalu menyusunnya kembali sebagai teks dipisah koma seperti bentuk simpanannya.
  select array_agg(c order by c) into ccs
    from unnest(ccs) c where c <> all(coalesce(tos,'{}'::text[]));

  new.email_cc := coalesce(array_to_string(ccs, ', '), '');
  return new;
end $fn$;
revoke all on function rc_private.rapikan_cc() from public,anon;

drop trigger if exists rapikan_cc on public.depots;
create trigger rapikan_cc before insert or update of email_to, email_cc on public.depots
  for each row execute function rc_private.rapikan_cc();

-- Membersihkan yang sudah tersimpan. Pembaruan ini menyentuh email_cc, sehingga trigger di
-- atas ikut berjalan dan merapikan seluruh baris sekaligus.
update public.depots set email_cc = email_cc
 where coalesce(btrim(email_cc),'') <> '';

create or replace function rc_private.marker_20261102() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261102() from public,anon;
grant execute on function rc_private.marker_20261102() to authenticated;

select 'CC tanpa duplikat TO terpasang' as hasil,
 (select count(*) from public.depots where coalesce(btrim(email_cc),'') <> '') as depot_punya_cc,
 (select count(*) from public.depots d
   where exists(select 1 from unnest(rc_private.pecah_email(d.email_cc)) c
                 where c = any(rc_private.pecah_email(d.email_to)))) as masih_bentrok;
