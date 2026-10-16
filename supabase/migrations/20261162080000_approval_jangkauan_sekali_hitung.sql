-- ==========================================================================================
-- Management of Approval: izin depot dihitung sekali, bukan per baris
-- ==========================================================================================
-- rc_approval_batches (tab WPT / Overdue) dan rc_approval_hold (tab Hold / Expired) memanggil
-- can_access(depot, 'approve_claim') untuk SETIAP baris dokumen. Di dev, 9.861 dokumen
-- menunggu keputusan: tab WPT 0,8 detik saat cache hangat, 4 detik saat dingin, dan melewati
-- batas 8 detik ketika beberapa modul dibuka berdekatan.
--
-- Diganti padanan yang sama dengan rc_approval_history (20261162060000):
--
--   can_access(d, 'approve_claim')
--     = saya_sm() or (d = any(depot_akses_saya()) and can_access(null, 'approve_claim'))
--
-- Padanannya DIBUKTIKAN ulang di sini untuk setiap pengguna x setiap depot, lalu keluaran kedua
-- fungsi sebelum dan sesudah dibandingkan untuk setiap pengguna aktif - termasuk pengguna yang
-- ditolak, yang galatnya harus tetap sama.
--
-- depot_id berasal dari claims.depot_id yang NOT NULL (diperiksa), jadi cabang "depot kosong"
-- dari can_access tidak pernah terjadi.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $syarat$
begin
  if not (select attnotnull from pg_attribute
           where attrelid = 'public.claims'::regclass and attname = 'depot_id') then
    raise exception 'claims.depot_id boleh NULL; padanan can_access tidak berlaku.';
  end if;
end
$syarat$;

do $setara$
declare u record; d record; n int := 0;
begin
  for u in select id, user_code, role, status from public.profiles order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    for d in select id, depot_code from public.depots loop
      if rc_private.can_access(d.id, 'approve_claim')
         is distinct from (rc_private.saya_sm()
                           or (d.id = any(rc_private.depot_akses_saya())
                               and rc_private.can_access(null, 'approve_claim'))) then
        raise exception 'GAGAL padanan approve_claim: % (% / %) depot %.',
          u.user_code, u.role, u.status, d.depot_code; end if;
      n := n + 1;
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'Padanan approve_claim terbukti untuk % pasangan.', n;
end
$setara$;

-- Keluaran SEBELUM, untuk setiap pengguna aktif dan setiap tab. Galat disimpan sebagai
-- teksnya, supaya penolakan pun harus tetap sama persis.
create temp table _approval_sebelum(kunci text primary key, hasil text) on commit drop;

do $sebelum$
declare u record; k text; hasil text;
begin
  if pg_get_functiondef('public.rc_approval_batches(text,text)'::regprocedure) ~ 'v_izin' then
    raise notice 'Fungsi approval sudah ditambal; pembandingan dilewati.'; return; end if;
  for u in select id, user_code from public.profiles where status = 'active' order by user_code loop
    perform set_config('request.jwt.claims',
      json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    foreach k in array array['wpt', 'ovd', 'hold'] loop
      begin
        set local role authenticated;
        if k = 'hold' then hasil := public.rc_approval_hold(null, null)::text;
        else hasil := public.rc_approval_batches(k, null)::text; end if;
        reset role;
      exception when others then
        reset role;
        hasil := 'GALAT ' || sqlstate || ': ' || sqlerrm;
      end;
      insert into _approval_sebelum values (u.user_code || '|' || k, hasil);
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', true);
end
$sebelum$;

do $tambal$
declare src text; baru text; n int;
  lama_filter text; baru_filter text;
  isi text := '
  -- Padanan can_access(depot,''approve_claim''), dihitung sekali (lihat 20261162080000).
  v_sm    := rc_private.saya_sm();
  v_akses := rc_private.depot_akses_saya();
  v_izin  := rc_private.can_access(null,''approve_claim'');';
begin
  -- rc_approval_batches -------------------------------------------------------------------
  select pg_get_functiondef('public.rc_approval_batches(text,text)'::regprocedure) into src;
  if src !~ 'v_izin' then
    lama_filter := 'where rc_private.can_access(r.depot_id,''approve_claim'')';
    n := (length(src) - length(replace(src, lama_filter, ''))) / length(lama_filter);
    if n <> 1 then raise exception 'rc_approval_batches: penyaring ditemukan % kali, diharapkan 1.', n; end if;
    baru := replace(src, lama_filter, 'where (v_sm or (r.depot_id = any(v_akses) and v_izin))');

    if position('declare v_ovd boolean; v_depot text; hasil jsonb;' in baru) = 0 then
      raise exception 'rc_approval_batches: deklarasi tidak dikenali.'; end if;
    baru := replace(baru, 'declare v_ovd boolean; v_depot text; hasil jsonb;',
      'declare v_ovd boolean; v_depot text; hasil jsonb; v_sm boolean; v_akses uuid[]; v_izin boolean;');

    lama_filter := 'raise exception ''Tidak punya hak menyetujui dokumen'' using errcode=''42501''; end if;';
    n := (length(baru) - length(replace(baru, lama_filter, ''))) / length(lama_filter);
    if n <> 1 then raise exception 'rc_approval_batches: pemeriksaan hak ditemukan % kali, diharapkan 1.', n; end if;
    baru := replace(baru, lama_filter, lama_filter || isi);
    execute baru;
    raise notice 'rc_approval_batches ditambal.';
  end if;

  -- rc_approval_hold ----------------------------------------------------------------------
  select pg_get_functiondef('public.rc_approval_hold(text,text)'::regprocedure) into src;
  if src !~ 'v_izin' then
    lama_filter := 'and rc_private.can_access(c.depot_id,''approve_claim'')';
    n := (length(src) - length(replace(src, lama_filter, ''))) / length(lama_filter);
    if n <> 1 then raise exception 'rc_approval_hold: penyaring ditemukan % kali, diharapkan 1.', n; end if;
    baru := replace(src, lama_filter, 'and (v_sm or (c.depot_id = any(v_akses) and v_izin))');

    if position('declare hasil jsonb; v_depot text; v_cari text;' in baru) = 0 then
      raise exception 'rc_approval_hold: deklarasi tidak dikenali.'; end if;
    baru := replace(baru, 'declare hasil jsonb; v_depot text; v_cari text;',
      'declare hasil jsonb; v_depot text; v_cari text; v_sm boolean; v_akses uuid[]; v_izin boolean;');

    lama_filter := 'raise exception ''Tidak punya hak melihat antrean ini'' using errcode=''42501''; end if;';
    n := (length(baru) - length(replace(baru, lama_filter, ''))) / length(lama_filter);
    if n <> 1 then raise exception 'rc_approval_hold: pemeriksaan hak ditemukan % kali, diharapkan 1.', n; end if;
    baru := replace(baru, lama_filter, lama_filter || isi);
    execute baru;
    raise notice 'rc_approval_hold ditambal.';
  end if;
end
$tambal$;

do $sesudah$
declare r record; u_id uuid; bagian text[]; hasil text; n int := 0;
begin
  for r in select * from _approval_sebelum order by kunci loop
    bagian := string_to_array(r.kunci, '|');
    select id into u_id from public.profiles where user_code = bagian[1];
    perform set_config('request.jwt.claims',
      json_build_object('sub', u_id::text, 'role', 'authenticated')::text, true);
    begin
      set local role authenticated;
      if bagian[2] = 'hold' then hasil := public.rc_approval_hold(null, null)::text;
      else hasil := public.rc_approval_batches(bagian[2], null)::text; end if;
      reset role;
    exception when others then
      reset role;
      hasil := 'GALAT ' || sqlstate || ': ' || sqlerrm;
    end;
    if hasil is distinct from r.hasil then
      raise exception 'GAGAL approval %: keluaran berubah.', r.kunci; end if;
    n := n + 1;
  end loop;
  perform set_config('request.jwt.claims', '', true);
  raise notice 'Keluaran approval identik pada % kombinasi.', n;
end
$sesudah$;
