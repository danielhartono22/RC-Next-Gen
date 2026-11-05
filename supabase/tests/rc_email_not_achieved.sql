-- ==========================================================================================
-- Uji email otomatis Not Achieved - migrasi 20261163360000
-- ==========================================================================================
-- Seluruh uji berjalan di subtransaksi yang DIBATALKAN (UJI_SELESAI). Tidak ada email yang
-- dikirim: hanya baris email_outbox yang disusun lalu ikut dibatalkan (antrean tidak dijalankan).
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_not_achieved.sql
-- ==========================================================================================
create temp table if not exists _hasil_na(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_na;

create or replace function pg_temp.na_sebagai(p_user uuid) returns void language sql as $f$
  select set_config('request.jwt.claims', case when p_user is null then '' else
    json_build_object('sub', p_user::text, 'role', 'authenticated')::text end, true);
$f$;

do $uji$
declare
  hasil jsonb := '[]'; r jsonb; j jsonb; v_galat text; d1 record; d2 record; c1 uuid; c2 uuid; c3 uuid;
  v_sm uuid; v_adm uuid; v_osc uuid; v_dh uuid; v_set public.email_settings; v_pen jsonb; v_html text; n integer;
  v_b timestamptz := rc_private.email_na_batas(now());
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select id into v_adm from public.profiles where role = 'admin' and status = 'active' order by user_code limit 1;
  select id into v_osc from public.profiles where role = 'osc' and status = 'active' order by user_code limit 1;
  select id into v_dh from public.profiles where role in ('supervisor', 'others', 'finance') and status = 'active' and id <> v_osc order by user_code limit 1;
  select d.id, d.depot_code kode, upper(btrim(d.region)) region into d1 from public.depots d
   where d.archived_at is null and not d.bukan_depot and btrim(coalesce(d.region, '')) <> '' order by d.depot_code limit 1;
  select d.id, d.depot_code kode, upper(btrim(d.region)) region into d2 from public.depots d
   where d.archived_at is null and not d.bukan_depot and btrim(coalesce(d.region, '')) <> '' and upper(btrim(d.region)) <> d1.region
   order by d.depot_code limit 1;
  select id into c1 from public.campaigns where archived_at is null order by campaign_code limit 1;
  select id into c2 from public.campaigns where archived_at is null order by campaign_code offset 1 limit 1;
  select id into c3 from public.campaigns where archived_at is null order by campaign_code offset 2 limit 1;

  begin
    -- ---- Jendela waktu -------------------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'Batas: 15:59 WIB -> 16:00 kemarin; 16:00 dan 16:30 WIB -> 16:00 hari itu',
      'lulus', rc_private.email_na_batas('2026-10-22 15:59+07') = '2026-10-21 16:00+07'
           and rc_private.email_na_batas('2026-10-22 16:00+07') = '2026-10-22 16:00+07'
           and rc_private.email_na_batas('2026-10-22 16:30+07') = '2026-10-22 16:00+07', 'rinci', '-');
    delete from public.email_outbox where jenis = 'notachieved';
    j := rc_private.email_na_jendela('2026-10-22 16:05+07', true);
    hasil := hasil || jsonb_build_object('uji', 'Terjadwal 16:05 tanpa riwayat: 16:00 kemarin s/d 16:00 hari ini',
      'lulus', (j->>'dari')::timestamptz = '2026-10-21 16:00+07' and (j->>'sampai')::timestamptz = '2026-10-22 16:00+07', 'rinci', j::text);
    j := rc_private.email_na_jendela('2026-10-22 10:00+07', false);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau 10:00: sejak 16:00 kemarin s/d saat ini (calon email 16:00 hari ini)',
      'lulus', (j->>'dari')::timestamptz = '2026-10-21 16:00+07' and (j->>'sampai')::timestamptz = '2026-10-22 10:00+07', 'rinci', j::text);
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks)
    values ('notachieved', '{a@b.co}', 'x', '', 'sent', jsonb_build_object('preview', false, 'uji', false, 'sampai', '2026-10-20 16:00+07'));
    j := rc_private.email_na_jendela('2026-10-22 16:05+07', true);
    hasil := hasil || jsonb_build_object('uji', 'Hari terlewat ikut: jendela mulai dari batas email sungguhan terakhir',
      'lulus', (j->>'dari')::timestamptz = '2026-10-20 16:00+07', 'rinci', j::text);
    insert into public.email_outbox(jenis, tujuan, subjek, isi_html, status, konteks)
    values ('notachieved', '{a@b.co}', 'x', '', 'skipped', jsonb_build_object('preview', true, 'sampai', '2026-10-22 12:00+07'));
    j := rc_private.email_na_jendela('2026-10-22 16:05+07', true);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau tidak menggeser jendela', 'lulus', (j->>'dari')::timestamptz = '2026-10-20 16:00+07', 'rinci', j::text);
    delete from public.email_outbox where jenis = 'notachieved';

    -- ---- Penerima ----------------------------------------------------------------------------
    update public.depots set email_to = 'to1.uji@contoh.co.id, bersama.uji@contoh.co.id', email_cc = 'cc1.uji@contoh.co.id; bersama.uji@contoh.co.id' where id = d1.id;
    update public.depots set email_to = 'to2.uji@contoh.co.id', email_cc = 'cc2.uji@contoh.co.id' where id = d2.id;
    update public.profiles set business_email = 'osc.uji@contoh.co.id' where id = v_osc;
    delete from public.user_depot_access where user_id in (v_adm, v_osc, v_dh);
    insert into public.user_depot_access(user_id, depot_id) values (v_adm, d1.id), (v_osc, d1.id), (v_dh, d1.id);
    -- 20261163370000: CC tambahan Not Achieved dari Email Otomatis; CC tab Email Pengajuan tidak dipakai.
    update public.email_settings set cc_tambahan = '{semua.uji@contoh.co.id}', cc_per_jenis = '{"done":["done.uji@contoh.co.id"]}',
           mode_uji = false where jenis = 'pengajuan';
    update public.email_settings set cc_tambahan = '{na.uji@contoh.co.id,to1.uji@contoh.co.id}' where jenis = 'notachieved';
    v_pen := rc_private.email_na_penerima(array[d1.id]);
    hasil := hasil || jsonb_build_object('uji', 'TO = Email TO Depot Master saja',
      'lulus', v_pen->'to' = '["bersama.uji@contoh.co.id", "to1.uji@contoh.co.id"]'::jsonb, 'rinci', v_pen->>'to');
    hasil := hasil || jsonb_build_object('uji', 'CC = Email CC Depot Master + CC tambahan jadwal Not Achieved (Email Otomatis); CC tab Email Pengajuan tidak ikut; TO tidak diulang',
      'lulus', v_pen->'cc' = '["cc1.uji@contoh.co.id", "na.uji@contoh.co.id"]'::jsonb, 'rinci', v_pen->>'cc');

    -- ---- Isi dan susun ------------------------------------------------------------------------
    delete from public.timetable_not_achieved; -- hanya tanda uji yang dihitung; ikut dibatalkan
    insert into public.timetable_not_achieved(depot_id, campaign_id, marked_by, marked_at, note) values
      (d1.id, c1, v_adm, v_b - interval '2 hours', 'uji'),
      (d1.id, c2, v_osc, v_b - interval '23 hours', ''),
      (d2.id, c1, v_osc, v_b - interval '1 hour', ''),
      (d2.id, c3, v_osc, v_b - interval '25 hours', ''),     -- sebelum jendela
      (d1.id, c3, v_osc, v_b + interval '1 minute', '');     -- sesudah 16:00: email berikutnya
    j := rc_private.email_na_isi(v_b - interval '1 day', v_b);
    hasil := hasil || jsonb_build_object('uji', 'Isi: seluruh region dalam satu daftar, hanya tanda dalam jendela 16:00-16:00',
      'lulus', jsonb_array_length(j->'rows') = 3 and jsonb_array_length(j->'region') = 2 and jsonb_array_length(j->'depot') = 2
           and j->'rows'->0->>'region' <= j->'rows'->2->>'region',
      'rinci', (select string_agg((x->>'region') || '/' || (x->>'kodeDepot'), ', ') from jsonb_array_elements(j->'rows') x));
    v_html := rc_private.email_na_html(j->'rows', v_b - interval '1 day', v_b);
    hasil := hasil || jsonb_build_object('uji', 'HTML: kalimat pembuka baru, 7 kolom (Region dulu), remark perhatian OSC, Summary per Campaign, kalimat penutup baru',
      'lulus', v_html like '%Berikut daftar campaign yang sudah dikonfirmasi tidak mencapai target sesuai memo campaign yang ditetapkan, sehingga tidak ada toko yang mencapai cashback atas campaign tersebut.%'
           and v_html not like '%ditandai <strong>Not Achieved</strong> pada%'
           and v_html like '%REGION%NAMA DEPOT%NAMA CAMPAIGN%PERIODE START%PERIODE END%PROCESS BY%TIMESTAMP%'
           and v_html like '%Not Achieved Campaign Report%'
           and v_html like '%Mohon OSC konfirmasi ke admin terkait mengenai tindakan ini, karena tindakan ini akan membuat campaign tersebut%tidak bisa diajukan kembali oleh tim depo%'
           and v_html like '%PERHATIAN%Summary per Campaign%KODE CAMPAIGN%NAMA CAMPAIGN%JUMLAH DEPOT TIDAK MENCAPAI%TOTAL 2 CAMPAIGN%>3</td>%Detail%REGION%NAMA DEPOT%TIMESTAMP%'
           and v_html like '%Mohon perhatian kepada All RSM dan Depot Head agar menjadi bahan evaluasi ke depannya.%'
           and v_html not like '%terkait mengenai tindakan ini.</p>%'
           and v_html not like '%SO START%', 'rinci', length(v_html));

    -- Terjadwal (tanpa user login, seperti pg_cron): satu baris antrean per region.
    perform pg_temp.na_sebagai(null);
    r := public.rc_email_susun('notachieved', true);
    hasil := hasil || jsonb_build_object('uji', 'Terjadwal: satu email untuk seluruh region (pending), subjek "Not Achieved Campaign Report - hari ini", batas jendela dicatat',
      'lulus', (select count(*) from public.email_outbox where jenis = 'notachieved' and status = 'pending') = 1
           and (select bool_and((konteks->>'sampai')::timestamptz = v_b and subjek = 'Not Achieved Campaign Report - ' || rc_private.tgl_panjang(now())
                                and jsonb_array_length(konteks->'region') = 2 and tujuan = array['bersama.uji@contoh.co.id', 'to1.uji@contoh.co.id', 'to2.uji@contoh.co.id']
                                and cc @> array['cc1.uji@contoh.co.id', 'cc2.uji@contoh.co.id']
                                and konteks->>'pdfHtml' like '%Not Achieved Campaign Report%dikonfirmasi tidak mencapai target%Summary per Campaign%Detail%')
                  from public.email_outbox where jenis = 'notachieved' and status = 'pending'),
      'rinci', r->>'message' || ' / ' || (select subjek from public.email_outbox where jenis = 'notachieved' and status = 'pending' limit 1));
    hasil := hasil || jsonb_build_object('uji', 'Sesudah terkirim terjadwal: penjadwal tidak menyusun lagi hari itu',
      'lulus', rc_private.email_terkirim_hari_ini('notachieved', now()), 'rinci', '-');
    j := rc_private.email_na_jendela(now(), false);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau sesudahnya mulai dari batas 16:00 email tadi (tanda sesudah 16:00 masuk besok)',
      'lulus', (j->>'dari')::timestamptz = v_b, 'rinci', j::text);

    -- Mode Uji tab Email Pengajuan: dibelokkan ke alamat uji dengan spanduk.
    delete from public.email_outbox where jenis = 'notachieved';
    update public.email_settings set mode_uji = true, email_uji = 'uji.na@contoh.co.id' where jenis = 'pengajuan';
    r := public.rc_email_susun('notachieved', true);
    hasil := hasil || jsonb_build_object('uji', 'Mode Uji: TO hanya alamat uji, tanpa CC, subjek [UJI], spanduk penerima seharusnya',
      'lulus', (select bool_and(tujuan = '{uji.na@contoh.co.id}' and coalesce(array_length(cc, 1), 0) = 0 and subjek like '[UJI] %'
                                and isi_html like '%MODE UJI%' and (konteks->>'modeUji')::boolean)
                  from public.email_outbox where jenis = 'notachieved' and status = 'pending'), 'rinci', r->>'message');

    -- Pratinjau sebagai System Manager: tidak masuk antrean.
    delete from public.email_outbox where jenis = 'notachieved';
    update public.email_settings set mode_uji = false where jenis = 'pengajuan';
    perform pg_temp.na_sebagai(v_sm);
    r := public.rc_email_susun('notachieved', false);
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: tersusun, tidak masuk antrean, isi memuat TO/CC per region',
      'lulus', not exists(select 1 from public.email_outbox where jenis = 'notachieved' and status = 'pending')
           and r->>'isiHtml' like '%TO:%CC:%', 'rinci', r->>'message');
    r := public.rc_email_susun('notachieved', true, 'tes.na@contoh.co.id');
    hasil := hasil || jsonb_build_object('uji', 'Test Email: hanya ke alamat uji, ditandai uji (tidak menggeser jendela)',
      'lulus', (select bool_and(tujuan = '{tes.na@contoh.co.id}' and (konteks->>'uji')::boolean) from public.email_outbox where jenis = 'notachieved' and status = 'pending')
           and not rc_private.email_terkirim_hari_ini('notachieved', now()), 'rinci', r->>'message');

    -- Tanpa tanda: tidak ada email.
    delete from public.email_outbox where jenis = 'notachieved';
    delete from public.timetable_not_achieved; -- hanya tanda uji yang dihitung; ikut dibatalkan
    perform pg_temp.na_sebagai(null);
    r := public.rc_email_susun('notachieved', true);
    hasil := hasil || jsonb_build_object('uji', 'Tanpa tanda Not Achieved: email tidak disusun (baris skipped saja)',
      'lulus', not (r->>'dikirim')::boolean and not exists(select 1 from public.email_outbox where jenis = 'notachieved' and status = 'pending')
           and not rc_private.email_terkirim_hari_ini('notachieved', now()), 'rinci', r->>'message');

    -- ---- Pengaturan ------------------------------------------------------------------------------
    select * into v_set from public.email_settings where jenis = 'notachieved';
    -- Jam dan hari dapat diubah pengguna di Email Otomatis, jadi tidak diperiksa di sini.
    hasil := hasil || jsonb_build_object('uji', 'Jenis notachieved terdaftar; PDF dari isi tersimpan (bukan PDF laporan umum); pengirim punya cabang PDF Not Achieved',
      'lulus', v_set.jenis = 'notachieved' and not rc_private.email_perlu_pdf('notachieved')
           and position('Not_Achieved_Campaign_Report_' in pg_get_functiondef('rc_private.kirim_satu_email(uuid)'::regprocedure)) > 0,
      'rinci', v_set.jam || ' / ' || coalesce(v_set.hari_list::text, 'tiap hari'));
    perform pg_temp.na_sebagai(v_sm);
    r := public.rc_email_settings_simpan('[{"jenis":"notachieved","cc":"X.na@contoh.co.id; y.na@contoh.co.id"}]');
    hasil := hasil || jsonb_build_object('uji', 'CC tambahan Not Achieved disimpan dari Email Otomatis',
      'lulus', (select cc_tambahan = '{x.na@contoh.co.id,y.na@contoh.co.id}' from public.email_settings where jenis = 'notachieved'), 'rinci', r->>'message');
    begin perform public.rc_email_pengajuan_simpan(false, '[]', false, '', '{"notachieved":["x.na@contoh.co.id"]}'); v_galat := 'lolos';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Tab Email Pengajuan tidak lagi menerima CC Not Achieved', 'lulus', v_galat ~ 'tidak dikenal', 'rinci', v_galat);
    hasil := hasil || jsonb_build_object('uji', 'Email Otomatis menampilkan jadwal notachieved',
      'lulus', exists(select 1 from jsonb_array_elements(public.rc_email_status()->'pengaturan') x where x->>'jenis' = 'notachieved'), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  insert into _hasil_na(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_na order by urut;
