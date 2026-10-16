-- ==========================================================================================
-- Email Pengajuan - bagian 1: pengaturan, kop surat, penerima, dan penyusun isi
-- ==========================================================================================
-- Permintaan pemilik: setiap pengajuan depot (submitted), termasuk On Hold, Expired, Approval
-- dan Clearing, dikirimkan lewat email dengan format No Batch, Nama Campaign, Jumlah Toko,
-- Total CB dan Grand Total. Emailnya berkop merah dengan logo Nippon, dan ditutup tanda tangan
-- SA & SD Operations.
--
-- Tujuan email (ketetapan pemilik):
--   TO : alamat depot pada Depot Master
--   CC : seluruh sisanya - CC depot, OSC sesuai yurisdiksi, Supervisor, dan daftar email
--        tambahan yang dikelola di tab Email Pengajuan.
--
-- SAKELARNYA LAHIR DALAM KEADAAN MATI, mengikuti keputusan yang sudah berlaku pada email
-- otomatis: "seluruhnya NONAKTIF sampai dinyalakan dengan sadar". Alamat pada Depot Master
-- adalah alamat orang sungguhan, jadi fitur ini tidak boleh mulai mengirim hanya karena
-- migrasinya dijalankan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Pengaturan
-- ------------------------------------------------------------------------------------------
-- Menumpang pada email_settings yang sudah ada supaya hanya ada SATU tempat pengaturan email,
-- bukan dua yang harus dirawat berbarengan. Kolom jam dan hari tidak dipakai jenis ini karena
-- emailnya berangkat saat kejadian, bukan terjadwal.
do $pengaturan$
begin
  alter table public.email_settings drop constraint if exists email_settings_jenis_check;
  alter table public.email_settings add constraint email_settings_jenis_check
    check (jenis in ('daily','weekly','timetable','pengajuan'));

  alter table public.email_settings
    add column if not exists cc_tambahan text[] not null default '{}';

  -- Kolom jam dan hari_list dibiarkan pada bawaannya: jenis ini berangkat saat kejadian,
  -- bukan terjadwal, jadi keduanya memang tidak dipakai.
  insert into public.email_settings(jenis,aktif,subjek,catatan)
  values('pengajuan', false, 'RC Pengajuan',
         'Dikirim saat kejadian: Submitted, On Hold, Expired, Approval dan Clearing.')
  on conflict(jenis) do nothing;

  raise notice 'email_settings: jenis pengajuan tersedia (lahir NONAKTIF).';
end
$pengaturan$;

-- ------------------------------------------------------------------------------------------
-- 2. Kop surat: header merah dengan logo Nippon
-- ------------------------------------------------------------------------------------------
-- Logo dirujuk sebagai URL mutlak ke halaman yang sudah tayang, mengikuti cara yang sudah
-- dipakai diagram pada email lain. Klien email tidak mengambil berkas relatif, dan melampirkan
-- gambar sebagai CID membuat antreannya jauh lebih rumit tanpa hasil yang lebih baik.
create or replace function rc_private.email_kepala(p_judul text, p_anak_judul text default '')
returns text language sql immutable set search_path to '' as $fn$
  select
    '<div style="background:#C8102E;padding:16px 20px;border-radius:8px 8px 0 0;">'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"><tr>'
    || '<td width="44" valign="middle">'
    || '<img src="https://rc-next-gen.vercel.app/images/logo.png" width="36" height="36" '
    || 'alt="Nippon Paint" style="display:block;border-radius:6px;background:#ffffff;">'
    || '</td>'
    || '<td valign="middle" style="padding-left:12px;">'
    || '<div style="color:#ffffff;font-size:17px;font-weight:bold;line-height:1.3;">'
    || rc_private.html_aman(p_judul) || '</div>'
    || case when coalesce(btrim(p_anak_judul),'') = '' then ''
            else '<div style="color:#ffd9de;font-size:12px;line-height:1.4;margin-top:2px;">'
                 || rc_private.html_aman(p_anak_judul) || '</div>' end
    || '</td></tr></table></div>';
$fn$;

-- ------------------------------------------------------------------------------------------
-- 3. Tanda tangan, dengan kata-kata persis seperti yang diminta pemilik
-- ------------------------------------------------------------------------------------------
-- Berlaku untuk SELURUH email, bukan hanya yang baru. Dua identitas berbeda pada surat yang
-- berasal dari sistem yang sama hanya akan membingungkan penerimanya.
create or replace function rc_private.email_ttd()
returns text language sql stable set search_path to '' as $fn$
  select '<p style="margin-top:18px;line-height:1.6;">Regards,<br><strong>SA &amp; SD Operations</strong></p>'
    || '<p style="color:#5f6368;font-size:11px;border-top:1px solid #e0e2e6;padding-top:8px;margin-top:20px;line-height:1.6;">'
    || 'Jika ada kendala RC dapat melaporkan ke '
    || '<a href="mailto:sa_sd1@nipponpaint-indonesia.com" style="color:#5f6368;">sa_sd1@nipponpaint-indonesia.com</a><br>'
    || 'Data ditarik pada ' || rc_private.tgl_panjang(now()) || ' '
    || to_char(now() at time zone 'Asia/Jakarta','HH24:MI') || '. Email ini dikirim otomatis.</p>';
$fn$;

-- ------------------------------------------------------------------------------------------
-- 4. Penerima
-- ------------------------------------------------------------------------------------------
-- TO hanya alamat depot. Semua pihak lain masuk CC, sesuai ketetapan "semuanya cc kecuali
-- email to". Alamat yang sama tidak diulang, dan alamat yang sudah ada di TO dibuang dari CC -
-- surat yang mengirim orang yang sama dua kali terlihat seperti kesalahan.
create or replace function rc_private.email_pengajuan_penerima(p_depot uuid)
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_to text[]; v_cc text[]; v_dep public.depots%rowtype; v_tam text[];
begin
  select * into v_dep from public.depots where id = p_depot;

  -- Alamat pada Depot Master ditulis dipisah koma.
  select coalesce(array_agg(distinct lower(btrim(x))) filter (where btrim(x) <> ''), '{}')
    into v_to
    from unnest(string_to_array(coalesce(v_dep.email_to,''), ',')) x;

  select coalesce(cc_tambahan,'{}') into v_tam
    from public.email_settings where jenis='pengajuan';

  select coalesce(array_agg(distinct a) filter (where a <> ''), '{}')
    into v_cc
    from (
      -- CC yang tercatat pada Depot Master
      select lower(btrim(x)) a
        from unnest(string_to_array(coalesce(v_dep.email_cc,''), ',')) x
      union all
      -- OSC dan Supervisor yang benar-benar memegang depot ini
      select lower(btrim(coalesce(p.business_email,'')))
        from public.profiles p
        join public.user_depot_access uda on uda.user_id = p.id
       where uda.depot_id = p_depot
         and lower(coalesce(p.role,'')) in ('osc','supervisor')
         and coalesce(p.status,'') = 'active'
      union all
      -- Daftar tambahan yang dikelola di tab Email Pengajuan
      select lower(btrim(y)) from unnest(v_tam) y
    ) s
   where a is not null and a <> '' and a like '%@%';

  -- Alamat yang sudah menjadi tujuan utama tidak perlu ikut sebagai tembusan.
  select coalesce(array_agg(c),'{}') into v_cc
    from unnest(v_cc) c where not (c = any(coalesce(v_to,'{}')));

  return jsonb_build_object('to', to_jsonb(coalesce(v_to,'{}')),
                            'cc', to_jsonb(coalesce(v_cc,'{}')),
                            'depot', coalesce(v_dep.depot_name, v_dep.depot_code, ''));
end
$fn$;

-- ------------------------------------------------------------------------------------------
-- 5. Penyusun isi
-- ------------------------------------------------------------------------------------------
-- Satu baris per campaign - itulah yang membuat "jumlah toko" punya arti. Grand Total berdiri
-- sebagai baris tersendiri supaya angka yang paling dicari tidak perlu dijumlah sendiri oleh
-- pembacanya.
create or replace function rc_private.email_pengajuan_html(
  p_action text, p_batch text, p_ids uuid[], p_aktor uuid, p_alasan text default '')
returns text language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_judul text; v_depot text; v_html text; v_baris text := ''; v_r record;
  v_toko int := 0; v_cb numeric := 0; v_doc int := 0; v_nama text;
begin
  v_judul := case p_action
    when 'submit'              then 'Pengajuan Baru'
    when 'hold'                then 'Dokumen On Hold'
    when 'expire'              then 'Dokumen Expired'
    when 'expire_claim_process'then 'Dokumen Expired'
    when 'approve'             then 'Dokumen Disetujui'
    when 'clearing'            then 'Clearing Selesai'
    else initcap(replace(p_action,'_',' ')) end;

  select coalesce(d.depot_name, d.depot_code, '') into v_depot
    from public.claims c join public.depots d on d.id = c.depot_id
   where c.id = any(p_ids) limit 1;

  select coalesce(full_name, user_code, '') into v_nama
    from public.profiles where id = p_aktor;

  for v_r in
    select coalesce(ca.campaign_name, ca.campaign_code, '(tanpa campaign)') as campaign,
           count(distinct c.customer_id) as toko,
           count(*)                      as doc,
           coalesce(sum(c.cb_net),0)     as cb
      from public.claims c
      left join public.campaigns ca on ca.id = c.campaign_id
     where c.id = any(p_ids)
     group by 1
     order by 4 desc, 1
  loop
    v_toko := v_toko + v_r.toko;
    v_doc  := v_doc  + v_r.doc;
    v_cb   := v_cb   + v_r.cb;
    v_baris := v_baris
      || '<tr>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;white-space:nowrap;">'
         || rc_private.html_aman(coalesce(p_batch,'-')) || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;">'
         || rc_private.html_aman(v_r.campaign) || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;text-align:right;">'
         || v_r.toko::text || '</td>'
      || '<td style="padding:8px 10px;border-bottom:1px solid #eceff1;font-size:12px;text-align:right;white-space:nowrap;">'
         || rc_private.rupiah(v_r.cb) || '</td>'
      || '</tr>';
  end loop;

  v_html :=
    rc_private.email_kepala('RC ' || v_judul,
      'Depot ' || coalesce(nullif(v_depot,''),'-')
      || case when coalesce(p_batch,'') <> '' then '  |  Batch ' || p_batch else '' end)
    || '<div style="border:1px solid #e0e2e6;border-top:none;border-radius:0 0 8px 8px;padding:18px 20px;">'
    || '<p style="line-height:1.6;margin-top:0;">'
    || rc_private.html_aman(v_judul) || ' sebanyak <strong>' || v_doc::text
    || '</strong> dokumen oleh <strong>' || rc_private.html_aman(coalesce(nullif(v_nama,''),'-'))
    || '</strong> pada ' || rc_private.tgl_panjang(now()) || ' '
    || to_char(now() at time zone 'Asia/Jakarta','HH24:MI') || ' WIB.</p>'
    || case when coalesce(btrim(p_alasan),'') = '' then ''
            else '<p style="line-height:1.6;background:#fff8e1;border-left:3px solid #f0ad4e;'
                 || 'padding:8px 12px;margin:12px 0;font-size:12px;"><strong>Alasan:</strong> '
                 || rc_private.html_aman(p_alasan) || '</p>' end
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" '
    || 'style="border-collapse:collapse;margin-top:12px;">'
    || '<thead><tr style="background:#f5f6f7;">'
    || '<th align="left"  style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">NO BATCH</th>'
    || '<th align="left"  style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">NAMA CAMPAIGN</th>'
    || '<th align="right" style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">JUMLAH TOKO</th>'
    || '<th align="right" style="padding:8px 10px;font-size:11px;color:#5f6368;border-bottom:2px solid #e0e2e6;">TOTAL CB</th>'
    || '</tr></thead><tbody>' || v_baris || '</tbody>'
    || '<tfoot><tr style="background:#fdecef;">'
    || '<td colspan="2" style="padding:10px;font-size:12px;font-weight:bold;color:#C8102E;">GRAND TOTAL</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;">'
       || v_toko::text || '</td>'
    || '<td style="padding:10px;font-size:12px;font-weight:bold;text-align:right;color:#C8102E;white-space:nowrap;">'
       || rc_private.rupiah(v_cb) || '</td>'
    || '</tr></tfoot></table>'
    || rc_private.email_ttd()
    || '</div>';

  return '<div style="font-family:Arial,Helvetica,sans-serif;color:#202124;max-width:640px;">'
         || v_html || '</div>';
end
$fn$;

revoke all on function rc_private.email_kepala(text,text) from public, anon, authenticated;
revoke all on function rc_private.email_pengajuan_penerima(uuid) from public, anon, authenticated;
revoke all on function rc_private.email_pengajuan_html(text,text,uuid[],uuid,text) from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_ids uuid[]; v_dep uuid; h text; pen jsonb; v_act uuid;
begin
  if not exists (select 1 from public.email_settings where jenis='pengajuan') then
    raise exception 'GAGAL: baris pengaturan pengajuan tidak terbentuk.'; end if;
  if (select aktif from public.email_settings where jenis='pengajuan') then
    raise exception 'GAGAL: email pengajuan lahir dalam keadaan AKTIF. Harus nonaktif.'; end if;

  -- Satu depot saja: email pengajuan memang selalu tentang satu depot.
  select depot_id into v_dep from public.claims
   where archived_at is null and depot_id is not null
   order by no_doc limit 1;
  if v_dep is null then raise notice 'Tidak ada klaim untuk diperiksa; dilewati.'; return; end if;
  select array_agg(id) into v_ids
    from (select id from public.claims
           where archived_at is null and depot_id = v_dep
           order by no_doc limit 5) c;

  pen := rc_private.email_pengajuan_penerima(v_dep);
  if not (pen ? 'to' and pen ? 'cc') then
    raise exception 'GAGAL: penerima tidak membawa to dan cc.'; end if;

  select id into v_act from public.profiles order by user_code limit 1;
  h := rc_private.email_pengajuan_html('submit','B0125-01', v_ids, v_act, '');
  if position('GRAND TOTAL' in h) = 0 then
    raise exception 'GAGAL: isi email tanpa Grand Total.'; end if;
  if position('SA &amp; SD Operations' in h) = 0 then
    raise exception 'GAGAL: tanda tangan SA & SD Operations tidak ada.'; end if;
  if position('sa_sd1@nipponpaint-indonesia.com' in h) = 0 then
    raise exception 'GAGAL: alamat pelaporan kendala tidak ada.'; end if;
  if position('#C8102E' in h) = 0 then
    raise exception 'GAGAL: kop merah tidak ada.'; end if;
  if position('/images/logo.png' in h) = 0 then
    raise exception 'GAGAL: logo Nippon tidak ada.'; end if;
  if position('NAMA CAMPAIGN' in h) = 0 or position('JUMLAH TOKO' in h) = 0
     or position('TOTAL CB' in h) = 0 or position('NO BATCH' in h) = 0 then
    raise exception 'GAGAL: kolom yang diminta tidak lengkap.'; end if;

  -- Nominal ditulis dengan pemisah titik dan tanpa desimal, sama seperti di layar. Koma di
  -- sini berarti to_char mengikuti locale server, bukan kebiasaan pembacanya.
  if h ~ 'Rp [0-9]+,[0-9]{3}' then
    raise exception 'GAGAL: nominal memakai koma sebagai pemisah ribuan.'; end if;
  if h ~ 'Rp [0-9.]+,[0-9]{1,2}<' then
    raise exception 'GAGAL: nominal masih memuat desimal.'; end if;

  raise notice 'Pemeriksaan lolos. TO: % alamat, CC: % alamat.',
    jsonb_array_length(pen->'to'), jsonb_array_length(pen->'cc');
end
$periksa$;
