-- ==========================================================================================
-- Email: kirim seketika, tombol kirim manual, dan hari yang boleh lebih dari satu
-- ==========================================================================================
-- Permintaan pemilik, 20 September 2026:
--
--   "untuk kirim uji (ganti Test Email) itu langsung kirim setelah saya klik, dan tambahkan
--    button baru manual send ketika di klik langsung ke kirim, dan untuk hari bisa multiple
--    choice sehingga kita bisa exc hari yang ga mau ada email"
--
-- ------------------------------------------------------------------------------------------
-- 1. MENGAPA SELAMA INI TIDAK LANGSUNG TERKIRIM
-- ------------------------------------------------------------------------------------------
-- rc_email_susun(jenis, true) hanya MENGANTRE: ia menaruh satu baris berstatus 'pending' di
-- email_outbox lalu selesai. Yang benar-benar mengirim adalah rc_email_jalankan_antrean, dan
-- itu hanya dipanggil oleh rc_email_tick - sebuah pekerjaan pg_cron yang berjalan sekali sejam
-- pada menit ke-5.
--
-- Jadi menekan "Kirim Uji" pukul 20:31 berarti menunggu sampai 21:05. Dari kursi penggunanya,
-- tombol itu tampak tidak melakukan apa-apa.
--
-- Fungsi baru rc_email_kirim_sekarang menyusun DAN langsung mengirim baris itu juga, lalu
-- melaporkan hasil yang sebenarnya - terkirim, tertunda karena setelan belum lengkap, atau
-- gagal beserta sebabnya. Tidak ada lagi jeda satu jam antara menekan tombol dan mengetahui
-- hasilnya.
--
-- Pengantreannya sendiri tidak dihapus: rc_email_susun tetap seperti semula, dan jadwal
-- otomatis tetap melewati antrean seperti biasa. Yang ditambahkan hanya jalan pintas manual.
--
-- ------------------------------------------------------------------------------------------
-- 2. HARI: DARI SATU MENJADI BEBERAPA
-- ------------------------------------------------------------------------------------------
-- email_settings.hari adalah satu integer, sehingga sebuah jadwal hanya bisa jatuh pada satu
-- hari dalam seminggu - atau setiap hari bila NULL. Tidak ada cara menyatakan "tiap hari kerja
-- kecuali Sabtu dan Minggu", yang justru bentuk paling lazim.
--
-- Kolomnya diganti hari_list smallint[]: NULL berarti tiap hari, dan selain itu daftar hari
-- yang dikehendaki (0 = Minggu sampai 6 = Sabtu).
--
-- Kolom lama DIHAPUS, tidak disimpan "untuk jaga-jaga". Pelajaran dari migration 20261111010000
-- masih segar: ketika depot asal dipindahkan ke kolom baru tetapi kolom lama dibiarkan, dua
-- fungsi tetap membaca yang lama dan layar menampilkan kosong selama berjam-jam tanpa ada yang
-- tahu. Satu sumber kebenaran, dan seluruh pembacanya dipindahkan dalam migration yang sama.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Kolom hari_list menggantikan hari
-- ------------------------------------------------------------------------------------------
alter table public.email_settings add column if not exists hari_list smallint[];

do $pindah$
begin
  if exists(select 1 from information_schema.columns
             where table_schema='public' and table_name='email_settings' and column_name='hari') then
    execute 'update public.email_settings
                set hari_list = case when hari is null then null else array[hari::smallint] end
              where hari_list is null';
  end if;
end
$pindah$;

-- ------------------------------------------------------------------------------------------
-- 2. Penyimpanan jadwal menerima daftar hari
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_settings_simpan(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r jsonb; n integer := 0; v_hari smallint[]; v_angka smallint;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat mengubah jadwal email' using errcode='42501'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    -- hariList tidak dikirim  -> biarkan seperti semula
    -- hariList array kosong   -> tiap hari (NULL)
    -- hariList berisi angka   -> hanya hari itu
    v_hari := null;
    if r ? 'hariList' then
      if jsonb_typeof(r->'hariList') <> 'array' then
        raise exception 'hariList harus berupa daftar angka hari'; end if;
      v_hari := '{}'::smallint[];
      for v_angka in select (value#>>'{}')::smallint from jsonb_array_elements(r->'hariList') loop
        if v_angka < 0 or v_angka > 6 then
          raise exception 'Hari harus 0 (Minggu) sampai 6 (Sabtu), diterima %', v_angka; end if;
        if not (v_angka = any(v_hari)) then v_hari := v_hari || v_angka; end if;
      end loop;
      if array_length(v_hari,1) is null then v_hari := null; end if;
    end if;

    update public.email_settings set
      aktif     = coalesce((r->>'aktif')::boolean, aktif),
      jam       = coalesce((r->>'jam')::integer, jam),
      hari_list = case when r ? 'hariList' then v_hari else hari_list end,
      subjek    = coalesce(nullif(btrim(coalesce(r->>'subjek','')),''), subjek),
      diubah_pada = now(), diubah_oleh = (select auth.uid())
    where jenis = lower(btrim(r->>'jenis'));
    if found then n := n + 1; end if;
  end loop;

  return jsonb_build_object('status','success','jumlah',n,'message',n||' jadwal email disimpan');
end $fn$;

-- ------------------------------------------------------------------------------------------
-- 3. Status mengembalikan daftar hari
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_status()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object('status','success',
    'pengaturan',(select coalesce(jsonb_agg(jsonb_build_object(
        'jenis',jenis,'aktif',aktif,'jam',jam,
        -- NULL tetap dikirim sebagai null, yang di layar berarti "tiap hari".
        'hariList',to_jsonb(hari_list),
        'subjek',subjek) order by jenis),'[]'::jsonb)
      from public.email_settings),
    'antrean',(select coalesce(jsonb_agg(jsonb_build_object(
        'id',id,'jenis',jenis,'subjek',subjek,'status',status,
        'tujuan',array_length(tujuan,1),'cc',array_length(cc,1),'galat',galat,
        'dibuat',to_char(dibuat_pada at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'dikirim',to_char(dikirim_pada at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'))
        order by dibuat_pada desc),'[]'::jsonb)
      from (select * from public.email_outbox order by dibuat_pada desc limit 50) x),
    'ringkas',(select jsonb_object_agg(status,n) from
      (select status,count(*) n from public.email_outbox group by status) y),
    'depotBerEmail',(select count(*) from public.depots where coalesce(btrim(email_to),'')<>''),
    'depotTotal',(select count(*) from public.depots));
$fn$;

-- ------------------------------------------------------------------------------------------
-- 4. Penjadwal membaca daftar hari
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_tick()
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare s public.email_settings; sekarang timestamptz := now();
  jam_lokal integer; hari_lokal smallint; n integer := 0; sudah boolean;
begin
  jam_lokal  := extract(hour from sekarang at time zone 'Asia/Jakarta')::integer;
  hari_lokal := extract(dow  from sekarang at time zone 'Asia/Jakarta')::smallint;

  for s in select * from public.email_settings where aktif loop
    if s.jam <> jam_lokal then continue; end if;
    -- hari_list NULL berarti tiap hari. Selain itu hanya hari yang tercantum - sehingga hari
    -- yang tidak dikehendaki cukup tidak dimasukkan ke daftarnya.
    if s.hari_list is not null and not (hari_lokal = any(s.hari_list)) then continue; end if;

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

-- ------------------------------------------------------------------------------------------
-- 5. Kolom lama dilepas - satu sumber kebenaran
-- ------------------------------------------------------------------------------------------
alter table public.email_settings drop column if exists hari;

-- ------------------------------------------------------------------------------------------
-- 6. Kirim seketika
-- ------------------------------------------------------------------------------------------
-- Menyusun lalu LANGSUNG mengirim baris itu juga, dan melaporkan hasil yang sebenarnya.
-- p_test_email terisi berarti pengiriman uji: seluruh pemetaan penerima depot diabaikan dan
-- email hanya berangkat ke satu alamat itu - penjagaan itu ada di dalam rc_email_susun dan
-- tidak dilonggarkan di sini.
create or replace function public.rc_email_kirim_sekarang(p_jenis text, p_test_email text default '')
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare v_susun jsonb; v_id uuid; v_hasil jsonb; v_status text; v_sebab text;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat mengirim email' using errcode='42501'; end if;

  v_susun := public.rc_email_susun(p_jenis, true, coalesce(p_test_email,''));
  v_id := nullif(v_susun->>'id','')::uuid;
  if v_id is null then
    return jsonb_build_object('status','error',
      'message', coalesce(v_susun->>'message','Email tidak jadi disusun; tidak ada baris antrean.'));
  end if;

  -- Kegagalan pengiriman TIDAK boleh membatalkan baris antreannya: tanpa penangkapan ini,
  -- exception dari kirim_satu_email akan menggulung balik seluruh transaksi termasuk baris
  -- yang baru disusun, dan pengguna tidak punya jejak apa pun untuk diperiksa.
  begin
    v_hasil := rc_private.kirim_satu_email(v_id);
    v_status := coalesce(v_hasil->>'status','');
    if v_status = 'success' then
      return jsonb_build_object('status','success','id',v_id,'terkirim',true,
        'message','Email ' || p_jenis || ' terkirim'
          || case when coalesce(btrim(p_test_email),'') <> ''
                  then ' ke ' || btrim(p_test_email) else '' end || '.');
    end if;
    v_sebab := coalesce(v_hasil->>'sebab','Setelan email belum lengkap.');
    update public.email_outbox set galat = left(v_sebab,500) where id = v_id;
    return jsonb_build_object('status','warning','id',v_id,'terkirim',false,
      'message','Belum terkirim: ' || v_sebab || ' Barisnya tetap di antrean.');
  exception when others then
    v_sebab := sqlerrm;
    update public.email_outbox
       set percobaan = coalesce(percobaan,0) + 1, galat = left(v_sebab,500)
     where id = v_id;
    return jsonb_build_object('status','warning','id',v_id,'terkirim',false,
      'message','Gagal mengirim: ' || left(v_sebab,300));
  end;
end $fn$;
revoke all on function public.rc_email_kirim_sekarang(text,text) from public,anon;
grant execute on function public.rc_email_kirim_sekarang(text,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 7. Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare n int;
begin
  if exists(select 1 from information_schema.columns
             where table_schema='public' and table_name='email_settings' and column_name='hari') then
    raise exception 'GAGAL: kolom hari lama masih ada.';
  end if;
  if not exists(select 1 from information_schema.columns
                 where table_schema='public' and table_name='email_settings' and column_name='hari_list') then
    raise exception 'GAGAL: kolom hari_list tidak ada.';
  end if;

  -- Tidak boleh ada fungsi yang masih membaca kolom lama.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where p.prokind='f' and ns.nspname in ('public','rc_private')
     and pg_get_functiondef(p.oid) like '%s.hari %';
  if n > 0 then raise exception 'GAGAL: % fungsi masih membaca s.hari.', n; end if;

  if not exists(select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
                 where ns.nspname='public' and p.proname='rc_email_kirim_sekarang') then
    raise exception 'GAGAL: rc_email_kirim_sekarang tidak terpasang.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
