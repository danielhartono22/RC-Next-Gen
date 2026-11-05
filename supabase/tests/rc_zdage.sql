-- ==========================================================================================
-- Uji Upload Debtor (ZDAGE) - migrasi 20261163170000
-- ==========================================================================================
-- Fixture memakai klaim, customer, campaign, dan depot yang sudah ada (FK utuh). Baris ZDAGE
-- disusun per klaim supaya setiap aturan teruji. Setiap kelompok uji berjalan di subtransaksi
-- yang DIBATALKAN (UJI_SELESAI); hasil dicatat di variabel lalu ditulis di akhir. Email hanya
-- ke alamat uji dan ikut dibatalkan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_zdage.sql
-- ==========================================================================================
create temp table if not exists _hasil_zd(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_zd;

-- Penilaian hanya memakai SO / Billing Campaign Master. Campaign fixture yang belum memuatnya
-- diberi SO / Billing dari periode campaign-nya di dalam subtransaksi uji (ikut dibatalkan).
-- Setiap blok juga mulai dari keadaan debtor kosong, supaya data yang sudah ada (mis. uji pengguna
-- di dev) tidak memengaruhi hasil; semuanya ikut dibatalkan bersama subtransaksinya.
create or replace function pg_temp.zd_siapkan(p_ids uuid[]) returns void language sql as $f$
  update public.campaigns ca set so_start = coalesce(ca.so_start, ca.period_start),
         billing_end = coalesce(ca.billing_end, ca.so_end, ca.period_end)
   where ca.id in (select c.campaign_id from public.claims c where c.id = any(p_ids))
     and (ca.so_start is null or coalesce(ca.billing_end, ca.so_end) is null);
  delete from public.rc_clearing_offers;
  delete from public.rc_zdage_hasil;
  delete from public.rc_zdage_depot_data;
  update public.claims set bad_debt_remark_id = null where bad_debt_remark_id is not null;
  delete from public.rc_bad_debt_remarks;
$f$;

do $uji$
declare v_sm uuid; hasil jsonb := '[]'; v_dep uuid; v_kode text; v_as date := date_trunc('month', now() at time zone 'Asia/Jakarta')::date;
  v_hari date := (now() at time zone 'Asia/Jakarta')::date; k uuid[]; x record; r jsonb; v_id uuid; v_id2 uuid; v_rows jsonb;
  v_nol jsonb; c1 public.claims%rowtype; o public.rc_clearing_offers%rowtype; n integer; n2 integer; v_galat text; v_txt text;
  v_lain uuid; v_lain_kode text; v_admin uuid; v_admin_dep uuid; v_tmp jsonb;
  function_ok boolean;
  v_zd_asli jsonb; -- 20261163620000: saklar ZDAGE Integration sebelum uji
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password
     and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- Depot dengan klaim Not Yet berperiode di dalam jendela 13 bulan dan jenis CB yang dapat diajukan.
  select z.depot_id into v_dep from (
    select c.depot_id, count(distinct c.customer_id) n
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status <> 'inactive'
      join public.customers cu on cu.id = c.customer_id
     where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and (cu.npwp is not null or cu.ktp is not null)
       and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = 'cn'
       and date_trunc('month', coalesce(c.extend_so_start, ca.so_start, ca.period_start)) between v_as - interval '10 month' and v_as - interval '1 month'
       and date_trunc('month', coalesce(c.extend_billing_end, ca.billing_end, ca.so_end, ca.period_end)) between v_as - interval '10 month' and v_as - interval '1 month'
     group by 1 having count(distinct c.customer_id) >= 7 order by 2 desc limit 1) z;
  select depot_code into v_kode from public.depots where id = v_dep;
  -- Tujuh klaim, tujuh toko berbeda: a (tidak di file), b (nol), c (aturan 1), d (aturan 3), e (aturan 2), f (Bad Debt), g (tanpa master).
  select array_agg(id order by no_doc) into k from (
    select distinct on (c.customer_id) c.id, c.no_doc
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id and ca.status <> 'inactive'
      join public.customers cu on cu.id = c.customer_id
     where c.depot_id = v_dep and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
       and (cu.npwp is not null or cu.ktp is not null)
       and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = 'cn'
       and date_trunc('month', coalesce(c.extend_so_start, ca.so_start, ca.period_start)) between v_as - interval '10 month' and v_as - interval '1 month'
       and date_trunc('month', coalesce(c.extend_billing_end, ca.billing_end, ca.so_end, ca.period_end)) between v_as - interval '10 month' and v_as - interval '1 month'
     order by c.customer_id, c.no_doc) z limit 7;
  if v_dep is null or coalesce(array_length(k, 1), 0) < 7 then
    insert into _hasil_zd(uji, lulus, rinci) values ('Fixture', false, 'Tidak ada depot dengan 7 klaim Not Yet yang memenuhi syarat');
    return; end if;

  -- 20261163620000: uji ini menguji cara baru, jadi saklar ZDAGE Integration dihidupkan selama uji
  -- dan dikembalikan ke nilai semula di akhir (blok luar ini tidak dibatalkan).
  select nilai into v_zd_asli from public.pengaturan_sistem where kunci = 'zdage_aktif';
  update public.pengaturan_sistem set nilai = 'true'::jsonb where kunci = 'zdage_aktif';

  -- Depot lain dengan klaim Not Yet (untuk cakupan per depot).
  select c.depot_id, d.depot_code into v_lain, v_lain_kode from public.claims c join public.depots d on d.id = c.depot_id
   where c.depot_id <> v_dep and c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and c.customer_id is not null
   group by 1, 2 order by count(*) desc limit 1;

  v_nol := (select jsonb_object_agg(to_char(v_as - make_interval(months => i), 'YYYY-MM'), 0) from generate_series(0, 12) i);
  -- Baris ZDAGE: b nol, c tagihan di Bulan Bill, d overdue, e tagihan sebulan sebelum SO, f nol.
  select jsonb_agg(jsonb_build_object('rowNo', z.i + 1, 'channel', v_kode, 'customerCode', '   ' || z.kode, 'customerName', z.nama,
           'termFi', 'I060', 'overdueAmt', z.ovd, 'totalAmt', z.total, 'buckets', z.b, 'bucketOlder', 0) order by z.i)
    into v_rows
    from (select q.i, cu.customer_code kode, cu.customer_name nama,
                 case q.peran when 'd' then 1000 else 0 end ovd,
                 case q.peran when 'c' then 250000 when 'e' then 75000 when 'd' then 1000 else 0 end total,
                 case q.peran
                   when 'c' then jsonb_set(v_nol, array[to_char(date_trunc('month', coalesce(c.extend_billing_end, ca.billing_end, ca.so_end, ca.period_end)), 'YYYY-MM')], '250000')
                   when 'e' then jsonb_set(v_nol, array[to_char(date_trunc('month', coalesce(c.extend_so_start, ca.so_start, ca.period_start)) - interval '1 month', 'YYYY-MM')], '75000')
                   when 'd' then jsonb_set(v_nol, array[to_char(v_as, 'YYYY-MM')], '1000')
                   else v_nol end b
            from (values (1, 'b', 2), (2, 'c', 3), (3, 'd', 4), (4, 'e', 5), (5, 'f', 6)) q(i, peran, pos)
            join public.claims c on c.id = k[q.pos]
            join public.campaigns ca on ca.id = c.campaign_id
            join public.customers cu on cu.id = c.customer_id) z;

  -- ---- 1. Stage: penolakan dan penerimaan ------------------------------------------------
  begin
    perform pg_temp.zd_siapkan(k);
    begin perform public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', now(), v_rows || (v_rows->0), null); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Stage menolak kode toko duplikat dan menyebut barisnya', v_galat ~ 'duplikat', v_galat));
    begin perform public.rc_zdage_stage('x.xlsx', now(), jsonb_build_array((v_rows->0) || jsonb_build_object('buckets', v_nol - to_char(v_as, 'YYYY-MM'))), null); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Stage menolak kolom bulan yang tidak 13 bulan', v_galat ~ 'tidak terbaca|bulan', v_galat));
    begin perform public.rc_zdage_stage('x.xlsx', null, v_rows, null); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Stage menolak tanpa tanggal tarikan', v_galat ~ 'Tanggal tarikan', v_galat));
    begin perform public.rc_zdage_stage('x.xlsx', now(), jsonb_build_array((v_rows->0) || jsonb_build_object('overdueAmt', 'abc')), null); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Stage menolak angka yang tidak terbaca, dengan nomor baris', v_galat ~ 'tidak terbaca' and v_galat ~ ('baris ' || ((v_rows->0)->>'rowNo')), v_galat));
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', now(), jsonb_build_array(v_rows->0, v_rows->1), null);
    v_id := (r->>'uploadId')::uuid;
    r := public.rc_zdage_stage('lain', now(), (select jsonb_agg(e) from jsonb_array_elements(v_rows) with ordinality t(e, i) where i > 2), v_id);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Stage per bagian: bagian kedua menambah ke upload yang sama',
      (select row_count from public.rc_zdage_uploads where id = v_id) = 5 and (select count(*) from public.rc_zdage_rows where upload_id = v_id) = 5
        and (select status from public.rc_zdage_uploads where id = v_id) = 'preview',
      'baris ' || (select row_count from public.rc_zdage_uploads where id = v_id)));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Stage', false, sqlerrm)); end if;
  end;

  -- ---- 2. Alur lengkap: pratinjau, terapkan, idempoten, Open, kembalikan, tawar ulang, proses
  begin
    perform pg_temp.zd_siapkan(k);
    update public.claims set customer_id = null, source_customer_code = 'UJIZD-G' where id = k[7];
    update public.claims set paid_on = date '2026-01-15' where id = k[3];
    update public.claims set paid_on = null where id = k[2];
    r := public.rc_bad_debt_set(array[(select no_doc from public.claims where id = k[6])], 'Uji bad debt');
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    v_id := (r->>'uploadId')::uuid;
    r := public.rc_zdage_preview(v_id, '{}');
    select string_agg(e->>'noDoc' || '=' || (e->>'hasil') || coalesce((e->'alasan'->'gagal')::text, ''), ' ' order by e->>'noDoc') into v_txt
      from jsonb_array_elements(r->'rows') e where (e->>'noDoc') in (select no_doc from public.claims where id = any(k));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Pratinjau (prioritas 1 over due, 2 selama, 3 sebelum campaign): a tidak di file LUNAS, b nol LUNAS, c gagal 2, d gagal 1, e gagal 3, f Bad Debt, g tanpa master',
      exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[1]) and e->>'hasil' = 'LUNAS' and (e->'alasan'->>'tidakDiFile')::boolean)
      and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[2]) and e->>'hasil' = 'LUNAS' and not (e->'alasan'->>'tidakDiFile')::boolean)
      and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[3]) and e->>'hasil' = 'GAGAL' and e->'alasan'->'gagal' = '[2]' and (e->'alasan'->>'utama')::int = 2)
      and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[4]) and e->>'hasil' = 'GAGAL' and e->'alasan'->'gagal' = '[1]' and (e->'alasan'->>'utama')::int = 1)
      and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[5]) and e->>'hasil' = 'GAGAL' and e->'alasan'->'gagal' = '[3]' and (e->'alasan'->>'utama')::int = 3)
      and (r->'ringkasan'->>'gagal1')::int >= 1 and (r->'ringkasan'->>'gagal2')::int >= 1 and (r->'ringkasan'->>'gagal3')::int >= 1
      and r->'ringkasan' ? 'periodeSalah' and r->'ringkasan' ? 'campaignBermasalah' and not (r ? 'kodeTidakDikenal')
      and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[6]) and e->>'hasil' = 'BLOCKED_BAD_DEBT')
      and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[7]) and e->>'hasil' = 'TANPA_MASTER'),
      v_txt));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Pratinjau tidak menulis apa pun; hanya depot di file yang dinilai',
      not exists(select 1 from public.rc_clearing_offers where upload_id = v_id)
        and not exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'kodeDepot' <> v_kode)
        and jsonb_array_length(r->'depotTidakAda') > 0
        and exists(select 1 from jsonb_array_elements(r->'depotTidakAda') d where d->>'kode' = v_lain_kode),
      jsonb_array_length(r->'rows') || ' klaim dinilai; ' || jsonb_array_length(r->'depotTidakAda') || ' depot tidak ada di file'));

    r := public.rc_zdage_apply(v_id, '{}');
    select * into o from public.rc_clearing_offers where claim_id = k[1] and status = 'offered';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Terapkan: tawaran hanya untuk yang LUNAS, batas = hari ini + 7 (WIB)',
      o.id is not null and (o.deadline_at at time zone 'Asia/Jakarta')::date = v_hari + 7
        and exists(select 1 from public.rc_clearing_offers where claim_id = k[2] and status = 'offered')
        and not exists(select 1 from public.rc_clearing_offers where upload_id = v_id and claim_id = any(array[k[3], k[4], k[5], k[6], k[7]]))
        and (r->>'tawaranBaru')::int = (select count(*) from public.rc_clearing_offers where upload_id = v_id),
      'tawaran baru ' || (r->>'tawaranBaru') || ', batas ' || to_char(o.deadline_at at time zone 'Asia/Jakarta', 'DD-MM-YYYY HH24:MI')));
    select * into c1 from public.claims where id = k[2];
    hasil := hasil || jsonb_build_array(jsonb_build_array('Tgl Lunas kosong diisi tanggal tarikan; yang sudah terisi tidak diubah; riwayat + satu baris log',
      c1.paid_on = date '2026-10-16' and (select paid_on from public.claims where id = k[3]) = date '2026-01-15'
        and exists(select 1 from public.claim_status_history h where h.claim_id = k[2] and h.action = 'zdage_offer')
        and (select count(*) from public.activity_logs a where a.event_type = 'zdage_offer' and a.details->>'uploadId' = v_id::text) = 1
        and exists(select 1 from public.rc_zdage_depot_data dd where dd.depot_id = v_dep and dd.upload_id = v_id and not dd.kosong),
      'Tgl Lunas b ' || coalesce(to_char(c1.paid_on, 'DD-MM-YYYY'), '-')));
    n := (select count(*) from public.rc_clearing_offers);
    r := public.rc_zdage_apply(v_id, '{}');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Terapkan ulang idempoten: tidak ada tawaran baru, batas tidak diperpanjang',
      (r->>'sudahDiterapkan')::boolean and (select count(*) from public.rc_clearing_offers) = n
        and (select deadline_at from public.rc_clearing_offers where id = o.id) = o.deadline_at, r->>'message'));

    -- Tab Open: hanya klaim lunas, deadline + sisa hari, deadline terdekat di atas. Toko Bad Debt
    -- tidak di Open selama Approval Bad Debt mati (ada di Restricted). Disaring per campaign.
    execute 'set local role authenticated';
    r := public.rc_open_claims_filtered('', (select ca.campaign_code from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.id = k[1]), 0, 500, '');
    v_tmp := public.rc_open_claims_filtered((select no_doc from public.claims where id = k[6]), '', 0, 50, '');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Open: klaim lunas membawa deadline, sisa 7 hari; semua baris punya tawaran; toko Bad Debt tidak di Open',
      exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[1])
             and (e->>'sisaHari')::int = 7 and e->>'offerStatus' = 'offered' and e->>'deadline' <> '')
      and not exists(select 1 from jsonb_array_elements(r->'rows') e where coalesce(e->>'offerStatus', '') = '')
      and (v_tmp->>'total')::int = 0,
      'baris Open ' || jsonb_array_length(r->'rows') || ', Bad Debt di Open ' || (v_tmp->>'total')));
    execute 'set local role authenticated';
    v_tmp := public.rc_restricted_claims((select no_doc from public.claims where id = k[6]), '', 0, 50, '');
    r := public.rc_open_claims_filtered('', (select ca.campaign_code from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.id = k[2]), 0, 500, '');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Restricted: toko Bad Debt beralasan Bad Debt; Open: Tgl Lunas dari tarikan ZDAGE siap dipindah ke Mass Upload',
      v_tmp->'rows'->0->>'alasan' = 'Bad Debt' and (v_tmp->'rows'->0->>'badDebt')::boolean
        and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[2]) and e->>'tglLunasIsi' = '16-10-2026'),
      coalesce(v_tmp->'rows'->0->>'alasan', '-')));

    -- Kembalikan ke Not Yet: alasan wajib, lalu tawaran berikutnya SUPPRESSED, tawar ulang OSC.
    begin perform public.rc_clearing_return(array[(select no_doc from public.claims where id = k[1])], ''); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    r := public.rc_clearing_return(array[(select no_doc from public.claims where id = k[1])], 'Toko belum konfirmasi');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Kembalikan: tanpa alasan ditolak; dengan alasan tawaran returned + riwayat',
      v_galat ~ 'Alasan' and (r->>'berhasil')::int = 1
        and exists(select 1 from public.rc_clearing_offers where id = o.id and status = 'returned' and return_reason = 'Toko belum konfirmasi')
        and exists(select 1 from public.claim_status_history where claim_id = k[1] and action = 'zdage_return'),
      v_galat || ' | ' || (r->>'message')));
    r := public.rc_zdage_stage('EXPORT_20261017_080000.xlsx', '2026-10-17T08:00:00+07:00', v_rows, null);
    v_id2 := (r->>'uploadId')::uuid;
    r := public.rc_zdage_preview(v_id2, '{}');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Upload berikutnya: yang dikembalikan SUPPRESSED, yang masih ditawarkan SUDAH_DITAWARKAN',
      exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[1]) and e->>'hasil' = 'SUPPRESSED')
      and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[2]) and e->>'hasil' = 'SUDAH_DITAWARKAN'),
      'ok'));
    r := public.rc_clearing_dikembalikan();
    n := jsonb_array_length(r->'rows');
    r := public.rc_clearing_reoffer(array[(select no_doc from public.claims where id = k[1])]);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Tawar ulang: muncul di daftar Dikembalikan, lalu tawaran baru 7 hari',
      n >= 1 and (r->>'berhasil')::int = 1
        and exists(select 1 from public.rc_clearing_offers where claim_id = k[1] and status = 'offered' and result = 'REOFFER'),
      r->>'message'));

    -- Diajukan lewat jalur upload yang ada -> processed.
    select * into c1 from public.claims where id = k[2];
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    execute 'set local role authenticated';
    perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Klaim ditawarkan yang diajukan: tawaran processed',
      exists(select 1 from public.rc_clearing_offers where claim_id = k[2] and status = 'processed')
        and not exists(select 1 from public.rc_clearing_offers where claim_id = k[2] and status in ('offered','overdue')),
      (select status from public.claims where id = k[2])));

    -- Expired lewat Posting Exception (approval mati) -> cancelled + riwayat.
    insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb)
      on conflict (kunci) do update set nilai = excluded.nilai;
    execute 'set local role authenticated';
    perform public.rc_posting_exception('expired', jsonb_build_array(jsonb_build_object('noDoc', (select no_doc from public.claims where id = k[1]))), 'Uji tawaran batal');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Klaim ditawarkan yang di-Expired: tawaran cancelled + riwayat zdage_cancel',
      exists(select 1 from public.rc_clearing_offers where claim_id = k[1] and status = 'cancelled' and result = 'REOFFER')
        and exists(select 1 from public.claim_status_history where claim_id = k[1] and action = 'zdage_cancel'),
      (select status from public.claims where id = k[1])));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Alur lengkap', false, sqlerrm)); end if;
  end;

  -- ---- 3. Cakupan per depot: data lama, Tidak ada tagihan, depot tanpa data ----------------
  begin
    perform pg_temp.zd_siapkan(k);
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    v_id := (r->>'uploadId')::uuid;
    begin perform public.rc_zdage_apply(v_id, array[v_kode]); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    r := public.rc_zdage_apply(v_id, array[v_lain_kode]);
    n := (select count(*) from public.rc_clearing_offers co join public.claims c on c.id = co.claim_id where co.upload_id = v_id and c.depot_id = v_lain);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Depot dicentang Tidak ada tagihan: seluruh klaimnya LUNAS dan ditawarkan; depot di file tidak boleh dicentang',
      v_galat ~ 'tidak sah' and n > 0 and exists(select 1 from public.rc_zdage_depot_data where depot_id = v_lain and kosong),
      n || ' tawaran di depot ' || v_lain_kode || ' | ' || v_galat));
    -- Upload kedua hanya berisi depot lain: depot pertama memakai data lama.
    r := public.rc_zdage_stage('EXPORT_20261017_090000.xlsx', '2026-10-17T09:00:00+07:00',
      jsonb_build_array((v_rows->0) || jsonb_build_object('channel', v_lain_kode, 'customerCode', 'UJIZD-X')), null);
    v_id2 := (r->>'uploadId')::uuid;
    r := public.rc_zdage_preview(v_id2, '{}');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Depot yang tidak ada di file memakai data lama (sumber "lama"); pop up menyebut data lamanya',
      exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'kodeDepot' = v_kode and e->'alasan'->>'sumber' = 'lama')
        and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[3]) and e->>'hasil' = 'GAGAL')
        and exists(select 1 from jsonb_array_elements(r->'depotTidakAda') d where d->>'kode' = v_kode and d->'dataLama' is not null),
      'ok'));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Cakupan per depot', false, sqlerrm)); end if;
  end;

  begin
    perform pg_temp.zd_siapkan(k);
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    v_id := (r->>'uploadId')::uuid;
    r := public.rc_zdage_preview(v_id, '{}');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Depot tanpa data lama dan tidak dicentang tidak dinilai',
      not exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'kodeDepot' <> v_kode
                  and not exists(select 1 from public.rc_zdage_depot_data dd join public.depots d on d.id = dd.depot_id where d.depot_code = e->>'kodeDepot')),
      'ok'));
    -- Bulan tarikan lebih tua dari data yang sudah berlaku ditolak.
    perform public.rc_zdage_apply(v_id, '{}');
    r := public.rc_zdage_stage('EXPORT_20260916_080000.xlsx', '2026-09-16T08:00:00+07:00',
      (select jsonb_agg(e || jsonb_build_object('buckets', (select jsonb_object_agg(to_char(v_as - make_interval(months => i + 1), 'YYYY-MM'), 0) from generate_series(0, 12) i)))
         from jsonb_array_elements(v_rows) e), null);
    v_id2 := (r->>'uploadId')::uuid;
    begin perform public.rc_zdage_apply(v_id2, '{}'); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Bulan tarikan lebih tua dari data yang sudah diterapkan ditolak',
      v_galat ~ 'lebih tua', v_galat));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Cakupan depot tanpa data / bulan lama', false, sqlerrm)); end if;
  end;

  -- ---- 3b. Campaign tanpa SO / Billing dan periode terbalik ---------------------------------
  begin
    perform pg_temp.zd_siapkan(k);
    update public.campaigns set so_start = null, billing_end = null, so_end = null
     where id = (select campaign_id from public.claims where id = k[4]);
    update public.campaigns ca set so_start = date '2026-09-01', billing_end = date '2026-03-31'
     where id = (select campaign_id from public.claims where id = k[5]) and id <> (select campaign_id from public.claims where id = k[4]);
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    r := public.rc_zdage_preview((r->>'uploadId')::uuid, '{}');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Periode Salah = tanpa tanggal SO/Billing + tanggal salah; Campaign Bermasalah = ringkasan per campaign',
      exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[4])
             and e->>'hasil' = 'PERIODE_SALAH' and e->'alasan'->>'masalah' = 'tanpa_tanggal')
      and (exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = (select no_doc from public.claims where id = k[5])
                  and e->>'hasil' = 'PERIODE_SALAH' and e->'alasan'->>'masalah' = 'tanggal_salah')
           or (select campaign_id from public.claims where id = k[5]) = (select campaign_id from public.claims where id = k[4]))
      and (r->'ringkasan'->>'campaignBermasalah')::int >= 1
      and exists(select 1 from jsonb_array_elements(r->'ringkasan'->'campaign') cx
                  where cx->>'kode' = (select ca.campaign_code from public.claims c join public.campaigns ca on ca.id = c.campaign_id where c.id = k[4])
                    and cx->>'masalah' = 'tanpa_tanggal' and (cx->>'klaim')::int >= 1),
      (r->'ringkasan'->>'periodeSalah') || ' klaim, ' || (r->'ringkasan'->>'campaignBermasalah') || ' campaign: ' || left((r->'ringkasan'->'campaign')::text, 200)));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Campaign Bermasalah / Periode Salah', false, sqlerrm)); end if;
  end;

  -- ---- 4. Bad Debt: tawaran batal, approval mati = langsung, approval nyala = tab Bad Debt -----
  begin
    perform pg_temp.zd_siapkan(k);
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb)
      on conflict (kunci) do update set nilai = excluded.nilai;
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    perform public.rc_zdage_apply((r->>'uploadId')::uuid, '{}');
    r := public.rc_bad_debt_set(array[(select no_doc from public.claims where id = k[2])], 'Toko macet');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Tandai Bad Debt: tawaran aktif toko itu dibatalkan, satu baris log',
      exists(select 1 from public.rc_clearing_offers where claim_id = k[2] and status = 'cancelled')
        and exists(select 1 from public.rc_bad_debt_remarks b join public.claims c on c.customer_id = b.customer_id where c.id = k[2] and b.status = 'active')
        and (r->>'tawaranDibatalkan')::int >= 1,
      r->>'message'));
    select * into c1 from public.claims where id = k[2];
    begin
      execute 'set local role authenticated';
      perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
      v_galat := 'diterima';
    exception when others then v_galat := sqlerrm;
    end;
    execute 'reset role';
    r := public.rc_restricted_pindah(array[c1.no_doc], 'Uji Bad Debt dipindah ke Open');
    select * into c1 from public.claims where id = k[2];
    execute 'set local role authenticated';
    perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
    execute 'reset role';
    select * into c1 from public.claims where id = k[2];
    hasil := hasil || jsonb_build_array(jsonb_build_array('Approval Bad Debt mati: toko Bad Debt di Restricted (pengajuan ditolak); dipindah Editor ke Open lalu dapat diajukan, ber-remark Bad Debt',
      v_galat ~ 'Restricted' and (r->>'berhasil')::int = 1 and c1.status = 'approved' and c1.pending_approval is null and c1.bad_debt_remark_id is not null
        and rc_private.email_remark_bad_debt(array[c1.id]) ~ 'Remark: Bad Debt',
      v_galat || ' | ' || c1.status));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Bad Debt approval mati', false, sqlerrm)); end if;
  end;

  begin
    perform pg_temp.zd_siapkan(k);
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb)
      on conflict (kunci) do update set nilai = excluded.nilai;
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    perform public.rc_zdage_apply((r->>'uploadId')::uuid, '{}');
    r := public.rc_bad_debt_approval_setel(true, 'Uji approval bad debt');
    r := public.rc_bad_debt_set(array[(select no_doc from public.claims where id = k[2])], 'Toko macet');
    select * into c1 from public.claims where id = k[2];
    execute 'set local role authenticated';
    perform public.rc_process_claims('submit', jsonb_build_array(
      jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no),
      jsonb_build_object('no_doc', (select no_doc from public.claims where id = k[1]), 'version_no', (select version_no from public.claims where id = k[1]))),
      gen_random_uuid(), '');
    execute 'reset role';
    select * into c1 from public.claims where id = k[2];
    r := public.rc_approval_bad_debt('', '');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Approval Bad Debt nyala: toko Bad Debt menunggu di tab Bad Debt (bukan WPT/Overdue), dokumen lain tetap langsung',
      c1.status = 'submitted' and c1.pending_approval->>'bad_debt' = 'true'
        and (select status from public.claims where id = k[1]) = 'approved'
        and not exists(select 1 from rc_private.approval_rows ar where ar.id = k[2])
        and exists(select 1 from jsonb_array_elements(r->'rows') e where e->>'noDoc' = c1.no_doc and e->>'alasanBadDebt' = 'Toko macet'),
      c1.status || ' / ' || (select status from public.claims where id = k[1])));
    execute 'set local role authenticated';
    perform public.rc_process_claims('approve', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Approve dari tab Bad Debt: dokumen Approved',
      (select status from public.claims where id = k[2]) = 'approved' and (select pending_approval from public.claims where id = k[2]) is null,
      (select status from public.claims where id = k[2])));
    r := public.rc_bad_debt_revoke(array[c1.no_doc], 'Sudah dibayar');
    hasil := hasil || jsonb_build_array(jsonb_build_array('Cabut Bad Debt',
      (r->>'toko')::int = 1 and not exists(select 1 from public.rc_bad_debt_remarks where customer_id = c1.customer_id and status = 'active'),
      r->>'message'));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Bad Debt approval nyala', false, sqlerrm)); end if;
  end;

  -- ---- 4c. Open hanya lunas, Restricted beserta alasan, Pindah ke Open, penilaian ulang ------
  begin
    perform pg_temp.zd_siapkan(k);
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'false'::jsonb)
      on conflict (kunci) do update set nilai = excluded.nilai;
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    perform public.rc_zdage_apply((r->>'uploadId')::uuid, '{}');
    execute 'set local role authenticated';
    r := public.rc_open_claims_filtered((select no_doc from public.claims where id = k[3]), '', 0, 50, '');
    v_tmp := public.rc_restricted_claims((select no_doc from public.claims where id = k[3]), '', 0, 50, '');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Open hanya klaim lunas; klaim belum lunas di Restricted beserta alasannya',
      (r->>'total')::int = 0 and (v_tmp->>'total')::int = 1 and v_tmp->'rows'->0->>'alasan' = 'Belum lunas'
        and (v_tmp->'rows'->0->'alasanRinci'->>'utama')::int = 2,
      'Open ' || (r->>'total') || ', Restricted ' || (v_tmp->>'total') || ': ' || coalesce(v_tmp->'rows'->0->>'alasan', '-')));
    -- Mengajukan klaim Restricted (Mass Upload / Manual Input) ditolak server.
    select * into c1 from public.claims where id = k[3];
    begin
      execute 'set local role authenticated';
      perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
      v_galat := 'diterima';
    exception when others then v_galat := sqlerrm;
    end;
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Mengajukan klaim Restricted ditolak dengan pesan yang jelas', v_galat ~ 'belum lunas \(Restricted\)', v_galat));
    -- Posting Exception: klaim Restricted tidak dapat di-On Hold.
    execute 'set local role authenticated';
    r := public.rc_posting_exception('hold', jsonb_build_array(jsonb_build_object('noDoc', c1.no_doc, 'soStart', '2026-01-01', 'soEnd', '2026-12-31',
      'billingStart', '2026-01-01', 'billingEnd', '2026-12-31')), 'Uji hold restricted');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Klaim Restricted tidak dapat di-On Hold (hanya Expired)',
      (r->>'berhasil')::int = 0 and r->'gagal'->0->>'sebab' ~ 'hanya dapat di-Expired', r->'gagal'->0->>'sebab'));
    -- Editor memindahkan ke Open: berlabel Restricted, tanpa batas, boleh diajukan.
    r := public.rc_restricted_pindah(array[c1.no_doc], 'Toko sudah konfirmasi lunas');
    execute 'set local role authenticated';
    v_tmp := public.rc_open_claims_filtered(c1.no_doc, '', 0, 50, '');
    execute 'reset role';
    select * into c1 from public.claims where id = k[3];
    execute 'set local role authenticated';
    perform public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', c1.no_doc, 'version_no', c1.version_no)), gen_random_uuid(), '');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Pindah ke Open (Editor): tampil di Open berlabel Restricted tanpa deadline, lalu dapat diajukan',
      (r->>'berhasil')::int = 1 and (v_tmp->'rows'->0->>'restricted')::boolean and v_tmp->'rows'->0->>'deadline' = ''
        and (select status from public.claims where id = k[3]) = 'approved'
        and exists(select 1 from public.claim_status_history where claim_id = k[3] and action = 'restricted_open'),
      (r->>'message') || ' | ' || (select status from public.claims where id = k[3])));
    -- Penilaian ulang: toko yang tadinya lunas kini overdue -> tawaran batal, kembali ke Restricted.
    r := public.rc_zdage_stage('EXPORT_20261017_070000.xlsx', '2026-10-17T07:00:00+07:00',
      (select jsonb_agg(e order by (e->>'rowNo')::int) from (
         select e from jsonb_array_elements((select jsonb_agg(jsonb_build_object('rowNo', h.row_no, 'channel', h.channel, 'customerCode', h.customer_code,
             'customerName', h.customer_name, 'termFi', h.term_fi, 'overdueAmt', h.overdue_amt, 'totalAmt', h.total_amt, 'buckets', h.buckets,
             'bucketOlder', h.bucket_older)) from public.rc_zdage_rows h where h.upload_id = (select id from public.rc_zdage_uploads where status = 'applied' order by applied_at desc limit 1))) e
         union all
         select jsonb_build_object('rowNo', 99, 'channel', v_kode, 'customerCode', cu.customer_code, 'customerName', cu.customer_name, 'termFi', 'I060',
                  'overdueAmt', 5000, 'totalAmt', 5000, 'buckets', jsonb_set(v_nol, array[to_char(v_as, 'YYYY-MM')], '5000'), 'bucketOlder', 0)
           from public.claims c join public.customers cu on cu.id = c.customer_id where c.id = k[1]) z(e)), null);
    v_id2 := (r->>'uploadId')::uuid;
    r := public.rc_zdage_preview(v_id2, '{}');
    n := (r->'ringkasan'->>'kembaliRestricted')::int;
    r := public.rc_zdage_apply(v_id2, '{}');
    execute 'set local role authenticated';
    v_tmp := public.rc_restricted_claims((select no_doc from public.claims where id = k[1]), '', 0, 50, '');
    execute 'reset role';
    hasil := hasil || jsonb_build_array(jsonb_build_array('Toko lunas yang kemudian overdue: tawaran batal saat Terapkan, klaim kembali ke Restricted',
      n >= 1 and (r->>'kembaliRestricted')::int >= 1
        and exists(select 1 from public.rc_clearing_offers where claim_id = k[1] and status = 'cancelled')
        and not exists(select 1 from public.rc_clearing_offers where claim_id = k[1] and status in ('offered','overdue'))
        and exists(select 1 from public.claim_status_history where claim_id = k[1] and action = 'zdage_cancel' and reason ~ 'Tidak lunas lagi')
        and v_tmp->'rows'->0->>'alasan' = 'Belum lunas' and (v_tmp->'rows'->0->'alasanRinci'->>'utama')::int = 1,
      'pratinjau ' || n || ', terapkan ' || (r->>'kembaliRestricted') || ', Restricted: ' || coalesce(v_tmp->'rows'->0->>'alasan', '-')));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Open / Restricted', false, sqlerrm)); end if;
  end;

  -- ---- 5. Job harian: overdue + email peringatan per depot ----------------------------------
  begin
    perform pg_temp.zd_siapkan(k);
    update public.email_settings set aktif = true, mode_uji = true, email_uji = 'uji.zdage@example.com' where jenis = 'pengajuan';
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    perform public.rc_zdage_apply((r->>'uploadId')::uuid, '{}');
    update public.rc_clearing_offers set deadline_at = now() - interval '1 day' where claim_id = any(k) and status = 'offered';
    n := (select count(*) from public.email_outbox);
    r := rc_private.zdage_harian();
    select string_agg(ob.subjek, ' | ') into v_txt from public.email_outbox ob where ob.konteks->>'aksi' = 'debtor_warning' and ob.konteks->>'depot' = v_dep::text;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Job harian: tawaran lewat batas menjadi overdue + riwayat + satu baris log',
      (r->>'overdue')::int >= 2 and exists(select 1 from public.rc_clearing_offers where claim_id = k[1] and status = 'overdue')
        and exists(select 1 from public.claim_status_history where claim_id = k[1] and action = 'zdage_overdue')
        and exists(select 1 from public.activity_logs where event_type = 'zdage_overdue' and created_at = now()),
      r::text));
    -- 20261163670000: email peringatan harian lama diganti email berjenjang jenis 'debtor'
    -- (supabase/tests/rc_email_debtor.sql); job harian tidak lagi mengirimnya.
    hasil := hasil || jsonb_build_array(jsonb_build_array('Email peringatan lama tidak dikirim job harian (diganti email berjenjang)',
      v_txt is null and (r->>'email')::int = 0, coalesce(v_txt, 'tidak ada email')));
    n2 := (select count(*) from public.email_outbox);
    r := rc_private.zdage_harian();
    hasil := hasil || jsonb_build_array(jsonb_build_array('Job dijalankan lagi di hari yang sama: tidak ada email ganda',
      (select count(*) from public.email_outbox) = n2, ((select count(*) from public.email_outbox) - n2) || ' email tambahan'));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Job harian', false, sqlerrm)); end if;
  end;

  -- ---- 6. Hak akses: tab opt-in, penolakan tanpa tab, Kembalikan dalam jangkauan --------------
  select p.id into v_admin from public.profiles p where p.role = 'admin' and p.status = 'active' and not p.must_change_password
     and exists(select 1 from public.user_depot_access u where u.user_id = p.id) order by p.user_code limit 1;
  begin
    perform pg_temp.zd_siapkan(k);
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    function_ok := coalesce((rc_private.tab_rights(v_admin)->>'compilation.debtor')::boolean, false);
    begin perform public.rc_zdage_stage('x.xlsx', now(), v_rows, null); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Tab Upload Debtor bawaannya tidak dicentang; tanpa tab, Stage ditolak',
      not function_ok and v_galat ~ 'Akses tab compilation.debtor', v_galat));
    -- Seperti Access Management: modul Document Center diberikan, lalu tab-nya dicentang.
    insert into public.user_permissions(user_id, permission_code) values (v_admin, 'view_compilation') on conflict do nothing;
    insert into rc_private.user_tab_access(user_id, tab_code, allowed) values (v_admin, 'compilation.debtor', true)
      on conflict (user_id, tab_code) do update set allowed = true;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Dicentang di Access Management: tab Upload Debtor terbuka',
      coalesce((rc_private.tab_rights(v_admin)->>'compilation.debtor')::boolean, false), 'ok'));
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Restricted terlihat bawaan (ikut Claim Upload); Restricted (Editor) dan Bad Debt (Tandai) hanya bila dicentang',
      coalesce((rc_private.tab_rights(v_admin)->>'upload.restricted')::boolean, false) = coalesce((rc_private.tab_rights(v_admin)->>'upload.open')::boolean, false)
        and not coalesce((rc_private.tab_rights(v_admin)->>'upload.restrictedEdit')::boolean, false)
        and not coalesce((rc_private.tab_rights(v_admin)->>'upload.baddebt')::boolean, false),
      'restricted ' || coalesce(rc_private.tab_rights(v_admin)->>'upload.restricted', '-') || ', editor ' || coalesce(rc_private.tab_rights(v_admin)->>'upload.restrictedEdit', '-')
        || ', bad debt ' || coalesce(rc_private.tab_rights(v_admin)->>'upload.baddebt', '-')));
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    begin perform public.rc_bad_debt_set(array[(select no_doc from public.claims where id = k[2])], 'Uji tanpa izin'); v_galat := 'diterima';
    exception when others then v_galat := sqlerrm; end;
    begin perform public.rc_restricted_pindah(array[(select no_doc from public.claims where id = k[2])], 'Uji tanpa izin'); v_txt := 'diterima';
    exception when others then v_txt := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Tanpa centang: Tandai Bad Debt dan Pindah ke Open ditolak',
      v_galat ~ 'upload.baddebt' and v_txt ~ 'upload.restrictedEdit', v_galat || ' | ' || v_txt));
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_array(jsonb_build_array('System Manager selalu memegang tab Upload Debtor dan Bad Debt',
      (rc_private.tab_rights(v_sm)->>'compilation.debtor')::boolean and (rc_private.tab_rights(v_sm)->>'approval.baddebt')::boolean, 'ok'));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Hak akses tab', false, sqlerrm)); end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  begin
    -- Admin hanya dapat mengembalikan dokumen di depot jangkauannya.
    perform pg_temp.zd_siapkan(k);
    r := public.rc_zdage_stage('EXPORT_20261016_205703.xlsx', '2026-10-16T20:57:00+07:00', v_rows, null);
    perform public.rc_zdage_apply((r->>'uploadId')::uuid, array[]::text[]);
    perform set_config('request.jwt.claims', json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    insert into rc_private.user_tab_access(user_id, tab_code, allowed) values (v_admin, 'upload.open', true)
      on conflict (user_id, tab_code) do update set allowed = true;
    function_ok := rc_private.can_access(v_dep, 'upload_claim');
    begin r := public.rc_clearing_return(array[(select no_doc from public.claims where id = k[1])], 'Uji jangkauan'); v_galat := r->>'berhasil';
    exception when others then v_galat := sqlerrm; end;
    hasil := hasil || jsonb_build_array(jsonb_build_array('Kembalikan mengikuti jangkauan depot pemanggil',
      (function_ok and v_galat = '1') or (not function_ok and (v_galat = '0' or v_galat ~ 'Akses|izin')),
      'jangkauan ' || function_ok || ', hasil ' || v_galat));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Kembalikan per jangkauan', false, sqlerrm)); end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- ---- 7. Pengaturan bawaan -------------------------------------------------------------------
  hasil := hasil || jsonb_build_array(jsonb_build_array('Bawaan: toleransi Rp 1, mode per kolom, Approval Bad Debt mati',
    rc_private.zdage_toleransi() = 1 and rc_private.zdage_mode() = 'kolom' and not rc_private.approval_bad_debt_aktif(),
    rc_private.zdage_toleransi() || ' / ' || rc_private.zdage_mode() || ' / ' || rc_private.approval_bad_debt_aktif()));
  hasil := hasil || jsonb_build_array(jsonb_build_array('Tidak ada sisa data uji',
    not exists(select 1 from public.rc_zdage_uploads where row_count = 5 or file_name like 'EXPORT_20261017_0%'),
    (select count(*) from public.rc_clearing_offers) || ' tawaran di database'));

  perform set_config('request.jwt.claims', '', true);
  update public.pengaturan_sistem set nilai = coalesce(v_zd_asli, 'false'::jsonb) where kunci = 'zdage_aktif';
  insert into _hasil_zd(uji, lulus, rinci) select h->>0, (h->>1)::boolean, h->>2 from jsonb_array_elements(hasil) h;
end
$uji$;

select (select count(*) filter (where lulus) || '/' || count(*) from _hasil_zd) skor, urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci
  from _hasil_zd order by urut;
