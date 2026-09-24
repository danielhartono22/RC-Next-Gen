-- ==========================================================================================
-- Penetapan OSC binaan tidak boleh gagal diam-diam
-- ==========================================================================================
-- Ditemukan saat memeriksa hasil pengujian pemilik, 20 September 2026.
--
-- Log Access Management mencatat penyimpanan berhasil dengan "osc": 1 sebanyak empat kali:
--
--   19:50:00  {"rp": 0, "osc": 1, "role": "supervisor", "status": "active", ...}
--   19:49:53  {"rp": 0, "osc": 1, ...}
--   18:58:40  {"rp": 0, "osc": 1, ...}
--   18:58:13  {"rp": 0, "osc": 1, ...}
--
-- Tetapi tabel public.user_supervision KOSONG, dan IQBAL tetap berjangkauan nol depot. Layar
-- mengatakan berhasil, basis data mengatakan tidak ada apa-apa.
--
-- SEBABNYA satu baris pada rc_update_access:
--
--   insert into public.user_supervision(supervisor_id,osc_id)
--   select v_target,id from public.profiles where user_code=upper(btrim(c)) and id<>v_target
--   on conflict do nothing;
--   n_osc:=n_osc+1;            <-- dihitung SELALU, bahkan ketika insert tidak menemukan siapa pun
--
-- Bentuk "insert ... select" tidak gagal ketika select-nya tidak mengembalikan baris; ia hanya
-- menyisipkan nol baris. Penghitungnya tetap naik, hasilnya dilaporkan sebagai keberhasilan, dan
-- yang menekan tombol tidak punya cara mengetahui bahwa tidak ada yang tersimpan.
--
-- Kegagalan diam seperti ini lebih buruk daripada galat: pemilik menyimpan empat kali, setiap
-- kali memperoleh pesan berhasil, dan tetap bertanya-tanya mengapa jangkauannya tidak berubah.
--
-- PERBAIKANNYA menghitung baris yang BENAR-BENAR tersisip, dan berhenti dengan pesan yang
-- menyebut kodenya bila tidak ada. Penyimpanan dibatalkan seluruhnya - lebih baik tidak
-- menyimpan apa pun daripada menyimpan sebagian sambil mengaku lengkap.
--
-- CATATAN PENTING TENTANG KEADAAN SEKARANG
-- Sistem ini belum punya satu pun akun berperan 'osc'; yang ada hanya admin, supervisor dan
-- system manager. Karena yurisdiksi supervisor mengalir lewat OSC, seorang supervisor belum
-- dapat memperoleh jangkauan apa pun sampai akun OSC dibuat. Itu keadaan data, bukan cacat
-- program, dan dilaporkan terpisah kepada pemilik.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

do $mig$
declare src text; baru text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rc_update_access';
  if src is null then raise exception 'public.rc_update_access tidak ditemukan.'; end if;

  if position('v_tersisip' in src) > 0 then
    raise notice 'rc_update_access sudah menghitung baris tersisip; dilewati.';
    return;
  end if;

  baru := src;

  -- Peubah penampung jumlah baris yang benar-benar tersisip.
  baru := replace(baru,
    '  v_perms text[]; v_depot uuid; c text; n_rp int:=0; n_as int:=0; n_osc int:=0;',
    '  v_perms text[]; v_depot uuid; c text; n_rp int:=0; n_as int:=0; n_osc int:=0;' || chr(10)
      || '  v_tersisip int;');

  baru := replace(baru,
    '          insert into public.user_supervision(supervisor_id,osc_id)' || chr(10)
      || '          select v_target,id from public.profiles where user_code=upper(btrim(c)) and id<>v_target' || chr(10)
      || '          on conflict do nothing;' || chr(10)
      || '          n_osc:=n_osc+1;',
    '          insert into public.user_supervision(supervisor_id,osc_id)' || chr(10)
      || '          select v_target,id from public.profiles where user_code=upper(btrim(c)) and id<>v_target' || chr(10)
      || '          on conflict do nothing;' || chr(10)
      || '          -- "insert ... select" TIDAK gagal ketika select-nya kosong; ia hanya menyisipkan' || chr(10)
      || '          -- nol baris. Tanpa pemeriksaan ini, kode yang tidak dikenal dilaporkan sebagai' || chr(10)
      || '          -- keberhasilan dan tidak ada yang tersimpan.' || chr(10)
      || '          get diagnostics v_tersisip = row_count;' || chr(10)
      || '          if v_tersisip = 0 then' || chr(10)
      || '            if upper(btrim(c)) = v_kode then' || chr(10)
      || '              raise exception ''Akun % tidak dapat membina dirinya sendiri sebagai OSC.'', btrim(c);' || chr(10)
      || '            else' || chr(10)
      || '              raise exception ''Akun OSC % tidak ditemukan. Periksa User ID-nya, atau buat akunnya lebih dulu - yurisdiksi supervisor mengalir lewat OSC.'', btrim(c);' || chr(10)
      || '            end if;' || chr(10)
      || '          end if;' || chr(10)
      || '          n_osc:=n_osc+v_tersisip;');

  if baru = src then
    raise exception 'Pola penetapan OSC binaan tidak ditemukan pada rc_update_access. '
      'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
  end if;

  execute baru;
  raise notice 'rc_update_access: penetapan OSC binaan tidak lagi gagal diam-diam.';
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'rc_update_access';

  if position('get diagnostics v_tersisip = row_count' in src) = 0 then
    raise exception 'GAGAL: rc_update_access belum menghitung baris yang tersisip.';
  end if;
  if position('n_osc:=n_osc+1;' in src) > 0 then
    raise exception 'GAGAL: penghitung lama yang selalu naik masih ada.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
