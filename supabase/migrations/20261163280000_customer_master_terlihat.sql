-- ==========================================================================================
-- Customer Master terlihat sama bagi user yang berhak: System Manager melihat semua, dan toko
-- otomatis tertaut ke depot tempat ia punya klaim
-- ==========================================================================================
-- Pemilik, 21 Oktober 2026: "data yang ada di master data, customer master tidak sinkron antara
-- 1 user dengan user lainnya. contoh di a ada tapi di b tidak ada". Temuan di prod:
--
--  A. RLS customers / customer_depots memakai rc_private.depot_cd_saya(), yang hanya membaca
--     user_depot_access - tanpa pengecualian System Manager. Baris akses System Manager hanya
--     cermin (20260924010000) dan tertinggal ketika depot baru dibuat: DANIEL kurang 6 depot
--     (4B, 5S, 5T, 5X, 5Y, 5Z) sehingga 734 customer terlihat oleh RIKA / YANTO tetapi tidak
--     olehnya. Kini System Manager selalu seluruh depot (aturan visibilitas 20 September 2026),
--     dan cermin aksesnya dibangun ulang.
--  B. 727 pasangan toko-depot punya klaim (717 customer, 1.510 klaim; terbanyak 5K) tetapi toko
--     itu belum tertaut ke depot tersebut di Customer Master, sehingga user depot itu tidak
--     melihatnya. Pasangan itu ditautkan sekali jalan, dan seterusnya klaim yang dibuat / diubah
--     menautkan tokonya ke depot klaim secara otomatis (trigger per pernyataan).
--
-- Depot rumah TIDAK ditambahkan ke yurisdiksi: "depot rumah adalah keterangan identitas, bukan
-- pemberian wewenang" (pemilik, 20 September 2026).
--
-- Penjaga MD5 pra-citra rc_private.depot_cd_saya: 6a960456 (sama di dev dan prod).
-- ==========================================================================================

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.depot_cd_saya()'::regprocedure), E'\r', '');
  if src ~ '20261163280000' then raise notice 'depot_cd_saya sudah ditambal.'; return; end if;
  if md5(src) <> '6a9604567f23cb5fe54f1808d5393c0a' then
    raise exception 'DITOLAK: depot_cd_saya berbeda dari yang diukur (md5 %).', md5(src); end if;
  execute $f$
create or replace function rc_private.depot_cd_saya()
returns uuid[] language sql stable security definer set search_path = '' as $b$
  -- 20261163280000: System Manager selalu seluruh depot, bukan cermin user_depot_access yang
  -- dapat tertinggal ketika depot baru dibuat.
  select case
    when exists(select 1 from public.profiles p
                 where p.id = (select auth.uid()) and p.role = 'system manager'
                   and p.status = 'active' and not p.must_change_password)
      then coalesce((select array_agg(d.id) from public.depots d), '{}'::uuid[])
    else coalesce((
      select array_agg(a.depot_id)
        from public.user_depot_access a
        join public.profiles p on p.id = a.user_id
       where a.user_id = (select auth.uid())
         and not p.must_change_password), '{}'::uuid[])
  end;
$b$$f$;
end $tambal$;

-- Cermin akses System Manager disamakan lagi (konsol Otorisasi menampilkan keadaan sebenarnya).
do $cermin$
declare u uuid;
begin
  for u in select id from public.profiles where role = 'system manager' and status = 'active' loop
    perform rc_private.rebuild_depot_access(u);
  end loop;
end $cermin$;

-- ---- B. Toko tertaut ke depot tempat ia punya klaim -------------------------------------------
create or replace function rc_private.tautkan_customer_depot_klaim()
returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  insert into public.customer_depots(customer_id, depot_id)
  select distinct b.customer_id, b.depot_id
    from baru b
   where b.customer_id is not null and b.depot_id is not null and b.archived_at is null
     and not exists(select 1 from public.customer_depots cd
                     where cd.customer_id = b.customer_id and cd.depot_id = b.depot_id)
  on conflict do nothing;
  return null;
end $f$;
revoke all on function rc_private.tautkan_customer_depot_klaim() from public, anon, authenticated;

drop trigger if exists tautkan_customer_depot_tambah on public.claims;
create trigger tautkan_customer_depot_tambah after insert on public.claims
  referencing new table as baru for each statement execute function rc_private.tautkan_customer_depot_klaim();
drop trigger if exists tautkan_customer_depot_ubah on public.claims;
create trigger tautkan_customer_depot_ubah after update on public.claims
  referencing new table as baru for each statement execute function rc_private.tautkan_customer_depot_klaim();

-- Sekali jalan: pasangan toko-depot yang sudah punya klaim aktif.
do $isi$
declare n integer;
begin
  insert into public.customer_depots(customer_id, depot_id)
  select distinct c.customer_id, c.depot_id
    from public.claims c
   where c.archived_at is null and c.customer_id is not null and c.depot_id is not null
     and not exists(select 1 from public.customer_depots cd where cd.customer_id = c.customer_id and cd.depot_id = c.depot_id)
  on conflict do nothing;
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.activity_logs(event_type, details)
    values ('customer_depot_tertaut_otomatis', jsonb_build_object('pasangan', n, 'sumber', '20261163280000: klaim yang sudah ada'));
  end if;
  raise notice 'Pasangan toko-depot ditautkan: %', n;
end $isi$;

do $cek$
begin
  if pg_get_functiondef('rc_private.depot_cd_saya()'::regprocedure) !~ '20261163280000' then
    raise exception 'GAGAL: depot_cd_saya belum ditambal'; end if;
  if exists(select 1 from public.claims c where c.archived_at is null and c.customer_id is not null and c.depot_id is not null
             and not exists(select 1 from public.customer_depots cd where cd.customer_id = c.customer_id and cd.depot_id = c.depot_id)) then
    raise exception 'GAGAL: masih ada pasangan toko-depot yang belum tertaut'; end if;
end $cek$;
