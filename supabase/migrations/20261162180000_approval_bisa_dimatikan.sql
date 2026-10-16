-- ==========================================================================================
-- Approval dapat dihidupkan / dimatikan dari Access Management
-- ==========================================================================================
-- Diminta pemilik, 9 Oktober 2026:
--   "Tambahkan 1 tab di access management dimana akses approval bisa dihidupkan atau
--    dimatikan, artinya ketika dimatikan maka langsung stage selanjutnya tanpa approval, dan
--    dokumen yang ada di approval (gantung) harus di approve dengan line lama. dan email nya
--    juga akan berubah bukan approval - pengajuan ... tapi langsung Pengajuan Claim Depot ..."
--
-- PERILAKU
--   * public.pengaturan_sistem menyimpan 'approval_aktif' (bawaan: true = seperti sekarang).
--   * Saat DIMATIKAN, submit tidak lagi berhenti di Submitted menunggu Management of Approval:
--     dokumen langsung Approved (antrean Release) - atau Done untuk Rebate Manual, persis
--     tujuan yang dulu ditetapkan persetujuannya. Riwayatnya mencatat dua langkah: submit dan
--     "approve_otomatis" dengan alasan "Approval dimatikan".
--   * Dokumen yang SUDAH diajukan sebelum dimatikan tetap Submitted dan tetap diputuskan lewat
--     Management of Approval seperti biasa ("line lama").
--   * Email pengajuan untuk submit tanpa approval berjudul "Pengajuan Claim Depot <nama depot>"
--     (bukan "Approval - Pengajuan Claim Cashback ..."), dan isinya meminta OSC memproses.
--   * Keputusan On Hold / Expired tidak termasuk: tetap melalui tab On Hold & Expired.
--
-- HAK: tab baru Access Management > "Approval On/Off" (access.approval). Karena ini saklar yang
-- berlaku untuk SELURUH sistem, tab ini bawaannya MATI bagi semua kecuali System Manager dan
-- menyala hanya bila dicentang di Edit Akses.
--
-- Ditambal dengan penjaga MD5 pra-citra (akhir baris dinormalkan), sama di dev dan prod pada
-- 9 Oktober 2026. Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Pengaturan sistem
-- ------------------------------------------------------------------------------------------
create table if not exists public.pengaturan_sistem (
  kunci       text primary key,
  nilai       jsonb not null,
  catatan     text,
  diubah_oleh uuid references public.profiles(id),
  diubah_pada timestamptz not null default now()
);
alter table public.pengaturan_sistem enable row level security;
revoke all on public.pengaturan_sistem from anon, authenticated;
insert into public.pengaturan_sistem(kunci, nilai) values ('approval_aktif', 'true'::jsonb) on conflict do nothing;

create or replace function rc_private.approval_aktif()
returns boolean language sql stable security definer set search_path = '' as $fn$
  select coalesce((select (nilai #>> '{}')::boolean from public.pengaturan_sistem where kunci = 'approval_aktif'), true);
$fn$;
revoke all on function rc_private.approval_aktif() from public, anon;
grant execute on function rc_private.approval_aktif() to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2. Tab baru: Access Management > Approval On/Off
-- ------------------------------------------------------------------------------------------
insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select 'access.approval', 'access', 'approval', 'manage_access', 'Approval On/Off', t.label, t.key
  from rc_private.tab_catalog t where t.code = 'access.list'
on conflict do nothing;

-- ------------------------------------------------------------------------------------------
-- 3. RPC
-- ------------------------------------------------------------------------------------------
-- Keadaan saklar untuk spanduk di layar (Management of Approval, Claim Upload).
create or replace function public.rc_approval_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare s public.pengaturan_sistem;
begin
  if not rc_private.can_access(null) then raise exception 'Access denied' using errcode = '42501'; end if;
  select * into s from public.pengaturan_sistem where kunci = 'approval_aktif';
  return jsonb_build_object('status','success','aktif', rc_private.approval_aktif(),
    'sejak', case when s.diubah_oleh is null then '' else to_char(s.diubah_pada at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI') end,
    'oleh', coalesce((select full_name from public.profiles where id = s.diubah_oleh), ''));
end
$fn$;
revoke all on function public.rc_approval_status() from public, anon;
grant execute on function public.rc_approval_status() to authenticated;

create or replace function public.rc_approval_setelan()
returns jsonb language plpgsql stable security definer set search_path = '' as $fn$
declare s public.pengaturan_sistem;
begin
  perform rc_private.require_tab('access.approval');
  select * into s from public.pengaturan_sistem where kunci = 'approval_aktif';
  return jsonb_build_object('status','success','aktif', rc_private.approval_aktif(),
    'diubahPada', case when s.diubah_oleh is null then '' else to_char(s.diubah_pada at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI:SS') end,
    'diubahOleh', coalesce((select full_name || ' (' || user_code || ')' from public.profiles where id = s.diubah_oleh), ''),
    'catatan', coalesce(s.catatan, ''),
    -- Dokumen yang masih menunggu keputusan di Management of Approval ("gantung").
    'menunggu', (select count(*) from public.claims where status = 'submitted' and archived_at is null
                  and pending_approval->>'kind' = 'submit'),
    'menungguDepot', (select count(distinct depot_id) from public.claims where status = 'submitted' and archived_at is null
                       and pending_approval->>'kind' = 'submit'),
    'riwayat', coalesce((select jsonb_agg(jsonb_build_object(
        'waktu', to_char(a.created_at at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI'),
        'oleh', coalesce((select full_name from public.profiles where id = a.actor_id), ''),
        'aksi', case when a.event_type = 'approval_dimatikan' then 'Dimatikan' else 'Dihidupkan' end,
        'catatan', coalesce(a.details->>'catatan', '')) order by a.created_at desc)
      from (select * from public.activity_logs where event_type in ('approval_dimatikan','approval_dihidupkan')
             order by created_at desc limit 10) a), '[]'::jsonb));
end
$fn$;
revoke all on function public.rc_approval_setelan() from public, anon;
grant execute on function public.rc_approval_setelan() to authenticated;

create or replace function public.rc_approval_setel(p_aktif boolean, p_catatan text)
returns jsonb language plpgsql security definer set search_path = '' as $fn$
declare v_kini boolean; n_menunggu int;
begin
  perform rc_private.require_tab('access.approval');
  if p_aktif is null then raise exception 'Pilihan wajib diisi'; end if;
  if length(btrim(coalesce(p_catatan,''))) < 3 then raise exception 'Alasan wajib diisi'; end if;
  perform pg_advisory_xact_lock(hashtextextended('rc-approval-aktif', 0));
  v_kini := rc_private.approval_aktif();
  if v_kini = p_aktif then
    return jsonb_build_object('status','success','aktif', v_kini,
      'message', case when v_kini then 'Approval sudah aktif.' else 'Approval sudah dimatikan.' end);
  end if;

  insert into public.pengaturan_sistem(kunci, nilai, catatan, diubah_oleh, diubah_pada)
  values ('approval_aktif', to_jsonb(p_aktif), left(btrim(p_catatan), 300), (select auth.uid()), now())
  on conflict (kunci) do update set nilai = excluded.nilai, catatan = excluded.catatan,
    diubah_oleh = excluded.diubah_oleh, diubah_pada = excluded.diubah_pada;

  select count(*) into n_menunggu from public.claims
   where status = 'submitted' and archived_at is null and pending_approval->>'kind' = 'submit';
  insert into public.activity_logs(actor_id, event_type, details)
  values ((select auth.uid()), case when p_aktif then 'approval_dihidupkan' else 'approval_dimatikan' end,
    jsonb_build_object('catatan', left(btrim(p_catatan), 300), 'menunggu', n_menunggu));

  return jsonb_build_object('status','success','aktif', p_aktif, 'menunggu', n_menunggu,
    'message', case when p_aktif
      then 'Approval dihidupkan kembali. Pengajuan baru menunggu persetujuan di Management of Approval.'
      else 'Approval dimatikan. Pengajuan baru langsung ke tahap Release tanpa approval.'
        || case when n_menunggu > 0 then ' ' || n_menunggu || ' dokumen yang sudah diajukan tetap menunggu keputusan di Management of Approval.' else '' end
      end);
end
$fn$;
revoke all on function public.rc_approval_setel(boolean, text) from public, anon;
grant execute on function public.rc_approval_setel(boolean, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Tambalan pada fungsi yang hidup
-- ------------------------------------------------------------------------------------------
do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text, n int) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti, n) values
  -- Tab saklar: bawaannya mati bagi semua kecuali System Manager.
  ('rc_private.tab_rights(uuid)', '1c810c52c0845cf2d08186e1265fb2d7',
   $p$not (p.role='depot head' and t.code in ('approval.ovd','approval.hold')))$p$,
   $p$not ((p.role='depot head' and t.code in ('approval.ovd','approval.hold')) or t.code='access.approval' /* 20261162180000: hanya bila dicentang */))$p$, 1),

  -- Mesin status.
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;$p$,
   $p$declare actor uuid:=auth.uid(); perm text; v_payload jsonb; cached rc_private.requests%rowtype;
 -- 20261162180000: approval dimatikan -> submit langsung ke tahap berikutnya.
 v_langsung boolean:=(p_action='submit' and not rc_private.approval_aktif());$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$ if p_action='submit' and c.status='not_yet' and c.pending_approval is null then target:='submitted';$p$,
   $p$ if p_action='submit' and c.status='not_yet' and c.pending_approval is null then
  target:=case when v_langsung then case when jenis='rebate manual' then 'done' else 'approved' end else 'submitted' end;$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$   when p_action in('submit','hold','expire') then jsonb_build_object($p$,
   $p$   when p_action in('submit','hold','expire') and not v_langsung then jsonb_build_object($p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$ approved_at=case when p_action='approve' then stamp$p$,
   $p$ approved_at=case when p_action='approve' or v_langsung then stamp$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$(p_action='approve' and target='done')$p$,
   $p$((p_action='approve' or v_langsung) and target='done')$p$, 2),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$   when p_action='approve' and target='done' then c.batch_upload else batch_clearing end,$p$,
   $p$   when p_action='approve' and target='done' then c.batch_upload when v_langsung and target='done' then batch else batch_clearing end,$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$ if p_action='approve' and target='done' then$p$,
   $p$ if v_langsung then
  insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
   values(c.id,actor,c.status,'submitted','submit',batch,p_reason),
         (c.id,actor,'submitted','approved','approve_otomatis',batch,'Approval dimatikan');
  if target='done' then
   insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,batch,reason)
    values(c.id,actor,'approved','done','manual_complete',batch,'Rebate Manual');
  end if;
 elsif p_action='approve' and target='done' then$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$'pending_approval',p_action in('submit','hold','expire'),'gross_up'$p$,
   $p$'pending_approval',p_action in('submit','hold','expire') and not v_langsung,'gross_up'$p$, 1),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '601e8a8ab55102447ca77f7e6af716bb',
   $p$  perform rc_private.email_pengajuan_antre(p_action,batch,v_mail_ids,actor,p_reason);$p$,
   $p$  perform rc_private.email_pengajuan_antre(case when v_langsung then 'submit_langsung' else p_action end,batch,v_mail_ids,actor,p_reason);$p$, 1),

  -- Email pengajuan.
  ('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)', 'afc89b09cf6e9ae930789918d6092533',
   $p$  if p_action not in ('submit','hold','expire','expire_claim_process','approve','clearing') then$p$,
   $p$  if p_action not in ('submit','submit_langsung' /* 20261162180000 */,'hold','expire','expire_claim_process','approve','clearing') then$p$, 1),
  ('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)', 'afc89b09cf6e9ae930789918d6092533',
   $p$    when 'submit'               then 'Pengajuan Baru'$p$,
   $p$    when 'submit'               then 'Pengajuan Baru'
    when 'submit_langsung'      then 'Pengajuan Baru'$p$, 1),
  ('rc_private.email_pengajuan_subjek(text,text[])', '09be4123b8a38dd472463999ad747d27',
   $p$    when 'approve' then 'Approved - Pengajuan Claim Cashback Depo'$p$,
   $p$    -- 20261162180000: approval dimatikan - bukan "Approval - Pengajuan ...".
    when 'submit_langsung' then 'Pengajuan Claim Depot'
      || coalesce(' ' || rc_private.email_daftar_depot(p_depot), '')
    when 'approve' then 'Approved - Pengajuan Claim Cashback Depo'$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', 'a796bf32c2d75dbd016ef49af3736710',
   $p$  v_pembuka := case p_action$p$,
   $p$  v_pembuka := case replace(p_action, 'submit_langsung', 'submit') /* 20261162180000 */$p$, 1),
  ('rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)', 'a796bf32c2d75dbd016ef49af3736710',
   $p$    when 'submit'   then 'Mohon tim Management untuk segera melakukan approval atas pengajuan di atas.'$p$,
   $p$    when 'submit_langsung' then 'Pengajuan ini tidak melalui approval dan langsung diteruskan ke tahap Release. Mohon tim OSC untuk segera memproses dokumen tersebut.'
    when 'submit'   then 'Mohon tim Management untuk segera melakukan approval atas pengajuan di atas.'$p$, 1);

  for f in select sig, min(harapan) harapan from _tambal group by sig order by min(urut) loop
    src := pg_get_functiondef(to_regprocedure(f.sig));
    if src is null then raise exception 'DITOLAK: fungsi % tidak ada.', f.sig; end if;
    if src ~ '20261162180000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: definisi % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := src;
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> r.n then
        raise exception '%: pola "%" ditemukan % kali, diharapkan %.', f.sig, left(r.lama, 80), n, r.n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    if baru !~ '20261162180000' then raise exception '%: tambalan tidak memuat penanda.', f.sig; end if;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- 5. Pemeriksaan di dalam subtransaksi yang dibatalkan
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; v_spv uuid; d record; d2 record; d3 record; h jsonb; hasil jsonb := '{}'; e text := '';
begin
  select id into v_sm from public.profiles where role='system manager' and status='active' and not must_change_password
     and coalesce(suffix_num,'') <> '' order by user_code limit 1;
  select id into v_spv from public.profiles where role='supervisor' and status='active' and not must_change_password order by user_code limit 1;
  -- Dokumen Not Yet yang dapat di-submit: pelanggan memegang tepat satu dari KTP/NPWP, campaign
  -- aktif berjenis CB, tanpa tanda NP/NA.
  select c.id, c.no_doc, c.version_no into d from public.claims c
    join public.customers cu on cu.id = c.customer_id join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and ca.status = 'active'
     and coalesce(ca.cashback_type,'') <> '' and rc_private.jenis_efektif(ca.cashback_type) in ('transfer','cn')
     and ((coalesce(cu.ktp,'') <> '') <> (coalesce(cu.npwp,'') <> ''))
     and not rc_private.np_pasangan(c.depot_id, c.campaign_id)
     and not exists(select 1 from public.timetable_not_achieved na where na.depot_id = c.depot_id and na.campaign_id = c.campaign_id)
   order by c.no_doc limit 2;
  select c.id, c.no_doc, c.version_no into d2 from public.claims c
    join public.customers cu on cu.id = c.customer_id join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'not_yet' and c.pending_approval is null and c.archived_at is null and ca.status = 'active'
     and coalesce(ca.cashback_type,'') <> '' and rc_private.jenis_efektif(ca.cashback_type) in ('transfer','cn')
     and ((coalesce(cu.ktp,'') <> '') <> (coalesce(cu.npwp,'') <> ''))
     and not rc_private.np_pasangan(c.depot_id, c.campaign_id)
     and not exists(select 1 from public.timetable_not_achieved na where na.depot_id = c.depot_id and na.campaign_id = c.campaign_id)
     and c.id <> d.id order by c.no_doc limit 1;
  -- Dokumen "gantung" dari campaign AKTIF: campaign inactive memang melarang dokumen maju
  -- (jaga_status_campaign), terlepas dari saklar approval.
  select c.id, c.no_doc, c.version_no into d3 from public.claims c join public.campaigns ca on ca.id = c.campaign_id
   where c.status = 'submitted' and c.pending_approval->>'kind' = 'submit' and c.archived_at is null
     and ca.status = 'active' order by c.no_doc limit 1;
  if v_sm is null or d.id is null or d2.id is null then raise notice 'Data uji tidak lengkap; dilewati.'; return; end if;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);
    hasil := hasil || jsonb_build_object('awal', rc_private.approval_aktif());
    h := public.rc_approval_setel(false, 'uji migrasi');
    hasil := hasil || jsonb_build_object('mati', rc_private.approval_aktif(), 'pesanMati', h->>'message');

    -- Submit saat approval mati: langsung Approved, tanpa antrean.
    h := public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d.no_doc, 'version_no', d.version_no,
           'account_number', '1234567890', 'account_name', 'UJI', 'bank', 'BCA', 'top', '30', 'paid_on', '2026-10-01')), gen_random_uuid(), '');
    hasil := hasil || jsonb_build_object('langsung', (select jsonb_build_object('status', status, 'antre', pending_approval is not null,
        'approvedAt', approved_at is not null, 'batch', batch_upload is not null,
        'riwayat', (select string_agg(action, '>' order by id) from public.claim_status_history where claim_id = c.id and action in ('submit','approve_otomatis')))
      from public.claims c where c.id = d.id));
    -- Dokumen lama yang masih menunggu tetap dapat disetujui.
    if d3.id is not null then
      h := public.rc_process_claims('approve', jsonb_build_array(jsonb_build_object('no_doc', d3.no_doc, 'version_no', d3.version_no)), gen_random_uuid(), '');
      hasil := hasil || jsonb_build_object('gantungDisetujui', (select status from public.claims where id = d3.id));
    end if;
    hasil := hasil || jsonb_build_object('subjek', rc_private.email_pengajuan_subjek('submit_langsung', array['Medan']),
      'subjekLama', rc_private.email_pengajuan_subjek('submit', array['Medan']));

    -- Hidup kembali: submit kembali menunggu approval.
    h := public.rc_approval_setel(true, 'uji migrasi');
    h := public.rc_process_claims('submit', jsonb_build_array(jsonb_build_object('no_doc', d2.no_doc, 'version_no', d2.version_no,
           'account_number', '1234567890', 'account_name', 'UJI', 'bank', 'BCA', 'top', '30', 'paid_on', '2026-10-01')), gen_random_uuid(), '');
    hasil := hasil || jsonb_build_object('hidupLagi', (select status || '/' || coalesce(pending_approval->>'kind','-') from public.claims where id = d2.id));

    -- Tab saklar: Supervisor tidak memegangnya sebelum dicentang.
    if v_spv is not null then
      perform set_config('request.jwt.claims', json_build_object('sub', v_spv::text, 'role', 'authenticated')::text, true);
      hasil := hasil || jsonb_build_object('spvTab', rc_private.can_tab('access.approval'));
    end if;
    raise exception 'UJI_SELESAI';
  exception when raise_exception then if sqlerrm <> 'UJI_SELESAI' then raise; end if; end;
  perform set_config('request.jwt.claims', '', true);

  if not (hasil->>'awal')::boolean then e := e || ' keadaan awal bukan aktif;'; end if;
  if (hasil->>'mati')::boolean then e := e || ' saklar tidak mati;'; end if;
  if hasil->'langsung'->>'status' <> 'approved' or (hasil->'langsung'->>'antre')::boolean or not (hasil->'langsung'->>'approvedAt')::boolean
     or hasil->'langsung'->>'riwayat' <> 'submit>approve_otomatis' then e := e || ' submit tanpa approval;'; end if;
  if hasil ? 'gantungDisetujui' and hasil->>'gantungDisetujui' not in ('approved','done') then e := e || ' dokumen gantung;'; end if;
  if hasil->>'subjek' <> 'Pengajuan Claim Depot Medan' or hasil->>'subjekLama' !~ '^Approval - ' then e := e || ' subjek email;'; end if;
  if hasil->>'hidupLagi' <> 'submitted/submit' then e := e || ' hidup kembali;'; end if;
  if hasil ? 'spvTab' and (hasil->>'spvTab')::boolean then e := e || ' tab bawaan supervisor;'; end if;
  if e <> '' then raise exception 'GAGAL:% Hasil: %', e, hasil; end if;
  if not rc_private.approval_aktif() or (select status from public.claims where id = d.id) <> 'not_yet' then
    raise exception 'GAGAL: uji meninggalkan perubahan.'; end if;
  raise notice 'Saklar approval teruji: %', hasil;
end
$uji$;
