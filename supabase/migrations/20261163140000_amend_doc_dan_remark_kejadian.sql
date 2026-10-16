-- ==========================================================================================
-- Document Center > Amend Doc, dan Remark Analytics untuk kejadian khusus
-- ==========================================================================================
-- Pemilik, 16 Oktober 2026:
--   "buat di dev dan testing tab "Amend Doc" di Document Center dengan ketentuan:
--    1. Tab ini muncul ketika izin di tick pada access management
--    2. Tab ini hanya cukup mengisi no doc dan net cb terbaru.
--    3. ketika di proses maka akan muncul di remark pada analytics, "Doc Ammendement", tambahan
--       jika reprocessing akan muncul di analytic remarknya "Document Reprocessed"
--    jadi kolom remark untuk semua kejadian khusus."
--
-- 1. TAB compilation.amend (Document Center > Amend Doc). Bawaannya MATI untuk semua kecuali
--    System Manager; menyala hanya bila dicentang di Edit Akses (sama dengan access.approval).
--
-- 2. AMEND: No Doc + Net CB baru. Status dokumen tidak berubah. Desimal dipotong (aturan
--    Document Center 20261162210000). Gross up dihitung ulang dengan aturan yang sama dengan
--    Reprocessing (gross_up_klaim, Subyek Pajak dokumen, Status Pajak campaign, Jenis CB efektif).
--    Ditolak bila: dokumen tidak ada/terarsip, di luar yurisdiksi, Customer Master belum ada,
--    sedang menunggu keputusan approval, nilai sama, negatif, atau dokumen berubah sejak dicek.
--    Jejak: claims.amended_at/amended_by, riwayat status 'amend' (status tetap), activity log
--    'amend_doc' berisi nilai lama dan baru.
--
-- 3. REMARK (kolom "untuk semua kejadian khusus"): satu sumber, rc_private.claim_remark_dari,
--    dipakai Analytics, Claim Process dan detail dokumen. Isinya kini:
--      Doc Amendment         dokumen pernah di-Amend
--      Document Reprocessed  dokumen pernah diproses ulang lewat Reprocessing Doc (dulu "Reprocessing")
--      CB Type Changed       Jenis CB dokumen berbeda dari campaign (tetap)
--
-- Ditambal dengan penjaga MD5 pra-citra (dev dan prod sama, 16 Oktober 2026). Aman diulang.
-- ==========================================================================================

alter table public.claims add column if not exists amended_at timestamptz;
alter table public.claims add column if not exists amended_by uuid;
comment on column public.claims.amended_at is 'Terakhir di-Amend lewat Document Center > Amend Doc (20261163140000).';

insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select 'compilation.amend', 'compilation', 'amend', 'view_compilation', 'Amend Doc', t.label, t.key
  from rc_private.tab_catalog t where t.code = 'compilation.list'
on conflict do nothing;

-- ------------------------------------------------------------------------------------------
-- Remark: satu sumber untuk semua kejadian khusus
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean,
  p_cb_berubah boolean, p_amended_at timestamptz)
returns text language sql stable as $fn$
  select concat_ws(', ',
    case when p_amended_at is not null then 'Doc Amendment' end,
    case when p_reprocessed_at is not null or p_ada_reprocess then 'Document Reprocessed' end,
    case when p_cb_berubah then 'CB Type Changed' end);
$fn$;
-- Bentuk lama (3 argumen) tetap ada untuk pemanggil lain; labelnya ikut yang baru.
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean)
returns text language sql stable as $fn$
  select rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, null::timestamptz);
$fn$;
create or replace function rc_private.claim_remark(c public.claims)
returns text language sql stable set search_path to '' as $fn$
  select rc_private.claim_remark_dari(c.reprocessed_at,
    exists(select 1 from public.claim_status_history h
            where h.claim_id = c.id and h.action like '%reprocess%'),
    c.cashback_type_changed, c.amended_at /* 20261163140000 */);
$fn$;

do $tambal$
declare r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti) values
  ('rc_private.tab_rights(uuid)', 'b7c3332433a360645b56d27ce9ef80c6',
   $p$or t.code='access.approval' /* 20261162180000: hanya bila dicentang */)$p$,
   $p$or t.code='access.approval' /* 20261162180000: hanya bila dicentang */ or t.code='compilation.amend' /* 20261163140000: hanya bila dicentang */)$p$),
  ('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)', '955c3a0c47b4b69f3bf22c6cfbb71d29',
   $p$rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed)$p$,
   $p$rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed, c.amended_at /* 20261163140000 */)$p$),
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '540bd12688f0512e4f8066411f3277b1',
   $p$rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed)$p$,
   $p$rc_private.claim_remark_dari(c.reprocessed_at, pel.ada_reprocess, c.cashback_type_changed, c.amended_at /* 20261163140000 */)$p$);

  for r in select * from _tambal order by urut loop
    src := pg_get_functiondef(r.sig::regprocedure);
    if src ~ '20261163140000' then raise notice '% sudah ditambal.', r.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> r.harapan then
      raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', r.sig, md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
    n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
    if n <> 1 then raise exception '%: pola ditemukan % kali, diharapkan 1.', r.sig, n; end if;
    execute replace(baru, r.lama, r.ganti);
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- RPC Amend Doc
-- ------------------------------------------------------------------------------------------
-- Pratinjau satu dokumen sebelum di-Amend.
create or replace function public.rc_amend_cek(p_no_doc text)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare c public.claims%rowtype; d public.depots%rowtype; cu public.customers%rowtype; ca public.campaigns%rowtype;
  v_doc text := upper(btrim(coalesce(p_no_doc, ''))); v_sebab text;
begin
  perform rc_private.require_tab('compilation.amend');
  if v_doc = '' then raise exception 'No Doc wajib diisi'; end if;
  select * into c from public.claims where upper(no_doc) = v_doc and archived_at is null;
  if not found or not rc_private.can_access(c.depot_id) then
    raise exception 'Dokumen % tidak ditemukan (atau terarsip / di luar yurisdiksi Anda)', v_doc; end if;
  select * into d from public.depots where id = c.depot_id;
  select * into cu from public.customers where id = c.customer_id;
  select * into ca from public.campaigns where id = c.campaign_id;
  v_sebab := case
    when c.customer_id is null then 'Customer Master belum ada; lengkapi dulu di Key Master'
    when c.pending_approval is not null then 'Sedang menunggu keputusan di Management of Approval'
  end;
  return jsonb_build_object('status', 'success',
    'noDoc', c.no_doc, 'versionNo', c.version_no, 'statusDok', rc_private.legacy_status(c.status),
    'kodeDepot', d.depot_code, 'depot', d.depot_name,
    'kodeToko', coalesce(cu.customer_code, c.source_customer_code), 'namaToko', coalesce(cu.customer_name, 'Customer Master belum ada'),
    'kodeCampaign', ca.campaign_code, 'campaign', ca.campaign_name,
    'jenisCb', rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)),
    'cbNet', c.cb_net, 'grossUp', c.gross_up,
    'bisa', v_sebab is null, 'sebab', coalesce(v_sebab, ''),
    'amendTerakhir', rc_private.legacy_ts(c.amended_at),
    'remark', coalesce(rc_private.claim_remark(c), ''));
end $fn$;

create or replace function public.rc_amend_doc(p_no_doc text, p_cb_net text, p_version_no bigint default null)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare c public.claims%rowtype; v_doc text := upper(btrim(coalesce(p_no_doc, ''))); v_baru numeric;
  v_subjek text; v_pajak text; v_jenis text; v_gross numeric; actor uuid := (select auth.uid());
begin
  perform rc_private.require_tab('compilation.amend');
  if v_doc = '' then raise exception 'No Doc wajib diisi'; end if;
  begin
    v_baru := nullif(btrim(coalesce(p_cb_net, '')), '')::numeric;
  exception when others then raise exception 'Net CB baru "%" bukan angka', p_cb_net;
  end;
  if v_baru is null then raise exception 'Net CB baru wajib diisi'; end if;
  if v_baru < 0 then raise exception 'Net CB tidak boleh negatif'; end if;
  -- Aturan Document Center (20261162210000): desimal dipotong, bukan dibulatkan.
  v_baru := trunc(v_baru);

  select * into c from public.claims where upper(no_doc) = v_doc and archived_at is null for update;
  if not found or not rc_private.can_access(c.depot_id) then
    raise exception 'Dokumen % tidak ditemukan (atau terarsip / di luar yurisdiksi Anda)', v_doc; end if;
  if p_version_no is not null and p_version_no <> c.version_no then
    raise exception 'Dokumen % berubah sejak dicek; cek ulang lalu proses lagi', c.no_doc; end if;
  if c.customer_id is null then
    raise exception 'Dokumen %: Customer Master belum ada; lengkapi dulu di Key Master', c.no_doc; end if;
  if c.pending_approval is not null then
    raise exception 'Dokumen % sedang menunggu keputusan di Management of Approval', c.no_doc; end if;
  if v_baru = c.cb_net then
    raise exception 'Net CB baru sama dengan Net CB sekarang (%)', rc_private.rupiah(c.cb_net); end if;

  -- Gross up dihitung ulang dengan aturan Reprocessing (20261162240000/20261162250000).
  select coalesce(c.tax_subject, cu.tax_subject), ca.tax_status, coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)
    into v_subjek, v_pajak, v_jenis
    from public.customers cu, public.campaigns ca where cu.id = c.customer_id and ca.id = c.campaign_id;
  v_gross := case when v_subjek is not null then rc_private.gross_up_klaim(v_baru, v_subjek, v_pajak, v_jenis) end;

  update public.claims set cb_net = v_baru, gross_up = v_gross, tax_subject = v_subjek,
    amended_at = now(), amended_by = actor, version_no = version_no + 1, updated_at = now()
  where id = c.id;

  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  values (c.id, actor, c.status, c.status, 'amend',
    'Amend Doc: Net CB ' || rc_private.rupiah(c.cb_net) || ' -> ' || rc_private.rupiah(v_baru));
  insert into public.activity_logs(actor_id, depot_id, event_type, entity_id, details)
  values (actor, c.depot_id, 'amend_doc', c.id, jsonb_build_object('noDoc', c.no_doc, 'status', c.status,
    'cbNetLama', c.cb_net, 'cbNetBaru', v_baru, 'grossUpLama', c.gross_up, 'grossUpBaru', v_gross));

  return jsonb_build_object('status', 'success', 'noDoc', c.no_doc, 'cbNetLama', c.cb_net, 'cbNetBaru', v_baru,
    'grossUpLama', c.gross_up, 'grossUpBaru', v_gross,
    'message', 'Dokumen ' || c.no_doc || ' di-Amend: Net CB ' || rc_private.rupiah(c.cb_net)
      || ' menjadi ' || rc_private.rupiah(v_baru) || '.');
end $fn$;

-- Riwayat Amend dalam jangkauan depot pemanggil, terbaru dulu.
create or replace function public.rc_amend_riwayat(p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_semua boolean; v_depot uuid[];
begin
  perform rc_private.require_tab('compilation.amend');
  v_semua := rc_private.saya_sm(); v_depot := rc_private.depot_akses_saya();
  return jsonb_build_object('status', 'success', 'rows', coalesce((select jsonb_agg(x order by x->>'urut' desc) from (
    select jsonb_build_object('urut', lpad(l.id::text, 20, '0'), 'waktu', rc_private.legacy_ts(l.created_at),
      'noDoc', l.details->>'noDoc', 'kodeDepot', d.depot_code, 'statusDok', rc_private.legacy_status(l.details->>'status'),
      'cbNetLama', (l.details->>'cbNetLama')::numeric, 'cbNetBaru', (l.details->>'cbNetBaru')::numeric,
      'oleh', coalesce(p.full_name, '')) x
      from public.activity_logs l
      left join public.depots d on d.id = l.depot_id
      left join public.profiles p on p.id = l.actor_id
     where l.event_type = 'amend_doc' and (v_semua or l.depot_id = any(v_depot))
     order by l.id desc limit least(greatest(coalesce(p_limit, 50), 1), 500)) t), '[]'::jsonb));
end $fn$;

revoke all on function public.rc_amend_cek(text) from public, anon;
revoke all on function public.rc_amend_doc(text, text, bigint) from public, anon;
revoke all on function public.rc_amend_riwayat(integer) from public, anon;
grant execute on function public.rc_amend_cek(text) to authenticated;
grant execute on function public.rc_amend_doc(text, text, bigint) to authenticated;
grant execute on function public.rc_amend_riwayat(integer) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (seluruhnya dibatalkan)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_user uuid; d record; dd record; c public.claims%rowtype; r jsonb; e text := ''; v_galat text; harap numeric;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Pengguna biasa yang memegang izin Document Center (tanpa centang tab Amend).
  select p.id into v_user from public.profiles p
   where p.role not in ('system manager', 'depot head', 'management') and p.status = 'active'
     and exists(select 1 from public.user_permissions up where up.user_id = p.id and up.permission_code = 'view_compilation')
   order by p.user_code limit 1;

  -- Tab: SM selalu; pengguna biasa hanya bila dicentang.
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  if not coalesce((rc_private.tab_rights(v_sm)->>'compilation.amend')::boolean, false) then e := e || ' SM tidak punya tab Amend;'; end if;
  if v_user is not null then
    if coalesce((rc_private.tab_rights(v_user)->>'compilation.amend')::boolean, false)
       and not exists(select 1 from rc_private.user_tab_access where user_id = v_user and tab_code = 'compilation.amend' and allowed) then
      e := e || ' tab Amend menyala tanpa dicentang;'; end if;
    begin
      insert into rc_private.user_tab_access(user_id, tab_code, allowed) values (v_user, 'compilation.amend', true)
        on conflict (user_id, tab_code) do update set allowed = true;
      if not coalesce((rc_private.tab_rights(v_user)->>'compilation.amend')::boolean, false) then e := e || ' tab Amend tidak menyala walau dicentang;'; end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' centang tab galat: ' || sqlerrm || ';'; end if;
    end;
    -- Tanpa centang: Amend ditolak.
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
      perform public.rc_amend_cek('X'); e := e || ' Amend tanpa tab diterima;';
    exception when others then if sqlerrm !~* 'tab|akses|denied|izin' then e := e || ' pesan tanpa tab: ' || sqlerrm || ';'; end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
  end if;

  -- Amend dokumen Not Yet: Net CB berubah (desimal dipotong), gross up dihitung ulang, status tetap,
  -- riwayat 'amend', Remark "Doc Amendment".
  select c2.id, c2.no_doc, c2.version_no, c2.cb_net, c2.status, c2.tax_subject, cu.tax_subject cu_subjek, ca.tax_status,
         coalesce(nullif(c2.cashback_type_override, ''), ca.cashback_type) jenis into d
    from public.claims c2 join public.customers cu on cu.id = c2.customer_id join public.campaigns ca on ca.id = c2.campaign_id
   where c2.status = 'not_yet' and c2.archived_at is null and c2.pending_approval is null and c2.cb_net > 0
   order by c2.no_doc limit 1;
  if d.no_doc is not null then
    begin
      r := public.rc_amend_cek(lower(d.no_doc));
      if not (r->>'bisa')::boolean or (r->>'versionNo')::bigint <> d.version_no then e := e || ' cek: ' || r::text || ';'; end if;
      r := public.rc_amend_doc(d.no_doc, (trunc(d.cb_net) + 1000)::text || '.75', d.version_no);
      select * into c from public.claims where id = d.id;
      harap := rc_private.gross_up_klaim(trunc(d.cb_net) + 1000, coalesce(d.tax_subject, d.cu_subjek), d.tax_status, d.jenis);
      if c.cb_net <> trunc(d.cb_net) + 1000 or c.gross_up is distinct from harap or c.status <> d.status or c.amended_at is null
         or c.version_no <> d.version_no + 1 then
        e := e || format(' amend: cb %s (harap %s), gross %s (harap %s), status %s;', c.cb_net, trunc(d.cb_net) + 1000, c.gross_up, harap, c.status); end if;
      if not exists(select 1 from public.claim_status_history h where h.claim_id = d.id and h.action = 'amend' and h.from_status = d.status and h.to_status = d.status) then
        e := e || ' riwayat amend tidak tercatat;'; end if;
      if (rc_private.claim_details(c))->>'remark' !~ 'Doc Amendment' then e := e || ' remark detail: ' || coalesce((rc_private.claim_details(c))->>'remark', 'null') || ';'; end if;
      if not exists(select 1 from public.activity_logs where event_type = 'amend_doc' and entity_id = d.id) then e := e || ' activity log amend tidak ada;'; end if;
      r := public.rc_amend_riwayat(5);
      if (r->'rows'->0->>'noDoc') is distinct from d.no_doc then e := e || ' riwayat: ' || left(r::text, 200) || ';'; end if;
      -- Versi lama ditolak; nilai sama ditolak; negatif ditolak.
      begin perform public.rc_amend_doc(d.no_doc, '5000', d.version_no); e := e || ' versi lama diterima;';
      exception when others then if sqlerrm !~ 'berubah sejak dicek' then e := e || ' pesan versi: ' || sqlerrm || ';'; end if; end;
      begin perform public.rc_amend_doc(d.no_doc, c.cb_net::text, null); e := e || ' nilai sama diterima;';
      exception when others then if sqlerrm !~ 'sama dengan' then e := e || ' pesan sama: ' || sqlerrm || ';'; end if; end;
      begin perform public.rc_amend_doc(d.no_doc, '-5', null); e := e || ' negatif diterima;';
      exception when others then if sqlerrm !~ 'negatif' then e := e || ' pesan negatif: ' || sqlerrm || ';'; end if; end;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' amend galat: ' || sqlerrm || ';'; end if;
    end;
  end if;

  -- Dokumen Done juga bisa di-Amend; statusnya tetap Done.
  select c2.id, c2.no_doc, c2.version_no, c2.cb_net into dd from public.claims c2
   where c2.status = 'done' and c2.archived_at is null and c2.pending_approval is null and c2.customer_id is not null and c2.cb_net > 0
   order by c2.no_doc limit 1;
  if dd.no_doc is not null then
    begin
      perform public.rc_amend_doc(dd.no_doc, (trunc(dd.cb_net) + 1)::text, dd.version_no);
      select * into c from public.claims where id = dd.id;
      if c.status <> 'done' or c.cb_net <> trunc(dd.cb_net) + 1 then e := e || format(' amend Done: status %s, cb %s;', c.status, c.cb_net); end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' amend Done galat: ' || sqlerrm || ';'; end if;
    end;
  end if;

  -- Dokumen yang menunggu approval dan dokumen tanpa Customer Master ditolak.
  select no_doc into v_galat from public.claims where pending_approval is not null and archived_at is null order by no_doc limit 1;
  if v_galat is not null then
    begin perform public.rc_amend_doc(v_galat, '1000', null); e := e || ' dokumen menunggu approval diterima;';
    exception when others then if sqlerrm !~ 'menunggu keputusan' then e := e || ' pesan approval: ' || sqlerrm || ';'; end if; end;
  end if;
  select no_doc into v_galat from public.claims where customer_id is null and archived_at is null order by no_doc limit 1;
  if v_galat is not null then
    begin perform public.rc_amend_doc(v_galat, '1000', null); e := e || ' dokumen tanpa Customer Master diterima;';
    exception when others then if sqlerrm !~ 'Customer Master belum ada' then e := e || ' pesan master: ' || sqlerrm || ';'; end if; end;
  end if;

  -- Label Remark.
  if rc_private.claim_remark_dari(now(), false, true, now()) <> 'Doc Amendment, Document Reprocessed, CB Type Changed'
     or rc_private.claim_remark_dari(null, true, false) <> 'Document Reprocessed'
     or rc_private.claim_remark_dari(null, false, false, null) <> '' then
    e := e || ' label remark: ' || coalesce(rc_private.claim_remark_dari(now(), false, true, now()), 'null') || ';'; end if;

  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
