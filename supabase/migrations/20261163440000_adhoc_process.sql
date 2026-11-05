-- ==========================================================================================
-- Jenis CB "Others" dan modul Ad-Hoc Process
-- ==========================================================================================
-- Pemilik, 22 Oktober 2026: "saya mau buat 1 jenis cb tambahan yakni others dan akan masuk di
-- modul 'Ad-Hoc Process'. workflownya semua yang admin masukan sebagai jenis claim sebagai others
-- di claim upload akan masuk kesini. Details modulnya sama seperti claim process, claim to
-- finance. hanya saja ada beberapa kolom yang harus diisi manual oleh user, seperti tax count
-- (jika iya harus di tick), jenis cb (harus masukin), proceed to claim process (jika di tick akan
-- masuk ke modul claim to finance, jika tidak langsung done), proceed to clearing (jika tick masuk
-- ke modul claim process, ke clearing) dan bisa dilakukan secara masal ... Kalo cb bisa masukan
-- copas. jika semua tidak di tick maka akan langsung done, dan remark special claims ... untuk
-- pajak mengikuti, jika normal mengikuti badan dan perorangan, jika rebate x 11% sesuai ppn."
-- Jawaban pemilik: masuk Ad-Hoc SETELAH approval (menggantikan Release); Rebate = CB x 1,11;
-- Tax Count tidak dicentang -> Gross Up = Net CB; keduanya dicentang -> Claim to Finance dulu.
--
-- ALUR
--   Claim Upload: Jenis CB "Others" -> Submit -> Management of Approval (bila aktif) -> status
--   Approved dengan claims.jalur_adhoc = true -> antrean Ad-Hoc Process (bukan Release, bukan
--   Bulk Process). Di sana per dokumen (massal): Jenis CB wajib (Transfer, CN, Voucher, Rebate,
--   Rebate Manual), Net CB boleh diganti, Tax Count, Proceed to Claim Process, Proceed to Clearing.
--     Proceed to Claim dicentang (dengan/tanpa Clearing) -> Released  (Claim to Finance)
--     hanya Proceed to Clearing                          -> Claimed   (Clearing)
--     keduanya tidak                                     -> Done, remark "Special Claims"
--   Gross Up (rc_private.gross_up_adhoc): Tax Count tidak -> = Net CB; Tax Count + Rebate /
--   Rebate Manual -> Net CB x 1,11; Tax Count + jenis lain -> Badan / Perorangan.
--   Dokumen jalur Ad-Hoc yang Jenis CB-nya Rebate tetap lewat Claim Process (bukan Bulk Process).
--
-- Izin modul baru adhoc_process, tab adhoc.list (bawaan tercentang bagi pemegang izin, seperti
-- Claim Process). Belum diberikan ke siapa pun selain yang perannya mendapat seluruh izin.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Kolom ------------------------------------------------------------------------------
alter table public.claims
  add column if not exists jalur_adhoc boolean not null default false,
  add column if not exists adhoc_at timestamptz,
  add column if not exists adhoc_by uuid,
  add column if not exists adhoc_pajak boolean,
  add column if not exists adhoc_lanjut text;
do $c$ begin
  if not exists(select 1 from pg_constraint where conname = 'claims_adhoc_lanjut_check') then
    alter table public.claims add constraint claims_adhoc_lanjut_check check (adhoc_lanjut in ('claim', 'clearing', 'done'));
  end if;
end $c$;
comment on column public.claims.jalur_adhoc is 'Diajukan berjenis Others: setelah approval masuk Ad-Hoc Process (20261163440000).';
comment on column public.claims.adhoc_lanjut is 'Hasil Ad-Hoc Process: claim (Claim to Finance), clearing, atau done (Special Claims).';

-- ---- 2. Jenis CB Others dan rumus ----------------------------------------------------------
create or replace function rc_private.cb_label(p_jenis text)
 returns text
 language sql
 immutable
as $function$
 -- 20261163100000: Voucher. 20261163440000: Others.
 select case rc_private.jenis_efektif(p_jenis) when 'rebate manual' then 'Rebate Manual' when 'rebate' then 'Rebate'
 when 'transfer' then 'Transfer' when 'cn' then 'CN' when 'voucher' then 'Voucher' when 'others' then 'Others' else coalesce(p_jenis,'') end;
$function$;

create or replace function rc_private.gross_up_adhoc(p_net numeric, p_subyek text, p_jenis text, p_pajak boolean)
 returns numeric
 language sql
 immutable
 set search_path = ''
as $function$
  -- Tax Count tidak dicentang: Gross Up = Net CB. Dicentang: Rebate / Rebate Manual x 1,11
  -- (PPN 11%), selain itu Badan / Perorangan apa pun Status Pajak campaign-nya - pengguna
  -- sendiri yang memutuskan dokumen ini kena pajak.
  select case when coalesce(p_net, 0) <= 0 then 0
              when not coalesce(p_pajak, false) then trunc(p_net)
              when rc_private.jenis_efektif(p_jenis) in ('rebate', 'rebate manual') then trunc(p_net * 1.11)
              else rc_private.gross_claimed(p_net, p_subyek, null) end;
$function$;
revoke all on function rc_private.gross_up_adhoc(numeric, text, text, boolean) from public, anon;
grant execute on function rc_private.gross_up_adhoc(numeric, text, text, boolean) to authenticated;

-- Remark "Special Claims": dokumen Ad-Hoc yang langsung Done.
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamp with time zone, p_ada_reprocess boolean, p_cb_berubah boolean,
  p_amended_at timestamp with time zone, p_amend_dari text[], p_rek_diubah boolean, p_special boolean)
 returns text
 language sql
 stable
 set search_path = ''
as $function$
  select nullif(concat_ws(', ', nullif(rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, p_amended_at, p_amend_dari, p_rek_diubah), ''),
                          case when coalesce(p_special, false) then 'Special Claims' end), '');
$function$;
grant execute on function rc_private.claim_remark_dari(timestamptz, boolean, boolean, timestamptz, text[], boolean, boolean) to authenticated;

create or replace function rc_private.claim_remark(c public.claims)
 returns text
 language sql
 stable
 set search_path to ''
as $function$
  select rc_private.claim_remark_dari(c.reprocessed_at,
    exists(select 1 from public.claim_status_history h where h.claim_id = c.id and h.action like '%reprocess%'),
    c.cashback_type_changed, c.amended_at,
    array(select rc_private.legacy_status(h.from_status) from public.claim_status_history h
           where h.claim_id = c.id and h.action = 'amend' order by h.id) /* 20261163150000 */,
    coalesce((select s.rekening_diubah from rc_private.claim_sensitive s where s.claim_id = c.id), false) /* 20261163400000 */,
    c.adhoc_lanjut = 'done' /* 20261163440000 */);
$function$;

-- ---- 3. Tambalan fungsi yang ada -----------------------------------------------------------
do $tambal$
declare src text; f text;
begin
  -- 3a. Pengajuan dan proses klaim.
  f := 'rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163440000' then
    src := pg_temp.ganti(src, $p$if v_jenis_input not in('Transfer','CN','Rebate','RA07','RA7','Rebate Manual','Voucher') then$p$,
      $p$if v_jenis_input not in('Transfer','CN','Rebate','RA07','RA7','Rebate Manual','Voucher','Others' /* 20261163440000 */) then$p$, 1, f || ' daftar jenis');
    src := pg_temp.ganti(src, $p$Tulis persis Transfer, CN, Voucher, Rebate atau Rebate Manual',$p$,
      $p$Tulis persis Transfer, CN, Voucher, Rebate, Rebate Manual atau Others',$p$, 1, f || ' pesan jenis');
    src := pg_temp.ganti(src, $p$    and jenis='rebate' then
  raise exception 'Dokumen % berjenis Rebate dan hanya dapat diproses lewat Bulk Process',c.no_doc;
 end if;$p$,
      $p$    and jenis='rebate' and not c.jalur_adhoc /* 20261163440000: Rebate pilihan Ad-Hoc lewat Claim Process */ then
  raise exception 'Dokumen % berjenis Rebate dan hanya dapat diproses lewat Bulk Process',c.no_doc;
 end if;
 -- 20261163440000: Others diproses di Ad-Hoc Process, bukan Release maupun Bulk Process.
 if p_action in('release','bulk_rebate','reject_bulk') and (c.jalur_adhoc or jenis='others') then
  raise exception 'Dokumen % berjalur Ad-Hoc Process (diajukan berjenis Others); tidak diproses lewat Release maupun Bulk Process',c.no_doc;
 end if;$p$, 1, f || ' penjaga jalur');
    -- Pola tanpa penanda 20261163170000 supaya sama di dev dan prod (170000 belum di prod).
    src := pg_temp.ganti(src, $p$update public.claims set tax_subject=subject,gross_up=v_gross,$p$,
      $p$update public.claims set tax_subject=subject,gross_up=v_gross,
    jalur_adhoc=(jenis='others'),adhoc_at=null,adhoc_by=null,adhoc_pajak=null,adhoc_lanjut=null /* 20261163440000 */,$p$, 1, f || ' submit jalur');
    execute src;
  end if;

  -- 3b. Antrean: Others keluar dari Release, masuk adhocData; Rebate jalur Ad-Hoc tidak ke Bulk.
  f := 'public.rc_legacy_workflow(integer,timestamp with time zone,uuid)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163440000' then
    src := pg_temp.ganti(src, $p$'rebate',lower(btrim(rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))))='rebate') as x$p$,
      $p$'rebate',lower(btrim(rc_private.cb_label(coalesce(nullif(c.cashback_type_override,''),ca.cashback_type))))='rebate' and not c.jalur_adhoc /* 20261163440000 */)
   -- 20261163440000: objek kedua, karena jsonb_build_object dibatasi 100 argumen.
   || jsonb_build_object('adhoc',c.jalur_adhoc,'adhocPajak',c.adhoc_pajak,'adhocLanjut',coalesce(c.adhoc_lanjut,''),'tglAdhoc',rc_private.legacy_ts(c.adhoc_at)) as x$p$, 1, f || ' bendera');
    src := pg_temp.ganti(src, $p$coalesce(s.rekening_diubah, false) /* 20261163400000 */)$p$,
      $p$coalesce(s.rekening_diubah, false) /* 20261163400000 */, c.adhoc_lanjut = 'done' /* 20261163440000 */)$p$, 1, f || ' remark');
    src := pg_temp.ganti(src, $p$where rc_private.can_tab('release.list') and v->>'status'='Approved' and not (v->>'rebate')::boolean),$p$,
      $p$where rc_private.can_tab('release.list') and v->>'status'='Approved' and not (v->>'rebate')::boolean and not (v->>'adhoc')::boolean),$p$, 1, f || ' release');
    src := pg_temp.ganti(src, $p$v->>'status' <> 'Submitted'));$p$,
      $p$v->>'status' <> 'Submitted'),
  -- 20261163440000: Others sesudah approval.
  'adhocData',(select coalesce(jsonb_agg(v),'[]'::jsonb) from jsonb_array_elements(rows_json) v
    where rc_private.can_tab('adhoc.list') and v->>'status'='Approved' and (v->>'adhoc')::boolean));$p$, 1, f || ' adhocData');
    execute src;
  end if;

  -- 3c. Remark di Analytics.
  f := 'public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163440000' then
    src := pg_temp.ganti(src, $p$coalesce(rk.rekening_diubah, false) /* 20261163400000 */)$p$,
      $p$coalesce(rk.rekening_diubah, false) /* 20261163400000 */, c.adhoc_lanjut = 'done' /* 20261163440000 */)$p$, 1, f || ' remark');
    execute src;
  end if;

  -- 3d. Amend Doc dokumen yang sudah diproses Ad-Hoc memakai aturan Tax Count-nya.
  f := 'public.rc_amend_doc(jsonb,text)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163440000' then
    src := pg_temp.ganti(src, $p$v_gross := case when v_subjek is not null then rc_private.gross_up_klaim(v_baru, v_subjek, v_pajak, v_jenis) end;$p$,
      $p$v_gross := case when c.adhoc_at is not null then rc_private.gross_up_adhoc(v_baru, v_subjek, v_jenis, c.adhoc_pajak) /* 20261163440000 */
                       when v_subjek is not null then rc_private.gross_up_klaim(v_baru, v_subjek, v_pajak, v_jenis) end;$p$, 1, f || ' gross');
    execute src;
  end if;

  -- 3e. Report / Cost Center / Dashboard: Gross Up dokumen Ad-Hoc adalah yang diputuskan di sana.
  src := pg_get_viewdef('public.rc_report_rows'::regclass, true);
  if src !~ 'adhoc_at' then
    src := pg_temp.ganti(src,
      $p$rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status, COALESCE(NULLIF(c.cashback_type_override, ''::text), ca.cashback_type)) AS gross_claimed$p$,
      $p$CASE WHEN c.adhoc_at IS NOT NULL THEN c.gross_up ELSE rc_private.gross_up_klaim(c.cb_net, c.tax_subject, ca.tax_status, COALESCE(NULLIF(c.cashback_type_override, ''::text), ca.cashback_type)) END AS gross_claimed$p$,
      1, 'rc_report_rows gross');
    execute 'create or replace view public.rc_report_rows as ' || src;
  end if;

  -- 3f. Kunci izin modul baru; tanpa ini adhoc_process tercabut setiap akun disimpan.
  f := 'public.rc_update_access(jsonb)';
  src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
  if src !~ '20261163440000' then
    src := pg_temp.ganti(src, $p$('report','view_report'),$p$,
      $p$('report','view_report'),('adhoc','adhoc_process') /* 20261163440000 */,$p$, 1, f || ' peta izin');
    execute src;
  end if;
end $tambal$;

-- ---- 4. Izin dan tab -----------------------------------------------------------------------
insert into public.permissions(code, description)
values ('adhoc_process', 'Ad-Hoc Process: memproses klaim Jenis CB Others (Jenis CB, Net CB, Tax Count, lanjut Claim / Clearing / Done)')
on conflict (code) do update set description = excluded.description;

insert into rc_private.tab_catalog(code, module, label, permission, key, tab, title)
values ('adhoc.list', 'adhoc', 'Ad-Hoc Process', 'adhoc_process', 'adhoc', 'list', 'Ad-Hoc Process')
on conflict (code) do update set module = excluded.module, label = excluded.label, permission = excluded.permission,
  key = excluded.key, tab = excluded.tab, title = excluded.title;

-- ---- 5. Proses Ad-Hoc ----------------------------------------------------------------------
-- p_items: [{no_doc, version_no, jenis_cb, cb_net (kosong = tetap), pajak, lanjut_claim, lanjut_clearing}]
create or replace function public.rc_adhoc_proses(p_items jsonb, p_request_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare actor uuid := auth.uid(); cached rc_private.requests%rowtype; v_payload jsonb;
  item jsonb; c public.claims%rowtype; camp public.campaigns%rowtype; s rc_private.claim_sensitive%rowtype; cust public.customers%rowtype;
  stamp timestamptz := now(); v_batch text; v_batch_dok text; v_batches text[] := '{}';
  v_jenis_in text; v_jenis text; v_label text; v_cb numeric; v_cb_teks text; v_pajak boolean; v_claim boolean; v_clr boolean;
  v_target text; v_gross numeric; v_alasan text; v_norek text; v_namarek text; v_bank text; v_tahap int;
  processed jsonb := '[]'; v_dok jsonb := '[]'; v_done uuid[] := '{}'; n_claim int := 0; n_clr int := 0; n_done int := 0; v_depot uuid;
begin
  if not rc_private.can_access(null, 'adhoc_process') then raise exception 'Access denied' using errcode = '42501'; end if;
  perform rc_private.require_tab('adhoc.list');
  if p_request_id is null or p_items is null or jsonb_typeof(p_items) <> 'array' then raise exception 'Invalid request'; end if;
  if jsonb_array_length(p_items) not between 1 and 500 then raise exception 'Satu proses maksimal 500 dokumen'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) x
             where jsonb_typeof(x) <> 'object' or btrim(coalesce(x->>'no_doc', '')) = '' or coalesce(x->>'version_no', '') !~ '^[1-9][0-9]{0,17}$')
     or (select count(distinct upper(btrim(x->>'no_doc'))) from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'Setiap dokumen wajib punya No Doc unik dan versi'; end if;

  v_payload := jsonb_build_object('action', 'adhoc', 'items', p_items);
  insert into rc_private.requests(actor_id, request_id, payload) values (actor, p_request_id, v_payload) on conflict do nothing;
  select * into strict cached from rc_private.requests where actor_id = actor and request_id = p_request_id for update;
  if cached.payload <> v_payload then raise exception 'Request ID reused for different payload'; end if;
  if cached.result is not null then return cached.result; end if;

  -- Satu nomor batch per proses (tahap 02, seperti Bulk Process); digit pertama = kejadian dokumen.
  v_batch := rc_private.next_batch('02');

  for item in select value from jsonb_array_elements(p_items) order by value->>'no_doc' loop
    select * into c from public.claims where no_doc = btrim(item->>'no_doc') for update;
    if not found then raise exception 'Dokumen % tidak ditemukan', item->>'no_doc'; end if;
    if c.archived_at is not null then raise exception 'Dokumen % sudah diarsipkan', c.no_doc; end if;
    if not rc_private.can_access(c.depot_id, 'adhoc_process') then raise exception 'Depot access denied' using errcode = '42501'; end if;
    if c.version_no <> (item->>'version_no')::bigint then
      raise exception 'Dokumen % berubah sejak dimuat; segarkan data lalu ulangi', c.no_doc using errcode = '40001'; end if;
    if c.pending_approval is not null then raise exception 'Dokumen % masih menunggu approval', c.no_doc; end if;
    select * into camp from public.campaigns where id = c.campaign_id;
    if c.status <> 'approved' or not (c.jalur_adhoc or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), camp.cashback_type)) = 'others') then
      raise exception 'Dokumen % tidak ada di antrean Ad-Hoc Process (status %)', c.no_doc, rc_private.legacy_status(c.status); end if;
    if c.customer_id is null then raise exception 'Dokumen %: Customer Master belum ada; lengkapi dulu di Key Master', c.no_doc; end if;

    v_jenis_in := btrim(coalesce(item->>'jenis_cb', ''));
    if v_jenis_in = '' then raise exception 'Dokumen %: Jenis CB wajib diisi', c.no_doc; end if;
    v_jenis := rc_private.jenis_efektif(v_jenis_in);
    if v_jenis not in ('transfer', 'cn', 'voucher', 'rebate', 'rebate manual') then
      raise exception 'Dokumen %: Jenis CB "%" tidak dikenali. Tulis persis Transfer, CN, Voucher, Rebate atau Rebate Manual', c.no_doc, v_jenis_in; end if;
    v_label := rc_private.cb_label(v_jenis);

    -- Net CB: kosong berarti tetap; desimal dipotong ke rupiah bulat.
    v_cb_teks := btrim(coalesce(item->>'cb_net', ''));
    if v_cb_teks = '' then v_cb := c.cb_net;
    else
      begin v_cb := v_cb_teks::numeric;
      exception when others then raise exception 'Dokumen %: Net CB "%" bukan angka', c.no_doc, v_cb_teks; end;
      if v_cb < 0 then raise exception 'Dokumen %: Net CB tidak boleh negatif', c.no_doc; end if;
      v_cb := trunc(v_cb);
    end if;

    begin
      v_pajak := coalesce((item->>'pajak')::boolean, false);
      v_claim := coalesce((item->>'lanjut_claim')::boolean, false);
      v_clr := coalesce((item->>'lanjut_clearing')::boolean, false);
    exception when others then raise exception 'Dokumen %: isian centang tidak valid', c.no_doc; end;
    v_target := case when v_claim then 'released' when v_clr then 'claimed' else 'done' end;
    v_tahap := case v_target when 'released' then 1 when 'claimed' then 2 else 3 end;

    -- Transfer memerlukan rekening, sama dengan aturan pengajuan. Rekening saat diajukan dipakai;
    -- bila waktu itu kosong (Others tidak menuntutnya), diambil dari Customer Master sekarang.
    if v_jenis = 'transfer' then
      select * into s from rc_private.claim_sensitive where claim_id = c.id;
      select * into cust from public.customers where id = c.customer_id;
      v_norek   := coalesce(nullif(btrim(coalesce(s.account_number, '')), ''), nullif(btrim(coalesce(cust.account_number, '')), ''));
      v_namarek := coalesce(nullif(btrim(coalesce(s.account_name, '')), ''), nullif(btrim(coalesce(cust.account_name, '')), ''));
      v_bank    := coalesce(nullif(btrim(coalesce(s.bank, '')), ''), nullif(btrim(coalesce(cust.bank, '')), ''));
      if v_norek is null or v_namarek is null or v_bank is null then
        raise exception 'Dokumen %: Jenis CB Transfer memerlukan Nomor Rekening, Nama Rekening dan Bank. Lengkapi di Customer Master lalu ulangi', c.no_doc; end if;
      insert into rc_private.claim_sensitive(claim_id) values (c.id) on conflict do nothing;
      update rc_private.claim_sensitive set account_number = v_norek, account_name = v_namarek, bank = v_bank where claim_id = c.id;
    end if;

    v_gross := rc_private.gross_up_adhoc(v_cb, c.tax_subject, v_jenis, v_pajak);
    v_batch_dok := rc_private.batch_kejadian(v_batch, coalesce(c.batch_event_code, '0'));
    if not (v_batch_dok = any(v_batches)) then v_batches := v_batches || v_batch_dok; end if;
    v_alasan := left('Ad-Hoc Process: Jenis CB ' || v_label || ', Tax Count ' || case when v_pajak then 'Ya' else 'Tidak' end
      || case when v_cb is distinct from c.cb_net then ', Net CB ' || rc_private.rupiah(c.cb_net) || ' -> ' || rc_private.rupiah(v_cb) else '' end
      || case v_target when 'released' then ', lanjut Claim to Finance' when 'claimed' then ', lanjut Clearing' else ', langsung Done (Special Claims)' end, 300);

    update public.claims set status = v_target, cashback_type_override = v_label, cb_net = v_cb, gross_up = v_gross,
      jalur_adhoc = true, adhoc_at = stamp, adhoc_by = actor, adhoc_pajak = v_pajak,
      adhoc_lanjut = case v_target when 'released' then 'claim' when 'claimed' then 'clearing' else 'done' end,
      released_at = stamp, released_by = actor, batch_release = v_batch_dok,
      claimed_at = case when v_tahap >= 2 then stamp end, claimed_by = case when v_tahap >= 2 then actor end,
      batch_claim = case when v_tahap >= 2 then v_batch_dok end,
      cleared_at = case when v_tahap = 3 then stamp end, cleared_by = case when v_tahap = 3 then actor end,
      batch_clearing = case when v_tahap = 3 then v_batch_dok end,
      version_no = version_no + 1, updated_at = stamp
    where id = c.id;
    -- Riwayat memakai nama tahap yang biasa supaya Process by (Release / Claim / Clearing) terisi.
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, batch, reason)
    select c.id, actor, x.dari, x.ke, x.aksi, v_batch_dok, v_alasan
      from (values (1, 'approved', 'released', 'release'), (2, 'released', 'claimed', 'claim'), (3, 'claimed', 'done', 'clearing')) x(urut, dari, ke, aksi)
     where x.urut <= v_tahap order by x.urut;

    if v_tahap = 1 then n_claim := n_claim + 1; elsif v_tahap = 2 then n_clr := n_clr + 1; else n_done := n_done + 1; v_done := v_done || c.id; end if;
    processed := processed || jsonb_build_array(jsonb_build_object('no_doc', c.no_doc, 'status', v_target, 'version_no', c.version_no + 1,
      'batch', v_batch_dok, 'gross_up', v_gross, 'cb_net', v_cb, 'jenis_cb', v_label, 'pajak', v_pajak));
    v_dok := v_dok || jsonb_build_object('noDoc', c.no_doc, 'depotId', c.depot_id, 'jenisCb', v_label, 'taxCount', v_pajak,
      'cbNetLama', c.cb_net, 'cbNet', v_cb, 'grossUp', v_gross, 'hasil', v_target);
  end loop;

  v_batch := (select string_agg(x, ', ' order by x) from unnest(v_batches) x);
  select case when count(distinct x->>'depotId') = 1 then min(x->>'depotId')::uuid end into v_depot from jsonb_array_elements(v_dok) x;
  insert into public.activity_logs(actor_id, depot_id, event_type, details, batch_no, module, tab, process_stage)
  values (actor, v_depot, 'adhoc_process', jsonb_build_object(
    'detail', 'Ad-Hoc Process: ' || jsonb_array_length(v_dok) || ' dokumen (' || n_claim || ' ke Claim to Finance, '
              || n_clr || ' ke Clearing, ' || n_done || ' langsung Done)',
    'jumlah', jsonb_array_length(v_dok), 'dokumen', v_dok), v_batch, 'adhoc', 'list', 'adhoc');

  -- Dokumen yang langsung Done memperoleh email Done seperti Clearing.
  if coalesce(array_length(v_done, 1), 0) > 0 then
    begin
      perform rc_private.email_pengajuan_antre('clearing', v_batch, v_done, actor, '');
    exception when others then
      insert into public.activity_logs(actor_id, event_type, details)
      values (actor, 'email_pengajuan_gagal', jsonb_build_object('aksi', 'adhoc', 'batch', v_batch, 'sebab', left(sqlerrm, 300)));
    end;
  end if;

  v_payload := jsonb_build_object('processed', processed, 'batch', v_batch, 'count', jsonb_array_length(processed),
    'keClaim', n_claim, 'keClearing', n_clr, 'done', n_done);
  update rc_private.requests set result = v_payload where actor_id = actor and request_id = p_request_id;
  return v_payload;
end $function$;

-- Tolak dari Ad-Hoc Process: kembali ke depot (Not Yet) berjenis Others, seperti Reject di Release.
create or replace function public.rc_adhoc_tolak(p_items jsonb, p_request_id uuid, p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare actor uuid := auth.uid(); cached rc_private.requests%rowtype; v_payload jsonb;
  item jsonb; c public.claims%rowtype; camp public.campaigns%rowtype; stamp timestamptz := now();
  v_alasan text := left(btrim(coalesce(p_reason, '')), 1000); processed jsonb := '[]'; v_dok jsonb := '[]'; v_depot uuid;
begin
  if not rc_private.can_access(null, 'adhoc_process') then raise exception 'Access denied' using errcode = '42501'; end if;
  perform rc_private.require_tab('adhoc.list');
  if p_request_id is null or p_items is null or jsonb_typeof(p_items) <> 'array' then raise exception 'Invalid request'; end if;
  if jsonb_array_length(p_items) not between 1 and 500 then raise exception 'Satu proses maksimal 500 dokumen'; end if;
  if v_alasan = '' then raise exception 'Reason required'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) x
             where jsonb_typeof(x) <> 'object' or btrim(coalesce(x->>'no_doc', '')) = '' or coalesce(x->>'version_no', '') !~ '^[1-9][0-9]{0,17}$')
     or (select count(distinct upper(btrim(x->>'no_doc'))) from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'Setiap dokumen wajib punya No Doc unik dan versi'; end if;

  v_payload := jsonb_build_object('action', 'adhoc_tolak', 'items', p_items, 'reason', v_alasan);
  insert into rc_private.requests(actor_id, request_id, payload) values (actor, p_request_id, v_payload) on conflict do nothing;
  select * into strict cached from rc_private.requests where actor_id = actor and request_id = p_request_id for update;
  if cached.payload <> v_payload then raise exception 'Request ID reused for different payload'; end if;
  if cached.result is not null then return cached.result; end if;

  for item in select value from jsonb_array_elements(p_items) order by value->>'no_doc' loop
    select * into c from public.claims where no_doc = btrim(item->>'no_doc') for update;
    if not found then raise exception 'Dokumen % tidak ditemukan', item->>'no_doc'; end if;
    if c.archived_at is not null then raise exception 'Dokumen % sudah diarsipkan', c.no_doc; end if;
    if not rc_private.can_access(c.depot_id, 'adhoc_process') then raise exception 'Depot access denied' using errcode = '42501'; end if;
    if c.version_no <> (item->>'version_no')::bigint then
      raise exception 'Dokumen % berubah sejak dimuat; segarkan data lalu ulangi', c.no_doc using errcode = '40001'; end if;
    select * into camp from public.campaigns where id = c.campaign_id;
    if c.status <> 'approved' or c.pending_approval is not null
       or not (c.jalur_adhoc or rc_private.jenis_efektif(coalesce(nullif(c.cashback_type_override, ''), camp.cashback_type)) = 'others') then
      raise exception 'Dokumen % tidak ada di antrean Ad-Hoc Process (status %)', c.no_doc, rc_private.legacy_status(c.status); end if;

    -- Kembali berjenis Others (pilihan Ad-Hoc sebelumnya, bila ada, dibatalkan) dengan gross up
    -- aturan biasa sampai diajukan ulang.
    update public.claims set status = 'not_yet', cashback_type_override = 'Others',
      gross_up = rc_private.gross_up_klaim(c.cb_net, c.tax_subject, camp.tax_status, 'Others'),
      adhoc_at = null, adhoc_by = null, adhoc_pajak = null, adhoc_lanjut = null,
      uploaded_at = null, submitted_by = null, approved_at = null, approved_by = null, batch_upload = null,
      version_no = version_no + 1, updated_at = stamp
    where id = c.id;
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, batch, reason)
    values (c.id, actor, c.status, 'not_yet', 'reject_adhoc', null, v_alasan);
    processed := processed || jsonb_build_array(jsonb_build_object('no_doc', c.no_doc, 'status', 'not_yet', 'version_no', c.version_no + 1));
    v_dok := v_dok || jsonb_build_object('noDoc', c.no_doc, 'depotId', c.depot_id);
  end loop;

  select case when count(distinct x->>'depotId') = 1 then min(x->>'depotId')::uuid end into v_depot from jsonb_array_elements(v_dok) x;
  insert into public.activity_logs(actor_id, depot_id, event_type, details, module, tab, process_stage)
  values (actor, v_depot, 'adhoc_reject', jsonb_build_object('detail', 'Ad-Hoc Process: ' || jsonb_array_length(v_dok)
    || ' dokumen dikembalikan ke depot. Alasan: ' || v_alasan, 'jumlah', jsonb_array_length(v_dok), 'dokumen', v_dok, 'alasan', v_alasan),
    'adhoc', 'list', 'adhoc');

  v_payload := jsonb_build_object('processed', processed, 'count', jsonb_array_length(processed));
  update rc_private.requests set result = v_payload where actor_id = actor and request_id = p_request_id;
  return v_payload;
end $function$;

revoke all on function public.rc_adhoc_proses(jsonb, uuid), public.rc_adhoc_tolak(jsonb, uuid, text) from public, anon;
grant execute on function public.rc_adhoc_proses(jsonb, uuid), public.rc_adhoc_tolak(jsonb, uuid, text) to authenticated;
