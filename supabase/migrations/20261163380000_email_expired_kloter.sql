-- ==========================================================================================
-- Email Expired (hangus) direkap per kloter 12:00 dan 16:00. Pemilik, 22 Oktober 2026:
--   "untuk email expired supaya ga satu per satu tiap jam 12 dan 4 aja, jadi yang lewat rentang
--    jam itu akan dikirimkan ke kloter selanjutnya, dan ini tetep dikirim per depo. Hanya aja
--    direkap dulu baru kirim." dan "untuk email hangus saya mau summary per depo yang pertama".
-- ==========================================================================================
-- * Saat dokumen di-Expired (expire / expire_claim_process), email tidak langsung dibuat; prosesnya
--   dicatat di rc_private.email_expired_antrean. Email On Hold, Pengajuan, Approval, Done tetap
--   langsung seperti sebelumnya.
-- * Kloter: 12:00 dan 16:00 WIB. Proses sebelum 12:00 masuk kloter 12:00; 12:00-16:00 masuk kloter
--   16:00; sesudah 16:00 masuk kloter 12:00 besok. Dikirim oleh penjadwal email (rc_email_tick,
--   menit ke-5 tiap jam) begitu batas kloter lewat.
-- * Tetap satu email per depot, penerima sama dengan email Expired sebelumnya (Email Pengajuan:
--   TO Depot Master, CC OSC / Supervisor depot + CC semua email + CC wajib On Hold & Expired),
--   Mode Uji dan sakelar aktif Email Pengajuan tetap berlaku.
-- * Isi: Summary depot di bagian pertama (jumlah batch, dokumen, toko, total CB hangus), lalu
--   detail per batch dan campaign (diproses oleh, waktu, alasan).
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- ---- 1. Antrean proses Expired -----------------------------------------------------------------
create table if not exists rc_private.email_expired_antrean (
  id bigint generated always as identity primary key,
  aksi text not null,
  batch text,
  claim_ids uuid[] not null,
  aktor uuid,
  alasan text not null default '',
  dibuat_pada timestamptz not null default now(),
  kloter timestamptz,            -- batas kloter saat direkap (null = menunggu)
  diproses_pada timestamptz,
  outbox_ids uuid[] not null default '{}'
);
create index if not exists email_expired_antrean_tunggu on rc_private.email_expired_antrean(dibuat_pada) where kloter is null;
revoke all on rc_private.email_expired_antrean from public, anon, authenticated;

-- Batas kloter terakhir yang sudah lewat (12:00 atau 16:00 WIB, <= p_t).
create or replace function rc_private.email_expired_batas(p_t timestamptz) returns timestamptz
language sql immutable set search_path = '' as $f$
  select max(b) from (
    select (date_trunc('day', p_t at time zone 'Asia/Jakarta') - make_interval(days => d) + make_interval(hours => h)) at time zone 'Asia/Jakarta' b
      from unnest(array[0, 1]) d, unnest(array[12, 16]) h) x
   where b <= p_t;
$f$;

-- ---- 2. Isi email rekap satu depot --------------------------------------------------------------
create or replace function rc_private.email_expired_html(p_ant bigint[], p_depot uuid, p_batas timestamptz) returns text
language plpgsql stable security definer set search_path = '' as $f$
declare
  v_th text := 'padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;';
  v_td text := 'padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;';
  v_depot text; v_kode text; v_batch int; v_doc int; v_toko int; v_cb numeric; v_baris text; v_ids uuid[]; v_bd text := '';
  v_kloter text := to_char(p_batas at time zone 'Asia/Jakarta', 'HH24:MI');
begin
  select coalesce(d.depot_name, d.depot_code, ''), coalesce(d.depot_code, '') into v_depot, v_kode from public.depots d where d.id = p_depot;

  select count(distinct coalesce(a.batch, a.id::text)), count(distinct c.id), count(distinct c.customer_id), coalesce(sum(c.cb_net), 0),
         array_agg(distinct c.id)
    into v_batch, v_doc, v_toko, v_cb, v_ids
    from rc_private.email_expired_antrean a cross join lateral unnest(a.claim_ids) x(id) join public.claims c on c.id = x.id
   where a.id = any(p_ant) and c.depot_id = p_depot;

  select string_agg('<tr>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(coalesce(t.batch, '-')) || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(t.campaign) || '</td>'
      || '<td style="' || v_td || 'text-align:right;">' || t.toko::text || '</td>'
      || '<td style="' || v_td || 'text-align:right;white-space:nowrap;">' || rc_private.rupiah(t.cb) || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(t.oleh) || '</td>'
      || '<td style="' || v_td || 'white-space:nowrap;">' || rc_private.html_aman(t.waktu) || '</td>'
      || '<td style="' || v_td || '">' || rc_private.html_aman(coalesce(nullif(t.alasan, ''), '-')) || '</td>'
      || '</tr>', '' order by t.dibuat_pada, t.id, t.cb desc, t.campaign)
    into v_baris
    from (select a.id, a.dibuat_pada, a.batch, a.alasan,
                 coalesce(ca.campaign_name, ca.campaign_code, '(tanpa campaign)') campaign,
                 count(distinct c.customer_id) toko, coalesce(sum(c.cb_net), 0) cb,
                 coalesce(nullif(btrim(pr.full_name), ''), pr.user_code, '-') oleh,
                 to_char(a.dibuat_pada at time zone 'Asia/Jakarta', 'DD-Mon-YYYY HH24:MI') waktu
            from rc_private.email_expired_antrean a cross join lateral unnest(a.claim_ids) x(id)
            join public.claims c on c.id = x.id
            left join public.campaigns ca on ca.id = c.campaign_id
            left join public.profiles pr on pr.id = a.aktor
           where a.id = any(p_ant) and c.depot_id = p_depot
           group by a.id, a.dibuat_pada, a.batch, a.alasan, 5, pr.full_name, pr.user_code) t;

  -- Remark Bad Debt (bila fitur Upload Debtor sudah terpasang di lingkungan ini).
  if to_regprocedure('rc_private.email_remark_bad_debt(uuid[])') is not null then
    execute 'select rc_private.email_remark_bad_debt($1)' into v_bd using v_ids;
  end if;

  return rc_private.email_outlook(
    rc_private.email_kepala(rc_private.email_pengajuan_subjek('expire', array[coalesce(nullif(v_depot, ''), 'Depot')]),
      'Depo ' || coalesce(nullif(v_depot, ''), '-') || '  |  Rekap kloter ' || v_kloter || ' ' || rc_private.tgl_panjang(p_batas)
      || '  |  ' || coalesce(v_doc, 0)::text || ' dokumen')
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">'
    || '<tr><td style="border:1px solid #e0e2e6;border-top:none;padding:18px 20px;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    || '<p style="line-height:1.6;">Berikut rekap pengajuan claim cashback Depo <strong>' || rc_private.html_aman(coalesce(nullif(v_depot, ''), '-'))
    || '</strong> yang dihanguskan (Expired) sampai kloter <strong>' || v_kloter || ' WIB, ' || rc_private.tgl_panjang(p_batas) || '</strong>.</p>'
    -- Summary depot di bagian pertama.
    || '<p style="line-height:1.6;margin:16px 0 6px;font-weight:bold;">Summary</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left" style="' || v_th || '">DEPOT</th><th align="right" style="' || v_th || '">JUMLAH BATCH</th>'
    || '<th align="right" style="' || v_th || '">JUMLAH DOKUMEN</th><th align="right" style="' || v_th || '">JUMLAH TOKO</th>'
    || '<th align="right" style="' || v_th || '">TOTAL CB HANGUS</th></tr></thead><tbody><tr style="background:#fdecef;">'
    || '<td style="' || v_td || 'font-weight:bold;">' || rc_private.html_aman(v_kode || ' - ' || v_depot) || '</td>'
    || '<td style="' || v_td || 'text-align:right;font-weight:bold;">' || coalesce(v_batch, 0)::text || '</td>'
    || '<td style="' || v_td || 'text-align:right;font-weight:bold;">' || coalesce(v_doc, 0)::text || '</td>'
    || '<td style="' || v_td || 'text-align:right;font-weight:bold;">' || coalesce(v_toko, 0)::text || '</td>'
    || '<td style="' || v_td || 'text-align:right;font-weight:bold;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(coalesce(v_cb, 0)) || '</td>'
    || '</tr></tbody></table>'
    -- Detail per batch dan campaign.
    || '<p style="line-height:1.6;margin:20px 0 6px;font-weight:bold;">Detail</p>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="border-collapse:collapse;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left" style="' || v_th || '">NO BATCH</th><th align="left" style="' || v_th || '">NAMA CAMPAIGN</th>'
    || '<th align="right" style="' || v_th || '">JUMLAH TOKO</th><th align="right" style="' || v_th || '">TOTAL CB</th>'
    || '<th align="left" style="' || v_th || '">DIPROSES OLEH</th><th align="left" style="' || v_th || '">WAKTU</th>'
    || '<th align="left" style="' || v_th || '">ALASAN</th></tr></thead><tbody>' || coalesce(v_baris, '') || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;"><td colspan="2" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">GRAND TOTAL</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;">' || coalesce(v_toko, 0)::text || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">' || rc_private.rupiah(coalesce(v_cb, 0)) || '</td>'
    || '<td colspan="3" style="padding:10px;"></td></tr></tfoot></table>'
    || coalesce(v_bd, '')
    || '<p style="line-height:1.6;margin-top:16px;">Mohon tim Depo untuk mencatat dokumen yang dihanguskan pada batch tersebut.</p>'
    || rc_private.email_ttd()
    || '</td></tr></table>');
end $f$;

-- ---- 3. Rekap kloter ----------------------------------------------------------------------------
create or replace function rc_private.email_expired_kloter(p_sekarang timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = '' as $f$
declare
  v_batas timestamptz := rc_private.email_expired_batas(p_sekarang); v_ant bigint[]; v_dep record; v_pen jsonb;
  v_to text[]; v_cc text[]; v_html text; v_subjek text; v_id uuid; v_ids uuid[] := '{}'; v_aktif boolean; v_uji boolean;
  v_alamat text; v_spanduk text; v_qty integer;
begin
  -- Proses sebelum batas kloter yang belum direkap diambil sekaligus ditandai (atomik).
  with u as (update rc_private.email_expired_antrean set kloter = v_batas, diproses_pada = now()
              where kloter is null and dibuat_pada < v_batas returning id)
  select array_agg(id order by id) into v_ant from u;
  if v_ant is null then
    return jsonb_build_object('status', 'success', 'kloter', v_batas, 'email', 0);
  end if;

  select aktif, mode_uji, btrim(coalesce(email_uji, '')) into v_aktif, v_uji, v_alamat from public.email_settings where jenis = 'pengajuan';
  if not coalesce(v_aktif, false) then
    return jsonb_build_object('status', 'success', 'kloter', v_batas, 'email', 0, 'proses', cardinality(v_ant),
                              'catatan', 'Email Pengajuan nonaktif; rekap tidak dikirim');
  end if;
  v_uji := coalesce(v_uji, false) and coalesce(v_alamat, '') <> '';

  for v_dep in
    select c.depot_id, coalesce(d.depot_name, d.depot_code, '') nama, count(distinct c.id) qty,
           array_agg(distinct coalesce(a.batch, '-')) batch
      from rc_private.email_expired_antrean a cross join lateral unnest(a.claim_ids) x(id)
      join public.claims c on c.id = x.id
      left join public.depots d on d.id = c.depot_id
     where a.id = any(v_ant) and c.depot_id is not null
     group by c.depot_id, 2
     order by 2
  loop
    v_pen := rc_private.email_pengajuan_penerima(v_dep.depot_id, 'hold_expired');
    v_to := array(select jsonb_array_elements_text(v_pen->'to'));
    v_cc := array(select jsonb_array_elements_text(v_pen->'cc'));
    if coalesce(array_length(v_to, 1), 0) = 0 and not v_uji then
      insert into public.activity_logs(depot_id, event_type, details)
      values (v_dep.depot_id, 'email_pengajuan_tanpa_tujuan',
              jsonb_build_object('aksi', 'expire', 'kloter', v_batas, 'sebab', 'Alamat email depot belum diisi di Depot Master'));
      continue;
    end if;

    v_html := rc_private.email_expired_html(v_ant, v_dep.depot_id, v_batas);
    v_subjek := rc_private.email_pengajuan_subjek('expire', array[coalesce(nullif(v_dep.nama, ''), 'Depot')])
                || ' - Rekap ' || rc_private.tgl_panjang(v_batas) || ' ' || to_char(v_batas at time zone 'Asia/Jakarta', 'HH24:MI');
    if v_uji then
      v_spanduk := '<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;padding:12px 16px;'
        || 'border-radius:8px;margin-bottom:12px;max-width:640px;"><div style="font-size:13px;font-weight:bold;margin-bottom:6px;">'
        || 'MODE UJI &mdash; surat ini TIDAK dikirim ke depot</div><div style="font-size:11px;line-height:1.7;color:#d1d5db;">Seharusnya dikirim ke<br>'
        || '<strong style="color:#ffffff;">TO</strong> (' || coalesce(array_length(v_to, 1), 0)::text || '): '
        || rc_private.html_aman(coalesce(nullif(array_to_string(v_to, ', '), ''), 'BELUM ADA ALAMAT DEPOT DI DEPOT MASTER')) || '<br>'
        || '<strong style="color:#ffffff;">CC</strong> (' || coalesce(array_length(v_cc, 1), 0)::text || '): '
        || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc, ', '), ''), 'tidak ada')) || '</div></div>';
      v_html := v_spanduk || v_html;
      v_subjek := '[UJI] ' || v_subjek;
      v_to := array[v_alamat];
      v_cc := '{}';
    end if;

    insert into public.email_outbox(jenis, tujuan, cc, subjek, isi_html, konteks)
    values ('pengajuan', v_to, v_cc, v_subjek, v_html,
            jsonb_build_object('aksi', 'expire', 'kloter', v_batas, 'depot', v_dep.depot_id, 'qty', v_dep.qty,
                               'batch', to_jsonb(v_dep.batch), 'antrean', to_jsonb(v_ant), 'modeUji', v_uji))
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  update rc_private.email_expired_antrean set outbox_ids = v_ids where id = any(v_ant);
  return jsonb_build_object('status', 'success', 'kloter', v_batas, 'email', cardinality(v_ids), 'proses', cardinality(v_ant));
end $f$;

revoke all on function rc_private.email_expired_batas(timestamptz), rc_private.email_expired_html(bigint[], uuid, timestamptz),
  rc_private.email_expired_kloter(timestamptz) from public, anon, authenticated;

-- ---- 4. Tambalan bertanda ------------------------------------------------------------------------
do $tambal$
declare src text;
begin
  -- email_pengajuan_antre: Expired dicatat untuk kloter, tidak langsung dibuat emailnya.
  src := replace(pg_get_functiondef('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)'::regprocedure), E'\r', '');
  if src !~ '20261163380000' then
    src := pg_temp.ganti(src, $p$  if not coalesce(v_aktif,false) then return 0; end if;$p$,
      $p$  if not coalesce(v_aktif,false) then return 0; end if;

  -- 20261163380000: Expired direkap per depot dan dikirim pada kloter 12:00 / 16:00
  -- (rc_private.email_expired_kloter lewat rc_email_tick).
  if p_action in ('expire','expire_claim_process') then
    insert into rc_private.email_expired_antrean(aksi, batch, claim_ids, aktor, alasan)
    values (p_action, p_batch, p_ids, p_aktor, coalesce(p_alasan,''));
    return 0;
  end if;$p$, 1, 'email_pengajuan_antre kloter');
    execute src;
  end if;

  -- rc_email_tick: rekap Expired dikirim begitu batas kloter lewat; kegagalannya dicatat.
  src := replace(pg_get_functiondef('public.rc_email_tick()'::regprocedure), E'\r', '');
  if src !~ '20261163380000' then
    src := pg_temp.ganti(src, $p$  perform public.rc_email_jalankan_antrean(50);$p$,
      $p$  -- 20261163380000: rekap email Expired per kloter 12:00 / 16:00.
  begin
    perform rc_private.email_expired_kloter(sekarang);
  exception when others then
    insert into public.activity_logs(event_type, details)
    values ('email_terjadwal_gagal', jsonb_build_object('jenis', 'expired', 'sebab', left(sqlerrm, 500)));
  end;

  perform public.rc_email_jalankan_antrean(50);$p$, 1, 'rc_email_tick kloter');
    execute src;
  end if;
end $tambal$;

update public.email_settings
   set catatan = 'Dikirim saat kejadian: Submitted, On Hold, Approval dan Clearing. Expired direkap per depot dan dikirim pada kloter 12:00 dan 16:00.'
 where jenis = 'pengajuan' and catatan = 'Dikirim saat kejadian: Submitted, On Hold, Expired, Approval dan Clearing.';
