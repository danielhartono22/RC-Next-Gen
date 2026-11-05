-- ==========================================================================================
-- Uji KTP / NPWP tepat 16 digit (migrasi 20261163260000)
-- ==========================================================================================
-- Seluruhnya di subtransaksi yang DIBATALKAN (UJI_SELESAI): customer uji dan perubahan customer
-- yang ada ikut dibatalkan. Aman untuk dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_ktp_npwp_16.sql
-- ==========================================================================================
create temp table if not exists _hasil_k16(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_k16;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_kode text; v_depot text; c record; v_galat text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select cu.customer_code into v_kode from public.customers cu where cu.archived_at is null
     and exists(select 1 from public.customer_depots cd where cd.customer_id = cu.id) order by cu.customer_code limit 1;
  select depot_code into v_depot from public.depots where archived_at is null order by depot_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  begin
    perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode,
      'ktp', '3201010101010001', 'npwp', '0123456789012345')));
    select * into c from public.customers where customer_code = v_kode;
    hasil := hasil || jsonb_build_object('uji', '16 digit diterima; NPWP terisi -> Badan',
      'lulus', c.ktp = '3201010101010001' and c.npwp = '0123456789012345' and c.tax_subject = 'Badan', 'rinci', c.ktp || ' / ' || c.npwp);

    perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode,
      'ktp', ' 3201 0101 0101 0002 ', 'npwp', E'0123 4567\t8901 2346')));
    select * into c from public.customers where customer_code = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Spasi (termasuk tab / spasi tak terputus) dibuang lalu diterima',
      'lulus', c.ktp = '3201010101010002' and c.npwp = '0123456789012346', 'rinci', c.ktp || ' / ' || c.npwp);

    begin
      perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'npwp', '012345678901234')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'NPWP 15 digit ditolak dengan pesan jelas',
      'lulus', v_galat ~ 'No NPWP harus tepat 16 digit angka \(terbaca 15 karakter', 'rinci', v_galat);

    begin
      perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'ktp', '32010101010100011')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'KTP 17 digit ditolak',
      'lulus', v_galat ~ 'No KTP harus tepat 16 digit angka \(terbaca 17 karakter', 'rinci', v_galat);

    begin
      perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'npwp', '01.234.567.8-901.234')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'NPWP bertitik / strip ditolak (bukan angka murni)',
      'lulus', v_galat ~ 'No NPWP harus tepat 16 digit', 'rinci', v_galat);

    begin
      perform public.rc_customer_upsert_periksa(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'ktp', '123')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'Pratinjau unggahan (periksa) ikut menolak dengan pesan yang sama',
      'lulus', v_galat ~ 'No KTP harus tepat 16 digit angka \(terbaca 3 karakter', 'rinci', v_galat);

    perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'custName', c.customer_name)));
    select * into c from public.customers where customer_code = v_kode;
    hasil := hasil || jsonb_build_object('uji', 'Kolom tidak dikirim (sel kosong): nilai lama tetap',
      'lulus', c.ktp = '3201010101010002' and c.npwp = '0123456789012346', 'rinci', '');

    perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'npwp', '', 'ktp', '-')));
    select * into c from public.customers where customer_code = v_kode;
    hasil := hasil || jsonb_build_object('uji', '"-" / kosong mengosongkan (subyek pajak ikut kosong)',
      'lulus', c.ktp is null and c.npwp is null and c.tax_subject is null, 'rinci', '');

    begin
      perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', 'UJIKTP16', 'custName', 'TOKO UJI KTP',
        'kodeDepot', v_depot, 'ktp', '320101010101000')));
      v_galat := '(tidak ditolak)';
    exception when others then v_galat := sqlerrm;
    end;
    hasil := hasil || jsonb_build_object('uji', 'Customer baru dengan KTP 15 digit ditolak',
      'lulus', v_galat ~ 'Customer UJIKTP16: No KTP harus tepat 16 digit' and not exists(select 1 from public.customers where customer_code = 'UJIKTP16'),
      'rinci', v_galat);
    perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', 'UJIKTP16', 'custName', 'TOKO UJI KTP',
      'kodeDepot', v_depot, 'ktp', '3201 0101 0101 0003')));
    select * into c from public.customers where customer_code = 'UJIKTP16';
    hasil := hasil || jsonb_build_object('uji', 'Customer baru dengan KTP 16 digit (berspasi) tersimpan rapi -> Perorangan',
      'lulus', c.ktp = '3201010101010003' and c.tax_subject = 'Perorangan', 'rinci', coalesce(c.ktp, '-'));

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);

  insert into _hasil_k16(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_k16 order by urut;
