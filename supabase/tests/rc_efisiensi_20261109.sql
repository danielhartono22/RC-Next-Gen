-- ==========================================================================================
-- Uji 9 November 2026: Upload Debtor bertahap (860000) dan efisiensi server (870000)
-- ==========================================================================================
-- Hasil harus sama dengan cara lama. Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_efisiensi_20261109.sql
-- ==========================================================================================
create temp table if not exists _hasil_ef(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_ef;

-- Rantai Remark lama, sebagai pembanding hasil yang baru.
create or replace function pg_temp.remark_lama(a timestamptz, b boolean, c boolean, d timestamptz, e text[], f boolean, g boolean, h boolean, i boolean default false) returns text language sql stable as $f$
  select nullif(concat_ws(', ', nullif(concat_ws(', ', nullif(concat_ws(', ', nullif(concat_ws(', ', nullif(concat_ws(', ',
    case when coalesce(array_length(e,1),0) > 0
         then (select string_agg('Doc Amendment - ' || t, ', ' order by o)
                 from (select t, min(o) o from unnest(e) with ordinality u(t, o) group by t) s)
         when d is not null then 'Doc Amendment' end,
    case when a is not null or b then 'Document Reprocessed' end,
    case when c then 'CB Type Changed' end), ''),
    case when coalesce(f, false) then 'Bank Account Changed' end), ''),
    case when coalesce(g, false) then 'Special Claims' end), ''),
    case when coalesce(h, false) then 'DC changed' end), ''),
    case when coalesce(i, false) then 'Status Changed' end), ''); /* 20261163880000 */
$f$;

do $uji$
declare hasil jsonb := '[]'; r jsonb; r2 jsonb; v_sm uuid; v_galat text; n bigint; n2 bigint; v_zd jsonb;
  v_as date := date_trunc('month', now() at time zone 'Asia/Jakarta')::date; v_nol jsonb; v_rows jsonb; v_id uuid; v_id2 uuid; d1 record; d2 record; m jsonb; v_baris jsonb; v_kode text; t0 timestamptz; v_tahun int := extract(year from now() at time zone 'Asia/Jakarta')::int;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  select nilai into v_zd from public.pengaturan_sistem where kunci = 'zdage_aktif';

  begin
    -- ---- Hasil pembantu per baris sama dengan cara lama -------------------------------------------
    select count(*) into n from generate_series(1, 2) g, (values
        (null::timestamptz, false, false, null::timestamptz, null::text[], false, false, false),
        (now(), false, false, null, null, false, false, false), (null, true, true, null, null, false, false, false),
        (null, false, false, now(), '{}', false, false, false), (null, false, false, now(), array['Released', 'Claimed', 'Released'], true, true, true),
        (null, false, false, null, array['Done'], null, null, null), (now(), true, true, now(), array['Not Yet'], true, false, true)) v(a, b, c, d, e, f, g2, h)
     where rc_private.claim_remark_dari(a, b, c, d, e, f, g2, h) is distinct from pg_temp.remark_lama(a, b, c, d, e, f, g2, h);
    select count(*) into n2 from public.claims c left join rc_private.claim_sensitive s on s.claim_id = c.id
     where rc_private.claim_remark(c) is distinct from pg_temp.remark_lama(c.reprocessed_at,
        exists(select 1 from public.claim_status_history h where h.claim_id = c.id and h.action like '%reprocess%'), c.cashback_type_changed, c.amended_at,
        array(select rc_private.legacy_status(h.from_status) from public.claim_status_history h where h.claim_id = c.id and h.action = 'amend' order by h.id),
        coalesce(s.rekening_diubah, false), c.adhoc_lanjut = 'done', c.dc_changed_at is not null, c.status_changed_at is not null);
    hasil := hasil || jsonb_build_object('uji', 'Remark sama dengan rantai lama: contoh dan seluruh klaim', 'lulus', n = 0 and n2 = 0, 'rinci', n || ' / ' || n2);
    hasil := hasil || jsonb_build_object('uji', 'Rekening tampil: salinan dokumen, master, kosong',
      'lulus', rc_private.rekening_tampil(' 1 ', '', '', '2', 'b', 'c') = '{"noRek":"1","namaRek":"","bank":"","sumberRek":"dokumen"}'::jsonb
           and rc_private.rekening_tampil('', null, '', ' 2', 'b', 'c') = '{"noRek":"2","namaRek":"b","bank":"c","sumberRek":"master"}'::jsonb
           and rc_private.rekening_tampil(null, null, null, null, null, null) = '{"noRek":"","namaRek":"","bank":"","sumberRek":""}'::jsonb, 'rinci', '-');

    -- ---- Open dan Restricted sama dengan boleh_open --------------------------------------------------
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    select count(*) filter (where rc_private.boleh_open(c.id, c.customer_id)), count(*) filter (where not rc_private.boleh_open(c.id, c.customer_id)) into n, n2
      from public.claims c where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null;
    r := public.rc_open_claims_filtered('', '', 0, 500, ''); r2 := public.rc_restricted_claims('', '', 0, 500, '');
    hasil := hasil || jsonb_build_object('uji', 'ZDAGE hidup: Open dan Restricted = boleh_open', 'lulus', (r->>'total')::bigint = n and (r2->>'total')::bigint = n2, 'rinci', (r->>'total') || '/' || n || ' ' || (r2->>'total') || '/' || n2);
    -- Bad Debt dan tawaran muncul di baris Open seperti debtor_info.
    hasil := hasil || jsonb_build_object('uji', 'Baris Open sama dengan debtor_info',
      'lulus', not exists (select 1 from jsonb_array_elements(r->'rows') x join public.claims c on c.no_doc = x->>'noDoc' cross join lateral rc_private.debtor_info(c.id, c.customer_id) di
        where (x->>'offerStatus') is distinct from coalesce(di.offer_status, '') or (x->>'badDebt')::boolean is distinct from coalesce(di.bad_debt, false)
           or (x->>'sisaHari')::integer is distinct from di.sisa_hari or (x->>'offerJenis') is distinct from coalesce(di.offer_result, '')), 'rinci', jsonb_array_length(r->'rows')::text);
    hasil := hasil || jsonb_build_object('uji', 'Baris Restricted berurutan dan beralasan',
      'lulus', not exists (select 1 from jsonb_array_elements(r2->'rows') x where coalesce(x->>'alasan', '') = '')
           and (select coalesce(array_agg(x->>'noDoc'), '{}') from jsonb_array_elements(r2->'rows') x)
             = array(select c.no_doc from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and not rc_private.boleh_open(c.id, c.customer_id) order by ca.campaign_code, c.no_doc limit 500), 'rinci', jsonb_array_length(r2->'rows')::text);
    update public.pengaturan_sistem set nilai = 'false'::jsonb where kunci = 'zdage_aktif';
    r := public.rc_open_claims_filtered('', '', 0, 1, '');
    select count(*) into n from public.claims c where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null;
    begin perform public.rc_restricted_claims('', '', 0, 1, ''); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'ZDAGE mati: seluruh Not Yet di Open, tab Restricted tertutup', 'lulus', (r->>'total')::bigint = n and v_galat ~ 'tidak diizinkan', 'rinci', (r->>'total') || '/' || n || ' ' || v_galat);
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';

    -- ---- Lookup: bolehAjukan sama dengan boleh_open --------------------------------------------------
    select jsonb_agg(c.no_doc) into r from (select no_doc from public.claims where status = 'not_yet' and archived_at is null order by no_doc limit 300) c;
    r2 := public.rc_lookup_master('{}', array(select upper(jsonb_array_elements_text(r))));
    hasil := hasil || jsonb_build_object('uji', 'Lookup dokumen: bolehAjukan = boleh_open',
      'lulus', not exists (select 1 from jsonb_array_elements(r2->'documents') x join public.claims c on c.no_doc = x->>'noDoc'
        where (x->>'bolehAjukan')::boolean is distinct from rc_private.boleh_open(c.id, c.customer_id)), 'rinci', jsonb_array_length(r2->'documents')::text);

    -- ---- Workflow ------------------------------------------------------------------------------------
    r := public.rc_legacy_workflow(1000, null, null);
    hasil := hasil || jsonb_build_object('uji', 'Workflow: tanpa can_tab per baris, volume dan net value ikut',
      'lulus', pg_get_functiondef('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)'::regprocedure) !~ 'where rc_private.can_tab'
           and not exists (select 1 from jsonb_array_elements(r->'claimFinData') x where not (x ? 'volume' and x ? 'netValue'))
           and jsonb_typeof(r->'releaseData') = 'array' and jsonb_typeof(r->'adhocData') = 'array', 'rinci', (r->>'total'));

    -- ---- Analytics ------------------------------------------------------------------------------------
    r := public.rc_legacy_dashboard(5000, null, null);
    select count(*) into n from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.archived_at is null;
    r2 := public.rc_legacy_dashboard(5000, null, null, array[v_tahun, 0]);
    select count(*) into n2 from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.archived_at is null
       and coalesce(extract(year from coalesce(c.period_start, ca.period_start))::int, 0) in (v_tahun, 0);
    hasil := hasil || jsonb_build_object('uji', 'Analytics: tanpa tahun seluruh klaim; dengan tahun hanya tahun itu + tanpa periode',
      'lulus', (r->>'perkiraanTotal')::bigint = n and (r2->>'perkiraanTotal')::bigint = n2
           and jsonb_array_length(r2->'history') = least(n2, 5000)
           and not exists (select 1 from jsonb_array_elements(r2->'history') x where coalesce(nullif(x->>'validYear', ''), v_tahun::text) <> v_tahun::text)
           and jsonb_array_length(r->'tahunTersedia') >= 1, 'rinci', n || ' -> ' || n2 || ' ' || (r->'tahunTersedia')::text);

    -- ---- Cron email -----------------------------------------------------------------------------------
    update rc_private.email_sapu set terakhir = now();
    hasil := hasil || jsonb_build_object('uji', 'Sapu Drive: baru saja = tidak perlu', 'lulus', not rc_private.email_sapu_perlu(), 'rinci', '-');
    update rc_private.email_sapu set terakhir = now() - interval '2 hours';
    update public.email_outbox set dikirim_pada = null where dikirim_pada > now() - interval '2 hours';
    hasil := hasil || jsonb_build_object('uji', 'Sapu Drive: 2 jam tanpa email terkirim = tidak perlu', 'lulus', not rc_private.email_sapu_perlu(), 'rinci', '-');
    update rc_private.email_sapu set terakhir = now() - interval '25 hours';
    hasil := hasil || jsonb_build_object('uji', 'Sapu Drive: sekali sehari walau tanpa email', 'lulus', rc_private.email_sapu_perlu(), 'rinci', '-');
    perform set_config('request.jwt.claims', '', true);
    insert into net._http_response(id, status_code, content, created) values (-987654, null, null, now());
    hasil := hasil || jsonb_build_object('uji', 'Token: jawaban pg_net tanpa status bukan kegagalan', 'lulus', rc_private.gmail_token_ambil(-987654) is null, 'rinci', '-');
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok efisiensi berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  -- ---- Upload Debtor bertahap ---------------------------------------------------------------------------
  begin
    update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';
    update public.campaigns ca set so_start = coalesce(ca.so_start, ca.period_start), billing_end = coalesce(ca.billing_end, ca.so_end, ca.period_end)
     where ca.so_start is null or coalesce(ca.billing_end, ca.so_end) is null;
    delete from public.rc_clearing_offers; delete from public.rc_zdage_hasil; delete from public.rc_zdage_depot_data;
    update public.claims set bad_debt_remark_id = null where bad_debt_remark_id is not null;
    delete from public.rc_bad_debt_remarks;
    delete from public.rc_zdage_uploads where status in ('preview', 'menerapkan');

    select c.depot_id id, d.depot_code kode into d1 from public.claims c join public.depots d on d.id = c.depot_id
     where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and c.customer_id is not null group by 1, 2 order by count(*) desc limit 1;
    select c.depot_id id, d.depot_code kode into d2 from public.claims c join public.depots d on d.id = c.depot_id
     where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and c.customer_id is not null and c.depot_id <> d1.id group by 1, 2 order by count(*) desc limit 1;

    v_nol := (select jsonb_object_agg(to_char(v_as - make_interval(months => i), 'YYYY-MM'), 0) from generate_series(0, 12) i);
    -- Toko berjumlah kecil di depot pertama dan kedua; sebagian bertagihan supaya hasilnya beragam.
    select jsonb_agg(jsonb_build_object('rowNo', z.rn + 1, 'channel', z.kode, 'customerCode', z.customer_code, 'customerName', z.customer_name, 'termFi', 'I060',
             'overdueAmt', case when z.rn % 3 = 0 then 5000 else 0 end, 'totalAmt', case when z.rn % 3 = 0 then 5000 else 0 end,
             'buckets', case when z.rn % 3 = 0 then jsonb_set(v_nol, array[to_char(v_as, 'YYYY-MM')], '5000') else v_nol end, 'bucketOlder', 0) order by z.rn)
      into v_rows
      from (select row_number() over (order by y.kode, y.customer_code) rn, y.* from (
              select distinct d.depot_code kode, cu.customer_code, cu.customer_name from public.claims c join public.depots d on d.id = c.depot_id join public.customers cu on cu.id = c.customer_id
               where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.depot_id in (d1.id, d2.id)) y limit 400) z;
    r := public.rc_zdage_stage('EXPORT_20261109_080000.xlsx', now(), (select jsonb_agg(e) from jsonb_array_elements(v_rows) with ordinality t(e, i) where i <= 200), null);
    v_id := (r->>'uploadId')::uuid;
    r := public.rc_zdage_stage('x', now(), (select jsonb_agg(e) from jsonb_array_elements(v_rows) with ordinality t(e, i) where i > 200), v_id);
    n := (select row_count from public.rc_zdage_uploads where id = v_id);
    r2 := public.rc_zdage_stage('x', now(), (select jsonb_agg(e) from jsonb_array_elements(v_rows) with ordinality t(e, i) where i > 200), v_id);
    hasil := hasil || jsonb_build_object('uji', 'Kirim ulang bagian yang sudah tersimpan: tidak ditulis dua kali, tidak ditolak',
      'lulus', r2->>'status' = 'success' and (r2->>'diterima')::int = 0 and (select row_count from public.rc_zdage_uploads where id = v_id) = n, 'rinci', n::text);

    -- Pratinjau bertahap = pratinjau sekaligus.
    r := public.rc_zdage_preview(v_id, '{}');
    m := public.rc_zdage_preview_awal(v_id, '{}');
    v_baris := '[]';
    for d1 in select b->>'kode' kode from jsonb_array_elements(m->'bagian') b loop
      v_baris := v_baris || (public.rc_zdage_preview_bagian(v_id, '{}', d1.kode)->'rows');
    end loop;
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau bertahap per depot = pratinjau sekaligus',
      'lulus', v_baris = r->'rows' and jsonb_array_length(v_baris) > 0 and m->'depotTidakAda' = r->'depotTidakAda' and m->'upload' = r->'upload' and m->'galat' = r->'galat'
           and (m->>'totalBeda') = (r->>'totalBeda') and not (m ? 'rows'), 'rinci', jsonb_array_length(v_baris) || ' klaim, ' || jsonb_array_length(m->'bagian') || ' depot');

    -- Terapkan bertahap, terputus di tengah, lalu dilanjutkan.
    m := public.rc_zdage_apply_mulai(v_id, '{}');
    v_kode := m->'bagian'->0->>'kode';
    hasil := hasil || jsonb_build_object('uji', 'Mulai: status menerapkan, belum ada tawaran', 'lulus', (select status from public.rc_zdage_uploads where id = v_id) = 'menerapkan' and not exists (select 1 from public.rc_clearing_offers), 'rinci', jsonb_array_length(m->'bagian') || ' depot');
    r2 := public.rc_zdage_apply_bagian(v_id, v_kode);
    n := (select count(*) from public.rc_clearing_offers); n2 := (select count(*) from public.rc_zdage_hasil);
    begin perform public.rc_zdage_apply_selesai(v_id); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Selesai ditolak bila masih ada depot', 'lulus', v_galat ~ 'belum diterapkan', 'rinci', v_galat);
    m := public.rc_zdage_apply_bagian(v_id, v_kode);
    hasil := hasil || jsonb_build_object('uji', 'Depot yang selesai tidak dikerjakan dua kali',
      'lulus', (m->>'sudah')::boolean and (select count(*) from public.rc_clearing_offers) = n and (select count(*) from public.rc_zdage_hasil) = n2 and (m->>'tawaranBaru') = (r2->>'tawaranBaru'), 'rinci', 'tawaran ' || n);
    r2 := public.rc_zdage_riwayat();
    hasil := hasil || jsonb_build_object('uji', 'Riwayat menyebut penerapan yang terhenti', 'lulus', r2->'belumSelesai'->0->>'id' = v_id::text and (r2->'belumSelesai'->0->>'selesai')::int = 1, 'rinci', (r2->'belumSelesai')::text);
    m := public.rc_zdage_apply_mulai(v_id, '{}');
    hasil := hasil || jsonb_build_object('uji', 'Lanjutkan: daftar depot selesai ikut', 'lulus', m->'selesai' = jsonb_build_array(v_kode), 'rinci', (m->'selesai')::text);
    for d1 in select b->>'kode' kode from jsonb_array_elements(m->'bagian') b loop
      perform public.rc_zdage_apply_bagian(v_id, d1.kode);
    end loop;
    r2 := public.rc_zdage_apply_selesai(v_id);
    hasil := hasil || jsonb_build_object('uji', 'Selesai: hasil = hitungan pratinjau, applied, satu Log Activity, data depot tercatat',
      'lulus', (r2->>'tawaranBaru')::int = ((r->'ringkasan')->>'lunas')::int and (r2->>'gagal') = ((r->'ringkasan')->>'gagal') and (r2->>'dinilai') = ((r->'ringkasan')->>'total')
           and (r2->>'tawaranBaru')::int = (select count(*) from public.rc_clearing_offers where upload_id = v_id)
           and (select status = 'applied' and progres is null from public.rc_zdage_uploads where id = v_id)
           and (select count(*) from public.activity_logs a where a.event_type = 'zdage_offer' and a.details->>'uploadId' = v_id::text) = 1
           and (select count(distinct depot_id) from public.rc_zdage_depot_data where upload_id = v_id) = (select count(distinct depot_id) from public.rc_zdage_rows where upload_id = v_id and depot_id is not null),
      'rinci', r2->>'message');
    r2 := public.rc_zdage_apply_selesai(v_id);
    hasil := hasil || jsonb_build_object('uji', 'Selesai ulang idempoten', 'lulus', (r2->>'sudahDiterapkan')::boolean, 'rinci', r2->>'message');

    -- Berkas baru menutup penerapan lama yang terhenti.
    r := public.rc_zdage_stage('EXPORT_20261109_090000.xlsx', now(), v_rows, null); v_id := (r->>'uploadId')::uuid;
    m := public.rc_zdage_apply_mulai(v_id, '{}');
    perform public.rc_zdage_apply_bagian(v_id, m->'bagian'->0->>'kode');
    r := public.rc_zdage_stage('EXPORT_20261109_100000.xlsx', now(), v_rows, null); v_id2 := (r->>'uploadId')::uuid;
    hasil := hasil || jsonb_build_object('uji', 'Berkas baru tidak menghapus baris penerapan yang terhenti', 'lulus', (select count(*) from public.rc_zdage_rows where upload_id = v_id) = jsonb_array_length(v_rows), 'rinci', '-');
    m := public.rc_zdage_apply_mulai(v_id2, '{}');
    hasil := hasil || jsonb_build_object('uji', 'Berkas baru menutup yang terhenti: applied, hasil sebagian, tercatat',
      'lulus', (select u.status = 'applied' and (u.hasil->>'terhenti')::boolean from public.rc_zdage_uploads u where u.id = v_id)
           and exists (select 1 from public.activity_logs a where a.event_type = 'zdage_offer' and a.details->>'uploadId' = v_id::text and a.details->>'detail' ~ 'terhenti'), 'rinci', '-');
    begin perform public.rc_zdage_apply_bagian(v_id, m->'bagian'->0->>'kode'); v_galat := 'lolos'; exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Penerapan yang ditutup tidak bisa dilanjutkan', 'lulus', v_galat ~ 'tidak sedang diterapkan', 'rinci', v_galat);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok Upload Debtor berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_ef(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_ef order by urut;
