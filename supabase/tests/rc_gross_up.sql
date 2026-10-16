-- ==========================================================================================
-- Uji Gross Up: rumus, compile, Reprocessing Doc, dan konsistensi data
-- ==========================================================================================
-- Dibuat 12 Oktober 2026 ("hitung gross up buat dan testing"); diperbarui untuk aturan
-- 20261162250000 (semua status pajak dihitung, seluruh Rebate 0, disimpan bulat).
--
-- Menjalankan:  node scripts/apply-sql.mjs --env dev supabase/tests/rc_gross_up.sql
-- Hasilnya satu tabel: uji, lulus, rinci. Semua perubahan data dibuat di dalam subtransaksi
-- yang DIBATALKAN (raise 'UJI_SELESAI'), jadi tidak ada yang tertinggal di database; yang
-- bertahan hanya tabel sementara berisi hasil uji.
--
-- Aturan yang diuji (rc_private.gross_up_klaim -> rc_private.gross_claimed):
--   0  Jenis CB Rebate / Rebate Manual (RA07, RA7), atau Status Pajak Rebate Non Tax
--   Badan                        cashback / 0,85
--   Perorangan (dan subyek kosong), progresif:
--     s.d. 57.000.000            cashback / 0,95
--     s.d. 218.500.000           60.000.000    + (cashback - 57.000.000)    / 0,85
--     s.d. 406.000.000           250.000.000   + (cashback - 218.500.000)   / 0,75
--     s.d. 3.556.000.000         500.000.000   + (cashback - 406.000.000)   / 0,70
--     di atasnya                 5.000.000.000 + (cashback - 3.556.000.000) / 0,65
--   Berlaku sama untuk Status Pajak Customer, PT Nipsea Paint and Chemicals / Ditanggung
--   Perusahaan, dan kosong. Hasil dipotong ke rupiah bulat.
-- ==========================================================================================

create temp table if not exists _hasil_gross(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_gross;

-- ------------------------------------------------------------------------------------------
-- 1. Rumus - angka pasti di setiap batas tarif dan setiap status pajak
-- ------------------------------------------------------------------------------------------
insert into _hasil_gross(uji, lulus, rinci)
select 'Rumus: ' || nama, hasil = harap, format('hasil %s, harap %s', hasil, harap)
from (values
  ('Badan 85.000 -> 100.000',                         rc_private.gross_up_klaim(85000, 'Badan', 'Customer', 'Transfer'),            100000::numeric),
  ('Badan tidak peka huruf besar',                    rc_private.gross_up_klaim(85000, ' BADAN ', 'Customer', 'CN'),               100000::numeric),
  ('Badan 1.000.000 -> 1.176.470 (dipotong)',         rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'Transfer'),          1176470::numeric),
  ('Perorangan 57.000.000 -> 60.000.000 (batas 1)',   rc_private.gross_up_klaim(57000000, 'Perorangan', 'Customer', 'Transfer'),    60000000::numeric),
  ('Perorangan 57.000.001 masuk tarif 2 (dipotong)',  rc_private.gross_up_klaim(57000001, 'Perorangan', 'Customer', 'Transfer'),    60000001::numeric),
  ('Perorangan 218.500.000 -> 250.000.000 (batas 2)', rc_private.gross_up_klaim(218500000, 'Perorangan', 'Customer', 'Transfer'),   250000000::numeric),
  ('Perorangan 406.000.000 -> 500.000.000 (batas 3)', rc_private.gross_up_klaim(406000000, 'Perorangan', 'Customer', 'Transfer'),   500000000::numeric),
  ('Perorangan 3.556.000.000 -> 5.000.000.000 (batas 4)', rc_private.gross_up_klaim(3556000000, 'Perorangan', 'Customer', 'CN'),    5000000000::numeric),
  ('Perorangan 3.621.000.000 -> 5.100.000.000 (tarif 5)', rc_private.gross_up_klaim(3621000000, 'Perorangan', 'Customer', 'CN'),    5100000000::numeric),
  ('Subyek dan status kosong: progresif',             rc_private.gross_up_klaim(1000000, null, null, null),                         1052631::numeric),
  ('PT Nipsea Paint and Chemicals kini dihitung',     rc_private.gross_up_klaim(85000, 'Badan', 'PT Nipsea Paint and Chemicals', 'CN'), 100000::numeric),
  ('PT Nipsea Paint And Chemicals (Perorangan)',      rc_private.gross_up_klaim(57000000, 'Perorangan', 'PT Nipsea Paint And Chemicals', 'Transfer'), 60000000::numeric),
  ('Ditanggung Perusahaan kini dihitung',             rc_private.gross_up_klaim(85000, 'Badan', 'Ditanggung Perusahaan', 'Transfer'), 100000::numeric),
  ('Jenis CB Rebate -> 0',                            rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'Rebate'),            0::numeric),
  ('Jenis CB Rebate Manual -> 0',                     rc_private.gross_up_klaim(1000000, 'Badan', 'PT Nipsea Paint and Chemicals', 'Rebate Manual'), 0::numeric),
  ('Jenis CB RA07 -> 0',                              rc_private.gross_up_klaim(1000000, 'Perorangan', 'Customer', 'RA07'),         0::numeric),
  ('Status Rebate Non Tax -> 0',                      rc_private.gross_up_klaim(1000000, 'Badan', 'Rebate Non Tax', 'Transfer'),    0::numeric),
  ('Status Rebate Non-Tax (tanda hubung) -> 0',       rc_private.gross_up_klaim(1000000, 'Badan', 'Rebate Non-Tax', 'CN'),          0::numeric),
  ('Cashback 0 -> 0',                                 rc_private.gross_up_klaim(0, 'Badan', 'Customer', 'Transfer'),                0::numeric),
  ('Cashback negatif -> 0',                           rc_private.gross_up_klaim(-1, 'Badan', 'Customer', 'Transfer'),               0::numeric),
  ('Cashback kosong -> 0',                            rc_private.gross_up_klaim(null, 'Badan', 'Customer', 'Transfer'),             0::numeric)
) t(nama, hasil, harap);

-- ------------------------------------------------------------------------------------------
-- 2. Konsistensi data
-- ------------------------------------------------------------------------------------------
insert into _hasil_gross(uji, lulus, rinci)
select 'Data: gross up setiap dokumen sesuai aturan', n = 0,
       format('%s dari %s dokumen (dengan Customer Master) tidak sesuai%s', n, total,
              case when n > 0 then '; contoh ' || contoh else '' end)
from (select count(*) filter (where c.gross_up is distinct from rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status,
                                coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type))) n,
             count(*) total,
             min(c.no_doc) filter (where c.gross_up is distinct from rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status,
                                coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type))) contoh
        from public.claims c join public.campaigns ca on ca.id = c.campaign_id
       where c.customer_id is not null and c.archived_at is null) x;

insert into _hasil_gross(uji, lulus, rinci)
select 'Data: tidak ada gross up berdesimal', n = 0, format('%s dokumen berdesimal', n)
from (select count(*) n from public.claims where gross_up <> trunc(gross_up)) x;

insert into _hasil_gross(uji, lulus, rinci)
select 'Data: seluruh Rebate dan Voucher bernilai 0', n = 0, format('%s dokumen Rebate/Voucher dengan gross up bukan 0', n)
from (select count(*) n from public.claims c join public.campaigns ca on ca.id = c.campaign_id
       where c.customer_id is not null and coalesce(c.gross_up, 0) <> 0
         and (rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('rebate', 'rebate manual', 'voucher') -- 20261163120000
              or lower(coalesce(ca.tax_status, '')) ~ 'non[[:space:]_-]*tax')) x;

insert into _hasil_gross(uji, lulus, rinci)
select 'Data: PT Nipsea non-Rebate/Voucher kini punya gross up', n = 0, format('%s dokumen PT Nipsea (cashback > 0, bukan Rebate/Voucher) bernilai 0', n)
from (select count(*) n from public.claims c join public.campaigns ca on ca.id = c.campaign_id
       where c.customer_id is not null and c.cb_net > 0 and coalesce(c.gross_up, 0) = 0
         and lower(coalesce(ca.tax_status, '')) like '%nipsea%'
         and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) not in ('rebate', 'rebate manual', 'voucher')) x; -- 20261163120000

insert into _hasil_gross(uji, lulus, rinci)
select 'Data: Report (rc_report_rows) sama dengan gross up tersimpan', n = 0, format('%s dokumen berbeda', n)
from (select count(*) n from public.rc_report_rows v join public.claims c on c.id = v.id
       where c.customer_id is not null and v.gross_claimed is distinct from c.gross_up) x;

-- ------------------------------------------------------------------------------------------
-- 3 & 4. Compile dan Reprocessing - dijalankan sungguhan lalu dibatalkan
-- ------------------------------------------------------------------------------------------
do $uji$
declare
  v_sm uuid; d record; hasil jsonb; v_hasil jsonb := '[]'; v_doc text; v_c record; harap numeric;
  tambah text;
begin
  select id into v_sm from public.profiles
   where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  if v_sm is null then
    insert into _hasil_gross(uji, lulus, rinci) values ('Fixture', false, 'Tidak ada System Manager aktif');
    return;
  end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

    -- 3. Compile: pasangan campaign x customer yang belum punya klaim, satu per kombinasi
    --    subyek pajak x jenis (Rebate / bukan Rebate).
    for d in
      select distinct on (cu.tax_subject, rc_private.jenis_efektif(ca.cashback_type) = 'rebate')
             dp.depot_code, dp.abbr, ca.campaign_code, ca.cashback_type, cu.customer_code, cu.tax_subject, ca.tax_status
        from public.customers cu
        join public.customer_depots m on m.customer_id = cu.id
        join public.depots dp on dp.id = m.depot_id and dp.archived_at is null and dp.abbr is not null
        cross join lateral (select ca.* from public.campaigns ca
                             where ca.status = 'active' and ca.archived_at is null
                               and lower(coalesce(ca.tax_status, '')) !~ 'non[[:space:]_-]*tax'
                               and not exists(select 1 from public.claims c where c.campaign_id = ca.id and c.customer_id = cu.id)
                               and not rc_private.np_pasangan(dp.id, ca.id)
                               and not exists(select 1 from public.timetable_not_achieved na where na.depot_id = dp.id and na.campaign_id = ca.id)
                             limit 1) ca
       where cu.archived_at is null and cu.tax_subject is not null
       order by cu.tax_subject, rc_private.jenis_efektif(ca.cashback_type) = 'rebate'
    loop
      hasil := rc_private.compile_upload(jsonb_build_array(jsonb_build_object(
        'kodeDepot', d.depot_code, 'abbr', d.abbr, 'codeCampaign', d.campaign_code, 'custCode', d.customer_code,
        'custName', '', 'netValue', '10.000.000,99', 'volume', '250', 'cbNet', '58.000.000,75', 'jenisCb', '')), gen_random_uuid());
      v_doc := hasil->'dokumen'->0->>'noDoc';
      select cb_net, gross_up, tax_subject into v_c from public.claims where no_doc = v_doc;
      harap := rc_private.gross_up_klaim(58000000, d.tax_subject, d.tax_status, d.cashback_type);
      v_hasil := v_hasil || jsonb_build_object('uji', format('Compile %s, %s, %s: cashback dipotong, gross up sesuai aturan', d.tax_subject, d.cashback_type, d.tax_status),
        'lulus', v_doc is not null and v_c.cb_net = 58000000 and v_c.gross_up = harap and v_c.gross_up = trunc(v_c.gross_up)
                 and (harap = 0) = (rc_private.jenis_efektif(d.cashback_type) = 'rebate'),
        'rinci', format('%s: cashback %s, gross up %s (harap %s)', coalesce(v_doc, hasil::text), v_c.cb_net, v_c.gross_up, harap));
    end loop;

    -- 4. Reprocessing: dokumen Not Yet ditahan dulu, lalu direvisi; satu per subyek pajak x
    --    (Rebate / bukan Rebate).
    for d in
      select distinct on (tax_subject, rebate) * from (
        select c.id, c.no_doc, c.cb_net, c.gross_up, c.tax_subject, ca.tax_status,
               coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type) jenis,
               rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('rebate', 'rebate manual', 'voucher') rebate
          from public.claims c
          join public.customers cu on cu.id = c.customer_id and cu.tax_subject is not null and cu.tax_subject = c.tax_subject
          join public.campaigns ca on ca.id = c.campaign_id and ca.status = 'active'
         where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null
           and lower(coalesce(ca.tax_status, '')) !~ 'non[[:space:]_-]*tax') x
       order by tax_subject, rebate, cb_net desc
    loop
      update public.claims set status = 'on_hold', previous_status = 'not_yet' where id = d.id;

      hasil := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', d.no_doc, 'totalCashback', '-5')), 'uji');
      v_hasil := v_hasil || jsonb_build_object('uji', format('Reprocessing %s %s: cashback negatif ditolak', d.tax_subject, d.jenis),
        'lulus', (hasil->>'berhasil')::int = 0 and (select gross_up from public.claims where id = d.id) is not distinct from d.gross_up,
        'rinci', coalesce(hasil->'gagal'->0->>'sebab', hasil::text));

      hasil := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', d.no_doc, 'totalCashback', '219000000.6')), 'uji');
      select cb_net, gross_up, tax_subject, status into v_c from public.claims where id = d.id;
      harap := rc_private.gross_up_klaim(219000000, d.tax_subject, d.tax_status, d.jenis);
      v_hasil := v_hasil || jsonb_build_object('uji', format('Reprocessing %s %s: 219.000.000,6 -> gross up dihitung ulang', d.tax_subject, d.jenis),
        'lulus', (hasil->>'berhasil')::int = 1 and v_c.cb_net = 219000000 and v_c.gross_up = harap
                 and v_c.status = 'not_yet' and (harap = 0) = d.rebate,
        'rinci', format('%s: gross up lama %s, baru %s (harap %s), status %s', d.no_doc, d.gross_up, v_c.gross_up, harap, v_c.status));

      -- 20261163150000: Reprocessing tidak lagi menulis log per dokumen (Log Activity satu baris per
      -- proses); jejaknya riwayat status 'reprocess' beserta alasannya.
      tambah := (select reason from public.claim_status_history where claim_id = d.id and action = 'reprocess' order by id desc limit 1);
      v_hasil := v_hasil || jsonb_build_object('uji', format('Reprocessing %s %s: riwayat mencatat alasan, tanpa log per dokumen', d.tax_subject, d.jenis),
        'lulus', tambah = 'uji' and not exists(select 1 from public.activity_logs where event_type = 'reprocessing_upload' and entity_id = d.id),
        'rinci', coalesce(tambah, 'riwayat tidak ada'));
    end loop;

    -- 5. Submit (rc_process_claims 'submit'): gross up dihitung ulang dari identitas dan
    --    Jenis CB saat diajukan. Dokumen CN dan Rebate dipakai karena tidak menuntut rekening.
    --    Antrean email pengajuan ikut dibatalkan bersama subtransaksi ini.
    for d in
      select distinct on (rebate) * from (
        select c.id, c.no_doc, c.version_no, c.cb_net, cu.tax_subject, ca.tax_status,
               coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type) jenis,
               rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = 'rebate' rebate
          from public.claims c
          join public.customers cu on cu.id = c.customer_id
           and (nullif(btrim(coalesce(cu.ktp, '')), '') is null) <> (nullif(btrim(coalesce(cu.npwp, '')), '') is null)
          join public.campaigns ca on ca.id = c.campaign_id and ca.status = 'active'
         where c.status = 'not_yet' and c.archived_at is null and c.pending_approval is null and c.cb_net > 0
           and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) in ('cn', 'rebate')
           and lower(coalesce(ca.tax_status, '')) !~ 'non[[:space:]_-]*tax') x
       order by rebate, cb_net desc
    loop
      begin
        -- Gross up dikosongkan dulu supaya terbukti dihitung oleh submit, bukan tersisa.
        update public.claims set gross_up = null where id = d.id;
        hasil := public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no)), gen_random_uuid(), '');
        select gross_up, status into v_c from public.claims where id = d.id;
        harap := rc_private.gross_up_klaim(d.cb_net, d.tax_subject, d.tax_status, d.jenis);
        v_hasil := v_hasil || jsonb_build_object('uji', format('Submit %s %s %s: gross up dihitung saat diajukan', d.tax_subject, d.jenis, d.tax_status),
          'lulus', v_c.gross_up = harap and (harap = 0) = d.rebate,
          'rinci', format('%s: gross up %s (harap %s), status %s', d.no_doc, v_c.gross_up, harap, v_c.status));
      exception when others then
        v_hasil := v_hasil || jsonb_build_object('uji', format('Submit %s %s', d.tax_subject, d.jenis), 'lulus', false, 'rinci', d.no_doc || ': ' || sqlerrm);
      end;
    end loop;

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then
      v_hasil := v_hasil || jsonb_build_object('uji', 'Compile/Reprocessing/Submit', 'lulus', false, 'rinci', 'galat: ' || sqlerrm);
    end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  if jsonb_array_length(v_hasil) = 0 then
    v_hasil := jsonb_build_array(jsonb_build_object('uji', 'Fixture compile/reprocessing', 'lulus', false, 'rinci', 'tidak ada data yang dapat diuji'));
  end if;
  insert into _hasil_gross(uji, lulus, rinci)
  select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(v_hasil) x;
end
$uji$;

select uji, lulus, rinci from _hasil_gross order by urut;
