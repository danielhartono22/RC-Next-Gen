-- ==========================================================================================
-- Tanda Terima: Remark PP + saringan Remark, rekening dihapus dari form; popup hasil Upload File Bank
-- ==========================================================================================
-- Pemilik, 5 November 2026 (sesudah uji Bukti TF):
-- * "kalo ada bukti tf di remark ada PP" + "remark sudah ada tapi saya mau dibuatkan filternya":
--   Remark kini PDA / PDH / PDA + PDH ditambah PP bila toko punya Bukti TF yang ikut tercetak (Bukti TF
--   hanya dicetak sesudah form PDA, jadi PP dihitung dari dokumen PDA saja). Saringan Remark (saringan
--   toko, seperti Status Unduh): pda = PDA saja, pdh = PDH saja, campur = PDA + PDH, pp = ada Bukti TF,
--   tanpa_pp = tanpa Bukti TF.
-- * "bank account hapus aja dari header untuk seluruhnya karena sudah diganti bukti tf": Bank, No.
--   Rekening, dan Atas Nama (Customer Master) tidak lagi dikirim ke daftar maupun form; rekening tujuan
--   yang sebenarnya ada di Bukti TF (dari file bank).
-- * "keluar pop up seperti biasa ketika proses": hasil Upload File Bank membawa nama campaign dan
--   Gross Up supaya layar menampilkan Laporan Workflow yang sama dengan Posting Done.
-- Butuh 20261163730000. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regprocedure('rc_private.bukti_tf(uuid)') is null then
    raise exception 'DITOLAK: jalankan 20261163730000 lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text;
begin
  -- ---- 1. Daftar: Remark PP, saringan Remark, tanpa rekening -------------------------------------
  src := replace(pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure), E'\r', '');
  if src !~ 'v_remark' then
    src := pg_temp.ganti(src,
      $p$  v_cari text := lower(nullif(btrim(coalesce(v_sar->>'cari', '')), ''));$p$,
      $p$  v_cari text := lower(nullif(btrim(coalesce(v_sar->>'cari', '')), ''));
  v_remark text := nullif(btrim(coalesce(v_sar->>'remark', '')), ''); -- 20261163740000$p$, 1, 'list declare');
    src := pg_temp.ganti(src,
      $p$  if v_master is not null and v_master not in ('siap', 'kurang') then raise exception 'Saringan Customer Master tidak dikenal'; end if;$p$,
      $p$  if v_master is not null and v_master not in ('siap', 'kurang') then raise exception 'Saringan Customer Master tidak dikenal'; end if;
  if v_remark is not null and v_remark not in ('pda', 'pdh', 'campur', 'pp', 'tanpa_pp') then raise exception 'Saringan Remark tidak dikenal'; end if;$p$,
      1, 'list validasi');
    src := pg_temp.ganti(src,
      $p$           count(*) filter (where exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = k.claim_id and bb.diproses)) n_bukti$p$,
      $p$           -- 20261163740000: hanya dokumen PDA, karena Bukti TF dicetak sesudah form PDA.
           count(*) filter (where rc_private.docgen_kategori(k.tgl_done, k.jenis_cb) = 'PDA'
                              and exists (select 1 from public.rc_clearing_bank_baris bb where bb.claim_id = k.claim_id and bb.diproses)) n_bukti$p$,
      1, 'list n_bukti');
    src := pg_temp.ganti(src,
      $p$           coalesce(btrim(cu.bank), '') bank, coalesce(btrim(cu.account_number), '') no_rek, coalesce(btrim(cu.account_name), '') atas_nama,
$p$, '', 1, 'list rekening s');
    src := pg_temp.ganti(src, $p$s.sales, s.bank, s.no_rek, s.atas_nama, s.depot_code$p$, $p$s.sales, s.depot_code$p$, 1, 'list cari');
    src := pg_temp.ganti(src,
      $p$       and (v_master is null or (v_master = 'siap') = (s.masalah is null))$p$,
      $p$       and (v_master is null or (v_master = 'siap') = (s.masalah is null))
       and (v_remark is null or (v_remark = 'pda' and s.ada_pda and not s.ada_pdh) or (v_remark = 'pdh' and s.ada_pdh and not s.ada_pda)
            or (v_remark = 'campur' and s.ada_pda and s.ada_pdh) or (v_remark = 'pp' and s.n_bukti > 0) or (v_remark = 'tanpa_pp' and s.n_bukti = 0))$p$,
      1, 'list saring');
    src := pg_temp.ganti(src,
      $p$             'bank', h.bank, 'noRek', h.no_rek, 'atasNama', h.atas_nama,
$p$, '', 1, 'list rekening out');
    src := pg_temp.ganti(src,
      $p$'remark', concat_ws(' + ', case when h.ada_pda then 'PDA' end, case when h.ada_pdh then 'PDH' end) /* 20261163700000 */,$p$,
      $p$'remark', concat_ws(' + ', case when h.ada_pda then 'PDA' end, case when h.ada_pdh then 'PDH' end,
                                case when h.n_bukti > 0 then 'PP' end) /* 20261163700000, PP 20261163740000 */,$p$,
      1, 'list remark');
    execute src;
  end if;

  -- ---- 2. Form: tanpa rekening ----------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure), E'\r', '');
  if src ~ '''rekening''' then
    src := pg_temp.ganti(src,
      $p$           coalesce(btrim(cu.bank), '') bank, coalesce(btrim(cu.account_number), '') no_rek, coalesce(btrim(cu.account_name), '') atas_nama,
$p$, '', 1, 'generate rekening r');
    src := pg_temp.ganti(src,
      $p$        'rekening', jsonb_build_object('bank', r.bank, 'noRek', r.no_rek, 'atasNama', r.atas_nama),
$p$, '', 1, 'generate rekening out');
    execute src;
  end if;
end $tambal$;

-- ---- 3. Hasil Upload File Bank: nama campaign dan Gross Up untuk Laporan Workflow --------------
do $bank$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.clearing_bank_hasil(uuid)'::regprocedure), E'\r', '');
  if src !~ 'namaCampaign' then
    src := pg_temp.ganti(src,
      $p$'depot', coalesce(d.depot_code, ''), 'campaign', coalesce(ca.campaign_code, ''))$p$,
      $p$'depot', coalesce(d.depot_code, ''), 'campaign', coalesce(ca.campaign_code, ''),
         'namaCampaign', coalesce(ca.campaign_name, ''), 'grossUp', trunc(coalesce(c.gross_up, 0)) /* 20261163740000 */)$p$,
      1, 'hasil');
    execute src;
  end if;
end $bank$;

do $cek$
declare l text := pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure);
        g text := pg_get_functiondef('public.rc_docgen_generate(jsonb,text,jsonb)'::regprocedure);
begin
  if l !~ 'v_remark' or l ~ 'atasNama' or l ~ 'account_number' then raise exception 'GAGAL: list'; end if;
  if g ~ '''rekening''' or g ~ 'account_number' then raise exception 'GAGAL: generate'; end if;
  if pg_get_functiondef('rc_private.clearing_bank_hasil(uuid)'::regprocedure) !~ 'namaCampaign' then raise exception 'GAGAL: hasil'; end if;
end $cek$;
