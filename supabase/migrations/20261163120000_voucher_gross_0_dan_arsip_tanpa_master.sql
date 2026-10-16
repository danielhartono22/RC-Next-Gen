-- ==========================================================================================
-- Gross up Voucher = 0, dan dokumen tanpa Customer Master tetap dapat diarsipkan
-- ==========================================================================================
-- Pemilik, 14 Oktober 2026: "voucher juga 0 ya, dan tambahkan saya mau list yang di arsip tidak
-- perlu lengkap master datanya, tidak lengkap pun bisa dihapus."
--
-- 1. GROSS UP VOUCHER
--    rc_private.gross_up_klaim: Voucher bergabung dengan Rebate dan Rebate Manual (gross up 0).
--    Dipakai compile, submit, Reprocessing, rc_report_rows dan alat muat ulang, jadi semua ikut.
--    Nilai tersimpan pada dokumen Voucher yang sudah ada dihitung ulang menjadi 0.
--    Prod 14 Oktober 2026: 0 dokumen Voucher; dev: 425.
--
-- 2. ARSIP DOKUMEN TANPA CUSTOMER MASTER
--    Trigger jaga_customer_master_klaim menolak SETIAP perubahan dokumen yang belum punya
--    Customer Master ("Customer Master ... belum tersedia; klaim tidak dapat diproses"),
--    termasuk pengarsipan. Akibatnya dokumen "Customer Master belum ada" tidak dapat dihapus
--    (diarsipkan) dari Document Center. Prod 14 Oktober 2026: 774 dokumen seperti itu.
--    Sekarang perubahan yang HANYA menyentuh kolom arsip (archived_at, archived_by,
--    archive_reason, updated_at, version_no) diizinkan - mengarsipkan maupun memulihkan.
--    Perubahan lain (memproses, mengubah nilai) tetap ditolak seperti sebelumnya.
--
-- 3. DAFTAR "LIHAT ARSIP" DOCUMENT CENTER
--    rc_archived_list berjalan dengan hak pemanggil, sedangkan RLS claims_scope hanya membuka
--    baris yang BELUM diarsipkan - jadi daftar arsip selalu kosong bagi siapa pun, dan baris
--    terarsip tidak dapat dipulihkan dari layar. Sekarang SECURITY DEFINER dengan penjagaan yang
--    sama: tab compilation.archive, boleh_arsip_compilation, dan depot dalam jangkauan
--    pemanggil. Dokumen tanpa Customer Master ikut tampil (kode toko dari sumber).
--
-- Ditambal dengan penjaga MD5 pra-citra (14 Oktober 2026; dev dan prod sama).
-- ==========================================================================================

do $jaga$
begin
  if md5(replace(pg_get_functiondef('rc_private.gross_up_klaim(numeric,text,text,text)'::regprocedure), E'\r', '')) <> '27380ad8ec3fdd29348a2a895efdb3c4'
     and pg_get_functiondef('rc_private.gross_up_klaim(numeric,text,text,text)'::regprocedure) !~ '20261163120000' then
    raise exception 'DITOLAK: rc_private.gross_up_klaim berbeda dari yang diukur.'; end if;
  if md5(replace(pg_get_functiondef('rc_private.jaga_customer_master_klaim()'::regprocedure), E'\r', '')) <> 'bd4957044ce496d12e5226cbe7fa5a63'
     and pg_get_functiondef('rc_private.jaga_customer_master_klaim()'::regprocedure) !~ '20261163120000' then
    raise exception 'DITOLAK: rc_private.jaga_customer_master_klaim berbeda dari yang diukur.'; end if;
  if md5(replace(pg_get_functiondef('public.rc_archived_list(integer,integer)'::regprocedure), E'\r', '')) <> '3f0fdff91f7e0484f7e2d02aafa1cf39'
     and pg_get_functiondef('public.rc_archived_list(integer,integer)'::regprocedure) !~ '20261163120000' then
    raise exception 'DITOLAK: rc_archived_list berbeda dari yang diukur.'; end if;
end
$jaga$;

create or replace function public.rc_archived_list(p_offset integer default 0, p_limit integer default 100)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
-- 20261163120000: SECURITY DEFINER - sebagai SECURITY INVOKER daftar ini selalu kosong karena RLS
-- claims_scope hanya membuka baris yang belum diarsipkan. Hak dijaga di sini: tab
-- compilation.archive, boleh_arsip_compilation, dan depot dalam jangkauan pemanggil.
declare v jsonb;
begin
 perform rc_private.require_tab('compilation.archive');
 if not rc_private.boleh_arsip_compilation() /* 20261162130000 */ then raise exception 'Anda belum diberi akses Archive Compilation' using errcode='42501'; end if;
 select coalesce(jsonb_agg(x),'[]'::jsonb) into v from (
  select jsonb_build_object('id',c.id,'noDoc',c.no_doc,'kodeToko',coalesce(cu.customer_code,c.source_customer_code),
   'namaToko',coalesce(cu.customer_name,'Customer Master belum ada'),
   'codeCampaign',ca.campaign_code,'cbNet',c.cb_net,
   'alasan',coalesce(c.archive_reason,''),'olehUser',coalesce(p.user_code,''),
   'waktu',rc_private.legacy_ts(c.archived_at)) as x
  from public.claims c
  left join public.customers cu on cu.id=c.customer_id
  join public.campaigns ca on ca.id=c.campaign_id
  left join public.profiles p on p.id=c.archived_by
  where c.archived_at is not null and rc_private.can_access(c.depot_id)
  order by c.archived_at desc
  limit least(greatest(coalesce(p_limit,100),1),500) offset greatest(coalesce(p_offset,0),0)) t;
 return jsonb_build_object('status','success','rows',v);
end $function$;
revoke all on function public.rc_archived_list(integer, integer) from public, anon;
grant execute on function public.rc_archived_list(integer, integer) to authenticated, service_role;

create or replace function rc_private.gross_up_klaim(p_net numeric, p_subyek text, p_status_campaign text, p_jenis text)
 returns numeric
 language sql
 immutable
as $function$
  -- 20261162250000: seluruh Rebate (Rebate dan Rebate Manual) tanpa gross up.
  -- 20261163120000: Voucher juga tanpa gross up.
  select case when rc_private.jenis_efektif(p_jenis) in ('rebate', 'rebate manual', 'voucher') then 0
              else rc_private.gross_claimed(p_net, p_subyek, p_status_campaign) end;
$function$;

create or replace function rc_private.jaga_customer_master_klaim()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if old.customer_id is null and new.customer_id is null then
    -- 20261163120000: mengarsipkan dan memulihkan dokumen tanpa Customer Master tetap boleh,
    -- asalkan yang berubah HANYA kolom arsip. Memproses dokumen itu tetap ditolak.
    if old.archived_at is distinct from new.archived_at
       and (to_jsonb(new) - array['archived_at','archived_by','archive_reason','updated_at','version_no'])
         = (to_jsonb(old) - array['archived_at','archived_by','archive_reason','updated_at','version_no']) then
      return new;
    end if;
    raise exception using
      errcode = '23503',
      message = format('Customer Master %s belum tersedia; klaim tidak dapat diproses.',
        coalesce(new.source_customer_code, '(kode tidak tersedia)'));
  end if;
  return new;
end
$function$;

-- Gross up tersimpan pada dokumen Voucher dihitung ulang (0). Dokumen tanpa Customer Master
-- dilewati karena triggernya menolak perubahan nilai; nilainya dihitung saat master tersedia.
do $hitung$
declare n integer;
begin
  update public.claims c set gross_up = 0
    from public.campaigns ca
   where ca.id = c.campaign_id and c.customer_id is not null
     and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''), ca.cashback_type)) = 'voucher'
     and coalesce(c.gross_up, -1) <> 0;
  get diagnostics n = row_count;
  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'gross_up_voucher_dinolkan', jsonb_build_object('dokumen', n, 'migrasi', '20261163120000'));
  raise notice 'Gross up Voucher dinolkan pada % dokumen.', n;
end
$hitung$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (dibatalkan)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; d record; r jsonb; e text := ''; v_galat text; v_arsip timestamptz;
begin
  if rc_private.gross_up_klaim(1000000, 'Perorangan', 'Customer', 'Voucher') <> 0
     or rc_private.gross_up_klaim(1000000, 'Perorangan', 'Customer', 'Rebate Manual') <> 0
     or rc_private.gross_up_klaim(1000000, 'Badan', 'Customer', 'Transfer') = 0 then
    e := e || ' rumus gross up;'; end if;
  if exists(select 1 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
             where c.customer_id is not null and coalesce(c.gross_up, 0) <> 0
               and rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override,''), ca.cashback_type)) = 'voucher') then
    e := e || ' masih ada dokumen Voucher dengan gross up bukan 0;'; end if;

  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  select c.id, c.no_doc, c.version_no, c.source_customer_code into d from public.claims c
   where c.archived_at is null order by c.customer_id is null desc, c.no_doc limit 1;
  if v_sm is not null and d.id is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    begin
      -- Jadikan dokumen tanpa Customer Master (bila belum), lalu arsipkan dan pulihkan.
      update public.claims set customer_id = null, source_customer_code = coalesce(source_customer_code, 'UJI-TANPA-MASTER') where id = d.id and customer_id is not null;
      execute 'set local role authenticated';
      r := public.rc_archive_compilation(array[d.id], 'uji arsip tanpa Customer Master');
      execute 'reset role';
      select archived_at into v_arsip from public.claims where id = d.id;
      if (r->>'jumlah')::int <> 1 or v_arsip is null then e := e || format(' arsip tanpa master: %s;', r); end if;
      execute 'set local role authenticated';
      r := public.rc_archived_list(0, 500);
      execute 'reset role';
      if not exists(select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = d.id::text) then
        e := e || ' dokumen terarsip tidak tampil di Lihat Arsip;'; end if;
      execute 'set local role authenticated';
      r := public.rc_unarchive_compilation(array[d.id]);
      execute 'reset role';
      if (select archived_at from public.claims where id = d.id) is not null then e := e || format(' pulihkan arsip tanpa master: %s;', r); end if;
      -- Perubahan selain arsip tetap ditolak.
      begin
        update public.claims set cb_net = cb_net + 1 where id = d.id;
        e := e || ' perubahan nilai dokumen tanpa master diterima;';
      exception when others then v_galat := sqlerrm;
        if v_galat !~ 'belum tersedia' then e := e || ' pesan penjaga: ' || v_galat || ';'; end if;
      end;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' arsip: ' || sqlerrm || ';'; end if;
    end;
    perform set_config('request.jwt.claims', '', true);
  end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
