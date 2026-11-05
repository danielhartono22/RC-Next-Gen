-- ==========================================================================================
-- Uji email Done: TO = Email Kepala Admin; bila kosong user yang mengajukan klaim, lalu user
-- yang memproses Done (apa pun perannya); tanpa alamat ditahan. CC hanya Access Management
-- (migrasi 20261163210000)
-- ==========================================================================================
-- Seluruh uji berjalan di subtransaksi yang DIBATALKAN (UJI_SELESAI): pengaturan email, alamat
-- depot, profil, kolom pengaju / pemroses klaim, dan baris email_outbox ikut dibatalkan.
-- email_outbox tidak punya trigger; surat hanya dikirim cron dari baris yang tersimpan, jadi
-- tidak ada yang terkirim. Alamat uji memakai domain example.invalid. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_done.sql
-- ==========================================================================================
create temp table if not exists _hasil_em(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_em;

do $uji$
declare v_sm uuid; v_osc uuid; v_aju uuid; v_aju2 uuid; v_pro uuid; d record; v_c2 uuid; hasil jsonb := '[]'; p jsonb; n integer; o record; v_log0 integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_osc from public.profiles where lower(role) = 'osc' and status = 'active' order by user_code limit 1;
  -- Pengaju dan pemroses sengaja berperan bukan Admin: perannya tidak menjadi syarat.
  select id into v_aju from public.profiles where lower(role) = 'osc' and status = 'active' and id <> v_osc order by user_code limit 1;
  select id into v_aju2 from public.profiles where lower(role) = 'supervisor' and status = 'active' order by user_code limit 1;
  select id into v_pro from public.profiles where status = 'active' and id not in (v_sm, v_osc, v_aju, v_aju2) and lower(role) <> 'admin' order by user_code limit 1;
  select c.depot_id, c.id into d from public.claims c join public.depots dp on dp.id = c.depot_id where dp.archived_at is null order by c.created_at desc limit 1;
  select c.id into v_c2 from public.claims c where c.depot_id = d.depot_id and c.id <> d.id order by c.created_at desc limit 1;

  begin
    if v_osc is null or v_aju is null or v_aju2 is null or v_pro is null or d.id is null or v_c2 is null then
      raise exception 'Fixture: OSC / Supervisor / user aktif / dua klaim satu depot tidak ada'; end if;
    update public.email_settings set aktif = true, mode_uji = false,
           cc_tambahan = array['semua.uji@example.invalid'],
           cc_per_jenis = coalesce(cc_per_jenis, '{}'::jsonb) || jsonb_build_object('done', jsonb_build_array('done.uji@example.invalid'),
                                                                                    'approval', jsonb_build_array('approval.uji@example.invalid'))
     where jenis = 'pengajuan';
    update public.depots set email_to = 'to.uji@example.invalid' where id = d.depot_id;
    insert into public.depot_profiles(depot_id, email_kepala_admin) values (d.depot_id, 'ka.uji@example.invalid')
      on conflict (depot_id) do update set email_kepala_admin = excluded.email_kepala_admin;
    update public.profiles set business_email = 'osc.uji@example.invalid' where id = v_osc;
    insert into public.user_depot_access(user_id, depot_id) values (v_osc, d.depot_id) on conflict do nothing;
    update public.profiles set business_email = 'sm.uji@example.invalid' where id = v_sm;
    update public.profiles set business_email = 'aju.uji@example.invalid' where id = v_aju;
    update public.profiles set business_email = 'aju2.uji@example.invalid' where id = v_aju2;
    update public.profiles set business_email = 'pro.uji@example.invalid' where id = v_pro;
    update public.claims set submitted_by = v_aju, cleared_by = v_pro where id = d.id;
    update public.claims set submitted_by = v_aju2, cleared_by = v_pro where id = v_c2;

    -- ---- Penerima per jenis -------------------------------------------------------------
    p := rc_private.email_pengajuan_penerima(d.depot_id, 'done');
    hasil := hasil || jsonb_build_object('uji', 'CC email Done: hanya CC Semua Email + CC wajib Done (Access Management), tanpa OSC/Supervisor',
      'lulus', p->'cc' ? 'semua.uji@example.invalid' and p->'cc' ? 'done.uji@example.invalid' and not (p->'cc' ? 'osc.uji@example.invalid')
        and not exists(select 1 from jsonb_array_elements_text(p->'cc') x
                        where x not in (select lower(btrim(y)) from public.email_settings s, unnest(s.cc_tambahan) y where s.jenis = 'pengajuan')
                          and x not in (select lower(btrim(z)) from public.email_settings s, jsonb_array_elements_text(s.cc_per_jenis->'done') z where s.jenis = 'pengajuan')),
      'rinci', (p->'cc')::text);
    p := rc_private.email_pengajuan_penerima(d.depot_id, 'approval');
    hasil := hasil || jsonb_build_object('uji', 'Jenis lain (Pengajuan / approval) tidak berubah: OSC/Supervisor tetap ditembuskan',
      'lulus', p->'cc' ? 'osc.uji@example.invalid' and p->'cc' ? 'semua.uji@example.invalid' and p->'cc' ? 'approval.uji@example.invalid', 'rinci', (p->'cc')::text);

    -- ---- Antrean email Done --------------------------------------------------------------
    n := rc_private.email_pengajuan_antre('clearing', 'UJIDONE-1', array[d.id, v_c2], v_sm, '');
    select * into o from public.email_outbox where konteks->>'batch' = 'UJIDONE-1' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Email Kepala Admin terisi: TO hanya Kepala Admin (pengaju / pemroses tidak ikut); CC hanya Access Management',
      'lulus', n = 1 and o.tujuan = array['ka.uji@example.invalid'] and 'semua.uji@example.invalid' = any(o.cc) and 'done.uji@example.invalid' = any(o.cc)
        and not ('osc.uji@example.invalid' = any(o.cc)) and not ('to.uji@example.invalid' = any(o.tujuan || o.cc))
        and not ('aju.uji@example.invalid' = any(o.tujuan || o.cc)) and not ('sm.uji@example.invalid' = any(o.tujuan || o.cc)),
      'rinci', 'TO ' || coalesce(array_to_string(o.tujuan, ', '), '-') || ' | CC ' || coalesce(array_to_string(o.cc, ', '), '-'));

    -- Email Kepala Admin kosong: ke user yang mengajukan klaim di surat itu (OSC + Supervisor).
    update public.depot_profiles set email_kepala_admin = null where depot_id = d.depot_id;
    n := rc_private.email_pengajuan_antre('clearing', 'UJIDONE-2', array[d.id, v_c2], v_sm, '');
    select * into o from public.email_outbox where konteks->>'batch' = 'UJIDONE-2' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Email Kepala Admin kosong: TO user yang mengajukan klaimnya (apa pun perannya), bukan Email TO depot / pemroses',
      'lulus', n = 1 and o.tujuan = array['aju.uji@example.invalid', 'aju2.uji@example.invalid'] and not ('to.uji@example.invalid' = any(o.tujuan || o.cc))
        and not ('pro.uji@example.invalid' = any(o.tujuan)) and not ('sm.uji@example.invalid' = any(o.tujuan))
        and not ('osc.uji@example.invalid' = any(o.cc)) and 'done.uji@example.invalid' = any(o.cc),
      'rinci', 'TO ' || coalesce(array_to_string(o.tujuan, ', '), '-') || ' | CC ' || coalesce(array_to_string(o.cc, ', '), '-'));

    -- Hanya pengaju klaim di surat itu; pengaju nonaktif tidak ikut.
    update public.profiles set status = 'inactive' where id = v_aju2;
    n := rc_private.email_pengajuan_antre('clearing', 'UJIDONE-3', array[d.id, v_c2], v_sm, '');
    select * into o from public.email_outbox where konteks->>'batch' = 'UJIDONE-3' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Pengaju nonaktif tidak menerima email Done',
      'lulus', n = 1 and o.tujuan = array['aju.uji@example.invalid'], 'rinci', 'TO ' || coalesce(array_to_string(o.tujuan, ', '), '-'));

    -- Pengaju tidak tercatat (klaim impor): ke user yang memproses Done (pelaku + cleared_by).
    update public.claims set submitted_by = null where id in (d.id, v_c2);
    n := rc_private.email_pengajuan_antre('clearing', 'UJIDONE-4', array[d.id, v_c2], v_sm, '');
    select * into o from public.email_outbox where konteks->>'batch' = 'UJIDONE-4' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Pengaju tidak tercatat (klaim impor): TO user yang memproses Done (pelaku proses + Cleared by)',
      'lulus', n = 1 and o.tujuan = array['pro.uji@example.invalid', 'sm.uji@example.invalid'] and not ('to.uji@example.invalid' = any(o.tujuan || o.cc)),
      'rinci', 'TO ' || coalesce(array_to_string(o.tujuan, ', '), '-'));

    -- Tanpa Email Kepala Admin, tanpa pengaju, pemroses tanpa email: ditahan, dicatat sebabnya.
    update public.claims set cleared_by = null where id in (d.id, v_c2);
    update public.profiles set business_email = '' where id = v_sm;
    v_log0 := (select count(*) from public.activity_logs where event_type = 'email_pengajuan_tanpa_tujuan' and depot_id = d.depot_id);
    n := rc_private.email_pengajuan_antre('clearing', 'UJIDONE-5', array[d.id, v_c2], v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Tanpa Email Kepala Admin dan tanpa email user yang proses: email Done ditahan (tidak ke Email TO depot), dicatat di Log',
      'lulus', n = 0 and not exists(select 1 from public.email_outbox where konteks->>'batch' = 'UJIDONE-5')
        and (select count(*) from public.activity_logs where event_type = 'email_pengajuan_tanpa_tujuan' and depot_id = d.depot_id) = v_log0 + 1
        and (select details->>'sebab' from public.activity_logs where event_type = 'email_pengajuan_tanpa_tujuan' and depot_id = d.depot_id
              order by created_at desc limit 1) ~ 'user yang mengajukan / memproses Done',
      'rinci', 'antre=' || n);

    -- Jenis lain tetap ke Email TO depot, CC termasuk OSC.
    n := rc_private.email_pengajuan_antre('submit_langsung', 'UJIDONE-6', array[d.id], v_sm, '');
    select * into o from public.email_outbox where konteks->>'batch' = 'UJIDONE-6' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Email Pengajuan Baru tidak berubah: TO Email TO depot, CC termasuk OSC',
      'lulus', n = 1 and o.tujuan = array['to.uji@example.invalid'] and 'osc.uji@example.invalid' = any(o.cc),
      'rinci', 'TO ' || coalesce(array_to_string(o.tujuan, ', '), '-') || ' | CC ' || coalesce(array_to_string(o.cc, ', '), '-'));

    -- Mode uji: surat uji tetap dibuat, spanduknya menyebut email Done akan ditahan.
    update public.email_settings set mode_uji = true, email_uji = 'penguji@example.invalid' where jenis = 'pengajuan';
    n := rc_private.email_pengajuan_antre('clearing', 'UJIDONE-7', array[d.id, v_c2], v_sm, '');
    select * into o from public.email_outbox where konteks->>'batch' = 'UJIDONE-7' order by dibuat_pada desc limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Mode uji: surat uji ke alamat penguji, spanduk menyebut email Done ditahan',
      'lulus', n = 1 and o.tujuan = array['penguji@example.invalid'] and o.isi_html ~ 'TIDAK ADA EMAIL KEPALA ADMIN MAUPUN EMAIL USER YANG PROSES' and o.subjek ~ '^\[UJI\]',
      'rinci', o.subjek);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  insert into _hasil_em(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_em order by urut;
