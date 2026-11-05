-- ==========================================================================================
-- Uji email Closing Campaign / compile (20261163610000): jadwal, jendela, isi per depot,
-- penerima seperti Daily + CC tambahan, PDF, Test Email, hari tanpa compile.
-- ==========================================================================================
-- Data uji (riwayat compile_import, arsip, CC tambahan, outbox) dibatalkan lewat UJI_SELESAI.
-- Tidak ada email terkirim: antrean dibatalkan bersama transaksi.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_compile.sql
-- ==========================================================================================
create temp table if not exists _hasil_cmp(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_cmp;

do $uji$
declare hasil jsonb := '[]'; r jsonb; o public.email_outbox; v_sm uuid; v_jam integer; v_batas timestamptz;
  v_k uuid[]; v_dep text[]; v_html text; v_arsip uuid; v_tot numeric; v_camp text; v_dep1 text; v_nama text; v_jenis text;
  v_pen jsonb; n integer; v_camps text[];
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select coalesce(nullif(btrim(full_name), ''), user_code) || case when nullif(btrim(full_name), '') is not null then ' (' || user_code || ')' else '' end
    into v_nama from public.profiles where id = v_sm;

  begin
    perform set_config('request.jwt.claims', '', true);
    select jam into v_jam from public.email_settings where jenis = 'compile';
    hasil := hasil || jsonb_build_object('uji', 'Jadwal compile: mingguan Senin jam 14, aktif, subjek Closing Campaign Report (20261163640000)',
      'lulus', (select aktif and jam = 14 and hari_list = '{1}' and subjek = 'Closing Campaign Report' from public.email_settings where jenis = 'compile'),
      'rinci', (select to_jsonb(s) - 'catatan' from public.email_settings s where jenis = 'compile')::text);

    -- Email compile sungguhan sebelumnya tidak dihitung, supaya jendela uji mulai dari bawaan.
    update public.email_outbox set konteks = konteks - 'sampai' where jenis = 'compile';
    -- Riwayat compile sungguhan di jendela uji disingkirkan; yang dihitung hanya data uji.
    update public.claim_status_history set action = 'compile_import_x'
     where action = 'compile_import' and created_at >= now() - interval '15 days';

    -- Data uji: 2 depot, 4 dokumen not_yet (2 di satu depot x campaign yang sama), dicompile 1 menit lalu.
    with d as (select c.depot_id from public.claims c join public.depots dp on dp.id = c.depot_id
                where c.status = 'not_yet' and c.archived_at is null and c.cb_net > 0 group by c.depot_id
               having count(distinct c.campaign_id) >= 2 order by c.depot_id limit 2),
         p as (select c.id, c.depot_id, c.campaign_id, row_number() over (partition by c.depot_id order by c.campaign_id, c.id) rn,
                      dense_rank() over (partition by c.depot_id order by c.campaign_id) cr
                 from public.claims c join d on d.depot_id = c.depot_id where c.status = 'not_yet' and c.archived_at is null and c.cb_net > 0)
    select array_agg(id order by depot_id, rn) into v_k from p where cr <= 2 and rn <= 3;
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, batch, reason, created_at)
    select x, v_sm, null, 'not_yet', 'compile_import', 'UJI', 'Compile cashback', now() - interval '1 minute' from unnest(v_k) x;
    select array_agg(distinct dp.depot_code order by dp.depot_code) into v_dep from public.claims c join public.depots dp on dp.id = c.depot_id where c.id = any(v_k);
    select array_agg(distinct ca.campaign_code order by ca.campaign_code) into v_camps from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.id = any(v_k);

    -- ---- Pratinjau -------------------------------------------------------------------------
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_email_susun('compile', false);
    v_html := coalesce(r->>'isiHtml', '');
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau: wording "Dear All," lalu "Berikut closing campaign per hari ini (tanggal)"',
      'lulus', r->>'status' = 'success' and v_html ~ 'Dear All,' and position('Berikut closing campaign per hari ini (<strong>' || rc_private.tgl_panjang(now()) || '</strong>)' in v_html) > 0,
      'rinci', coalesce(r->>'message', '') || ' ' || cardinality(v_k)::text || ' dokumen uji');
    hasil := hasil || jsonb_build_object('uji', 'Satu email untuk semua depot: dikelompokkan per campaign (urut kode campaign), depot di bawahnya',
      'lulus', cardinality(v_dep) = 2 and cardinality(v_camps) >= 2
           and not exists (select 1 from unnest(v_camps) k where position('>' || k || ' - ' in v_html) = 0)
           and position('>' || v_camps[1] || ' - ' in v_html) < position('>' || v_camps[2] || ' - ' in v_html)
           and v_html !~ '>Depot [^<]* - ',
      'rinci', array_to_string(v_camps, ', ') || ' | ' || array_to_string(v_dep, ', '));
    hasil := hasil || jsonb_build_object('uji', 'Judul campaign memuat Periode Campaign dan Jenis Hadiah; kolom No, Kode Depot, Nama Depot, Total CB Net, Process By',
      'lulus', v_html ~ '>NO</th><th[^>]*>KODE DEPOT</th><th[^>]*>NAMA DEPOT</th><th[^>]*>TOTAL CB NET</th><th[^>]*>PROCESS BY</th>'
           and v_html ~ 'Periode Campaign: ' and v_html ~ 'Jenis Hadiah: ' and v_html ~ '>1\.</td>' and v_html ~ '>2\.</td>', 'rinci', '-');

    -- Satu baris = depot x campaign; total = jumlah cb_net dokumennya; jenis hadiah = bawaan Key Master.
    select dp.depot_code, ca.campaign_code, trunc(sum(c.cb_net)), rc_private.cb_label(ca.cashback_type) into v_dep1, v_camp, v_tot, v_jenis
      from public.claims c join public.depots dp on dp.id = c.depot_id join public.campaigns ca on ca.id = c.campaign_id
     where c.id = any(v_k) group by 1, 2, 4 order by count(*) desc, 1, 2 limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Baris depot x campaign: Total CB Net = jumlah cb_net, Jenis Hadiah = Jenis CB bawaan campaign, Process By = user compile',
      'lulus', substring(v_html from position('>' || v_camp || ' - ' in v_html)) ~ ('^>' || v_camp || ' - [^<]*<[^>]*>[^<]*<[^>]*>Periode Campaign: [^<]* &middot; Jenis Hadiah: '
                         || rc_private.html_aman(coalesce(nullif(v_jenis, ''), '-')) || ' &middot;')
           and substring(v_html from position('>' || v_camp || ' - ' in v_html)) ~ ('<td[^>]*>' || v_dep1 || '</td><td[^>]*>[^<]*</td><td[^>]*>'
                         || replace(rc_private.rupiah(v_tot), '.', '\.') || '</td><td[^>]*>' || replace(replace(rc_private.html_aman(v_nama), '(', '\('), ')', '\)') || '</td>'),
      'rinci', v_dep1 || ' ' || v_camp || ' ' || coalesce(v_jenis, '') || ' ' || rc_private.rupiah(v_tot) || ' ' || v_nama);
    hasil := hasil || jsonb_build_object('uji', 'Total per campaign dan total keseluruhan',
      'lulus', position('Total Campaign ' || v_camps[1] in v_html) > 0
           and position('total CB Net ' || rc_private.rupiah((select sum(trunc(t)) from (select sum(c.cb_net) t from public.claims c where c.id = any(v_k) group by c.depot_id, c.campaign_id) z)) in v_html) > 0,
      'rinci', '-');

    -- Dokumen compile yang diarsip tidak masuk.
    v_arsip := v_k[1];
    update public.claims set archived_at = now() where id = v_arsip;
    hasil := hasil || jsonb_build_object('uji', 'Dokumen compile yang diarsip tidak dihitung',
      'lulus', (select sum((x->>'qty')::int) from jsonb_array_elements(rc_private.email_cmp_isi(now() - interval '1 hour', now())->'rows') x) = cardinality(v_k) - 1,
      'rinci', '-');
    update public.claims set archived_at = null where id = v_arsip;

    -- ---- Penerima seperti Daily + CC tambahan ----------------------------------------------
    update public.email_settings set cc_tambahan = array['cc.tambahan@contoh.co.id'] where jenis = 'compile';
    r := public.rc_email_susun('compile', false);
    v_pen := rc_private.penerima_depot(v_dep);
    hasil := hasil || jsonb_build_object('uji', 'TO = Email TO depot yang compile (seperti Top 5 Depot); CC = Email CC depot + CC tambahan',
      'lulus', (r->'penerima'->'to') = (v_pen->'to') and (r->'penerima'->'cc') ? 'cc.tambahan@contoh.co.id'
           and not exists (select 1 from jsonb_array_elements_text(v_pen->'cc') x where not ((r->'penerima'->'cc') ? x)),
      'rinci', (r->'penerima')::text);
    hasil := hasil || jsonb_build_object('uji', 'Panel Email Otomatis: jadwal compile tampil dengan CC tambahan',
      'lulus', exists (select 1 from jsonb_array_elements(public.rc_email_status()->'pengaturan') x
                        where x->>'jenis' = 'compile' and (x->'cc') ? 'cc.tambahan@contoh.co.id' and (x->>'jam')::int = 14), 'rinci', '-');

    -- ---- Terjadwal -------------------------------------------------------------------------
    perform set_config('request.jwt.claims', '', true);
    v_batas := rc_private.email_cmp_batas(now(), v_jam);
    update public.claim_status_history set created_at = v_batas - interval '1 minute' where action = 'compile_import' and claim_id = any(v_k);
    r := public.rc_email_susun('compile', true);
    select * into o from public.email_outbox where id = nullif(r->>'id', '')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Terjadwal: jendela sampai jam 14:00 WIB terakhir, outbox pending, PDF ikut disusun',
      'lulus', o.status in ('pending', 'skipped') and (o.konteks->>'sampai')::timestamptz = v_batas
           and (o.konteks->>'dari')::timestamptz = v_batas - interval '7 days'
           and o.konteks->>'pdfHtml' ~ 'Closing Campaign Report' and o.konteks->>'pdfHtml' ~ ('>' || v_camps[1] || ' - ')
           and o.subjek = 'Closing Campaign Report - ' || rc_private.tgl_panjang(now()) and 'cc.tambahan@contoh.co.id' = any(o.cc),
      'rinci', coalesce(o.status, '-') || ' ' || coalesce(o.konteks->>'dari', '') || ' .. ' || coalesce(o.konteks->>'sampai', '') || ' ' || coalesce(o.galat, ''));
    update public.email_outbox set status = 'sent' where id = o.id;
    r := public.rc_email_susun('compile', false);
    hasil := hasil || jsonb_build_object('uji', 'Sesudah terkirim: compile yang sama tidak terulang di email berikutnya',
      'lulus', r->>'dikirim' = 'false' and r->>'message' ~ 'Tidak ada compile', 'rinci', coalesce(r->>'message', ''));
    hasil := hasil || jsonb_build_object('uji', 'Pengiriman: lampiran PDF bernama Closing_Campaign_Report_<tanggal>',
      'lulus', pg_get_functiondef('rc_private.kirim_satu_email(uuid)'::regprocedure) ~ 'Closing_Campaign_Report_'
           and pg_get_functiondef('rc_private.kirim_satu_email(uuid)'::regprocedure) ~ $r$v\.jenis in \('notachieved', 'compile'$r$, 'rinci', '-');

    -- ---- Test Email ------------------------------------------------------------------------
    update public.claim_status_history set created_at = now() - interval '1 minute' where action = 'compile_import' and claim_id = any(v_k);
    r := public.rc_email_susun('compile', true, 'uji.rc@contoh.co.id');
    select * into o from public.email_outbox where id = nullif(r->>'id', '')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Test Email: hanya ke alamat uji, subjek [UJI], tidak menggeser jendela',
      'lulus', o.tujuan = array['uji.rc@contoh.co.id'] and coalesce(cardinality(o.cc), 0) = 0 and o.subjek ~ '^\[UJI\] Closing Campaign Report'
           and (o.konteks->>'uji')::boolean, 'rinci', coalesce(o.subjek, '-'));

    -- ---- Hari tanpa compile ----------------------------------------------------------------
    delete from public.claim_status_history where action = 'compile_import' and claim_id = any(v_k);
    select count(*) into n from public.email_outbox where jenis = 'compile' and status = 'pending';
    r := public.rc_email_susun('compile', true);
    hasil := hasil || jsonb_build_object('uji', 'Tanpa compile: email tidak dikirim (outbox skipped)',
      'lulus', r->>'dikirim' = 'false' and (select status from public.email_outbox where id = nullif(r->>'id', '')::uuid) = 'skipped'
           and (select count(*) from public.email_outbox where jenis = 'compile' and status = 'pending') = n,
      'rinci', coalesce(r->>'message', ''));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_cmp(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_cmp order by urut;
