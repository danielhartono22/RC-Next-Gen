-- ==========================================================================================
-- Email klaim: Normal Claim dan Restricted Claim dalam satu email
-- ==========================================================================================
-- Pemilik, 11 November 2026: "saya mau tetep bisa claim hanya aja nanti di email dibedakan dengan
-- normal claim dan restricted claim dengan keterangan tambahan : Toko belum lunas, overdue amount,
-- atau kalo lebih dari 6 bulan ga bayar ditandai baddebt. tetep dalam 1 email klaim yg sama."
--
-- Restricted -> Open sudah dapat di-claim (offer RESTRICTED membuka Claim Upload); yang berubah hanya
-- email pengajuan / approve (rc_private.email_pengajuan_html):
--   * Restricted Claim = dokumen yang tawaran terakhirnya RESTRICTED (dipindah editor dari Restricted
--     ke Open) atau yang diajukan ketika tokonya Bad Debt.
--   * Bagian "Normal Claim" (tabel lama per campaign) dan bagian "Restricted Claim" (per dokumen) dengan
--     Keterangan: "Toko belum lunas" + Overdue Amount, atau "Bad Debt" bila toko ditandai Bad Debt ATAU
--     punya tunggakan di bulan tagihan yang lebih dari 6 bulan sebelum bulan data ZDAGE terakhir depot
--     (bucket bulan + kolom "lebih lama"), di atas toleransi ZDAGE. Penanda Bad Debt ini hanya di email;
--     data Bad Debt toko (rc_bad_debt_remarks) tidak diubah.
--   * Grand total = Normal + Restricted. Email tanpa Restricted Claim tidak berubah sama sekali.
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function rc_private.email_info_restricted(p_ids uuid[])
returns table(claim_id uuid, bad_debt_tanda boolean, ada_data boolean, overdue numeric, tua numeric)
language sql stable security definer set search_path to '' as $f$
  select c.id,
         c.bad_debt_remark_id is not null
           or exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active'),
         coalesce(z.n, 0) > 0, z.overdue, z.tua
    from public.claims c
    left join public.rc_zdage_depot_data dd on dd.depot_id = c.depot_id
    left join public.rc_zdage_uploads u on u.id = dd.upload_id
    left join lateral (
      select count(*) n, sum(r.overdue_amt) overdue,
             sum(coalesce(r.bucket_older, 0) + coalesce((
               select sum(nullif(e.value, '')::numeric) from jsonb_each_text(coalesce(r.buckets, '{}'::jsonb)) e
                where e.key ~ '^\d{4}-\d{2}$'
                  and (extract(year from u.as_of_month)::int * 12 + extract(month from u.as_of_month)::int)
                      - (left(e.key, 4)::int * 12 + right(e.key, 2)::int) > 6), 0)) tua
        from public.rc_zdage_rows r
       where r.upload_id = dd.upload_id
         and r.customer_key = rc_private.kode_toko(coalesce((select cu.customer_code from public.customers cu where cu.id = c.customer_id), c.source_customer_code))
         and (r.depot_id is null or r.depot_id = c.depot_id)) z on true
   where c.id = any(p_ids)
     and (c.bad_debt_remark_id is not null
          or (select o.result from public.rc_clearing_offers o where o.claim_id = c.id order by o.created_at desc limit 1) = 'RESTRICTED');
$f$;
revoke all on function rc_private.email_info_restricted(uuid[]) from public, anon, authenticated;

create or replace function rc_private.email_pengajuan_html(p_action text, p_batch text, p_ids uuid[], p_aktor uuid, p_alasan text DEFAULT ''::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_depot text; v_kode text; v_baris text := ''; v_r record;
  v_toko int := 0; v_cb numeric := 0; v_doc int := 0; v_nama text;
  v_pembuka text; v_aksi text; v_aktual text; v_html text; v_judul text; -- 20261162270000
  -- 20261163910000: Restricted Claim
  v_res uuid[] := '{}'; v_norm uuid[]; v_rbaris text := ''; v_rtoko int := 0; v_rcb numeric := 0; v_rdoc int := 0; v_ket text;
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
begin
  select coalesce(d.depot_name, d.depot_code, ''), coalesce(d.depot_code,'')
    into v_depot, v_kode
    from public.claims c join public.depots d on d.id = c.depot_id
   where c.id = any(p_ids) limit 1;

  v_judul := rc_private.email_pengajuan_subjek(p_action,
               array[coalesce(nullif(v_depot,''),'Depot')]);

  select coalesce(full_name, user_code, '') into v_nama
    from public.profiles where id = p_aktor;

  -- 20261163910000: dokumen Restricted dipisahkan hanya pada email klaim (pengajuan dan approve).
  if p_action in ('submit', 'submit_langsung', 'approve') then
    v_res := coalesce((select array_agg(i.claim_id) from rc_private.email_info_restricted(p_ids) i), '{}');
  end if;
  v_norm := coalesce(array(select x from unnest(p_ids) x where not (x = any(v_res))), '{}');

  for v_r in
    select coalesce(ca.campaign_name, ca.campaign_code, '(tanpa campaign)') as campaign,
           count(distinct c.customer_id) as toko,
           count(*)                      as doc,
           coalesce(sum(c.cb_net),0)     as cb
      from public.claims c
      left join public.campaigns ca on ca.id = c.campaign_id
     where c.id = any(v_norm)
     group by 1
     order by 4 desc, 1
  loop
    v_toko := v_toko + v_r.toko;
    v_doc  := v_doc  + v_r.doc;
    v_cb   := v_cb   + v_r.cb;
    v_baris := v_baris
      || '<tr>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;white-space:nowrap;">'
         || rc_private.html_aman(coalesce(p_batch,'-')) || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;">'
         || rc_private.html_aman(v_r.campaign) || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;text-align:right;">'
         || v_r.toko::text || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;text-align:right;white-space:nowrap;">'
         || rc_private.rupiah(v_r.cb) || '</td>'
      || '</tr>';
  end loop;

  -- 20261163910000: Restricted Claim per dokumen dengan keterangannya.
  if cardinality(v_res) > 0 then
    for v_r in
      select c.no_doc, coalesce(cu.customer_code, c.source_customer_code, '') kode, coalesce(cu.customer_name, '') nama,
             coalesce(ca.campaign_name, ca.campaign_code, '(tanpa campaign)') campaign, coalesce(c.cb_net, 0) cb,
             i.bad_debt_tanda, i.ada_data, i.overdue, i.tua
        from rc_private.email_info_restricted(v_res) i
        join public.claims c on c.id = i.claim_id
        left join public.customers cu on cu.id = c.customer_id
        left join public.campaigns ca on ca.id = c.campaign_id
       order by 2, 1
    loop
      v_rdoc := v_rdoc + 1;
      v_rcb := v_rcb + v_r.cb;
      v_ket := case when v_r.bad_debt_tanda or coalesce(v_r.tua, 0) > rc_private.zdage_toleransi()
                 then '<strong style="color:#C8102E;">Bad Debt</strong>'
                      || case when coalesce(v_r.tua, 0) > rc_private.zdage_toleransi()
                              then '<br>Tidak bayar &gt; 6 bulan: <span style="white-space:nowrap;">' || rc_private.rupiah(v_r.tua) || '</span>' else '' end
                 else '<strong style="color:#b45309;">Toko belum lunas</strong>' end
               || '<br>Overdue Amount: <span style="white-space:nowrap;">' || case when v_r.ada_data then rc_private.rupiah(coalesce(v_r.overdue, 0)) else 'data debtor tidak ada' end || '</span>';
      v_rbaris := v_rbaris
        || '<tr>'
        || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(v_r.no_doc) || '</td>'
        || '<td style="' || v_td || '">' || rc_private.html_aman(v_r.kode || case when v_r.nama <> '' then ' - ' || v_r.nama else '' end) || '</td>'
        || '<td style="' || v_td || '">' || rc_private.html_aman(v_r.campaign) || '</td>'
        || '<td style="' || v_td || 'text-align:right;white-space:nowrap;">' || rc_private.rupiah(v_r.cb) || '</td>'
        || '<td style="' || v_td || 'line-height:1.5;">' || v_ket || '</td>'
        || '</tr>';
    end loop;
    select count(distinct coalesce(c.customer_id::text, c.source_customer_code)) into v_rtoko from public.claims c where c.id = any(v_res);
  end if;

  -- 20261162270000: nama campaign cukup di tabel; yang ditampilkan di atas tabel adalah
  -- tanggal transfer/proses aktual pilihan pengguna.
  select string_agg(distinct rc_private.tgl_panjang((c.cleared_actual_on + time '12:00') at time zone 'Asia/Jakarta'), ', ')
    into v_aktual
    from public.claims c
   where c.id = any(p_ids) and c.cleared_actual_on is not null;

  v_pembuka := case replace(p_action, 'submit_langsung', 'submit') /* 20261162180000 */
    when 'submit' then
      'Berikut terlampir pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong>.'
    when 'approve' then
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang telah disetujui.'
    when 'clearing' then
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_kode,''),'-')) || ' &ndash; '
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang telah selesai diproses.'
    when 'hold' then
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang ditahan sementara.'
    else
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang dihanguskan.'
    end;

  v_aksi := case p_action
    -- 20261163020000: approval dimatikan - cukup pengajuannya, tanpa catatan "melewati approval".
    when 'submit_langsung' then ''
    when 'submit'   then 'Mohon tim Management untuk segera melakukan approval atas pengajuan di atas.'
    when 'approve'  then 'Mohon tim OSC untuk segera memproses dokumen yang sudah di-approve.'
    when 'clearing' then 'Mohon tim Depo untuk mengecek kembali list toko pada nomor batch tersebut.'
    -- Kedua kalimat di bawah TIDAK ditetapkan pemilik; ditulis mengikuti suara yang sama.
    when 'hold'     then 'Mohon tim Depo untuk menindaklanjuti dokumen yang ditahan pada batch tersebut.'
    else                 'Mohon tim Depo untuk mencatat dokumen yang dihanguskan pada batch tersebut.'
    end;

  v_html :=
    rc_private.email_kepala(v_judul,
      'Depo ' || coalesce(nullif(v_depot,''),'-')
      || case when coalesce(p_batch,'') <> '' then '  |  Batch ' || p_batch else '' end)
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    || '<p style="line-height:1.6;">' || v_pembuka || '</p>'
    || case when p_action = 'clearing' then
         '<p style="line-height:1.6;">Tanggal transfer / proses aktual: <strong>'
         || rc_private.html_aman(coalesce(v_aktual,'-')) || '</strong></p>' else '' end
    || '<p style="line-height:1.6;color:#5f6368;font-size:12px;">'
    || case when p_action = 'clearing' then 'Diproses di sistem oleh <strong>' else 'Diproses oleh <strong>' end || rc_private.html_aman(coalesce(nullif(v_nama,''),'-'))
    || '</strong> pada ' || rc_private.tgl_panjang(now()) || ' '
    || to_char(now() at time zone 'Asia/Jakarta','HH24:MI') || ' WIB &middot; '
    || (v_doc + v_rdoc)::text || ' dokumen.</p>'
    || case when coalesce(btrim(p_alasan),'') = '' then ''
            else '<p style="line-height:1.6;background:#fff8e1;border-left:3px solid #f0ad4e;'
                 || 'padding:8px 12px;margin:12px 0;font-size:12px;"><strong>Alasan:</strong> '
                 || rc_private.html_aman(p_alasan) || '</p>' end
    -- ---- Normal Claim (tabel lama; tanpa judul bila tidak ada Restricted Claim) ----
    || case when v_rdoc > 0 and v_doc > 0 then '<p style="margin:16px 0 0;font-size:13px;font-weight:bold;color:#1f2937;">NORMAL CLAIM</p>' else '' end
    || case when v_doc > 0 or v_rdoc = 0 then
       '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" '
    || 'style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left"  style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">NO BATCH</th>'
    || '<th align="left"  style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">NAMA CAMPAIGN</th>'
    || '<th align="right" style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">JUMLAH TOKO</th>'
    || '<th align="right" style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">TOTAL CB</th>'
    || '</tr></thead><tbody>' || v_baris || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;">'
    || '<td colspan="2" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">' || case when v_rdoc > 0 then 'TOTAL NORMAL CLAIM' else 'GRAND TOTAL' end || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;">'
       || v_toko::text || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">'
       || rc_private.rupiah(v_cb) || '</td>'
    || '</tr></tfoot></table>' else '' end
    -- ---- Restricted Claim ----
    || case when v_rdoc = 0 then '' else
       '<p style="margin:20px 0 0;font-size:13px;font-weight:bold;color:#C8102E;">RESTRICTED CLAIM</p>'
    || '<p style="margin:4px 0 0;font-size:11px;color:#5f6368;">Dokumen dari toko yang belum lunas / Bad Debt, diajukan setelah dipindahkan dari Restricted ke Open. '
    || 'Overdue Amount dari data debtor (ZDAGE) terakhir depot; Bad Debt = ditandai Bad Debt atau ada tagihan yang tidak dibayar lebih dari 6 bulan.</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:8px;">'
    || '<thead><tr style="background:#fdecef;">'
    || '<th align="left" style="' || v_th || '">NO DOC</th>'
    || '<th align="left" style="' || v_th || '">TOKO</th>'
    || '<th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="right" style="' || v_th || '">TOTAL CB</th>'
    || '<th align="left" style="' || v_th || '">KETERANGAN</th>'
    || '</tr></thead><tbody>' || v_rbaris || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;">'
    || '<td colspan="3" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL RESTRICTED CLAIM (' || v_rtoko::text || ' toko)</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_rcb) || '</td>'
    || '<td></td></tr></tfoot></table>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
    || '<tr style="background:#C8102E;"><td style="padding:10px;font-size:12px;font-weight:bold;color:#ffffff;">GRAND TOTAL (NORMAL + RESTRICTED)</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#ffffff;">' || (v_toko + v_rtoko)::text || ' toko</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#ffffff;white-space:nowrap;">' || rc_private.rupiah(v_cb + v_rcb) || '</td></tr></table>'
    end
    || rc_private.email_remark_bad_debt(v_norm) /* 20261163170000; Bad Debt Restricted Claim sudah di bagiannya sendiri */
    || case when coalesce(v_aksi,'') = '' then ''
            else '<p style="line-height:1.6;margin-top:16px;">' || v_aksi || '</p>' end
    || rc_private.email_ttd()
    || '</td></tr></table>';

  return rc_private.email_outlook(v_html); -- 20261163020000
end
$function$;

do $cek$
begin
  if pg_get_functiondef('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)'::regprocedure) !~ 'RESTRICTED CLAIM' then raise exception 'GAGAL: email'; end if;
end $cek$;
