-- ==========================================================================================
-- Document Center > Change DC: memindahkan toko ke depot lain
-- ==========================================================================================
-- Pemilik, 9 November 2026. Input Kode Toko, Depot Baru, Reason. Tab compilation.changedc (hanya bila
-- dicentang di Access Management). Yang dilakukan, dalam satu transaksi:
-- * Master toko (customer_depots) pindah sepenuhnya ke depot baru.
-- * Dokumen yang belum selesai (bukan Done / Expired, termasuk yang diarsip supaya saat dikembalikan
--   tidak muncul di depot lama) pindah ke depot baru. No Doc tidak berubah.
-- * Dokumen Done tetap di depot lama dengan Remark "DC changed". Expired diperlakukan sama: tahap akhir,
--   setara Done. Trigger tautkan_customer_depot tidak lagi menautkan toko ke depot lama lewat dokumen ini.
-- * Satu baris Log Activity per proses, riwayat per dokumen, dan email ke depot asal dan depot tujuan.
-- Pemanggil harus punya jangkauan atas depot asal. Depot tujuan bebas.
-- Butuh 20261163790000. Aman dijalankan berulang.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

alter table public.claims add column if not exists dc_changed_at timestamptz;

insert into rc_private.tab_catalog(code, module, tab, permission, title, label, key)
select 'compilation.changedc', 'compilation', 'changedc', 'view_compilation', 'Change DC', t.label, t.key
  from rc_private.tab_catalog t where t.code = 'compilation.list'
   and not exists(select 1 from rc_private.tab_catalog where code = 'compilation.changedc');

-- Remark: satu sumber, ditambah "DC changed".
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean, p_cb_berubah boolean, p_amended_at timestamptz,
  p_amend_dari text[], p_rek_diubah boolean, p_special boolean, p_dc boolean)
returns text language sql stable set search_path to '' as $f$
  select nullif(concat_ws(', ', nullif(rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, p_amended_at, p_amend_dari, p_rek_diubah, p_special), ''),
                          case when coalesce(p_dc, false) then 'DC changed' end), '');
$f$;

do $tambal$
declare src text; f text;
begin
  src := replace(pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure), E'\r', '');
  if src !~ 'compilation.changedc' then
    src := pg_temp.ganti(src, $p$or t.code='compilation.amend' /* 20261163140000: hanya bila dicentang */$p$,
      $p$or t.code='compilation.amend' /* 20261163140000: hanya bila dicentang */ or t.code='compilation.changedc' /* 20261163810000: hanya bila dicentang */$p$, 1, 'tab_rights');
    execute src;
  end if;

  src := replace(pg_get_functiondef('rc_private.claim_remark(public.claims)'::regprocedure), E'\r', '');
  if src !~ 'dc_changed_at' then
    src := pg_temp.ganti(src, $p$c.adhoc_lanjut = 'done' /* 20261163440000 */)$p$, $p$c.adhoc_lanjut = 'done' /* 20261163440000 */, c.dc_changed_at is not null /* 20261163810000 */)$p$, 1, 'claim_remark');
    execute src;
  end if;
  foreach f in array array['public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', 'public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)'] loop
    src := replace(pg_get_functiondef(f::regprocedure), E'\r', '');
    if src !~ 'dc_changed_at' then
      src := pg_temp.ganti(src, $p$c.adhoc_lanjut = 'done' /* 20261163440000 */)$p$, $p$c.adhoc_lanjut = 'done' /* 20261163440000 */, c.dc_changed_at is not null /* 20261163810000 */)$p$, 1, f);
      execute src;
    end if;
  end loop;

  src := replace(pg_get_functiondef('rc_private.tautkan_customer_depot_klaim()'::regprocedure), E'\r', '');
  if src !~ 'dc_changed_at' then
    src := pg_temp.ganti(src, $p$ and b.archived_at is null$p$, $p$ and b.archived_at is null and b.dc_changed_at is null /* 20261163810000: Done yang tertinggal di depot lama */$p$, 1, 'tautkan');
    execute src;
  end if;
end $tambal$;

-- Depot asal toko: depot master dan depot dokumen, selain depot baru.
create or replace function rc_private.change_dc_asal(p_customer uuid, p_baru uuid)
returns table(depot_id uuid, depot_code text, depot_name text, aktif bigint, cb numeric, selesai bigint)
language sql stable security definer set search_path to '' as $f$
  select d.id, d.depot_code, coalesce(nullif(d.depot_name, ''), d.depot_code),
         count(c.id) filter (where c.status not in ('done', 'expired')),
         coalesce(trunc(sum(c.cb_net) filter (where c.status not in ('done', 'expired'))), 0),
         count(c.id) filter (where c.status in ('done', 'expired'))
    from public.depots d
    left join public.claims c on c.depot_id = d.id and c.customer_id = p_customer
   where d.id <> p_baru
     and (exists(select 1 from public.customer_depots cd where cd.customer_id = p_customer and cd.depot_id = d.id)
          or exists(select 1 from public.claims x where x.customer_id = p_customer and x.depot_id = d.id and x.status not in ('done', 'expired')))
   group by d.id, d.depot_code, d.depot_name;
$f$;
revoke all on function rc_private.change_dc_asal(uuid, uuid) from public, anon, authenticated;

-- Pratinjau untuk layar; tidak mengubah apa pun.
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
    'asal', coalesce((select jsonb_agg(jsonb_build_object('kode', a.depot_code, 'nama', a.depot_name, 'aktif', a.aktif, 'cb', a.cb, 'selesai', a.selesai,
                                                          'bolehAkses', rc_private.can_access(a.depot_id)) order by a.depot_code)
                        from rc_private.change_dc_asal(cu.id, d.id) a), '[]'::jsonb));
end $f$;

create or replace function public.rc_change_dc(p_kode_toko text, p_depot_baru text, p_reason text)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_aktor uuid := auth.uid(); cu public.customers; d public.depots; a record; v_reason text := btrim(coalesce(p_reason, ''));
  v_nama text; v_baris text; v_isi text; v_subjek text; n_pindah integer := 0; n_tetap integer := 0; v_tot numeric := 0; v_rinci jsonb := '[]'; v_tujuan uuid;
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

  drop table if exists pg_temp._asal;
  create temp table _asal on commit drop as select * from rc_private.change_dc_asal(cu.id, d.id);
  if not exists(select 1 from _asal) then raise exception 'Toko % sudah berada di depot %', cu.customer_code, d.depot_code; end if;
  if exists(select 1 from _asal x where not rc_private.can_access(x.depot_id)) then
    raise exception 'Depot asal di luar akses Anda: %', (select string_agg(x.depot_code, ', ') from _asal x where not rc_private.can_access(x.depot_id)) using errcode = '42501'; end if;

  select coalesce(nullif(full_name, ''), user_code, '-') into v_nama from public.profiles where id = v_aktor;

  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  select c.id, v_aktor, c.status, c.status, 'change_dc',
         left('Change DC ' || x.depot_code || ' -> ' || d.depot_code || case when c.status in ('done', 'expired') then ' (dokumen tetap di depot lama)' else '' end || ': ' || v_reason, 300)
    from public.claims c join _asal x on x.depot_id = c.depot_id where c.customer_id = cu.id;

  -- Yang selesai ditandai lebih dulu, supaya trigger tidak menautkan toko kembali ke depot lama.
  update public.claims c set dc_changed_at = now(), updated_at = now()
    from _asal x where x.depot_id = c.depot_id and c.customer_id = cu.id and c.status in ('done', 'expired');
  get diagnostics n_tetap = row_count;
  update public.claims c set depot_id = d.id, updated_at = now(), version_no = c.version_no + 1
    from _asal x where x.depot_id = c.depot_id and c.customer_id = cu.id and c.status not in ('done', 'expired');
  get diagnostics n_pindah = row_count;

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
      'detail', 'Change DC toko ' || cu.customer_code || ' ke ' || d.depot_code || ': ' || n_pindah || ' dokumen pindah, ' || n_tetap || ' dokumen selesai tetap di depot lama',
      'kodeToko', cu.customer_code, 'namaToko', cu.customer_name, 'ke', d.depot_code, 'asal', v_rinci, 'reason', v_reason), 'compilation', 'changedc', 'changedc');

  return jsonb_build_object('status', 'success', 'dipindah', n_pindah, 'tetap', n_tetap, 'totalCb', v_tot,
    'message', 'Toko ' || cu.customer_code || ' pindah ke depot ' || d.depot_code || ': ' || n_pindah || ' dokumen pindah, ' || n_tetap || ' dokumen selesai tetap di depot lama (Remark DC changed).');
end $f$;

-- Riwayat dan pilihan Depot Baru (seluruh depot, bukan hanya jangkauan pemanggil).
create or replace function public.rc_change_dc_riwayat()
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  perform rc_private.require_tab('compilation.changedc');
  return jsonb_build_object('status', 'success',
    'depot', coalesce((select jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', d.depot_name) order by d.depot_code)
                         from public.depots d where d.archived_at is null and not coalesce(d.bukan_depot, false)), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('waktu', z.waktu, 'oleh', z.oleh, 'detail', z.details->>'detail', 'kodeToko', z.details->>'kodeToko',
                                                          'namaToko', z.details->>'namaToko', 'ke', z.details->>'ke', 'reason', z.details->>'reason',
                                                          'dari', (select string_agg(x->>'dari', ', ') from jsonb_array_elements(z.details->'asal') x)) order by z.created_at desc)
                        from (select l.created_at, l.details, to_char(l.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') waktu, coalesce(nullif(p.full_name, ''), p.user_code, '-') oleh
                                from public.activity_logs l left join public.profiles p on p.id = l.actor_id
                               where l.event_type = 'change_dc' order by l.created_at desc limit 50) z), '[]'::jsonb));
end $f$;

revoke all on function public.rc_change_dc_cek(text, text), public.rc_change_dc(text, text, text), public.rc_change_dc_riwayat() from public, anon;
grant execute on function public.rc_change_dc_cek(text, text), public.rc_change_dc(text, text, text), public.rc_change_dc_riwayat() to authenticated, service_role;

do $cek$ begin
  if not coalesce((select pg_get_functiondef('rc_private.tab_rights(uuid)'::regprocedure) ~ 'compilation.changedc'), false) then raise exception 'GAGAL: tab_rights'; end if;
  if pg_get_functiondef('rc_private.tautkan_customer_depot_klaim()'::regprocedure) !~ 'dc_changed_at' then raise exception 'GAGAL: tautkan'; end if;
end $cek$;
