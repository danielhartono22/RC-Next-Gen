-- ==========================================================================================
-- Ad-Hoc Process terbuka bawaan untuk OSC dan Supervisor
-- ==========================================================================================
-- Pemilik, 22 Oktober 2026: "transport default user osc buka semua dan supervisor".
-- Seluruh akun berperan OSC dan Supervisor - yang ada sekarang maupun yang dibuat kelak -
-- mendapat tab Ad-Hoc Process tanpa perlu dicentang, dalam jangkauan depot masing-masing. Polanya
-- sama dengan Access Management bagi Supervisor: modulnya melekat pada peran, tabnya tetap dapat
-- dimatikan per akun di Access Management (user_tab_access).
--
-- Karena akses mengikuti tab (20261162130000), rc_adhoc_proses dan rc_adhoc_tolak kini dijaga tab
-- adhoc.list dan yurisdiksi depot, bukan baris izin adhoc_process - pemegang izin tetap mendapat
-- tabnya seperti biasa. Bergantung pada 20261163440000.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; f text;
begin
  f := 'rc_private.tab_rights(uuid)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163450000' then
    src := pg_temp.ganti(src, $p$or (t.module='access' and p.role='supervisor')$p$,
      $p$or (t.module='access' and p.role='supervisor') or (t.module='adhoc' and p.role in ('osc','supervisor')) /* 20261163450000: Ad-Hoc bawaan OSC dan Supervisor */$p$,
      1, f || ' bawaan peran');
    execute src;
  end if;

  foreach f in array array['public.rc_adhoc_proses(jsonb,uuid)', 'public.rc_adhoc_tolak(jsonb,uuid,text)'] loop
    src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
    if src !~ '20261163450000' then
      src := pg_temp.ganti(src, $p$if not rc_private.can_access(null, 'adhoc_process') then raise exception 'Access denied' using errcode = '42501'; end if;$p$,
        $p$-- 20261163450000: akses mengikuti tab adhoc.list (bawaan OSC dan Supervisor); yurisdiksi lewat can_access.
  if not rc_private.can_access(null) then raise exception 'Access denied' using errcode = '42501'; end if;$p$, 1, f || ' gerbang');
      src := pg_temp.ganti(src, $p$rc_private.can_access(c.depot_id, 'adhoc_process')$p$, $p$rc_private.can_access(c.depot_id)$p$, 1, f || ' yurisdiksi');
      execute src;
    end if;
  end loop;
end $tambal$;
