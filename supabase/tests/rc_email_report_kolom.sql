-- ==========================================================================================
-- Uji email report: Kode Depot / Nama Depot terpisah, Region kode saja, PDF Daily (20261163580000)
-- ==========================================================================================
-- Email disusun sebagai pratinjau (tidak dikirim); seluruhnya dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_report_kolom.sql
-- ==========================================================================================
create temp table if not exists _hasil_kol(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_kol;

do $uji$
declare hasil jsonb := '[]'; v_html text; v_kode text; v_nama text; v_pertama text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    v_html := coalesce(public.rc_email_susun('daily', false)->>'isiHtml', '');
    hasil := hasil || jsonb_build_object('uji', 'Daily: tabel Top Depot berkolom Kode Depot dan Nama Depot terpisah',
      'lulus', v_html ~ '>Kode Depot</th>' and v_html ~ '>Nama Depot</th>', 'rinci', '-');

    v_html := coalesce(public.rc_email_susun('weekly', false)->>'isiHtml', '');
    hasil := hasil || jsonb_build_object('uji', 'Weekly: tabel Top Depot terpisah; tabel Region tanpa tulisan "Region" di depan kode',
      'lulus', v_html ~ '>Kode Depot</th>' and v_html ~ '>Nama Depot</th>' and v_html !~ '>Region [^<]',
      'rinci', coalesce(substring(v_html from '>Region [^<]{1,12}'), '-'));

    v_html := rc_private.pdf_detail_html('Uji');
    select d.depot_code, d.depot_name into v_kode, v_nama
      from public.rc_report_rows c join public.depots d on d.id = c.depot_id
     group by d.depot_code, d.depot_name
     order by coalesce(sum(c.cb_net) filter (where c.outstanding_claim), 0) / nullif(sum(c.cb_net), 0) desc nulls last,
              coalesce(sum(c.cb_net) filter (where c.outstanding_claim), 0) desc limit 1;
    v_pertama := substring(substring(v_html from 'Performa per Depot.*') from '<tr><td>([^<]+)</td>');
    hasil := hasil || jsonb_build_object('uji', 'PDF Daily: Kode Depot / Nama Depot terpisah; Performa per Depot berkolom Outstanding Claim, urut tertinggi',
      'lulus', v_html ~ '<th align="left">Kode Depot</th><th align="left">Nama Depot</th>' and position('<td>' || v_kode || ' - ' in v_html) = 0
        and v_pertama = v_kode and substring(v_html from 'Performa per Depot.*') ~ 'Outstanding Claim</th>',
      'rinci', coalesce(v_pertama, '?') || ' vs ' || coalesce(v_kode, '?'));
    hasil := hasil || jsonb_build_object('uji', 'PDF Daily: Performa per Campaign berkolom Outstanding Claim',
      'lulus', substring(v_html from 'Performa per Campaign.*') ~ 'Outstanding Claim</th>', 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_kol(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_kol order by urut;
