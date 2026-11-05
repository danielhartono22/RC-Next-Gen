-- ==========================================================================================
-- Head Office bukan depot: tidak ikut laporan apa pun maupun Timetable
-- ==========================================================================================
-- Pemilik, 21 Oktober 2026: "Head Offie bukan depo sehingga tidak masuk sebagai report apapun dan
-- timetable."
--
-- HO tercatat di Depot Master (kode HO, tanpa region / Email TO) karena menjadi depot rumah 17
-- user, tetapi tidak punya klaim, customer, maupun tanda Not Participating. Laporan berbasis
-- klaim (Report, Analytics, Cost Center, Daily) memang tidak memuatnya; yang memuatnya adalah
-- daftar yang disusun dari Depot Master:
--  * Timetable: matriks depot x campaign (HO tampil dengan seluruh campaign belum dikerjakan) dan
--    ringkasannya (angka "depot dipantau" / kombinasi di email Timetable dan Weekly);
--  * People Performance: depot OSC dan kombinasi depot x campaign-nya;
--  * Details Campaign: daftar depot / region dan catatan "berlaku di depot" untuk user ber-depot
--    rumah HO;
--  * Laporan Kesehatan: risiko "depot aktif tanpa Abbr / Email TO".
--
-- Kolom baru depots.bukan_depot (bawaan false; HO = true) dan daftar-daftar di atas melewatinya.
-- HO tetap ada di Depot Master, Kelola Akses, dan sebagai depot rumah user.
--
-- Penjaga MD5 pra-citra (sama di dev dan prod, 21 Oktober 2026): rc_timetable_matrix 05f7ec37,
-- timetable_ringkas cbf7d618, people_depots 83d604f2, people_metrics 7cc88a0a,
-- rc_timetable_campaigns 7dc4147d, email_kesehatan_isi 3edd7d07.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.depots add column if not exists bukan_depot boolean not null default false;
comment on column public.depots.bukan_depot is
  'true = kantor (mis. Head Office), bukan depot: tidak ikut Timetable, People Performance, Details Campaign, Laporan Kesehatan (20261163300000).';
update public.depots set bukan_depot = true where depot_code = 'HO' and not bukan_depot;

do $tambal$
declare src text; f record; t text := ' and not d.bukan_depot /* 20261163300000 */';
begin
  for f in select * from (values
    ('public.rc_timetable_matrix(jsonb)', '05f7ec37'),
    ('rc_private.timetable_ringkas(integer)', 'cbf7d618'),
    ('rc_private.people_depots(uuid)', '83d604f2'),
    ('rc_private.people_metrics(uuid[],date)', '7cc88a0a'),
    ('public.rc_timetable_campaigns()', '7dc4147d'),
    ('rc_private.email_kesehatan_isi(timestamp with time zone)', '3edd7d07')) x(sig, harapan)
  loop
    src := replace(pg_get_functiondef(f.sig::regprocedure), E'\r', '');
    if src ~ '20261163300000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if left(md5(src), 8) <> f.harapan then raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', f.sig, md5(src); end if;

    if f.sig like 'public.rc_timetable_matrix%' then
      src := pg_temp.ganti(src, $p$        from public.depots d
       where d.archived_at is null and rc_private.can_access(d.id)$p$,
        $p$        from public.depots d
       where d.archived_at is null and rc_private.can_access(d.id)$p$ || t, 1, 'matrix depot_boleh');
      src := pg_temp.ganti(src, $p$        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
       where d.archived_at is null$p$,
        $p$        left join rekap r on r.depot_id=d.id and r.campaign_id=k.id
       where d.archived_at is null$p$ || t, 1, 'matrix ringkas');
    elsif f.sig like 'rc_private.timetable_ringkas%' then
      src := pg_temp.ganti(src, $p$depot_aktif as (select d.id from public.depots d where d.archived_at is null)$p$,
        $p$depot_aktif as (select d.id from public.depots d where d.archived_at is null$p$ || t || ')', 1, 'ringkas');
    elsif f.sig like 'rc_private.people_depots%' then
      src := pg_temp.ganti(src, $p$where a.user_id=p_user and d.archived_at is null and rc_private.can_access(d.id)$p$,
        $p$where a.user_id=p_user and d.archived_at is null and rc_private.can_access(d.id)$p$ || t, 1, 'people_depots');
    elsif f.sig like 'rc_private.people_metrics%' then
      src := pg_temp.ganti(src, $p$where d.id=any(p_depots) and d.archived_at is null$p$,
        $p$where d.id=any(p_depots) and d.archived_at is null$p$ || t, 1, 'people_metrics');
    elsif f.sig like 'public.rc_timetable_campaigns%' then
      src := pg_temp.ganti(src, $p$where g.user_id = auth.uid() and g.kind = 'rp' and d.archived_at is null and g.depot_id is distinct from v_rumah$p$,
        $p$where g.user_id = auth.uid() and g.kind = 'rp' and d.archived_at is null and g.depot_id is distinct from v_rumah$p$ || t, 1, 'campaigns rp');
      src := pg_temp.ganti(src, $p$coalesce((select d.depot_code from public.depots d where d.id = v_rumah), '')$p$,
        $p$coalesce((select d.depot_code from public.depots d where d.id = v_rumah$p$ || t || $p$), '')$p$, 1, 'campaigns depotSaya');
      src := pg_temp.ganti(src, $p$where d.archived_at is null and btrim(coalesce(d.region, '')) <> '') x)$p$,
        $p$where d.archived_at is null and btrim(coalesce(d.region, '')) <> ''$p$ || t || ') x)', 1, 'campaigns regions');
      src := pg_temp.ganti(src, $p$where d.archived_at is null and (l.semua or d.id = any(l.depot) or d.id = v_rumah or d.id = any(v_rp))$p$,
        $p$where d.archived_at is null and (l.semua or d.id = any(l.depot) or d.id = v_rumah or d.id = any(v_rp))$p$ || t, 2, 'campaigns depots + tidakBerlakuDepot');
    else
      src := pg_temp.ganti(src, $p$from public.depots where archived_at is null and coalesce(btrim(abbr), '') = '' having count(*) > 0$p$,
        $p$from public.depots where archived_at is null and not bukan_depot and coalesce(btrim(abbr), '') = '' having count(*) > 0 /* 20261163300000 */$p$, 1, 'kesehatan abbr');
      src := pg_temp.ganti(src, $p$from public.depots where archived_at is null and coalesce(btrim(email_to), '') = '' having count(*) > 0$p$,
        $p$from public.depots where archived_at is null and not bukan_depot and coalesce(btrim(email_to), '') = '' having count(*) > 0 /* 20261163300000 */$p$, 1, 'kesehatan email');
    end if;
    execute src;
  end loop;
end $tambal$;

do $cek$
declare e text := ''; f text;
begin
  foreach f in array array['public.rc_timetable_matrix(jsonb)', 'rc_private.timetable_ringkas(integer)', 'rc_private.people_depots(uuid)',
                           'rc_private.people_metrics(uuid[],date)', 'public.rc_timetable_campaigns()',
                           'rc_private.email_kesehatan_isi(timestamp with time zone)'] loop
    if pg_get_functiondef(f::regprocedure) !~ '20261163300000' then e := e || ' ' || f || ';'; end if;
  end loop;
  if not exists(select 1 from public.depots where depot_code = 'HO' and bukan_depot) then e := e || ' HO belum ditandai;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
