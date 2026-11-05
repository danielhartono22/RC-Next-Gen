-- ==========================================================================================
-- Tagihan per dokumen dari Upload Debtor (ZDAGE): Tagihan dan Final Billing Month
-- ==========================================================================================
-- Pemilik, 21 Oktober 2026: "Tampilkan tagihan di kolom open dan document center serta di
-- details pada analytics" dan "Final billing month tagihan bulan apa aja, jika <1 tahun tulis
-- <1 tahun misal sep-26,okt-26,<1 yrs".
--
-- Sumber: data debtor yang BERLAKU untuk depot dokumen (rc_zdage_depot_data -> unggahan
-- terakhirnya), baris toko yang sama (kode toko tanpa nol di depan, rc_private.kode_toko) - persis
-- sumber yang dipakai evaluasi Open / Restricted (20261163170000).
--  * Tagihan            = Total (kolom F) toko itu.
--  * Final Billing Month = bulan-bulan (kolom G..S) yang masih bertagihan di atas toleransi
--                          unggahan (bawaan Rp 1), urut bulan, format "Sep-26"; kolom T
--                          ("<bulan tertua", lebih dari setahun) ditulis "<1 yrs" di akhir.
--  * Depot ditandai "Tidak ada tagihan", atau toko tidak ada di file -> Tagihan 0 (lunas).
--  * Depot tanpa data debtor sama sekali -> tidak diketahui ("-" di layar).
-- Kunci bulan disimpan sebagai bulan sebenarnya (YYYY-MM) dari header file, jadi pergeseran
-- kolom tiap bulan (Oct-2026..Oct-2025 lalu Nov-2026..Nov-2025) terbaca sendiri.
--
-- Satu RPC untuk ketiga layar (Open, Document Center, Details Analytics) - dipanggil untuk No Doc
-- yang sedang tampil, jangkauan depot pemanggil berlaku. Bergantung pada 20261163170000.
-- ==========================================================================================

create or replace function rc_private.tagihan_bulan(p_buckets jsonb, p_older numeric, p_tol numeric)
returns text language sql immutable set search_path = '' as $f$
  select concat_ws(', ',
    nullif((select string_agg(to_char(to_date(e.key, 'YYYY-MM'), 'Mon-YY'), ', ' order by e.key)
              from jsonb_each(coalesce(p_buckets, '{}'::jsonb)) e
             where e.key ~ '^\d{4}-\d{2}$'
               and coalesce(nullif(e.value #>> '{}', '')::numeric, 0) > coalesce(p_tol, 1)), ''),
    case when coalesce(p_older, 0) > coalesce(p_tol, 1) then '<1 yrs' end);
$f$;

create or replace function rc_private.tagihan_toko(p_depot uuid, p_kode text)
returns jsonb language sql stable security definer set search_path = '' as $f$
  select case
    when dd.depot_id is null then jsonb_build_object('status', 'tanpa_data')
    when dd.kosong then jsonb_build_object('status', 'kosong', 'tagihan', 0, 'overdue', 0, 'bulan', '',
                                            'asOf', to_char(dd.as_of_month, 'Mon-YYYY'))
    when r.upload_id is null then jsonb_build_object('status', 'tidak_di_file', 'tagihan', 0, 'overdue', 0, 'bulan', '',
                                                      'asOf', to_char(dd.as_of_month, 'Mon-YYYY'))
    else jsonb_build_object('status', 'ada', 'tagihan', r.total_amt, 'overdue', r.overdue_amt,
                            'bulan', rc_private.tagihan_bulan(r.buckets, r.bucket_older, coalesce(u.toleransi, 1)),
                            'asOf', to_char(dd.as_of_month, 'Mon-YYYY'))
  end
  from (select 1) z
  left join public.rc_zdage_depot_data dd on dd.depot_id = p_depot
  left join public.rc_zdage_uploads u on u.id = dd.upload_id
  left join public.rc_zdage_rows r on r.upload_id = dd.upload_id and r.customer_key = rc_private.kode_toko(p_kode);
$f$;

create or replace function public.rc_tagihan_dokumen(p_no_doc text[])
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare v_doc text[];
begin
  if not rc_private.can_access(null) then raise exception 'Access denied' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct upper(btrim(x))) filter (where btrim(x) <> ''), '{}')
    into v_doc from unnest(coalesce(p_no_doc, '{}')) x;
  if cardinality(v_doc) > 2000 then raise exception 'Maksimal 2000 dokumen per permintaan'; end if;
  if cardinality(v_doc) = 0 then return jsonb_build_object('status', 'success', 'data', '{}'::jsonb); end if;
  return jsonb_build_object('status', 'success', 'data', coalesce((
    select jsonb_object_agg(upper(c.no_doc), rc_private.tagihan_toko(c.depot_id, coalesce(cu.customer_code, c.source_customer_code)))
      from public.claims c
      left join public.customers cu on cu.id = c.customer_id
      cross join rc_private.lingkup_depot_saya() l
     where upper(c.no_doc) = any(v_doc) and (l.semua or c.depot_id = any(l.depot))), '{}'::jsonb));
end $f$;

revoke all on function rc_private.tagihan_bulan(jsonb, numeric, numeric), rc_private.tagihan_toko(uuid, text)
  from public, anon, authenticated;
revoke all on function public.rc_tagihan_dokumen(text[]) from public, anon;
grant execute on function public.rc_tagihan_dokumen(text[]) to authenticated;

do $cek$
begin
  if rc_private.tagihan_bulan('{"2026-08": 2885496.32, "2026-09": 245826.89, "2026-10": 0.5, "2025-10": 0}'::jsonb, 10, 1)
     <> 'Aug-26, Sep-26, <1 yrs' then
    raise exception 'GAGAL: format Final Billing Month %',
      rc_private.tagihan_bulan('{"2026-08": 2885496.32, "2026-09": 245826.89, "2026-10": 0.5, "2025-10": 0}'::jsonb, 10, 1);
  end if;
end $cek$;
