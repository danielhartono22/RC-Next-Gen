-- ==========================================================================================
-- Uji Portal Link - migrasi 20261163180000
-- ==========================================================================================
-- Seluruh uji berjalan di subtransaksi yang DIBATALKAN (UJI_SELESAI); link, centang tab, dan
-- jangkauan depot akun uji ikut dibatalkan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_portal_link.sql
-- ==========================================================================================
create temp table if not exists _hasil_pl(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_pl;

create or replace function pg_temp.pl_sebagai(p_user uuid) returns void language sql as $f$
  select set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
$f$;

do $uji$
declare v_sm uuid; v_usr uuid; v_non uuid; hasil jsonb := '[]'; r jsonb; v_galat text; v_txt text;
  d1 record; d2 record; v_id_semua uuid; v_id_region uuid; v_id_depot uuid; v_id_lain uuid; v_tabs jsonb; n integer;
  v_log0 integer := (select count(*) from public.activity_logs where module = 'links');
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password
   order by user_code limit 1;
  -- v_usr: Admin Depot (hanya Daftar Link). v_non: akun biasa bukan admin (Editor Link bawaan terbuka).
  -- Jangkauan keduanya diatur ulang di sini.
  select id into v_usr from public.profiles where role = 'admin'
     and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_non from public.profiles where role in ('osc', 'supervisor', 'finance', 'others')
     and status = 'active' and not must_change_password order by user_code limit 1;
  -- Dua depot dari region berbeda.
  select d.id, d.depot_code, upper(btrim(d.region)) region into d1 from public.depots d
   where d.archived_at is null and btrim(coalesce(d.region, '')) <> '' order by d.depot_code limit 1;
  select d.id, d.depot_code, upper(btrim(d.region)) region into d2 from public.depots d
   where d.archived_at is null and btrim(coalesce(d.region, '')) <> '' and upper(btrim(d.region)) <> d1.region order by d.depot_code limit 1;

  begin
    delete from public.user_depot_access where user_id = v_usr;
    insert into public.user_depot_access(user_id, depot_id) values (v_usr, d1.id);
    delete from rc_private.user_tab_access where user_id in (v_usr, v_non) and tab_code like 'links.%';
    delete from public.user_depot_access where user_id = v_non;
    insert into public.user_depot_access(user_id, depot_id) values (v_non, d1.id);

    -- ---- Hak tab ----------------------------------------------------------------------
    perform pg_temp.pl_sebagai(v_usr);
    v_tabs := rc_private.tab_rights(v_usr);
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot: Daftar Link terlihat, Editor Link tidak',
      'lulus', (v_tabs->>'links.view')::boolean and not (v_tabs->>'links.editor')::boolean, 'rinci', v_tabs->>'links.view' || '/' || (v_tabs->>'links.editor'));
    -- Admin tetap tanpa Editor walau dicentang di Access Management.
    insert into rc_private.user_tab_access values (v_usr, 'links.editor', true);
    v_tabs := rc_private.tab_rights(v_usr);
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot dicentang Editor Link: tetap tidak mendapat Editor',
      'lulus', not (v_tabs->>'links.editor')::boolean, 'rinci', v_tabs->>'links.editor');
    begin perform public.rc_link_editor_list(false); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot: Editor list ditolak server', 'lulus', v_galat ~ 'links\.editor', 'rinci', v_galat);
    begin perform public.rc_link_simpan(jsonb_build_object('tab', 'X', 'url', 'https://x.id')); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Admin Depot: Simpan link ditolak server', 'lulus', v_galat ~ 'links\.editor', 'rinci', v_galat);
    delete from rc_private.user_tab_access where user_id = v_usr and tab_code = 'links.editor';
    perform pg_temp.pl_sebagai(v_non);
    v_tabs := rc_private.tab_rights(v_non);
    hasil := hasil || jsonb_build_object('uji', 'Peran lain (bukan admin): Daftar Link dan Editor Link terbuka bawaan',
      'lulus', (v_tabs->>'links.view')::boolean and (v_tabs->>'links.editor')::boolean, 'rinci', v_tabs->>'links.view' || '/' || (v_tabs->>'links.editor'));

    -- ---- Editor (System Manager) ------------------------------------------------------
    perform pg_temp.pl_sebagai(v_sm);
    r := public.rc_link_simpan(jsonb_build_object('tab', 'UJI Portal', 'url', 'https://semua.example.com', 'pinned', false));
    v_id_semua := (r->>'id')::uuid;
    r := public.rc_link_simpan(jsonb_build_object('tab', 'uji portal', 'subTab', 'Region Saja', 'url', 'https://region.example.com',
           'regions', jsonb_build_array(lower(d1.region))));
    v_id_region := (r->>'id')::uuid;
    r := public.rc_link_simpan(jsonb_build_object('tab', 'UJI Lain', 'subTab', 'Depot Saja', 'url', 'https://depot.example.com',
           'depotIds', jsonb_build_array(d1.id), 'pinned', true));
    v_id_depot := (r->>'id')::uuid;
    r := public.rc_link_simpan(jsonb_build_object('tab', 'UJI Lain', 'subTab', 'Region Lain', 'url', 'https://lain.example.com',
           'regions', jsonb_build_array(d2.region), 'depotIds', jsonb_build_array(d2.id)));
    v_id_lain := (r->>'id')::uuid;

    select tab into v_txt from public.rc_portal_links where id = v_id_region;
    hasil := hasil || jsonb_build_object('uji', 'Nama Tab mengikuti penulisan Tab yang sudah ada', 'lulus', v_txt = 'UJI Portal', 'rinci', v_txt);
    select regions[1] into v_txt from public.rc_portal_links where id = v_id_region;
    hasil := hasil || jsonb_build_object('uji', 'Region disimpan huruf besar', 'lulus', v_txt = d1.region, 'rinci', v_txt);
    select count(*) filter (where pinned) into n from public.rc_portal_links where lower(tab) = 'uji lain';
    hasil := hasil || jsonb_build_object('uji', 'Link baru di Tab ter-pin ikut ter-pin (pin per Tab)', 'lulus', n = 2, 'rinci', n);

    -- Validasi
    foreach v_txt in array array['javascript:alert(1)', 'ftp://x.id', 'https://a b.id', ''] loop
      begin perform public.rc_link_simpan(jsonb_build_object('tab', 'UJI', 'url', v_txt)); v_galat := 'lolos';
      exception when others then v_galat := sqlerrm; end;
      hasil := hasil || jsonb_build_object('uji', 'URL ditolak: ' || coalesce(nullif(v_txt, ''), '(kosong)'), 'lulus', v_galat ~ 'http', 'rinci', v_galat);
    end loop;
    begin perform public.rc_link_simpan(jsonb_build_object('tab', '  ', 'url', 'https://x.id')); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tab kosong ditolak', 'lulus', v_galat ~ 'Tab wajib', 'rinci', v_galat);
    begin perform public.rc_link_simpan(jsonb_build_object('tab', 'UJI', 'url', 'https://x.id', 'regions', jsonb_build_array('ZZ-TIDAK-ADA'))); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Region tak dikenal ditolak', 'lulus', v_galat ~ 'Region tidak dikenal', 'rinci', v_galat);
    begin perform public.rc_link_simpan(jsonb_build_object('tab', 'UJI', 'url', 'https://x.id', 'depotIds', jsonb_build_array(gen_random_uuid()))); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Depot tak dikenal ditolak', 'lulus', v_galat ~ 'Depot tidak dikenal', 'rinci', v_galat);

    -- ---- Aturan tampil (akun biasa, jangkauan hanya d1) --------------------------------
    perform pg_temp.pl_sebagai(v_usr);
    r := public.rc_link_list();
    select string_agg(x->>'url', ' ' order by x->>'url') into v_txt from jsonb_array_elements(r->'rows') x where x->>'tab' like 'UJI%';
    hasil := hasil || jsonb_build_object('uji', 'Akun biasa melihat link Semua + Region-nya + Depot-nya, bukan region/depot lain',
      'lulus', v_txt = 'https://depot.example.com https://region.example.com https://semua.example.com', 'rinci', v_txt);
    select string_agg(x->>'tab', '|' order by o) into v_txt from jsonb_array_elements(r->'rows') with ordinality t(x, o) where x->>'tab' like 'UJI%';
    hasil := hasil || jsonb_build_object('uji', 'Tab yang di-pin tampil lebih dulu', 'lulus', v_txt like 'UJI Lain|%', 'rinci', v_txt);

    -- Depot d2 ditambahkan ke jangkauannya: link region/depot lain ikut terlihat.
    insert into public.user_depot_access(user_id, depot_id) values (v_usr, d2.id);
    r := public.rc_link_list();
    hasil := hasil || jsonb_build_object('uji', 'Jangkauan bertambah: link region/depot lain ikut terlihat',
      'lulus', exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'url' = 'https://lain.example.com'), 'rinci', jsonb_array_length(r->'rows'));
    delete from public.user_depot_access where user_id = v_usr and depot_id = d2.id;

    -- Daftar Link dimatikan untuk akun ini.
    insert into rc_private.user_tab_access values (v_usr, 'links.view', false);
    begin perform public.rc_link_list(); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Daftar Link ditolak bila tab-nya dimatikan', 'lulus', v_galat ~ 'links\.view', 'rinci', v_galat);
    delete from rc_private.user_tab_access where user_id = v_usr and tab_code = 'links.view';

    -- ---- Editor bawaan (bukan admin, bukan System Manager) -----------------------------
    perform pg_temp.pl_sebagai(v_non);
    v_tabs := rc_private.tab_rights(v_non);
    r := public.rc_link_editor_list(false);
    hasil := hasil || jsonb_build_object('uji', 'Editor (bukan admin): melihat seluruh link termasuk di luar jangkauannya, dengan ringkasan aturan',
      'lulus', (v_tabs->>'links.editor')::boolean and exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'url' = 'https://lain.example.com'
                 and x->>'aturan' = 'Region ' || d2.region || ' · Depot ' || d2.depot_code)
               and exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'url' = 'https://semua.example.com' and x->>'aturan' = 'Semua akun')
               and jsonb_array_length(r->'regions') > 0 and jsonb_array_length(r->'depots') > 0,
      'rinci', (select x->>'aturan' from jsonb_array_elements(r->'rows') x where x->>'url' = 'https://lain.example.com'));

    r := public.rc_link_simpan(jsonb_build_object('id', v_id_semua, 'tab', 'UJI Portal', 'subTab', '', 'url', 'https://semua2.example.com',
           'keterangan', 'diubah', 'regions', '[]'::jsonb, 'depotIds', '[]'::jsonb));
    select url into v_txt from public.rc_portal_links where id = v_id_semua;
    hasil := hasil || jsonb_build_object('uji', 'Ubah link', 'lulus', v_txt = 'https://semua2.example.com' and r->>'message' ~ 'diperbarui', 'rinci', v_txt);

    r := public.rc_link_pin('uji portal', true);
    select count(*) filter (where pinned) into n from public.rc_portal_links where lower(tab) = 'uji portal';
    hasil := hasil || jsonb_build_object('uji', 'Pin Tab: seluruh baris Tab ikut', 'lulus', n = 2 and (r->>'jumlah')::int = 2, 'rinci', n);
    begin perform public.rc_link_pin('UJI tidak ada', true); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Pin Tab tak dikenal ditolak', 'lulus', v_galat ~ 'tidak ditemukan', 'rinci', v_galat);

    -- Arsip / pulihkan
    begin perform public.rc_link_arsip(array[v_id_lain], true, ''); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Arsip tanpa alasan ditolak', 'lulus', v_galat ~ 'Alasan', 'rinci', v_galat);
    r := public.rc_link_arsip(array[v_id_lain, v_id_depot], true, 'uji arsip');
    hasil := hasil || jsonb_build_object('uji', 'Arsip dua link', 'lulus', (r->>'jumlah')::int = 2, 'rinci', r->>'message');
    r := public.rc_link_list();
    hasil := hasil || jsonb_build_object('uji', 'Link arsip hilang dari Daftar Link',
      'lulus', not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'url' = 'https://depot.example.com'), 'rinci', jsonb_array_length(r->'rows'));
    r := public.rc_link_editor_list(true);
    hasil := hasil || jsonb_build_object('uji', 'Link arsip tampil di daftar Arsip Editor',
      'lulus', (select count(*) from jsonb_array_elements(r->'rows') x where x->>'tab' = 'UJI Lain' and (x->>'arsip')::boolean) = 2, 'rinci', r->>'jumlahArsip');
    begin perform public.rc_link_simpan(jsonb_build_object('id', v_id_depot, 'tab', 'UJI Lain', 'url', 'https://x.id')); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Link arsip tidak dapat diubah', 'lulus', v_galat ~ 'diarsip', 'rinci', v_galat);
    r := public.rc_link_arsip(array[v_id_depot], false, null);
    hasil := hasil || jsonb_build_object('uji', 'Pulihkan link', 'lulus', (r->>'jumlah')::int = 1
      and exists(select 1 from public.rc_portal_links where id = v_id_depot and archived_at is null), 'rinci', r->>'message');

    select count(*) - v_log0 into n from public.activity_logs where module = 'links'
      and event_type in ('link_tambah', 'link_ubah', 'link_pin', 'link_arsip', 'link_pulihkan');
    hasil := hasil || jsonb_build_object('uji', 'Log Activity satu baris per proses (4 tambah + 1 ubah + 1 pin + 1 arsip + 1 pulihkan)', 'lulus', n = 8, 'rinci', n);

    -- Tabel tidak dapat dibaca langsung.
    hasil := hasil || jsonb_build_object('uji', 'Tabel tertutup bagi authenticated (hanya lewat RPC)',
      'lulus', not has_table_privilege('authenticated', 'public.rc_portal_links', 'select')
           and not has_table_privilege('anon', 'public.rc_portal_links', 'select'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  insert into _hasil_pl(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_pl order by urut;
