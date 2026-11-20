-- ==========================================================================================
-- Clearing file bank: No Doc boleh ditulis sebagian, mulai dari Abbr depot
-- ==========================================================================================
-- Pemilik, 14 November 2026:
--   "ada masalah banyak file txt tidak terbaca ternyata karena terlalu panjang, oleh karena itu
--    saya putuskan yang dibaca boleh sebagian karakter aja asal spesifik contoh ketika di bca
--    klik CKR/2125/032 maka akan otomatis terbaca. dan ini tidak menutup kemungkinan dengan no
--    doc penuh juga hanya saja ketika spesifik dari abbr ke belakang itu sudah valid dijadikan
--    acuan."
--   "dengan no ref tetep mengikuti no doc lengkap dan tanggal efektif di bukti transfer diubah
--    jadi 'Tanggal Transferr'"
--
-- Remark 1 di KlikBCA hanya memuat 18 karakter, sedangkan No Doc tanpa "NPC/" sering lebih
-- panjang (182 dari 1.285 dokumen Claimed di prod). Sekarang Remark 1 dicocokkan begini:
--   1. No Doc lengkap, dengan atau tanpa "NPC/" (seperti sebelumnya).
--   2. Bila tidak ada: BAGIAN AKHIR No Doc, mulai dari Abbr depot - minimal tiga ruas
--      (Abbr / kode campaign / nomor urut, mis. CKR/2125/032) dan harus tepat di batas "/".
--      Huruf besar-kecil tidak dibedakan. Di prod bagian akhir tiga ruas itu unik untuk seluruh
--      dokumen dan paling panjang 17 karakter, jadi selalu muat di kolom bank.
--   3. Bila bagian akhir itu cocok dengan lebih dari satu dokumen: ditolak (tidak_spesifik).
--   4. Kurang dari tiga ruas tidak pernah dipakai sebagai acuan.
-- Dua baris dengan tulisan berbeda yang menunjuk dokumen yang sama ditolak sebagai duplikat.
-- Bukti Transfer: "Berita" selalu No Doc lengkap milik dokumennya (bukan potongan dari bank);
-- label "Tanggal Efektif" diganti di layar (53-document-generator.js).
-- Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

do $tambal$
declare src text; f regprocedure;
begin
  -- ---- Aturan pencocokan ------------------------------------------------------------------------
  select p.oid::regprocedure into f from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'rc_private' and p.proname = 'clearing_bank_nilai';
  src := replace(pg_get_functiondef(f), E'\r', '');
  if src !~ '20261163990000' then
    src := pg_temp.ganti(src, $p$declare c record; v_kandidat text; v_jenis text; v_lama record; v_doc text := btrim(coalesce(p_remark, ''));$p$,
      $p$declare c record; v_kandidat text; v_jenis text; v_lama record; v_doc text := btrim(coalesce(p_remark, ''));
  v_n integer; v_pola text; -- 20261163990000$p$, 1, 'nilai declare');
    src := pg_temp.ganti(src, $p$  if not found then
    if length(v_doc) >= 18 and p_mode is distinct from 'template' then$p$,
      $p$  -- 20261163990000: No Doc ditulis sebagian - bagian akhir mulai dari Abbr depot (minimal tiga ruas,
  -- tepat di batas "/"), dan hanya bila menunjuk satu dokumen saja.
  if not found and v_doc ~ '^[^/]+(/[^/]+){2,}$' then
    v_pola := '%/' || replace(replace(replace(v_doc, '\', '\\'), '%', '\%'), '_', '\_');
    select count(*) into v_n from public.claims x where x.archived_at is null and x.no_doc ilike v_pola;
    if v_n > 1 then
      select string_agg(z.no_doc, ', ' order by z.no_doc) into v_kandidat
        from (select x.no_doc from public.claims x where x.archived_at is null and x.no_doc ilike v_pola order by x.no_doc limit 5) z;
      return query select 'tidak_spesifik', 'No Doc "' || v_doc || '" cocok dengan ' || v_n || ' dokumen (' || v_kandidat
        || case when v_n > 5 then ', ...' else '' end || '). Tulis lebih lengkap.', null::uuid, null::text, null::numeric; return;
    end if;
    if v_n = 1 then
      select cl.id, cl.no_doc, cl.status, cl.cb_net, cl.cleared_actual_on, cl.cleared_at, cl.batch_clearing, cl.pending_approval,
             cl.jalur_adhoc, cl.cashback_type_override, ca.cashback_type
        into c
        from public.claims cl join public.campaigns ca on ca.id = cl.campaign_id
       where cl.archived_at is null and cl.no_doc ilike v_pola;
    end if;
  end if;
  if c.id is null then
    if length(v_doc) >= 18 and p_mode is distinct from 'template' then$p$, 1, 'nilai sebagian');
    src := pg_temp.ganti(src, $p$    return query select 'tidak_ditemukan', 'No Doc tidak ada di RC', null::uuid, null::text, null::numeric; return;$p$,
      $p$    return query select 'tidak_ditemukan', 'No Doc tidak ada di RC'
      || case when v_doc !~ '^[^/]+(/[^/]+){2,}$' then '. Tulis No Doc lengkap atau minimal mulai dari Abbr depot, mis. CKR/2125/032' else '' end,
      null::uuid, null::text, null::numeric; return;$p$, 1, 'nilai pesan');
    execute src;
  end if;

  -- ---- Pratinjau: tulisan berbeda yang menunjuk dokumen yang sama = duplikat ---------------------
  select p.oid::regprocedure into f from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'rc_clearing_bank_preview';
  src := replace(pg_get_functiondef(f), E'\r', '');
  if src !~ '20261163990000' then
    src := pg_temp.ganti(src, $p$   where b.upload_id = v_id and b.baris_ke = n.baris_ke;

  select count(*) into n_baris$p$,
      $p$   where b.upload_id = v_id and b.baris_ke = n.baris_ke;

  -- 20261163990000: No Doc boleh ditulis sebagian, jadi dua tulisan berbeda bisa menunjuk dokumen yang sama.
  update public.rc_clearing_bank_baris b set hasil = 'duplikat', keterangan = 'Dokumen ' || b.no_doc_rc || ' muncul lebih dari sekali dalam file (No Doc ditulis berbeda)'
   where b.upload_id = v_id and b.hasil in ('ok', 'ok_bukti') and b.claim_id is not null
     and (select count(*) from public.rc_clearing_bank_baris b2 where b2.upload_id = v_id and b2.claim_id = b.claim_id and b2.hasil in ('ok', 'ok_bukti', 'duplikat')) > 1;

  select count(*) into n_baris$p$, 1, 'preview duplikat dokumen');
    execute src;
  end if;

  -- ---- Bukti Transfer: Berita = No Doc lengkap ---------------------------------------------------
  src := replace(pg_get_functiondef('rc_private.bukti_tf(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163990000' then
    src := pg_temp.ganti(src, $p$'berita', regexp_replace(b.remark1, '^NPC/', ''),$p$,
      $p$'berita', c.no_doc, /* 20261163990000: No Doc lengkap, bukan potongan yang ditulis di bank */$p$, 1, 'bukti berita');
    execute src;
  end if;
end $tambal$;

do $cek$
declare f regprocedure;
begin
  select p.oid::regprocedure into f from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'rc_private' and p.proname = 'clearing_bank_nilai';
  if pg_get_functiondef(f) !~ 'tidak_spesifik' then raise exception 'GAGAL: aturan sebagian'; end if;
  if pg_get_functiondef('rc_private.bukti_tf(uuid)'::regprocedure) !~ '''berita'', c.no_doc' then raise exception 'GAGAL: berita'; end if;
end $cek$;
