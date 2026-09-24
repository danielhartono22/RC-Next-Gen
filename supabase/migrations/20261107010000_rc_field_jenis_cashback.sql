-- ==========================================================================================
-- Upload gagal seluruhnya: "field tidak ditemukan"
-- ==========================================================================================
-- DUA CACAT BERUNTUN PADA SATU FIELD. Yang kedua hanya terlihat setelah yang pertama dibetulkan,
-- dan yang kedua justru mengenai lebih banyak dokumen daripada yang pertama.
--
-- ------------------------------------------------------------------------------------------
-- CACAT 1 - rc_private.mutate_claims menolak 'jenis_cashback'
-- ------------------------------------------------------------------------------------------
-- Fungsi ini memeriksa setiap kunci pada item terhadap sebuah daftar putih, dan menolak apa pun
-- yang tidak tercantum dengan 'Unknown item field'. Daftar itu memuat lima belas nama; satu
-- nama tertinggal: jenis_cashback.
--
-- Padahal PELAKSANANYA - rc_private.mutate_claims_unchecked - MEMBACA field itu, dan memakainya
-- untuk dua keputusan penting: memutuskan RA07/RA7 yang langsung selesai, dan menuntut nomor
-- rekening untuk jenis Transfer. Jadi satu fungsi menuntut field yang fungsi di depannya larang.
--
-- Adapter selalu mengirimkannya, karena layar mengisi Jenis CB otomatis dari Campaign Master.
-- Akibatnya SETIAP submit gagal - bukan sebagian, melainkan seluruhnya. Bekasnya terbaca di
-- claim_status_history: hanya 2 baris ber-action 'submit' di seluruh riwayat.
--
-- Dibuktikan pada 20 September 2026 di dalam transaksi yang dibatalkan, dengan dokumen
-- NPC/CMP/PSN/CA10/27886 v1: muatan yang sama persis, satu-satunya beda ada tidaknya
-- jenis_cashback.
--
--   DENGAN jenis_cashback : GAGAL -> Unknown item field
--   TANPA  jenis_cashback : LOLOS
--
-- ------------------------------------------------------------------------------------------
-- CACAT 2 - daftar jenis yang sah tidak mengakui 'Voucher'
-- ------------------------------------------------------------------------------------------
-- mutate_claims_unchecked menolak jenis apa pun di luar Transfer, CN, Rebate, RA07 dan RA7.
-- Tetapi rc_private.jenis_efektif() - fungsi milik sistem ini sendiri - justru MEMETAKAN
-- 'Voucher' menjadi 'transfer':
--
--   when 'voucher' then 'transfer'
--
-- Jadi basis data mengenali Voucher di satu tempat dan menolaknya di tempat lain. Selama
-- jenis_cashback tidak pernah sampai ke sana, ketidakcocokan itu tidak terlihat. Begitu cacat 1
-- diperbaiki, ia langsung mengenai dokumen yang paling banyak:
--
--   Transfer  55 campaign  217 klaim not_yet  diterima
--   CN        12 campaign  121 klaim not_yet  diterima
--   Rebate    31 campaign   72 klaim not_yet  diterima
--   Voucher    2 campaign  421 klaim not_yet  DITOLAK
--
-- 421 dari 831 klaim not_yet - lebih banyak daripada ketiga jenis lain digabung. Memperbaiki
-- cacat 1 saja hanya akan MEMINDAHKAN kegagalan, dari "Unknown item field" pada seluruh
-- dokumen menjadi 'Jenis CB "Voucher" tidak dikenali' pada separuhnya.
--
-- Voucher diterima di sini sebagai NAMA LAMA, bukan jenis baru. Ia tidak ditambahkan ke daftar
-- yang boleh diketik di layar (RC_JENIS_CB tetap lima nama), dan jenis_efektif tetap
-- memperlakukannya sebagai Transfer - termasuk kewajiban nomor rekening, nama rekening dan bank
-- yang menyertainya. Yang berubah hanyalah: nilai warisan dari Campaign Master tidak lagi
-- menggagalkan dokumen yang sah.
--
-- ------------------------------------------------------------------------------------------
-- CARA MENERAPKANNYA
-- ------------------------------------------------------------------------------------------
-- Kedua fungsi ini panjang. Menyalin badannya ke sini berarti membekukan salinan yang dapat
-- menyimpang diam-diam dari yang sesungguhnya terpasang - dan salinan yang menyimpang pada
-- fungsi penjaga seperti ini adalah cara paling halus sebuah perbaikan menjadi kemunduran.
--
-- Karena itu migration ini MEMBACA definisi yang sedang terpasang, mengubah satu pola di
-- dalamnya, lalu menjalankannya kembali. Ia idempoten: bila polanya sudah berubah, ia melewati
-- langkah itu. Bila polanya tidak ditemukan sama sekali, ia BERHENTI dengan galat alih-alih
-- diam-diam tidak melakukan apa pun.
-- ==========================================================================================

do $mig$
declare
  src text;
  baru text;
  n_ubah int := 0;
begin
  -- ----------------------------------------------------------------------------------------
  -- 1. Daftar putih menerima jenis_cashback
  -- ----------------------------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'rc_private' and p.proname = 'mutate_claims';

  if src is null then
    raise exception 'rc_private.mutate_claims tidak ditemukan.';
  end if;

  if position('''jenis_cashback''' in src) > 0 then
    raise notice 'Daftar putih sudah memuat jenis_cashback; dilewati.';
  else
    baru := replace(src, '''account_name'',''top'')', '''account_name'',''top'',''jenis_cashback'')');
    if baru = src then
      raise exception 'Pola daftar putih tidak ditemukan pada rc_private.mutate_claims. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini, jangan biarkan lolos.';
    end if;
    execute baru;
    n_ubah := n_ubah + 1;
    raise notice 'rc_private.mutate_claims: jenis_cashback ditambahkan ke daftar putih.';
  end if;

  -- ----------------------------------------------------------------------------------------
  -- 2. Voucher diakui sebagai nama lama dari Transfer
  -- ----------------------------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'rc_private' and p.proname = 'mutate_claims_unchecked';

  if src is null then
    raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.';
  end if;

  if position('''Voucher''' in src) > 0 then
    raise notice 'Daftar jenis sudah memuat Voucher; dilewati.';
  else
    baru := replace(src,
      '''Transfer'',''CN'',''Rebate'',''RA07'',''RA7''',
      '''Transfer'',''CN'',''Rebate'',''RA07'',''RA7'',''Voucher''');
    if baru = src then
      raise exception 'Pola daftar jenis tidak ditemukan pada rc_private.mutate_claims_unchecked. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini.';
    end if;
    execute baru;
    n_ubah := n_ubah + 1;
    raise notice 'rc_private.mutate_claims_unchecked: Voucher diterima sebagai nama lama Transfer.';
  end if;

  raise notice 'Selesai, % fungsi diubah.', n_ubah;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan sesudahnya - berhenti bila salah satu tidak sebagaimana mestinya
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'rc_private' and p.proname = 'mutate_claims';
  if position('''jenis_cashback''' in src) = 0 then
    raise exception 'GAGAL: daftar putih mutate_claims tetap tidak memuat jenis_cashback.';
  end if;

  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'rc_private' and p.proname = 'mutate_claims_unchecked';
  if position('''Voucher''' in src) = 0 then
    raise exception 'GAGAL: daftar jenis mutate_claims_unchecked tetap tidak memuat Voucher.';
  end if;

  -- Pelaksananya harus tetap membaca field itu; bila tidak, daftar putih yang baru justru
  -- membuka field yang tidak ada gunanya.
  if position('jenis_cashback' in src) = 0 then
    raise exception 'GAGAL: mutate_claims_unchecked tidak lagi membaca jenis_cashback.';
  end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
