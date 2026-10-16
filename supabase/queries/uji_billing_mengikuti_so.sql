-- ==========================================================================================
-- UJI (tidak menyimpan apa pun): Periode Billing mengikuti Periode SO
-- ==========================================================================================
-- Berkas ini SELALU berakhir dengan raise exception, jadi seluruh perubahannya dibatalkan.
-- Jalankan: node scripts/apply-sql.mjs supabase/queries/uji_billing_mengikuti_so.sql
-- ==========================================================================================
do $uji$
declare
  v_uid uuid; kode text; v_lolos int := 0;
  d_so_a date; d_so_b date; d_bi_a date; d_bi_b date; t_a text; t_b text;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  select campaign_code into kode from public.campaigns where archived_at is null
   order by campaign_code limit 1;
  if kode is null then raise exception 'Tidak ada campaign untuk diuji.'; end if;
  raise notice 'Campaign uji: %', kode;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  -- ---- 1. Hanya SO dikirim -> billing mengikutinya --------------------------------------
  perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
    'codeCampaign', kode, 'soStart','07-03-2026','soEnd','21-05-2026')));
  select so_start,so_end,billing_start,billing_end,billing_start_text,billing_end_text
    into d_so_a,d_so_b,d_bi_a,d_bi_b,t_a,t_b
    from public.campaigns where campaign_code=kode;
  if d_bi_a is distinct from d_so_a or d_bi_b is distinct from d_so_b then
    reset role; raise exception 'GAGAL: billing tidak mengikuti SO (SO % s/d %, billing % s/d %).',
      d_so_a,d_so_b,d_bi_a,d_bi_b; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  1. Hanya SO dikirim -> billing ikut: % s/d %', d_bi_a, d_bi_b;

  -- ---- 2. Teksnya ikut juga, bukan hanya tanggalnya --------------------------------------
  if coalesce(t_a,'') <> '07-03-2026' or coalesce(t_b,'') <> '21-05-2026' then
    reset role; raise exception 'GAGAL: teks billing tidak ikut SO -> % / %',
      coalesce(t_a,'(kosong)'), coalesce(t_b,'(kosong)'); end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  2. Teks billing ikut teks SO: % s/d %', t_a, t_b;

  -- ---- 3. Billing yang diisi sungguhan TETAP menang ---------------------------------------
  perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
    'codeCampaign', kode, 'soStart','07-03-2026','soEnd','21-05-2026',
    'billingStart','01-09-2026','billingEnd','30-09-2026')));
  select billing_start,billing_end into d_bi_a,d_bi_b
    from public.campaigns where campaign_code=kode;
  if d_bi_a <> date '2026-09-01' or d_bi_b <> date '2026-09-30' then
    reset role; raise exception 'GAGAL: billing yang diisi tertimpa SO -> % s/d %', d_bi_a,d_bi_b; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  3. Billing yang diisi tetap menang: % s/d %', d_bi_a, d_bi_b;

  -- ---- 4. Billing dikirim kosong -> jatuh kembali ke SO -----------------------------------
  perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
    'codeCampaign', kode, 'soStart','07-03-2026','soEnd','21-05-2026',
    'billingStart','','billingEnd','')));
  select billing_start,billing_end into d_bi_a,d_bi_b
    from public.campaigns where campaign_code=kode;
  if d_bi_a is distinct from date '2026-03-07' then
    reset role; raise exception 'GAGAL: billing kosong tidak jatuh ke SO -> %', d_bi_a; end if;
  v_lolos := v_lolos + 1;
  raise notice 'OK  4. Billing dikosongkan -> kembali mengikuti SO: % s/d %', d_bi_a, d_bi_b;

  -- ---- 5. Periode billing terbalik tetap ditolak ------------------------------------------
  begin
    perform public.rc_campaign_upsert(jsonb_build_array(jsonb_build_object(
      'codeCampaign', kode, 'billingStart','30-09-2026','billingEnd','01-09-2026')));
    reset role; raise exception 'GAGAL: periode billing terbalik diterima.';
  exception when others then
    if sqlerrm like 'GAGAL:%' then raise; end if;
    v_lolos := v_lolos + 1;
    raise notice 'OK  5. Periode billing terbalik tetap ditolak';
  end;
  reset role;

  raise exception 'SELESAI: % langkah lolos. Transaksi sengaja dibatalkan.', v_lolos;
exception when others then
  reset role;
  if sqlerrm like 'SELESAI:%' or sqlerrm like 'GAGAL:%' then raise; end if;
  raise exception 'GAGAL: uji berhenti -> %', sqlerrm;
end
$uji$;
