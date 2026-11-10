-- ==========================================================================================
-- Status campaign Closed, dan Amend Doc > Change Status (Expired -> Not Yet)
-- ==========================================================================================
-- Pemilik, 10 November 2026:
-- 1. "untuk status campaign tambahkan 1 lagi, closed artinya semua yang Not Yet akan jadi Expired dan
--    ada email untuk itu ... buat di email otomatis list cc nya."
--    * Status baru 'closed'. Saat campaign berubah menjadi Closed (formulir maupun upload Campaign
--      Master), seluruh dokumen Not Yet yang tidak diarsip menjadi Expired dalam transaksi yang sama:
--      satu batch (kepala 3, tahap 04) untuk satu campaign, riwayat 'campaign_closed', tawaran toko
--      lunas yang masih aktif dibatalkan, satu baris Log Activity. Approval tidak berlaku.
--    * Dokumen tanpa Customer Master ikut Expired (pengecualian khusus di jaga_customer_master_klaim).
--    * Closed bersifat final: tidak dapat dibuka kembali, dokumen Expired-nya tidak dapat dikembalikan,
--      dan dokumen baru ditolak. Dokumen yang sudah berjalan (Submitted ke atas) tetap dapat diselesaikan.
--    * Email "Campaign Closed": satu email untuk seluruh depot yang dokumennya dihanguskan (satu putaran,
--      seperti Daily Outstanding), bukan per depot. Diatur di Access Management > Email Pengajuan
--      ("pindahkan saja ke tab email pengajuan"): sakelar, Mode Uji, CC semua email, dan CC wajib jenis
--      Campaign Closed (cc_per_jenis 'closed'). TO = Email TO Depot Master depot-depot tersebut, CC =
--      OSC / Supervisor depot + CC semua email + CC wajib Campaign Closed. Email Expired per depot
--      (kloter 12:00 / 16:00) tidak ikut terkirim untuk penutupan ini.
--    * "untuk campaign yang udah cleared maka statusnya auto berubah jadi closed": status cleared yang
--      disimpan berubah menjadi closed (trigger), dan campaign cleared yang sudah ada ikut menjadi closed.
-- 2. "untuk ubah status dari expired ke not yet di amend doc buat sama seperti change value dengan nama
--    Change Status, ini hanya bisa dari expired ke not yet."
--    * Tab compilation.changestatus, sub bab Amend Doc, bawaan OSC (peran lain bila dicentang).
--    * Seluruh baris diperiksa dulu; satu salah = tidak ada yang diubah. Maksimal 200 dokumen.
--    * Kembali ke Not Yet seperti Reprocessing: perpanjangan SO / Billing dan Batch Clearing (batch
--      Expired) dikosongkan; riwayat 'change_status'; email per depot; satu baris Log Activity.
--    * Jawaban pemilik atas pertanyaan sesudahnya: Qty = jumlah toko (dokumen) dan Value = Net CB; kode
--      kejadian batch tetap 3; Remark "Status Changed" (claims.status_changed_at), seperti "DC changed".
-- Butuh 20261163870000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.claims add column if not exists status_changed_at timestamptz;

alter table public.campaigns drop constraint if exists campaigns_status_check;
alter table public.campaigns add constraint campaigns_status_check check (status in ('active', 'inactive', 'cleared', 'closed'));

insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select 'compilation.changestatus', 'compilation', 'changestatus', 'view_compilation', 'Amend Doc - Change Status', t.label, t.key
  from rc_private.tab_catalog t where t.code = 'compilation.list'
   and not exists(select 1 from rc_private.tab_catalog where code = 'compilation.changestatus');

do $tambal$
declare src text;
begin
  -- ---- Hak tab: Change Status bawaan OSC seperti Change Value dan Change DC -------------------
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid,text)'::regprocedure), E'\r', '');
  if src !~ 'compilation.changestatus' then
    src := pg_temp.ganti(src, $p$t.code in ('compilation.amend','compilation.changedc') and p.role<>'osc'$p$,
      $p$t.code in ('compilation.amend','compilation.changedc','compilation.changestatus' /* 20261163880000 */) and p.role<>'osc'$p$, 1, 'tab_rights');
    execute src;
  end if;

  -- ---- Klaim baru ditolak untuk campaign Closed; Expired-nya final -----------------------------
  src := replace(pg_get_functiondef('rc_private.jaga_status_campaign()'::regprocedure), E'\r', '');
  if src !~ '20261163880000' then
    src := pg_temp.ganti(src, $p$    if st in ('inactive','cleared') then$p$, $p$    if st in ('inactive','cleared','closed' /* 20261163880000 */) then$p$, 1, 'jaga insert');
    src := pg_temp.ganti(src, $p$  -- Hanya perpindahan MAJU yang dilarang.$p$,
      $p$  -- 20261163880000: campaign Closed - Expired sudah final dan tidak dapat dikembalikan.
  if st = 'closed' and old.status = 'expired' and new.status is distinct from old.status then
    raise exception 'Campaign % sudah Closed; dokumen Expired sudah final dan tidak dapat diubah statusnya', kode using errcode = 'P0001';
  end if;

  -- Hanya perpindahan MAJU yang dilarang.$p$, 1, 'jaga closed');
    execute src;
  end if;

  -- ---- Dokumen tanpa Customer Master ikut Expired saat campaign Closed -------------------------
  src := replace(pg_get_functiondef('rc_private.jaga_customer_master_klaim()'::regprocedure), E'\r', '');
  if src !~ '20261163880000' then
    src := pg_temp.ganti(src, $p$    raise exception using
      errcode = '23503',$p$, $p$    -- 20261163880000: campaign Closed menghanguskan seluruh Not Yet, termasuk yang tanpa master.
    if old.status = 'not_yet' and new.status = 'expired'
       and exists(select 1 from public.campaigns ca where ca.id = new.campaign_id and ca.status = 'closed') then
      return new;
    end if;
    raise exception using
      errcode = '23503',$p$, 1, 'jaga master');
    execute src;
  end if;

  -- ---- Compile menolak campaign Closed ----------------------------------------------------------
  src := replace(pg_get_functiondef('rc_private.compile_upload(jsonb,uuid)'::regprocedure), E'\r', '');
  if src !~ '''closed''' then
    src := pg_temp.ganti(src, $p$v_camp.status in ('inactive','cleared')$p$, $p$v_camp.status in ('inactive','cleared','closed' /* 20261163880000 */)$p$, 1, 'compile');
    execute src;
  end if;
  src := replace(pg_get_functiondef('public.rc_compile_preview(jsonb)'::regprocedure), E'\r', '');
  if src !~ '''closed''' then
    src := pg_temp.ganti(src, $p$v_camp.status in ('inactive','cleared')$p$, $p$v_camp.status in ('inactive','cleared','closed' /* 20261163880000 */)$p$, 1, 'preview');
    execute src;
  end if;

  -- ---- Campaign Master menerima status closed ---------------------------------------------------
  src := replace(pg_get_functiondef('rc_private.campaign_upsert(jsonb)'::regprocedure), E'\r', '');
  if src !~ '''closed''' then
    src := pg_temp.ganti(src, $p$st not in('active','inactive','cleared')$p$, $p$st not in('active','inactive','cleared','closed' /* 20261163880000 */)$p$, 1, 'upsert');
    src := pg_temp.ganti(src, $p$'Status campaign harus active, inactive atau cleared pada %'$p$, $p$'Status campaign harus active, inactive, cleared atau closed pada %'$p$, 1, 'upsert pesan');
    execute src;
  end if;

  -- ---- Email Pengajuan: CC wajib jenis Campaign Closed ------------------------------------------
  src := replace(pg_get_functiondef('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text,jsonb)'::regprocedure), E'\r', '');
  if src !~ '''closed''' then
    src := pg_temp.ganti(src, $p$'debtor' /* 20261163170000 */];$p$, $p$'debtor' /* 20261163170000 */, 'closed' /* 20261163880000 */];$p$, 1, 'pengajuan simpan');
    execute src;
  end if;
end $tambal$;

-- ==========================================================================================
-- 1. Campaign Closed
-- ==========================================================================================
create or replace function rc_private.campaign_tutup(p_campaign uuid)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_aktor uuid := auth.uid(); ca public.campaigns; v_batch text; v_nama text; n integer := 0; v_tot numeric := 0; v_dep jsonb := '[]';
  v_png public.email_settings; v_to text[] := '{}'; v_cc text[] := '{}'; v_pen jsonb; v_isi text; v_baris text := ''; d record; v_uji boolean; v_subjek text; v_spanduk text := '';
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;text-align:left;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
begin
  select * into ca from public.campaigns where id = p_campaign;
  select coalesce(nullif(full_name, ''), user_code, '-') into v_nama from public.profiles where id = v_aktor;

  if exists(select 1 from public.claims where campaign_id = ca.id and status = 'not_yet' and archived_at is null) then
    begin
      v_batch := rc_private.batch_kejadian(rc_private.next_batch('04'), '3');
    exception when no_data_found then
      raise exception 'Campaign hanya dapat di-Closed oleh pengguna RC yang aktif' using errcode = '42501';
    end;

    with x as (
      update public.claims c set status = 'expired', pending_approval = null, previous_status = null, hold_approved_at = now(),
             batch_clearing = v_batch, batch_event_code = '3', batch_event_at = now(), version_no = c.version_no + 1, updated_at = now()
       where c.campaign_id = ca.id and c.status = 'not_yet' and c.archived_at is null
      returning c.id, c.depot_id, c.cb_net),
    h as (
      insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, batch, reason)
      select x.id, v_aktor, 'not_yet', 'expired', 'campaign_closed', v_batch, left('Campaign ' || ca.campaign_code || ' ditutup (closed)', 300) from x
      returning claim_id),
    o as (
      update public.rc_clearing_offers t set status = 'cancelled', acted_by = v_aktor, acted_at = now()
        from x where t.claim_id = x.id and t.status in ('offered', 'overdue')
      returning t.claim_id)
    select coalesce(jsonb_agg(jsonb_build_object('depotId', z.depot_id, 'kode', dp.depot_code, 'nama', coalesce(nullif(dp.depot_name, ''), dp.depot_code), 'qty', z.n, 'cb', z.cb)
             order by dp.depot_code), '[]'::jsonb), coalesce(sum(z.n), 0), coalesce(sum(z.cb), 0)
      into v_dep, n, v_tot
      from (select x.depot_id, count(*) n, coalesce(trunc(sum(x.cb_net)), 0) cb from x group by x.depot_id) z
      join public.depots dp on dp.id = z.depot_id;
  end if;

  insert into public.activity_logs(actor_id, event_type, entity_id, details, module, tab, process_stage, batch_no)
  values (v_aktor, 'campaign_closed', ca.id, jsonb_build_object(
      'detail', 'Campaign ' || ca.campaign_code || ' ditutup (closed): ' || n || ' dokumen Not Yet menjadi Expired di ' || jsonb_array_length(v_dep) || ' depot, Rp ' || rc_private.angka(v_tot),
      'kodeCampaign', ca.campaign_code, 'namaCampaign', ca.campaign_name, 'jumlah', n, 'totalCb', v_tot, 'batch', v_batch,
      'depot', (select coalesce(jsonb_agg(e - 'depotId'), '[]'::jsonb) from jsonb_array_elements(v_dep) e)), 'keyMaster', 'campaign', 'closed', v_batch);

  -- Email: satu email untuk seluruh depot yang dihanguskan, lewat sakelar Email Pengajuan.
  -- Kegagalannya tidak membatalkan penutupan; jejaknya dicatat.
  select * into v_png from public.email_settings where jenis = 'pengajuan';
  if n > 0 and coalesce(v_png.aktif, false) then
    begin
      v_uji := coalesce(v_png.mode_uji, false) and coalesce(btrim(v_png.email_uji), '') <> '';
      -- Penerima dikumpulkan dari setiap depot: TO depot, CC OSC / Supervisor depot + CC semua email + CC wajib Campaign Closed.
      for d in select (e->>'depotId')::uuid id from jsonb_array_elements(v_dep) e loop
        v_pen := rc_private.email_pengajuan_penerima(d.id, 'closed');
        v_to := v_to || array(select jsonb_array_elements_text(v_pen->'to'));
        v_cc := v_cc || array(select jsonb_array_elements_text(v_pen->'cc'));
      end loop;
      v_to := array(select distinct x from unnest(v_to) x where coalesce(x, '') <> '');
      v_cc := array(select distinct x from unnest(v_cc) x where coalesce(x, '') <> '' and not (x = any(v_to)));

      for d in select e->>'kode' kode, e->>'nama' nama, (e->>'qty')::integer qty, (e->>'cb')::numeric cb from jsonb_array_elements(v_dep) e loop
        v_baris := v_baris || '<tr><td style="' || v_td || '">' || rc_private.html_aman(d.kode || ' - ' || d.nama) || '</td>'
          || '<td style="' || v_td || 'text-align:right;">' || rc_private.angka(d.qty) || '</td>'
          || '<td style="' || v_td || 'text-align:right;white-space:nowrap;">Rp ' || rc_private.angka(d.cb) || '</td></tr>';
      end loop;
      v_isi := rc_private.email_kepala('Campaign Closed - ' || ca.campaign_code, coalesce(ca.campaign_name, ''))
        || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
        || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#202124;">'
        || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
        || '<p style="line-height:1.6;">Campaign <strong>' || rc_private.html_aman(ca.campaign_code || ' - ' || coalesce(ca.campaign_name, '')) || '</strong> sudah ditutup (closed) '
        || 'sehingga semua toko yang outstanding dianggap hangus (expired). Penutupan campaign ini diproses oleh <strong>' || rc_private.html_aman(v_nama) || '</strong>.</p>'
        || '<p style="line-height:1.6;">Berikut di bawah ini details depot yang dihanguskan (expired):</p>'
        || '<table style="border-collapse:collapse;width:100%;"><thead><tr><th style="' || v_th || '">Kode Depot - Nama Depot</th>'
        || '<th style="' || v_th || 'text-align:right;">Total Qty Expired</th><th style="' || v_th || 'text-align:right;">Total Value Expired</th></tr></thead><tbody>'
        || v_baris
        || '<tr><td style="' || v_td || 'font-weight:bold;">Total</td><td style="' || v_td || 'text-align:right;font-weight:bold;">' || rc_private.angka(n) || '</td>'
        || '<td style="' || v_td || 'text-align:right;font-weight:bold;white-space:nowrap;">Rp ' || rc_private.angka(v_tot) || '</td></tr></tbody></table>'
        || '<p style="line-height:1.6;background:#fdecef;border-left:4px solid #C8102E;padding:10px 12px;margin:16px 0 0;color:#8a0d20;">'
        || 'Mohon untuk team depo untuk tidak melakukan claim atas campaign di atas dan sistem RC akan otomatis menolak seluruh claim di atas '
        || 'karena sudah final dihanguskan (expired).</p>'
        || '</td></tr></table>';
      v_subjek := 'Campaign Closed - ' || ca.campaign_code || ' ' || coalesce(ca.campaign_name, '');

      if coalesce(array_length(v_to, 1), 0) = 0 and not v_uji then
        insert into public.activity_logs(actor_id, event_type, details)
        values (v_aktor, 'email_pengajuan_tanpa_tujuan', jsonb_build_object('aksi', 'closed', 'sebab', 'Alamat email depot belum diisi di Depot Master'));
      else
        if v_uji then
          v_spanduk := '<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;padding:12px 16px;border-radius:8px;margin-bottom:12px;max-width:640px;">'
            || '<div style="font-size:13px;font-weight:bold;margin-bottom:6px;">MODE UJI &mdash; surat ini TIDAK dikirim ke depot</div>'
            || '<div style="font-size:11px;line-height:1.7;color:#d1d5db;">Seharusnya dikirim ke<br><strong style="color:#ffffff;">TO</strong> (' || coalesce(array_length(v_to, 1), 0) || '): '
            || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA ALAMAT DEPOT DI DEPOT MASTER')) || '<br>'
            || '<strong style="color:#ffffff;">CC</strong> (' || coalesce(array_length(v_cc, 1), 0) || '): ' || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), 'tidak ada'))
            || '</div></div>';
          v_subjek := '[UJI] ' || v_subjek; v_to := array[btrim(v_png.email_uji)]; v_cc := '{}';
        end if;
        insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, konteks)
        values ('pengajuan', v_to, v_cc, v_subjek, rc_private.email_outlook(v_spanduk || v_isi),
          jsonb_build_object('aksi', 'closed', 'kategori', 'closed', 'kodeCampaign', ca.campaign_code, 'batch', v_batch, 'jumlah', n, 'modeUji', v_uji));
      end if;
    exception when others then
      insert into public.activity_logs(actor_id, event_type, details)
      values (v_aktor, 'email_pengajuan_gagal', jsonb_build_object('aksi', 'closed', 'sebab', left(sqlerrm, 300)));
    end;
  end if;

  return jsonb_build_object('expired', n, 'totalCb', v_tot, 'batch', v_batch, 'depot', v_dep);
end $f$;

create or replace function rc_private.campaign_status_kunci()
returns trigger language plpgsql security definer set search_path to '' as $f$
begin
  -- "untuk campaign yang udah cleared maka statusnya auto berubah jadi closed".
  if new.status = 'cleared' then new.status := 'closed'; end if;
  if tg_op = 'UPDATE' and old.status = 'closed' and new.status is distinct from 'closed' then
    raise exception 'Campaign % sudah Closed dan tidak dapat dibuka kembali', old.campaign_code using errcode = 'P0001';
  end if;
  return new;
end $f$;

create or replace function rc_private.campaign_tutup_trg()
returns trigger language plpgsql security definer set search_path to '' as $f$
begin
  perform rc_private.campaign_tutup(new.id);
  return null;
end $f$;

revoke all on function rc_private.campaign_tutup(uuid), rc_private.campaign_status_kunci(), rc_private.campaign_tutup_trg() from public, anon, authenticated;

drop trigger if exists campaign_closed_kunci on public.campaigns;
create trigger campaign_closed_kunci before insert or update of status on public.campaigns for each row execute function rc_private.campaign_status_kunci();
drop trigger if exists campaign_ditutup on public.campaigns;
create trigger campaign_ditutup after update of status on public.campaigns for each row
  when (new.status = 'closed' and old.status is distinct from 'closed') execute function rc_private.campaign_tutup_trg();

-- Campaign cleared yang sudah ada menjadi closed (dan Not Yet-nya Expired) lewat trigger di atas.
update public.campaigns set status = 'closed' where status = 'cleared';

-- Pratinjau untuk konfirmasi di layar Campaign Master; tidak mengubah apa pun.
create or replace function public.rc_campaign_tutup_cek(p_kode text)
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare ca public.campaigns;
begin
  perform rc_private.require_tab('keyMaster.campaign');
  select * into ca from public.campaigns where campaign_code = btrim(coalesce(p_kode, ''));
  if not found then raise exception 'Campaign % tidak ditemukan', p_kode; end if;
  return jsonb_build_object('status', 'success', 'kode', ca.campaign_code, 'nama', ca.campaign_name, 'statusSekarang', ca.status,
    'jumlah', (select count(*) from public.claims c where c.campaign_id = ca.id and c.status = 'not_yet' and c.archived_at is null),
    'totalCb', (select coalesce(trunc(sum(c.cb_net)), 0) from public.claims c where c.campaign_id = ca.id and c.status = 'not_yet' and c.archived_at is null),
    'depot', coalesce((select jsonb_agg(jsonb_build_object('kode', z.depot_code, 'nama', z.depot_name, 'qty', z.n, 'cb', z.cb) order by z.depot_code)
       from (select d.depot_code, d.depot_name, count(*) n, coalesce(trunc(sum(c.cb_net)), 0) cb from public.claims c join public.depots d on d.id = c.depot_id
              where c.campaign_id = ca.id and c.status = 'not_yet' and c.archived_at is null group by 1, 2) z), '[]'::jsonb));
end $f$;

-- ==========================================================================================
-- 2. Amend Doc > Change Status (Expired -> Not Yet)
-- ==========================================================================================
create or replace function rc_private.change_status_baris(p_doc text)
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare v text := upper(btrim(coalesce(p_doc, ''))); r record;
begin
  if v = '' then return jsonb_build_object('noDoc', '', 'galat', 'No Doc wajib diisi'); end if;
  select c.id, c.no_doc, c.status, c.archived_at, c.cb_net, c.version_no, c.depot_id, c.customer_id, d.depot_code, d.depot_name,
         coalesce(cu.customer_code, c.source_customer_code, '') kode_toko, coalesce(cu.customer_name, '') nama_toko, ca.campaign_code, ca.campaign_name, ca.status camp_status
    into r
    from public.claims c join public.depots d on d.id = c.depot_id join public.campaigns ca on ca.id = c.campaign_id left join public.customers cu on cu.id = c.customer_id
   where upper(c.no_doc) = v order by c.archived_at nulls first limit 1;
  if not found then return jsonb_build_object('noDoc', v, 'galat', 'Dokumen tidak ditemukan'); end if;
  if r.archived_at is not null then return jsonb_build_object('noDoc', r.no_doc, 'galat', 'Dokumen sudah diarsipkan'); end if;
  if r.status <> 'expired' then
    return jsonb_build_object('noDoc', r.no_doc, 'galat', 'Status ' || rc_private.legacy_status(r.status) || '; hanya Expired yang dapat dikembalikan ke Not Yet'); end if;
  if r.camp_status = 'closed' then
    return jsonb_build_object('noDoc', r.no_doc, 'galat', 'Campaign ' || r.campaign_code || ' sudah Closed; Expired-nya final'); end if;
  if r.customer_id is null then
    return jsonb_build_object('noDoc', r.no_doc, 'galat', 'Customer Master ' || r.kode_toko || ' belum ada'); end if;
  return jsonb_build_object('claimId', r.id, 'noDoc', r.no_doc, 'statusDok', 'Expired', 'depotId', r.depot_id, 'kodeDepot', r.depot_code, 'namaDepot', r.depot_name,
    'kodeToko', r.kode_toko, 'namaToko', r.nama_toko, 'kodeCampaign', r.campaign_code, 'namaCampaign', r.campaign_name, 'cbNet', r.cb_net, 'versionNo', r.version_no);
end $f$;
revoke all on function rc_private.change_status_baris(text) from public, anon, authenticated;

create or replace function public.rc_change_status_cek(p_items jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' set statement_timeout to '90s' as $f$
begin
  perform rc_private.require_tab('compilation.changestatus');
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Daftar dokumen tidak valid'; end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Maksimal 200 dokumen sekali proses'; end if;
  return jsonb_build_object('status', 'success', 'rows', coalesce((
    select jsonb_agg(rc_private.change_status_baris(x.v->>'noDoc') - 'claimId' - 'depotId' order by x.o)
      from jsonb_array_elements(p_items) with ordinality x(v, o)), '[]'::jsonb));
end $f$;

create or replace function public.rc_change_status(p_items jsonb, p_alasan text default '')
returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '90s' set lock_timeout to '30s' as $f$
declare v_aktor uuid := auth.uid(); v_umum text := btrim(coalesce(p_alasan, '')); v_masalah text[] := '{}'; v_lihat text[] := '{}'; v_siap jsonb := '[]';
  x record; info jsonb; v_kode text; v_label text; v_alasan text; n integer := 0; v_nama text; v_dep uuid; v_isi text; v_baris text; v_tot numeric; v_n integer;
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;text-align:left;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
begin
  perform rc_private.require_tab('compilation.changestatus');
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Isi minimal satu No Doc'; end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Maksimal 200 dokumen sekali proses'; end if;

  -- Dokumen dikunci berurutan supaya dua proses yang berjalan bersamaan tidak saling menunggu.
  perform 1 from public.claims where upper(no_doc) in (select upper(btrim(coalesce(v->>'noDoc', ''))) from jsonb_array_elements(p_items) v) order by id for update;

  -- 1. Seluruh baris diperiksa dulu; satu salah = tidak ada yang diubah.
  for x in select v, o from jsonb_array_elements(p_items) with ordinality t(v, o) order by o loop
    v_kode := upper(btrim(coalesce(x.v->>'noDoc', '')));
    v_label := coalesce(nullif(v_kode, ''), 'Baris ' || x.o);
    if v_kode <> '' and v_kode = any(v_lihat) then v_masalah := v_masalah || (v_label || ': No Doc ganda di daftar'); continue; end if;
    v_lihat := v_lihat || v_kode;
    info := rc_private.change_status_baris(v_kode);
    if info ? 'galat' then v_masalah := v_masalah || (v_label || ': ' || (info->>'galat')); continue; end if;
    v_alasan := coalesce(nullif(btrim(coalesce(x.v->>'alasan', '')), ''), v_umum);
    if length(v_alasan) < 3 then v_masalah := v_masalah || (v_label || ': Alasan wajib diisi (minimal 3 karakter)'); continue; end if;
    if length(v_alasan) > 300 then v_masalah := v_masalah || (v_label || ': Alasan terlalu panjang (maksimal 300 karakter)'); continue; end if;
    v_siap := v_siap || (info || jsonb_build_object('alasan', v_alasan));
  end loop;
  if cardinality(v_masalah) > 0 then raise exception '%', array_to_string(v_masalah, '; '); end if;

  -- 2. Kembali ke Not Yet, seperti Reprocessing: perpanjangan dan batch Expired dikosongkan.
  for x in select v from jsonb_array_elements(v_siap) t(v) loop
    update public.claims set status = 'not_yet', previous_status = null, pending_approval = null,
           extend_so_start = null, extend_so_end = null, extend_billing_start = null, extend_billing_end = null,
           batch_clearing = null, status_changed_at = now() /* Remark Status Changed */, version_no = version_no + 1, updated_at = now()
     where id = (x.v->>'claimId')::uuid and status = 'expired';
    if not found then raise exception '%: dokumen berubah; periksa ulang', x.v->>'noDoc'; end if;
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    values ((x.v->>'claimId')::uuid, v_aktor, 'expired', 'not_yet', 'change_status', left('Change Status Expired -> Not Yet: ' || (x.v->>'alasan'), 300));
    n := n + 1;
  end loop;

  -- 3. Email per depot (saklar Email Pengajuan), lalu satu baris Log Activity.
  select coalesce(nullif(full_name, ''), user_code, '-') into v_nama from public.profiles where id = v_aktor;
  for v_dep in select distinct (e->>'depotId')::uuid from jsonb_array_elements(v_siap) e loop
    select string_agg('<tr><td style="' || v_td || 'white-space:nowrap;font-family:Consolas,monospace;">' || rc_private.html_aman(e->>'noDoc') || '</td>'
             || '<td style="' || v_td || '">' || rc_private.html_aman((e->>'kodeToko') || case when coalesce(e->>'namaToko', '') <> '' then ' - ' || (e->>'namaToko') else '' end) || '</td>'
             || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(e->>'kodeCampaign') || '</td>'
             || '<td style="' || v_td || 'text-align:right;white-space:nowrap;">Rp ' || rc_private.angka((e->>'cbNet')::numeric) || '</td>'
             || '<td style="' || v_td || '">' || rc_private.html_aman(e->>'alasan') || '</td></tr>', '' order by e->>'noDoc'),
           sum((e->>'cbNet')::numeric), count(*)
      into v_baris, v_tot, v_n
      from jsonb_array_elements(v_siap) e where (e->>'depotId')::uuid = v_dep;
    v_isi := rc_private.email_kepala('Change Status Doc - Claim Cashback Depo ' || (select coalesce(depot_name, depot_code) from public.depots where id = v_dep), v_n || ' dokumen')
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
      || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#202124;">'
      || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
      || '<p style="line-height:1.6;">Berikut dokumen claim cashback Depo <strong>' || rc_private.html_aman((select depot_code || ' - ' || coalesce(depot_name, '') from public.depots where id = v_dep))
      || '</strong> yang statusnya dikembalikan dari <strong>Expired</strong> ke <strong>Not Yet</strong> (Change Status), sehingga dapat diproses kembali.</p>'
      || '<p style="line-height:1.6;color:#5f6368;font-size:12px;">Diproses oleh <strong>' || rc_private.html_aman(v_nama) || '</strong> pada ' || rc_private.tgl_panjang(now()) || ' '
      || to_char(now() at time zone 'Asia/Jakarta', 'HH24:MI') || ' WIB &middot; ' || v_n || ' dokumen, total Net CB Rp ' || rc_private.angka(v_tot) || '.</p>'
      || '<table style="border-collapse:collapse;width:100%;margin-top:12px;"><thead><tr><th style="' || v_th || '">NO DOC</th><th style="' || v_th || '">TOKO</th>'
      || '<th style="' || v_th || '">CAMPAIGN</th><th style="' || v_th || 'text-align:right;">NET CB</th><th style="' || v_th || '">ALASAN</th></tr></thead><tbody>'
      || v_baris || '</tbody></table></td></tr></table>';
    begin
      perform rc_private.email_kejadian_antre('changestatus', 'changestatus', v_dep,
        'Change Status Doc - Claim Cashback Depo ' || (select coalesce(depot_name, depot_code) from public.depots where id = v_dep), v_isi, v_aktor, jsonb_build_object('qty', v_n));
    exception when others then
      insert into public.activity_logs(actor_id, depot_id, event_type, details)
      values (v_aktor, v_dep, 'email_pengajuan_gagal', jsonb_build_object('aksi', 'changestatus', 'sebab', left(sqlerrm, 300)));
    end;
  end loop;

  insert into public.activity_logs(actor_id, depot_id, event_type, details, module, tab, process_stage)
  values (v_aktor, case when (select count(distinct e->>'depotId') from jsonb_array_elements(v_siap) e) = 1 then (v_siap->0->>'depotId')::uuid end, 'change_status',
    jsonb_build_object('detail', 'Change Status: ' || n || ' dokumen Expired kembali ke Not Yet', 'jumlah', n,
      'dokumen', (select jsonb_agg(jsonb_build_object('noDoc', e->>'noDoc', 'kodeDepot', e->>'kodeDepot', 'kodeToko', e->>'kodeToko', 'namaToko', e->>'namaToko',
                    'kodeCampaign', e->>'kodeCampaign', 'cbNet', (e->>'cbNet')::numeric, 'alasan', e->>'alasan')) from jsonb_array_elements(v_siap) e)),
    'compilation', 'changestatus', 'changestatus');

  return jsonb_build_object('status', 'success', 'berhasil', n, 'message', n || ' dokumen Expired kembali ke Not Yet.');
end $f$;

create or replace function public.rc_change_status_riwayat()
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  perform rc_private.require_tab('compilation.changestatus');
  return jsonb_build_object('status', 'success', 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('waktu', z.waktu, 'oleh', z.oleh, 'noDoc', z.v->>'noDoc', 'kodeDepot', z.v->>'kodeDepot', 'kodeToko', z.v->>'kodeToko',
             'namaToko', z.v->>'namaToko', 'kodeCampaign', z.v->>'kodeCampaign', 'cbNet', (z.v->>'cbNet')::numeric, 'alasan', z.v->>'alasan') order by z.created_at desc, z.v->>'noDoc')
      from (select l.created_at, t.v, to_char(l.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') waktu, coalesce(nullif(p.full_name, ''), p.user_code, '-') oleh
              from (select * from public.activity_logs where event_type = 'change_status' order by created_at desc limit 100) l
              left join public.profiles p on p.id = l.actor_id
             cross join lateral jsonb_array_elements(coalesce(l.details->'dokumen', '[]'::jsonb)) t(v)
             order by l.created_at desc, t.v->>'noDoc' limit 200) z), '[]'::jsonb));
end $f$;

-- ---- Remark "Status Changed" ----------------------------------------------------------------------
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean, p_amended_at timestamptz,
  p_amend_dari text[], p_rek_diubah boolean, p_special boolean, p_dc boolean, p_status boolean)
returns text language sql stable as $f$
  select nullif(concat_ws(', ',
    case when coalesce(array_length(p_amend_dari, 1), 0) > 0 then rc_private.claim_remark_amend(p_amend_dari)
         when p_amended_at is not null then 'Doc Amendment' end,
    case when p_reprocessed_at is not null or p_ada_reprocess then 'Document Reprocessed' end,
    case when p_cb_berubah then 'CB Type Changed' end,
    case when coalesce(p_rek_diubah, false) then 'Bank Account Changed' end,
    case when coalesce(p_special, false) then 'Special Claims' end,
    case when coalesce(p_dc, false) then 'DC changed' end,
    case when coalesce(p_status, false) then 'Status Changed' end), '');
$f$;

create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean, p_amended_at timestamptz,
  p_amend_dari text[], p_rek_diubah boolean, p_special boolean, p_dc boolean)
returns text language sql stable as $f$
  select rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, p_amended_at, p_amend_dari, p_rek_diubah, p_special, p_dc, false);
$f$;

-- Pembentuk Remark yang sudah meneruskan tanda DC changed ikut meneruskan tanda Status Changed.
do $remark$
declare f oid; src text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('public', 'rc_private') and p.prosrc like '%c.dc_changed_at is not null /* 20261163810000 */)%'
              and p.prosrc not like '%status_changed_at%' loop
    src := replace(pg_get_functiondef(f), E'\r', '');
    src := replace(src, 'c.dc_changed_at is not null /* 20261163810000 */)', 'c.dc_changed_at is not null /* 20261163810000 */, c.status_changed_at is not null /* 20261163880000 */)');
    execute src;
  end loop;
end $remark$;

-- Dokumen yang sudah dikembalikan sebelum tanda ini ada.
update public.claims c set status_changed_at = h.t
  from (select claim_id, max(created_at) t from public.claim_status_history where action = 'change_status' group by 1) h
 where h.claim_id = c.id and c.status_changed_at is null;

revoke all on function public.rc_campaign_tutup_cek(text), public.rc_change_status_cek(jsonb), public.rc_change_status(jsonb, text), public.rc_change_status_riwayat() from public, anon;
grant execute on function public.rc_campaign_tutup_cek(text), public.rc_change_status_cek(jsonb), public.rc_change_status(jsonb, text), public.rc_change_status_riwayat() to authenticated, service_role;

notify pgrst, 'reload schema';

do $cek$ begin
  if pg_get_functiondef('rc_private.jaga_status_campaign()'::regprocedure) !~ '''closed''' then raise exception 'GAGAL: jaga'; end if;
  if pg_get_functiondef('rc_private.tab_rights(uuid,text)'::regprocedure) !~ 'compilation.changestatus' then raise exception 'GAGAL: tab_rights'; end if;
  if pg_get_functiondef('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text,jsonb)'::regprocedure) !~ '''closed''' then raise exception 'GAGAL: CC Campaign Closed'; end if;
  if exists(select 1 from public.campaigns where status = 'cleared') then raise exception 'GAGAL: masih ada campaign cleared'; end if;
  if (select count(*) from pg_proc where prosrc like '%c.status_changed_at is not null /* 20261163880000 */)%') <> 3 then raise exception 'GAGAL: Remark Status Changed'; end if;
end $cek$;
