-- ==========================================================================================
-- Pengirim email: antrean dijalankan, dan penulisan rupiah diperbaiki
-- ==========================================================================================
-- BAGIAN 1 - RUPIAH
-- to_char memakai pemisah ribuan milik locale server, yang di sini menghasilkan
-- "Rp 294,894,311". Penulisan Indonesia memakai titik. Diperbaiki dengan menukar pemisahnya
-- secara eksplisit, bukan dengan berharap locale server suatu saat berubah.
--
-- BAGIAN 2 - PENGIRIMAN
-- PostgreSQL tidak dapat mengirim email sendiri. Pengirimannya diserahkan ke penyedia email
-- lewat pg_net, dan dijadwalkan oleh pg_cron. Keduanya diaktifkan di sini.
--
-- KUNCI PENYEDIA DISIMPAN DI VAULT, BUKAN DI TABEL BIASA
-- Sebuah kunci API yang tersimpan sebagai teks di tabel akan ikut terbawa setiap kali seseorang
-- membaca tabel itu, ikut masuk ke backup, dan ikut terlihat di log. Vault menyimpannya
-- terenkripsi dan hanya membukanya di dalam fungsi yang memang membutuhkannya.
--
-- SELAMA KUNCINYA BELUM DIISI, TIDAK ADA YANG TERKIRIM. Email tetap tersusun dan menumpuk di
-- outbox berstatus pending, dan pengirimnya berhenti dengan pesan yang menyebutkan sebabnya.
-- Itu keadaan yang jujur: isinya bisa diperiksa lebih dulu, dan tidak ada email yang diam-diam
-- hilang karena dikira terkirim.
--
-- CARA MENGISI KUNCINYA, sekali saja, dari SQL Editor:
--   select vault.create_secret('re_xxxxxxxxxxxx', 'rc_email_api_key', 'Kunci API penyedia email');
--   select vault.create_secret('noreply@domain-anda.com', 'rc_email_from', 'Alamat pengirim');
-- Bentuk badan permintaannya mengikuti Resend. Bila penyedianya berbeda, yang perlu diubah
-- hanya rc_private.kirim_satu_email di bawah.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- ------------------------------------------------------------------------------------------
-- 1. Rupiah dengan pemisah titik
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.rupiah(n numeric)
returns text language sql immutable set search_path='' as $fn$
  -- to_char menghasilkan koma pada locale server ini; ditukar menjadi titik secara eksplisit.
  select 'Rp ' || replace(to_char(coalesce(n,0), 'FM999G999G999G999G990'), ',', '.');
$fn$;

-- ------------------------------------------------------------------------------------------
-- 2. Membaca rahasia dari Vault
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.rahasia(p_nama text)
returns text language sql stable security definer set search_path='' as $fn$
  select decrypted_secret from vault.decrypted_secrets where name = p_nama limit 1;
$fn$;
revoke all on function rc_private.rahasia(text) from public,anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Mengirim satu baris antrean
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.kirim_satu_email(p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v public.email_outbox; v_key text; v_from text; v_req bigint;
begin
  select * into v from public.email_outbox where id = p_id and status = 'pending' for update;
  if not found then return jsonb_build_object('status','skipped','sebab','Bukan baris pending'); end if;

  v_key  := rc_private.rahasia('rc_email_api_key');
  v_from := rc_private.rahasia('rc_email_from');
  if coalesce(v_key,'') = '' or coalesce(v_from,'') = '' then
    -- Sengaja TIDAK ditandai failed. Belum dikonfigurasi bukan kegagalan pengiriman, dan
    -- menandainya failed akan membuat email hilang begitu kuncinya nanti diisi.
    return jsonb_build_object('status','tertunda',
      'sebab','Kunci penyedia email belum diisi di Vault (rc_email_api_key dan rc_email_from)');
  end if;

  select net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer '||v_key),
    body := jsonb_build_object(
      'from', v_from,
      'to', to_jsonb(v.tujuan),
      'cc', to_jsonb(v.cc),
      'subject', v.subjek,
      'html', v.isi_html)
  ) into v_req;

  -- pg_net bekerja asinkron: yang kembali adalah nomor permintaan, bukan hasilnya. Barisnya
  -- ditandai terkirim beserta nomor itu, dan rc_email_periksa di bawah yang kemudian membaca
  -- jawaban sesungguhnya. Tanpa pemisahan ini, satu penyedia yang lambat akan menahan cron.
  update public.email_outbox
     set status='sent', dikirim_pada=now(), percobaan=percobaan+1,
         konteks = konteks || jsonb_build_object('net_request_id', v_req)
   where id = p_id;

  return jsonb_build_object('status','success','requestId',v_req);
end $fn$;
revoke all on function rc_private.kirim_satu_email(uuid) from public,anon,authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Menjalankan antrean
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_jalankan_antrean(p_maks integer default 20)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r record; n_kirim integer := 0; n_tunda integer := 0; v jsonb; v_sebab text := '';
begin
  for r in select id from public.email_outbox where status='pending'
            order by dibuat_pada limit greatest(coalesce(p_maks,20),1) loop
    v := rc_private.kirim_satu_email(r.id);
    if v->>'status' = 'success' then n_kirim := n_kirim + 1;
    else n_tunda := n_tunda + 1; v_sebab := coalesce(v->>'sebab',''); end if;
  end loop;
  return jsonb_build_object('status','success','terkirim',n_kirim,'tertunda',n_tunda,
    'sebab',v_sebab);
end $fn$;
revoke all on function public.rc_email_jalankan_antrean(integer) from public,anon;
grant execute on function public.rc_email_jalankan_antrean(integer) to authenticated;

-- Membaca jawaban penyedia untuk baris yang sudah dikirim, lalu menandai yang benar-benar
-- gagal. Tanpa langkah ini, "sent" hanya berarti permintaannya berhasil dititipkan.
create or replace function public.rc_email_periksa()
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r record; n_ok integer := 0; n_gagal integer := 0;
begin
  for r in
    select o.id, (o.konteks->>'net_request_id')::bigint as req
      from public.email_outbox o
     where o.status='sent' and o.konteks ? 'net_request_id'
       and o.dikirim_pada > now() - interval '2 days'
  loop
    begin
      perform 1 from net._http_response where id = r.req and status_code between 200 and 299;
      if found then n_ok := n_ok + 1; continue; end if;
      update public.email_outbox
         set status='failed',
             galat = coalesce((select left(coalesce(error_msg, 'HTTP '||status_code::text||': '||coalesce(content,'')),300)
                                 from net._http_response where id=r.req),'Tidak ada jawaban dari penyedia')
       where id = r.id and exists(select 1 from net._http_response where id=r.req);
      if found then n_gagal := n_gagal + 1; end if;
    exception when others then
      -- Tabel jawaban pg_net dibersihkan berkala; ketiadaan baris bukan bukti kegagalan.
      continue;
    end;
  end loop;
  return jsonb_build_object('status','success','berhasil',n_ok,'gagal',n_gagal);
end $fn$;
revoke all on function public.rc_email_periksa() from public,anon;
grant execute on function public.rc_email_periksa() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 5. Penjadwal
-- ------------------------------------------------------------------------------------------
-- Cron berjalan pada UTC. Jadwal disimpan dalam jam Asia/Jakarta, jadi fungsi ini yang menilai
-- apakah sekarang memang waktunya - bukan ekspresi cron yang harus ditulis ulang setiap kali
-- jamnya diubah dari layar.
create or replace function public.rc_email_tick()
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare s public.email_settings; sekarang timestamptz := now();
  jam_lokal integer; hari_lokal integer; n integer := 0; sudah boolean;
begin
  jam_lokal  := extract(hour from sekarang at time zone 'Asia/Jakarta')::integer;
  hari_lokal := extract(dow  from sekarang at time zone 'Asia/Jakarta')::integer;

  for s in select * from public.email_settings where aktif loop
    if s.jam <> jam_lokal then continue; end if;
    if s.hari is not null and s.hari <> hari_lokal then continue; end if;

    -- Satu jenis email hanya sekali per hari, walau tick berjalan setiap jam.
    select exists(select 1 from public.email_outbox o
                   where o.jenis = s.jenis
                     and o.dibuat_pada >= date_trunc('day', sekarang at time zone 'Asia/Jakarta')
                         at time zone 'Asia/Jakarta') into sudah;
    if sudah then continue; end if;

    perform public.rc_email_susun(s.jenis, true);
    n := n + 1;
  end loop;

  perform public.rc_email_jalankan_antrean(50);
  perform public.rc_email_periksa();
  return jsonb_build_object('status','success','disusun',n,
    'jam',jam_lokal,'hari',hari_lokal);
end $fn$;
revoke all on function public.rc_email_tick() from public,anon;
grant execute on function public.rc_email_tick() to authenticated;

-- Dipasang sekali, berjalan tiap jam. Jadwal sebenarnya diputuskan rc_email_tick di atas.
do $cron$
begin
  perform cron.unschedule('rc_email_tick');
exception when others then null;
end $cron$;
select cron.schedule('rc_email_tick', '5 * * * *', 'select public.rc_email_tick();');

create or replace function rc_private.marker_20261016() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261016() from public,anon;
grant execute on function rc_private.marker_20261016() to authenticated;

select 'Pengirim email terpasang' as hasil,
 (select count(*) from cron.job where jobname='rc_email_tick') as cron_terpasang,
 case when coalesce(rc_private.rahasia('rc_email_api_key'),'')='' then 'BELUM DIISI'
      else 'sudah diisi' end as kunci_penyedia,
 rc_private.rupiah(294894311) as contoh_rupiah,
 'Isi kunci Vault lalu nyalakan jadwal di layar Report' as langkah_berikutnya;
