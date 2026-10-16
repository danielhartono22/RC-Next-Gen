-- ==========================================================================================
-- Exclude Campaign mengikuti tab-nya, seperti seluruh aksi lain sejak 20261162130000
-- ==========================================================================================
-- Diminta pemilik, 6 Oktober 2026: "untuk expired on hold dan fungsi lainnya kenapa user di
-- luar system manager ada yang belum bisa karena izin padahal di akses management udah di
-- buka? check dan synchronized".
--
-- Diperiksa menyeluruh di dev (definisinya identik dengan prod): seorang admin diberi HANYA
-- satu izin modul beserta tab bawaannya, lalu setiap RPC layar modul itu dipanggil - 13 modul
-- jalur baca dan 17 aksi (Posting Exception Expired/On Hold, Approve/Reject, Release, Claim,
-- Clearing, Expired di Claim Process, Bulk Complete/Tolak, Timetable, Grade, Jadwal Email).
-- Semuanya lolos kecuali satu tab: Access Management > Exclude Campaign.
--
-- Tab itu milik modul Access Management (izin manage_access), tetapi ketiga fungsinya diam-diam
-- juga menuntut izin modul LAIN:
--   rc_campaign_exclude        izin Timetable
--   rc_timetable_matrix        izin Timetable atau Report   (daftar campaign di tab itu)
--   rc_timetable_not_achieved  izin Timetable atau Report
-- Pemegang tab Exclude Campaign tanpa modul Timetable/Report melihat tabnya tetapi ditolak
-- "Tidak punya hak ...". Kini cukup tab-nya (can_tab sudah mensyaratkan izin modulnya).
--
-- Ditambal pada definisi yang hidup dengan penjaga MD5 pra-citra (akhir baris dinormalkan),
-- sama di dev dan prod pada 6 Oktober 2026. Aman dijalankan berulang.
-- ==========================================================================================

do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  ('public.rc_campaign_exclude(jsonb,boolean,text)', 'd96d739748dcaf228198f047c751d0aa',
   $p$if not rc_private.can_access(null,'manage_timetable') and not rc_private.is_system_manager() then$p$,
   $p$if not rc_private.can_tab('access.exclude') /* 20261162150000 */ then$p$, 1),
  ('public.rc_timetable_matrix(jsonb)', '29907b1eccae3932d656b9c4b0ccd6c7',
   $p$if not rc_private.can_access(null,'manage_timetable')$p$,
   $p$if not rc_private.can_access(null,'manage_timetable') and not rc_private.can_tab('access.exclude') /* 20261162150000 */$p$, 1),
  ('public.rc_timetable_not_achieved()', 'dcd072296fb413e0a1d99a5b7b25ebdb',
   $p$if not rc_private.can_access(null,'manage_timetable')$p$,
   $p$if not rc_private.can_access(null,'manage_timetable') and not rc_private.can_tab('access.exclude') /* 20261162150000 */$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162150000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := src;
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan di dalam subtransaksi yang dibatalkan: admin yang HANYA diberi modul Access
-- Management (tab bawaan) dapat membuka dan menjalankan Exclude Campaign; tanpa modul itu
-- ditolak.
-- ------------------------------------------------------------------------------------------
do $uji$
declare a uuid; kode text; hasil jsonb := '{}'; e text;
begin
  select p.id into a from public.profiles p
   where p.role = 'admin' and p.status = 'active' and not p.must_change_password
     and exists(select 1 from public.user_depot_access x where x.user_id = p.id)
   order by p.user_code limit 1;
  select campaign_code into kode from public.campaigns order by campaign_code limit 1;
  if a is null or kode is null then raise notice 'Tidak ada admin aktif untuk diuji; dilewati.'; return; end if;

  begin
    delete from public.user_permissions where user_id = a;
    insert into public.user_permissions values (a, 'manage_access');
    delete from rc_private.user_tab_access where user_id = a;
    perform set_config('request.jwt.claims', json_build_object('sub', a::text, 'role', 'authenticated')::text, true);
    begin hasil := hasil || jsonb_build_object('matriks', public.rc_timetable_matrix('{}'::jsonb) ? 'kpi');
    exception when others then hasil := hasil || jsonb_build_object('matriks', sqlerrm); end;
    begin hasil := hasil || jsonb_build_object('notAchieved', public.rc_timetable_not_achieved()->>'status');
    exception when others then hasil := hasil || jsonb_build_object('notAchieved', sqlerrm); end;
    begin hasil := hasil || jsonb_build_object('exclude', public.rc_campaign_exclude(jsonb_build_array(kode), true, 'uji 20261162150000')->>'status');
    exception when others then hasil := hasil || jsonb_build_object('exclude', sqlerrm); end;

    perform set_config('request.jwt.claims', '', true);
    delete from public.user_permissions where user_id = a;
    perform set_config('request.jwt.claims', json_build_object('sub', a::text, 'role', 'authenticated')::text, true);
    begin perform public.rc_campaign_exclude(jsonb_build_array(kode), true, 'uji'); hasil := hasil || '{"tanpaModul":"LOLOS"}';
    exception when others then hasil := hasil || jsonb_build_object('tanpaModul', sqlerrm); end;
    raise exception 'UJI_SELESAI';
  exception when raise_exception then if sqlerrm <> 'UJI_SELESAI' then raise; end if; end;
  perform set_config('request.jwt.claims', '', true);

  e := '';
  if hasil->>'matriks' <> 'true' then e := e || ' daftar campaign: ' || (hasil->>'matriks') || ';'; end if;
  if hasil->>'notAchieved' <> 'success' then e := e || ' not achieved: ' || (hasil->>'notAchieved') || ';'; end if;
  if hasil->>'exclude' <> 'success' then e := e || ' exclude: ' || (hasil->>'exclude') || ';'; end if;
  if hasil->>'tanpaModul' !~ 'tidak diizinkan' then e := e || ' tanpa modul: ' || (hasil->>'tanpaModul') || ';'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
  raise notice 'Exclude Campaign mengikuti tab-nya, teruji: %', hasil;
end
$uji$;
