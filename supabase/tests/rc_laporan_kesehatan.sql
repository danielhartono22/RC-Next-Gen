-- ==========================================================================================
-- Uji Laporan Kesehatan RC / RC Health Report (migrasi 20261163230000)
-- ==========================================================================================
-- Hanya menyusun (rc_email_susun) dan menyimpan pengaturan, TIDAK mengirim: rc_email_tick /
-- rc_email_kirim_sekarang / rc_email_jalankan_antrean tidak dipanggil. Seluruh perubahan
-- (fixture klaim, pengaturan penerima, baris antrean) dibatalkan oleh UJI_SELESAI, dan pengirim
-- tiap menit tidak melihat baris yang belum di-commit. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_laporan_kesehatan.sql
-- ==========================================================================================
create temp table if not exists _hasil_lk(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_lk;

do $uji$
declare hasil jsonb := '[]'; r jsonb; o record; s record; v_sm uuid; v_tanpa uuid; v_galat text; u record;
  v_out record; v_tm record; v_mulai timestamptz; v_detik numeric; v_n bigint; v_cc_pengajuan text[];
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  for u in select p.id from public.profiles p where p.status = 'active' and not p.must_change_password and p.role <> 'system manager'
            order by p.user_code limit 100 loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id::text, 'role', 'authenticated')::text, true);
    if not rc_private.can_tab('access.email') then v_tanpa := u.id; exit; end if;
  end loop;
  perform set_config('request.jwt.claims', '', true);

  begin
    -- ---- Pengaturan --------------------------------------------------------------------
    select * into s from public.email_settings where jenis = 'kesehatan';
    -- Penerima diatur pemilik dari panel (bisa lebih dari sa_sd1), jadi yang diuji hanya: ada dan sah.
    hasil := hasil || jsonb_build_object('uji', 'Settings: active, 08:00, Mon-Fri, valid To recipients, English subject',
      'lulus', s.aktif and s.jam = 8 and s.hari_list = '{1,2,3,4,5}'::smallint[] and cardinality(s.tujuan) >= 1
        and not exists(select 1 from unnest(s.tujuan) x where x !~ '^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$')
        and s.subjek = 'RC Health Report - Outliers, Customers Without Master & Bugs',
      'rinci', format('aktif %s, jam %s, hari %s, tujuan %s, subjek %s', s.aktif, s.jam, s.hari_list, s.tujuan, s.subjek));
    hasil := hasil || jsonb_build_object('uji', 'No PDF attachment (Daily keeps its PDF)',
      'lulus', not rc_private.email_perlu_pdf('kesehatan') and rc_private.email_perlu_pdf('daily'), 'rinci', '');

    -- ---- Penerima To / CC dari panel ----------------------------------------------------------
    select cc_tambahan into v_cc_pengajuan from public.email_settings where jenis = 'pengajuan';
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_email_settings_simpan(jsonb_build_array(jsonb_build_object('jenis', 'kesehatan',
           'tujuan', 'sa_sd1@nipponpaint-indonesia.com', 'cc', 'Satu.Uji@example.invalid; dua.uji@example.invalid, SA_SD1@nipponpaint-indonesia.com')));
    select * into s from public.email_settings where jenis = 'kesehatan';
    hasil := hasil || jsonb_build_object('uji', 'CC can be customised: tidied, lower-case, To duplicates removed',
      'lulus', s.tujuan = array['sa_sd1@nipponpaint-indonesia.com'] and s.cc_tambahan = array['satu.uji@example.invalid', 'dua.uji@example.invalid'],
      'rinci', format('to %s | cc %s', s.tujuan, s.cc_tambahan));
    hasil := hasil || jsonb_build_object('uji', 'CC of other email types (CC Semua Email pengajuan) untouched',
      'lulus', (select cc_tambahan from public.email_settings where jenis = 'pengajuan') is not distinct from v_cc_pengajuan, 'rinci', '');
    begin
      r := public.rc_email_settings_simpan(jsonb_build_array(jsonb_build_object('jenis', 'kesehatan', 'cc', 'bukan-email')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'Invalid CC address rejected', 'lulus', v_galat ~ 'tidak sah', 'rinci', v_galat);
    begin
      r := public.rc_email_settings_simpan(jsonb_build_array(jsonb_build_object('jenis', 'kesehatan', 'tujuan', '')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'Empty To rejected', 'lulus', v_galat ~ 'wajib diisi', 'rinci', v_galat);
    r := public.rc_email_status();
    hasil := hasil || jsonb_build_object('uji', 'Email panel shows the kesehatan type with To and CC',
      'lulus', exists(select 1 from jsonb_array_elements(r->'pengaturan') p
                       where p->>'jenis' = 'kesehatan' and p->'tujuan' ? 'sa_sd1@nipponpaint-indonesia.com'
                         and p->'cc' ? 'satu.uji@example.invalid')
        and not exists(select 1 from jsonb_array_elements(r->'pengaturan') p where p->>'jenis' = 'pengajuan' and jsonb_typeof(p->'cc') = 'array'),
      'rinci', '');
    perform set_config('request.jwt.claims', '', true);

    -- ---- Fixture: satu outlier baru, satu klaim tanpa master, satu email gagal -----------
    select c.id, c.no_doc into v_out from public.claims c
     where c.archived_at is null and c.cb_net > 1000 and c.customer_id is not null order by c.created_at desc limit 1;
    -- CB sangat besar supaya pasti masuk 10 contoh teratas, walau prod sedang punya banyak
    -- outlier baru dalam periode yang sama.
    update public.claims set net_value = 1, cb_net = 999999999999, updated_at = now() where id = v_out.id;
    select c.id, c.no_doc into v_tm from public.claims c
     where c.archived_at is null and c.customer_id is not null and c.id <> v_out.id order by c.created_at desc limit 1;
    update public.claims set customer_id = null, source_customer_code = 'UJI-TOKO-LK' where id = v_tm.id;
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, galat, percobaan)
    values ('daily', array['uji@example.invalid'], 'uji', '', 'failed', 'UJI-GAGAL-KIRIM-LK', 5);

    -- ---- Seperti penjadwal: tanpa user login ---------------------------------------------
    v_mulai := clock_timestamp();
    r := public.rc_email_susun('kesehatan', true);
    v_detik := extract(epoch from clock_timestamp() - v_mulai);
    select * into o from public.email_outbox where id = nullif(r->>'id', '')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Scheduler (no login): queued To sa_sd1 with the custom CC, English subject with date',
      'lulus', r->>'status' = 'success' and o.status = 'pending' and o.jenis = 'kesehatan'
        and o.tujuan = array['sa_sd1@nipponpaint-indonesia.com'] and o.cc = array['satu.uji@example.invalid', 'dua.uji@example.invalid']
        and o.subjek ~ '^RC Health Report - Outliers, Customers Without Master & Bugs - \d{1,2} [A-Z][a-z]+ \d{4}$',
      'rinci', coalesce(o.status, '-') || ' | ' || coalesce(o.subjek, '-') || ' | cc ' || coalesce(array_to_string(o.cc, ', '), '-'));
    hasil := hasil || jsonb_build_object('uji', 'Composed in under 8 seconds (limit for a user''s manual send)',
      'lulus', v_detik < 8, 'rinci', round(v_detik, 2) || ' s');
    hasil := hasil || jsonb_build_object('uji', 'Opening "Hi Daniel," + "We would like to share", English sections incl. Key Statistics',
      'lulus', o.isi_html ~ 'Hi Daniel,' and o.isi_html ~ 'We would like to share the RC Health Report'
        and o.isi_html ~ 'Key Statistics' and o.isi_html ~ '1\. Data Outliers' and o.isi_html ~ '2\. Customers Without Master'
        and o.isi_html ~ '3\. Bugs &amp; Incidents' and o.isi_html ~ '4\. Bug Risk Prediction'
        and o.isi_html !~ 'could not be generated' and o.isi_html !~ 'Dear Team',
      'rinci', length(o.isi_html) || ' characters');
    select count(*) into v_n from public.claims where archived_at is null;
    hasil := hasil || jsonb_build_object('uji', 'Key Statistics: active claims count in English number format',
      'lulus', position('<td style="border:1px solid #dadce0;padding:6px 8px;vertical-align:top;">' || rc_private.kes_angka(v_n) || '</td>' in o.isi_html) > 0
        and rc_private.kes_angka(1234567) = '1,234,567' and rc_private.kes_rp(1234567.9) = 'Rp 1,234,567',
      'rinci', rc_private.kes_angka(v_n));
    hasil := hasil || jsonb_build_object('uji', 'New outlier (CB > Net Value) appears in top examples as new/changed',
      'lulus', position(rc_private.html_aman(v_out.no_doc) in o.isi_html) > 0 and o.isi_html ~ 'CB &gt; Net Value \(new/changed\)',
      'rinci', v_out.no_doc);
    select count(*) into v_n from public.claims where archived_at is null and customer_id is null;
    hasil := hasil || jsonb_build_object('uji', 'Documents without master count matches the data (incl. fixture)',
      'lulus', position('<b>' || rc_private.kes_angka(v_n) || '</b> documents are not yet linked' in o.isi_html) > 0,
      'rinci', rc_private.kes_angka(v_n) || ' documents');
    hasil := hasil || jsonb_build_object('uji', 'Failed email in the period listed under Bugs & Incidents',
      'lulus', o.isi_html ~ 'Email failed to send \(daily\)' and o.isi_html ~ 'UJI-GAGAL-KIRIM-LK', 'rinci', '');
    hasil := hasil || jsonb_build_object('uji', 'Summary figures stored in the queue context',
      'lulus', (o.konteks->'ringkas') ? 'outlierBaru' and (o.konteks->'ringkas'->>'tanpaMaster')::bigint = v_n
        and (o.konteks->'ringkas'->>'gangguan')::bigint >= 1,
      'rinci', (o.konteks->'ringkas')::text);

    -- ---- Pratinjau dan email uji -----------------------------------------------------------
    r := public.rc_email_susun('kesehatan', false);
    select * into o from public.email_outbox where id = nullif(r->>'id', '')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Preview: not queued (skipped, preview)',
      'lulus', o.status = 'skipped' and o.konteks->>'preview' = 'true' and r->>'isiHtml' is not null, 'rinci', coalesce(r->>'message', ''));
    r := public.rc_email_susun('kesehatan', true, 'penguji@example.invalid');
    select * into o from public.email_outbox where id = nullif(r->>'id', '')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Test email: only to the tester, no CC, subject [TEST]',
      'lulus', o.tujuan = array['penguji@example.invalid'] and o.cc = '{}' and o.subjek like '[TEST]%' and o.konteks->>'uji' = 'true',
      'rinci', o.subjek);

    -- ---- Akses ------------------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', v_tanpa::text, 'role', 'authenticated')::text, true);
    begin
      r := public.rc_email_susun('kesehatan', false);
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'User without Email Otomatis access rejected (compose)',
      'lulus', v_tanpa is not null and v_galat ~ 'access.email|akses Email Otomatis', 'rinci', v_galat);
    begin
      r := public.rc_email_settings_simpan(jsonb_build_array(jsonb_build_object('jenis', 'kesehatan', 'cc', 'x@example.invalid')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'User without Email Otomatis access rejected (change recipients)',
      'lulus', v_galat ~ 'access.email|akses Email Otomatis', 'rinci', v_galat);
    perform set_config('request.jwt.claims', '', true);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  insert into _hasil_lk(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_lk order by urut;
