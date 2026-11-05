-- ==========================================================================================
-- Uji Remark "Bank Account Changed" - migrasi 20261163400000
-- ==========================================================================================
-- Pengajuan sungguhan dijalankan di subtransaksi yang DIBATALKAN (UJI_SELESAI); status klaim,
-- master, dan antrean email ikut dibatalkan.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_remark_bank_account_changed.sql
-- ==========================================================================================
create temp table if not exists _hasil_bac(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_bac;

do $uji$
declare hasil jsonb := '[]'; r jsonb; x jsonb; v_sm uuid; k1 record; k2 record; k3 record; v_txt text; v_bool boolean; v_sql text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Tiga dokumen Not Yet yang dapat diajukan, dari tiga toko berbeda. Syarat "tampil di Open"
  -- (rc_private.boleh_open, fitur Upload Debtor) hanya dipakai bila fungsinya ada di lingkungan ini.
  v_sql := 'select cl.id, cl.no_doc, cl.version_no, cl.customer_id from public.claims cl
     join public.customers cu on cu.id = cl.customer_id join public.campaigns ca on ca.id = cl.campaign_id
    where cl.status = ''not_yet'' and cl.pending_approval is null and cl.archived_at is null
      and (coalesce(btrim(cu.npwp), '''') <> '''' or coalesce(btrim(cu.ktp), '''') <> '''') and coalesce(btrim(ca.cashback_type), '''') <> ''''
      and not (cl.customer_id = any($1))'
    || case when to_regprocedure('rc_private.boleh_open(uuid,uuid)') is not null then ' and rc_private.boleh_open(cl.id, cl.customer_id)' else '' end
    || ' order by cl.no_doc limit 1';
  execute v_sql into k1 using '{}'::uuid[];
  execute v_sql into k2 using array[k1.customer_id];
  execute v_sql into k3 using array[k1.customer_id, k2.customer_id];

  begin
    hasil := hasil || jsonb_build_object('uji', 'Remark: "Bank Account Changed" ditambahkan sesudah kejadian lain; tanpa tanda tidak ada',
      'lulus', rc_private.claim_remark_dari(null, false, false, null, null, true) = 'Bank Account Changed'
           and rc_private.claim_remark_dari(null, false, true, null, array['Done'], true) = 'Doc Amendment - Done, CB Type Changed, Bank Account Changed'
           and rc_private.claim_remark_dari(null, false, false, null, null, false) is null, 'rinci', '-');

    update public.customers set account_number = '1110001110', account_name = 'PEMILIK MASTER', bank = 'BCA' where id in (k1.customer_id, k2.customer_id, k3.customer_id);
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    -- k1: admin mengisi Nomor Rekening baru; k2: mengisi sama dengan master; k3: kolom rekening kosong (dari Key Master).
    perform rc_private.mutate_claims_unchecked('submit', jsonb_build_array(
      jsonb_build_object('no_doc', k1.no_doc, 'version_no', k1.version_no, 'account_number', '2220002220', 'account_name', 'PEMILIK BARU', 'bank', 'BCA'),
      jsonb_build_object('no_doc', k2.no_doc, 'version_no', k2.version_no, 'account_number', '1110001110', 'account_name', 'PEMILIK MASTER', 'bank', 'BCA'),
      jsonb_build_object('no_doc', k3.no_doc, 'version_no', k3.version_no)), gen_random_uuid(), '');

    select s.rekening_diubah, s.account_number into v_bool, v_txt from rc_private.claim_sensitive s where s.claim_id = k1.id;
    hasil := hasil || jsonb_build_object('uji', 'Admin mengisi Nomor Rekening baru saat pengajuan: ditandai, rekening dokumen = isian',
      'lulus', v_bool and v_txt = '2220002220', 'rinci', coalesce(v_bool::text, '-') || ' ' || coalesce(v_txt, '-'));
    hasil := hasil || jsonb_build_object('uji', 'Isian sama dengan Key Master: tidak ditandai',
      'lulus', not (select rekening_diubah from rc_private.claim_sensitive where claim_id = k2.id), 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Rekening dari Key Master (kolom kosong): tidak ditandai',
      'lulus', (select not rekening_diubah and account_number = '1110001110' from rc_private.claim_sensitive where claim_id = k3.id), 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Detail klaim (claim_remark): "Bank Account Changed" hanya pada dokumen bertanda',
      'lulus', (select rc_private.claim_remark(c) from public.claims c where c.id = k1.id) like '%Bank Account Changed%'
           and coalesce((select rc_private.claim_remark(c) from public.claims c where c.id = k2.id), '') not like '%Bank Account Changed%', 'rinci', '-');

    -- Analytics (sebagai authenticated): Remark dokumen bertanda.
    update public.claims set updated_at = now() + interval '1 minute' where id = k1.id;
    execute 'set local role authenticated';
    r := public.rc_legacy_dashboard(20, null, null);
    execute 'reset role';
    x := (select y from jsonb_array_elements(r->'history') y where y->>'noDoc' = k1.no_doc);
    hasil := hasil || jsonb_build_object('uji', 'Analytics: Remark memuat "Bank Account Changed", rekening = isian admin',
      'lulus', x->>'remark' like '%Bank Account Changed%' and x->>'noRek' = '2220002220', 'rinci', coalesce(x->>'remark', '-'));

    -- Unggah Customer Master (Key Master) mengganti rekening: dokumen lama tidak ikut berubah dan tidak ditandai.
    update public.customers set account_number = '3330003330' where id = k2.customer_id;
    hasil := hasil || jsonb_build_object('uji', 'Ganti rekening lewat Key Master sesudahnya: dokumen tetap rekening lama, tidak ditandai',
      'lulus', (select account_number = '1110001110' and not rekening_diubah from rc_private.claim_sensitive where claim_id = k2.id), 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_bac(uji, lulus, rinci) select y->>'uji', (y->>'lulus')::boolean, y->>'rinci' from jsonb_array_elements(hasil) y;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_bac order by urut;
