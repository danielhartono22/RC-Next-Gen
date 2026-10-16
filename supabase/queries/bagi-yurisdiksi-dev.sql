-- ==========================================================================================
-- Membagi yurisdiksi OSC dan Supervisor secara acak tetapi seimbang (DEV SAJA)
-- ==========================================================================================
-- Diminta pemilik, 30 September 2026: "bagikan yuridiksi secara random tapi seimbang untuk
-- osc dan spv".
--
-- Mengikuti model aplikasi sendiri (rc_update_access, rc_private.effective_depots):
--   * yurisdiksi OSC        = depot, disimpan sebagai user_depot_grants jenis 'assigned'
--   * yurisdiksi Supervisor = OSC binaannya (user_supervision); depotnya DIWARISI dari
--                             OSC binaan yang aktif
--   * user_depot_access dibangun ulang dengan rc_private.rebuild_depot_access, persis seperti
--     ketika akses disimpan lewat layar Access Management.
--
-- PEMBAGIAN
--   1. Seluruh depot aktif diacak lalu dibagikan bergiliran kepada OSC aktif yang juga diacak.
--      Setiap depot tepat satu OSC; jumlah depot per OSC berselisih paling banyak satu.
--      (Bila OSC lebih banyak daripada depot, setiap OSC mendapat satu depot dan setiap depot
--      dipegang jumlah OSC yang berselisih paling banyak satu.)
--   2. OSC aktif diacak lagi lalu dibagikan bergiliran kepada Supervisor aktif. Jumlah OSC per
--      Supervisor berselisih paling banyak satu; depot Supervisor ikut seimbang karenanya.
--   3. Yurisdiksi lama OSC dan Supervisor yang ikut dibagi dilepas lebih dulu, termasuk depot
--      yang ditempelkan langsung ke Supervisor - supaya keseimbangannya tidak rusak.
--   Peran lain (System Manager, Depot Head, admin, management, dst.) tidak disentuh.
--
-- ACAK YANG DAPAT DIULANG. Benihnya dicetak di hasil. Untuk mengulang pembagian yang sama:
--   set rc.benih = '0.42';   (angka antara -1 dan 1) sebelum menjalankan berkas ini.
--
-- Jalankan: node scripts/apply-sql.mjs --env dev supabase/queries/bagi-yurisdiksi-dev.sql
-- ==========================================================================================
create temp table _hasil_bagi(kunci text primary key, nilai text) on commit drop;

do $bagi$
declare
  v_benih double precision;
  n_depot int; n_osc int; n_spv int;
begin
  if not exists (select 1 from public.customers where npwp like 'DUMMY-NPWP-%') then
    raise exception 'DITOLAK: bukan database dev. Berkas ini hanya untuk dev.';
  end if;

  v_benih := coalesce(nullif(current_setting('rc.benih', true), '')::double precision,
                      round((random() * 2 - 1)::numeric, 6)::double precision);
  perform setseed(v_benih);

  create temp table _depot on commit drop as
    select id, (row_number() over (order by random()) - 1)::int as i
      from public.depots where archived_at is null;
  create temp table _osc on commit drop as
    select id, user_code, (row_number() over (order by random()) - 1)::int as j
      from public.profiles
     where role = 'osc' and status = 'active' and archived_at is null;
  create temp table _spv on commit drop as
    select id, user_code, (row_number() over (order by random()) - 1)::int as k
      from public.profiles
     where role = 'supervisor' and status = 'active' and archived_at is null;
  -- Urutan OSC kedua, terpisah dari urutan pembagian depot, untuk dibagikan ke Supervisor.
  create temp table _osc2 on commit drop as
    select id, (row_number() over (order by random()) - 1)::int as j2 from _osc;

  select count(*) into n_depot from _depot;
  select count(*) into n_osc from _osc;
  select count(*) into n_spv from _spv;
  if n_osc = 0 then raise exception 'Tidak ada OSC aktif untuk dibagi.'; end if;

  -- Yurisdiksi lama dilepas.
  delete from public.user_depot_grants g
   where g.kind = 'assigned' and (g.user_id in (select id from _osc) or g.user_id in (select id from _spv));
  delete from public.user_supervision s
   where s.osc_id in (select id from _osc) or s.supervisor_id in (select id from _spv);

  -- 1. Depot -> OSC.
  if n_depot >= n_osc then
    insert into public.user_depot_grants(user_id, depot_id, kind)
    select o.id, d.id, 'assigned' from _depot d join _osc o on o.j = d.i % n_osc;
  else
    insert into public.user_depot_grants(user_id, depot_id, kind)
    select o.id, d.id, 'assigned' from _osc o join _depot d on d.i = o.j % n_depot;
  end if;

  -- 2. OSC -> Supervisor.
  if n_spv > 0 then
    insert into public.user_supervision(supervisor_id, osc_id)
    select s.id, o.id from _osc2 o join _spv s on s.k = o.j2 % n_spv;
  end if;

  -- 3. Akses depot dibangun ulang dengan fungsi aplikasi.
  perform rc_private.rebuild_depot_access(x.id)
     from (select id from _osc union select id from _spv) x;

  insert into _hasil_bagi values
    ('benih', v_benih::text),
    ('depot aktif', n_depot::text),
    ('OSC aktif', n_osc::text),
    ('Supervisor aktif', n_spv::text);
end
$bagi$;

insert into _hasil_bagi
select 'depot per OSC (min-maks)', min(n)::text || ' - ' || max(n)::text
  from (select o.id, count(g.depot_id) n from public.profiles o
          left join public.user_depot_grants g on g.user_id = o.id and g.kind = 'assigned'
         where o.role = 'osc' and o.status = 'active' and o.archived_at is null group by o.id) t;
insert into _hasil_bagi
select 'OSC per Supervisor (min-maks)', min(n)::text || ' - ' || max(n)::text
  from (select s.id, count(u.osc_id) n from public.profiles s
          left join public.user_supervision u on u.supervisor_id = s.id
         where s.role = 'supervisor' and s.status = 'active' and s.archived_at is null group by s.id) t;
insert into _hasil_bagi
select 'depot per Supervisor (min-maks)', min(n)::text || ' - ' || max(n)::text
  from (select s.id, count(a.depot_id) n from public.profiles s
          left join public.user_depot_access a on a.user_id = s.id
         where s.role = 'supervisor' and s.status = 'active' and s.archived_at is null group by s.id) t;
insert into _hasil_bagi
select 'depot tanpa OSC', count(*)::text from public.depots d
 where d.archived_at is null
   and not exists (select 1 from public.user_depot_grants g join public.profiles o on o.id = g.user_id
                    where g.depot_id = d.id and g.kind = 'assigned' and o.role = 'osc' and o.status = 'active');

select kunci, nilai from _hasil_bagi order by kunci;
