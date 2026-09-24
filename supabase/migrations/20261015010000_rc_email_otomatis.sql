-- ==========================================================================================
-- Email otomatis: Daily, Weekly, dan Timetable
-- ==========================================================================================
-- Memindahkan FR-12, FR-13, FR-14 dan FR-15 dari RC_Reporting_AppsScript. Apps Script bisa
-- mengirim email sendiri lewat MailApp; PostgreSQL tidak. Karena itu bentuknya berbeda, dan
-- perbedaan itu disengaja:
--
--   1. Isi email disusun di dalam database oleh fungsi di bawah, dari data yang sama persis
--      dengan yang dibaca modul Report dan Timetable. Tidak ada perhitungan kedua yang bisa
--      menyimpang dari yang dilihat di layar.
--   2. Hasilnya dimasukkan ke public.email_outbox sebagai baris berstatus pending.
--   3. Pengirimnya membaca outbox itu dan menyerahkannya ke penyedia email lewat pg_net.
--
-- MENGAPA ADA OUTBOX, BUKAN LANGSUNG KIRIM
-- Karena kegagalan pengiriman harus terlihat. Bila penyedia email sedang bermasalah, kuncinya
-- kedaluwarsa, atau alamatnya salah, barisnya tetap ada dengan status dan pesan galatnya -
-- bukan menghilang tanpa jejak seperti yang terjadi ketika email dikirim langsung di dalam
-- satu transaksi. Outbox juga membuat "preview" dan "test" menjadi hal yang sama dengan
-- pengiriman sungguhan, hanya berbeda pada apakah barisnya dikirim atau tidak.
--
-- BELUM ADA KUNCI PENYEDIA EMAIL
-- Selama kunci belum diisi, seluruh email tetap tersusun dan menumpuk di outbox dengan status
-- pending, dan TIDAK ADA yang terkirim. Itu keadaan yang jujur dan aman: isinya bisa diperiksa
-- lebih dulu, dan begitu kuncinya diisi, antreannya berjalan. Pengiriman diaktifkan terpisah
-- pada 20261016010000 supaya keputusan itu tidak tercampur dengan pemasangan ini.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Pengaturan dan antrean
-- ------------------------------------------------------------------------------------------
create table if not exists public.email_settings(
  jenis text primary key check(jenis in('daily','weekly','timetable')),
  aktif boolean not null default false,
  jam integer not null default 7 check(jam between 0 and 23),
  hari integer check(hari between 0 and 6),          -- 0 Minggu, hanya untuk weekly dan timetable
  subjek text not null default '',
  catatan text not null default '',
  diubah_pada timestamptz not null default now(),
  diubah_oleh uuid references public.profiles(id)
);
alter table public.email_settings enable row level security;
revoke all on public.email_settings from public,anon,authenticated;
grant select on public.email_settings to authenticated;
drop policy if exists email_settings_baca on public.email_settings;
create policy email_settings_baca on public.email_settings for select to authenticated using (true);

-- Default mengikuti sistem lama: seluruhnya NONAKTIF sampai dinyalakan dengan sadar.
insert into public.email_settings(jenis,aktif,jam,hari,subjek) values
 ('daily',    false, 7, null, 'RC Outstanding Harian'),
 ('weekly',   false, 8, 5,    'RC Ringkasan Mingguan'),
 ('timetable',false, 8, 1,    'RC Progres Timetable')
on conflict(jenis) do nothing;

create table if not exists public.email_outbox(
  id uuid primary key default gen_random_uuid(),
  jenis text not null,
  tujuan text[] not null,
  cc text[] not null default '{}',
  subjek text not null,
  isi_html text not null,
  status text not null default 'pending' check(status in('pending','sent','failed','skipped')),
  percobaan integer not null default 0,
  galat text not null default '',
  konteks jsonb not null default '{}',
  dibuat_pada timestamptz not null default now(),
  dikirim_pada timestamptz
);
create index if not exists email_outbox_pending_idx on public.email_outbox(status, dibuat_pada);
alter table public.email_outbox enable row level security;
revoke all on public.email_outbox from public,anon,authenticated;
grant select on public.email_outbox to authenticated;
drop policy if exists email_outbox_baca on public.email_outbox;
create policy email_outbox_baca on public.email_outbox for select to authenticated using (true);

-- ------------------------------------------------------------------------------------------
-- 2. Penerima
-- ------------------------------------------------------------------------------------------
-- Penerima depot diambil dari master depot, bukan dari sheet terpisah. Alamat yang sudah ada
-- di TO tidak diulang di CC - aturan kecil yang mudah terlewat dan menghasilkan email ganda.
create or replace function rc_private.penerima_depot(p_kode_depot text[])
returns jsonb language sql stable security definer set search_path='' as $fn$
  with a as (
    select coalesce(array_agg(distinct t) filter (where t is not null),'{}'::text[]) as tos,
           coalesce(array_agg(distinct c) filter (where c is not null),'{}'::text[]) as ccs
      from public.depots d
      left join lateral unnest(rc_private.pecah_email(d.email_to)) t on true
      left join lateral unnest(rc_private.pecah_email(d.email_cc)) c on true
     where d.depot_code = any(p_kode_depot)
  )
  select jsonb_build_object(
    'to', to_jsonb(a.tos),
    'cc', to_jsonb(coalesce(array(select x from unnest(a.ccs) x where x <> all(a.tos)),'{}'::text[]))
  ) from a;
$fn$;
revoke all on function rc_private.penerima_depot(text[]) from public,anon;
grant execute on function rc_private.penerima_depot(text[]) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 3. Menyusun isi
-- ------------------------------------------------------------------------------------------
create or replace function rc_private.rupiah(n numeric)
returns text language sql immutable set search_path='' as $fn$
  select 'Rp ' || to_char(coalesce(n,0), 'FM999G999G999G999G990');
$fn$;
revoke all on function rc_private.rupiah(numeric) from public,anon;

-- Daily: outstanding dan Top 5 depot yang paling perlu ditindaklanjuti. Urutannya persis
-- aturan PRD - clearing rate terendah lebih dulu, lalu outstanding nominal terbesar - dan
-- hanya depot dengan Net CB dan outstanding di atas nol yang ikut.
create or replace function public.rc_email_susun(p_jenis text, p_kirim boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare
  v_jenis text; v_set public.email_settings; v_html text; v_subjek text;
  v_depot text[]; v_penerima jsonb; v_id uuid; v_baris integer := 0; v_ringkas jsonb;
begin
  if not rc_private.is_manager() then
    raise exception 'Hanya Supervisor atau System Manager yang dapat menyusun email'
      using errcode='42501'; end if;
  v_jenis := lower(btrim(coalesce(p_jenis,'')));
  select * into v_set from public.email_settings where jenis = v_jenis;
  if not found then raise exception 'Jenis email "%" tidak dikenali', p_jenis; end if;

  if v_jenis = 'daily' then
    with r as (
      select d.depot_code, d.depot_name,
             coalesce(sum(c.cb_net),0) net_cb,
             coalesce(sum(c.cb_net) filter (where c.status in('not_yet','submitted','released','claimed')),0) os_val,
             count(*) filter (where c.status in('not_yet','submitted','released','claimed')) os_qty,
             case when coalesce(sum(c.cb_net),0)=0 then 0
                  else coalesce(sum(c.cb_net) filter (where c.status in('done','expired')),0)/sum(c.cb_net) end cr
        from public.claims c join public.depots d on d.id=c.depot_id
       where c.archived_at is null
         and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=c.campaign_id)
       group by d.depot_code, d.depot_name
      having coalesce(sum(c.cb_net),0) > 0
         and coalesce(sum(c.cb_net) filter (where c.status in('not_yet','submitted','released','claimed')),0) > 0
    ), top5 as (select * from r order by cr, os_val desc limit 5)
    select array_agg(depot_code),
           coalesce(string_agg('<tr><td style="padding:6px 10px;border-bottom:1px solid #eee">'
             ||depot_code||' - '||depot_name||'</td><td style="padding:6px 10px;border-bottom:1px solid #eee;text-align:right">'
             ||os_qty||'</td><td style="padding:6px 10px;border-bottom:1px solid #eee;text-align:right">'
             ||rc_private.rupiah(os_val)||'</td><td style="padding:6px 10px;border-bottom:1px solid #eee;text-align:right">'
             ||to_char(cr*100,'FM990.0')||'%</td></tr>', '' order by cr, os_val desc),''),
           count(*)
      into v_depot, v_html, v_baris from top5;

    if v_baris = 0 then
      -- Tidak ada yang perlu ditindaklanjuti bukan kegagalan. Sistem lama mencatatnya FAILED;
      -- di sini statusnya skipped, supaya laporan kesehatan email tidak penuh alarm palsu.
      insert into public.email_outbox(jenis,tujuan,subjek,isi_html,status,konteks)
      values(v_jenis,'{}','(tidak dikirim)','',
        'skipped',jsonb_build_object('sebab','Tidak ada depot dengan outstanding'))
      returning id into v_id;
      return jsonb_build_object('status','success','dikirim',false,'id',v_id,
        'message','Tidak ada depot dengan outstanding; email tidak disusun.');
    end if;

    v_subjek := v_set.subjek || ' - ' || to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY');
    v_html := '<div style="font-family:Segoe UI,Arial,sans-serif;color:#1f2937">'
      ||'<h2 style="margin:0 0 4px">'||v_set.subjek||'</h2>'
      ||'<p style="color:#6b7280;margin:0 0 16px">Per '||to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI')||' WIB</p>'
      ||'<table style="border-collapse:collapse;width:100%;font-size:14px">'
      ||'<thead><tr style="background:#f3f4f6"><th style="padding:8px 10px;text-align:left">Depot</th>'
      ||'<th style="padding:8px 10px;text-align:right">Outstanding Qty</th>'
      ||'<th style="padding:8px 10px;text-align:right">Outstanding Nilai</th>'
      ||'<th style="padding:8px 10px;text-align:right">Clearing Rate</th></tr></thead><tbody>'
      ||v_html||'</tbody></table>'
      ||'<p style="color:#6b7280;font-size:12px;margin-top:16px">Diurutkan dari clearing rate terendah. '
      ||'Expired dihitung sebagai cleared secara nominal, sesuai definisi KPI yang berlaku.</p></div>';
    v_penerima := rc_private.penerima_depot(v_depot);

  elsif v_jenis in('weekly','timetable') then
    -- Weekly dan Timetable berlaku lintas depot, jadi penerimanya seluruh alamat pada master
    -- depot, bukan hanya depot tertentu.
    select array_agg(depot_code) into v_depot from public.depots
     where coalesce(btrim(email_to),'') <> '' or coalesce(btrim(email_cc),'') <> '';
    v_penerima := rc_private.penerima_depot(coalesce(v_depot,'{}'));

    if v_jenis = 'weekly' then
      select jsonb_build_object(
        'netCb',coalesce(sum(cb_net),0),
        'netClaimed',coalesce(sum(cb_net) filter (where status='done'),0),
        'osVal',coalesce(sum(cb_net) filter (where outstanding),0),
        'osQty',count(*) filter (where outstanding),
        'cr',case when coalesce(sum(cb_net),0)=0 then 0
             else coalesce(sum(cb_net) filter (where status in('done','expired')),0)/sum(cb_net) end)
        into v_ringkas from public.rc_report_rows;
      v_subjek := v_set.subjek || ' - ' || to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY');
      v_html := '<div style="font-family:Segoe UI,Arial,sans-serif;color:#1f2937">'
        ||'<h2 style="margin:0 0 12px">'||v_set.subjek||'</h2>'
        ||'<table style="border-collapse:collapse;font-size:14px">'
        ||'<tr><td style="padding:6px 14px 6px 0">Net CB</td><td style="padding:6px 0;font-weight:700">'||rc_private.rupiah((v_ringkas->>'netCb')::numeric)||'</td></tr>'
        ||'<tr><td style="padding:6px 14px 6px 0">Net Claimed</td><td style="padding:6px 0;font-weight:700">'||rc_private.rupiah((v_ringkas->>'netClaimed')::numeric)||'</td></tr>'
        ||'<tr><td style="padding:6px 14px 6px 0">Outstanding</td><td style="padding:6px 0;font-weight:700">'||(v_ringkas->>'osQty')||' dokumen / '||rc_private.rupiah((v_ringkas->>'osVal')::numeric)||'</td></tr>'
        ||'<tr><td style="padding:6px 14px 6px 0">Clearing Rate</td><td style="padding:6px 0;font-weight:700">'||to_char((v_ringkas->>'cr')::numeric*100,'FM990.0')||'%</td></tr>'
        ||'</table></div>';
    else
      select jsonb_build_object(
        'campaignAktif',(select count(*) from public.campaigns
           where period_start is not null and period_start<=current_date
             and coalesce(period_end,current_date)>=current_date
             and not exists(select 1 from public.excluded_campaigns x where x.campaign_id=campaigns.id)),
        'depot',(select count(*) from public.depots),
        'ditandai',(select count(*) from public.timetable_not_achieved))
        into v_ringkas;
      v_subjek := v_set.subjek || ' - ' || to_char(now() at time zone 'Asia/Jakarta','DD/MM/YYYY');
      v_html := '<div style="font-family:Segoe UI,Arial,sans-serif;color:#1f2937">'
        ||'<h2 style="margin:0 0 12px">'||v_set.subjek||'</h2>'
        ||'<p style="font-size:14px">Campaign aktif: <b>'||(v_ringkas->>'campaignAktif')||'</b><br>'
        ||'Depot dipantau: <b>'||(v_ringkas->>'depot')||'</b><br>'
        ||'Pasangan ditandai Not Achieved: <b>'||(v_ringkas->>'ditandai')||'</b></p>'
        ||'<p style="color:#6b7280;font-size:12px">Buka modul Timetable di RC untuk matrix lengkapnya.</p></div>';
    end if;
  else
    raise exception 'Jenis email "%" tidak dikenali', p_jenis;
  end if;

  if coalesce(jsonb_array_length(v_penerima->'to'),0) = 0 then
    insert into public.email_outbox(jenis,tujuan,subjek,isi_html,status,galat,konteks)
    values(v_jenis,'{}',v_subjek,v_html,'skipped',
      'Belum ada alamat TO pada master depot',jsonb_build_object('depot',to_jsonb(v_depot)))
    returning id into v_id;
    return jsonb_build_object('status','success','dikirim',false,'id',v_id,
      'message','Isi email tersusun, tetapi belum ada satu pun alamat TO di Key Master > Depot Master.');
  end if;

  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,status,konteks)
  values(v_jenis,
    array(select jsonb_array_elements_text(v_penerima->'to')),
    array(select jsonb_array_elements_text(v_penerima->'cc')),
    v_subjek, v_html,
    case when coalesce(p_kirim,false) then 'pending' else 'skipped' end,
    jsonb_build_object('depot',to_jsonb(v_depot),'preview',not coalesce(p_kirim,false)))
  returning id into v_id;

  return jsonb_build_object('status','success','id',v_id,
    'dikirim',coalesce(p_kirim,false),
    'penerima',v_penerima,
    'subjek',v_subjek,
    'isiHtml',v_html,
    'message',case when coalesce(p_kirim,false)
      then 'Email dimasukkan ke antrean pengiriman.'
      else 'Pratinjau tersusun. Tidak ada yang dikirim.' end);
end $fn$;
revoke all on function public.rc_email_susun(text,boolean) from public,anon;
grant execute on function public.rc_email_susun(text,boolean) to authenticated;

-- ------------------------------------------------------------------------------------------
-- 4. Pengaturan dan pemantauan dari layar
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_settings_simpan(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $fn$
declare r jsonb; n integer := 0;
begin
  if not rc_private.is_system_manager() then
    raise exception 'Hanya System Manager yang dapat mengubah jadwal email' using errcode='42501'; end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    update public.email_settings set
      aktif  = coalesce((r->>'aktif')::boolean, aktif),
      jam    = coalesce((r->>'jam')::integer, jam),
      hari   = case when r ? 'hari' then (r->>'hari')::integer else hari end,
      subjek = coalesce(nullif(btrim(coalesce(r->>'subjek','')),''), subjek),
      diubah_pada = now(), diubah_oleh = (select auth.uid())
    where jenis = lower(btrim(r->>'jenis'));
    if found then n := n + 1; end if;
  end loop;
  return jsonb_build_object('status','success','jumlah',n,'message',n||' jadwal email disimpan');
end $fn$;
revoke all on function public.rc_email_settings_simpan(jsonb) from public,anon;
grant execute on function public.rc_email_settings_simpan(jsonb) to authenticated;

create or replace function public.rc_email_status()
returns jsonb language sql stable security definer set search_path='' as $fn$
  select jsonb_build_object('status','success',
    'pengaturan',(select coalesce(jsonb_agg(jsonb_build_object(
        'jenis',jenis,'aktif',aktif,'jam',jam,'hari',hari,'subjek',subjek) order by jenis),'[]'::jsonb)
      from public.email_settings),
    'antrean',(select coalesce(jsonb_agg(jsonb_build_object(
        'id',id,'jenis',jenis,'subjek',subjek,'status',status,
        'tujuan',array_length(tujuan,1),'cc',array_length(cc,1),'galat',galat,
        'dibuat',to_char(dibuat_pada at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'),
        'dikirim',to_char(dikirim_pada at time zone 'Asia/Jakarta','DD/MM/YYYY HH24:MI'))
        order by dibuat_pada desc),'[]'::jsonb)
      from (select * from public.email_outbox order by dibuat_pada desc limit 50) x),
    'ringkas',(select jsonb_object_agg(status,n) from
      (select status,count(*) n from public.email_outbox group by status) y),
    'depotBerEmail',(select count(*) from public.depots where coalesce(btrim(email_to),'')<>''),
    'depotTotal',(select count(*) from public.depots));
$fn$;
revoke all on function public.rc_email_status() from public,anon;
grant execute on function public.rc_email_status() to authenticated;

create or replace function rc_private.marker_20261015() returns boolean
language sql immutable set search_path='' as $fn$select true$fn$;
revoke all on function rc_private.marker_20261015() from public,anon;
grant execute on function rc_private.marker_20261015() to authenticated;

select 'Email otomatis terpasang, pengiriman belum diaktifkan' as hasil,
 (select count(*) from public.email_settings) as jenis_email,
 (select count(*) from public.email_settings where aktif) as aktif,
 (select count(*) from public.depots where coalesce(btrim(email_to),'')<>'') as depot_ber_email,
 'Isi Key Master > Depot Master kolom Email TO dan CC lebih dulu' as langkah_berikutnya;
