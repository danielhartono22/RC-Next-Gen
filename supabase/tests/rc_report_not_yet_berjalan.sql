-- ==========================================================================================
-- Uji Report tanpa Not Yet dari campaign yang Billing End-nya belum lewat (20261163630000)
-- ==========================================================================================
-- Perubahan tanggal campaign / perpanjangan dan snapshot dibatalkan lewat UJI_SELESAI.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_report_not_yet_berjalan.sql
-- ==========================================================================================
create temp table if not exists _hasil_nyb(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_nyb;

do $uji$
declare hasil jsonb := '[]'; v_k uuid; v_ca uuid; v_be date; v_hari date := (now() at time zone 'Asia/Jakarta')::date; r jsonb; n integer;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    -- Dokumen Not Yet tanpa perpanjangan dari campaign yang sudah lewat Billing End (ada di Report).
    select c.id, c.campaign_id, ca.billing_end into v_k, v_ca, v_be from public.claims c join public.campaigns ca on ca.id = c.campaign_id
     where c.status = 'not_yet' and c.archived_at is null and c.extend_billing_end is null and ca.billing_end is not null
       and exists (select 1 from public.rc_report_rows v where v.id = c.id) order by c.id limit 1;
    hasil := hasil || jsonb_build_object('uji', 'Not Yet dari campaign yang sudah lewat Billing End: tetap di Report',
      'lulus', v_k is not null and v_be < v_hari, 'rinci', coalesce(v_be::text, '-'));

    update public.campaigns set billing_end = v_hari where id = v_ca;
    hasil := hasil || jsonb_build_object('uji', 'Billing End = hari ini (belum lewat): Not Yet keluar dari Report',
      'lulus', not exists (select 1 from public.rc_report_rows where id = v_k), 'rinci', '-');
    update public.campaigns set billing_end = v_hari - 1 where id = v_ca;
    hasil := hasil || jsonb_build_object('uji', 'Billing End kemarin (sudah lewat): masuk lagi',
      'lulus', exists (select 1 from public.rc_report_rows where id = v_k), 'rinci', '-');

    update public.campaigns set billing_end = v_hari + 30 where id = v_ca;
    update public.claims set extend_billing_end = v_hari - 1 where id = v_k;
    hasil := hasil || jsonb_build_object('uji', 'Perpanjangan Billing End dokumen didahulukan dari Billing End campaign',
      'lulus', exists (select 1 from public.rc_report_rows where id = v_k), 'rinci', '-');
    update public.claims set extend_billing_end = v_hari + 5 where id = v_k;
    hasil := hasil || jsonb_build_object('uji', 'Perpanjangan ke depan: keluar dari Report',
      'lulus', not exists (select 1 from public.rc_report_rows where id = v_k), 'rinci', '-');
    update public.claims set extend_billing_end = null where id = v_k;

    update public.campaigns set billing_end = null, so_end = v_hari + 3, period_end = greatest(coalesce(period_end, v_hari), v_hari) where id = v_ca;
    hasil := hasil || jsonb_build_object('uji', 'Tanpa Billing End: memakai SO End (belum lewat = keluar)',
      'lulus', not exists (select 1 from public.rc_report_rows where id = v_k), 'rinci', '-');

    update public.claims set status = 'submitted' where id = v_k;
    hasil := hasil || jsonb_build_object('uji', 'Selain Not Yet (mis. Submitted) tetap dihitung walau campaign belum berakhir',
      'lulus', exists (select 1 from public.rc_report_rows where id = v_k), 'rinci', '-');
    update public.claims set status = 'not_yet' where id = v_k;

    hasil := hasil || jsonb_build_object('uji', 'Tidak ada Not Yet dari campaign yang belum lewat Billing End di Report',
      'lulus', not exists (select 1 from public.rc_report_rows r join public.claims c on c.id = r.id join public.campaigns ca on ca.id = c.campaign_id
                            where r.status = 'not_yet' and coalesce(c.extend_billing_end, ca.billing_end, ca.so_end, ca.period_end) >= v_hari),
      'rinci', '-');

    -- Report (lewat snapshot) mengikuti: Total Klaim = jumlah baris view.
    perform rc_private.segarkan_report('uji');
    r := rc_private.report_dashboard('{}');
    select count(*) into n from public.rc_report_rows;
    hasil := hasil || jsonb_build_object('uji', 'Report Dashboard (snapshot): Total Klaim = baris view, dokumen itu tidak dihitung',
      'lulus', (r->'kpi'->>'claimQty')::int = n and not exists (select 1 from rc_private.report_rows_snap where id = v_k),
      'rinci', (r->'kpi'->>'claimQty') || ' / ' || n);

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_nyb(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_nyb order by urut;
