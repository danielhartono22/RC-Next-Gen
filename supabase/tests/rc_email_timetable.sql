-- ==========================================================================================
-- Uji email Timetable (20261163650000): Top 10 Depot / Campaign belum diupload (Not Yet, Billing
-- End lewat) dan dashboard Timetable di badan email.
-- ==========================================================================================
-- Perubahan tanggal campaign dan dokumen uji dibatalkan lewat UJI_SELESAI. Email hanya pratinjau.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_email_timetable.sql
-- ==========================================================================================
create temp table if not exists _hasil_tte(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_tte;

do $uji$
declare hasil jsonb := '[]'; r jsonb; r2 jsonb; v_html text; v_hari date := (now() at time zone 'Asia/Jakarta')::date;
  v_tahun integer := rc_private.timetable_tahun_baku(); v_n integer; v_top jsonb; v_ca uuid; v_dep uuid; v_kode text; v_kdep text;
begin
  begin
    perform set_config('request.jwt.claims', '', true);
    -- Hitungan bebas: pasangan depot aktif x campaign tahun bawaan, Not Yet, Billing End lewat.
    create temp table _tt_pas on commit drop as
    with k as (select ca.id, ca.campaign_code, coalesce(ca.billing_end, ca.so_end, ca.period_end) akhir from public.campaigns ca
                where ca.archived_at is null and extract(year from coalesce(ca.period_start, ca.period_end))::integer = v_tahun
                  and not exists (select 1 from public.excluded_campaigns x where x.campaign_id = ca.id)),
         d as (select id, depot_code from public.depots where archived_at is null and not bukan_depot)
    select d.id depot_id, d.depot_code, k.id campaign_id, k.campaign_code, k.akhir from d cross join k
     where k.akhir < v_hari
       and not exists (select 1 from public.claims c where c.depot_id = d.id and c.campaign_id = k.id and c.archived_at is null)
       and not exists (select 1 from public.timetable_not_achieved na where na.depot_id = d.id and na.campaign_id = k.id)
       and not rc_private.np_pasangan(d.id, k.id);

    r := rc_private.tt_email_isi(null);
    select count(*) into v_n from _tt_pas;
    hasil := hasil || jsonb_build_object('uji', 'Belum diupload = pasangan Not Yet dengan Billing End lewat (hitungan bebas sama)',
      'lulus', (r->>'belum')::int = v_n and (r->>'tahun')::int = v_tahun, 'rinci', (r->>'belum') || ' / ' || v_n);
    select coalesce(jsonb_agg(jsonb_build_object('kode', depot_code, 'n', n) order by n desc, depot_code), '[]') into v_top
      from (select depot_code, count(*) n from _tt_pas group by 1 order by 2 desc, 1 limit 10) z;
    hasil := hasil || jsonb_build_object('uji', 'Top 10 Depot: maks 10, urut terbanyak, angka sama dengan hitungan bebas',
      'lulus', jsonb_array_length(r->'topDepot') <= 10
           and (select jsonb_agg(jsonb_build_object('kode', x->>'kode', 'n', (x->>'n')::int) order by i) from jsonb_array_elements(r->'topDepot') with ordinality q(x, i)) is not distinct from nullif(v_top, '[]'),
      'rinci', left((r->'topDepot')::text, 200));
    select coalesce(jsonb_agg(jsonb_build_object('kode', campaign_code, 'n', n) order by n desc, campaign_code), '[]') into v_top
      from (select campaign_code, count(*) n from _tt_pas group by 1 order by 2 desc, 1 limit 10) z;
    hasil := hasil || jsonb_build_object('uji', 'Top 10 Campaign: maks 10, urut terbanyak, angka sama dengan hitungan bebas',
      'lulus', jsonb_array_length(r->'topCampaign') <= 10
           and (select jsonb_agg(jsonb_build_object('kode', x->>'kode', 'n', (x->>'n')::int) order by i) from jsonb_array_elements(r->'topCampaign') with ordinality q(x, i)) is not distinct from nullif(v_top, '[]'),
      'rinci', left((r->'topCampaign')::text, 200));

    -- Campaign yang Billing End-nya dimundurkan ke depan keluar dari hitungan.
    select campaign_id, campaign_code into v_ca, v_kode from _tt_pas group by 1, 2 order by count(*) desc, 2 limit 1;
    if v_ca is not null then
      select count(*) into v_n from _tt_pas where campaign_id = v_ca;
      update public.campaigns set billing_end = v_hari + 10 where id = v_ca;
      r2 := rc_private.tt_email_isi(null);
      hasil := hasil || jsonb_build_object('uji', 'Billing End belum lewat: campaign tidak dihitung belum diupload',
        'lulus', (r2->>'belum')::int = (r->>'belum')::int - v_n
             and not exists (select 1 from jsonb_array_elements(r2->'topCampaign') x where x->>'kode' = v_kode),
        'rinci', v_kode || ': ' || (r->>'belum') || ' -> ' || (r2->>'belum'));
      update public.campaigns set billing_end = v_hari - 1 where id = v_ca;

      -- Satu dokumen di-compile untuk satu pasangan: pasangan itu Compiled, keluar dari hitungan.
      select depot_id, depot_code into v_dep, v_kdep from _tt_pas where campaign_id = v_ca order by depot_code limit 1;
      insert into public.claims(no_doc, campaign_id, customer_id, depot_id, status, cb_net, version_no)
      select 'UJI/TT/' || md5(random()::text), v_ca, (select id from public.customers where archived_at is null order by id limit 1), v_dep, 'not_yet', 1000, 1;
      r2 := rc_private.tt_email_isi(null);
      hasil := hasil || jsonb_build_object('uji', 'Pasangan yang sudah ada dokumennya (Compiled) tidak dihitung',
        'lulus', (r2->>'belum')::int = (r->>'belum')::int - 1, 'rinci', v_kdep || ' x ' || v_kode);
    end if;

    -- ---- Badan email -----------------------------------------------------------------------
    r := public.rc_email_susun('timetable', false);
    v_html := coalesce(r->>'isiHtml', '');
    hasil := hasil || jsonb_build_object('uji', 'Email: bagian Top 10 Depot, Top 10 Campaign dan Dashboard Timetable berurutan',
      'lulus', r->>'status' = 'success'
           and position('10 Depot dengan Campaign Belum Diupload Terbanyak' in v_html) > 0
           and position('10 Campaign dengan Depot Belum Upload Terbanyak' in v_html) > position('10 Depot dengan Campaign Belum Diupload Terbanyak' in v_html)
           and position('Dashboard Timetable' in v_html) > position('10 Campaign dengan Depot Belum Upload Terbanyak' in v_html),
      'rinci', coalesce(r->>'message', ''));
    hasil := hasil || jsonb_build_object('uji', 'Email: kolom tabel depot dan campaign',
      'lulus', (v_html ~ 'KODE DEPOT</th><th[^>]*>NAMA DEPOT</th><th[^>]*>REGION</th><th[^>]*>CAMPAIGN BELUM DIUPLOAD</th>' or v_html ~ 'Tidak ada depot dengan campaign')
           and (v_html ~ 'KODE CAMPAIGN</th><th[^>]*>NAMA CAMPAIGN</th><th[^>]*>BILLING END</th><th[^>]*>DEPOT BELUM UPLOAD</th>' or v_html ~ 'Tidak ada campaign yang'),
      'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Dashboard: KPI dan grafik Proporsi Progres + Progres per Region (gambar QuickChart)',
      'lulus', v_html ~ 'Kombinasi Depot x Campaign' and v_html ~ 'Cleared \(Completed \+ Not Achieved\)'
           and v_html ~ 'alt="Proporsi Progres"' and v_html ~ 'alt="Progres per Region"' and v_html ~ 'quickchart\.io',
      'rinci', '-');
    hasil := hasil || jsonb_build_object('uji', 'Email: tidak lagi memuat ringkasan lama "Pasangan ditandai Not Achieved" sendirian; ada penjelasan istilah',
      'lulus', v_html !~ 'Pasangan ditandai Not Achieved' and v_html ~ 'Belum diupload = pasangan depot', 'rinci', '-');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;
  insert into _hasil_tte(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_tte order by urut;
