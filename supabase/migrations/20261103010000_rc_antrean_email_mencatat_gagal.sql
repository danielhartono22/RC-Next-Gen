-- ==========================================================================================
-- Antrean email mencatat kegagalannya, dan berhenti mengulang tanpa batas
-- ==========================================================================================
-- KEADAAN YANG DIPERBAIKI
-- Sebuah email Daily sungguhan mengantre sejak 16:02 dan cron mencobanya pukul 16:05. Percobaan
-- itu ditolak dengan benar oleh penjaga Vault - "Client secret tampak bukan nilai sungguhan
-- (15 karakter)" - sehingga tidak ada satu pun dari 15 penerima yang menerima apa pun.
--
-- Masalahnya ada pada pencatatan. Penolakan itu berupa exception, yang membatalkan seluruh
-- transaksi rc_email_tick. Akibatnya kolom percobaan pada barisnya tetap 0 dan kolom galat
-- tetap kosong: di layar Antrean Pengiriman barisnya terlihat "pending" yang tenang, seolah
-- belum pernah dicoba, padahal sudah gagal dan akan terus gagal tiap jam selamanya.
--
-- Sebab kegagalan hanya terlihat di cron.job_run_details, tempat yang tidak dibuka siapa pun.
--
-- YANG DIUBAH
-- Tiap baris dikirim di dalam blok yang menangkap galatnya sendiri. PL/pgSQL memasang savepoint
-- untuk setiap blok ber-EXCEPTION, sehingga kegagalan satu baris tidak lagi menjatuhkan baris
-- lain maupun seluruh cron, dan pencatatan di dalam penanganannya benar-benar tersimpan.
--
-- Sesudah lima percobaan barisnya ditandai failed dan berhenti diulang. Email yang tidak dapat
-- dikirim karena konfigurasinya belum lengkap sebaiknya berhenti dan terlihat, bukan mengetuk
-- pintu tiap jam sampai ada yang kebetulan membuka catatan cron.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function public.rc_email_jalankan_antrean(p_maks integer default 20)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  r record; n_kirim integer := 0; n_tunda integer := 0; n_gagal integer := 0;
  v jsonb; v_sebab text := ''; v_percobaan integer;
  BATAS_PERCOBAAN constant integer := 5;
begin
  for r in select id from public.email_outbox where status='pending'
            order by dibuat_pada limit greatest(coalesce(p_maks,20),1) loop
    begin
      v := rc_private.kirim_satu_email(r.id);
      if v->>'status' = 'success' then
        n_kirim := n_kirim + 1;
      else
        -- "tertunda" berarti konfigurasinya belum lengkap, bukan pengiriman yang gagal.
        -- Barisnya tetap pending, tetapi sebabnya dicatat supaya terbaca dari layar.
        n_tunda := n_tunda + 1;
        v_sebab := coalesce(v->>'sebab','');
        update public.email_outbox set galat = left(v_sebab, 500) where id = r.id;
      end if;
    exception when others then
      -- Penanganan ini berjalan setelah savepoint-nya dikembalikan, jadi perubahan di bawah
      -- benar-benar tersimpan - tidak seperti versi sebelumnya yang ikut hilang bersama
      -- transaksi yang dibatalkan.
      n_gagal := n_gagal + 1;
      v_sebab := sqlerrm;
      select percobaan + 1 into v_percobaan from public.email_outbox where id = r.id;
      update public.email_outbox
         set percobaan = v_percobaan,
             galat = left(sqlerrm, 500),
             status = case when v_percobaan >= BATAS_PERCOBAAN then 'failed' else 'pending' end
       where id = r.id;
    end;
  end loop;

  return jsonb_build_object('status','success','terkirim',n_kirim,
    'tertunda',n_tunda,'gagal',n_gagal,'sebab',v_sebab);
end $fn$;
revoke all on function public.rc_email_jalankan_antrean(integer) from public,anon;
grant execute on function public.rc_email_jalankan_antrean(integer) to authenticated;

-- Membatalkan email yang masih mengantre. Dipakai ketika sebuah pengiriman terlanjur diantrekan
-- dan diputuskan tidak jadi dikirim - lebih baik ada satu jalan resmi untuk itu daripada
-- menghapus barisnya langsung dari tabel.
create or replace function public.rc_email_batalkan(p_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v public.email_outbox;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat membatalkan email'
      using errcode='42501'; end if;
  select * into v from public.email_outbox where id = p_id for update;
  if not found then raise exception 'Email tidak ditemukan'; end if;
  if v.status not in ('pending','failed') then
    raise exception 'Email berstatus % tidak dapat dibatalkan', v.status; end if;

  update public.email_outbox
     set status = 'skipped', galat = 'Dibatalkan dari layar Access Management'
   where id = p_id;

  insert into public.activity_logs(actor_id,event_type,entity_id,details)
  values((select auth.uid()),'email_dibatalkan',p_id,
    jsonb_build_object('jenis',v.jenis,'subjek',v.subjek,'tujuan',to_jsonb(v.tujuan)));

  return jsonb_build_object('status','success','message','Email dibatalkan dan tidak akan dikirim.');
end $fn$;
revoke all on function public.rc_email_batalkan(uuid) from public,anon;
grant execute on function public.rc_email_batalkan(uuid) to authenticated;

create or replace function rc_private.marker_20261103() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261103() from public,anon;
grant execute on function rc_private.marker_20261103() to authenticated;

select 'Antrean email mencatat kegagalan' as hasil,
 (select count(*) from public.email_outbox where status='pending') as menunggu,
 (select count(*) from public.email_outbox where status='failed') as gagal;
