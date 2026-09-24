-- ==========================================================================================
-- Approval: penyaring depot, pencarian, dan pagination riwayat
-- ==========================================================================================
-- Permintaan pemilik untuk modul Management of Approval:
--
--   * penyaring berdasarkan depot bagi yang memegang lebih dari satu depot; yang hanya
--     memegang satu depot cukup dibekukan pada depotnya sendiri
--   * pencarian
--   * pagination pada tab History, "jika nantinya history banyak"
--
-- ------------------------------------------------------------------------------------------
-- MENGAPA DEPOT DISARING DI SERVER, SEDANGKAN PENCARIAN DI LAYAR
-- ------------------------------------------------------------------------------------------
-- Penyaring depot mengubah ANGKANYA - jumlah batch, jumlah dokumen, total Net CB. Kalau ia
-- dikerjakan di browser, ringkasan di atas tabel akan menghitung batch yang sudah tersembunyi,
-- dan orang membaca total yang tidak sesuai dengan yang dilihatnya. Karena itu ia dikerjakan
-- di server, di tempat yang sama dengan agregasinya.
--
-- Pencarian tidak mengubah apa pun selain yang tampak, dan barisnya sudah ada di layar. Ia
-- dikerjakan di browser supaya terasa seketika, tanpa bolak-balik ke server pada tiap ketikan.
--
-- Riwayat berbeda lagi: jumlahnya tumbuh tanpa batas, jadi pencarian DAN pagination-nya harus
-- di server - menyaring di browser hanya akan menyaring halaman yang kebetulan sedang terbuka.
--
-- Penyaring depot tidak pernah memperluas apa pun: ia hanya mempersempit di dalam jangkauan
-- yang sudah ditentukan rc_private.can_access. Depot di luar jangkauan tetap tidak terlihat
-- betapapun tepat kodenya diketik.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Daftar batch: membawa identitas depot dan menerima penyaringnya
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_approval_batches(text);
create or replace function public.rc_approval_batches(p_kind text default 'wpt',
                                                      p_depot text default null)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare v_ovd boolean; v_depot text; hasil jsonb;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;
  v_ovd := lower(coalesce(p_kind,'wpt')) = 'ovd';
  if v_ovd and not rc_private.boleh_approve_overdue() then
    raise exception 'Depot Head hanya dapat menyetujui dokumen Within Payment Term'
      using errcode='42501'; end if;
  v_depot := nullif(btrim(coalesce(p_depot,'')),'');

  select jsonb_build_object('status','success','kind', case when v_ovd then 'ovd' else 'wpt' end,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'noBatch', t.batch, 'kodeDepot', t.depot_code, 'namaDepot', t.depot_name,
      'qtyDoc', t.qty_doc, 'qtyCust', t.qty_cust,
      'qtyCampaign', t.qty_camp, 'totalNetCb', t.net_cb,
      'submittedBy', t.submitted_by, 'postingDate', t.posting_date)
      order by t.posting_date desc nulls last, t.batch), '[]'::jsonb))
  into hasil
  from (
    select coalesce(nullif(btrim(r.batch_upload),''),'(tanpa batch)') batch,
           coalesce(d.depot_code,'-') depot_code,
           coalesce(d.depot_name,'-') depot_name,
           count(*) qty_doc,
           count(distinct r.customer_code) qty_cust,
           count(distinct r.campaign_code) qty_camp,
           coalesce(sum(r.cb_net),0) net_cb,
           coalesce(string_agg(distinct p.full_name, ', '),'-') submitted_by,
           to_char(max(r.uploaded_at) at time zone 'Asia/Jakarta','DD-Mon-YYYY') posting_date
      from rc_private.approval_rows r
      left join public.profiles p on p.id = r.submitted_by
      left join public.depots d on d.id = r.depot_id
     where rc_private.can_access(r.depot_id,'approve_claim')
       and rc_private.approval_overdue(r.uploaded_at, r.top_text) = v_ovd
       and (v_depot is null or d.depot_code = v_depot)
     group by 1,2,3) t;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_batches(text,text) from public, anon;
grant execute on function public.rc_approval_batches(text,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Depot yang boleh dipilih pemakai ini
-- ------------------------------------------------------------------------------------------
-- Dipakai layar untuk memutuskan bentuk penyaringnya: satu depot berarti dibekukan, lebih dari
-- satu berarti dapat dipilih. Keputusan itu diambil dari data, bukan dari peran - seorang OSC
-- dapat memegang satu atau lima depot, dan yang menentukan adalah penetapannya.
create or replace function public.rc_approval_depots()
returns jsonb language plpgsql stable set search_path='' as $fn$
declare hasil jsonb;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak menyetujui dokumen' using errcode='42501'; end if;

  select jsonb_build_object('status','success',
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'kode', d.depot_code, 'nama', d.depot_name, 'region', coalesce(d.region,''))
      order by d.depot_code), '[]'::jsonb))
  into hasil
  from public.depots d
  where d.archived_at is null and rc_private.can_access(d.id,'approve_claim');
  return hasil;
end $fn$;
revoke all on function public.rc_approval_depots() from public, anon;
grant execute on function public.rc_approval_depots() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Riwayat: pencarian dan pagination di server
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_approval_history(integer, integer);
create or replace function public.rc_approval_history(p_limit integer default 50,
                                                      p_offset integer default 0,
                                                      p_search text default null,
                                                      p_depot text default null)
returns jsonb language plpgsql stable set search_path='' as $fn$
declare hasil jsonb; v_total bigint; v_cari text; v_depot text; v_limit int; v_offset int;
begin
  if not rc_private.can_access(null,'approve_claim') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak melihat riwayat approval' using errcode='42501'; end if;

  v_cari   := nullif(btrim(coalesce(p_search,'')),'');
  v_depot  := nullif(btrim(coalesce(p_depot,'')),'');
  v_limit  := greatest(1, least(coalesce(p_limit,50), 500));
  v_offset := greatest(0, coalesce(p_offset,0));

  -- Jumlah total dihitung dengan penyaring yang SAMA. Menghitungnya tanpa penyaring akan
  -- membuat nomor halaman menjanjikan baris yang tidak pernah muncul.
  with dasar as (
    select h.created_at, c.no_doc, h.batch, h.action, h.from_status, h.to_status,
           p.full_name, h.reason, d.depot_code, d.depot_name
      from public.claim_status_history h
      join public.claims c on c.id = h.claim_id
      left join public.depots d on d.id = c.depot_id
      left join public.profiles p on p.id = h.actor_id
     where h.action in ('approve','reject_approval')
       and rc_private.can_access(c.depot_id,'approve_claim')
       and (v_depot is null or d.depot_code = v_depot)
       and (v_cari is null or (
            c.no_doc ilike '%'||v_cari||'%'
         or coalesce(h.batch,'') ilike '%'||v_cari||'%'
         or coalesce(p.full_name,'') ilike '%'||v_cari||'%'
         or coalesce(h.reason,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_code,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_name,'') ilike '%'||v_cari||'%'))
  )
  select count(*) into v_total from dasar;

  with dasar as (
    select h.created_at, c.no_doc, h.batch, h.action, h.from_status, h.to_status,
           p.full_name, h.reason, d.depot_code, d.depot_name
      from public.claim_status_history h
      join public.claims c on c.id = h.claim_id
      left join public.depots d on d.id = c.depot_id
      left join public.profiles p on p.id = h.actor_id
     where h.action in ('approve','reject_approval')
       and rc_private.can_access(c.depot_id,'approve_claim')
       and (v_depot is null or d.depot_code = v_depot)
       and (v_cari is null or (
            c.no_doc ilike '%'||v_cari||'%'
         or coalesce(h.batch,'') ilike '%'||v_cari||'%'
         or coalesce(p.full_name,'') ilike '%'||v_cari||'%'
         or coalesce(h.reason,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_code,'') ilike '%'||v_cari||'%'
         or coalesce(d.depot_name,'') ilike '%'||v_cari||'%'))
     order by h.created_at desc
     limit v_limit offset v_offset
  )
  select jsonb_build_object('status','success','total',v_total,
    'limit', v_limit, 'offset', v_offset,
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'waktu', to_char(t.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI'),
      'noDoc', t.no_doc, 'noBatch', coalesce(t.batch,''),
      'kodeDepot', coalesce(t.depot_code,'-'),
      'tindakan', case when t.action='approve' then 'Approve' else 'Reject' end,
      'dari', rc_private.legacy_status(t.from_status),
      'ke', rc_private.legacy_status(t.to_status),
      'oleh', coalesce(t.full_name,''), 'alasan', coalesce(t.reason,''))
      order by t.created_at desc), '[]'::jsonb))
  into hasil from dasar t;
  return hasil;
end $fn$;
revoke all on function public.rc_approval_history(integer,integer,text,text) from public, anon;
grant execute on function public.rc_approval_history(integer,integer,text,text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_uid uuid; b jsonb; d jsonb; h jsonb; v_depot text; n_semua int; n_saring int;
begin
  select id into v_uid from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text,'role','authenticated')::text, true);

  b := public.rc_approval_batches('wpt', null);
  d := public.rc_approval_depots();
  h := public.rc_approval_history(5, 0, null, null);

  if (b->>'status') <> 'success' then raise exception 'GAGAL: daftar batch.'; end if;
  if (d->>'status') <> 'success' then raise exception 'GAGAL: daftar depot.'; end if;
  if (h->>'status') <> 'success' then raise exception 'GAGAL: riwayat.'; end if;
  if not (h ? 'total' and h ? 'limit' and h ? 'offset') then
    raise exception 'GAGAL: riwayat tidak membawa keterangan halaman.'; end if;
  if jsonb_array_length(h->'rows') > 5 then
    raise exception 'GAGAL: batas halaman tidak dihormati.'; end if;

  n_semua := jsonb_array_length(b->'rows');
  if n_semua > 0 then
    if (b->'rows'->0) ? 'kodeDepot' = false then
      raise exception 'GAGAL: baris batch tidak membawa kode depot.'; end if;

    -- Penyaring depot harus mempersempit, dan depot karangan harus menghasilkan kosong.
    v_depot := b->'rows'->0->>'kodeDepot';
    n_saring := jsonb_array_length(public.rc_approval_batches('wpt', v_depot)->'rows');
    if n_saring = 0 then
      raise exception 'GAGAL: penyaring depot % menghasilkan nol batch.', v_depot; end if;
    if n_saring > n_semua then
      raise exception 'GAGAL: penyaring depot justru memperluas hasil.'; end if;
    if jsonb_array_length(public.rc_approval_batches('wpt','DEPOT-KARANGAN')->'rows') <> 0 then
      raise exception 'GAGAL: depot karangan tetap mengembalikan batch.'; end if;
  end if;

  reset role;
  raise notice 'Batch %, depot terjangkau %, riwayat total %.',
    n_semua, jsonb_array_length(d->'rows'), h->>'total';
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
