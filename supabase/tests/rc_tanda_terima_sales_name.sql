-- ==========================================================================================
-- Uji Sales Name di Customer Master dan Tanda Terima - migrasi 20261163520000
-- ==========================================================================================
-- Seluruh perubahan data dibatalkan (UJI_SELESAI). Bagian Document Generator diperiksa hanya
-- bila 20261163550000 sudah ada; isi Tanda Terima (toko.sales, awalan TT-) diuji di
-- rc_document_generator.sql.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_tanda_terima_sales_name.sql
-- ==========================================================================================
create temp table if not exists _hasil_tt(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_tt;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_kode text; r jsonb; x jsonb; v_err text;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select cu.customer_code into v_kode from public.customers cu
   where cu.archived_at is null and exists(select 1 from public.customer_depots cd where cd.customer_id = cu.id)
   order by cu.customer_code limit 1;

  begin
    hasil := hasil || jsonb_build_object('uji', 'Kolom customers.sales_name ada',
      'lulus', exists(select 1 from information_schema.columns where table_schema = 'public' and table_name = 'customers' and column_name = 'sales_name'), 'rinci', '-');

    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'salesName', '  Sales Uji TT  ')));
    x := (select e from jsonb_array_elements(public.rc_customer_list(v_kode, 0, 50)->'rows') e where e->>'custCode' = v_kode);
    hasil := hasil || jsonb_build_object('uji', 'Upload / Ubah mengisi Sales Name (spasi dipangkas); daftar Customer Master mengirim salesName',
      'lulus', r->>'status' = 'success' and (select sales_name from public.customers where customer_code = v_kode) = 'Sales Uji TT' and x->>'salesName' = 'Sales Uji TT',
      'rinci', coalesce(x->>'salesName', 'tidak ada di daftar'));

    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'contactPerson', 'Pemilik Uji TT')));
    hasil := hasil || jsonb_build_object('uji', 'Sel Sales Name kosong (kolom tidak dikirim) membiarkan nilai lama',
      'lulus', (select sales_name from public.customers where customer_code = v_kode) = 'Sales Uji TT', 'rinci', '-');

    r := public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'salesName', '')));
    hasil := hasil || jsonb_build_object('uji', 'Sales Name "" (dari "-" di template) mengosongkan',
      'lulus', (select sales_name from public.customers where customer_code = v_kode) is null, 'rinci', '-');

    v_err := null;
    begin perform public.rc_customer_upsert(jsonb_build_array(jsonb_build_object('custCode', v_kode, 'salesName', repeat('x', 201))));
    exception when others then v_err := sqlerrm; end;
    hasil := hasil || jsonb_build_object('uji', 'Sales Name lebih dari 200 karakter ditolak', 'lulus', coalesce(v_err, '') ~ 'salesName', 'rinci', coalesce(v_err, 'diterima!'));

    -- Sejak 20261163540000 Document Generator memakai tab Done / Not Yet; isinya diuji di
    -- rc_document_generator.sql.
    if to_regprocedure('public.rc_docgen_generate(jsonb,text,jsonb)') is null then
      hasil := hasil || jsonb_build_object('uji', 'Tanda Terima', 'lulus', true, 'rinci', 'DILEWATI: Document Generator (20261163550000) belum ada di lingkungan ini');
    else
      hasil := hasil || jsonb_build_object('uji', 'Tanda Terima: nomor berawalan TT-, sales toko ikut',
        'lulus', pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure) ~ $p$'TT-' \|\| r\.abbr$p$
             and pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure) ~ $p$'sales', r\.sales$p$,
        'rinci', '-');
    end if;

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_tt(uji, lulus, rinci) select y->>'uji', (y->>'lulus')::boolean, y->>'rinci' from jsonb_array_elements(hasil) y;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_tt order by urut;
