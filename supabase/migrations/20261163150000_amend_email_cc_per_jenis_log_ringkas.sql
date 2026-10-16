-- ==========================================================================================
-- Amend Doc lanjutan, email Amend/Reprocessing, CC wajib per jenis email, log satu per proses
-- ==========================================================================================
-- Pemilik, 16 Oktober 2026 (lanjutan 20261163140000):
--   "Remark ini bisa lebih dari 1 kan, saya mau bisa."
--   "doc di amend bukan hanya not yet tapi seluruhnya, hanya saja nanti di remark nya
--    ditambahkan doc amendement - ... dari proses apa. lalu jika ada amend user yang melakukan
--    juga masuk ke process by dengan warna merah untuk font nya."
--   "untuk amend doc ini akan ada email dengan peringatan yang menampilkan semua doc yang di
--    amend, status awal, nilai cb lama, nilai cb baru dan reason nya ditampilkan. lalu tambahkan
--    peringatan 'Mohon perhatian karena tindakan ini akan merubah total CB Net dan Keseluruhan
--    data depot ... (sesuai), Team admin silakan konfirmasi ke OSC terkait tindakan ini'"
--   "buat juga email tiap reprocessing doc, disertai alasan."
--   "untuk log activity supaya ga menghabiskan banyak storage saya mau sekali pengajuan cukup 1
--    kali aja yg muncul contoh. Process 19 doc lalu isi batch nya di field batch."
--   "pada tab email pengajuan buat lebih details lagi cc nya. contoh cc wajib done, cc wajib
--    pengajuan, cc wajib approval dan approved, cc wajib amend doc, cc wajib reprocessing doc."
--
-- 1. REMARK: boleh lebih dari satu (dipisah koma, layar menampilkannya per baris). Setiap Amend
--    menambah "Doc Amendment - <tahap saat di-Amend>", mis. "Doc Amendment - Done".
-- 2. AMEND: seluruh status, termasuk yang menunggu approval. Satu proses boleh banyak dokumen,
--    masing-masing dengan alasan (atau satu alasan untuk semua). Diperiksa seluruhnya dulu: satu
--    baris salah, tidak ada yang diubah. Pelaku Amend dikirim sebagai amendBy (Process by, merah).
--    Satu baris activity log per proses berisi rinciannya (sumber Riwayat Amend).
-- 3. EMAIL: Amend -> email peringatan per depot; Reprocessing -> email per depot dengan alasan.
--    Tunduk pada sakelar Email Pengajuan dan mode ujinya, seperti email pengajuan lain.
-- 4. CC WAJIB PER JENIS: email_settings.cc_per_jenis (pengajuan, approval, done, hold_expired,
--    amend, reprocess) ditambahkan ke CC selain CC untuk semua email (cc_tambahan).
-- 5. LOG: proses klaim, Posting Exception, dan Reprocessing tidak lagi menulis satu baris log per
--    dokumen. Jejak per dokumen sudah ada di riwayat status (pelaku, waktu, batch); Log Activity
--    cukup satu baris per proses ("Workflow RELEASE: 19 dokumen", batch di kolom Batch) yang
--    ditulis layar. Perubahan Customer Master dari pengajuan diringkas menjadi satu baris.
--
-- Ditambal dengan penjaga MD5 pra-citra (dev sesudah 20261163140000). Aman diulang.
-- ==========================================================================================

alter table public.email_settings add column if not exists cc_per_jenis jsonb not null default '{}'::jsonb;
comment on column public.email_settings.cc_per_jenis is
  'CC wajib per jenis email pengajuan: pengajuan, approval, done, hold_expired, amend, reprocess (20261163150000).';

-- ------------------------------------------------------------------------------------------
-- 4. Penerima: CC semua email + CC wajib jenis ini
-- ------------------------------------------------------------------------------------------
do $cek$
begin
  if not exists(select 1 from pg_proc where oid = to_regprocedure('rc_private.email_pengajuan_penerima(uuid,text)')) and
     md5(replace(pg_get_functiondef('rc_private.email_pengajuan_penerima(uuid)'::regprocedure), E'\r', '')) <> '16dc315e0c24b710404c0a8618591642' then
    raise exception 'DITOLAK: email_pengajuan_penerima(uuid) berbeda dari yang diukur.'; end if;
end
$cek$;

create or replace function rc_private.email_pengajuan_penerima(p_depot uuid, p_kategori text)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_to text[]; v_cc text[]; v_dep public.depots%rowtype; v_tam text[]; v_jenis text[];
begin
  select * into v_dep from public.depots where id = p_depot;

  -- TO tetap dari Depot Master. Alamatnya ditulis dipisah koma.
  select coalesce(array_agg(distinct lower(btrim(x))) filter (where btrim(x) <> ''), '{}')
    into v_to
    from unnest(string_to_array(coalesce(v_dep.email_to,''), ',')) x;

  select coalesce(cc_tambahan,'{}'),
         coalesce(array(select jsonb_array_elements_text(case when p_kategori is null then '[]'::jsonb
                                                              else coalesce(cc_per_jenis->p_kategori,'[]'::jsonb) end)), '{}')
    into v_tam, v_jenis
    from public.email_settings where jenis='pengajuan';

  -- CC dari OSC/Supervisor depot, CC untuk semua email, dan CC wajib jenis ini (20261163150000).
  -- depots.email_cc SENGAJA tidak ikut: CC diatur di satu tempat, tab Email Pengajuan.
  select coalesce(array_agg(distinct a) filter (where a <> ''), '{}')
    into v_cc
    from (
      select lower(btrim(coalesce(p.business_email,''))) as a
        from public.profiles p
        join public.user_depot_access uda on uda.user_id = p.id
       where uda.depot_id = p_depot
         and lower(coalesce(p.role,'')) in ('osc','supervisor')
         and coalesce(p.status,'') = 'active'
      union all
      select lower(btrim(y)) from unnest(v_tam) y
      union all
      select lower(btrim(y)) from unnest(v_jenis) y
    ) s
   where a is not null and a <> '' and a like '%@%';

  -- Alamat yang sudah menjadi tujuan utama tidak perlu ikut sebagai tembusan.
  select coalesce(array_agg(c),'{}') into v_cc
    from unnest(v_cc) c where not (c = any(coalesce(v_to,'{}')));

  return jsonb_build_object('to', to_jsonb(coalesce(v_to,'{}')),
                            'cc', to_jsonb(coalesce(v_cc,'{}')),
                            'depot', coalesce(v_dep.depot_name, v_dep.depot_code, ''));
end $fn$;

create or replace function rc_private.email_pengajuan_penerima(p_depot uuid)
returns jsonb language sql stable security definer set search_path to '' as $fn$
  select rc_private.email_pengajuan_penerima(p_depot, null::text);
$fn$;

-- Pengantre umum untuk email kejadian yang isinya sudah disusun (Amend, Reprocessing): sakelar,
-- mode uji, penerima, dan antrean sama persis dengan email_pengajuan_antre.
create or replace function rc_private.email_kejadian_antre(p_kategori text, p_aksi text, p_depot uuid,
  p_subjek text, p_isi text, p_aktor uuid, p_konteks jsonb default '{}'::jsonb)
returns integer language plpgsql security definer set search_path to '' as $fn$
declare v_aktif boolean; v_uji boolean; v_alamat text; v_pen jsonb; v_to text[]; v_cc text[];
  v_subjek text := p_subjek; v_spanduk text := '';
begin
  select aktif, mode_uji, btrim(coalesce(email_uji,'')) into v_aktif, v_uji, v_alamat
    from public.email_settings where jenis='pengajuan';
  if not coalesce(v_aktif,false) then return 0; end if;
  v_uji := coalesce(v_uji,false) and coalesce(v_alamat,'') <> '';

  v_pen := rc_private.email_pengajuan_penerima(p_depot, p_kategori);
  v_to  := array(select jsonb_array_elements_text(v_pen->'to'));
  v_cc  := array(select jsonb_array_elements_text(v_pen->'cc'));

  if coalesce(array_length(v_to,1),0) = 0 and not v_uji then
    insert into public.activity_logs(actor_id,depot_id,event_type,details)
    values(p_aktor, p_depot, 'email_pengajuan_tanpa_tujuan',
      jsonb_build_object('aksi',p_aksi,'sebab','Alamat email depot belum diisi di Depot Master'));
    return 0;
  end if;

  if v_uji then
    v_spanduk :=
      '<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;'
      || 'padding:12px 16px;border-radius:8px;margin-bottom:12px;max-width:640px;">'
      || '<div style="font-size:13px;font-weight:bold;margin-bottom:6px;">MODE UJI &mdash; '
      || 'surat ini TIDAK dikirim ke depot</div>'
      || '<div style="font-size:11px;line-height:1.7;color:#d1d5db;">Seharusnya dikirim ke<br>'
      || '<strong style="color:#ffffff;">TO</strong> (' || coalesce(array_length(v_to,1),0)::text || '): '
      || rc_private.html_aman(coalesce(nullif(array_to_string(v_to,', '),''),'BELUM ADA ALAMAT DEPOT DI DEPOT MASTER')) || '<br>'
      || '<strong style="color:#ffffff;">CC</strong> (' || coalesce(array_length(v_cc,1),0)::text || '): '
      || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc,', '),''),'tidak ada'))
      || '</div></div>';
    v_subjek := '[UJI] ' || v_subjek;
    v_to := array[v_alamat];
    v_cc := '{}';
  end if;

  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,konteks)
  values('pengajuan', v_to, v_cc, v_subjek, rc_private.email_outlook(v_spanduk || p_isi),
    coalesce(p_konteks,'{}'::jsonb) || jsonb_build_object('aksi',p_aksi,'kategori',p_kategori,'depot',p_depot,'modeUji',v_uji));
  return 1;
end $fn$;

-- Isi email Amend (peringatan) dan Reprocessing untuk satu depot. p_dok: daftar dokumen depot itu
-- dengan nilai lama/baru, status awal, dan alasan.
create or replace function rc_private.email_kejadian_html(p_jenis text, p_depot uuid, p_dok jsonb, p_aktor uuid)
returns text language plpgsql stable security definer set search_path to '' as $fn$
declare v_depot text; v_kode text; v_nama text; v_baris text := ''; v_r record; v_lama numeric := 0; v_baru numeric := 0;
  v_n int := 0; v_judul text; v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
begin
  select coalesce(depot_name, depot_code, ''), coalesce(depot_code, '') into v_depot, v_kode from public.depots where id = p_depot;
  select coalesce(full_name, user_code, '') into v_nama from public.profiles where id = p_aktor;
  v_judul := case p_jenis when 'amend' then 'Peringatan - Amend Doc Claim Cashback Depo ' else 'Reprocessing Doc - Claim Cashback Depo ' end
             || coalesce(nullif(v_depot,''),'-');
  for v_r in
    select x->>'noDoc' no_doc, x->>'status' status_awal, (x->>'cbNetLama')::numeric lama, (x->>'cbNetBaru')::numeric baru,
           x->>'alasan' alasan, coalesce(cu.customer_code, c.source_customer_code, '') kode_toko, coalesce(cu.customer_name, '') toko,
           coalesce(ca.campaign_code, '') kode_camp
      from jsonb_array_elements(p_dok) x
      left join public.claims c on c.id = (x->>'claimId')::uuid
      left join public.customers cu on cu.id = c.customer_id
      left join public.campaigns ca on ca.id = c.campaign_id
     order by x->>'noDoc'
  loop
    v_n := v_n + 1; v_lama := v_lama + coalesce(v_r.lama,0); v_baru := v_baru + coalesce(v_r.baru,0);
    v_baris := v_baris || '<tr>'
      || '<td style="' || v_td || 'white-space:nowrap;font-family:Consolas,monospace;">' || rc_private.html_aman(v_r.no_doc) || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(v_r.kode_toko || case when v_r.toko <> '' then ' - ' || v_r.toko else '' end) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(v_r.kode_camp) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(rc_private.legacy_status(v_r.status_awal))
         || case when p_jenis = 'reprocess' then ' &rarr; Not Yet' else '' end || '</td>'
      || '<td style="' || v_td || 'text-align:right;white-space:nowrap;">' || rc_private.rupiah(v_r.lama) || '</td>'
      || '<td style="' || v_td || 'text-align:right;white-space:nowrap;font-weight:bold;color:#C8102E;">' || rc_private.rupiah(v_r.baru) || '</td>'
      || '<td style="' || v_td || 'text-align:right;white-space:nowrap;">' || rc_private.rupiah(v_r.baru - v_r.lama) || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(coalesce(v_r.alasan,'-')) || '</td>'
      || '</tr>';
  end loop;

  return rc_private.email_kepala(v_judul, 'Depo ' || coalesce(nullif(v_depot,''),'-') || '  |  ' || v_n::text || ' dokumen')
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    || case when p_jenis = 'amend' then
         '<p style="line-height:1.6;">Berikut dokumen claim cashback Depo <strong>' || rc_private.html_aman(v_kode || ' - ' || v_depot)
         || '</strong> yang nilai Net CB-nya diubah (Amend Doc).</p>'
         || '<p style="line-height:1.6;background:#fdecef;border-left:4px solid #C8102E;padding:10px 12px;margin:12px 0;font-size:13px;color:#8a0d20;">'
         || '<strong>PERINGATAN:</strong> Mohon perhatian karena tindakan ini akan merubah total CB Net dan keseluruhan data depot <strong>'
         || rc_private.html_aman(v_kode || ' - ' || v_depot) || '</strong>. Team admin silakan konfirmasi ke OSC terkait tindakan ini.</p>'
       else
         '<p style="line-height:1.6;">Berikut dokumen On Hold claim cashback Depo <strong>' || rc_private.html_aman(v_kode || ' - ' || v_depot)
         || '</strong> yang diproses ulang (Reprocessing Doc) dan kembali ke Not Yet dengan nilai revisi.</p>'
       end
    || '<p style="line-height:1.6;color:#5f6368;font-size:12px;">Diproses oleh <strong>' || rc_private.html_aman(coalesce(nullif(v_nama,''),'-'))
    || '</strong> pada ' || rc_private.tgl_panjang(now()) || ' ' || to_char(now() at time zone 'Asia/Jakarta','HH24:MI') || ' WIB &middot; '
    || v_n::text || ' dokumen.</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left" style="' || v_th || '">NO DOC</th><th align="left" style="' || v_th || '">TOKO</th>'
    || '<th align="left" style="' || v_th || '">CAMPAIGN</th><th align="left" style="' || v_th || '">'
    || case when p_jenis = 'amend' then 'STATUS AWAL' else 'STATUS' end || '</th>'
    || '<th align="right" style="' || v_th || '">NET CB LAMA</th><th align="right" style="' || v_th || '">NET CB BARU</th>'
    || '<th align="right" style="' || v_th || '">SELISIH</th><th align="left" style="' || v_th || '">ALASAN</th>'
    || '</tr></thead><tbody>' || v_baris || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;">'
    || '<td colspan="4" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">TOTAL</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_lama) || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_baru) || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(v_baru - v_lama) || '</td>'
    || '<td style="padding:10px;"></td></tr></tfoot></table>'
    || case when p_jenis = 'amend' then '<p style="line-height:1.6;margin-top:16px;">Dokumen di atas bertanda <strong>Doc Amendment</strong> pada Remark.</p>'
            else '<p style="line-height:1.6;margin-top:16px;">Mohon tim Depo untuk mengajukan kembali dokumen di atas sesuai nilai revisi.</p>' end
    || rc_private.email_ttd()
    || '</td></tr></table>';
end $fn$;

-- Kirim email kejadian per depot dari daftar dokumen (bebas galat: kegagalan email tidak
-- membatalkan proses, hanya dicatat).
create or replace function rc_private.email_kejadian_kirim(p_jenis text, p_dok jsonb, p_aktor uuid)
returns integer language plpgsql security definer set search_path to '' as $fn$
declare v_dep uuid; v_isi jsonb; v_n int := 0; v_nama text;
begin
  for v_dep in select distinct (x->>'depotId')::uuid from jsonb_array_elements(coalesce(p_dok,'[]'::jsonb)) x loop
    select jsonb_agg(x) into v_isi from jsonb_array_elements(p_dok) x where (x->>'depotId')::uuid = v_dep;
    select coalesce(depot_name, depot_code, 'Depot') into v_nama from public.depots where id = v_dep;
    begin
      v_n := v_n + rc_private.email_kejadian_antre(p_jenis, p_jenis, v_dep,
        case p_jenis when 'amend' then 'Peringatan - Amend Doc Claim Cashback Depo ' else 'Reprocessing Doc - Claim Cashback Depo ' end || v_nama,
        rc_private.email_kejadian_html(p_jenis, v_dep, v_isi, p_aktor), p_aktor,
        jsonb_build_object('qty', jsonb_array_length(v_isi)));
    exception when others then
      insert into public.activity_logs(actor_id,depot_id,event_type,details)
      values(p_aktor, v_dep, 'email_pengajuan_gagal', jsonb_build_object('aksi',p_jenis,'sebab',left(sqlerrm,300)));
    end;
  end loop;
  return v_n;
end $fn$;

-- ------------------------------------------------------------------------------------------
-- 1. Remark: boleh lebih dari satu; setiap Amend tercatat tahapnya
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean,
  p_cb_berubah boolean, p_amended_at timestamptz, p_amend_dari text[])
returns text language sql stable as $fn$
  select concat_ws(', ',
    case when coalesce(array_length(p_amend_dari,1),0) > 0
         then (select string_agg('Doc Amendment - ' || t, ', ' order by o)
                 from (select t, min(o) o from unnest(p_amend_dari) with ordinality u(t, o) group by t) s)
         when p_amended_at is not null then 'Doc Amendment' end,
    case when p_reprocessed_at is not null or p_ada_reprocess then 'Document Reprocessed' end,
    case when p_cb_berubah then 'CB Type Changed' end);
$fn$;
create or replace function rc_private.claim_remark_dari(p_reprocessed_at timestamptz, p_ada_reprocess boolean,
  p_cb_berubah boolean, p_amended_at timestamptz)
returns text language sql stable as $fn$
  select rc_private.claim_remark_dari(p_reprocessed_at, p_ada_reprocess, p_cb_berubah, p_amended_at, null::text[]);
$fn$;
create or replace function rc_private.claim_remark(c public.claims)
returns text language sql stable set search_path to '' as $fn$
  select rc_private.claim_remark_dari(c.reprocessed_at,
    exists(select 1 from public.claim_status_history h where h.claim_id = c.id and h.action like '%reprocess%'),
    c.cashback_type_changed, c.amended_at,
    array(select rc_private.legacy_status(h.from_status) from public.claim_status_history h
           where h.claim_id = c.id and h.action = 'amend' order by h.id) /* 20261163150000 */);
$fn$;

-- ------------------------------------------------------------------------------------------
-- Tambalan fungsi yang ada (beberapa tambalan per fungsi; MD5 diperiksa sekali per fungsi)
-- ------------------------------------------------------------------------------------------
do $tambal$
declare f record; r record; src text; baru text; n int;
begin
  create temp table _tambal(urut serial, sig text, harapan text, lama text, ganti text) on commit drop;
  insert into _tambal(sig, harapan, lama, ganti) values
  -- 4. CC wajib per jenis pada email pengajuan yang sudah ada.
  ('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)', '2628b39b5c928c53f7f35c5d6c502bea',
   $p$    v_pen := rc_private.email_pengajuan_penerima(v_dep.depot_id);$p$,
   $p$    -- 20261163150000: CC wajib per jenis email (tab Email Pengajuan).
    v_pen := rc_private.email_pengajuan_penerima(v_dep.depot_id, case p_action when 'submit' then 'approval'
      when 'approve' then 'approval' when 'submit_langsung' then 'pengajuan' when 'clearing' then 'done' else 'hold_expired' end);$p$),

  -- 1/2. Analytics: tahap setiap Amend (Remark) dan pelakunya (Process by).
  ('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)', '1aa57423d2c95aed65cd88e5da935dfb',
   $p$coalesce(bool_or(h.action like '%reprocess%'), false) as ada_reprocess$p$,
   $p$coalesce(bool_or(h.action like '%reprocess%'), false) as ada_reprocess,
           -- 20261163150000: setiap Amend (tahap dan pelakunya) untuk Remark dan Process by.
           coalesce(array_agg(rc_private.legacy_status(h.from_status) order by h.id) filter (where h.action='amend'), '{}') as amend_dari,
           coalesce(jsonb_agg(jsonb_build_object('aktor', h.actor_id, 'dari', rc_private.legacy_status(h.from_status),
             'waktu', rc_private.legacy_ts(h.created_at)) order by h.id) filter (where h.action='amend'), '[]'::jsonb) as amend_list$p$),
  ('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)', '1aa57423d2c95aed65cd88e5da935dfb',
   $p$c.amended_at /* 20261163140000 */)$p$,
   $p$c.amended_at /* 20261163140000 */, pel.amend_dari /* 20261163150000 */)$p$),
  ('public.rc_legacy_dashboard(integer,timestamp with time zone,uuid)', '1aa57423d2c95aed65cd88e5da935dfb',
   $p$'clearedBy',coalesce(nama_pemilik->>(pel.clear_by::text),''),$p$,
   $p$'clearedBy',coalesce(nama_pemilik->>(pel.clear_by::text),''),
    'amendBy',(select coalesce(jsonb_agg(jsonb_build_object('oleh',coalesce(nama_pemilik->>(a->>'aktor'),''),
      'dari',a->>'dari','waktu',a->>'waktu')),'[]'::jsonb) from jsonb_array_elements(pel.amend_list) a), /* 20261163150000 */$p$),

  -- 1/2. Claim Process: sama dengan Analytics.
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '8ad3d38acf172ed0e78821eb031ef46a',
   $p$coalesce(bool_or(h.action like '%reprocess%'), false) as ada_reprocess$p$,
   $p$coalesce(bool_or(h.action like '%reprocess%'), false) as ada_reprocess,
      -- 20261163150000: setiap Amend (tahap dan pelakunya) untuk Remark dan Process by.
      coalesce(array_agg(rc_private.legacy_status(h.from_status) order by h.id) filter (where h.action='amend'), '{}') as amend_dari,
      coalesce(jsonb_agg(jsonb_build_object('aktor', h.actor_id, 'dari', rc_private.legacy_status(h.from_status),
        'waktu', rc_private.legacy_ts(h.created_at)) order by h.id) filter (where h.action='amend'), '[]'::jsonb) as amend_list$p$),
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '8ad3d38acf172ed0e78821eb031ef46a',
   $p$c.amended_at /* 20261163140000 */)$p$,
   $p$c.amended_at /* 20261163140000 */, pel.amend_dari /* 20261163150000 */)$p$),
  ('public.rc_legacy_workflow(integer,timestamp with time zone,uuid)', '8ad3d38acf172ed0e78821eb031ef46a',
   $p$'clearedBy',coalesce(nama->>(pel.clear_by::text),''),$p$,
   $p$'clearedBy',coalesce(nama->>(pel.clear_by::text),''),
   'amendBy',(select coalesce(jsonb_agg(jsonb_build_object('oleh',coalesce(nama->>(a->>'aktor'),''),
     'dari',a->>'dari','waktu',a->>'waktu')),'[]'::jsonb) from jsonb_array_elements(pel.amend_list) a), /* 20261163150000 */$p$),

  -- 5. Proses klaim: tanpa log per dokumen; perubahan Customer Master diringkas.
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '1c06cd7198340649a730094c7c9e8085',
   $p$ v_tgl_aktual date; -- 20261162270000
$p$,
   $p$ v_tgl_aktual date; -- 20261162270000
 v_master_ubah jsonb := '[]'; -- 20261163150000
$p$),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '1c06cd7198340649a730094c7c9e8085',
   $p$   insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
   values(actor,c.depot_id,'customer_master_updated_from_upload',c.id,
     jsonb_build_object('custCode',cust.customer_code,'noDoc',c.no_doc));$p$,
   $p$   -- 20261163150000: diringkas menjadi satu baris per proses (sesudah loop).
   v_master_ubah := v_master_ubah || jsonb_build_object('custCode',cust.customer_code,'noDoc',c.no_doc);$p$),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '1c06cd7198340649a730094c7c9e8085',
   $p$ insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
 values(actor,c.depot_id,p_action,c.id,jsonb_build_object('from',c.status,'to',target,'batch',batch));
$p$,
   $p$ -- 20261163150000: tidak ada lagi log per dokumen; jejaknya di claim_status_history.
$p$),
  ('rc_private.mutate_claims_unchecked(text,jsonb,uuid,text)', '1c06cd7198340649a730094c7c9e8085',
   $p$ end loop;
 begin
  perform rc_private.email_pengajuan_antre(case when v_langsung$p$,
   $p$ end loop;
 if jsonb_array_length(v_master_ubah) > 0 then -- 20261163150000
  insert into public.activity_logs(actor_id,event_type,details,batch_no)
  values(actor,'customer_master_updated_from_upload',jsonb_build_object(
    'detail','Customer Master diperbarui dari pengajuan: '||jsonb_array_length(v_master_ubah)||' dokumen',
    'jumlah',jsonb_array_length(v_master_ubah),'dokumen',v_master_ubah),batch);
 end if;
 begin
  perform rc_private.email_pengajuan_antre(case when v_langsung$p$),

  -- 5. Posting Exception: tanpa log per dokumen.
  ('public.rc_posting_exception(text,jsonb,text)', 'f78335ff29593fd6567eaea66e50e07d',
   $p$      insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
      values(actor,c.depot_id,'posting_exception',c.id,jsonb_build_object(
        'noDoc',c.no_doc,'tindakan',v_action,'dari',c.status,'menjadi',v_target,'requestedStatus',v_target,
        'langsung',true,'batch',batch,
        'soStart',so_a,'soEnd',so_b,'billingStart',bi_a,'billingEnd',bi_b));$p$,
   $p$      -- 20261163150000: tidak ada lagi log per dokumen; jejaknya di claim_status_history.$p$),
  ('public.rc_posting_exception(text,jsonb,text)', 'f78335ff29593fd6567eaea66e50e07d',
   $p$    insert into public.activity_logs(actor_id,depot_id,event_type,entity_id,details)
    values(actor,c.depot_id,'posting_exception',c.id,jsonb_build_object(
      'noDoc',c.no_doc,'tindakan',v_action,'dari',c.status,'menjadi',c.status,'requestedStatus',v_target,
      'soStart',so_a,'soEnd',so_b,'billingStart',bi_a,'billingEnd',bi_b));$p$,
   $p$    -- 20261163150000: tidak ada lagi log per dokumen; jejaknya di claim_status_history.$p$),

  -- 4. Pengaturan Email Pengajuan: CC wajib per jenis ikut dibaca.
  ('public.rc_email_pengajuan_baca()', '8168e8f719b824e7f64bebe3f7de6031',
   $p$    'ccTambahan', to_jsonb(coalesce(v_s.cc_tambahan,'{}')),$p$,
   $p$    'ccTambahan', to_jsonb(coalesce(v_s.cc_tambahan,'{}')),
    'ccPerJenis', coalesce(v_s.cc_per_jenis,'{}'::jsonb), /* 20261163150000 */$p$);

  for f in select sig, min(harapan) harapan from _tambal group by sig loop
    src := pg_get_functiondef(f.sig::regprocedure);
    if src ~ '20261163150000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(replace(src, E'\r', '')) <> f.harapan then
      raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', f.sig, md5(replace(src, E'\r', '')); end if;
    baru := replace(src, E'\r', '');
    for r in select * from _tambal where sig = f.sig order by urut loop
      n := (length(baru) - length(replace(baru, r.lama, ''))) / length(r.lama);
      if n <> 1 then raise exception '%: pola #% ditemukan % kali, diharapkan 1.', f.sig, r.urut, n; end if;
      baru := replace(baru, r.lama, r.ganti);
    end loop;
    execute baru;
  end loop;
end
$tambal$;

-- ------------------------------------------------------------------------------------------
-- 4. Simpan pengaturan Email Pengajuan dengan CC wajib per jenis
-- ------------------------------------------------------------------------------------------
do $ganti$
begin
  if to_regprocedure('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text)') is not null then
    if md5(replace(pg_get_functiondef('public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text)'::regprocedure), E'\r', ''))
       <> '680c669d3aef8a0bf22558621e19ade2' then
      raise exception 'DITOLAK: rc_email_pengajuan_simpan berbeda dari yang diukur.'; end if;
    drop function public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text);
  end if;
end
$ganti$;

create or replace function public.rc_email_pengajuan_simpan(p_aktif boolean, p_cc jsonb, p_mode_uji boolean default false,
  p_email_uji text default '', p_cc_jenis jsonb default null)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_cc text[]; v_buruk text; v_uji text; v_jenis jsonb := '{}'::jsonb; k text; v_daftar text[];
  v_kunci text[] := array['pengajuan','approval','done','hold_expired','amend','reprocess'];
begin
  perform rc_private.require_tab('access.emailPengajuan');
  if not (rc_private.is_system_manager() or rc_private.can_tab('access.emailPengajuan')) then
    raise exception 'Anda belum diberi akses Email Pengajuan' using errcode='42501'; end if;

  if p_cc is null or jsonb_typeof(p_cc) <> 'array' then raise exception 'Daftar email tambahan harus berupa array'; end if;
  if jsonb_array_length(p_cc) > 50 then raise exception 'Email tambahan maksimal 50 alamat'; end if;
  select coalesce(array_agg(distinct lower(btrim(x))) filter (where btrim(x) <> ''), '{}') into v_cc from jsonb_array_elements_text(p_cc) x;
  select x into v_buruk from unnest(v_cc) x where x !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' limit 1;
  if v_buruk is not null then raise exception 'Alamat email tidak sah: %', v_buruk; end if;

  -- CC wajib per jenis (20261163150000). null = biarkan seperti semula.
  if p_cc_jenis is null then
    select coalesce(cc_per_jenis, '{}'::jsonb) into v_jenis from public.email_settings where jenis='pengajuan';
  else
    if jsonb_typeof(p_cc_jenis) <> 'object' then raise exception 'CC per jenis harus berupa objek'; end if;
    for k in select jsonb_object_keys(p_cc_jenis) loop
      if not (k = any(v_kunci)) then raise exception 'Jenis CC tidak dikenal: %', k; end if;
      if jsonb_typeof(p_cc_jenis->k) <> 'array' then raise exception 'CC wajib % harus berupa daftar', k; end if;
      select coalesce(array_agg(distinct lower(btrim(x))) filter (where btrim(x) <> ''), '{}') into v_daftar
        from jsonb_array_elements_text(p_cc_jenis->k) x;
      if coalesce(array_length(v_daftar,1),0) > 30 then raise exception 'CC wajib % maksimal 30 alamat', k; end if;
      select x into v_buruk from unnest(v_daftar) x where x !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' limit 1;
      if v_buruk is not null then raise exception 'Alamat email tidak sah pada CC wajib %: %', k, v_buruk; end if;
      if coalesce(array_length(v_daftar,1),0) > 0 then v_jenis := v_jenis || jsonb_build_object(k, to_jsonb(v_daftar)); end if;
    end loop;
  end if;

  v_uji := lower(btrim(coalesce(p_email_uji,'')));
  if v_uji <> '' and v_uji !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Alamat email uji tidak sah: %', v_uji; end if;
  -- Mode uji tanpa alamat akan diam-diam berubah menjadi pengiriman sungguhan.
  if coalesce(p_mode_uji,false) and v_uji = '' then raise exception 'Mode Uji memerlukan alamat email uji'; end if;

  update public.email_settings
     set aktif = coalesce(p_aktif,false), cc_tambahan = v_cc, cc_per_jenis = v_jenis,
         mode_uji = coalesce(p_mode_uji,false), email_uji = v_uji, diubah_pada = now(), diubah_oleh = auth.uid()
   where jenis='pengajuan';

  insert into public.activity_logs(actor_id,event_type,details)
  values(auth.uid(),'email_pengajuan_settings', jsonb_build_object('aktif',coalesce(p_aktif,false),
    'modeUji',coalesce(p_mode_uji,false), 'ccTambahan',coalesce(array_length(v_cc,1),0),
    'ccPerJenis',(select coalesce(jsonb_object_agg(key, jsonb_array_length(value)), '{}'::jsonb) from jsonb_each(v_jenis))));

  return jsonb_build_object('status','success',
    'message','Pengaturan disimpan. Pengiriman ' || case when coalesce(p_aktif,false) then 'AKTIF' else 'NONAKTIF' end
      || case when coalesce(p_mode_uji,false) and v_uji <> '' then ', MODE UJI ke ' || v_uji || ' (depot tidak menerima apa pun)' else '' end || '.');
end $fn$;
revoke all on function public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text,jsonb) from public, anon;
grant execute on function public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text,jsonb) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 2/3. Amend: seluruh status, banyak dokumen, alasan, email peringatan, satu log per proses
-- ------------------------------------------------------------------------------------------
drop function if exists public.rc_amend_doc(text, text, bigint);

create or replace function public.rc_amend_cek(p_no_doc text)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare c public.claims%rowtype; d public.depots%rowtype; cu public.customers%rowtype; ca public.campaigns%rowtype;
  v_doc text := upper(btrim(coalesce(p_no_doc, '')));
begin
  perform rc_private.require_tab('compilation.amend');
  if v_doc = '' then raise exception 'No Doc wajib diisi'; end if;
  select * into c from public.claims where upper(no_doc) = v_doc and archived_at is null;
  if not found or not rc_private.can_access(c.depot_id) then
    raise exception 'Dokumen % tidak ditemukan (atau terarsip / di luar yurisdiksi Anda)', v_doc; end if;
  select * into d from public.depots where id = c.depot_id;
  select * into cu from public.customers where id = c.customer_id;
  select * into ca from public.campaigns where id = c.campaign_id;
  return jsonb_build_object('status', 'success',
    'noDoc', c.no_doc, 'versionNo', c.version_no, 'statusDok', rc_private.legacy_status(c.status),
    'kodeDepot', d.depot_code, 'depot', d.depot_name,
    'kodeToko', coalesce(cu.customer_code, c.source_customer_code), 'namaToko', coalesce(cu.customer_name, 'Customer Master belum ada'),
    'kodeCampaign', ca.campaign_code, 'campaign', ca.campaign_name,
    'jenisCb', rc_private.cb_label(coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)),
    'cbNet', c.cb_net, 'grossUp', c.gross_up,
    -- 20261163150000: seluruh status boleh di-Amend; hanya dokumen tanpa Customer Master yang tidak
    -- (penjaga database menolak setiap perubahan pada dokumen itu).
    'bisa', c.customer_id is not null,
    'sebab', case when c.customer_id is null then 'Customer Master belum ada; lengkapi dulu di Key Master' else '' end,
    'amendTerakhir', rc_private.legacy_ts(c.amended_at),
    'remark', coalesce(rc_private.claim_remark(c), ''));
end $fn$;

create or replace function public.rc_amend_doc(p_items jsonb, p_alasan text default '')
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare r jsonb; c public.claims%rowtype; v_doc text; v_baru numeric; v_alasan text; v_umum text := btrim(coalesce(p_alasan, ''));
  v_subjek text; v_pajak text; v_jenis text; v_gross numeric; actor uuid := (select auth.uid());
  galat text[] := '{}'; v_lihat text[] := '{}'; v_dok jsonb := '[]'::jsonb; n int := 0; v_email int := 0; v_depot uuid;
begin
  perform rc_private.require_tab('compilation.amend');
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Tidak ada dokumen yang dikirim'; end if;
  if jsonb_array_length(p_items) > 200 then raise exception 'Maksimal 200 dokumen sekali Amend'; end if;

  -- 1. Seluruh baris diperiksa dulu. Satu saja salah, tidak ada yang diubah.
  for r in select value from jsonb_array_elements(p_items) loop
    v_doc := upper(btrim(coalesce(r->>'noDoc', '')));
    if v_doc = '' then galat := galat || 'ada baris tanpa No Doc'; continue; end if;
    if v_doc = any(v_lihat) then galat := galat || (v_doc || ': No Doc ganda di daftar'); continue; end if;
    v_lihat := v_lihat || v_doc;
    begin
      v_baru := nullif(btrim(coalesce(r->>'cbNet', '')), '')::numeric;
    exception when others then galat := galat || (v_doc || ': Net CB baru "' || coalesce(r->>'cbNet', '') || '" bukan angka'); continue;
    end;
    if v_baru is null then galat := galat || (v_doc || ': Net CB baru kosong'); continue; end if;
    if v_baru < 0 then galat := galat || (v_doc || ': Net CB tidak boleh negatif'); continue; end if;
    v_baru := trunc(v_baru);
    if coalesce(nullif(btrim(coalesce(r->>'alasan', '')), ''), nullif(v_umum, '')) is null then
      galat := galat || (v_doc || ': alasan wajib diisi'); continue; end if;
    select * into c from public.claims where upper(no_doc) = v_doc and archived_at is null;
    if not found or not rc_private.can_access(c.depot_id) then
      galat := galat || (v_doc || ': tidak ditemukan (atau terarsip / di luar yurisdiksi Anda)'); continue; end if;
    if nullif(r->>'versionNo', '') is not null and (r->>'versionNo')::bigint <> c.version_no then
      galat := galat || (v_doc || ': dokumen berubah sejak dicek; cek ulang'); continue; end if;
    if c.customer_id is null then galat := galat || (v_doc || ': Customer Master belum ada; lengkapi dulu di Key Master'); continue; end if;
    if v_baru = c.cb_net then galat := galat || (v_doc || ': Net CB baru sama dengan Net CB sekarang (' || rc_private.rupiah(c.cb_net) || ')'); continue; end if;
  end loop;
  if coalesce(array_length(galat, 1), 0) > 0 then
    raise exception 'Amend dibatalkan, tidak ada yang diubah. %', array_to_string(galat, '; '); end if;

  -- 2. Ubah. Gross up dihitung ulang dengan aturan Reprocessing; status dokumen tetap.
  for r in select value from jsonb_array_elements(p_items) loop
    v_doc := upper(btrim(r->>'noDoc'));
    v_baru := trunc(nullif(btrim(r->>'cbNet'), '')::numeric);
    v_alasan := left(coalesce(nullif(btrim(coalesce(r->>'alasan', '')), ''), v_umum), 300);
    select * into c from public.claims where upper(no_doc) = v_doc and archived_at is null for update;
    if nullif(r->>'versionNo', '') is not null and (r->>'versionNo')::bigint <> c.version_no then
      raise exception 'Dokumen % berubah sejak dicek; Amend dibatalkan', c.no_doc; end if;
    select coalesce(c.tax_subject, cu.tax_subject), ca.tax_status, coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)
      into v_subjek, v_pajak, v_jenis
      from public.customers cu, public.campaigns ca where cu.id = c.customer_id and ca.id = c.campaign_id;
    v_gross := case when v_subjek is not null then rc_private.gross_up_klaim(v_baru, v_subjek, v_pajak, v_jenis) end;

    update public.claims set cb_net = v_baru, gross_up = v_gross, tax_subject = v_subjek,
      amended_at = now(), amended_by = actor, version_no = version_no + 1, updated_at = now()
    where id = c.id;
    insert into public.claim_status_history(claim_id, actor_id, from_status, to_status, action, reason)
    values (c.id, actor, c.status, c.status, 'amend',
      left('Amend Doc (' || rc_private.legacy_status(c.status) || '): Net CB ' || rc_private.rupiah(c.cb_net)
        || ' -> ' || rc_private.rupiah(v_baru) || '. Alasan: ' || v_alasan, 300));
    v_dok := v_dok || jsonb_build_object('claimId', c.id, 'noDoc', c.no_doc, 'depotId', c.depot_id,
      'kodeDepot', (select depot_code from public.depots where id = c.depot_id), 'status', c.status,
      'cbNetLama', c.cb_net, 'cbNetBaru', v_baru, 'grossUpLama', c.gross_up, 'grossUpBaru', v_gross, 'alasan', v_alasan);
    n := n + 1;
  end loop;

  -- 3. Satu baris log per proses; rinciannya sumber Riwayat Amend.
  select case when count(distinct x->>'depotId') = 1 then min(x->>'depotId')::uuid end into v_depot from jsonb_array_elements(v_dok) x;
  insert into public.activity_logs(actor_id, depot_id, event_type, details, module, tab, process_stage)
  values (actor, v_depot, 'amend_doc', jsonb_build_object('detail', 'Amend Doc: ' || n || ' dokumen', 'jumlah', n, 'dokumen', v_dok),
    'compilation', 'amend', 'amend');

  -- 4. Email peringatan per depot.
  v_email := rc_private.email_kejadian_kirim('amend', v_dok, actor);

  return jsonb_build_object('status', 'success', 'berhasil', n, 'email', v_email, 'dokumen', v_dok,
    'message', n || ' dokumen di-Amend' || case when v_email > 0 then ', email peringatan diantrekan ke ' || v_email || ' depot' else '' end || '.');
end $fn$;

create or replace function public.rc_amend_riwayat(p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_semua boolean; v_depot uuid[];
begin
  perform rc_private.require_tab('compilation.amend');
  v_semua := rc_private.saya_sm(); v_depot := rc_private.depot_akses_saya();
  return jsonb_build_object('status', 'success', 'rows', coalesce((select jsonb_agg(t.x order by t.urut) from (
    select row_number() over (order by l.id desc, x->>'noDoc') urut,
      jsonb_build_object('waktu', rc_private.legacy_ts(l.created_at), 'noDoc', x->>'noDoc', 'kodeDepot', d.depot_code,
        'statusDok', rc_private.legacy_status(x->>'status'), 'cbNetLama', (x->>'cbNetLama')::numeric,
        'cbNetBaru', (x->>'cbNetBaru')::numeric, 'alasan', coalesce(x->>'alasan', ''), 'oleh', coalesce(p.full_name, '')) x
      from public.activity_logs l
      -- Baris lama (20261163140000) berisi satu dokumen; baris baru berisi daftar "dokumen".
      cross join lateral jsonb_array_elements(case when l.details ? 'dokumen' then l.details->'dokumen'
                                                   else jsonb_build_array(l.details) end) x
      left join public.depots d on d.id = coalesce((x->>'depotId')::uuid, l.depot_id)
      left join public.profiles p on p.id = l.actor_id
     where l.event_type = 'amend_doc' and (v_semua or coalesce((x->>'depotId')::uuid, l.depot_id) = any(v_depot))
     order by l.id desc, x->>'noDoc' limit least(greatest(coalesce(p_limit, 50), 1), 500)) t), '[]'::jsonb));
end $fn$;

revoke all on function public.rc_amend_doc(jsonb, text) from public, anon;
grant execute on function public.rc_amend_doc(jsonb, text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3/5. Reprocessing Doc: alasan wajib, email per depot, tanpa log per dokumen
-- ------------------------------------------------------------------------------------------
do $cek$
begin
  if pg_get_functiondef('public.rc_reprocessing_upload(jsonb,text)'::regprocedure) !~ '20261163150000'
     and md5(replace(pg_get_functiondef('public.rc_reprocessing_upload(jsonb,text)'::regprocedure), E'\r', ''))
         <> '0ded15fc10e161ea841f36ce91c9159d' then
    raise exception 'DITOLAK: rc_reprocessing_upload berbeda dari yang diukur.'; end if;
end
$cek$;

create or replace function public.rc_reprocessing_upload(p_rows jsonb, p_reason text default ''::text)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  r jsonb; v_doc text; c public.claims%rowtype; v_baru numeric;
  v_subjek text; v_pajak text; v_gross numeric; -- 20261162240000
  v_jenis_gu text; -- 20261162250000
  v_alasan text; v_dok jsonb := '[]'::jsonb; v_email integer := 0; -- 20261163150000
  n_ok integer := 0; gagal jsonb := '[]'::jsonb; actor uuid := (select auth.uid());
begin
 perform rc_private.require_tab('compilation.reprocess');
  if not rc_private.can_access(null,'view_compilation') and not rc_private.is_system_manager() then
    raise exception 'Tidak punya hak mengubah Cashback Compilation' using errcode='42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Tidak ada baris yang dikirim'; end if;
  if jsonb_array_length(p_rows) > 2000 then
    raise exception 'Maksimal 2000 baris sekali unggah'; end if;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_doc := upper(btrim(coalesce(r->>'noDoc','')));
    if v_doc = '' then continue; end if;

    select * into c from public.claims where upper(no_doc) = v_doc for update;
    if not found then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Dokumen tidak ditemukan'));
      continue;
    end if;
    if c.status <> 'on_hold' or c.pending_approval is not null then
      -- Menolak dokumen yang tidak tertahan penting: berkas unduhan yang dipakai ulang beberapa
      -- hari kemudian dapat memuat dokumen yang sementara itu sudah diproses orang lain.
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Status saat ini '||rc_private.legacy_status(c.status)||', bukan On Hold'));
      continue;
    end if;
    if not rc_private.can_access(c.depot_id) then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Depot di luar yurisdiksi Anda'));
      continue;
    end if;

    begin
      v_baru := nullif(btrim(coalesce(r->>'totalCashback','')),'')::numeric;
    exception when others then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Total cashback bukan angka: '||coalesce(r->>'totalCashback','')));
      continue;
    end;
    if v_baru is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback kosong'));
      continue;
    end if;
    if v_baru < 0 then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Total cashback tidak boleh negatif'));
      continue;
    end if;

    -- 20261162210000: angka di belakang desimal dibuang (dipotong, bukan dibulatkan).
    v_baru := trunc(v_baru);

    -- 20261163150000: alasan wajib - kolom "Alasan Reprocessing" per baris, atau satu alasan untuk semua.
    v_alasan := left(coalesce(nullif(btrim(coalesce(r->>'alasan','')),''), nullif(btrim(coalesce(p_reason,'')),'')), 300);
    if v_alasan is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,'sebab','Alasan Reprocessing wajib diisi'));
      continue;
    end if;

    -- 20261162240000: gross up dihitung ulang dari cashback hasil revisi.
    if c.customer_id is null then
      gagal := gagal || jsonb_build_array(jsonb_build_object('noDoc',v_doc,
        'sebab','Customer Master belum tersedia; lengkapi dulu di Key Master'));
      continue;
    end if;
    select coalesce(cu.tax_subject, c.tax_subject), ca.tax_status,
           coalesce(nullif(c.cashback_type_override, ''), ca.cashback_type)
      into v_subjek, v_pajak, v_jenis_gu
      from public.customers cu, public.campaigns ca
     where cu.id = c.customer_id and ca.id = c.campaign_id;
    v_gross := case when v_subjek is not null then rc_private.gross_up_klaim(v_baru, v_subjek, v_pajak, v_jenis_gu) end;

    update public.claims set
      cb_net = v_baru,
      gross_up = v_gross,
      tax_subject = v_subjek,
      status = 'not_yet',
      previous_status = null,
      -- Perpanjangan hanya berlaku selama dokumennya tertahan.
      extend_so_start = null, extend_so_end = null,
      extend_billing_start = null, extend_billing_end = null,
      version_no = version_no + 1,
      updated_at = now()
    where id = c.id;

    insert into public.claim_status_history(claim_id,actor_id,from_status,to_status,action,reason)
    values(c.id,actor,'on_hold','not_yet','reprocess',v_alasan);

    -- 20261163150000: tidak ada lagi log per dokumen (Log Activity: satu baris per proses dari
    -- layar); nilai lama/baru dikumpulkan untuk email.
    v_dok := v_dok || jsonb_build_object('claimId',c.id,'noDoc',c.no_doc,'depotId',c.depot_id,'status',c.status,
      'cbNetLama',c.cb_net,'cbNetBaru',v_baru,'alasan',v_alasan);
    n_ok := n_ok + 1;
  end loop;

  if n_ok > 0 then v_email := rc_private.email_kejadian_kirim('reprocess', v_dok, actor); end if;

  return jsonb_build_object('status','success','berhasil',n_ok,'email',v_email,
    'gagal',gagal,'jumlahGagal',jsonb_array_length(gagal),
    'message',n_ok||' dokumen kembali ke Not Yet'
      ||case when jsonb_array_length(gagal) > 0
             then ', '||jsonb_array_length(gagal)||' ditolak' else '' end);
end $function$;
-- Tanda tambalan untuk penjaga di atas saat dijalankan ulang.
comment on function public.rc_reprocessing_upload(jsonb,text) is 'Reprocessing Doc: alasan wajib, email per depot (20261163150000).';

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan (seluruhnya dibatalkan)
-- ------------------------------------------------------------------------------------------
do $uji$
declare v_sm uuid; e text := ''; v jsonb; r jsonb; d1 record; d2 record; d3 record; dh record; da record;
  c public.claims%rowtype; v_dep uuid; v_pen jsonb; v_o public.email_outbox%rowtype; v_galat text; n int; v_harap int;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_sm::text, 'role', 'authenticated')::text, true);

  -- A. Penerima: CC semua email + CC wajib jenisnya saja.
  begin
    update public.email_settings set cc_tambahan = array['semua@uji.invalid'],
      cc_per_jenis = '{"amend":["amend@uji.invalid"],"done":["done@uji.invalid"]}' where jenis = 'pengajuan';
    select id into v_dep from public.depots where archived_at is null order by depot_code limit 1;
    v_pen := rc_private.email_pengajuan_penerima(v_dep, 'amend');
    if not (v_pen->'cc' ? 'amend@uji.invalid') or not (v_pen->'cc' ? 'semua@uji.invalid') or (v_pen->'cc' ? 'done@uji.invalid') then
      e := e || ' CC amend: ' || (v_pen->'cc')::text || ';'; end if;
    v_pen := rc_private.email_pengajuan_penerima(v_dep);
    if (v_pen->'cc' ? 'amend@uji.invalid') or not (v_pen->'cc' ? 'semua@uji.invalid') then e := e || ' CC tanpa jenis: ' || (v_pen->'cc')::text || ';'; end if;
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' penerima galat: ' || sqlerrm || ';'; end if;
  end;

  -- B. Simpan / baca pengaturan CC wajib per jenis.
  begin
    r := public.rc_email_pengajuan_simpan(true, '["semua@uji.invalid"]', false, '', '{"amend":["Amend@Uji.invalid"],"approval":["appr@uji.invalid"]}');
    v := public.rc_email_pengajuan_baca();
    if v->'ccPerJenis'->'amend'->>0 is distinct from 'amend@uji.invalid' or v->'ccPerJenis'->'approval'->>0 is distinct from 'appr@uji.invalid' then
      e := e || ' simpan CC per jenis: ' || coalesce((v->'ccPerJenis')::text, 'null') || ';'; end if;
    r := public.rc_email_pengajuan_simpan(true, '[]', false, '', null);
    if (select cc_per_jenis->'amend'->>0 from public.email_settings where jenis = 'pengajuan') is distinct from 'amend@uji.invalid' then
      e := e || ' simpan tanpa CC per jenis mengosongkannya;'; end if;
    begin
      perform public.rc_email_pengajuan_simpan(true, '[]', false, '', '{"lainnya":["x@uji.invalid"]}'); e := e || ' jenis CC tak dikenal diterima;';
    exception when others then if sqlerrm !~ 'tidak dikenal' then e := e || ' pesan jenis CC: ' || sqlerrm || ';'; end if;
    end;
    begin
      perform public.rc_email_pengajuan_simpan(true, '[]', false, '', '{"done":["bukan-email"]}'); e := e || ' CC tidak sah diterima;';
    exception when others then if sqlerrm !~ 'tidak sah' then e := e || ' pesan CC tidak sah: ' || sqlerrm || ';'; end if;
    end;
    raise exception 'UJI_SELESAI';
  exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' pengaturan galat: ' || sqlerrm || ';'; end if;
  end;

  -- C. Amend banyak dokumen (Not Yet, Done, dan yang menunggu approval), alasan per baris atau
  --    umum, satu log per proses, email peringatan, Remark "Doc Amendment - <tahap>", amendBy.
  select c2.id, c2.no_doc, c2.version_no, c2.cb_net, c2.status into d1 from public.claims c2
   where c2.status = 'not_yet' and c2.archived_at is null and c2.customer_id is not null and c2.cb_net > 0 and c2.pending_approval is null
   order by c2.no_doc limit 1;
  select c2.id, c2.no_doc, c2.version_no, c2.cb_net, c2.status into d2 from public.claims c2
   where c2.status = 'done' and c2.archived_at is null and c2.customer_id is not null and c2.cb_net > 0 order by c2.no_doc limit 1;
  select c2.id, c2.no_doc, c2.version_no, c2.cb_net, c2.status into d3 from public.claims c2
   where c2.pending_approval is not null and c2.archived_at is null and c2.customer_id is not null order by c2.no_doc limit 1;
  if d1.no_doc is not null and d2.no_doc is not null then
    begin
      update public.email_settings set aktif = true, mode_uji = false, cc_per_jenis = '{"amend":["amend@uji.invalid"]}' where jenis = 'pengajuan';
      v_harap := case when d3.no_doc is null then 2 else 3 end;
      r := public.rc_amend_doc(jsonb_build_array(
          jsonb_build_object('noDoc', lower(d1.no_doc), 'cbNet', (trunc(d1.cb_net) + 1000)::text, 'versionNo', d1.version_no, 'alasan', 'Salah input nominal'),
          jsonb_build_object('noDoc', d2.no_doc, 'cbNet', (trunc(d2.cb_net) + 1)::text, 'versionNo', d2.version_no))
        || case when d3.no_doc is null then '[]'::jsonb
                else jsonb_build_array(jsonb_build_object('noDoc', d3.no_doc, 'cbNet', (trunc(d3.cb_net) + 1)::text)) end,
        'Koreksi umum');
      if (r->>'berhasil')::int <> v_harap then e := e || ' amend berhasil ' || (r->>'berhasil') || ';'; end if;
      select * into c from public.claims where id = d2.id;
      if c.status <> 'done' or c.cb_net <> trunc(d2.cb_net) + 1 then e := e || format(' amend Done: %s %s;', c.status, c.cb_net); end if;
      if coalesce(rc_private.claim_remark(c), '') !~ 'Doc Amendment - Done' then e := e || ' remark Done: ' || coalesce(rc_private.claim_remark(c), 'null') || ';'; end if;
      if not exists(select 1 from public.claim_status_history h where h.claim_id = d2.id and h.action = 'amend' and h.reason ~ 'Alasan: Koreksi umum') then
        e := e || ' alasan umum tidak tercatat;'; end if;
      if not exists(select 1 from public.claim_status_history h where h.claim_id = d1.id and h.action = 'amend' and h.reason ~ 'Alasan: Salah input nominal') then
        e := e || ' alasan per baris tidak tercatat;'; end if;
      if d3.no_doc is not null then
        select * into c from public.claims where id = d3.id;
        if c.pending_approval is null or c.status <> d3.status or c.cb_net <> trunc(d3.cb_net) + 1 then e := e || ' amend dokumen menunggu approval;'; end if;
      end if;
      if (select count(*) from public.activity_logs where event_type = 'amend_doc' and created_at = now()) <> 1
         or (select (details->>'jumlah')::int from public.activity_logs where event_type = 'amend_doc' and created_at = now() limit 1) <> v_harap then
        e := e || ' log amend bukan satu baris per proses;'; end if;
      if exists(select 1 from public.depots where id in (select depot_id from public.claims where id in (d1.id, d2.id)) and coalesce(email_to, '') <> '') then
        select * into v_o from public.email_outbox where konteks->>'aksi' = 'amend' and dibuat_pada = now() order by subjek limit 1;
        if v_o.id is null then e := e || ' email amend tidak diantrekan;';
        elsif v_o.subjek !~ '^Peringatan - Amend Doc' or v_o.isi_html !~ 'Mohon perhatian karena tindakan ini akan merubah total CB Net'
              or v_o.isi_html !~ 'STATUS AWAL' or v_o.isi_html !~ 'Team admin silakan konfirmasi ke OSC' or not ('amend@uji.invalid' = any(v_o.cc)) then
          e := e || ' isi email amend: ' || v_o.subjek || ' cc ' || array_to_string(v_o.cc, ',') || ';'; end if;
      end if;
      -- Amend kedua pada tahap yang sama tidak menggandakan Remark; tahap lain menambah satu.
      perform public.rc_amend_doc(jsonb_build_array(jsonb_build_object('noDoc', d2.no_doc, 'cbNet', (trunc(d2.cb_net) + 2)::text, 'alasan', 'Koreksi kedua')), '');
      select * into c from public.claims where id = d2.id;
      if rc_private.claim_remark(c) <> 'Doc Amendment - Done' then e := e || ' remark amend ganda: ' || rc_private.claim_remark(c) || ';'; end if;
      -- Analytics: Remark dan amendBy (Process by).
      v := public.rc_legacy_dashboard(1000, null, null);
      select x into r from jsonb_array_elements(v->'history') x where x->>'noDoc' = d2.no_doc;
      if r is null or r->>'remark' !~ 'Doc Amendment - Done' or jsonb_array_length(r->'amendBy') <> 2 or r->'amendBy'->0->>'dari' <> 'Done'
         or coalesce(r->'amendBy'->0->>'oleh', '') = '' then
        e := e || ' analytics amend: ' || coalesce(left(r::text, 300), 'tidak ada') || ';'; end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' amend galat: ' || sqlerrm || ';'; end if;
    end;
    -- Satu baris salah (tanpa alasan): tidak ada yang diubah.
    begin
      perform public.rc_amend_doc(jsonb_build_array(jsonb_build_object('noDoc', d1.no_doc, 'cbNet', '5000', 'alasan', 'ok'),
        jsonb_build_object('noDoc', d2.no_doc, 'cbNet', '6000')), '');
      e := e || ' amend tanpa alasan diterima;';
    exception when others then if sqlerrm !~ 'alasan wajib' then e := e || ' pesan tanpa alasan: ' || sqlerrm || ';'; end if;
    end;
    if (select cb_net from public.claims where id = d1.id) <> d1.cb_net then e := e || ' amend yang ditolak tetap mengubah;'; end if;
  end if;

  -- D. Reprocessing: alasan wajib, email per depot dengan alasan, tanpa log per dokumen.
  select c2.id, c2.no_doc, c2.cb_net, c2.depot_id into dh from public.claims c2
   where c2.status = 'on_hold' and c2.archived_at is null and c2.pending_approval is null and c2.customer_id is not null order by c2.no_doc limit 1;
  if dh.no_doc is not null then
    begin
      update public.email_settings set aktif = true, mode_uji = false, cc_per_jenis = '{"reprocess":["repro@uji.invalid"]}' where jenis = 'pengajuan';
      r := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', dh.no_doc, 'totalCashback', trunc(dh.cb_net)::text)), '');
      if (r->>'berhasil')::int <> 0 or coalesce(r->'gagal'->0->>'sebab', '') !~ 'Alasan Reprocessing wajib' then e := e || ' reprocess tanpa alasan: ' || r::text || ';'; end if;
      r := public.rc_reprocessing_upload(jsonb_build_array(jsonb_build_object('noDoc', dh.no_doc, 'totalCashback', (trunc(dh.cb_net) + 100)::text, 'alasan', 'Revisi nominal toko')), 'umum');
      select * into c from public.claims where id = dh.id;
      if (r->>'berhasil')::int <> 1 or c.status <> 'not_yet' then e := e || ' reprocess: ' || r::text || ';'; end if;
      if not exists(select 1 from public.claim_status_history h where h.claim_id = dh.id and h.action = 'reprocess' and h.reason = 'Revisi nominal toko') then
        e := e || ' alasan reprocess tidak tercatat;'; end if;
      if exists(select 1 from public.activity_logs where entity_id = dh.id and created_at = now()) then e := e || ' reprocess masih menulis log per dokumen;'; end if;
      if coalesce(rc_private.claim_remark(c), '') !~ 'Document Reprocessed' then e := e || ' remark reprocess;'; end if;
      if (select coalesce(email_to, '') from public.depots where id = dh.depot_id) <> '' then
        select * into v_o from public.email_outbox where konteks->>'aksi' = 'reprocess' and dibuat_pada = now() limit 1;
        if v_o.id is null or v_o.subjek !~ '^Reprocessing Doc' or v_o.isi_html !~ 'Revisi nominal toko' or not ('repro@uji.invalid' = any(v_o.cc)) then
          e := e || ' email reprocess: ' || coalesce(v_o.subjek, 'tidak ada') || ';'; end if;
      end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' reprocess galat: ' || sqlerrm || ';'; end if;
    end;
  end if;

  -- E. Proses klaim tidak lagi menulis log per dokumen.
  select c2.id, c2.no_doc, c2.version_no into da from public.claims c2 join public.campaigns ca on ca.id = c2.campaign_id and ca.status <> 'inactive'
   where c2.status = 'approved' and c2.archived_at is null and c2.pending_approval is null and c2.customer_id is not null order by c2.no_doc limit 1;
  if da.no_doc is not null then
    begin
      update public.email_settings set aktif = false where jenis = 'pengajuan';
      perform public.rc_process_claims('release', jsonb_build_array(jsonb_build_object('no_doc', da.no_doc, 'version_no', da.version_no)), gen_random_uuid(), '');
      if (select status from public.claims where id = da.id) <> 'released' then e := e || ' release uji tidak berjalan;'; end if;
      if exists(select 1 from public.activity_logs where entity_id = da.id and created_at = now()) then e := e || ' release masih menulis log per dokumen;'; end if;
      if not exists(select 1 from public.claim_status_history where claim_id = da.id and action = 'release' and created_at = now()) then
        e := e || ' riwayat release tidak tercatat;'; end if;
      raise exception 'UJI_SELESAI';
    exception when others then if sqlerrm <> 'UJI_SELESAI' then e := e || ' release galat: ' || sqlerrm || ';'; end if;
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end
$uji$;
