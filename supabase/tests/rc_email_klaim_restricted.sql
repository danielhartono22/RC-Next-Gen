-- ==========================================================================================
-- Uji 11 November 2026: email klaim Normal Claim + Restricted Claim (910000)
-- ==========================================================================================
-- Seluruh perubahan dibatalkan lewat UJI_SELESAI.
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_klaim_restricted.sql
-- ==========================================================================================
create temp table if not exists _hasil_er(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_er;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_dep uuid; v_norm uuid[]; v_lunas uuid; v_tua uuid; v_bd uuid; v_html text; v_n text;
  v_as date; v_tua_bulan text; r record;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password and suffix_num ~ '^[0-9]{3}$' order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  begin
    -- Depot dengan data debtor dan tiga toko Not Yet berbeda yang punya baris ZDAGE.
    select c.depot_id into v_dep from public.claims c join public.customers cu on cu.id = c.customer_id
      join public.rc_zdage_depot_data dd on dd.depot_id = c.depot_id
      join public.rc_zdage_rows zr on zr.upload_id = dd.upload_id and zr.customer_key = rc_private.kode_toko(cu.customer_code)
     where c.status = 'not_yet' and c.archived_at is null group by 1 having count(distinct c.customer_id) >= 6 order by count(*) desc limit 1;
    if v_dep is null then raise exception 'Fixture: depot dengan data debtor tidak ada'; end if;
    select u.as_of_month into v_as from public.rc_zdage_depot_data dd join public.rc_zdage_uploads u on u.id = dd.upload_id where dd.depot_id = v_dep;
    v_tua_bulan := to_char(v_as - interval '8 months', 'YYYY-MM');

    -- Tiga toko Restricted: (1) belum lunas tanpa tunggakan tua, (2) tunggakan > 6 bulan, (3) ditandai Bad Debt.
    for r in select distinct on (c.customer_id) c.id, c.customer_id, cu.customer_code
               from public.claims c join public.customers cu on cu.id = c.customer_id
               join public.rc_zdage_depot_data dd on dd.depot_id = c.depot_id
               join public.rc_zdage_rows zr on zr.upload_id = dd.upload_id and zr.customer_key = rc_private.kode_toko(cu.customer_code)
              where c.depot_id = v_dep and c.status = 'not_yet' and c.archived_at is null
                and not exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active')
              order by c.customer_id, c.no_doc limit 3 loop
      if v_lunas is null then v_lunas := r.id;
      elsif v_tua is null then v_tua := r.id;
      else v_bd := r.id; end if;
    end loop;
    -- Toko (1): tanpa tunggakan tua, overdue 5.000.000. Toko (2): tunggakan 8 bulan lalu 7.000.000.
    update public.rc_zdage_rows zr set overdue_amt = 5000000, bucket_older = 0,
           buckets = (select coalesce(jsonb_object_agg(e.key, 0), '{}') from jsonb_each(coalesce(zr.buckets, '{}')) e)
      from public.rc_zdage_depot_data dd, public.claims c, public.customers cu
     where dd.depot_id = v_dep and zr.upload_id = dd.upload_id and c.id = v_lunas and cu.id = c.customer_id and zr.customer_key = rc_private.kode_toko(cu.customer_code);
    update public.rc_zdage_rows zr set overdue_amt = 9000000, bucket_older = 0,
           buckets = (select coalesce(jsonb_object_agg(e.key, 0), '{}') from jsonb_each(coalesce(zr.buckets, '{}')) e) || jsonb_build_object(v_tua_bulan, 7000000)
      from public.rc_zdage_depot_data dd, public.claims c, public.customers cu
     where dd.depot_id = v_dep and zr.upload_id = dd.upload_id and c.id = v_tua and cu.id = c.customer_id and zr.customer_key = rc_private.kode_toko(cu.customer_code);
    update public.rc_zdage_rows zr set bucket_older = 0,
           buckets = (select coalesce(jsonb_object_agg(e.key, 0), '{}') from jsonb_each(coalesce(zr.buckets, '{}')) e)
      from public.rc_zdage_depot_data dd, public.claims c, public.customers cu
     where dd.depot_id = v_dep and zr.upload_id = dd.upload_id and c.id = v_bd and cu.id = c.customer_id and zr.customer_key = rc_private.kode_toko(cu.customer_code);
    insert into public.rc_bad_debt_remarks(customer_id, reason, created_by) select customer_id, 'Uji', v_sm from public.claims where id = v_bd;
    insert into public.rc_clearing_offers(claim_id, result, reason, offered_at, offered_by, status)
    select x, 'RESTRICTED', '{}'::jsonb, now(), v_sm, 'processed' from unnest(array[v_lunas, v_tua, v_bd]) x;
    -- Dua dokumen normal dari toko lain di depot yang sama.
    select array_agg(id) into v_norm from (select c.id from public.claims c where c.depot_id = v_dep and c.status = 'not_yet' and c.archived_at is null
       and c.id not in (v_lunas, v_tua, v_bd) and c.customer_id not in (select customer_id from public.claims where id in (v_lunas, v_tua, v_bd))
       and not exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id) order by c.no_doc limit 2) z;

    v_html := rc_private.email_pengajuan_html('submit_langsung', '010000000000001', v_norm, v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Tanpa dokumen Restricted: email tetap seperti semula (satu tabel, GRAND TOTAL, tanpa bagian Restricted)',
      'lulus', v_html !~ 'RESTRICTED CLAIM' and v_html !~ 'NORMAL CLAIM' and v_html ~ 'GRAND TOTAL' and v_html ~ 'NAMA CAMPAIGN', 'rinci', '-');

    v_html := rc_private.email_pengajuan_html('submit_langsung', '010000000000001', v_norm || array[v_lunas, v_tua, v_bd], v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Satu email: bagian NORMAL CLAIM dan RESTRICTED CLAIM, grand total gabungan',
      'lulus', v_html ~ 'NORMAL CLAIM' and v_html ~ 'TOTAL NORMAL CLAIM' and v_html ~ 'RESTRICTED CLAIM' and v_html ~ 'TOTAL RESTRICTED CLAIM \(3 toko\)'
           and v_html ~ 'GRAND TOTAL \(NORMAL \+ RESTRICTED\)' and v_html ~ '5 dokumen\.', 'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Restricted per dokumen: No Doc dan keterangan masing-masing',
      'lulus', v_html ~ (select no_doc from public.claims where id = v_lunas) and v_html ~ (select no_doc from public.claims where id = v_tua) and v_html ~ (select no_doc from public.claims where id = v_bd), 'rinci', '-');
    select string_agg(case when i.claim_id = v_lunas then 'lunas' when i.claim_id = v_tua then 'tua' else 'bd' end || ':' || i.bad_debt_tanda || '/' || coalesce(i.overdue::text, '-') || '/' || coalesce(i.tua::text, '-'), ' ') into v_n
      from rc_private.email_info_restricted(array[v_lunas, v_tua, v_bd]) i;
    hasil := hasil || jsonb_build_object('uji', 'Keterangan: belum lunas + Overdue; tunggakan > 6 bulan = Bad Debt; toko bertanda Bad Debt = Bad Debt',
      'lulus', (select not i.bad_debt_tanda and i.overdue = 5000000 and coalesce(i.tua, 0) = 0 from rc_private.email_info_restricted(array[v_lunas]) i)
           and (select not i.bad_debt_tanda and i.tua = 7000000 from rc_private.email_info_restricted(array[v_tua]) i)
           and (select i.bad_debt_tanda from rc_private.email_info_restricted(array[v_bd]) i)
           and v_html ~ 'Toko belum lunas' and v_html ~ 'Overdue Amount: <span[^>]*nowrap[^>]*>Rp 5\.000\.000' and v_html ~ 'Tidak bayar &gt; 6 bulan: <span[^>]*nowrap[^>]*>Rp 7\.000\.000'
           and (length(v_html) - length(replace(v_html, '>Bad Debt</strong>', ''))) / length('>Bad Debt</strong>') = 2,
      'rinci', v_n);
    v_html := rc_private.email_pengajuan_html('clearing', '040000000000001', v_norm || array[v_lunas], v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Email selain klaim (clearing) tidak dipisah', 'lulus', v_html !~ 'RESTRICTED CLAIM', 'rinci', '-');
    v_html := rc_private.email_pengajuan_html('approve', '020000000000001', array[v_tua], v_sm, '');
    hasil := hasil || jsonb_build_object('uji', 'Hanya Restricted (approve): tanpa tabel Normal, tetap ada grand total',
      'lulus', v_html ~ 'RESTRICTED CLAIM' and v_html !~ 'NORMAL CLAIM' and v_html !~ 'JUMLAH TOKO' and v_html ~ 'GRAND TOTAL \(NORMAL \+ RESTRICTED\)', 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  perform set_config('request.jwt.claims', '', true);
  insert into _hasil_er(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_er order by urut;
