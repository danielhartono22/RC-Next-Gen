-- ==========================================================================================
-- Email report: Kode Depot dan Nama Depot terpisah, Region cukup kodenya
-- ==========================================================================================
-- Pemilik, 30 Oktober 2026: "untuk kolom kode depot dan nama depot dipisah di report, untuk
-- region cukup kode nya aja ga perlu tulisan region dengan default outstanding paling tinggi",
-- lalu "untuk separate di reportnya juga" (email report, selain modul Report).
--
--   DAILY / WEEKLY  tabel Top Depot: kolom Kode Depot dan Nama Depot terpisah (baris membawa kode,
--                   nama). Tabel Region Weekly: kode Region saja, tanpa tulisan "Region".
--   PDF DAILY       Top 10, Performa per Depot (Kode, Nama, Region), dan Performa per Campaign
--                   terpisah kolomnya; Performa per Depot / Campaign menambah Outstanding Claim dan
--                   diurutkan Outstanding Claim % tertinggi, sama dengan modul Report.
--   Diagram tetap memakai label "kode - nama" (satu label per batang).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $prasyarat$ begin
  if to_regprocedure('rc_private.email_judul_top(text,integer)') is null then
    raise exception 'DITOLAK: jalankan 20261163570000 (Outstanding Claim) lebih dulu.'; end if;
end $prasyarat$;

-- Tabel Top Depot: bila baris membawa kode dan nama, keduanya kolom terpisah; bila tidak, label.
create or replace function rc_private.email_tabel_performa(p_rows jsonb, p_judul text)
returns text language plpgsql stable set search_path = '' as $f$
declare
  th   text := 'style="text-align:left;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;"';
  thn  text := 'style="text-align:right;background:#f1f3f4;color:#5f6368;font-size:11px;padding:6px 8px;border-bottom:1px solid #e0e2e6;white-space:nowrap;"';
  td   text := 'style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;"';
  tdn  text := 'style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;white-space:nowrap;"';
  r jsonb; i integer := 0; isi text := ''; warna text; warna_oc text; v_pisah boolean;
begin
  if p_rows is null or jsonb_array_length(p_rows) = 0 then
    return '<p style="color:#5f6368;">Tidak ada data.</p>';
  end if;
  v_pisah := p_rows->0 ? 'kode'; -- 20261163580000
  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1;
    warna := rc_private.warna_persen((r->>'cr')::numeric);
    warna_oc := rc_private.warna_persen(1 - coalesce((r->>'oc')::numeric, 0));
    isi := isi || '<tr>'
      || '<td ' || td || ' width="24">' || i || '.</td>'
      || case when v_pisah
              then '<td ' || td || '><strong>' || rc_private.html_aman(r->>'kode') || '</strong></td>'
                   || '<td ' || td || '>' || rc_private.html_aman(r->>'nama') || '</td>'
              else '<td ' || td || '>' || rc_private.html_aman(r->>'label') || '</td>' end
      || '<td ' || tdn || '>' || rc_private.rupiah((r->>'netCb')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.angka((r->>'qty')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.rupiah((r->>'osVal')::numeric) || '</td>'
      || '<td ' || tdn || '>' || rc_private.angka((r->>'osQty')::numeric) || '</td>'
      || '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;'
      || 'white-space:nowrap;background-color:' || warna || ';color:#ffffff;font-weight:bold;" bgcolor="'
      || warna || '">' || rc_private.persen((r->>'cr')::numeric) || '</td>'
      || case when r ? 'oc' then
           '<td style="font-size:12px;padding:6px 8px;border-bottom:1px solid #f0f1f3;text-align:right;'
           || 'white-space:nowrap;background-color:' || warna_oc || ';color:#ffffff;font-weight:bold;" bgcolor="'
           || warna_oc || '">' || rc_private.persen((r->>'oc')::numeric) || '</td>'
         else '<td ' || tdn || '>-</td>' end
      || '</tr>';
  end loop;
  return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr><th ' || th || ' width="24">#</th>'
    || case when v_pisah then '<th ' || th || '>Kode ' || rc_private.html_aman(p_judul) || '</th><th ' || th || '>Nama ' || rc_private.html_aman(p_judul) || '</th>'
            else '<th ' || th || '>' || rc_private.html_aman(p_judul) || '</th>' end
    || '<th ' || thn || '>Net CB</th><th ' || thn || '>Claim Qty</th>'
    || '<th ' || thn || '>Outstanding</th><th ' || thn || '>Outstanding Qty</th>'
    || '<th ' || thn || '>Clearing Rate</th><th ' || thn || '>Outstanding Claim</th></tr></thead><tbody>' || isi || '</tbody></table>';
end $f$;

do $tambal$
declare src text; f text;
begin
  f := 'public.rc_email_susun(text,boolean,text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163580000' then raise notice '% sudah ditambal.', f;
  else
    src := pg_temp.ganti(src, $p$'label',depot_code||' - '||depot_name,$p$,
      $p$'label',depot_code||' - '||depot_name,'kode',depot_code,'nama',depot_name,$p$, 2, 'public.rc_email_susun(text,boolean,text) #1');
    src := pg_temp.ganti(src, $p$border-bottom:1px solid #f0f1f3;">Region '
      ||rc_private.html_aman(q.region)||'</td>'$p$,
      $p$border-bottom:1px solid #f0f1f3;">' /* 20261163580000: kode Region saja */
      ||rc_private.html_aman(q.region)||'</td>'$p$, 1, 'public.rc_email_susun(text,boolean,text) #2');
    execute src;
  end if;

  f := 'rc_private.pdf_detail_html(text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src ~ '20261163580000' then raise notice '% sudah ditambal.', f;
  else
    src := pg_temp.ganti(src, $p$      '<tr><td>' || rc_private.html_aman(q.label) || '</td>'
      || '<td align="right">' || rc_private.rupiah(q.net_cb) || '</td>'$p$,
      $p$      '<tr><td>' || rc_private.html_aman(q.kode) || '</td><td>' || rc_private.html_aman(q.nama) || '</td>' /* 20261163580000 */
      || '<td align="right">' || rc_private.rupiah(q.net_cb) || '</td>'$p$, 1, 'rc_private.pdf_detail_html(text) #1');
    src := pg_temp.ganti(src, $p$    from (select d.depot_code || ' - ' || d.depot_name as label,$p$,
      $p$    from (select d.depot_code || ' - ' || d.depot_name as label, d.depot_code kode, d.depot_name nama,$p$, 2, 'rc_private.pdf_detail_html(text) #2');
    src := pg_temp.ganti(src, $p$           order by 2 limit 10) q;$p$,
      $p$           order by urut limit 10) q;$p$, 1, 'rc_private.pdf_detail_html(text) #3');
    src := pg_temp.ganti(src, $p$    || '<tr><th align="left">Depot</th><th align="right">Net CB</th><th align="right">Outstanding</th>'$p$,
      $p$    || '<tr><th align="left">Kode Depot</th><th align="left">Nama Depot</th><th align="right">Net CB</th><th align="right">Outstanding</th>'$p$, 1, 'rc_private.pdf_detail_html(text) #4');
    src := pg_temp.ganti(src, $p$      '<tr><td>' || rc_private.html_aman(q.label) || '</td>'
      || '<td>' || rc_private.html_aman(q.region) || '</td>'$p$,
      $p$      '<tr><td>' || rc_private.html_aman(q.kode) || '</td><td>' || rc_private.html_aman(q.nama) || '</td>'
      || '<td>' || rc_private.html_aman(q.region) || '</td>'$p$, 1, 'rc_private.pdf_detail_html(text) #5');
    src := pg_temp.ganti(src, $p$      || '<td align="right">' || rc_private.persen(q.cr) || '</td></tr>', '' order by q.cr, q.os_val desc), '')
    into v_baris
    from (select d.depot_code || ' - ' || d.depot_name as label, d.depot_code kode, d.depot_name nama,
                 coalesce(nullif(btrim(d.region),''),'-') region,$p$,
      $p$      || '<td align="right">' || rc_private.persen(q.cr) || '</td>'
      || '<td align="right">' || rc_private.persen(q.oc) || '</td></tr>', '' order by q.oc desc, q.oc_val desc), '')
    into v_baris
    from (select d.depot_code || ' - ' || d.depot_name as label, d.depot_code kode, d.depot_name nama,
                 coalesce(nullif(btrim(d.region),''),'-') region,
                 coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0) oc_val,
                 case when coalesce(sum(c.cb_net),0)=0 then 0
                      else coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0)/sum(c.cb_net) end oc,$p$, 1, 'rc_private.pdf_detail_html(text) #6');
    src := pg_temp.ganti(src, $p$    || '<tr><th align="left">Depot</th><th align="left">Region</th><th align="right">Qty</th>'
    || '<th align="right">Net CB</th><th align="right">Outstanding</th><th align="right">Clearing Rate</th></tr>'$p$,
      $p$    || '<tr><th align="left">Kode Depot</th><th align="left">Nama Depot</th><th align="left">Region</th><th align="right">Qty</th>'
    || '<th align="right">Net CB</th><th align="right">Outstanding</th><th align="right">Clearing Rate</th><th align="right">Outstanding Claim</th></tr>'$p$, 1, 'rc_private.pdf_detail_html(text) #7');
    src := pg_temp.ganti(src, $p$      || '<td align="right">' || rc_private.persen(q.cr) || '</td></tr>', '' order by q.cr, q.os_val desc), '')
    into v_baris
    from (select c.campaign_code || ' - ' || coalesce(c.campaign_name,'') as label,$p$,
      $p$      || '<td align="right">' || rc_private.persen(q.cr) || '</td>'
      || '<td align="right">' || rc_private.persen(q.oc) || '</td></tr>', '' order by q.oc desc, q.oc_val desc), '')
    into v_baris
    from (select c.campaign_code || ' - ' || coalesce(c.campaign_name,'') as label,
                 coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0) oc_val,
                 case when coalesce(sum(c.cb_net),0)=0 then 0
                      else coalesce(sum(c.cb_net) filter (where c.outstanding_claim),0)/sum(c.cb_net) end oc,$p$, 1, 'rc_private.pdf_detail_html(text) #8');
    src := pg_temp.ganti(src, $p$    || '<th align="right">Outstanding</th><th align="right">Clearing Rate</th></tr>'
    || v_baris || '</table>';

  return v_html$p$,
      $p$    || '<th align="right">Outstanding</th><th align="right">Clearing Rate</th><th align="right">Outstanding Claim</th></tr>'
    || v_baris || '</table>';

  return v_html$p$, 1, 'rc_private.pdf_detail_html(text) #9');
    execute src;
  end if;
end $tambal$;

do $cek$
declare e text := '';
begin
  if pg_get_functiondef('public.rc_email_susun(text,boolean,text)'::regprocedure) !~ '20261163580000' then e := e || ' email_susun;'; end if;
  if pg_get_functiondef('rc_private.pdf_detail_html(text)'::regprocedure) !~ '20261163580000' then e := e || ' pdf;'; end if;
  if rc_private.email_tabel_performa('[{"kode":"4A","nama":"Medan","label":"4A - Medan","cr":0.5,"oc":0.1}]', 'Depot') !~ 'Kode Depot'
     or rc_private.email_tabel_performa('[{"label":"X","cr":0.5}]', 'Depot') ~ 'Kode Depot' then e := e || ' tabel performa;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
