-- ==========================================================================================
-- Uji CC tambahan per jadwal Email Otomatis - migrasi 20261163370000
-- ==========================================================================================
-- Dibatalkan seluruhnya (UJI_SELESAI). Hanya pratinjau yang disusun; tidak ada email dikirim.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_otomatis_cc.sql
-- ==========================================================================================
create temp table if not exists _hasil_cc(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_cc;

do $uji$
declare hasil jsonb := '[]'; r jsonb; v_galat text; v_sm uuid; v_to text; v_row public.email_outbox;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

    r := public.rc_email_status();
    -- 20261163670000: jenis debtor tidak punya CC umum; CC-nya per jenjang (3 baris).
    hasil := hasil || jsonb_build_object('uji', 'Panel: setiap jadwal punya daftar CC (debtor: CC per jenjang); To sendiri hanya Kesehatan',
      'lulus', (select bool_and(case when p->>'jenis' = 'debtor' then jsonb_array_length(p->'jenjang') = 3 else jsonb_typeof(p->'cc') = 'array' end
                                and (p->>'toTetap')::boolean = (p->>'jenis' = 'kesehatan'))
                  from jsonb_array_elements(r->'pengaturan') p)
           and (select count(*) from jsonb_array_elements(r->'pengaturan') p) >= 5,
      'rinci', (select string_agg((p->>'jenis') || ':' || (p->>'toTetap'), ', ') from jsonb_array_elements(r->'pengaturan') p));

    r := public.rc_email_settings_simpan('[{"jenis":"timetable","cc":"Satu.CC@contoh.co.id, dua.cc@contoh.co.id; satu.cc@contoh.co.id"},{"jenis":"daily","cc":""}]');
    hasil := hasil || jsonb_build_object('uji', 'Simpan CC tambahan Timetable (rapi, tanpa kembar) dan kosongkan CC Daily',
      'lulus', (select cc_tambahan = '{satu.cc@contoh.co.id,dua.cc@contoh.co.id}' from public.email_settings where jenis = 'timetable')
           and (select cc_tambahan = '{}' from public.email_settings where jenis = 'daily'), 'rinci', r->>'message');
    begin perform public.rc_email_settings_simpan('[{"jenis":"weekly","cc":"bukan-email"}]'); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Alamat CC tidak sah ditolak', 'lulus', v_galat ~ 'tidak sah', 'rinci', v_galat);
    begin perform public.rc_email_settings_simpan('[{"jenis":"pengajuan","cc":"a@b.co"}]'); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Baris pengajuan tetap tidak tersentuh dari panel ini',
      'lulus', v_galat = 'lolos' and not (select 'a@b.co' = any(coalesce(cc_tambahan, '{}')) from public.email_settings where jenis = 'pengajuan'), 'rinci', v_galat);

    -- Pratinjau Timetable: CC tambahan ikut; alamat yang sudah di TO tidak diulang.
    select x into v_to from public.depots d, unnest(rc_private.pecah_email(d.email_to)) x
     where d.archived_at is null order by d.depot_code limit 1;
    update public.email_settings set cc_tambahan = array['satu.cc@contoh.co.id', v_to] where jenis = 'timetable';
    r := public.rc_email_susun('timetable', false);
    select * into v_row from public.email_outbox where id = (r->>'id')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Email Timetable: CC = Email CC Depot Master + CC tambahan; alamat TO tidak diulang di CC',
      'lulus', v_row.id is not null and 'satu.cc@contoh.co.id' = any(v_row.cc) and not (v_to = any(v_row.cc)) and v_to = any(v_row.tujuan),
      'rinci', coalesce(array_length(v_row.tujuan, 1), 0) || ' to / ' || coalesce(array_length(v_row.cc, 1), 0) || ' cc');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_cc(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_cc order by urut;
