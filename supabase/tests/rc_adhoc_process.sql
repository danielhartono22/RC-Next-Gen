-- ==========================================================================================
-- Uji Jenis CB Others dan Ad-Hoc Process - migrasi 20261163440000
-- ==========================================================================================
-- Alur dijalankan sungguhan lalu DIBATALKAN (UJI_SELESAI): Submit berjenis Others -> approval
-- (bila aktif) -> antrean Ad-Hoc -> proses massal ke Claim to Finance / Clearing / Done, Reject.
--
--   node scripts/apply-sql.mjs --env dev supabase/tests/rc_adhoc_process.sql
-- ==========================================================================================
create temp table if not exists _hasil_adhoc(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_adhoc;

-- Klaim di Open (lunas / dipindah dari Restricted) saja yang dapat diajukan (20261163170000).
-- Lingkungan yang belum memiliki Restricted/Open (prod sebelum 170000) tidak memerlukannya.
create or replace function pg_temp.uji_buka(p_no_docs text[]) returns void language plpgsql as $f$
begin
  if to_regclass('public.rc_clearing_offers') is null then return; end if;
  execute $q$insert into public.rc_clearing_offers(claim_id, result, reason, deadline_at, status)
    select c.id, 'RESTRICTED', '{"uji": true}'::jsonb, null, 'offered' from public.claims c where c.no_doc = any($1)
    on conflict (claim_id) where status in ('offered','overdue') do nothing$q$ using p_no_docs;
end $f$;
-- {no_doc, version_no} sesuai versi sekarang, ditambah isian lain per dokumen.
create or replace function pg_temp.butir(p_doc text, p_tambah jsonb default '{}') returns jsonb language sql as $f$
  select jsonb_build_object('no_doc', c.no_doc, 'version_no', c.version_no) || p_tambah from public.claims c where c.no_doc = p_doc;
$f$;
create or replace function pg_temp.coba_adhoc(p_items jsonb) returns text language plpgsql as $f$
begin perform public.rc_adhoc_proses(p_items, gen_random_uuid()); return 'OK';
exception when others then return sqlerrm; end $f$;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; d text[]; r jsonb; r2 jsonb; x jsonb; v_req uuid := gen_random_uuid();
  v_err text; v_c record; v_n int; v_cb numeric; v_items jsonb; v_wf jsonb; v_ver bigint; v_osc uuid; v_spv uuid; v_adm uuid;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Enam dokumen Not Yet dari toko yang lengkap identitas dan rekeningnya, campaign aktif.
  select array_agg(no_doc order by no_doc) into d from (
    select c.no_doc from public.claims c
      join public.customers cu on cu.id = c.customer_id
       and (nullif(btrim(coalesce(cu.ktp, '')), '') is not null or nullif(btrim(coalesce(cu.npwp, '')), '') is not null)
       and nullif(btrim(coalesce(cu.account_number, '')), '') is not null and nullif(btrim(coalesce(cu.account_name, '')), '') is not null
       and nullif(btrim(coalesce(cu.bank, '')), '') is not null
      join public.campaigns ca on ca.id = c.campaign_id and ca.status = 'active'
     where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.cb_net > 1000
     order by c.cb_net, c.no_doc limit 6) q;
  if coalesce(array_length(d, 1), 0) < 6 then
    insert into _hasil_adhoc(uji, lulus, rinci) values ('Fixture', false, 'kurang dari 6 dokumen Not Yet yang memenuhi syarat');
    return;
  end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

    -- ---- Rumus, label, katalog -----------------------------------------------------------
    hasil := hasil || jsonb_build_object('uji', 'cb_label dan jenis_efektif mengenal Others',
      'lulus', rc_private.cb_label('Others') = 'Others' and rc_private.cb_label(' others ') = 'Others' and rc_private.jenis_efektif('OTHERS') = 'others', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'gross_up_adhoc: Tax Count tidak -> Net CB; Rebate x 1,11; lain Badan/Perorangan',
      'lulus', rc_private.gross_up_adhoc(1000000.9, 'Badan', 'Transfer', false) = 1000000
           and rc_private.gross_up_adhoc(1000000, 'Badan', 'Rebate', false) = 1000000
           and rc_private.gross_up_adhoc(1000000, 'Badan', 'Rebate', true) = 1110000
           and rc_private.gross_up_adhoc(1000000, 'Perorangan', 'RA07', true) = 1110000
           and rc_private.gross_up_adhoc(85000, 'Badan', 'CN', true) = 100000
           and rc_private.gross_up_adhoc(57000000, 'Perorangan', 'Voucher', true) = 60000000
           and rc_private.gross_up_adhoc(-1, 'Badan', 'CN', true) = 0,
      'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Katalog: tab adhoc.list berizin adhoc_process; peta izin rc_update_access memuatnya',
      'lulus', exists(select 1 from rc_private.tab_catalog where code = 'adhoc.list' and permission = 'adhoc_process' and key = 'adhoc')
           and exists(select 1 from public.permissions where code = 'adhoc_process')
           and pg_get_functiondef('public.rc_update_access(jsonb)'::regprocedure) ~ '\(''adhoc'',''adhoc_process''\)', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Remark: Special Claims di urutan terakhir',
      'lulus', rc_private.claim_remark_dari(null, false, true, null, null, true, true) = 'CB Type Changed, Bank Account Changed, Special Claims'
           and rc_private.claim_remark_dari(null, false, false, null, null, false, false) is null, 'rinci', '-');

    -- ---- Submit berjenis Others, lalu approval bila aktif ----------------------------------
    perform pg_temp.uji_buka(d);
    select jsonb_agg(pg_temp.butir(x2, '{"jenis_cashback":"Others"}')) into v_items from unnest(d) x2;
    r := public.rc_process_claims('submit', v_items, gen_random_uuid(), '');
    select jsonb_agg(pg_temp.butir(c.no_doc)) into v_items from public.claims c where c.no_doc = any(d) and c.status = 'submitted';
    if v_items is not null then r := public.rc_process_claims('approve', v_items, gen_random_uuid(), ''); end if;
    select count(*) into v_n from public.claims where no_doc = any(d) and status = 'approved' and jalur_adhoc and cashback_type_override = 'Others' and pending_approval is null;
    hasil := hasil || jsonb_build_object('uji', 'Submit Others: Approved, jalur Ad-Hoc, Jenis CB Others',
      'lulus', v_n = 6, 'rinci', v_n || ' dari 6; approval ' || case when rc_private.approval_aktif() then 'aktif' else 'mati' end);

    -- Antrean (sebagai authenticated, seperti layar).
    update public.claims set updated_at = now() + interval '1 minute' where no_doc = any(d);
    execute 'set local role authenticated';
    v_wf := public.rc_legacy_workflow(50, null, null);
    execute 'reset role';
    hasil := hasil || jsonb_build_object('uji', 'Antrean: Others di adhocData, tidak di Release maupun Bulk Process',
      'lulus', (select count(*) from jsonb_array_elements(v_wf->'adhocData') y where y->>'noDoc' = any(d)) = 6
           and not exists(select 1 from jsonb_array_elements(v_wf->'releaseData') y where y->>'noDoc' = any(d))
           and not exists(select 1 from jsonb_array_elements(v_wf->'bulkRebateData') y where y->>'noDoc' = any(d))
           and (select bool_and(y->>'jenisCb' = 'Others') from jsonb_array_elements(v_wf->'adhocData') y where y->>'noDoc' = any(d)),
      'rinci', 'adhocData ' || jsonb_array_length(coalesce(v_wf->'adhocData', '[]')));

    v_err := null;
    begin r := public.rc_process_claims('release', jsonb_build_array(pg_temp.butir(d[1])), gen_random_uuid(), '');
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Release menolak dokumen Others', 'lulus', coalesce(v_err, '') ~ 'Ad-Hoc Process', 'rinci', coalesce(v_err, 'tidak ditolak'));

    -- ---- Validasi ---------------------------------------------------------------------------
    v_err := pg_temp.coba_adhoc(jsonb_build_array(pg_temp.butir(d[1], '{"jenis_cb":""}')));
    hasil := hasil || jsonb_build_object('uji', 'Validasi: Jenis CB wajib', 'lulus', v_err ~ 'Jenis CB wajib', 'rinci', v_err);
    v_err := pg_temp.coba_adhoc(jsonb_build_array(pg_temp.butir(d[1], '{"jenis_cb":"Others"}')));
    hasil := hasil || jsonb_build_object('uji', 'Validasi: Jenis CB Others tidak boleh dipilih lagi', 'lulus', v_err ~ 'tidak dikenali', 'rinci', v_err);
    v_err := pg_temp.coba_adhoc(jsonb_build_array(pg_temp.butir(d[1], '{"jenis_cb":"CN","cb_net":"-5"}')));
    hasil := hasil || jsonb_build_object('uji', 'Validasi: Net CB negatif', 'lulus', v_err ~ 'tidak boleh negatif', 'rinci', v_err);
    v_err := pg_temp.coba_adhoc(jsonb_build_array(pg_temp.butir(d[1], '{"jenis_cb":"CN","cb_net":"12a"}')));
    hasil := hasil || jsonb_build_object('uji', 'Validasi: Net CB bukan angka', 'lulus', v_err ~ 'bukan angka', 'rinci', v_err);
    v_err := pg_temp.coba_adhoc(jsonb_build_array(jsonb_build_object('no_doc', d[1], 'version_no', 1, 'jenis_cb', 'CN')));
    hasil := hasil || jsonb_build_object('uji', 'Validasi: versi lama ditolak', 'lulus', v_err ~ 'berubah sejak dimuat', 'rinci', v_err);
    begin
      update public.customers set account_number = null, account_name = null, bank = null
       where id = (select customer_id from public.claims where no_doc = d[6]);
      update rc_private.claim_sensitive set account_number = null, account_name = null, bank = null
       where claim_id = (select id from public.claims where no_doc = d[6]);
      v_err := pg_temp.coba_adhoc(jsonb_build_array(pg_temp.butir(d[6], '{"jenis_cb":"Transfer"}')));
      raise exception 'BALIK';
    exception when others then if sqlerrm <> 'BALIK' then v_err := 'galat: ' || sqlerrm; end if;
    end;
    hasil := hasil || jsonb_build_object('uji', 'Validasi: Transfer tanpa rekening ditolak', 'lulus', v_err ~ 'memerlukan Nomor Rekening', 'rinci', v_err);

    -- ---- Proses massal (sebagai authenticated) ---------------------------------------------
    select cb_net into v_cb from public.claims where no_doc = d[2];
    v_items := jsonb_build_array(
      pg_temp.butir(d[1], '{"jenis_cb":"CN","pajak":true,"lanjut_claim":true,"lanjut_clearing":false}'),
      pg_temp.butir(d[2], '{"jenis_cb":"rebate","pajak":true,"lanjut_claim":false,"lanjut_clearing":true}'),
      pg_temp.butir(d[3], '{"jenis_cb":"Voucher","pajak":false,"cb_net":"1234567.89"}'),
      pg_temp.butir(d[4], '{"jenis_cb":"Rebate","pajak":false,"lanjut_claim":true,"lanjut_clearing":true}'),
      pg_temp.butir(d[5], '{"jenis_cb":"Transfer","pajak":true}'));
    execute 'set local role authenticated';
    r := public.rc_adhoc_proses(v_items, v_req);
    execute 'reset role';
    hasil := hasil || jsonb_build_object('uji', 'Proses: 2 ke Claim to Finance, 1 ke Clearing, 2 langsung Done, satu batch',
      'lulus', (r->>'count')::int = 5 and (r->>'keClaim')::int = 2 and (r->>'keClearing')::int = 1 and (r->>'done')::int = 2 and coalesce(r->>'batch', '') <> '',
      'rinci', (r - 'processed')::text);

    select c.status, c.cashback_type_override j, c.gross_up, c.cb_net, c.tax_subject, c.batch_release, c.batch_claim, c.adhoc_lanjut, c.adhoc_pajak into v_c from public.claims c where no_doc = d[1];
    hasil := hasil || jsonb_build_object('uji', 'CN + Tax Count + Proceed to Claim -> Released, gross Badan/Perorangan',
      'lulus', v_c.status = 'released' and v_c.j = 'CN' and v_c.gross_up = rc_private.gross_claimed(v_c.cb_net, v_c.tax_subject, null)
           and v_c.batch_release is not null and v_c.batch_claim is null and v_c.adhoc_lanjut = 'claim' and v_c.adhoc_pajak,
      'rinci', row_to_json(v_c)::text);
    select c.status, c.cashback_type_override j, c.gross_up, c.cb_net, c.batch_release, c.batch_claim, c.batch_clearing, c.claimed_at into v_c from public.claims c where no_doc = d[2];
    hasil := hasil || jsonb_build_object('uji', 'Rebate + Tax Count + hanya Clearing -> Claimed, gross x 1,11',
      'lulus', v_c.status = 'claimed' and v_c.j = 'Rebate' and v_c.gross_up = trunc(v_cb * 1.11) and v_c.batch_claim = v_c.batch_release
           and v_c.batch_clearing is null and v_c.claimed_at is not null,
      'rinci', row_to_json(v_c)::text);
    select c.status, c.cashback_type_override j, c.gross_up, c.cb_net, c.cleared_at, c.batch_clearing, c.batch_release, rc_private.claim_remark(c) remark into v_c from public.claims c where no_doc = d[3];
    hasil := hasil || jsonb_build_object('uji', 'Voucher tanpa centang -> Done, Net CB copas dipotong, gross = Net CB, remark Special Claims',
      'lulus', v_c.status = 'done' and v_c.j = 'Voucher' and v_c.cb_net = 1234567 and v_c.gross_up = 1234567 and v_c.cleared_at is not null
           and v_c.batch_clearing = v_c.batch_release and v_c.remark ~ 'Special Claims',
      'rinci', row_to_json(v_c)::text);
    select c.status, c.cashback_type_override j, c.gross_up, c.cb_net, rc_private.claim_remark(c) remark into v_c from public.claims c where no_doc = d[4];
    hasil := hasil || jsonb_build_object('uji', 'Rebate tanpa Tax Count, Claim + Clearing -> Released (Claim to Finance dulu), gross = Net CB, tanpa Special Claims',
      'lulus', v_c.status = 'released' and v_c.j = 'Rebate' and v_c.gross_up = v_c.cb_net and coalesce(v_c.remark, '') !~ 'Special Claims',
      'rinci', row_to_json(v_c)::text);
    select c.status, c.cashback_type_override j, s.account_number, s.bank into v_c from public.claims c left join rc_private.claim_sensitive s on s.claim_id = c.id where c.no_doc = d[5];
    hasil := hasil || jsonb_build_object('uji', 'Transfer -> Done, rekening dokumen terisi',
      'lulus', v_c.status = 'done' and v_c.j = 'Transfer' and coalesce(v_c.account_number, '') <> '' and coalesce(v_c.bank, '') <> '',
      'rinci', row_to_json(v_c)::text);
    hasil := hasil || jsonb_build_object('uji', 'Riwayat memakai tahap biasa: Release / Claim / Clearing sesuai hasil',
      'lulus', (select string_agg(h.action, ',' order by h.id) from public.claim_status_history h join public.claims c on c.id = h.claim_id
                 where c.no_doc = d[1] and h.reason like 'Ad-Hoc Process:%') = 'release'
           and (select string_agg(h.action, ',' order by h.id) from public.claim_status_history h join public.claims c on c.id = h.claim_id
                 where c.no_doc = d[3] and h.reason like 'Ad-Hoc Process:%') = 'release,claim,clearing',
      'rinci', '-');
    select count(*) into v_n from public.activity_logs where event_type = 'adhoc_process' and created_at = now();
    hasil := hasil || jsonb_build_object('uji', 'Log Activity satu baris per proses', 'lulus', v_n = 1, 'rinci', v_n || ' baris');

    -- Kirim ulang dengan request ID yang sama: hasil tersimpan, tidak diproses dua kali.
    select version_no into v_ver from public.claims where no_doc = d[1];
    execute 'set local role authenticated';
    r2 := public.rc_adhoc_proses(v_items, v_req);
    execute 'reset role';
    hasil := hasil || jsonb_build_object('uji', 'Request ID sama -> hasil yang sama, tanpa proses ulang',
      'lulus', r2 = r and (select version_no from public.claims where no_doc = d[1]) = v_ver, 'rinci', '-');

    v_err := pg_temp.coba_adhoc(jsonb_build_array(pg_temp.butir(d[1], '{"jenis_cb":"CN"}')));
    hasil := hasil || jsonb_build_object('uji', 'Dokumen yang sudah keluar dari antrean ditolak', 'lulus', v_err ~ 'tidak ada di antrean', 'rinci', v_err);

    -- ---- Sesudah Ad-Hoc -------------------------------------------------------------------
    update public.claims set updated_at = now() + interval '1 minute' where no_doc = any(d);
    execute 'set local role authenticated';
    v_wf := public.rc_legacy_workflow(50, null, null);
    x := public.rc_legacy_dashboard(50, null, null);
    execute 'reset role';
    hasil := hasil || jsonb_build_object('uji', 'Antrean: Rebate jalur Ad-Hoc di Claim to Finance / Clearing, tidak di Bulk Process',
      'lulus', exists(select 1 from jsonb_array_elements(v_wf->'claimFinData') y where y->>'noDoc' = d[4])
           and exists(select 1 from jsonb_array_elements(v_wf->'claimFinData') y where y->>'noDoc' = d[1])
           and exists(select 1 from jsonb_array_elements(v_wf->'clearingData') y where y->>'noDoc' = d[2])
           and not exists(select 1 from jsonb_array_elements(v_wf->'bulkRebateData') y where y->>'noDoc' = any(d))
           and (select count(*) from jsonb_array_elements(v_wf->'adhocData') y where y->>'noDoc' = any(d)) = 1,
      'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Analytics: remark Special Claims pada dokumen langsung Done',
      'lulus', (select y->>'remark' from jsonb_array_elements(x->'history') y where y->>'noDoc' = d[3]) ~ 'Special Claims'
           and coalesce((select y->>'remark' from jsonb_array_elements(x->'history') y where y->>'noDoc' = d[1]), '') !~ 'Special Claims',
      'rinci', coalesce((select y->>'remark' from jsonb_array_elements(x->'history') y where y->>'noDoc' = d[3]), 'tidak ditemukan'));
    hasil := hasil || jsonb_build_object('uji', 'Report (rc_report_rows): Gross Up dokumen Ad-Hoc = yang tersimpan',
      'lulus', not exists(select 1 from public.rc_report_rows v join public.claims c on c.id = v.id
                           where c.no_doc = any(d[1:5]) and v.gross_claimed is distinct from c.gross_up)
           and (select v.gross_claimed from public.rc_report_rows v join public.claims c on c.id = v.id where c.no_doc = d[4])
               = (select cb_net from public.claims where no_doc = d[4]),
      'rinci', '-');

    -- Claim to Finance memproses Rebate jalur Ad-Hoc; Bulk Process menolaknya.
    v_err := null;
    begin r2 := public.rc_process_claims('claim', jsonb_build_array(pg_temp.butir(d[4])), gen_random_uuid(), '');
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Posting Claim: Rebate jalur Ad-Hoc diterima',
      'lulus', v_err is null and (select status from public.claims where no_doc = d[4]) = 'claimed', 'rinci', coalesce(v_err, 'claimed'));
    v_err := null;
    begin r2 := public.rc_process_claims('bulk_rebate', jsonb_build_array(pg_temp.butir(d[4])), gen_random_uuid(), '');
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Bulk Process menolak dokumen jalur Ad-Hoc', 'lulus', coalesce(v_err, '') ~ 'Ad-Hoc Process', 'rinci', coalesce(v_err, 'tidak ditolak'));

    -- Amend dokumen Ad-Hoc memakai Tax Count-nya (tidak dicentang -> gross = Net CB baru).
    r2 := public.rc_amend_doc(jsonb_build_array(jsonb_build_object('noDoc', d[4], 'cbNet', '777777', 'alasan', 'uji')), '');
    hasil := hasil || jsonb_build_object('uji', 'Amend Doc dokumen Ad-Hoc: gross mengikuti Tax Count',
      'lulus', (select gross_up from public.claims where no_doc = d[4]) = 777777, 'rinci', (select gross_up::text from public.claims where no_doc = d[4]));

    -- ---- Reject ---------------------------------------------------------------------------
    v_err := null;
    begin r2 := public.rc_adhoc_tolak(jsonb_build_array(pg_temp.butir(d[6])), gen_random_uuid(), ' ');
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Reject tanpa alasan ditolak', 'lulus', coalesce(v_err, '') ~ 'Reason required', 'rinci', coalesce(v_err, 'tidak ditolak'));
    execute 'set local role authenticated';
    r2 := public.rc_adhoc_tolak(jsonb_build_array(pg_temp.butir(d[6])), gen_random_uuid(), 'uji reject');
    execute 'reset role';
    select c.status, c.cashback_type_override j, c.batch_upload, c.approved_at, c.adhoc_at,
           (select h.action from public.claim_status_history h where h.claim_id = c.id order by h.id desc limit 1) aksi into v_c
      from public.claims c where no_doc = d[6];
    hasil := hasil || jsonb_build_object('uji', 'Reject -> Not Yet berjenis Others, batch upload dikosongkan, riwayat reject_adhoc',
      'lulus', v_c.status = 'not_yet' and v_c.j = 'Others' and v_c.batch_upload is null and v_c.approved_at is null and v_c.adhoc_at is null and v_c.aksi = 'reject_adhoc',
      'rinci', row_to_json(v_c)::text);

    -- Diajukan ulang dengan jenis biasa -> keluar dari jalur Ad-Hoc.
    perform pg_temp.uji_buka(array[d[6]]);
    r2 := public.rc_process_claims('submit', jsonb_build_array(pg_temp.butir(d[6], '{"jenis_cashback":"CN"}')), gen_random_uuid(), '');
    hasil := hasil || jsonb_build_object('uji', 'Pengajuan ulang berjenis CN: jalur Ad-Hoc dilepas',
      'lulus', not (select jalur_adhoc from public.claims where no_doc = d[6]), 'rinci', (select status from public.claims where no_doc = d[6]));

    -- ---- Bawaan peran OSC dan Supervisor (20261163450000) ---------------------------------
    select p.id into v_osc from public.profiles p where p.role = 'osc' and p.status = 'active' and not p.must_change_password
       and not exists(select 1 from rc_private.user_tab_access u where u.user_id = p.id and u.tab_code = 'adhoc.list') order by p.user_code limit 1;
    select p.id into v_spv from public.profiles p where p.role = 'supervisor' and p.status = 'active' and not p.must_change_password
       and not exists(select 1 from rc_private.user_tab_access u where u.user_id = p.id and u.tab_code = 'adhoc.list') order by p.user_code limit 1;
    select p.id into v_adm from public.profiles p where p.role = 'admin' and p.status = 'active' and not p.must_change_password
       and not exists(select 1 from public.user_permissions up where up.user_id = p.id and up.permission_code = 'adhoc_process') order by p.user_code limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Bawaan peran: OSC dan Supervisor mendapat tab Ad-Hoc; Admin Depot tanpa izin tidak',
      'lulus', v_osc is not null and coalesce((rc_private.tab_rights(v_osc)->>'adhoc.list')::boolean, false)
           and (v_spv is null or coalesce((rc_private.tab_rights(v_spv)->>'adhoc.list')::boolean, false))
           and v_adm is not null and not coalesce((rc_private.tab_rights(v_adm)->>'adhoc.list')::boolean, false),
      'rinci', format('osc %s, supervisor %s, admin %s', v_osc is not null, coalesce(v_spv::text, 'tidak ada'), v_adm is not null));
    -- Gerbang RPC: OSC lolos (galat berikutnya soal isi kiriman), Admin Depot ditolak tab.
    perform set_config('request.jwt.claims', json_build_object('sub', v_osc::text, 'role', 'authenticated')::text, true);
    v_err := pg_temp.coba_adhoc('[]'::jsonb);
    perform set_config('request.jwt.claims', json_build_object('sub', v_adm::text, 'role', 'authenticated')::text, true);
    v_err := v_err || ' / ' || pg_temp.coba_adhoc('[]'::jsonb);
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_object('uji', 'Gerbang: OSC lolos tanpa baris izin, Admin Depot tanpa tab ditolak',
      'lulus', v_err ~ '^Satu proses maksimal 500 dokumen / .*adhoc.list', 'rinci', v_err);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_adhoc(uji, lulus, rinci) select y->>'uji', (y->>'lulus')::boolean, y->>'rinci' from jsonb_array_elements(hasil) y;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_adhoc order by urut;
