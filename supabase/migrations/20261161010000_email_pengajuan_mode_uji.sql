-- ==========================================================================================
-- Mode Uji: email dari action sungguhan dibelokkan ke satu alamat
-- ==========================================================================================
-- Tombol "Kirim Uji" yang sudah ada hanya mengirim CONTOH buatan. Ia membuktikan surat bisa
-- sampai, tetapi tidak membuktikan bahwa action yang sebenarnya memicu surat yang benar -
-- padahal justru itu yang perlu diyakini sebelum fitur ini dinyalakan.
--
-- Mode Uji menutup celah itu: Submitted, On Hold, Expired, Approval dan Clearing yang
-- sungguhan tetap memicu surat, tetapi seluruhnya dibelokkan ke satu alamat. Depot dan CC
-- tidak menerima apa pun.
--
-- Suratnya membawa keterangan SIAPA yang seharusnya menerima. Tanpa itu, mode uji hanya
-- membuktikan surat terkirim - bukan bahwa penerimanya benar, yang justru bagian paling mudah
-- salah dan paling mahal akibatnya.
--
-- Depot tanpa alamat TIDAK dilewati dalam mode uji. Di jalur biasa ia memang dilewati, tetapi
-- ketika sedang menguji, justru depot itulah yang perlu terlihat.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

alter table public.email_settings
  add column if not exists mode_uji boolean not null default false,
  add column if not exists email_uji text not null default '';

-- ------------------------------------------------------------------------------------------
-- Pengantre: satu cabang pembelokan, dipasang setelah penerima sebenarnya dihitung
-- ------------------------------------------------------------------------------------------
-- Penerima sebenarnya tetap DIHITUNG lebih dulu meski akan dibelokkan, supaya yang diuji benar
-- benar perhitungan yang sama dengan yang nanti dipakai sungguhan - bukan jalur lain yang
-- kebetulan mirip.
create or replace function rc_private.email_pengajuan_antre(
  p_action text, p_batch text, p_ids uuid[], p_aktor uuid, p_alasan text default '')
returns integer language plpgsql security definer set search_path to '' as $fn$
declare
  v_aktif boolean; v_dep record; v_ids uuid[]; v_pen jsonb; v_html text;
  v_judul text; v_n int := 0; v_uji boolean; v_alamat text;
  v_to text[]; v_cc text[]; v_subjek text; v_spanduk text;
begin
  if p_ids is null or array_length(p_ids,1) is null then return 0; end if;

  if p_action not in ('submit','hold','expire','expire_claim_process','approve','clearing') then
    return 0; end if;

  select aktif, mode_uji, btrim(coalesce(email_uji,''))
    into v_aktif, v_uji, v_alamat
    from public.email_settings where jenis='pengajuan';
  if not coalesce(v_aktif,false) then return 0; end if;

  -- Mode uji tanpa alamat tidak boleh diam-diam berubah menjadi pengiriman sungguhan.
  v_uji := coalesce(v_uji,false) and coalesce(v_alamat,'') <> '';

  v_judul := case p_action
    when 'submit'               then 'Pengajuan Baru'
    when 'hold'                 then 'Dokumen On Hold'
    when 'expire'               then 'Dokumen Expired'
    when 'expire_claim_process' then 'Dokumen Expired'
    when 'approve'              then 'Dokumen Disetujui'
    when 'clearing'             then 'Clearing Selesai' end;

  for v_dep in
    select c.depot_id, coalesce(d.depot_name, d.depot_code, '') as nama
      from public.claims c
      left join public.depots d on d.id = c.depot_id
     where c.id = any(p_ids) and c.depot_id is not null
     group by c.depot_id, 2
  loop
    select array_agg(id) into v_ids
      from public.claims where id = any(p_ids) and depot_id = v_dep.depot_id;

    v_pen := rc_private.email_pengajuan_penerima(v_dep.depot_id);
    v_to  := array(select jsonb_array_elements_text(v_pen->'to'));
    v_cc  := array(select jsonb_array_elements_text(v_pen->'cc'));

    -- Di jalur biasa, depot tanpa alamat dilewati dengan jejak. Saat menguji, justru keadaan
    -- itu yang paling perlu terlihat, jadi suratnya tetap dibuat.
    if coalesce(array_length(v_to,1),0) = 0 and not v_uji then
      insert into public.activity_logs(actor_id,depot_id,event_type,details)
      values(p_aktor, v_dep.depot_id, 'email_pengajuan_tanpa_tujuan',
        jsonb_build_object('aksi',p_action,'batch',p_batch,
                           'sebab','Alamat email depot belum diisi di Depot Master'));
      continue;
    end if;

    v_html := rc_private.email_pengajuan_html(p_action, p_batch, v_ids, p_aktor, p_alasan);
    v_subjek := rc_private.email_pengajuan_subjek(p_action,
                  array[coalesce(nullif(v_dep.nama,''),'Depot')]);

    if v_uji then
      v_spanduk :=
        '<div style="font-family:Arial,Helvetica,sans-serif;background:#1f2937;color:#ffffff;'
        || 'padding:12px 16px;border-radius:8px;margin-bottom:12px;max-width:640px;">'
        || '<div style="font-size:13px;font-weight:bold;margin-bottom:6px;">MODE UJI &mdash; '
        || 'surat ini TIDAK dikirim ke depot</div>'
        || '<div style="font-size:11px;line-height:1.7;color:#d1d5db;">'
        || 'Seharusnya dikirim ke<br>'
        || '<strong style="color:#ffffff;">TO</strong> ('
        || coalesce(array_length(v_to,1),0)::text || '): '
        || rc_private.html_aman(coalesce(nullif(array_to_string(v_to,', '),''),
             'BELUM ADA ALAMAT DEPOT DI DEPOT MASTER')) || '<br>'
        || '<strong style="color:#ffffff;">CC</strong> ('
        || coalesce(array_length(v_cc,1),0)::text || '): '
        || rc_private.html_aman(coalesce(nullif(array_to_string(v_cc,', '),''),'tidak ada'))
        || '</div></div>';
      v_html   := v_spanduk || v_html;
      v_subjek := '[UJI] ' || v_subjek;
      v_to     := array[v_alamat];
      v_cc     := '{}';
    end if;

    insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,konteks)
    values('pengajuan', v_to, v_cc, v_subjek, v_html,
      jsonb_build_object('aksi',p_action,'batch',p_batch,'depot',v_dep.depot_id,
                         'qty',coalesce(array_length(v_ids,1),0),
                         'modeUji',v_uji));
    v_n := v_n + 1;
  end loop;

  return v_n;
end
$fn$;

revoke all on function rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)
  from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Judul di kop surat memakai SUBJEK yang sama
-- ------------------------------------------------------------------------------------------
-- Sebelumnya kop punya kalimatnya sendiri ("Pengajuan Claim Cashback", "Approved - Claim
-- Cashback"), terpisah dari subjek. Dua kalimat yang menerangkan hal yang sama pasti akan
-- berbeda cepat atau lambat - dan memang sudah berbeda. Sejak sekarang keduanya satu sumber:
-- rc_private.email_pengajuan_subjek.
create or replace function rc_private.email_pengajuan_html(
  p_action text, p_batch text, p_ids uuid[], p_aktor uuid, p_alasan text default '')
returns text language plpgsql stable security definer set search_path to '' as $fn$
declare
  v_depot text; v_kode text; v_baris text := ''; v_r record;
  v_toko int := 0; v_cb numeric := 0; v_doc int := 0; v_nama text;
  v_pembuka text; v_aksi text; v_campaign text; v_html text; v_judul text;
begin
  select coalesce(d.depot_name, d.depot_code, ''), coalesce(d.depot_code,'')
    into v_depot, v_kode
    from public.claims c join public.depots d on d.id = c.depot_id
   where c.id = any(p_ids) limit 1;

  v_judul := rc_private.email_pengajuan_subjek(p_action,
               array[coalesce(nullif(v_depot,''),'Depot')]);

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

revoke all on function rc_private.email_pengajuan_html(text,text,uuid[],uuid,text)
  from public, anon, authenticated;

-- ------------------------------------------------------------------------------------------
-- Tombol Kirim Uji memakai subjek yang sama
-- ------------------------------------------------------------------------------------------
-- Sebelumnya tombol ini menyusun subjeknya sendiri ("[UJI] RC Pengajuan Baru - ..."), sisa dari
-- sebelum subjek resmi ditetapkan. Akibatnya yang dilihat penguji bukan subjek yang sebenarnya
-- akan terkirim - persis hal yang seharusnya dibuktikan oleh sebuah uji.
create or replace function public.rc_email_pengajuan_uji(p_email text)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_email text; v_dep uuid; v_ids uuid[]; v_html text; v_id uuid; v_hasil jsonb;
  v_batch text; v_nama text;
begin
  perform rc_private.require_tab('access.emailPengajuan');
  if not (rc_private.is_system_manager()
          or lower(coalesce((select role from public.profiles where id=auth.uid()),'')) = 'supervisor') then
    raise exception 'Hanya Supervisor dan System Manager yang dapat mengirim email uji'
      using errcode='42501';
  end if;

  v_email := lower(btrim(coalesce(p_email,'')));
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'Alamat email uji tidak sah: %', coalesce(nullif(v_email,''),'(kosong)');
  end if;

  select c.depot_id, coalesce(c.batch_upload,'CONTOH-01') into v_dep, v_batch
    from public.claims c
   where c.archived_at is null and c.depot_id is not null
   order by c.updated_at desc nulls last limit 1;
  if v_dep is null then raise exception 'Belum ada dokumen yang bisa dijadikan contoh'; end if;

  select coalesce(depot_name, depot_code, 'Depot') into v_nama from public.depots where id = v_dep;

  select array_agg(id) into v_ids from (
    select id from public.claims
     where archived_at is null and depot_id = v_dep
     order by updated_at desc nulls last limit 10) x;

  v_html := rc_private.email_pengajuan_html('submit', v_batch, v_ids, auth.uid(), '');

  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,konteks)
  values('pengajuan', array[v_email], '{}',
    '[UJI] ' || rc_private.email_pengajuan_subjek('submit', array[v_nama]),
    v_html, jsonb_build_object('uji',true,'batch',v_batch))
  returning id into v_id;

  begin
    v_hasil := rc_private.kirim_satu_email(v_id);
    if coalesce(v_hasil->>'status','') = 'success' then
      return jsonb_build_object('status','success',
        'message','Email uji terkirim ke ' || v_email || '.');
    end if;
    update public.email_outbox
       set galat = left(coalesce(v_hasil->>'sebab','Setelan email belum lengkap.'),500)
     where id = v_id;
    return jsonb_build_object('status','warning',
      'message','Belum terkirim: ' || coalesce(v_hasil->>'sebab','Setelan email belum lengkap.')
        || ' Barisnya tetap di antrean.');
  exception when others then
    update public.email_outbox
       set percobaan = coalesce(percobaan,0)+1, galat = left(sqlerrm,500) where id = v_id;
    return jsonb_build_object('status','warning',
      'message','Gagal mengirim: ' || left(sqlerrm,300));
  end;
end
$fn$;

revoke all on function public.rc_email_pengajuan_uji(text) from public, anon;
grant execute on function public.rc_email_pengajuan_uji(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- RPC baca dan simpan ikut membawa mode uji
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_pengajuan_baca()
returns jsonb language plpgsql stable security definer set search_path to '' as $fn$
declare v_s public.email_settings%rowtype; v_dep uuid; v_pen jsonb; v_n int;
begin
  perform rc_private.require_tab('access.emailPengajuan');

  select * into v_s from public.email_settings where jenis='pengajuan';

  select id into v_dep from public.depots
   where archived_at is null and coalesce(email_to,'') <> ''
   order by depot_code limit 1;
  if v_dep is not null then v_pen := rc_private.email_pengajuan_penerima(v_dep); end if;

  select count(*) into v_n from public.email_outbox where jenis='pengajuan';

  return jsonb_build_object(
    'status','success',
    'aktif', coalesce(v_s.aktif,false),
    'modeUji', coalesce(v_s.mode_uji,false),
    'emailUji', coalesce(v_s.email_uji,''),
    'ccTambahan', to_jsonb(coalesce(v_s.cc_tambahan,'{}')),
    'catatan', coalesce(v_s.catatan,''),
    'diubahPada', case when v_s.diubah_pada is null then ''
                       else to_char(v_s.diubah_pada at time zone 'Asia/Jakarta','DD-Mon-YYYY HH24:MI') end,
    'diubahOleh', coalesce((select full_name from public.profiles where id=v_s.diubah_oleh),''),
    'bolehUbah', rc_private.is_system_manager()
                 or lower(coalesce((select role from public.profiles where id=auth.uid()),'')) = 'supervisor',
    'depotTanpaEmail', (select count(*) from public.depots
                         where archived_at is null and coalesce(email_to,'')=''),
    'depotContoh', coalesce(v_pen->>'depot',''),
    'contohTo', coalesce(v_pen->'to','[]'::jsonb),
    'contohCc', coalesce(v_pen->'cc','[]'::jsonb),
    'sudahDiantre', v_n);
end
$fn$;

create or replace function public.rc_email_pengajuan_simpan(
  p_aktif boolean, p_cc jsonb, p_mode_uji boolean default false, p_email_uji text default '')
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_cc text[]; v_buruk text; v_uji text;
begin
  perform rc_private.require_tab('access.emailPengajuan');
  if not (rc_private.is_system_manager()
          or lower(coalesce((select role from public.profiles where id=auth.uid()),'')) = 'supervisor') then
    raise exception 'Hanya Supervisor dan System Manager yang dapat mengubah pengaturan ini'
      using errcode='42501';
  end if;

  if p_cc is null or jsonb_typeof(p_cc) <> 'array' then
    raise exception 'Daftar email tambahan harus berupa array';
  end if;
  if jsonb_array_length(p_cc) > 50 then
    raise exception 'Email tambahan maksimal 50 alamat';
  end if;

  select coalesce(array_agg(distinct lower(btrim(x))) filter (where btrim(x) <> ''), '{}')
    into v_cc from jsonb_array_elements_text(p_cc) x;

  select x into v_buruk from unnest(v_cc) x
   where x !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' limit 1;
  if v_buruk is not null then
    raise exception 'Alamat email tidak sah: %', v_buruk;
  end if;

  v_uji := lower(btrim(coalesce(p_email_uji,'')));
  if v_uji <> '' and v_uji !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'Alamat email uji tidak sah: %', v_uji;
  end if;
  -- Mode uji tanpa alamat akan diam-diam berubah menjadi pengiriman sungguhan. Ditolak di sini,
  -- bukan dibiarkan menjadi kejutan.
  if coalesce(p_mode_uji,false) and v_uji = '' then
    raise exception 'Mode Uji memerlukan alamat email uji';
  end if;

  update public.email_settings
     set aktif = coalesce(p_aktif,false), cc_tambahan = v_cc,
         mode_uji = coalesce(p_mode_uji,false), email_uji = v_uji,
         diubah_pada = now(), diubah_oleh = auth.uid()
   where jenis='pengajuan';

  insert into public.activity_logs(actor_id,event_type,details)
  values(auth.uid(),'email_pengajuan_settings',
    jsonb_build_object('aktif',coalesce(p_aktif,false),
                       'modeUji',coalesce(p_mode_uji,false),
                       'ccTambahan',coalesce(array_length(v_cc,1),0)));

  return jsonb_build_object('status','success',
    'message','Pengaturan disimpan. Pengiriman '
      || case when coalesce(p_aktif,false) then 'AKTIF' else 'NONAKTIF' end
      || case when coalesce(p_mode_uji,false) and v_uji <> ''
              then ', MODE UJI ke ' || v_uji || ' (depot tidak menerima apa pun)'
              else '' end || '.');
end
$fn$;

revoke all on function public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text) from public, anon;
grant execute on function public.rc_email_pengajuan_simpan(boolean,jsonb,boolean,text) to authenticated;

-- Tanda tangan lama dibuang supaya tidak ada dua versi yang bisa terpanggil berbeda-beda.
drop function if exists public.rc_email_pengajuan_simpan(boolean,jsonb);

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan
-- ------------------------------------------------------------------------------------------
do $periksa$
declare
  v_sm uuid; v_ids uuid[]; v_dep uuid; n int; n_awal int;
  v_surat public.email_outbox%rowtype; v_alamat text := 'penguji.rc@contoh.com';
begin
  select count(*) into n_awal from public.email_outbox;
  select id into v_sm from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  select depot_id into v_dep from public.claims
   where archived_at is null and depot_id is not null order by no_doc limit 1;

  -- Sama seperti pada 20261155: tanpa klaim, tidak ada surat yang bisa diuji, sementara
  -- fungsinya sudah terpasang di atas. Dilewati dengan jejak supaya pemasangannya tidak ikut
  -- tergulung balik.
  if v_dep is null then
    raise notice 'Belum ada klaim; pengujian mode uji dilewati.'; return; end if;

  select array_agg(id) into v_ids from (
    select id from public.claims where archived_at is null and depot_id = v_dep
     order by no_doc limit 4) x;

  begin
    update public.email_settings
       set aktif=true, mode_uji=true, email_uji=v_alamat where jenis='pengajuan';

    n := rc_private.email_pengajuan_antre('submit','B-UJI-01',v_ids,v_sm,'');
    if n <> 1 then raise exception 'GAGAL: seharusnya 1 surat, dapat %.', n; end if;

    -- Dipilih lewat nomor batch, bukan waktu: now() tetap sama sepanjang satu transaksi,
    -- sehingga mengurutkan berdasarkan dibuat_pada akan mengambil baris sembarang.
    select * into v_surat from public.email_outbox
     where konteks->>'batch' = 'B-UJI-01' limit 1;

    if v_surat.tujuan <> array[v_alamat] then
      raise exception 'GAGAL: tujuan tidak dibelokkan -> %', v_surat.tujuan; end if;
    if coalesce(array_length(v_surat.cc,1),0) <> 0 then
      raise exception 'GAGAL: CC tidak dikosongkan dalam mode uji.'; end if;
    if v_surat.subjek !~ '^\[UJI\] ' then
      raise exception 'GAGAL: subjek tidak ditandai UJI -> %', v_surat.subjek; end if;
    if position('MODE UJI' in v_surat.isi_html) = 0 then
      raise exception 'GAGAL: spanduk mode uji tidak ada.'; end if;
    if position('Seharusnya dikirim ke' in v_surat.isi_html) = 0 then
      raise exception 'GAGAL: surat tidak menyebut penerima sebenarnya.'; end if;
    if not coalesce((v_surat.konteks->>'modeUji')::boolean,false) then
      raise exception 'GAGAL: konteks tidak menandai mode uji.'; end if;
    raise notice 'OK  1. Action sungguhan -> surat dibelokkan ke % , CC kosong', v_alamat;

    -- Mode uji tanpa alamat TIDAK boleh berubah menjadi pengiriman sungguhan.
    update public.email_settings set email_uji='' where jenis='pengajuan';
    n := rc_private.email_pengajuan_antre('submit','B-UJI-02',v_ids,v_sm,'');
    select * into v_surat from public.email_outbox
     where konteks->>'batch' = 'B-UJI-02' limit 1;
    if v_surat.subjek ~ '^\[UJI\] ' then
      raise exception 'GAGAL: masih ditandai UJI padahal alamatnya kosong.'; end if;
    raise notice 'OK  2. Mode uji tanpa alamat kembali ke penerima sebenarnya, bukan menghilang';

    raise exception 'ULANGI_SAJA';
  exception when others then
    if sqlerrm <> 'ULANGI_SAJA' then raise; end if;
  end;

  select count(*) into n from public.email_outbox;
  if n <> n_awal then
    raise exception 'GAGAL: antrean uji tidak tergulung balik (% -> %).', n_awal, n; end if;
  if (select aktif or mode_uji from public.email_settings where jenis='pengajuan') then
    raise exception 'GAGAL: sakelar atau mode uji tertinggal menyala.'; end if;
  raise notice 'OK  3. Tidak ada jejak; sakelar dan mode uji tetap MATI';

  -- Subjek harus SATU di seluruh jalur: antrean action, tombol uji, dan judul kop surat.
  -- Ketiganya pernah berbeda, dan itulah yang terlihat pemilik.
  declare
    v_html text; v_subjek text; v_act uuid;
  begin
    select id into v_act from public.profiles order by user_code limit 1;
    select depot_id into v_dep from public.claims
     where archived_at is null and depot_id is not null order by no_doc limit 1;
    select array_agg(id) into v_ids from (
      select id from public.claims where archived_at is null and depot_id = v_dep
       order by no_doc limit 3) x;
    select coalesce(depot_name, depot_code, 'Depot') into v_alamat
      from public.depots where id = v_dep;

    v_subjek := rc_private.email_pengajuan_subjek('submit', array[v_alamat]);
    if v_subjek <> 'Approval - Pengajuan Claim Cashback ' || v_alamat then
      raise exception 'GAGAL: subjek submitted menyimpang -> %', v_subjek; end if;

    v_html := rc_private.email_pengajuan_html('submit','B-UJI', v_ids, v_act, '');
    if position(rc_private.html_aman(v_subjek) in v_html) = 0 then
      raise exception 'GAGAL: judul kop surat tidak sama dengan subjek (%).', v_subjek; end if;

    -- Kalimat lama yang berdiri sendiri tidak boleh tersisa di mana pun.
    if position('RC Pengajuan Baru' in v_html) > 0 then
      raise exception 'GAGAL: judul lama "RC Pengajuan Baru" masih terpakai.'; end if;
    if position('RC Pengajuan Baru' in
        (select pg_get_functiondef(p.oid) from pg_proc p
           join pg_namespace ns on ns.oid=p.pronamespace
          where ns.nspname='public' and p.proname='rc_email_pengajuan_uji')) > 0 then
      raise exception 'GAGAL: tombol Kirim Uji masih memakai subjek lama.'; end if;

    raise notice 'OK  4. Subjek sama di antrean action, tombol uji, dan kop surat: "%"', v_subjek;
  end;

  raise notice 'Pemeriksaan lolos.';
end
$periksa$;
