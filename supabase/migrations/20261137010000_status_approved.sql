-- ==========================================================================================
-- Tahap Approval: status baru 'approved', sebelum Release
-- ==========================================================================================
-- Permintaan pemilik: "proses ini sebelum masuk ke release, jadi butuh approval sebelum masuk
-- ke release", dengan alur submitted -> approved -> released, dan penolakan mengembalikan
-- dokumen ke depot sebagai Not Yet.
--
-- ------------------------------------------------------------------------------------------
-- SATU MESIN STATUS, BUKAN DUA
-- ------------------------------------------------------------------------------------------
-- Seluruh perpindahan status dokumen di sistem ini melewati satu tempat:
-- rc_private.mutate_claims_unchecked. Di sanalah versi dokumen dinaikkan, riwayat status
-- dicatat, Log Aktivitas diisi, dan hak akses per depot diperiksa. Approval karena itu
-- ditambahkan sebagai dua tindakan baru pada mesin yang sama - 'approve' dan 'reject_approval' -
-- bukan sebagai jalur tersendiri.
--
-- Akibatnya langsung: riwayat approval masuk ke public.claim_status_history dan ke
-- public.activity_logs tanpa satu baris tambahan, sehingga permintaan "diintegrasikan ke dalam
-- Log Activity juga" terpenuhi dengan sendirinya. Jalur kedua akan berarti kedua catatan itu
-- harus diisi tangan, dan yang terlupa tidak akan terlihat sampai ada yang mencarinya.
--
-- ------------------------------------------------------------------------------------------
-- PENJAGA TOP DICABUT
-- ------------------------------------------------------------------------------------------
-- Dulu unggahan ditolak bila TOP yang diketik melebihi TOP Customer Master kecuali kolom
-- Approval diisi. Pemilik mencabutnya: "hapus field approver top nya semua bisa diupload nanti
-- dideterminasi dari approval aja". Kolomnya sudah hilang dari layar; penjaganya dicabut di
-- sini supaya server tidak lagi menolak dokumen yang sah.
--
-- TOP yang diketik TETAP disimpan - di rc_private.claim_sensitive.top_text - karena justru
-- nilai itulah yang dipakai modul approval untuk memisahkan Within Payment Term dari Overdue.
--
-- ------------------------------------------------------------------------------------------
-- JEJAK PER TAHAP
-- ------------------------------------------------------------------------------------------
-- Kolom *_by ditambahkan untuk setiap tahap, melengkapi *_at yang sudah ada. Nilainya ditulis
-- di tempat yang sama dengan waktunya, sehingga tidak mungkin ada waktu tanpa pelaku.
-- Penolakan mengosongkan jejak tahap yang dibatalkan - dokumen yang kembali ke depot tidak
-- boleh terlihat masih menyimpan nama penyetujunya.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Kolom jejak dan status baru
-- ------------------------------------------------------------------------------------------
alter table public.claims
  add column if not exists approved_at  timestamptz,
  add column if not exists submitted_by uuid references public.profiles(id),
  add column if not exists approved_by  uuid references public.profiles(id),
  add column if not exists released_by  uuid references public.profiles(id),
  add column if not exists claimed_by   uuid references public.profiles(id),
  add column if not exists cleared_by   uuid references public.profiles(id);

comment on column public.claims.approved_at is
  'Waktu dokumen disetujui pada modul Management of Approval, sebelum masuk Release.';

alter table public.claims drop constraint if exists claims_status_check;
alter table public.claims add constraint claims_status_check
  check (status = any (array['not_yet','submitted','approved','released','claimed','done','on_hold','expired']));

create index if not exists claims_status_approved_idx
  on public.claims(status, batch_upload) where status = 'submitted';

-- ------------------------------------------------------------------------------------------
-- 2. Izin baru
-- ------------------------------------------------------------------------------------------
insert into public.permissions(code, description)
values ('approve_claim','Menyetujui atau menolak dokumen sebelum Release')
on conflict (code) do update set description = excluded.description;

-- ------------------------------------------------------------------------------------------
-- 3. Status baru dikenali seluruh pembaca
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.legacy_status(s text)
returns text language sql immutable set search_path='' as $fn$
 select case s when 'not_yet' then 'Not Yet' when 'submitted' then 'Submitted'
 when 'approved' then 'Approved'
 when 'released' then 'Released' when 'claimed' then 'Claimed' when 'done' then 'Done'
 when 'on_hold' then 'On Hold' when 'expired' then 'Expired' else s end;
$fn$;

-- Dokumen yang menunggu approval jelas masih outstanding: ia belum cair dan belum hangus.
-- Definisi view dibaca dari katalog lalu ditambal, supaya kolom lain tidak mungkin bergeser.
do $mig$
declare def text; baru text;
begin
  def := pg_get_viewdef('public.rc_report_rows'::regclass, true);
  if position('''approved''' in def) > 0 then
    raise notice 'rc_report_rows sudah mengenal approved; dilewati.';
  else
    baru := replace(def,
      'ARRAY[''not_yet''::text, ''submitted''::text, ''released''::text, ''claimed''::text]',
      'ARRAY[''not_yet''::text, ''submitted''::text, ''approved''::text, ''released''::text, ''claimed''::text]');
    if baru = def then
      raise exception 'Pola daftar status outstanding tidak ditemukan pada rc_report_rows. '
        'Definisinya sudah berubah - periksa dan perbarui migration ini.';
    end if;
    execute 'create or replace view public.rc_report_rows as ' || baru;
    raise notice 'rc_report_rows: approved dihitung outstanding.';
  end if;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- 4. Mesin status
-- ------------------------------------------------------------------------------------------
do $mig$
declare src text; baru text; n int := 0;
  -- pola, pengganti
  ubah text[][] := array[
    -- daftar tindakan yang dikenali
    [$p$'reject_clearing','hold','unhold','expire','bulk_rebate')$p$,
     $p$'reject_clearing','hold','unhold','expire','bulk_rebate','approve','reject_approval')$p$],
    -- izin untuk tindakan baru
    [$p$ when p_action in('release','reject_release') then 'release_claim'$p$,
     $p$ when p_action in('approve','reject_approval') then 'approve_claim'$p$ || chr(10) ||
     $p$ when p_action in('release','reject_release') then 'release_claim'$p$],
    -- alasan wajib saat menolak
    [$p$if p_action in('reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$p$,
     $p$if p_action in('reject_approval','reject_release','reject_claim','reject_clearing','hold','unhold','expire') and btrim$p$],
    -- perpindahan status
    [$p$ elsif p_action='release' and c.status='submitted' then target:='released';$p$,
     $p$ elsif p_action='approve' and c.status='submitted' then target:='approved';$p$ || chr(10) ||
     $p$ elsif p_action='reject_approval' and c.status in('submitted','approved') then target:='not_yet';$p$ || chr(10) ||
     $p$ elsif p_action='release' and c.status='approved' then target:='released';$p$],
    [$p$ elsif p_action='reject_release' and c.status='submitted' then target:='not_yet';$p$,
     $p$ elsif p_action='reject_release' and c.status in('submitted','approved') then target:='not_yet';$p$],
    [$p$ elsif p_action='reject_claim' and c.status='released' then target:='submitted';$p$,
     $p$ elsif p_action='reject_claim' and c.status='released' then target:='approved';$p$],
    [$p$ elsif p_action='hold' and c.status in('not_yet','submitted','released','claimed')$p$,
     $p$ elsif p_action='hold' and c.status in('not_yet','submitted','approved','released','claimed')$p$],
    [$p$c.previous_status in('not_yet','submitted','released','claimed')$p$,
     $p$c.previous_status in('not_yet','submitted','approved','released','claimed')$p$],
    [$p$ elsif p_action='expire' and c.status in('not_yet','submitted','released','claimed','on_hold')$p$,
     $p$ elsif p_action='expire' and c.status in('not_yet','submitted','approved','released','claimed','on_hold')$p$],
    [$p$ elsif p_action='bulk_rebate' and c.status in('submitted','released','claimed') then$p$,
     $p$ elsif p_action='bulk_rebate' and c.status in('submitted','approved','released','claimed') then$p$],
    -- approval memakai nomor batch unggahan, tidak menerbitkan nomornya sendiri
    [$p$ if stage is not null and batch is null then batch:=rc_private.next_batch(stage); end if;$p$,
     $p$ if stage is not null and batch is null then batch:=rc_private.next_batch(stage); end if;$p$ || chr(10) ||
     $p$ -- Approval bekerja ATAS batch unggahan dan tidak menerbitkan nomor sendiri: nomor yang$p$ || chr(10) ||
     $p$ -- dicatat riwayat adalah nomor yang benar-benar dilihat penyetujunya di layar.$p$ || chr(10) ||
     $p$ if p_action in('approve','reject_approval') then batch:=c.batch_upload; end if;$p$],
    -- jejak per tahap
    [$p$ uploaded_at=case when p_action='submit' then stamp when p_action='reject_release' then null else uploaded_at end,$p$,
     $p$ uploaded_at=case when p_action='submit' then stamp when p_action in('reject_release','reject_approval') then null else uploaded_at end,$p$ || chr(10) ||
     $p$ submitted_by=case when p_action='submit' then actor when p_action in('reject_release','reject_approval') then null else submitted_by end,$p$ || chr(10) ||
     $p$ approved_at=case when p_action='approve' then stamp when p_action in('reject_approval','reject_release') then null else approved_at end,$p$ || chr(10) ||
     $p$ approved_by=case when p_action='approve' then actor when p_action in('reject_approval','reject_release') then null else approved_by end,$p$],
    [$p$ released_at=case when p_action in('release','bulk_rebate') then stamp when p_action='reject_claim' then null else released_at end,$p$,
     $p$ released_at=case when p_action in('release','bulk_rebate') then stamp when p_action='reject_claim' then null else released_at end,$p$ || chr(10) ||
     $p$ released_by=case when p_action in('release','bulk_rebate') then actor when p_action='reject_claim' then null else released_by end,$p$],
    [$p$ claimed_at=case when p_action in('claim','bulk_rebate') then stamp when p_action='reject_clearing' then null else claimed_at end,$p$,
     $p$ claimed_at=case when p_action in('claim','bulk_rebate') then stamp when p_action='reject_clearing' then null else claimed_at end,$p$ || chr(10) ||
     $p$ claimed_by=case when p_action in('claim','bulk_rebate') then actor when p_action='reject_clearing' then null else claimed_by end,$p$],
    [$p$ cleared_at=case when p_action in('clearing','bulk_rebate') then stamp else cleared_at end,$p$,
     $p$ cleared_at=case when p_action in('clearing','bulk_rebate') then stamp else cleared_at end,$p$ || chr(10) ||
     $p$ cleared_by=case when p_action in('clearing','bulk_rebate') then actor else cleared_by end,$p$]
  ];
  i int;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';
  if src is null then raise exception 'rc_private.mutate_claims_unchecked tidak ditemukan.'; end if;

  if position($p$p_action='approve'$p$ in src) > 0 then
    raise notice 'Mesin status sudah mengenal approve; dilewati.';
    return;
  end if;

  baru := src;
  for i in 1 .. array_length(ubah,1) loop
    if position(ubah[i][1] in baru) = 0 then
      raise exception 'Pola ke-% tidak ditemukan pada mutate_claims_unchecked: %. '
        'Sumbernya sudah berubah - periksa dan perbarui migration ini.', i, left(ubah[i][1], 80);
    end if;
    baru := replace(baru, ubah[i][1], ubah[i][2]);
    n := n + 1;
  end loop;

  -- Penjaga TOP dicabut. Dicari dari baris pertamanya sampai 'end if;' supaya tidak bergantung
  -- pada spasi di tengah blok.
  declare awal int; akhir int; blok text;
  begin
    awal := position($p$  if input_top is not null and master_top is not null and input_top>master_top$p$ in baru);
    if awal = 0 then raise exception 'Blok penjaga TOP tidak ditemukan.'; end if;
    akhir := position($p$  end if;$p$ in substr(baru, awal)) + awal + length($p$  end if;$p$) - 1;
    blok := substr(baru, awal, akhir - awal);
    baru := replace(baru, blok,
      $p$  -- Penjaga "TOP melebihi Customer Master maka Approval wajib" dicabut atas instruksi$p$ || chr(10) ||
      $p$  -- pemilik: seluruh dokumen boleh diunggah, dan layak-tidaknya TOP ditentukan di modul$p$ || chr(10) ||
      $p$  -- Management of Approval - bukan oleh orang yang mengetik unggahannya. TOP-nya tetap$p$ || chr(10) ||
      $p$  -- disimpan di bawah, karena justru nilai itulah yang dipakai modul tersebut.$p$);
    n := n + 1;
  end;

  execute baru;
  raise notice 'Mesin status diperbarui (% pola).', n;
end
$mig$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare src text;
begin
  if not exists (select 1 from pg_constraint where conrelid='public.claims'::regclass
                  and conname='claims_status_check'
                  and pg_get_constraintdef(oid) like '%approved%') then
    raise exception 'GAGAL: status approved belum diizinkan constraint.'; end if;

  foreach src in array array['approved_at','submitted_by','approved_by','released_by','claimed_by','cleared_by'] loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='claims' and column_name=src) then
      raise exception 'GAGAL: kolom claims.% tidak terbentuk.', src; end if;
  end loop;

  if rc_private.legacy_status('approved') <> 'Approved' then
    raise exception 'GAGAL: legacy_status belum memetakan approved.'; end if;

  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='rc_private' and p.proname='mutate_claims_unchecked';

  if position($q$p_action='approve' and c.status='submitted' then target:='approved'$q$ in src) = 0 then
    raise exception 'GAGAL: perpindahan submitted -> approved tidak ada.'; end if;
  if position($q$p_action='release' and c.status='approved'$q$ in src) = 0 then
    raise exception 'GAGAL: Release masih menerima dokumen yang belum disetujui.'; end if;
  if position($q$p_action='release' and c.status='submitted'$q$ in src) > 0 then
    raise exception 'GAGAL: jalur lama Release dari submitted masih ada.'; end if;
  if position($q$reject_approval$q$ in src) = 0 then
    raise exception 'GAGAL: penolakan approval tidak ada.'; end if;
  if position($q$sehingga Approval wajib diisi$q$ in src) > 0 then
    raise exception 'GAGAL: penjaga TOP masih ada.'; end if;
  if position($q$approved_by=case when p_action='approve' then actor$q$ in src) = 0 then
    raise exception 'GAGAL: jejak approved_by tidak ditulis.'; end if;

  if not exists (select 1 from public.permissions where code='approve_claim') then
    raise exception 'GAGAL: izin approve_claim tidak ada.'; end if;

  -- Dokumen yang menunggu approval harus tetap terhitung outstanding.
  if exists (select 1 from pg_views where schemaname='public' and viewname='rc_report_rows'
              and definition not like '%approved%') then
    raise exception 'GAGAL: rc_report_rows belum mengenal approved.'; end if;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
