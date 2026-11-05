-- ==========================================================================================
-- Saklar ZDAGE Integration (On/Off), satu tab dengan saklar Approval
-- ==========================================================================================
-- Pemilik, 4 November 2026: "saya mau buatkan juga tab on / off zdage integration seperti
-- approval dan jadikan 1 tab aja artinya kalo di klik akan mengunakan cara baru bisa?"
--
-- * Saklar baru pengaturan_sistem 'zdage_aktif', BAWAAN MATI (cara lama). Diatur di tab
--   Access Management > On/Off Sistem (dulu "Approval On/Off"), bersama saklar Approval dan
--   Approval Bad Debt. Hak ubah sama: tab access.approval. Alasan wajib; tercatat di Log Activity.
-- * MATI (cara lama): seluruh dokumen Not Yet tampil di Claim Upload > Open dan boleh diajukan /
--   di-On Hold / Expired, tanpa menunggu tawaran toko lunas dari ZDAGE. Tab Restricted kosong.
--   Job harian ZDAGE (tawaran lewat batas -> overdue, email peringatan) tidak berjalan.
--   Upload Debtor tetap bisa dipakai untuk menyiapkan data; tawarannya tersimpan dan baru
--   berlaku saat saklar dihidupkan.
-- * HIDUP (cara baru): seperti 20261163170000 - hanya dokumen dengan tawaran aktif (atau toko
--   Bad Debt saat Approval Bad Debt menyala) yang ada di Open; sisanya Restricted.
-- * Bad Debt (tandai / cabut, Approval Bad Debt) tidak terpengaruh saklar ini.
-- Butuh 20261163170000 (Upload Debtor). Aman dijalankan berulang.
-- ==========================================================================================

do $pra$ begin
  if to_regprocedure('rc_private.boleh_open(uuid,uuid)') is null or to_regprocedure('rc_private.zdage_harian()') is null then
    raise exception 'DITOLAK: jalankan 20261163170000 (Upload Debtor ZDAGE) lebih dulu.'; end if;
end $pra$;

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Saklar -----------------------------------------------------------------------------
insert into public.pengaturan_sistem(kunci, nilai, catatan)
values ('zdage_aktif', 'false'::jsonb, 'ZDAGE Integration: bawaan mati (cara lama)')
on conflict (kunci) do nothing;

create or replace function rc_private.zdage_aktif() returns boolean
language sql stable security definer set search_path to '' as $f$
  select coalesce((select (nilai #>> '{}')::boolean from public.pengaturan_sistem where kunci = 'zdage_aktif'), false);
$f$;
revoke all on function rc_private.zdage_aktif() from public, anon;
grant execute on function rc_private.zdage_aktif() to authenticated;

-- ---- 2. Open: saat mati, semua Not Yet boleh (cara lama) -------------------------------------
create or replace function rc_private.boleh_open(p_claim uuid, p_customer uuid)
returns boolean language sql stable security definer set search_path to '' as $function$
  select not rc_private.zdage_aktif() /* 20261163620000: saklar ZDAGE Integration mati = cara lama */
      or exists(select 1 from public.rc_clearing_offers o where o.claim_id = p_claim and o.status in ('offered','overdue'))
      or (exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = p_customer and b.status = 'active')
          and rc_private.approval_bad_debt_aktif());
$function$;

-- ---- 3. Job harian berhenti saat mati -------------------------------------------------------
do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.zdage_harian()'::regprocedure), E'\r', '');
  if src !~ '20261163620000' then
    src := pg_temp.ganti(src,
      $p$begin
  with t as ($p$,
      $p$begin
  -- 20261163620000: saklar ZDAGE Integration mati - tidak ada overdue maupun email peringatan.
  if not rc_private.zdage_aktif() then
    return jsonb_build_object('overdue', 0, 'email', 0, 'lewati', 'ZDAGE Integration mati');
  end if;
  with t as ($p$, 1, 'zdage_harian');
    execute src;
  end if;
end $tambal$;

-- ---- 4. Setelan, ubah, status ----------------------------------------------------------------
create or replace function public.rc_zdage_setelan()
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare s public.pengaturan_sistem; u public.rc_zdage_uploads;
begin
  perform rc_private.require_tab('access.approval');
  select * into s from public.pengaturan_sistem where kunci = 'zdage_aktif';
  select * into u from public.rc_zdage_uploads where applied_at is not null order by applied_at desc limit 1;
  return jsonb_build_object('status', 'success', 'aktif', rc_private.zdage_aktif(),
    'diubahPada', case when s.diubah_oleh is null then '' else to_char(s.diubah_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI:SS') end,
    'diubahOleh', coalesce((select full_name || ' (' || user_code || ')' from public.profiles where id = s.diubah_oleh), ''),
    'catatan', case when s.diubah_oleh is null then '' else coalesce(s.catatan, '') end,
    -- Dampak bila (tetap) hidup: berapa Not Yet di Open dan berapa Restricted.
    'notYet', (select count(*) from public.claims c where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null),
    'openBilaHidup', (select count(*) from public.claims c where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null
        and (exists(select 1 from public.rc_clearing_offers o where o.claim_id = c.id and o.status in ('offered','overdue'))
             or (exists(select 1 from public.rc_bad_debt_remarks b where b.customer_id = c.customer_id and b.status = 'active')
                 and rc_private.approval_bad_debt_aktif()))),
    'uploadTerakhir', case when u.id is null then '' else coalesce(u.file_name, '-') || ' (diterapkan '
        || to_char(u.applied_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') || ')' end,
    'riwayat', coalesce((select jsonb_agg(jsonb_build_object(
        'waktu', to_char(a.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI'),
        'oleh', coalesce((select full_name from public.profiles where id = a.actor_id), ''),
        'aksi', case when a.event_type = 'zdage_dimatikan' then 'Dimatikan' else 'Dihidupkan' end,
        'catatan', coalesce(a.details->>'catatan', '')) order by a.created_at desc)
      from (select * from public.activity_logs where event_type in ('zdage_dimatikan', 'zdage_dihidupkan')
             order by created_at desc limit 10) a), '[]'::jsonb));
end $f$;

create or replace function public.rc_zdage_setel(p_aktif boolean, p_catatan text)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare n_open integer; n_total integer;
begin
  perform rc_private.require_tab('access.approval');
  if p_aktif is null then raise exception 'Pilihan wajib diisi'; end if;
  if length(btrim(coalesce(p_catatan, ''))) < 3 then raise exception 'Alasan wajib diisi'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rc-zdage-aktif', 0));
  if rc_private.zdage_aktif() = p_aktif then
    return jsonb_build_object('status', 'success', 'aktif', p_aktif,
      'message', case when p_aktif then 'ZDAGE Integration sudah hidup.' else 'ZDAGE Integration sudah mati.' end); end if;

  insert into public.pengaturan_sistem(kunci, nilai, catatan, diubah_oleh, diubah_pada)
  values ('zdage_aktif', to_jsonb(p_aktif), left(btrim(p_catatan), 300), auth.uid(), now())
  on conflict (kunci) do update set nilai = excluded.nilai, catatan = excluded.catatan,
    diubah_oleh = excluded.diubah_oleh, diubah_pada = excluded.diubah_pada;

  select count(*), count(*) filter (where rc_private.boleh_open(c.id, c.customer_id)) into n_total, n_open
    from public.claims c where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null;
  insert into public.activity_logs(actor_id, event_type, details, module, tab)
  values (auth.uid(), case when p_aktif then 'zdage_dihidupkan' else 'zdage_dimatikan' end,
    jsonb_build_object('catatan', left(btrim(p_catatan), 300), 'notYet', n_total, 'open', n_open), 'access', 'approval');

  return jsonb_build_object('status', 'success', 'aktif', p_aktif, 'open', n_open, 'notYet', n_total,
    'message', case when p_aktif
      then 'ZDAGE Integration dihidupkan (cara baru): ' || n_open || ' dari ' || n_total
           || ' dokumen Not Yet ada di Open; sisanya Restricted sampai tokonya lunas menurut Upload Debtor.'
      else 'ZDAGE Integration dimatikan (cara lama): seluruh ' || n_total || ' dokumen Not Yet kembali ada di Open.' end);
end $f$;

-- Untuk layar Open / Restricted / Upload Debtor (spanduk keadaan), semua user login.
create or replace function public.rc_zdage_status()
returns jsonb language sql stable security definer set search_path to '' as $f$
  select jsonb_build_object('status', 'success', 'aktif', rc_private.zdage_aktif());
$f$;

revoke all on function public.rc_zdage_setelan(), public.rc_zdage_setel(boolean, text), public.rc_zdage_status() from public, anon;
grant execute on function public.rc_zdage_setelan(), public.rc_zdage_setel(boolean, text), public.rc_zdage_status() to authenticated;

-- ---- 5. Nama tab: satu tab untuk seluruh saklar -------------------------------------------------
update rc_private.tab_catalog set title = 'On/Off Sistem' where code = 'access.approval' and title = 'Approval On/Off';

do $cek$ begin
  if pg_get_functiondef('rc_private.boleh_open(uuid,uuid)'::regprocedure) !~ 'zdage_aktif' then raise exception 'GAGAL: boleh_open'; end if;
  if pg_get_functiondef('rc_private.zdage_harian()'::regprocedure) !~ '20261163620000' then raise exception 'GAGAL: zdage_harian'; end if;
  raise notice 'Saklar ZDAGE Integration terpasang (keadaan: %).', case when rc_private.zdage_aktif() then 'HIDUP' else 'MATI' end;
end $cek$;
