-- ==========================================================================================
-- Uji migrasi 20261163160000: digit kejadian pada nomor batch + tautan Customer Master
-- ==========================================================================================
-- Sebagai System Manager dengan peran authenticated, memanggil fungsi yang sama dengan layar.
-- Setiap uji di subtransaksi yang DIBATALKAN (UJI_SELESAI); hasil dikumpulkan di variabel lalu
-- dicatat di akhir. Email pengajuan dimatikan di dalam uji; antrean email lain ikut batal.
-- Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_batch_kejadian_dan_tautan_master.sql
-- ==========================================================================================
create temp table if not exists _hasil_160(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_160;

do $uji$
declare v_sm uuid; s text; hasil jsonb := '[]'; hari date := (now() at time zone 'Asia/Jakarta')::date;
  a record; b record; x record; c1 public.claims%rowtype; c2 public.claims%rowtype; r jsonb; n integer;
  v_harap text; v_dapat text; v_kode text; v_cust uuid; v_lama text; v_lama2 text; v_dep text;
  procedure_ok boolean;
begin
  select id, suffix_num into v_sm, s from public.profiles
   where role = 'system manager' and status = 'active' and not must_change_password and suffix_num ~ '^[0-9]{3}$'
   order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- ---- A1. next_batch melompati nomor yang variannya sudah terpakai --------------------------
  begin
    select coalesce(max(counter), 0) into n from rc_private.batch_counters where stage = '02' and suffix = s and business_date = hari;
    v_harap := '02' || s || to_char(hari, 'DDMMYY') || lpad((n + 1)::text, 4, '0');
    update public.claims set batch_claim = '3' || substr(v_harap, 2)
     where id = (select id from public.claims where customer_id is not null and archived_at is null order by no_doc limit 1);
    v_dapat := rc_private.next_batch('02');
    hasil := hasil || jsonb_build_array(jsonb_build_array('next_batch melompati nomor yang variannya (3...) sudah dipakai',
      v_dapat = '02' || s || to_char(hari, 'DDMMYY') || lpad((n + 2)::text, 4, '0'),
      format('terpakai %s, terbit %s', '3' || substr(v_harap, 2), v_dapat)));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('next_batch varian', false, sqlerrm)); end if;
  end;

  -- ---- A2. Amend lalu Release bersama dokumen biasa: 12... dan 02... dengan urutan sama ------
  select c.id, c.no_doc, c.version_no, c.cb_net, c.batch_upload into a
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status <> 'inactive'
   where c.status = 'approved' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null
     and c.batch_event_code = '0' and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('transfer', 'cn')
   order by c.no_doc limit 1;
  select c.id, c.no_doc, c.version_no into b
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status <> 'inactive'
   where c.status = 'approved' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null
     and c.batch_event_code = '0' and c.id <> a.id
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('transfer', 'cn')
   order by c.no_doc limit 1;
  if a.id is null or b.id is null then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Amend + Release campuran', true, 'dilewati: kurang dari 2 dokumen Approved non-Rebate'));
  else
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      execute 'set local role authenticated';
      perform public.rc_amend_doc(jsonb_build_array(jsonb_build_object('noDoc', a.no_doc, 'cbNet', (a.cb_net + 1)::text,
        'versionNo', a.version_no, 'alasan', 'Uji kode batch')), 'Uji kode batch');
      r := public.rc_process_claims('release', jsonb_build_array(
        jsonb_build_object('no_doc', a.no_doc, 'version_no', a.version_no + 1),
        jsonb_build_object('no_doc', b.no_doc, 'version_no', b.version_no)), gen_random_uuid(), '');
      execute 'reset role';
      select * into c1 from public.claims where id = a.id;
      select * into c2 from public.claims where id = b.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Amend memberi kode 1; Release berikutnya 12..., dokumen biasa 02..., urutan sama',
        c1.batch_event_code = '1' and c1.batch_release ~ '^12' and c2.batch_release ~ '^02'
          and substr(c1.batch_release, 2) = substr(c2.batch_release, 2) and length(c1.batch_release) = 15,
        format('%s: %s / %s: %s', c1.no_doc, c1.batch_release, c2.no_doc, c2.batch_release)));
      hasil := hasil || jsonb_build_array(jsonb_build_array('Batch sebelumnya tidak berubah (batch Submit dokumen yang di-Amend)',
        c1.batch_upload is not distinct from a.batch_upload, format('Submit %s -> %s', a.batch_upload, c1.batch_upload)));
      hasil := hasil || jsonb_build_array(jsonb_build_array('Hasil proses menyebut kedua batch; riwayat per dokumen memakai batch dokumennya',
        r->>'batch' = c2.batch_release || ', ' || c1.batch_release
          and exists(select 1 from public.claim_status_history h where h.claim_id = a.id and h.action = 'release' and h.batch = c1.batch_release)
          and exists(select 1 from public.claim_status_history h where h.claim_id = b.id and h.action = 'release' and h.batch = c2.batch_release)
          and (select bool_and(p ? 'batch') from jsonb_array_elements(r->'processed') p),
        'batch hasil: ' || coalesce(r->>'batch', '-')));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then
      hasil := hasil || jsonb_build_array(jsonb_build_array('Amend + Release campuran', false, sqlerrm)); end if;
    end;
  end if;

  -- ---- A3. Reprocessing lalu pengajuan ulang: 21... ------------------------------------------
  select c.id, c.no_doc, c.cb_net into x
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status <> 'inactive'
    join public.customers cu on cu.id = c.customer_id
   where c.status = 'on_hold' and c.archived_at is null and c.pending_approval is null
     and (cu.npwp is not null or cu.ktp is not null)
     and (rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'transfer'
          or (cu.account_number is not null and cu.account_name is not null and cu.bank is not null))
   order by c.no_doc limit 1;
  if x.id is null then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Reprocessing lalu Submit', true, 'dilewati: tidak ada dokumen On Hold yang lengkap'));
  else
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      execute 'set local role authenticated';
      perform public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', x.no_doc,
        'totalCashback', trunc(x.cb_net)::text, 'alasan', 'Uji kode batch')), '');
      execute 'reset role';
      select * into c1 from public.claims where id = x.id;
      v_kode := c1.batch_event_code;
      execute 'set local role authenticated';
      r := public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
      execute 'reset role';
      select * into c1 from public.claims where id = x.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Reprocessing memberi kode 2; batch Submit berikutnya 21...',
        v_kode = '2' and c1.batch_upload ~ ('^21' || s), format('%s: kode %s, Submit %s (%s)', c1.no_doc, v_kode, c1.batch_upload, c1.status)));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then
      hasil := hasil || jsonb_build_array(jsonb_build_array('Reprocessing lalu Submit', false, sqlerrm)); end if;
    end;
  end if;

  -- ---- A4. Jenis CB diganti saat Submit: 41..., dokumen lain di proses sama 01... --------------
  select c.id, c.no_doc, c.version_no into a
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status <> 'inactive'
    join public.customers cu on cu.id = c.customer_id
   where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.batch_event_code = '0'
     and (cu.npwp is not null or cu.ktp is not null) and rc_private.jenis_efektif(ca.cashback_type) = 'transfer'
     and coalesce(c.cashback_type_override, '') = ''
   order by c.no_doc limit 1;
  select c.id, c.no_doc, c.version_no into b
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status <> 'inactive'
    join public.customers cu on cu.id = c.customer_id
   where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.batch_event_code = '0'
     and (cu.npwp is not null or cu.ktp is not null) and rc_private.jenis_efektif(ca.cashback_type) = 'cn'
     and coalesce(c.cashback_type_override, '') = '' and c.id <> a.id
   order by c.no_doc limit 1;
  if a.id is null or b.id is null then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Ganti Jenis CB saat Submit', true, 'dilewati: tidak ada pasangan dokumen Not Yet Transfer + CN'));
  else
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      execute 'set local role authenticated';
      r := public.rc_process_claims('submit', jsonb_build_array(
        jsonb_build_object('no_doc', a.no_doc, 'version_no', a.version_no, 'jenis_cashback', 'CN'),
        jsonb_build_object('no_doc', b.no_doc, 'version_no', b.version_no)), gen_random_uuid(), '');
      execute 'reset role';
      select * into c1 from public.claims where id = a.id;
      select * into c2 from public.claims where id = b.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Jenis CB diganti: batch Submit proses itu 41..., dokumen biasa 01..., urutan sama',
        c1.batch_event_code = '4' and c1.cashback_type_changed and c1.batch_upload ~ '^41' and c2.batch_upload ~ '^01'
          and substr(c1.batch_upload, 2) = substr(c2.batch_upload, 2) and c2.batch_event_code = '0',
        format('%s: %s (kode %s) / %s: %s', c1.no_doc, c1.batch_upload, c1.batch_event_code, c2.no_doc, c2.batch_upload)));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then
      hasil := hasil || jsonb_build_array(jsonb_build_array('Ganti Jenis CB saat Submit', false, sqlerrm)); end if;
    end;
  end if;

  -- ---- A5/A6. Expired lewat Posting Exception: 34..., dengan dan tanpa approval ---------------
  select c.id, c.no_doc, c.version_no, c.batch_upload into x
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null
   order by c.no_doc limit 1;
  foreach procedure_ok in array array[false, true] loop
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', to_jsonb(procedure_ok))
        on conflict (kunci) do update set nilai = excluded.nilai;
      execute 'set local role authenticated';
      r := public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', x.no_doc)), 'Uji kode batch');
      if procedure_ok then
        execute 'reset role';
        select * into c1 from public.claims where id = x.id;
        execute 'set local role authenticated';
        perform public.rc_process_claims('approve_hold', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
      end if;
      execute 'reset role';
      select * into c1 from public.claims where id = x.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Expired ' || case when procedure_ok then 'lewat approval On Hold & Expired' else 'langsung (approval mati)' end || ': batch 34..., kode 3',
        c1.status = 'expired' and c1.batch_clearing ~ ('^34' || s) and c1.batch_event_code = '3'
          and c1.batch_upload is not distinct from x.batch_upload,
        format('%s: %s, Clearing %s, kode %s', c1.no_doc, c1.status, c1.batch_clearing, c1.batch_event_code)));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then
      hasil := hasil || jsonb_build_array(jsonb_build_array('Expired Posting Exception approval=' || procedure_ok, false, sqlerrm)); end if;
    end;
  end loop;

  -- ---- A7. Expired dari Claim Process: 34... -------------------------------------------------
  select c.id, c.no_doc, c.version_no, c.batch_release into x
    from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'released' and c.archived_at is null and c.pending_approval is null and c.customer_id is not null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) <> 'rebate'
   order by c.no_doc limit 1;
  if x.id is null then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Expired dari Claim Process', true, 'dilewati: tidak ada dokumen Released non-Rebate'));
  else
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      execute 'set local role authenticated';
      perform public.rc_process_claims('expire_claim_process', jsonb_build_array(jsonb_build_object('no_doc', x.no_doc, 'version_no', x.version_no)), gen_random_uuid(), 'Uji kode batch');
      execute 'reset role';
      select * into c1 from public.claims where id = x.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Expired dari Claim Process: batch 34..., batch Release tetap',
        c1.status = 'expired' and c1.batch_clearing ~ ('^34' || s) and c1.batch_event_code = '3' and c1.batch_release is not distinct from x.batch_release,
        format('%s: Clearing %s, Release %s', c1.no_doc, c1.batch_clearing, c1.batch_release)));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then
      hasil := hasil || jsonb_build_array(jsonb_build_array('Expired dari Claim Process', false, sqlerrm)); end if;
    end;
  end if;

  -- ---- B. Tautan Customer Master -------------------------------------------------------------
  select c.id, c.no_doc, c.version_no, d.depot_code into x
    from public.claims c join public.depots d on d.id = c.depot_id and d.archived_at is null
    join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'not_yet' and c.archived_at is null and c.customer_id is not null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('transfer', 'cn')
     and coalesce(ca.tax_status, '') !~* 'non'
   order by c.no_doc limit 1;
  v_lama := 'UJI160' || to_char(clock_timestamp(), 'HH24MISSMS');

  -- B1. Simpan lewat unggah Customer Master (fungsi yang sama dengan layar).
  begin
    update public.claims set customer_id = null, source_customer_code = v_lama, gross_up = null, tax_subject = null,
      master_data_issue = 'Customer Master tidak ditemukan: ' || v_lama where id = x.id;
    select count(*) into n from public.activity_logs where event_type = 'customer_master_linked';
    execute 'set local role authenticated';
    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', lower(v_lama), 'custName', 'Toko Uji 160',
      'kodeDepot', x.depot_code, 'npwp', '01.234.567.8-901.000')));
    execute 'reset role';
    select * into c1 from public.claims where id = x.id;
    select id into v_cust from public.customers where customer_code = v_lama;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Unggah Customer Master menautkan dokumen yang tadinya tanpa master',
      c1.customer_id = v_cust and c1.master_data_issue is null and c1.tax_subject = 'Badan' and c1.gross_up is not null
        and c1.version_no = x.version_no + 1,
      format('%s: customer %s, subyek %s, gross up %s, versi %s->%s', c1.no_doc, case when c1.customer_id = v_cust then 'tertaut' else 'KOSONG' end,
        c1.tax_subject, c1.gross_up, x.version_no, c1.version_no)));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Tautan tercatat: riwayat dokumen + satu baris Log Activity',
      exists(select 1 from public.claim_status_history h where h.claim_id = x.id and h.action = 'customer_master_linked' and h.actor_id = v_sm)
        and (select count(*) from public.activity_logs where event_type = 'customer_master_linked') = n + 1
        and exists(select 1 from public.activity_logs where event_type = 'customer_master_linked' and actor_id = v_sm and (details->>'jumlah')::int = 1),
      'log ' || ((select count(*) from public.activity_logs where event_type = 'customer_master_linked') - n) || ' baris'));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Tautan lewat unggah Customer Master', false, sqlerrm)); end if;
  end;

  -- B2. Periksa (tanpa simpan) tidak menautkan.
  begin
    update public.claims set customer_id = null, source_customer_code = v_lama where id = x.id;
    execute 'set local role authenticated';
    r := public.rc_customer_upsert_periksa(jsonb_build_array(jsonb_build_object('custCode', v_lama, 'custName', 'Toko Uji 160',
      'kodeDepot', x.depot_code, 'npwp', '01.234.567.8-901.000')));
    execute 'reset role';
    select * into c1 from public.claims where id = x.id;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Periksa unggahan tidak menyimpan apa pun, termasuk tautan',
      c1.customer_id is null and not exists(select 1 from public.customers where customer_code = v_lama) and (r->>'periksa')::boolean,
      format('periksa %s, dokumen %s', r->>'periksa', case when c1.customer_id is null then 'tetap tanpa master' else 'TERTAUT' end)));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Periksa unggahan', false, sqlerrm)); end if;
  end;

  -- B3. Master terarsip tidak menautkan; dipulihkan lalu menautkan. Nilai yang ada tidak ditimpa.
  begin
    update public.claims set customer_id = null, source_customer_code = v_lama, tax_subject = 'Perorangan', gross_up = 123 where id = x.id;
    insert into public.customers(customer_code, customer_name, npwp, archived_at) values (v_lama, 'Toko Uji 160', '01.234.567.8-901.000', now())
      returning id into v_cust;
    select * into c1 from public.claims where id = x.id;
    v_lama2 := case when c1.customer_id is null then 'tetap tanpa master' else 'TERTAUT' end;
    update public.customers set archived_at = null where id = v_cust;
    select * into c1 from public.claims where id = x.id;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Master terarsip tidak menautkan; dipulihkan menautkan; Subyek/Gross Up yang ada tetap',
      v_lama2 = 'tetap tanpa master' and c1.customer_id = v_cust and c1.tax_subject = 'Perorangan' and c1.gross_up = 123,
      format('saat arsip: %s; sesudah pulih: %s, subyek %s, gross up %s', v_lama2,
        case when c1.customer_id = v_cust then 'tertaut' else 'KOSONG' end, c1.tax_subject, c1.gross_up)));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Master terarsip / dipulihkan', false, sqlerrm)); end if;
  end;

  -- B4. Seluruh data: tidak ada dokumen tanpa master yang masternya sebenarnya ada.
  select count(*) into n from public.claims c
   where c.customer_id is null
     and exists(select 1 from public.customers cu where upper(btrim(cu.customer_code)) = upper(btrim(c.source_customer_code)) and cu.archived_at is null);
  hasil := hasil || jsonb_build_array(jsonb_build_array('Seluruh data: tidak ada dokumen "Customer Master belum ada" yang masternya ada',
    n = 0, n || ' dokumen; ' || (select count(*) from public.claims where customer_id is null) || ' dokumen memang belum punya master'));
  select count(*) into n from public.claims where status = 'expired' and batch_event_code not in ('3', '1');
  hasil := hasil || jsonb_build_array(jsonb_build_array('Seluruh data: setiap dokumen Expired berkode 3 (atau 1 bila di-Amend sesudahnya)', n = 0,
    n || ' dokumen menyimpang; ' || (select count(*) from public.claims where status = 'expired' and batch_event_code = '3') || ' berkode 3, '
      || (select count(*) from public.claims where status = 'expired' and batch_event_code = '1') || ' berkode 1, dari '
      || (select count(*) from public.claims where status = 'expired') || ' Expired'));

  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_160(uji, lulus, rinci) select h->>0, (h->>1)::boolean, h->>2 from jsonb_array_elements(hasil) h;
end
$uji$;

select (select count(*) filter (where lulus) || '/' || count(*) from _hasil_160) skor, urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci
  from _hasil_160 order by urut;
