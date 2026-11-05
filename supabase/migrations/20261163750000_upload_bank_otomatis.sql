-- ==========================================================================================
-- Upload File Bank: satu jalur otomatis (Clearing + Bukti TF) tanpa pilihan Mode
-- ==========================================================================================
-- Pemilik, 5 November 2026: "untuk part clearing tadi saya minta bisa dengan txt doc lalu nanti keluar
-- pop up seperti biasa ketika proses". Pada uji di dev, file Clearing (27 baris) ikut terproses di
-- mode Arsip karena pilihan Mode masih tertinggal dari file sebelumnya: 20 dokumen Pending Finance
-- tidak di-Clearing. Pilihan Mode ditiadakan di layar; satu upload kini menilai tiap baris sendiri:
--   * dokumen Pending Finance (Claimed), nominal = Net CB          -> ok       : Clearing (Done) lewat
--                                                                    alur lama, Bukti TF tersimpan;
--   * dokumen yang SUDAH Done, belum punya Bukti TF, nominal sama -> ok_bukti : hanya Bukti TF yang
--                                                                    disimpan, status / batch tetap;
--   * selebihnya seperti sebelumnya (nominal beda, tidak ditemukan, terpotong, sudah diproses, ...).
-- Mode 'clearing' dan 'arsip' (20261163710000 / 20261163730000) tetap dikenal server; layar memakai
-- 'otomatis'. Sidik file tetap unik per mode. Butuh 20261163740000. Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regprocedure('rc_private.bukti_tf(uuid)') is null
     or pg_get_functiondef('rc_private.clearing_bank_hasil(uuid)'::regprocedure) !~ 'namaCampaign' then
    raise exception 'DITOLAK: jalankan 20261163740000 lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Mode otomatis -----------------------------------------------------------------------------
alter table public.rc_clearing_bank_upload drop constraint if exists rc_clearing_bank_upload_mode_check;
alter table public.rc_clearing_bank_upload add constraint rc_clearing_bank_upload_mode_check check (mode in ('clearing', 'arsip', 'otomatis'));

do $tambal$
declare src text;
begin
  -- ---- 2. Penilaian baris: dokumen Done di mode otomatis dinilai seperti arsip (hasil ok_bukti) -------
  src := replace(pg_get_functiondef('rc_private.clearing_bank_nilai(text,date,numeric,boolean,text,text,text,boolean,uuid,text)'::regprocedure), E'\r', '');
  if src !~ 'ok_bukti' then
    src := pg_temp.ganti(src,
      $p$  if coalesce(p_mode, 'clearing') = 'arsip' then$p$,
      $p$  if coalesce(p_mode, 'clearing') = 'arsip' or (p_mode = 'otomatis' and c.status = 'done') then /* otomatis: 20261163750000 */$p$,
      1, 'nilai arsip');
    src := pg_temp.ganti(src,
      $p$    return query select 'ok', 'Siap diarsip sebagai Bukti TF (Done ' ||
      coalesce(to_char(coalesce(c.cleared_actual_on, (c.cleared_at at time zone 'Asia/Jakarta')::date), 'DD-Mon-YYYY'), '-') || ')',$p$,
      $p$    return query select case when p_mode = 'otomatis' then 'ok_bukti' else 'ok' end,
      case when p_mode = 'otomatis' then 'Sudah Done (tanggal clearing ' else 'Siap diarsip sebagai Bukti TF (Done ' end ||
      coalesce(to_char(coalesce(c.cleared_actual_on, (c.cleared_at at time zone 'Asia/Jakarta')::date), 'DD-Mon-YYYY'), '-') ||
      case when p_mode = 'otomatis' then coalesce(', batch ' || nullif(btrim(c.batch_clearing), ''), '') || '): hanya Bukti TF yang disimpan, status tidak berubah' else ')' end,$p$,
      1, 'nilai ok_bukti');
    execute src;
  end if;

  -- ---- 3. Ringkasan: Nominal OK termasuk ok_bukti ----------------------------------------------------
  src := replace(pg_get_functiondef('rc_private.clearing_bank_hasil(uuid)'::regprocedure), E'\r', '');
  if src !~ 'ok_bukti' then
    src := pg_temp.ganti(src,
      $p$where b.upload_id = u.id and b.hasil = 'ok'),$p$,
      $p$where b.upload_id = u.id and b.hasil in ('ok', 'ok_bukti')),$p$, 1, 'hasil totalOk');
    execute src;
  end if;

  -- ---- 4. Pratinjau: mode otomatis ------------------------------------------------------------------
  src := replace(pg_get_functiondef('public.rc_clearing_bank_preview(text,text,integer,text,jsonb,text)'::regprocedure), E'\r', '');
  if src !~ 'otomatis' then
    src := pg_temp.ganti(src,
      $p$  if v_mode not in ('clearing', 'arsip') then raise exception 'Mode upload tidak dikenal'; end if;$p$,
      $p$  if v_mode not in ('clearing', 'arsip', 'otomatis') then raise exception 'Mode upload tidak dikenal'; end if;$p$, 1, 'preview mode');
    src := pg_temp.ganti(src,
      $p$      case when v_mode = 'arsip' then 'Arsip Bukti TF' else 'Clearing' end,$p$,
      $p$      case v_mode when 'arsip' then 'Arsip Bukti TF' when 'otomatis' then 'Upload File Bank' else 'Clearing' end,$p$, 1, 'preview sudah');
    src := pg_temp.ganti(src,
      $p$|| case when v_mode = 'arsip' then ' siap diarsip sebagai Bukti TF.' else ' siap Clearing.' end || ' Belum ada yang disimpan.');$p$,
      $p$|| case when v_mode = 'arsip' then ' siap diarsip sebagai Bukti TF.' else ' siap Clearing' ||
                                    case when v_mode = 'otomatis' then ', ' || coalesce((v->'ringkasan'->'perHasil'->>'ok_bukti'), '0') || ' sudah Done (simpan Bukti TF)' else '' end || '.' end
                                 || ' Belum ada yang disimpan.');$p$, 1, 'preview pesan');
    execute src;
  end if;
end $tambal$;

-- ---- 5. Proses: Clearing baris ok, Bukti TF baris ok_bukti --------------------------------------------
create or replace function public.rc_clearing_bank_proses(p_upload uuid)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare u public.rc_clearing_bank_upload; v_items jsonb; v_hasil jsonb; v_batch text; n_ok integer; n_clr integer; n_btf integer;
  n_berubah integer := 0; v jsonb;
begin
  perform rc_private.require_tab('process.clearing');
  select * into u from public.rc_clearing_bank_upload where id = p_upload for update;
  if not found then raise exception 'Upload tidak ditemukan'; end if;
  if u.status = 'diproses' then raise exception 'Upload ini sudah diproses (%).', coalesce('batch ' || u.batch_clearing, 'Bukti TF'); end if;
  if exists (select 1 from public.rc_clearing_bank_upload x where x.sidik = u.sidik and x.mode = u.mode and x.status = 'diproses') then
    raise exception 'File dengan isi yang sama sudah diproses sebelumnya. File yang sama tidak bisa diproses dua kali.'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rc_clearing_bank', 0));

  -- Nilai ulang baris OK: klaim bisa berubah sejak pratinjau. Di mode otomatis dokumen yang sementara
  -- itu di-Clearing orang lain berpindah ke ok_bukti dan tetap diproses (hanya Bukti TF).
  with nilai as (
    select b.baris_ke, z.* from public.rc_clearing_bank_baris b
      cross join lateral rc_private.clearing_bank_nilai(b.remark1, b.tgl_transfer, b.nominal, true, b.status_bank, b.reason, b.trans_id, false, b.upload_id, u.mode) z
     where b.upload_id = u.id and b.hasil in ('ok', 'ok_bukti'))
  update public.rc_clearing_bank_baris b set hasil = n.hasil, claim_id = n.claim_id, no_doc_rc = n.no_doc_rc, nominal_klaim = n.nominal_klaim,
         keterangan = case when n.hasil = b.hasil then b.keterangan else 'Berubah sejak pratinjau: ' || n.keterangan end
    from nilai n where b.upload_id = u.id and b.baris_ke = n.baris_ke;
  select count(*) into n_berubah from public.rc_clearing_bank_baris b
   where b.upload_id = u.id and b.keterangan like 'Berubah sejak pratinjau:%' and b.hasil not in ('ok', 'ok_bukti');
  -- Mode arsip: hasil ok = Bukti TF. Mode clearing / otomatis: ok = Clearing, ok_bukti = Bukti TF.
  select count(*) filter (where b.hasil = 'ok' and u.mode <> 'arsip'),
         count(*) filter (where b.hasil = 'ok_bukti' or (b.hasil = 'ok' and u.mode = 'arsip'))
    into n_clr, n_btf from public.rc_clearing_bank_baris b where b.upload_id = u.id;
  n_ok := n_clr + n_btf;
  if n_ok = 0 then
    raise exception 'Tidak ada baris berstatus OK untuk diproses%.', case when n_berubah > 0 then ' (' || n_berubah || ' baris berubah sejak pratinjau)' else '' end;
  end if;

  if n_clr > 0 then
    select jsonb_agg(jsonb_build_object('no_doc', c.no_doc, 'version_no', c.version_no, 'tgl_aktual', to_char(b.tgl_transfer, 'YYYY-MM-DD')) order by c.no_doc)
      into v_items
      from public.rc_clearing_bank_baris b join public.claims c on c.id = b.claim_id
     where b.upload_id = u.id and b.hasil = 'ok';
    -- Alur Clearing lama, apa adanya: Done, batch Clearing 04, Tgl Transfer aktual per dokumen, email Done.
    v_hasil := rc_private.mutate_claims('clearing', v_items, gen_random_uuid(), '');
    v_batch := v_hasil->>'batch';
  end if;

  update public.rc_clearing_bank_baris b set diproses = true,
         keterangan = case when u.mode = 'arsip' or b.hasil = 'ok_bukti'
                           then 'Bukti TF tersimpan (Tgl Transfer ' || to_char(b.tgl_transfer, 'DD-Mon-YYYY') || ')'
                                || case when b.hasil = 'ok_bukti' then '; dokumen sudah Done sebelumnya, status tidak berubah' else '' end
                           else 'Clearing selesai, Tgl Transfer ' || to_char(b.tgl_transfer, 'DD-Mon-YYYY') || coalesce(', batch ' || v_batch, '') end
   where b.upload_id = u.id and b.hasil in ('ok', 'ok_bukti');
  update public.rc_clearing_bank_upload set status = 'diproses', batch_clearing = v_batch, jumlah_diproses = n_ok,
         diproses_oleh = auth.uid(), diproses_pada = now(),
         ringkasan = (select coalesce(jsonb_object_agg(z.hasil, z.n), '{}'::jsonb) from (select b.hasil, count(*) n from public.rc_clearing_bank_baris b
                       where b.upload_id = u.id group by 1) z)
   where id = u.id;

  insert into public.activity_logs(actor_id, event_type, details, module, tab, process_stage, batch_no)
  values (auth.uid(), case when u.mode = 'arsip' then 'bukti_tf_arsip' else 'clearing_upload_bank' end,
    jsonb_build_object('detail', case u.mode
                                   when 'arsip' then 'Arsip Bukti TF dari file bank ' || u.nama_file || ': ' || n_ok || ' dokumen'
                                   when 'clearing' then 'Clearing dari file bank ' || u.nama_file || ': ' || n_ok || ' dokumen Done'
                                   else 'Upload file bank ' || u.nama_file || ': ' || concat_ws(', ',
                                          case when n_clr > 0 then n_clr || ' dokumen Done (Clearing)' end,
                                          case when n_btf > 0 then n_btf || ' Bukti TF dokumen yang sudah Done' end) end
                         || case when n_berubah > 0 then ' (' || n_berubah || ' baris berubah sejak pratinjau, tidak diproses)' else '' end,
                       'upload', u.id, 'file', u.nama_file, 'mode', u.mode, 'jumlah', n_ok, 'clearing', n_clr, 'bukti', n_btf,
                       'berubah', n_berubah, 'batch', v_batch),
    'process', 'clearing', 'clearing', v_batch);

  v := rc_private.clearing_bank_hasil(u.id);
  return v || jsonb_build_object('batch', v_batch, 'diproses', n_ok, 'clearing', n_clr, 'bukti', n_btf, 'berubah', n_berubah,
    'message', case when u.mode = 'arsip' then n_ok || ' Bukti TF tersimpan (klaim tidak diubah)'
                    else concat_ws('; ', case when n_clr > 0 then n_clr || ' dokumen di-Clearing (Done), batch ' || coalesce(v_batch, '-') end,
                                         case when n_btf > 0 then n_btf || ' Bukti TF tersimpan untuk dokumen yang sudah Done (status tidak berubah)' end) end
      || case when n_berubah > 0 then '; ' || n_berubah || ' baris berubah sejak pratinjau dan tidak diproses' else '' end || '.');
end $f$;

revoke all on function public.rc_clearing_bank_proses(uuid) from public, anon;
grant execute on function public.rc_clearing_bank_proses(uuid) to authenticated;

do $cek$ begin
  if pg_get_functiondef('rc_private.clearing_bank_nilai(text,date,numeric,boolean,text,text,text,boolean,uuid,text)'::regprocedure) !~ 'ok_bukti' then raise exception 'GAGAL: nilai'; end if;
  if pg_get_functiondef('public.rc_clearing_bank_preview(text,text,integer,text,jsonb,text)'::regprocedure) !~ 'otomatis' then raise exception 'GAGAL: preview'; end if;
  if pg_get_functiondef('rc_private.clearing_bank_hasil(uuid)'::regprocedure) !~ 'ok_bukti' then raise exception 'GAGAL: hasil'; end if;
end $cek$;
