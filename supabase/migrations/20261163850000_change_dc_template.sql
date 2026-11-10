-- ==========================================================================================
-- Change DC lewat template: banyak toko sekali proses, mengikuti pola Change Value
-- ==========================================================================================
-- Pemilik, 9 November 2026: "buat change dc bisa upload dengan template sama seperti change value."
-- * Masukan: daftar { kodeToko, depotBaru, reason } ditambah reason umum untuk baris yang reason-nya
--   kosong. Maksimal 200 toko. Seluruh baris diperiksa dulu; satu salah = tidak ada yang dipindah.
-- * Depot Baru boleh berisi kode, "kode - nama", atau nama depot; huruf besar kecil tidak dibedakan.
-- * Email: satu per pasangan depot asal -> depot baru, satu baris tabel per toko, ke kedua depot.
-- * Log Activity satu baris per proses (details.toko berisi rincian per toko). Riwayat Change DC tetap
--   per toko dan masih membaca log lama yang berbentuk satu toko.
-- * Aturan pindahnya tidak berubah: master dan dokumen belum selesai pindah, No Doc mengikuti abbr depot
--   baru, Done dan Expired tetap di depot lama dengan Remark "DC changed", tanpa yurisdiksi.
-- * rc_change_dc dan rc_change_dc_cek kini menerima daftar. Versi satu toko dihapus: belum pernah ada di
--   prod dan layar tidak memakainya lagi.
-- Butuh 20261163830000. Aman dijalankan berulang.
-- ==========================================================================================

drop function if exists public.rc_change_dc_cek(text, text);
drop function if exists public.rc_change_dc(text, text, text);

create or replace function rc_private.change_dc_depot(p_teks text)
returns public.depots language sql stable security definer set search_path to '' as $f$
  with t as (select upper(btrim(coalesce(p_teks, ''))) isi)
  select d.* from public.depots d, t
   where d.archived_at is null and not coalesce(d.bukan_depot, false)
     and (upper(d.depot_code) = t.isi or upper(btrim(d.depot_name)) = t.isi or upper(d.depot_code) = btrim(split_part(t.isi, ' - ', 1)))
   order by (upper(d.depot_code) = t.isi) desc, (upper(btrim(d.depot_name)) = t.isi) desc
   limit 1;
$f$;

-- Pemeriksaan satu baris, dipakai layar dan proses supaya aturannya satu. Tidak mengubah apa pun.
create or replace function rc_private.change_dc_baris(p_kode text, p_depot text)
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
declare cu public.customers; d public.depots; v_kode text := upper(btrim(coalesce(p_kode, ''))); v_teks text := btrim(coalesce(p_depot, '')); v_abbr text; v_asal jsonb;
begin
  if v_kode = '' then return jsonb_build_object('kodeToko', '', 'galat', 'Kode Toko wajib diisi'); end if;
  select * into cu from public.customers where customer_code = v_kode and archived_at is null;
  if not found then return jsonb_build_object('kodeToko', v_kode, 'galat', 'Tidak ada di Customer Master'); end if;
  if v_teks = '' then return jsonb_build_object('kodeToko', v_kode, 'namaToko', cu.customer_name, 'galat', 'Depot Baru wajib diisi'); end if;
  d := rc_private.change_dc_depot(v_teks);
  if d.id is null then return jsonb_build_object('kodeToko', v_kode, 'namaToko', cu.customer_name, 'galat', 'Depot Baru "' || v_teks || '" tidak ada di Depot Master'); end if;
  v_abbr := upper(btrim(coalesce(d.abbr, '')));
  if v_abbr = '' then return jsonb_build_object('kodeToko', v_kode, 'namaToko', cu.customer_name, 'galat', 'Abbr depot ' || d.depot_code || ' belum diisi di Depot Master'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('depotId', a.depot_id, 'kode', a.depot_code, 'nama', a.depot_name, 'aktif', a.aktif, 'cb', a.cb, 'selesai', a.selesai) order by a.depot_code), '[]'::jsonb)
    into v_asal from rc_private.change_dc_asal(cu.id, d.id) a;
  if jsonb_array_length(v_asal) = 0 then
    return jsonb_build_object('kodeToko', v_kode, 'namaToko', cu.customer_name, 'galat',
      case when exists(select 1 from public.customer_depots x where x.customer_id = cu.id and x.depot_id = d.id)
           then 'Sudah berada di depot ' || d.depot_code else 'Belum memiliki depot asal' end);
  end if;
  return jsonb_build_object('customerId', cu.id, 'kodeToko', cu.customer_code, 'namaToko', cu.customer_name, 'depotId', d.id, 'depotKode', d.depot_code,
    'depotNama', coalesce(nullif(d.depot_name, ''), d.depot_code), 'depotBaru', d.depot_code || ' - ' || coalesce(d.depot_name, ''), 'abbrBaru', v_abbr, 'asal', v_asal);
end $f$;

-- Pemindahan satu toko yang sudah lolos pemeriksaan. Tanpa email dan Log Activity: keduanya per proses.
create or replace function rc_private.change_dc_pindah(p_info jsonb, p_reason text, p_aktor uuid)
returns jsonb language plpgsql security definer set search_path to '' as $f$
declare v_cust uuid := (p_info->>'customerId')::uuid; v_baru uuid := (p_info->>'depotId')::uuid; v_kode text := p_info->>'depotKode'; v_abbr text := p_info->>'abbrBaru';
  v_ids uuid[]; r record; v_doc text; n_pindah integer := 0; n_tetap integer := 0; n_nomor integer := 0;
begin
  select array_agg((x->>'depotId')::uuid) into v_ids from jsonb_array_elements(p_info->'asal') x;

  -- Yang selesai ditandai lebih dulu, supaya trigger tidak menautkan toko kembali ke depot lama.
  insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
  select c.id, p_aktor, c.status, c.status, 'change_dc', left('Change DC ' || d.depot_code || ' -> ' || v_kode || ' (dokumen tetap di depot lama): ' || p_reason, 300)
    from public.claims c join public.depots d on d.id = c.depot_id
   where c.customer_id = v_cust and c.depot_id = any(v_ids) and c.status in ('done', 'expired');
  update public.claims c set dc_changed_at = now(), updated_at = now()
   where c.customer_id = v_cust and c.depot_id = any(v_ids) and c.status in ('done', 'expired');
  get diagnostics n_tetap = row_count;

  -- Dokumen yang pindah: depot dan abbr pada No Doc ikut depot baru.
  for r in select c.id, c.no_doc, c.status, d.depot_code asal, ca.campaign_code
             from public.claims c join public.depots d on d.id = c.depot_id join public.campaigns ca on ca.id = c.campaign_id
            where c.customer_id = v_cust and c.depot_id = any(v_ids) and c.status not in ('done', 'expired') order by c.no_doc loop
    v_doc := regexp_replace(r.no_doc, '^(NPC/[^/]+/)[^/]+/', '\1' || v_abbr || '/');
    if v_doc <> r.no_doc and exists(select 1 from public.claims z where z.no_doc = v_doc) then
      v_doc := rc_private.next_document(v_abbr, r.campaign_code);
    end if;
    if v_doc <> r.no_doc then n_nomor := n_nomor + 1; end if;
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    values (r.id, p_aktor, r.status, r.status, 'change_dc', left('Change DC ' || r.asal || ' -> ' || v_kode
      || case when v_doc <> r.no_doc then ', No Doc ' || r.no_doc || ' -> ' || v_doc else '' end || ': ' || p_reason, 300));
    update public.claims set depot_id = v_baru, no_doc = v_doc,
           no_doc_lama = case when v_doc <> r.no_doc then r.no_doc else no_doc_lama end, updated_at = now(), version_no = version_no + 1
     where id = r.id;
    n_pindah := n_pindah + 1;
  end loop;

  delete from public.customer_depots where customer_id = v_cust and depot_id <> v_baru;
  insert into public.customer_depots(customer_id, depot_id) values (v_cust, v_baru) on conflict do nothing;

  return jsonb_build_object('customerId', v_cust, 'kodeToko', p_info->>'kodeToko', 'namaToko', p_info->>'namaToko', 'depotId', v_baru, 'ke', v_kode, 'depotNama', p_info->>'depotNama',
    'reason', p_reason, 'dipindah', n_pindah, 'tetap', n_tetap, 'noDocBerubah', n_nomor,
    'totalCb', (select coalesce(sum((x->>'cb')::numeric), 0) from jsonb_array_elements(p_info->'asal') x),
    'detail', n_pindah || ' dokumen pindah (' || n_nomor || ' No Doc mengikuti abbr ' || v_abbr || '), ' || n_tetap || ' dokumen selesai tetap di depot lama',
    'asal', (select jsonb_agg(jsonb_build_object('depotId', x->>'depotId', 'dari', x->>'kode', 'nama', x->>'nama', 'dokumenPindah', (x->>'aktif')::bigint,
                                                 'totalCb', (x->>'cb')::numeric, 'dokumenTetap', (x->>'selesai')::bigint))
               from jsonb_array_elements(p_info->'asal') x));
end $f$;

revoke all on function rc_private.change_dc_depot(text), rc_private.change_dc_baris(text, text), rc_private.change_dc_pindah(jsonb, text, uuid) from public, anon, authenticated;

-- Pratinjau untuk layar: satu panggilan untuk seluruh baris. Tidak mengubah apa pun.
create or replace function public.rc_change_dc_cek(p_items jsonb)
returns jsonb language plpgsql stable security definer set search_path to '' set statement_timeout to '90s' as $f$
begin
  perform rc_private.require_tab('compilation.changedc');
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Daftar toko tidak valid'; end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Maksimal 200 toko sekali proses'; end if;
  return jsonb_build_object('status', 'success', 'rows', coalesce((
    select jsonb_agg(rc_private.change_dc_baris(x.v->>'kodeToko', x.v->>'depotBaru') order by x.o)
      from jsonb_array_elements(p_items) with ordinality x(v, o)), '[]'::jsonb));
end $f$;

create or replace function public.rc_change_dc(p_items jsonb, p_reason text default '')
returns jsonb language plpgsql security definer set search_path to '' set statement_timeout to '90s' set lock_timeout to '30s' as $f$
declare v_aktor uuid := auth.uid(); v_umum text := btrim(coalesce(p_reason, '')); v_masalah text[] := '{}'; v_lihat text[] := '{}'; v_siap jsonb := '[]'; v_toko jsonb := '[]';
  x record; p record; info jsonb; v_kode text; v_label text; v_reason text; v_hasil jsonb; v_nama text; v_isi text; v_subjek text; v_tujuan uuid; v_daftar jsonb;
  n_toko integer; n_pindah bigint; n_tetap bigint; n_nomor bigint; v_tot numeric; v_depot uuid;
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;text-align:left;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
begin
  perform rc_private.require_tab('compilation.changedc');
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Isi minimal satu toko'; end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Maksimal 200 toko sekali proses'; end if;

  -- Toko dikunci berurutan supaya dua proses yang berjalan bersamaan tidak saling menunggu.
  perform 1 from public.customers
    where archived_at is null and customer_code in (select upper(btrim(coalesce(v->>'kodeToko', ''))) from jsonb_array_elements(p_items) v)
    order by customer_code for update;

  -- 1. Seluruh baris diperiksa dulu; satu salah = tidak ada yang dipindah.
  for x in select v, o from jsonb_array_elements(p_items) with ordinality t(v, o) order by o loop
    v_kode := upper(btrim(coalesce(x.v->>'kodeToko', '')));
    v_label := coalesce(nullif(v_kode, ''), 'Baris ' || x.o);
    if v_kode <> '' and v_kode = any(v_lihat) then v_masalah := v_masalah || (v_label || ': Kode Toko ganda di daftar'); continue; end if;
    v_lihat := v_lihat || v_kode;
    info := rc_private.change_dc_baris(v_kode, x.v->>'depotBaru');
    if info ? 'galat' then v_masalah := v_masalah || (v_label || ': ' || (info->>'galat')); continue; end if;
    v_reason := coalesce(nullif(btrim(coalesce(x.v->>'reason', '')), ''), v_umum);
    if length(v_reason) < 3 then v_masalah := v_masalah || (v_label || ': Reason wajib diisi (minimal 3 karakter)'); continue; end if;
    if length(v_reason) > 500 then v_masalah := v_masalah || (v_label || ': Reason terlalu panjang (maksimal 500 karakter)'); continue; end if;
    v_siap := v_siap || jsonb_build_object('info', info, 'reason', v_reason);
  end loop;
  if cardinality(v_masalah) > 0 then raise exception '%', array_to_string(v_masalah, '; '); end if;

  -- 2. Pindahkan.
  for x in select v from jsonb_array_elements(v_siap) t(v) loop
    begin
      v_hasil := rc_private.change_dc_pindah(x.v->'info', x.v->>'reason', v_aktor);
    exception when others then
      raise exception '%: %', x.v->'info'->>'kodeToko', sqlerrm;
    end;
    v_toko := v_toko || v_hasil;
  end loop;

  select count(*), sum((t.v->>'dipindah')::bigint), sum((t.v->>'tetap')::bigint), sum((t.v->>'noDocBerubah')::bigint), sum((t.v->>'totalCb')::numeric),
         case when count(distinct t.v->>'depotId') = 1 then min(t.v->>'depotId')::uuid end
    into n_toko, n_pindah, n_tetap, n_nomor, v_tot, v_depot from jsonb_array_elements(v_toko) t(v);
  select coalesce(nullif(full_name, ''), user_code, '-') into v_nama from public.profiles where id = v_aktor;

  -- 3. Email: satu per pasangan depot asal -> depot baru, ke kedua depot.
  for p in
    select a.v->>'depotId' asal_id, a.v->>'nama' asal_nama, t.v->>'depotId' baru_id, t.v->>'depotNama' baru_nama, count(*) n, min(t.v->>'kodeToko') kode_awal,
           left(string_agg(t.v->>'kodeToko', ', ' order by t.v->>'kodeToko'), 500) daftar,
           string_agg('<tr><td style="' || v_td || '">' || rc_private.html_aman(t.v->>'kodeToko') || '</td><td style="' || v_td || '">' || rc_private.html_aman(coalesce(t.v->>'namaToko', ''))
             || '</td><td style="' || v_td || '">' || rc_private.html_aman((a.v->>'dari') || ' - ' || (a.v->>'nama')) || '</td><td style="' || v_td || '">' || rc_private.html_aman((t.v->>'ke') || ' - ' || (t.v->>'depotNama'))
             || '</td><td style="' || v_td || 'text-align:right;white-space:nowrap;">Rp ' || rc_private.angka((a.v->>'totalCb')::numeric) || '</td><td style="' || v_td || '">' || rc_private.html_aman(t.v->>'reason') || '</td></tr>', '' order by t.v->>'kodeToko') baris
      from jsonb_array_elements(v_toko) t(v) cross join lateral jsonb_array_elements(t.v->'asal') a(v)
     group by 1, 2, 3, 4 order by 2, 4 loop
    v_isi := '<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#202124;">'
      || '<p>Berikut di bawah ini adalah toko dari Depot ' || rc_private.html_aman(p.asal_nama) || ' yang dipindahkan ke Depot ' || rc_private.html_aman(p.baru_nama)
      || ' oleh ' || rc_private.html_aman(v_nama) || '.</p>'
      || '<p style="color:#b3261e;font-weight:bold;">Peringatan, sebagai konsekuensi dari tindakan ini, depot sebelumnya tidak lagi memiliki akses sepenuhnya terhadap dokumen terkait toko tersebut.</p>'
      || '<table style="border-collapse:collapse;width:100%;"><thead><tr><th style="' || v_th || '">Kode Customer</th><th style="' || v_th || '">Nama Customer</th><th style="' || v_th || '">Old DC - Name</th><th style="' || v_th
      || '">New DC - Name</th><th style="' || v_th || 'text-align:right;">Total CB</th><th style="' || v_th || '">Reason</th></tr></thead><tbody>' || p.baris || '</tbody></table></div>';
    v_subjek := 'Change DC - ' || case when p.n = 1 then 'Toko ' || p.kode_awal else p.n || ' Toko' end || ' dari Depo ' || p.asal_nama || ' ke Depo ' || p.baru_nama;
    foreach v_tujuan in array array[p.asal_id::uuid, p.baru_id::uuid] loop
      begin
        perform rc_private.email_kejadian_antre('changedc', 'changedc', v_tujuan, v_subjek, v_isi, v_aktor, jsonb_build_object('kodeToko', p.daftar));
      exception when others then
        insert into public.activity_logs(actor_id, depot_id, event_type, details)
        values (v_aktor, v_tujuan, 'email_pengajuan_gagal', jsonb_build_object('aksi', 'changedc', 'sebab', left(sqlerrm, 300)));
      end;
    end loop;
  end loop;

  -- 4. Log Activity: satu baris per proses.
  select jsonb_agg(t.v - 'customerId' - 'depotId' - 'depotNama') into v_daftar from jsonb_array_elements(v_toko) t(v);
  insert into public.activity_logs(actor_id, depot_id, event_type, entity_id, details, module, tab, process_stage)
  values (v_aktor, v_depot, 'change_dc', case when n_toko = 1 then (v_toko->0->>'customerId')::uuid end, jsonb_build_object(
      'detail', case when n_toko = 1 then 'Change DC toko ' || (v_toko->0->>'kodeToko') || ' ke ' || (v_toko->0->>'ke') || ': ' || (v_toko->0->>'detail')
                     else 'Change DC: ' || n_toko || ' toko, ' || n_pindah || ' dokumen pindah, ' || n_tetap || ' dokumen selesai tetap di depot lama' end,
      'jumlah', n_toko, 'toko', v_daftar), 'compilation', 'changedc', 'changedc');

  return jsonb_build_object('status', 'success', 'toko', n_toko, 'dipindah', n_pindah, 'tetap', n_tetap, 'noDocBerubah', n_nomor, 'totalCb', v_tot,
    'message', case when n_toko = 1 then 'Toko ' || (v_toko->0->>'kodeToko') || ' pindah ke depot ' || (v_toko->0->>'ke') else n_toko || ' toko pindah' end
      || ': ' || n_pindah || ' dokumen pindah (No Doc mengikuti abbr depot baru), ' || n_tetap || ' dokumen Done / Expired tetap di depot lama (Remark DC changed).');
end $f$;

-- Riwayat per toko dan pilihan Depot Baru. Log lama (satu toko di details) tetap terbaca.
create or replace function public.rc_change_dc_riwayat()
returns jsonb language plpgsql stable security definer set search_path to '' as $f$
begin
  perform rc_private.require_tab('compilation.changedc');
  return jsonb_build_object('status', 'success',
    'depot', coalesce((select jsonb_agg(jsonb_build_object('kode', d.depot_code, 'nama', d.depot_name) order by d.depot_code)
                         from public.depots d where d.archived_at is null and not coalesce(d.bukan_depot, false)), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('waktu', z.waktu, 'oleh', z.oleh, 'detail', z.v->>'detail', 'kodeToko', z.v->>'kodeToko',
                                                          'namaToko', z.v->>'namaToko', 'ke', z.v->>'ke', 'reason', z.v->>'reason',
                                                          'dari', (select string_agg(x->>'dari', ', ') from jsonb_array_elements(z.v->'asal') x)) order by z.created_at desc, z.v->>'kodeToko')
                        from (select l.created_at, t.v, to_char(l.created_at at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') waktu, coalesce(nullif(p.full_name, ''), p.user_code, '-') oleh
                                from (select * from public.activity_logs where event_type = 'change_dc' order by created_at desc limit 100) l
                                left join public.profiles p on p.id = l.actor_id
                               cross join lateral jsonb_array_elements(coalesce(l.details->'toko', jsonb_build_array(l.details))) t(v)
                               order by l.created_at desc, t.v->>'kodeToko' limit 100) z), '[]'::jsonb));
end $f$;

revoke all on function public.rc_change_dc_cek(jsonb), public.rc_change_dc(jsonb, text), public.rc_change_dc_riwayat() from public, anon;
grant execute on function public.rc_change_dc_cek(jsonb), public.rc_change_dc(jsonb, text), public.rc_change_dc_riwayat() to authenticated, service_role;

do $cek$ begin
  if to_regprocedure('public.rc_change_dc(text,text,text)') is not null then raise exception 'GAGAL: versi satu toko masih ada'; end if;
  if pg_get_functiondef('public.rc_change_dc(jsonb,text)'::regprocedure) ~ 'can_access' then raise exception 'GAGAL: masih yurisdiksi'; end if;
  if pg_get_functiondef('rc_private.change_dc_pindah(jsonb,text,uuid)'::regprocedure) !~ 'no_doc_lama' then raise exception 'GAGAL: No Doc lama'; end if;
end $cek$;
