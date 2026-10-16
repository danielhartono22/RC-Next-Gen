-- ==========================================================================================
-- Email Pengajuan: subjek, wording, dan kop dengan kedua logo
-- ==========================================================================================
-- Subjek mengikuti ketetapan pemilik:
--
--   Submitted : Approval - Pengajuan Claim Cashback <depo>
--   Approved  : Approved - Pengajuan Claim Cashback Depo <depo>
--   Done      : Done - Pengajuan Claim Cashback
--
-- Nama depo boleh lebih dari satu; bila LEBIH DARI TIGA, namanya tidak disebutkan sama sekali.
-- Aturan itu masuk akal: subjek yang memanjang berisi belasan nama tidak lagi terbaca di daftar
-- kotak masuk, justru pada tempat yang paling menentukan surat itu dibuka atau tidak.
--
-- Wordingnya mengikuti kalimat yang ditulis pemilik, dirapikan seperlunya - permintaan aksinya
-- dibiarkan persis karena di situlah maksud suratnya:
--
--   Submitted : Mohon tim Management untuk segera melakukan approval
--   Approved  : Mohon tim OSC untuk segera memproses dokumen yang sudah di-approve
--   Done      : Mohon tim Depo cek kembali list toko di no batch tersebut
--
-- On Hold dan Expired tidak disebutkan pemilik. Keduanya tetap perlu kalimat, jadi ditulis
-- dengan suara yang sama dan ditandai di sini supaya mudah diganti bila ternyata berbeda.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Kop surat: logo Nippon dan maskot RC, keduanya inline
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_kepala(p_judul text, p_anak_judul text default '')
returns text language sql immutable set search_path to '' as $fn$
  select
    '<div style="background:#C8102E;padding:16px 20px;border-radius:8px 8px 0 0;">'
    || '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"><tr>'
    || '<td width="40" valign="middle">'
    || '<img src="cid:logo" width="34" height="34" alt="Nippon Paint" '
    || 'style="display:block;border-radius:6px;background:#ffffff;">'
    || '</td>'
    || '<td valign="middle" style="padding-left:12px;">'
    || '<div style="color:#ffffff;font-size:17px;font-weight:bold;line-height:1.3;">'
    || rc_private.html_aman(p_judul) || '</div>'
    || case when coalesce(btrim(p_anak_judul),'') = '' then ''
            else '<div style="color:#ffd9de;font-size:12px;line-height:1.4;margin-top:2px;">'
                 || rc_private.html_aman(p_anak_judul) || '</div>' end
    || '</td>'
    -- Maskot RC di ujung kanan: penanda cepat bahwa surat ini datang dari Resource Collection,
    -- bukan dari salah satu sistem Nippon yang lain.
    || '<td width="44" valign="middle" align="right">'
    || '<img src="cid:blobby" width="38" height="38" alt="Resource Collection" '
    || 'style="display:block;">'
    || '</td>'
    || '</tr></table></div>';
$fn$;

-- ------------------------------------------------------------------------------------------
-- 2. Penyusun subjek
-- ------------------------------------------------------------------------------------------
-- Lebih dari tiga depo: namanya tidak disebutkan. Mengembalikan null, bukan teks kosong, supaya
-- pemanggilnya ikut membuang spasi pemisahnya lewat coalesce.
create or replace function rc_private.email_daftar_depot(p_depot text[])
returns text language sql immutable set search_path to '' as $fn$
  select case
    when coalesce(array_length(p_depot,1),0) = 0 then null
    when array_length(p_depot,1) > 3 then null
    else array_to_string(p_depot, ', ') end;
$fn$;

create or replace function rc_private.email_pengajuan_subjek(p_action text, p_depot text[])
returns text language sql immutable set search_path to '' as $fn$
  select case p_action
    when 'submit' then 'Approval - Pengajuan Claim Cashback'
      || coalesce(' ' || rc_private.email_daftar_depot(p_depot), '')
    when 'approve' then 'Approved - Pengajuan Claim Cashback Depo'
      || coalesce(' ' || rc_private.email_daftar_depot(p_depot), '')
    when 'clearing' then 'Done - Pengajuan Claim Cashback'
    when 'hold' then 'On Hold - Pengajuan Claim Cashback'
      || coalesce(' ' || rc_private.email_daftar_depot(p_depot), '')
    when 'expire' then 'Expired - Pengajuan Claim Cashback'
      || coalesce(' ' || rc_private.email_daftar_depot(p_depot), '')
    when 'expire_claim_process' then 'Expired - Pengajuan Claim Cashback'
      || coalesce(' ' || rc_private.email_daftar_depot(p_depot), '')
    else 'Pengajuan Claim Cashback' end;
$fn$;


-- ------------------------------------------------------------------------------------------
-- 3. Isi surat
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.email_pengajuan_html(
  p_action text, p_batch text, p_ids uuid[], p_aktor uuid, p_alasan text default '')
returns text language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_judul text; v_depot text; v_kode text; v_baris text := ''; v_r record;
  v_toko int := 0; v_cb numeric := 0; v_doc int := 0; v_nama text;
  v_pembuka text; v_aksi text; v_campaign text; v_html text;
begin
  v_judul := case p_action
    when 'submit'               then 'Pengajuan Claim Cashback'
    when 'approve'              then 'Approved - Claim Cashback'
    when 'clearing'             then 'Done - Claim Cashback'
    when 'hold'                 then 'On Hold - Claim Cashback'
    when 'expire'               then 'Expired - Claim Cashback'
    when 'expire_claim_process' then 'Expired - Claim Cashback'
    else initcap(replace(p_action,'_',' ')) end;

  select coalesce(d.depot_name, d.depot_code, ''), coalesce(d.depot_code,'')
    into v_depot, v_kode
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

  -- Done menyebutkan kode depo dan campaign apa saja, sesuai permintaan pemilik.
  select string_agg(distinct coalesce(ca.campaign_name, ca.campaign_code), ', ')
    into v_campaign
    from public.claims c left join public.campaigns ca on ca.id = c.campaign_id
   where c.id = any(p_ids);

  v_pembuka := case p_action
    when 'submit' then
      'Berikut terlampir pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong>.'
    when 'approve' then
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang telah disetujui.'
    when 'clearing' then
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_kode,''),'-')) || ' &ndash; '
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang telah selesai diproses.'
      || '<br>Campaign: <strong>' || rc_private.html_aman(coalesce(v_campaign,'-')) || '</strong>'
    when 'hold' then
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang ditahan sementara.'
    else
      'Berikut pengajuan claim cashback Depo <strong>'
      || rc_private.html_aman(coalesce(nullif(v_depot,''),'-')) || '</strong> yang dihanguskan.'
    end;

  v_aksi := case p_action
    when 'submit'   then 'Mohon tim Management untuk segera melakukan approval atas pengajuan di atas.'
    when 'approve'  then 'Mohon tim OSC untuk segera memproses dokumen yang sudah di-approve.'
    when 'clearing' then 'Mohon tim Depo untuk mengecek kembali list toko pada nomor batch tersebut.'
    -- Kedua kalimat di bawah TIDAK ditetapkan pemilik; ditulis mengikuti suara yang sama.
    when 'hold'     then 'Mohon tim Depo untuk menindaklanjuti dokumen yang ditahan pada batch tersebut.'
    else                 'Mohon tim Depo untuk mencatat dokumen yang dihanguskan pada batch tersebut.'
    end;

  v_html :=
    rc_private.email_kepala(v_judul,
      'Depo ' || coalesce(nullif(v_depot,''),'-')
      || case when coalesce(p_batch,'') <> '' then '  |  Batch ' || p_batch else '' end)
    || '<div style="border:1px solid #e0e2e6;border-top:none;border-radius:0 0 8px 8px;padding:18px 20px;">'
    || '<p style="line-height:1.6;margin-top:0;">Dear All,</p>'
    || '<p style="line-height:1.6;">' || v_pembuka || '</p>'
    || '<p style="line-height:1.6;color:#5f6368;font-size:12px;">'
    || 'Diproses oleh <strong>' || rc_private.html_aman(coalesce(nullif(v_nama,''),'-'))
    || '</strong> pada ' || rc_private.tgl_panjang(now()) || ' '
    || to_char(now() at time zone 'Asia/Jakarta','HH24:MI') || ' WIB &middot; '
    || v_doc::text || ' dokumen.</p>'
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
    || '<p style="line-height:1.6;margin-top:16px;">' || v_aksi || '</p>'
    || rc_private.email_ttd()
    || '</div>';

  return '<div style="font-family:Arial,Helvetica,sans-serif;color:#202124;max-width:640px;">'
         || v_html || '</div>';
end
$fn$;

revoke all on function rc_private.email_kepala(text,text) from public, anon, authenticated;
revoke all on function rc_private.email_pengajuan_subjek(text,text[]) from public, anon, authenticated;
revoke all on function rc_private.email_daftar_depot(text[]) from public, anon, authenticated;
revoke all on function rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)
  from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Pengantre memakai subjek yang baru
-- ------------------------------------------------------------------------------------------
do $kait$
declare src text; baru text; pola text;
begin
  select pg_get_functiondef(p.oid) into src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='rc_private' and p.proname='email_pengajuan_antre';
  if src is null then raise exception 'rc_private.email_pengajuan_antre tidak ditemukan.'; end if;
  if position('email_pengajuan_subjek' in src) > 0 then
    raise notice 'Pengantre sudah memakai subjek baru; dilewati.'; return; end if;

  pola := '      ''RC '' || v_judul || '' - '' || coalesce(nullif(v_dep.nama,''''),''Depot'')' || chr(10) ||
          '        || case when coalesce(p_batch,'''') <> '''' then '' - '' || p_batch else '''' end,';
  if position(pola in src) = 0 then
    raise exception 'Pola penyusunan subjek tidak ditemukan pada email_pengajuan_antre.'; end if;

  baru := replace(src, pola,
    '      rc_private.email_pengajuan_subjek(p_action, array[coalesce(nullif(v_dep.nama,''''),''Depot'')]),');
  execute baru;
  raise notice 'email_pengajuan_antre memakai subjek baru.';
end
$kait$;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare v_ids uuid[]; v_dep uuid; v_act uuid; h text; s text;
begin
  -- Subjek: ketiga bentuk yang ditetapkan pemilik.
  s := rc_private.email_pengajuan_subjek('submit', array['Medan']);
  if s <> 'Approval - Pengajuan Claim Cashback Medan' then
    raise exception 'GAGAL: subjek submitted -> %', s; end if;
  s := rc_private.email_pengajuan_subjek('approve', array['Medan','Jakarta']);
  if s <> 'Approved - Pengajuan Claim Cashback Depo Medan, Jakarta' then
    raise exception 'GAGAL: subjek approved -> %', s; end if;
  s := rc_private.email_pengajuan_subjek('clearing', array['Medan']);
  if s <> 'Done - Pengajuan Claim Cashback' then
    raise exception 'GAGAL: subjek done -> %', s; end if;

  -- Tepat tiga depo masih disebut; empat tidak lagi.
  s := rc_private.email_pengajuan_subjek('submit', array['A','B','C']);
  if s <> 'Approval - Pengajuan Claim Cashback A, B, C' then
    raise exception 'GAGAL: tiga depo seharusnya masih disebut -> %', s; end if;
  s := rc_private.email_pengajuan_subjek('submit', array['A','B','C','D']);
  if s <> 'Approval - Pengajuan Claim Cashback' then
    raise exception 'GAGAL: lebih dari tiga depo masih disebut -> %', s; end if;
  raise notice 'OK  1. Subjek sesuai ketetapan, termasuk batas tiga depo';

  -- Isi surat.
  select depot_id into v_dep from public.claims
   where archived_at is null and depot_id is not null order by no_doc limit 1;
  select array_agg(id) into v_ids from (
    select id from public.claims where archived_at is null and depot_id = v_dep
     order by no_doc limit 5) x;
  select id into v_act from public.profiles order by user_code limit 1;

  h := rc_private.email_pengajuan_html('submit','B-UJI', v_ids, v_act, '');
  if position('Dear All,' in h) = 0 then raise exception 'GAGAL: pembuka tidak ada.'; end if;
  if position('Berikut terlampir pengajuan claim cashback Depo' in h) = 0 then
    raise exception 'GAGAL: kalimat pembuka submitted tidak sesuai.'; end if;
  if position('Mohon tim Management untuk segera melakukan approval' in h) = 0 then
    raise exception 'GAGAL: permintaan aksi submitted tidak ada.'; end if;
  if position('cid:logo' in h) = 0 or position('cid:blobby' in h) = 0 then
    raise exception 'GAGAL: kedua logo tidak dirujuk inline.'; end if;
  if position('http' in substring(h from 1 for position('</div>' in h))) > 0 then
    raise exception 'GAGAL: kop masih memuat gambar jarak jauh.'; end if;
  raise notice 'OK  2. Wording submitted dan kedua logo inline';

  h := rc_private.email_pengajuan_html('approve','B-UJI', v_ids, v_act, '');
  if position('Mohon tim OSC untuk segera memproses dokumen yang sudah di-approve' in h) = 0 then
    raise exception 'GAGAL: permintaan aksi approved tidak ada.'; end if;
  raise notice 'OK  3. Wording approved';

  h := rc_private.email_pengajuan_html('clearing','B-UJI', v_ids, v_act, '');
  if position('Mohon tim Depo untuk mengecek kembali list toko' in h) = 0 then
    raise exception 'GAGAL: permintaan aksi done tidak ada.'; end if;
  if position('Campaign:' in h) = 0 then
    raise exception 'GAGAL: done tidak menyebut campaign.'; end if;
  raise notice 'OK  4. Wording done, lengkap dengan kode depo dan campaign';

  if position('SA &amp; SD Operations' in h) = 0 then
    raise exception 'GAGAL: tanda tangan hilang.'; end if;
  if h ~ 'Rp [0-9]+,[0-9]{3}' then
    raise exception 'GAGAL: nominal memakai koma.'; end if;
  raise notice 'OK  5. Tanda tangan dan format nominal tetap';
  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
