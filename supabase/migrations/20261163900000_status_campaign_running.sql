-- ==========================================================================================
-- Status campaign: Inactive, Active, Running, Closed (tanpa Cleared) dan Batas Compile
-- ==========================================================================================
-- Pemilik, 11 November 2026:
--   "urutannya ubah, inactive berarti campaign tidak bisa di upload claim. active itu campaign yang
--    aktif, kalo closed itu campaign yang sudah selesai dan tidak bisa proses submit. tidak ada cleared."
--   "bagaimana jika campaign closed lalu ditolak di released? akan kembali ke not yet dan depot bisa
--    proses itu kembali."
--   "bagaimana jika campaign expired mau di amend statusnya atau change status? bisa jadi not yet dan
--    diproses kembali sementara compile tertutup sepenuhnya saat not yet."
--   "campaign akan dibukakan 1 bulan setelah campaign berakhir berdasarkan billing end kalo tidak ada
--    yang compile otomatis akan closed otomatis"
--   Jawaban atas pertanyaan sesudahnya:
--   "Aktif artinya bisa compile, lalu setelah itu Running artinya hanya bisa claim. jadi aktif akan
--    berubah 1 bulan setelah billing end jadi running jadi campaign dibuat by default aktif.
--    bagaimana yang baru buat masternya? maka tetep akan diberikan waktu 1 bulan dari tanggal di buat
--    meski billing end lewat tapi kalo di buat maks 1 minggu setelah berakhir maka tetep pake billing end."
--   "1 bulan jalan statusnya berubah jadi running, masa running ini gabole compile lagi untuk campaign
--    saat ini di overwrite dulu 1 bulan."
--   Inactive: "Claim Upload + compile" (dokumen yang sudah Submitted tetap berjalan sampai Done).
--
-- Aturan:
--   Active   bawaan saat dibuat. Compile dan klaim berjalan sampai Batas Compile.
--   Running  otomatis sehari sesudah Batas Compile. Compile ditutup; klaim tetap berjalan.
--   Inactive compile dan Claim Upload (Not Yet -> Submitted) ditutup; dokumen yang sudah Submitted
--            tetap berjalan sampai Done.
--   Closed   selesai. Not Yet menjadi Expired saat ditutup (20261163880000), compile ditutup, tidak
--            dapat dibuka kembali. Not Yet yang muncul sesudahnya (ditolak saat Release, atau Expired
--            yang dikembalikan lewat Amend Doc > Change Status) boleh diproses kembali.
--   Cleared  tidak ada lagi: ditolak di Campaign Master dan di constraint.
--
-- Batas Compile (campaigns.batas_compile, tanggal terakhir compile boleh):
--   billing end + 1 bulan; bila master dibuat LEBIH dari 1 minggu sesudah billing end (atau billing end
--   kosong): tanggal dibuat + 1 bulan. Billing End diubah -> dihitung ulang dengan tanggal hari itu.
--   Dapat ditimpa di formulir Campaign Master; dikosongkan = dihitung ulang. Campaign yang dibuka
--   kembali menjadi Active sesudah batasnya lewat mendapat 1 bulan dari hari itu.
--   Campaign yang sudah ada: dihitung seolah dibuat hari ini ("di overwrite dulu 1 bulan").
--
-- Pemindah otomatis (cron rc_campaign_batas, 00:05 WIB): campaign Active yang lewat Batas Compile
-- menjadi Running; yang sama sekali tidak punya dokumen (tidak ada yang compile) menjadi Closed.
-- Butuh 20261163880000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- Kolom, constraint, hitungan batas ------------------------------------------------------------
alter table public.campaigns add column if not exists batas_compile date;
comment on column public.campaigns.batas_compile is 'Tanggal terakhir compile boleh; sesudahnya campaign Active menjadi Running (20261163900000).';

update public.campaigns set status = 'closed' where status = 'cleared';
alter table public.campaigns drop constraint if exists campaigns_status_check;
alter table public.campaigns add constraint campaigns_status_check check (status in ('active', 'inactive', 'running', 'closed'));

create or replace function rc_private.batas_compile_hitung(p_billing_end date, p_dibuat date)
returns date language sql immutable set search_path to '' as $f$
  select case when p_billing_end is null or p_dibuat > p_billing_end + 7
              then (p_dibuat + interval '1 month')::date
              else (p_billing_end + interval '1 month')::date end;
$f$;

create or replace function rc_private.campaign_batas_compile()
returns trigger language plpgsql set search_path to '' as $f$
declare v_hari date := (now() at time zone 'Asia/Jakarta')::date;
begin
  if tg_op = 'INSERT' then
    if new.batas_compile is null then new.batas_compile := rc_private.batas_compile_hitung(new.billing_end, v_hari); end if;
    return new;
  end if;
  if new.batas_compile is null then
    new.batas_compile := rc_private.batas_compile_hitung(new.billing_end, v_hari);
  elsif new.batas_compile is not distinct from old.batas_compile and new.billing_end is distinct from old.billing_end then
    new.batas_compile := rc_private.batas_compile_hitung(new.billing_end, v_hari);
  end if;
  -- Dibuka kembali menjadi Active sesudah batasnya lewat: 1 bulan dari hari itu.
  if new.status = 'active' and old.status is distinct from 'active' and new.batas_compile < v_hari then
    new.batas_compile := (v_hari + interval '1 month')::date;
  end if;
  return new;
end $f$;
drop trigger if exists campaign_batas_compile on public.campaigns;
create trigger campaign_batas_compile before insert or update of billing_end, batas_compile, status on public.campaigns
  for each row execute function rc_private.campaign_batas_compile();

-- Campaign yang sudah ada: dihitung seolah dibuat hari ini.
update public.campaigns set batas_compile = rc_private.batas_compile_hitung(billing_end, (now() at time zone 'Asia/Jakarta')::date)
 where batas_compile is null;

-- ---- Penjaga dokumen ------------------------------------------------------------------------------
create or replace function rc_private.jaga_status_campaign()
returns trigger language plpgsql security definer set search_path to '' as $f$
declare st text; kode text;
begin
  select c.status, c.campaign_code into st, kode
    from public.campaigns c where c.id = new.campaign_id;
  if st is null then return new; end if;

  -- Dokumen baru (compile, Ad-Hoc) hanya untuk campaign Active.
  if tg_op = 'INSERT' then
    if st <> 'active' then
      raise exception 'Campaign % berstatus %; klaim baru tidak dapat dibuat', kode, initcap(st) using errcode = 'P0001';
    end if;
    return new;
  end if;

  -- 20261163900000: Inactive menutup Claim Upload (Not Yet -> Submitted). Dokumen yang sudah Submitted
  -- tetap berjalan sampai Done. Running dan Closed tidak menutupnya: Not Yet di campaign Closed hanya ada
  -- karena ditolak saat Release atau dikembalikan lewat Change Status, dan boleh diproses kembali.
  if st = 'inactive' and new.status = 'submitted' and old.status = 'not_yet' then
    raise exception 'Campaign % berstatus Inactive; Claim Upload ditutup', kode using errcode = 'P0001';
  end if;
  return new;
end $f$;

do $tambal$
declare src text; v_lama text := $p$  if v_camp.status in ('inactive','cleared','closed' /* 20261163880000 */) then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan','Campaign '||v_code||' berstatus '||v_camp.status||'; klaim baru tidak dapat dibuat'));$p$;
  v_baru text := $p$  -- 20261163900000: compile hanya untuk campaign Active yang Batas Compile-nya belum lewat.
  if v_camp.status <> 'active' or v_camp.batas_compile < (now() at time zone 'Asia/Jakarta')::date then
   ditolak:=ditolak||jsonb_build_array(jsonb_build_object('baris',baris,
     'alasan',case when v_camp.status = 'active'
       then 'Batas Compile campaign '||v_code||' sudah lewat ('||to_char(v_camp.batas_compile,'DD-Mon-YYYY')||'); campaign menjadi Running dan compile ditutup'
       when v_camp.status = 'running' then 'Campaign '||v_code||' berstatus Running (masa klaim); compile ditutup sejak '||to_char(v_camp.batas_compile + 1,'DD-Mon-YYYY')
       else 'Campaign '||v_code||' berstatus '||initcap(v_camp.status)||'; compile tidak dapat dilakukan' end));$p$;
begin
  -- ---- Compile dan pratinjaunya ------------------------------------------------------------------
  src := replace(pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163900000' then execute pg_temp.ganti(src, v_lama, v_baru, 1, 'compile'); end if;
  src := replace(pg_get_functiondef('public.rc_compile_preview(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163900000' then execute pg_temp.ganti(src, v_lama, v_baru, 1, 'preview'); end if;

  -- ---- Change Status: Expired campaign Closed boleh dikembalikan ke Not Yet ------------------------
  src := replace(pg_get_functiondef('rc_private.change_status_baris(text)'::regprocedure), E'\r', '');
  if src !~ '20261163900000' then
    src := pg_temp.ganti(src, $p$  if r.camp_status = 'closed' then
    return jsonb_build_object('noDoc', r.no_doc, 'galat', 'Campaign ' || r.campaign_code || ' sudah Closed; Expired-nya final'); end if;
$p$, $p$  -- 20261163900000: Expired campaign Closed pun boleh kembali ke Not Yet dan diproses kembali.
$p$, 1, 'change status');
    execute src;
  end if;

  -- ---- Campaign Master: status baru, tanpa Cleared, Batas Compile ---------------------------------
  src := replace(pg_get_functiondef('rc_private.campaign_upsert(jsonb)'::regprocedure), E'\r', '');
  if src !~ '20261163900000' then
    src := pg_temp.ganti(src, $p$ v_bi_at text; v_bi_bt text;$p$, $p$ v_bi_at text; v_bi_bt text; v_batas date; /* 20261163900000 */$p$, 1, 'upsert declare');
    src := pg_temp.ganti(src, $p$'variantZsq04Desc','variantZsodDesc','variantMcsiDesc' /* 20261163200000 */)$p$,
      $p$'variantZsq04Desc','variantZsodDesc','variantMcsiDesc' /* 20261163200000 */,'batasCompile' /* 20261163900000 */)$p$, 1, 'upsert kolom');
    src := pg_temp.ganti(src, $p$st not in('active','inactive','cleared','closed' /* 20261163880000 */) then
   raise exception 'Status campaign harus active, inactive, cleared atau closed pada %',code; end if;$p$,
      $p$st not in('active','inactive','running','closed' /* 20261163900000 */) then
   raise exception 'Status campaign harus Inactive, Active, Running atau Closed pada % (Cleared tidak dipakai lagi)',code; end if;
  v_batas := null;
  if r ? 'batasCompile' and btrim(r->>'batasCompile') <> '' then
   v_batas := rc_private.urai_tanggal_rc(btrim(r->>'batasCompile'));
   if v_batas is null then raise exception 'Batas Compile tidak terbaca pada %: %',code,r->>'batasCompile'; end if;
  end if;$p$, 1, 'upsert status');
    src := pg_temp.ganti(src, $p$    status=case when st <> '' then st else status end,$p$,
      $p$    status=case when st <> '' then st else status end,
    batas_compile=case when r ? 'batasCompile' then v_batas else batas_compile end, /* kosong = dihitung ulang */$p$, 1, 'upsert update');
    src := pg_temp.ganti(src, $p$variant_zsq04_desc,variant_zsod_desc,variant_mcsi_desc)$p$,
      $p$variant_zsq04_desc,variant_zsod_desc,variant_mcsi_desc,batas_compile)$p$, 1, 'upsert insert kolom');
    src := pg_temp.ganti(src, $p$     nullif(btrim(coalesce(r->>'variantMcsiDesc','')),''));$p$,
      $p$     nullif(btrim(coalesce(r->>'variantMcsiDesc','')),''),v_batas);$p$, 1, 'upsert insert nilai');
    execute src;
  end if;

  src := replace(pg_get_functiondef('public.rc_campaign_list(text,integer,integer)'::regprocedure), E'\r', '');
  if src !~ '20261163900000' then
    src := pg_temp.ganti(src, $p$   'status',ca.status,$p$,
      $p$   'status',ca.status,'batasCompile',rc_private.legacy_date(ca.batas_compile) /* 20261163900000 */,$p$, 1, 'list');
    execute src;
  end if;
end $tambal$;

-- ---- Pemindah otomatis ----------------------------------------------------------------------------
create or replace function rc_private.campaign_batas_jalan()
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_hari date := (now() at time zone 'Asia/Jakarta')::date; ca record; v_run text[] := '{}'; v_tutup text[] := '{}';
begin
  for ca in select c.id, c.campaign_code from public.campaigns c
             where c.status = 'active' and c.archived_at is null and c.batas_compile < v_hari order by c.campaign_code for update loop
    if exists(select 1 from public.claims k where k.campaign_id = ca.id and k.archived_at is null) then
      update public.campaigns set status = 'running' where id = ca.id;
      v_run := v_run || ca.campaign_code;
    else
      -- Tidak ada yang compile: Closed. Tanpa Not Yet, penutupan tidak menghanguskan apa pun dan tidak mengirim email.
      update public.campaigns set status = 'closed' where id = ca.id;
      v_tutup := v_tutup || ca.campaign_code;
    end if;
  end loop;
  if cardinality(v_run) + cardinality(v_tutup) > 0 then
    insert into public.activity_logs(actor_id, event_type, details, module, tab)
    values (null, 'campaign_status_otomatis', jsonb_build_object(
      'detail', 'Batas Compile lewat: ' || cardinality(v_run) || ' campaign menjadi Running, ' || cardinality(v_tutup) || ' campaign tanpa dokumen menjadi Closed',
      'running', to_jsonb(v_run), 'closed', to_jsonb(v_tutup)), 'keyMaster', 'campaign');
  end if;
  return jsonb_build_object('running', to_jsonb(v_run), 'closed', to_jsonb(v_tutup));
end $f$;
revoke all on function rc_private.campaign_batas_jalan() from public, anon, authenticated;

do $cron$
begin
  if exists(select 1 from cron.job where jobname = 'rc_campaign_batas') then perform cron.unschedule('rc_campaign_batas'); end if;
  perform cron.schedule('rc_campaign_batas', '5 17 * * *', $c$select rc_private.campaign_batas_jalan()$c$);
end $cron$;

-- ---- Pemeriksaan ----------------------------------------------------------------------------------
do $cek$
begin
  if exists(select 1 from public.campaigns where batas_compile is null) then raise exception 'GAGAL: batas_compile kosong'; end if;
  if pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure) !~ '20261163900000' then raise exception 'GAGAL: compile'; end if;
  if pg_get_functiondef('public.rc_compile_preview(jsonb)'::regprocedure) !~ '20261163900000' then raise exception 'GAGAL: preview'; end if;
  if pg_get_functiondef('rc_private.change_status_baris(text)'::regprocedure) ~ 'Expired-nya final' then raise exception 'GAGAL: change status'; end if;
  if pg_get_functiondef('rc_private.campaign_upsert(jsonb)'::regprocedure) !~ 'batasCompile' then raise exception 'GAGAL: upsert'; end if;
  if pg_get_functiondef('public.rc_campaign_list(text,integer,integer)'::regprocedure) !~ 'batasCompile' then raise exception 'GAGAL: list'; end if;
  if not exists(select 1 from cron.job where jobname = 'rc_campaign_batas') then raise exception 'GAGAL: cron'; end if;
end $cek$;
