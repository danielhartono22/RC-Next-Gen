-- ==========================================================================================
-- Digit pertama batch: 6 = compile ulang dari dokumen arsip, 7 = nilai diubah (Change Value)
-- ==========================================================================================
-- Pemilik, 9 November 2026: "untuk dokumen yang arsip lalu compile ulang kepala pertama ... akan terbentuk 6
-- artinya dideteksi ada dokumen dengan kode cust dan kode campaign yang lama dan diarsipkan. Untuk
-- dokumen yang value-nya diubah no kepalanya akan 7 di stage dokumen itu diubah dan selanjutnya."
-- Melanjutkan 20261163160000 (K T SSS DDMMYY NNNN, disimpan di claims.batch_event_code, kejadian terakhir
-- yang berlaku, terbawa ke proses berikutnya):
-- * 6: compile_upload memeriksa dokumen arsip dengan toko + campaign yang sama. Batch compile di riwayat
--   dan seluruh batch berikutnya berkepala 6. Satu compile tetap satu nomor urut; hasil dan Log Activity
--   memuat kedua nomor bila campur.
-- * 7: rc_amend_doc memakai 7 (sebelumnya 1). Batch stage dokumen saat ini ikut berkepala 7; batch stage
--   sebelumnya tidak berubah. Not Yet belum punya batch, jadi 7 muncul di proses berikutnya.
-- * Dokumen yang pernah di-Amend (kode 1): proses berikutnya memakai 7; batch yang sudah terbit tetap.
-- Butuh 20261163830000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

create or replace function rc_private.batch_kejadian(p_batch text, p_kode text)
returns text language sql immutable set search_path to '' as $f$
  select case when p_batch ~ '^0[1-5].{13}$' and p_kode in ('1','2','3','4','6','7')
              then p_kode || substr(p_batch, 2) else p_batch end;
$f$;

alter table public.claims drop constraint if exists claims_batch_event_code_check;
alter table public.claims add constraint claims_batch_event_code_check check (batch_event_code in ('0','1','2','3','4','6','7'));
update public.claims set batch_event_code = '7' where batch_event_code = '1';

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.next_batch(text)'::regprocedure), E'\r', '');
  if src !~ '''7''\|\|substr' then
    src := pg_temp.ganti(src, $p$'4'||substr(b,2)];$p$, $p$'4'||substr(b,2),'6'||substr(b,2),'7'||substr(b,2)]; /* 20261163840000 */$p$, 1, 'next_batch');
    execute src;
  end if;

  src := replace(pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure), E'\r', '');
  if src !~ 'v_ulang' then
    src := pg_temp.ganti(src, $p$ batch text; kunci text; terlihat jsonb:='{}';$p$,
      $p$ batch text; kunci text; terlihat jsonb:='{}';
 v_ulang boolean; ada_biasa boolean:=false; ada_ulang boolean:=false; v_batch_hasil text; -- 20261163840000$p$, 1, 'compile declare');
    src := pg_temp.ganti(src, $p$  v_doc:=rc_private.next_document(v_abbr,v_code);$p$,
      $p$  -- 20261163840000: toko + campaign ini pernah diarsipkan = compile ulang, kepala batch 6.
  v_ulang:=exists(select 1 from public.claims z where z.campaign_id=v_camp.id and z.customer_id=v_cust.id and z.archived_at is not null);
  if v_ulang then ada_ulang:=true; else ada_biasa:=true; end if;

  v_doc:=rc_private.next_document(v_abbr,v_code);$p$, 1, 'compile deteksi');
    src := pg_temp.ganti(src, $p$version_no,cashback_type_override,created_by,cashback_type_changed)$p$,
      $p$version_no,cashback_type_override,created_by,cashback_type_changed,batch_event_code,batch_event_at)$p$, 1, 'compile kolom');
    src := pg_temp.ganti(src, $p$rc_private.jenis_efektif(v_jenis)<>rc_private.jenis_efektif(v_camp.cashback_type));$p$,
      $p$rc_private.jenis_efektif(v_jenis)<>rc_private.jenis_efektif(v_camp.cashback_type),
    case when v_ulang then '6' else '0' end,case when v_ulang then now() end);$p$, 1, 'compile nilai');
    src := pg_temp.ganti(src, $p$  select id,actor,null,v_status,'compile_import',batch,'Compile cashback'$p$,
      $p$  select id,actor,null,v_status,'compile_import',case when v_ulang then rc_private.batch_kejadian(batch,'6') else batch end,
         case when v_ulang then 'Compile cashback (compile ulang, dokumen lama diarsipkan)' else 'Compile cashback' end$p$, 1, 'compile riwayat');
    src := pg_temp.ganti(src, $p$ insert into public.activity_logs(actor_id,event_type,details)
 values(actor,'compile_upload',$p$,
      $p$ v_batch_hasil:=coalesce(nullif(concat_ws(', ',case when ada_biasa then batch end,case when ada_ulang then rc_private.batch_kejadian(batch,'6') end),''),batch);
 insert into public.activity_logs(actor_id,event_type,details)
 values(actor,'compile_upload',$p$, 1, 'compile gabung');
    src := pg_temp.ganti(src, $p$'dibuat',dibuat,'batch',batch,$p$, $p$'dibuat',dibuat,'batch',v_batch_hasil,$p$, 2, 'compile hasil');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_amend_doc(jsonb,text)'::regprocedure), E'\r', '');
  if src !~ '20261163840000' then
    src := pg_temp.ganti(src, $p$batch_event_code = '1', batch_event_at = now() /* 20261163160000 */$p$,
      $p$batch_event_code = '7', batch_event_at = now(), /* 20261163840000: kepala 7 di stage saat ini dan seterusnya */
      batch_upload = case when c.status in ('submitted', 'approved') and batch_upload ~ '^[0-9]{2}.{13}$' then '7' || substr(batch_upload, 2) else batch_upload end,
      batch_release = case when c.status = 'released' and batch_release ~ '^[0-9]{2}.{13}$' then '7' || substr(batch_release, 2) else batch_release end,
      batch_claim = case when c.status = 'claimed' and batch_claim ~ '^[0-9]{2}.{13}$' then '7' || substr(batch_claim, 2) else batch_claim end,
      batch_clearing = case when c.status in ('done', 'expired') and batch_clearing ~ '^[0-9]{2}.{13}$' then '7' || substr(batch_clearing, 2) else batch_clearing end$p$, 1, 'amend');
    execute src;
  end if;
end $tambal$;

do $cek$ begin
  if pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure) !~ 'v_ulang' then raise exception 'GAGAL: compile'; end if;
  if pg_get_functiondef('public.rc_amend_doc(jsonb,text)'::regprocedure) !~ 'batch_event_code = ''7''' then raise exception 'GAGAL: amend'; end if;
end $cek$;
