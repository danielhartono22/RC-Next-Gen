-- ==========================================================================================
-- Claim Process > Clearing: Mass Upload (template No Doc + Tanggal Proses Aktual)
-- ==========================================================================================
-- Pemilik, 9 November 2026. Mass Process (tempel No Doc) diganti Mass Upload. Memakai mesin Upload File
-- Bank (rc_clearing_bank_preview / proses, mode baru 'template') supaya pratinjau, log, dan popup sama:
-- * Isi template cukup No Doc dan Tanggal Proses Aktual. Tanpa nominal, jadi nominal tidak dibandingkan.
-- * Dokumen yang sudah diupload lewat file bank, atau sudah Done: hasil 'sudah_diupload' ("sudah diupload
--   dan tidak berubah"), nilai lama tetap. Selebihnya di-Clearing lewat alur lama.
-- * Jenis Transfer: Bukti TF tetap tersedia dengan No. Referensi kosong, isi lainnya dari data klaim
--   (sumber 'template'; tidak mengaku berasal dari KlikBCA). Jenis lain: di-Clearing tanpa Bukti TF.
-- * File bank menang: file bank yang menyusul mengganti Bukti TF dari template (status dan Tgl Done
--   dokumen tetap), dan tidak ditolak sebagai "sudah punya Bukti TF".
-- Butuh 20261163760000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.rc_clearing_bank_baris add column if not exists ada_bukti boolean not null default true;
alter table public.rc_clearing_bank_upload drop constraint if exists rc_clearing_bank_upload_mode_check;
alter table public.rc_clearing_bank_upload add constraint rc_clearing_bank_upload_mode_check check (mode in ('clearing', 'arsip', 'otomatis', 'template'));

do $tambal$
declare src text;
begin
  -- ---- Penilaian baris ---------------------------------------------------------------------------
  src := replace(pg_get_functiondef('rc_private.clearing_bank_nilai(text,date,numeric,boolean,text,text,text,boolean,uuid,text)'::regprocedure), E'\r', '');
  if src !~ 'sudah_diupload' then
    src := pg_temp.ganti(src, $p$    if length(v_doc) >= 18 then$p$,
      $p$    if length(v_doc) >= 18 and p_mode is distinct from 'template' then$p$, 1, 'nilai terpotong');
    -- Bukti TF dari template tidak menghalangi file bank.
    src := pg_temp.ganti(src,
      $p$     where b.diproses and b.claim_id = c.id and b.upload_id <> coalesce(p_upload, gen_random_uuid()) limit 1;$p$,
      $p$     where b.diproses and b.claim_id = c.id and b.upload_id <> coalesce(p_upload, gen_random_uuid()) and u.mode <> 'template' limit 1;$p$, 1, 'nilai bukti');
    src := pg_temp.ganti(src,
      $p$  if coalesce(p_mode, 'clearing') = 'arsip' or (p_mode = 'otomatis' and c.status = 'done') then$p$,
      $p$  if p_mode = 'template' then /* 20261163790000 */
    select u.nama_file, u.diproses_pada into v_lama
      from public.rc_clearing_bank_baris b join public.rc_clearing_bank_upload u on u.id = b.upload_id
     where b.diproses and b.claim_id = c.id and u.mode <> 'template' limit 1;
    if found then
      return query select 'sudah_diupload', 'Sudah diupload lewat file bank ' || v_lama.nama_file || '; nilai file bank tetap, tidak berubah',
        c.id, c.no_doc, trunc(c.cb_net); return;
    end if;
    if c.status = 'done' then
      return query select 'sudah_diupload', 'Sudah diupload dan tidak berubah (Done ' ||
        coalesce(to_char(coalesce(c.cleared_actual_on, (c.cleared_at at time zone 'Asia/Jakarta')::date), 'DD-Mon-YYYY'), '-') ||
        coalesce(', batch ' || nullif(btrim(c.batch_clearing), ''), '') || ')', c.id, c.no_doc, trunc(c.cb_net); return;
    end if;
  end if;

  if coalesce(p_mode, 'clearing') = 'arsip' or (p_mode = 'otomatis' and c.status = 'done') then$p$, 1, 'nilai template');
    src := pg_temp.ganti(src, E'\n  if trunc(c.cb_net) is distinct from trunc(p_nominal) then',
      E'\n  if p_mode is distinct from ''template'' and trunc(c.cb_net) is distinct from trunc(p_nominal) then', 1, 'nilai nominal');
    execute src;
  end if;

  -- ---- Ringkasan: template tidak punya nominal transfer ----------------------------------------------
  src := replace(pg_get_functiondef('rc_private.clearing_bank_hasil(uuid)'::regprocedure), E'\r', '');
  if src !~ 'nominal_klaim, 0' then
    src := pg_temp.ganti(src, $p$coalesce(sum(b.nominal), 0)$p$, $p$coalesce(sum(coalesce(b.nominal, b.nominal_klaim, 0)), 0)$p$, 2, 'hasil total');
    execute src;
  end if;

  -- ---- Pratinjau -------------------------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_clearing_bank_preview(text,text,integer,text,jsonb,text)'::regprocedure), E'\r', '');
  if src !~ '''template''' then
    src := pg_temp.ganti(src, $p$  if v_mode not in ('clearing', 'arsip', 'otomatis') then$p$,
      $p$  if v_mode not in ('clearing', 'arsip', 'otomatis', 'template') then$p$, 1, 'preview mode');
    execute src;
  end if;

  -- ---- Proses ----------------------------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_clearing_bank_proses(uuid)'::regprocedure), E'\r', '');
  if src !~ '''template''' then
    src := pg_temp.ganti(src, $p$  update public.rc_clearing_bank_baris b set diproses = true,$p$,
      $p$  -- 20261163790000: file bank mengganti Bukti TF dari template; template mengisi data dari klaim.
  if u.mode = 'template' then
    update public.rc_clearing_bank_baris b
       set nominal = b.nominal_klaim, ada_bukti = (rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)) = 'transfer'),
           to_acc = coalesce(nullif(btrim(s.account_number), ''), nullif(btrim(cu.account_number), ''), ''),
           bank = coalesce(nullif(btrim(s.bank), ''), nullif(btrim(cu.bank), ''), '')
      from public.claims c join public.campaigns ca on ca.id = c.campaign_id
      left join public.customers cu on cu.id = c.customer_id
      left join rc_private.claim_sensitive s on s.claim_id = c.id
     where c.id = b.claim_id and b.upload_id = u.id and b.hasil = 'ok';
  else
    update public.rc_clearing_bank_baris t set diproses = false, keterangan = 'Bukti TF diganti file bank ' || u.nama_file
      from public.rc_clearing_bank_upload tu
     where tu.id = t.upload_id and tu.mode = 'template' and t.diproses
       and t.claim_id in (select b.claim_id from public.rc_clearing_bank_baris b where b.upload_id = u.id and b.hasil in ('ok', 'ok_bukti'));
  end if;

  update public.rc_clearing_bank_baris b set diproses = true,$p$, 1, 'proses bukti');
    src := pg_temp.ganti(src, $p$                                   when 'clearing' then 'Clearing dari file bank '$p$,
      $p$                                   when 'template' then 'Mass Upload Clearing ' || u.nama_file || ': ' || n_clr || ' dokumen Done'
                                   when 'clearing' then 'Clearing dari file bank '$p$, 1, 'proses log');
    execute src;
  end if;

  -- ---- Remark PP hanya bila ada Bukti TF ---------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_docgen_list(text,jsonb,integer,integer,boolean)'::regprocedure), E'\r', '');
  if src !~ 'ada_bukti' then
    src := pg_temp.ganti(src, $p$bb.claim_id = k.claim_id and bb.diproses)$p$, $p$bb.claim_id = k.claim_id and bb.diproses and bb.ada_bukti)$p$, 1, 'list');
    execute src;
  end if;
end $tambal$;

-- ---- Bukti TF: sumber template -----------------------------------------------------------------------
create or replace function rc_private.bukti_tf(p_claim uuid) returns jsonb
language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object(
    'noDoc', c.no_doc, 'campaign', coalesce(ca.campaign_code, ''),
    'sumber', case when u.mode = 'template' then 'template' else 'bank' end,
    'tglEfektif', to_char(b.tgl_transfer, 'DD-Mon-YYYY'), 'transId', b.trans_id,
    'layanan', case when u.mode = 'template' then 'Transfer' else
               case upper(btrim(b.layanan)) when 'BCA' then 'Transfer sesama BCA' when 'LLG' then 'Transfer Antarbank (LLG)'
                    when 'RTGS' then 'Transfer Antarbank (RTGS)' when 'BIFAST' then 'Transfer Antarbank (BI-FAST)' when '' then 'Transfer'
                    else 'Transfer ' || b.layanan end || ' - KlikBCA Bisnis' end,
    'dariRek', b.dari_rek,
    'dariNama', case when upper(b.dari_nama) like 'NIPSEA PAINT AND CHEMICA%' then 'PT NIPSEA PAINT AND CHEMICALS' else b.dari_nama end,
    'keRek', b.to_acc,
    'bankTujuan', coalesce(nullif(btrim(b.nama_bank), ''), case when upper(btrim(b.layanan)) = 'BCA' then 'PT. BANK CENTRAL ASIA TBK' end, nullif(btrim(b.bank), ''), '-'),
    'namaPenerima', coalesce(nullif(btrim(s.account_name), ''), nullif(btrim(cu.account_name), ''), ''),
    'nominal', b.nominal, 'biaya', coalesce(b.biaya, 0),
    'biayaOleh', case upper(btrim(b.biaya_oleh)) when 'OUR' then 'ditanggung pengirim' when 'BEN' then 'ditanggung penerima'
                      when 'SHA' then 'ditanggung bersama' else lower(b.biaya_oleh) end,
    'berita', regexp_replace(b.remark1, '^NPC/', ''),
    'status', case when u.mode = 'template' then 'DIPROSES' else upper(b.status_bank) end)
  from public.rc_clearing_bank_baris b
  join public.rc_clearing_bank_upload u on u.id = b.upload_id
  join public.claims c on c.id = b.claim_id
  left join public.campaigns ca on ca.id = c.campaign_id
  left join public.customers cu on cu.id = c.customer_id
  left join rc_private.claim_sensitive s on s.claim_id = c.id
 where b.claim_id = p_claim and b.diproses and b.ada_bukti
 limit 1;
$f$;
revoke all on function rc_private.bukti_tf(uuid) from public, anon, authenticated;

do $cek$ begin
  if pg_get_functiondef('rc_private.clearing_bank_nilai(text,date,numeric,boolean,text,text,text,boolean,uuid,text)'::regprocedure) !~ 'sudah_diupload' then raise exception 'GAGAL: nilai'; end if;
  if pg_get_functiondef('public.rc_clearing_bank_proses(uuid)'::regprocedure) !~ 'ada_bukti' then raise exception 'GAGAL: proses'; end if;
end $cek$;
