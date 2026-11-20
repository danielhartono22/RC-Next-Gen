-- ==========================================================================================
-- Timetable: bawaan hanya campaign yang Billing End-nya >= hari ini; centang "Show All Campaign"
-- ==========================================================================================
-- Pemilik, 20 November 2026: "buat juga kolom ini untuk timetable 'Show All Campaign'. By default
-- tampilkan yang billing end date >= today".
--
-- rc_timetable_matrix: penyaring baru 'semuaCampaign'. Kosong (bawaan) = hanya campaign yang
-- batasnya (Billing End campaign, lalu SO End, lalu Period End) >= hari ini (WIB); campaign tanpa
-- tanggal tetap tampil. 'true' = semua campaign tahun terpilih. Memilih satu campaign tertentu
-- menampilkan campaign itu walau sudah berakhir. Kunci baru 'campaignBerakhir' = jumlah campaign
-- tahun itu yang disembunyikan karena sudah berakhir (untuk keterangan di layar).
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $g$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $g$;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('public.rc_timetable_matrix(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261164090000' then
    src := pg_temp.ganti(src, $p$  v_semua_tahun boolean := false; -- 20261162220000: Semua Tahun$p$,
      $p$  v_semua_tahun boolean := false; -- 20261162220000: Semua Tahun
  v_semua_camp boolean; v_hari date := (now() at time zone 'Asia/Jakarta')::date; -- 20261164090000$p$, 1, 'deklarasi');
    src := pg_temp.ganti(src, $p$  v_tahun_teks := nullif(btrim(coalesce(p_filter->>'tahunCampaign','')),'');$p$,
      $p$  v_tahun_teks := nullif(btrim(coalesce(p_filter->>'tahunCampaign','')),'');
  -- 20261164090000: bawaan hanya campaign yang belum berakhir; Show All Campaign / campaign terpilih = semua.
  v_semua_camp := lower(btrim(coalesce(p_filter->>'semuaCampaign', ''))) in ('true', '1', 'ya') or v_campaign is not null;$p$, 1, 'nilai');
    src := pg_temp.ganti(src, $p$         and (v_campaign is null or ca.campaign_code=v_campaign)$p$,
      $p$         and (v_campaign is null or ca.campaign_code=v_campaign)
         and (v_semua_camp or coalesce(ca.billing_end, ca.so_end, ca.period_end) is null
              or coalesce(ca.billing_end, ca.so_end, ca.period_end) >= v_hari) /* 20261164090000 */$p$, 1, 'saring');
    src := pg_temp.ganti(src, $p$      'campaignAktif',(select count(*) from campaign_tahun),$p$,
      $p$      'campaignAktif',(select count(*) from campaign_tahun),
      'semuaCampaign',v_semua_camp, /* 20261164090000 */
      'campaignBerakhir',case when v_semua_camp then 0 else (select count(*) from public.campaigns ca
        where ca.archived_at is null
          and coalesce(ca.period_start,ca.period_end) is not null
          and (v_semua_tahun or extract(year from coalesce(ca.period_start,ca.period_end))::integer=v_tahun)
          and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=ca.id)
          and coalesce(ca.billing_end, ca.so_end, ca.period_end) < v_hari) end,$p$, 1, 'jumlah berakhir');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('public.rc_timetable_matrix(jsonb)'::regprocedure) !~ 'v_semua_camp' then raise exception 'GAGAL: timetable'; end if;
end $cek$;
