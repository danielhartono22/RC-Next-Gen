-- ==========================================================================================
-- Uji pascatransport 16 Oktober 2026 (migrasi 20261163130000 + frontend unggah bertahap)
-- ==========================================================================================
-- Sebagai System Manager dengan peran authenticated, memanggil fungsi yang sama dengan layar.
-- Setiap uji di subtransaksi yang DIBATALKAN; hasil dikumpulkan di variabel lalu dicatat di
-- akhir. Email pengajuan dimatikan di uji Clearing (tidak ada yang terkirim). Aman untuk dev
-- dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_transport_20261016.sql
-- ==========================================================================================
create temp table if not exists _hasil_1016(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_1016;

do $uji$
declare v_sm uuid; hasil jsonb := '[]'; d record; c public.claims%rowtype; r jsonb; v_galat text;
  hari date := (now() at time zone 'Asia/Jakarta')::date; v_tgl date; v_rows jsonb; v_md5a text; v_md5b text;
  t0 timestamptz; v_ms numeric; v_kode text; v_rek text; v_dep text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  select c2.id, c2.no_doc, c2.version_no into d
    from public.claims c2 join public.campaigns ca on ca.id = c2.campaign_id and ca.status <> 'inactive'
   where c2.status = 'claimed' and c2.archived_at is null and c2.pending_approval is null and c2.customer_id is not null
   order by c2.no_doc limit 1;

  -- ---- Clearing: tanggal Done = tanggal pilihan ----------------------------------------------
  foreach v_tgl in array array[hari - 1, hari - 5, hari] loop
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      execute 'set local role authenticated';
      perform public.rc_process_claims('clearing', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc,
        'version_no', d.version_no, 'tgl_aktual', to_char(v_tgl, 'YYYY-MM-DD'))), gen_random_uuid(), '');
      select * into c from public.claims where id = d.id;
      hasil := hasil || jsonb_build_array(jsonb_build_array('Clearing tanggal ' || case v_tgl when hari then 'hari ini' else (hari - v_tgl) || ' hari lalu' end
          || ': Tgl Done = tanggal pilihan, jam = jam proses',
        c.status = 'done' and c.cleared_actual_on = v_tgl and (c.cleared_at at time zone 'Asia/Jakarta')::date = v_tgl
          and (c.cleared_at at time zone 'Asia/Jakarta')::time = (now() at time zone 'Asia/Jakarta')::time
          and exists(select 1 from public.claim_status_history h where h.claim_id = d.id and h.to_status = 'done' and h.created_at = now()),
        format('%s: status %s, Tgl Done %s WIB, riwayat %s', d.no_doc, c.status,
          to_char(c.cleared_at at time zone 'Asia/Jakarta', 'DD-MM-YYYY HH24:MI:SS'),
          (select to_char(max(h.created_at) at time zone 'Asia/Jakarta', 'DD-MM-YYYY HH24:MI:SS') from public.claim_status_history h where h.claim_id = d.id))));
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then
      hasil := hasil || jsonb_build_array(jsonb_build_array('Clearing tanggal ' || v_tgl, false, sqlerrm)); end if;
    end;
  end loop;
  begin
    update public.email_settings set aktif = false where jenis = 'pengajuan';
    execute 'set local role authenticated';
    perform public.rc_process_claims('clearing', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc,
      'version_no', d.version_no, 'tgl_aktual', to_char(hari + 1, 'YYYY-MM-DD'))), gen_random_uuid(), '');
    v_galat := 'diterima';
  exception when others then v_galat := sqlerrm;
  end;
  hasil := hasil || jsonb_build_array(jsonb_build_array('Clearing tanggal besok ditolak', v_galat ~ 'belum terjadi', v_galat));
  hasil := hasil || jsonb_build_array(jsonb_build_array('Data lama: tidak ada Tgl Done yang berbeda dari tanggal pilihan',
    not exists(select 1 from public.claims where cleared_actual_on is not null and cleared_actual_on <> (cleared_at at time zone 'Asia/Jakarta')::date),
    (select count(*) from public.claims where cleared_actual_on is not null) || ' dokumen bertanggal pilihan'));

  -- ---- Customer Master: 2.000 baris nyata, seperti satu bagian unggahan ----------------------
  -- Layar tidak mengirim sel kosong; di sini hanya Customer Code + Customer Name yang dikirim.
  select jsonb_agg(jsonb_build_object('custCode', customer_code, 'custName', customer_name) order by customer_code),
         md5(string_agg(to_jsonb(cu)::text, '|' order by customer_code))
    into v_rows, v_md5a
    from (select * from public.customers where archived_at is null and customer_name is not null order by customer_code limit 2000) cu;
  begin
    execute 'set local role authenticated';
    t0 := clock_timestamp();
    r := public.rc_customer_upsert_periksa(v_rows);
    v_ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then r := jsonb_build_object('galat', sqlerrm); end if;
  end;
  select md5(string_agg(to_jsonb(cu)::text, '|' order by customer_code)) into v_md5b
    from public.customers cu where customer_code in (select x->>'custCode' from jsonb_array_elements(v_rows) x);
  hasil := hasil || jsonb_build_array(jsonb_build_array('Periksa 2.000 customer: hasil sama dengan simpan, tidak ada yang tertulis',
    coalesce((r->>'diperbarui')::int, 0) = jsonb_array_length(v_rows) and (r->>'periksa')::boolean and v_md5a = v_md5b,
    format('diperbarui %s, dibuat %s, %s ms, data %s', r->>'diperbarui', r->>'dibuat', v_ms, case when v_md5a = v_md5b then 'tidak berubah' else 'BERUBAH' end)));

  select customer_code, account_number into v_kode, v_rek from public.customers
   where archived_at is null and account_number is not null and customer_code in (select x->>'custCode' from jsonb_array_elements(v_rows) x)
   order by customer_code limit 1;
  begin
    execute 'set local role authenticated';
    t0 := clock_timestamp();
    r := public.rc_customer_upsert(v_rows);
    v_ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    hasil := hasil || jsonb_build_array(jsonb_build_array('Simpan 2.000 customer: kolom yang tidak dikirim (sel kosong) memakai data lama',
      (r->>'diperbarui')::int = jsonb_array_length(v_rows) and v_kode is not null
        and (select account_number from public.customers where customer_code = v_kode) = v_rek,
      format('diperbarui %s, %s ms; rekening %s tetap %s', r->>'diperbarui', v_ms, v_kode, v_rek)));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Simpan 2.000 customer', false, sqlerrm)); end if;
  end;
  begin
    execute 'set local role authenticated';
    perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'noRek', '')));
    hasil := hasil || jsonb_build_array(jsonb_build_array('Formulir Ubah / tanda "-": nilai kosong yang dikirim mengosongkan',
      (select account_number from public.customers where customer_code = v_kode) is null, v_kode));
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then
    hasil := hasil || jsonb_build_array(jsonb_build_array('Formulir Ubah mengosongkan', false, sqlerrm)); end if;
  end;
  begin
    execute 'set local role authenticated';
    perform public.rc_customer_upsert_periksa(jsonb_build_array(jsonb_build_object('custCode', 'UJI1016X', 'custName', 'UJI', 'kodeDepot', 'ZZ9')));
    v_galat := 'diterima';
  exception when others then v_galat := sqlerrm;
  end;
  hasil := hasil || jsonb_build_array(jsonb_build_array('Periksa menolak Kode Depot tak dikenal dengan menyebut kodenya',
    v_galat ~ 'UJI1016X' and v_galat ~ 'ZZ9', v_galat));
  hasil := hasil || jsonb_build_array(jsonb_build_array('Tidak ada sisa data uji',
    not exists(select 1 from public.customers where customer_code like 'UJI1016%'), ''));

  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_1016(uji, lulus, rinci) select x->>0, (x->>1)::boolean, x->>2 from jsonb_array_elements(hasil) x;
end
$uji$;

select urut, uji, lulus, rinci from _hasil_1016 order by urut;
