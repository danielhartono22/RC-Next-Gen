-- ==========================================================================================
-- Upload Debtor: batas waktu diperpanjang, tanpa penjagaan yurisdiksi
-- ==========================================================================================
-- Pemilik, 9 November 2026: "untuk upload debtor selalu timeout, coba perpanjang time limit ... dan
-- upload debtor tanpa penjagaan yuridiksi apapun, so ketika dikasih akses upload debtor semua bisa
-- upload."
-- * Peran authenticated dibatasi 8 detik per kueri; pratinjau file nasional (±17.000 baris) sudah
--   7,6-7,9 detik di prod saat sepi. rc_zdage_stage / preview / apply kini 90 detik (di bawah batas
--   gateway 100 detik). PostgREST menerapkan statement_timeout milik fungsi sebelum memanggilnya.
--   Apply menunggu kunci baris klaim sampai 30 detik (bawaan 8 detik).
-- * Yang menjaga kini hanya tab compilation.debtor (rc_private.require_tab): seluruh depot di file
--   dinilai dan diterapkan, siapa pun pengunggahnya. rc_clearing_dikembalikan, rc_clearing_reoffer,
--   dan riwayat depot ikut, karena bagian tab yang sama. Upload hanya dapat diteruskan pengunggahnya
--   atau System Manager (kepemilikan, bukan yurisdiksi).
-- Butuh 20261163170000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; v_kepala text := E' SET search_path TO \'\'\nAS $function$';
begin
  -- ---- Penilaian ---------------------------------------------------------------------------------
  src := replace(pg_get_functiondef('rc_private.zdage_evaluasi(uuid,text[],numeric,text)'::regprocedure), E'\r', '');
  if src ~ 'can_access' then
    src := pg_temp.ganti(src, $p$     where d.archived_at is null and rc_private.can_access(d.id, 'view_compilation')$p$,
      $p$     where d.archived_at is null /* 20261163780000: seluruh depot */$p$, 1, 'evaluasi');
    execute src;
  end if;
  src := replace(pg_get_functiondef('rc_private.zdage_galat(uuid)'::regprocedure), E'\r', '');
  if src ~ 'can_access' then
    src := pg_temp.ganti(src, $p$ and dd.upload_id <> u.id
     and rc_private.can_access(d.id, 'view_compilation');$p$, $p$ and dd.upload_id <> u.id;$p$, 1, 'galat');
    execute src;
  end if;

  -- ---- Kirim baris -------------------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_zdage_stage(text,timestamp with time zone,jsonb,uuid)'::regprocedure), E'\r', '');
  if src !~ 'statement_timeout' then
    src := pg_temp.ganti(src, v_kepala, E' SET search_path TO \'\'\n SET statement_timeout TO \'90s\'\nAS $function$', 1, 'stage kepala');
    execute src;
  end if;

  -- ---- Pratinjau ---------------------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_zdage_preview(uuid,text[])'::regprocedure), E'\r', '');
  if src !~ 'statement_timeout' then
    src := pg_temp.ganti(src, v_kepala, E' SET search_path TO \'\'\n SET statement_timeout TO \'90s\'\nAS $function$', 1, 'preview kepala');
    src := pg_temp.ganti(src, $p$           where r.upload_id = u.id and rc_private.can_access(d.id, 'view_compilation')
$p$, $p$           where r.upload_id = u.id
$p$, 1, 'preview depot file');
    src := pg_temp.ganti(src, $p$  -- Depot di file tetapi di luar jangkauan pengunggah, dan kode kolom A yang bukan depot.
  select coalesce(jsonb_agg(distinct d.depot_code), '[]'::jsonb) into v_luar
    from public.rc_zdage_rows r join public.depots d on d.id = r.depot_id
   where r.upload_id = u.id and not rc_private.can_access(d.id, 'view_compilation');
$p$, $p$  -- 20261163780000: tanpa yurisdiksi, tidak ada depot di luar jangkauan. Kode kolom A yang bukan depot.
  v_luar := '[]'::jsonb;
$p$, 1, 'preview luar');
    src := pg_temp.ganti(src, $p$   where d.archived_at is null and rc_private.can_access(d.id, 'view_compilation')
     and not exists$p$, $p$   where d.archived_at is null
     and not exists$p$, 1, 'preview tidak ada');
    execute src;
  end if;

  -- ---- Terapkan ----------------------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_zdage_apply(uuid,text[])'::regprocedure), E'\r', '');
  if src !~ 'statement_timeout' then
    src := pg_temp.ganti(src, v_kepala, E' SET search_path TO \'\'\n SET statement_timeout TO \'90s\'\n SET lock_timeout TO \'30s\'\nAS $function$', 1, 'apply kepala');
    src := pg_temp.ganti(src, $p$  -- "Tidak ada tagihan" hanya untuk depot dalam jangkauan yang memang tidak ada di file.$p$,
      $p$  -- "Tidak ada tagihan" hanya untuk depot yang memang tidak ada di file.$p$, 1, 'apply komentar');
    src := pg_temp.ganti(src, $p$ and d.archived_at is null
                     and rc_private.can_access(d.id, 'view_compilation')
                     and not exists$p$, $p$ and d.archived_at is null
                     and not exists$p$, 1, 'apply kosong');
    src := pg_temp.ganti(src, $p$ and r.depot_id is not null and rc_private.can_access(r.depot_id, 'view_compilation')$p$,
      $p$ and r.depot_id is not null$p$, 1, 'apply depot data');
    execute src;
  end if;

  -- ---- Riwayat, Dikembalikan, Tawar Ulang --------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_zdage_riwayat()'::regprocedure), E'\r', '');
  if src ~ 'can_access' then
    src := pg_temp.ganti(src, $p$ join public.depots d on d.id = dd.depot_id
     where rc_private.can_access(d.id, 'view_compilation')), '[]'::jsonb));$p$,
      $p$ join public.depots d on d.id = dd.depot_id), '[]'::jsonb));$p$, 1, 'riwayat');
    execute src;
  end if;
  src := replace(pg_get_functiondef('public.rc_clearing_dikembalikan()'::regprocedure), E'\r', '');
  if src ~ 'can_access' then
    src := pg_temp.ganti(src, $p$ and c.archived_at is null
     and rc_private.can_access(c.depot_id, 'view_compilation')), '[]'::jsonb));$p$,
      $p$ and c.archived_at is null), '[]'::jsonb));$p$, 1, 'dikembalikan');
    execute src;
  end if;
  src := replace(pg_get_functiondef('public.rc_clearing_reoffer(text[])'::regprocedure), E'\r', '');
  if src ~ 'can_access' then
    src := pg_temp.ganti(src, $p$ and rc_private.can_access(c.depot_id, 'view_compilation')
$p$, E'\n', 1, 'reoffer');
    execute src;
  end if;
end $tambal$;

notify pgrst, 'reload schema';

do $cek$
declare f text;
begin
  foreach f in array array['rc_private.zdage_evaluasi(uuid,text[],numeric,text)', 'rc_private.zdage_galat(uuid)', 'public.rc_zdage_stage(text,timestamp with time zone,jsonb,uuid)',
    'public.rc_zdage_preview(uuid,text[])', 'public.rc_zdage_apply(uuid,text[])', 'public.rc_zdage_riwayat()', 'public.rc_clearing_dikembalikan()', 'public.rc_clearing_reoffer(text[])'] loop
    if pg_get_functiondef(f::regprocedure) ~ 'can_access' then raise exception 'GAGAL: % masih memakai can_access', f; end if;
  end loop;
  foreach f in array array['public.rc_zdage_stage(text,timestamp with time zone,jsonb,uuid)', 'public.rc_zdage_preview(uuid,text[])', 'public.rc_zdage_apply(uuid,text[])'] loop
    if pg_get_functiondef(f::regprocedure) !~ 'statement_timeout' then raise exception 'GAGAL: % tanpa batas waktu', f; end if;
  end loop;
end $cek$;
