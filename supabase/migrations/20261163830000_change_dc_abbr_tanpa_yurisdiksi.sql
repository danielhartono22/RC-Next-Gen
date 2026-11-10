-- ==========================================================================================
-- Change DC: No Doc ikut abbr depot baru, tanpa yurisdiksi; Amend Doc bawaan OSC
-- ==========================================================================================
-- Pemilik, 9 November 2026, atas pertanyaan sesudah 20261163810000:
-- * "tidak ada no doc, pake code customer, depot baru, lalu abbr ikut kode depot baru": input tetap Kode
--   Toko + Depot Baru; No Doc dokumen yang pindah memakai abbr depot baru (NPC/CMP/JAS/.. -> NPC/CMP/WNH/..).
--   Nomor yang sudah terpakai diganti nomor baru dari rc_private.next_document. Done dan Expired tetap
--   di depot lama dengan No Doc lama dan Remark "DC changed".
-- * Nomor lama disimpan di claims.no_doc_lama: dokumen yang sudah dikirim ke Finance dapat ditransfer
--   dengan nomor lama, jadi Upload File Bank dan Mass Upload tetap mengenalinya.
-- * "tanpa yuridiksi semua bisa": cukup tab compilation.changedc.
-- * "untuk role osc semuanya sudah by default dicentang": compilation.amend dan compilation.changedc
--   bawaan hidup untuk OSC, termasuk akun yang sudah tersimpan tidak dicentang. Peran lain tetap bila
--   dicentang. Keduanya sub bab Amend Doc: Change Value dan Change DC.
-- Butuh 20261163810000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.claims add column if not exists no_doc_lama text;
create index if not exists claims_no_doc_lama_idx on public.claims (no_doc_lama) where no_doc_lama is not null;

update rc_private.tab_catalog set title = 'Amend Doc - Change Value' where code = 'compilation.amend';
update rc_private.tab_catalog set title = 'Amend Doc - Change DC' where code = 'compilation.changedc';

-- Akun OSC yang tersimpan tidak dicentang kembali ke bawaan (hidup). Sesudah ini centang manual tetap berlaku.
delete from rc_private.user_tab_access u using public.profiles p
 where p.id = u.user_id and lower(p.role) = 'osc' and u.tab_code = 'compilation.amend' and not u.allowed;

do $tambal$
declare src text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src !~ '20261163830000' then
    src := pg_temp.ganti(src,
      $p$or t.code='compilation.amend' /* 20261163140000: hanya bila dicentang */ or t.code='compilation.changedc' /* 20261163810000: hanya bila dicentang */$p$,
      $p$or (t.code in ('compilation.amend','compilation.changedc') and p.role<>'osc') /* 20261163830000: bawaan OSC; peran lain bila dicentang */$p$, 1, 'tab_rights');
    execute src;
  end if;

  src := replace(pg_get_functiondef('rc_private.clearing_bank_nilai(text,date,numeric,boolean,text,text,text,boolean,uuid,text)'::regprocedure), E'\r', '');
  if src !~ 'no_doc_lama' then
    src := pg_temp.ganti(src,
      $p$   where cl.archived_at is null and cl.no_doc in (v_doc, 'NPC/' || v_doc)
   order by (cl.no_doc = v_doc) desc limit 1;$p$,
      $p$   where cl.archived_at is null and (cl.no_doc in (v_doc, 'NPC/' || v_doc) or cl.no_doc_lama in (v_doc, 'NPC/' || v_doc)) /* 20261163830000 */
   order by (cl.no_doc = v_doc) desc, (cl.no_doc = 'NPC/' || v_doc) desc limit 1;$p$, 1, 'nilai');
    execute src;
  end if;
end $tambal$;

create or replace function public.rc_change_dc_cek(p_kode_toko text, p_depot_baru text)
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare cu public.customers; d public.depots;
begin
  perform rc_private.require_tab('compilation.changedc');
  select * into cu from public.customers where customer_code = upper(btrim(coalesce(p_kode_toko, ''))) and archived_at is null;
  if not found then raise exception 'Kode Toko "%" tidak ada di Customer Master', btrim(coalesce(p_kode_toko, '')); end if;
  select * into d from public.depots where depot_code = btrim(coalesce(p_depot_baru, '')) and archived_at is null and not coalesce(bukan_depot, false);
  if not found then raise exception 'Depot Baru wajib dipilih'; end if;
  return jsonb_build_object('status', 'success', 'kodeToko', cu.customer_code, 'namaToko', cu.customer_name, 'depotBaru', d.depot_code || ' - ' || d.depot_name,
    'abbrBaru', coalesce(d.abbr, ''),
    'asal', coalesce((select jsonb_agg(jsonb_build_object('kode', a.depot_code, 'nama', a.depot_name, 'aktif', a.aktif, 'cb', a.cb, 'selesai', a.selesai) order by a.depot_code)
                        from rc_private.change_dc_asal(cu.id, d.id) a), '[]'::jsonb));
end $f$;

create or replace function public.rc_change_dc(p_kode_toko text, p_depot_baru text, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_aktor uuid := auth.uid(); cu public.customers; d public.depots; a record; r record; v_reason text := btrim(coalesce(p_reason, ''));
  v_nama text; v_baris text; v_isi text; v_subjek text; n_pindah integer := 0; n_tetap integer := 0; n_nomor integer := 0; v_tot numeric := 0; v_rinci jsonb := '[]'; v_tujuan uuid;
  v_doc text; v_abbr text;
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;text-align:left;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
begin
  perform rc_private.require_tab('compilation.changedc');
  if length(v_reason) < 3 then raise exception 'Reason wajib diisi (minimal 3 karakter)'; end if;
  if length(v_reason) > 500 then raise exception 'Reason terlalu panjang (maksimal 500 karakter)'; end if;
  select * into cu from public.customers where customer_code = upper(btrim(coalesce(p_kode_toko, ''))) and archived_at is null for update;
  if not found then raise exception 'Kode Toko "%" tidak ada di Customer Master', btrim(coalesce(p_kode_toko, '')); end if;
  select * into d from public.depots where depot_code = btrim(coalesce(p_depot_baru, '')) and archived_at is null and not coalesce(bukan_depot, false);
  if not found then raise exception 'Depot Baru wajib dipilih'; end if;
  v_abbr := upper(btrim(coalesce(d.abbr, '')));
  if v_abbr = '' then raise exception 'Abbr depot % belum diisi di Depot Master', d.depot_code; end if;

  drop table if exists pg_temp._asal;
  create temp table _asal on commit drop as select * from rc_private.change_dc_asal(cu.id, d.id);
  if not exists(select 1 from _asal) then raise exception 'Toko % sudah berada di depot %', cu.customer_code, d.depot_code; end if;

  select coalesce(nullif(full_name, ''), user_code, '-') into v_nama from public.profiles where id = v_aktor;

  -- Yang selesai ditandai lebih dulu, supaya trigger tidak menautkan toko kembali ke depot lama.
  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  select c.id, v_aktor, c.status, c.status, 'change_dc', left('Change DC ' || x.depot_code || ' -> ' || d.depot_code || ' (dokumen tetap di depot lama): ' || v_reason, 300)
    from public.claims c join _asal x on x.depot_id = c.depot_id where c.customer_id = cu.id and c.status in ('done', 'expired');
  update public.claims c set dc_changed_at = now(), updated_at = now()
    from _asal x where x.depot_id = c.depot_id and c.customer_id = cu.id and c.status in ('done', 'expired');
  get diagnostics n_tetap = row_count;

  -- Dokumen yang pindah: depot dan abbr pada No Doc ikut depot baru.
  for r in select c.id, c.no_doc, c.status, x.depot_code asal, ca.campaign_code
             from public.claims c join _asal x on x.depot_id = c.depot_id join public.campaigns ca on ca.id = c.campaign_id
            where c.customer_id = cu.id and c.status not in ('done', 'expired') order by c.no_doc loop
    v_doc := regexp_replace(r.no_doc, '^(NPC/[^/]+/)[^/]+/', '\1' || v_abbr || '/');
    if v_doc <> r.no_doc and exists(select 1 from public.claims z where z.no_doc = v_doc) then
      v_doc := rc_private.next_document(v_abbr, r.campaign_code);
    end if;
    if v_doc <> r.no_doc then n_nomor := n_nomor + 1; end if;
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    values (r.id, v_aktor, r.status, r.status, 'change_dc', left('Change DC ' || r.asal || ' -> ' || d.depot_code
      || case when v_doc <> r.no_doc then ', No Doc ' || r.no_doc || ' -> ' || v_doc else '' end || ': ' || v_reason, 300));
    update public.claims set depot_id = d.id, no_doc = v_doc,
           no_doc_lama = case when v_doc <> r.no_doc then r.no_doc else no_doc_lama end, updated_at = now(), version_no = version_no + 1
     where id = r.id;
    n_pindah := n_pindah + 1;
  end loop;

  delete from public.customer_depots where customer_id = cu.id and depot_id <> d.id;
  insert into public.customer_depots(customer_id, depot_id) values (cu.id, d.id) on conflict do nothing;

  for a in select * from _asal order by depot_code loop
    v_tot := v_tot + a.cb;
    v_rinci := v_rinci || jsonb_build_object('dari', a.depot_code, 'dokumenPindah', a.aktif, 'totalCb', a.cb, 'dokumenTetap', a.selesai);
    v_baris := '<tr><td style="' || v_td || '">' || rc_private.html_aman(cu.customer_code) || '</td><td style="' || v_td || '">' || rc_private.html_aman(coalesce(cu.customer_name, ''))
      || '</td><td style="' || v_td || '">' || rc_private.html_aman(a.depot_code || ' - ' || a.depot_name) || '</td><td style="' || v_td || '">' || rc_private.html_aman(d.depot_code || ' - ' || coalesce(d.depot_name, ''))
      || '</td><td style="' || v_td || 'text-align:right;white-space:nowrap;">Rp ' || rc_private.angka(a.cb) || '</td><td style="' || v_td || '">' || rc_private.html_aman(v_reason) || '</td></tr>';
    v_isi := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#202124;">'
      || '<p>Berikut di bawah ini adalah toko dari Depot ' || rc_private.html_aman(a.depot_name) || ' yang dipindahkan ke Depot ' || rc_private.html_aman(coalesce(d.depot_name, d.depot_code))
      || ' oleh ' || rc_private.html_aman(v_nama) || '.</p>'
      || '<p style="color:#b3261e;font-weight:bold;">Peringatan, sebagai konsekuensi dari tindakan ini, depot sebelumnya tidak lagi memiliki akses sepenuhnya terhadap dokumen terkait toko tersebut.</p>'
      || '<table style="border-collapse:collapse;width:100%;"><thead><tr><th style="' || v_th || '">Kode Customer</th><th style="' || v_th || '">Nama Customer</th><th style="' || v_th || '">Old DC - Name</th><th style="' || v_th
      || '">New DC - Name</th><th style="' || v_th || 'text-align:right;">Total CB</th><th style="' || v_th || '">Reason</th></tr></thead><tbody>' || v_baris || '</tbody></table></div>';
    v_subjek := 'Change DC - Toko ' || cu.customer_code || ' dari Depo ' || a.depot_name || ' ke Depo ' || coalesce(d.depot_name, d.depot_code);
    foreach v_tujuan in array array[a.depot_id, d.id] loop
      begin
        perform rc_private.email_kejadian_antre('changedc', 'changedc', v_tujuan, v_subjek, v_isi, v_aktor, jsonb_build_object('kodeToko', cu.customer_code));
      exception when others then
        insert into public.activity_logs(actor_id, depot_id, event_type, details)
        values (v_aktor, v_tujuan, 'email_pengajuan_gagal', jsonb_build_object('aksi', 'changedc', 'sebab', left(sqlerrm, 300)));
      end;
    end loop;
  end loop;

  insert into public.activity_logs(actor_id, depot_id, event_type, entity_id, details, module, tab, process_stage)
  values (v_aktor, d.id, 'change_dc', cu.id, jsonb_build_object(
      'detail', 'Change DC toko ' || cu.customer_code || ' ke ' || d.depot_code || ': ' || n_pindah || ' dokumen pindah (' || n_nomor || ' No Doc mengikuti abbr ' || v_abbr || '), ' || n_tetap || ' dokumen selesai tetap di depot lama',
      'kodeToko', cu.customer_code, 'namaToko', cu.customer_name, 'ke', d.depot_code, 'asal', v_rinci, 'reason', v_reason), 'compilation', 'changedc', 'changedc');

  return jsonb_build_object('status', 'success', 'dipindah', n_pindah, 'tetap', n_tetap, 'noDocBerubah', n_nomor, 'totalCb', v_tot,
    'message', 'Toko ' || cu.customer_code || ' pindah ke depot ' || d.depot_code || ': ' || n_pindah || ' dokumen pindah (No Doc mengikuti abbr ' || v_abbr || '), ' || n_tetap || ' dokumen Done / Expired tetap di depot lama (Remark DC changed).');
end $f$;

do $cek$ begin
  if pg_get_functiondef('public.rc_change_dc(text,text,text)'::regprocedure) ~ 'can_access' then raise exception 'GAGAL: masih yurisdiksi'; end if;
  if pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure) !~ '20261163830000' then raise exception 'GAGAL: tab_rights'; end if;
  if pg_get_functiondef('rc_private.clearing_bank_nilai(text,date,numeric,boolean,text,text,text,boolean,uuid,text)'::regprocedure) !~ 'no_doc_lama' then raise exception 'GAGAL: nilai'; end if;
end $cek$;
