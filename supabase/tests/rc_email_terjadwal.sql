-- ==========================================================================================
-- Uji email terjadwal tanpa user login (migrasi 20261163220000)
-- ==========================================================================================
-- Hanya rc_email_susun yang dipanggil - BUKAN rc_email_tick / rc_email_jalankan_antrean, yang
-- dapat benar-benar mengirim. Baris antrean yang tersusun ikut dibatalkan (UJI_SELESAI) dan
-- pengirim tiap menit tidak dapat melihat baris yang belum di-commit. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_terjadwal.sql
-- ==========================================================================================
create temp table if not exists _hasil_et(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_et;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_sm uuid; v_tanpa uuid; v_galat text; o record; u record;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- User aktif yang memang tidak punya akses tab Email Otomatis.
  for u in select p.id from public.profiles p
            where p.status = 'active' and not p.must_change_password and p.role <> 'system manager'
            order by p.user_code limit 100 loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    if not rc_private.can_tab('access.email') then v_tanpa := u.id; exit; end if;
  end loop;

  begin
    -- Seperti penjadwal: tanpa JWT sama sekali.
    perform set_config('request.jwt.claims', '', true);
    r := public.rc_email_susun('daily', true);
    select * into o from public.email_outbox where id = nullif(r->>'id', '')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Tanpa user login (penjadwal): Daily tersusun, tidak ditolak akses tab',
      'lulus', r->>'status' = 'success' and o.id is not null and o.jenis = 'daily' and o.status in ('pending', 'skipped'),
      'rinci', coalesce(o.status, '-') || ' | ' || coalesce(r->>'message', ''));
    r := public.rc_email_susun('weekly', false);
    hasil := hasil || jsonb_build_object('uji', 'Tanpa user login: Weekly (pratinjau) tersusun',
      'lulus', r->>'status' = 'success', 'rinci', coalesce(r->>'message', ''));

    -- User yang login tanpa akses Email Otomatis tetap ditolak.
    perform set_config('request.jwt.claims', json_build_object('sub', v_tanpa::text, 'role', 'authenticated')::text, true);
    begin
      r := public.rc_email_susun('daily', false);
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'User login tanpa akses Email Otomatis tetap ditolak',
      'lulus', v_tanpa is not null and v_galat ~ 'access.email|akses Email Otomatis', 'rinci', v_galat);

    -- System Manager (punya akses) tetap dapat menyusun.
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_email_susun('daily', false);
    hasil := hasil || jsonb_build_object('uji', 'System Manager tetap dapat menyusun pratinjau',
      'lulus', r->>'status' = 'success', 'rinci', coalesce(r->>'message', ''));

    hasil := hasil || jsonb_build_object('uji', 'anon tidak dapat menjalankan rc_email_susun',
      'lulus', not has_function_privilege('anon', 'public.rc_email_susun(text,boolean,text)', 'execute'), 'rinci', '');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  insert into _hasil_et(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_et order by urut;
