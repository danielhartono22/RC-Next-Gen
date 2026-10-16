-- ==========================================================================================
-- Email Pengajuan - bagian 3: tab Access Management dan RPC-nya
-- ==========================================================================================
-- Tab baru "Email Pengajuan" berisi tiga hal: sakelar aktif/nonaktif, daftar email tambahan
-- yang selalu ikut sebagai CC, dan tombol kirim uji.
--
-- Kewenangan mengikuti ketetapan pemilik untuk seluruh modul Access Management: hanya
-- Supervisor dan System Manager yang boleh mengubah, sisanya hanya melihat.
--
-- Email uji dikirim HANYA ke alamat yang diketik. Tidak ke depot, tidak ke CC siapa pun -
-- mencoba fitur tidak boleh berubah menjadi mengirim surat ke orang sungguhan.
--
-- Aman dijalankan berulang.
-- ==========================================================================================

-- ------------------------------------------------------------------------------------------
-- 1. Tab terdaftar di katalog izin
-- ------------------------------------------------------------------------------------------
insert into rc_private.tab_catalog(code,module,label,permission,key,tab,title)
values('access.emailPengajuan','access','Access Management','manage_access','n',
       'emailPengajuan','Email Pengajuan')
on conflict(code) do update set title = excluded.title;

-- ------------------------------------------------------------------------------------------
-- 2. Membaca pengaturan
-- ------------------------------------------------------------------------------------------
-- Ikut membawa ringkasan penerima untuk satu depot contoh, supaya orang yang menyalakan
-- sakelar dapat melihat lebih dulu KE SIAPA suratnya akan pergi. Menyalakan pengiriman tanpa
-- bisa melihat daftar penerimanya adalah cara paling mudah mengirim surat ke orang yang salah.
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

-- ------------------------------------------------------------------------------------------
-- 3. Menyimpan pengaturan
-- ------------------------------------------------------------------------------------------
create or replace function public.rc_email_pengajuan_simpan(p_aktif boolean, p_cc jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare v_cc text[]; v_buruk text;
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

  -- Alamat yang jelas salah bentuk ditolak di sini. Dibiarkan lewat, ia akan menjadi kegagalan
  -- pengiriman yang muncul jauh kemudian, ketika tidak ada lagi yang ingat siapa mengetiknya.
  select x into v_buruk from unnest(v_cc) x
   where x !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' limit 1;
  if v_buruk is not null then
    raise exception 'Alamat email tidak sah: %', v_buruk;
  end if;

  update public.email_settings
     set aktif = coalesce(p_aktif,false), cc_tambahan = v_cc,
         diubah_pada = now(), diubah_oleh = auth.uid()
   where jenis='pengajuan';

  insert into public.activity_logs(actor_id,event_type,details)
  values(auth.uid(),'email_pengajuan_settings',
    jsonb_build_object('aktif',coalesce(p_aktif,false),'ccTambahan',coalesce(array_length(v_cc,1),0)));

  return jsonb_build_object('status','success',
    'message','Pengaturan email pengajuan disimpan. Pengiriman '
      || case when coalesce(p_aktif,false) then 'AKTIF' else 'NONAKTIF' end || '.');
end
$fn$;

-- ------------------------------------------------------------------------------------------
-- 4. Kirim uji
-- ------------------------------------------------------------------------------------------
-- Memakai data nyata terbaru supaya yang dilihat penguji adalah surat yang sesungguhnya, bukan
-- contoh karangan yang tidak membuktikan apa pun. Tujuannya tetap hanya satu alamat.
create or replace function public.rc_email_pengajuan_uji(p_email text)
returns jsonb language plpgsql security definer set search_path to '' as $fn$
declare
  v_email text; v_dep uuid; v_ids uuid[]; v_html text; v_id uuid; v_hasil jsonb; v_batch text;
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

  select array_agg(id) into v_ids from (
    select id from public.claims
     where archived_at is null and depot_id = v_dep
     order by updated_at desc nulls last limit 10) x;

  v_html := rc_private.email_pengajuan_html('submit', v_batch, v_ids, auth.uid(), '');

  -- CC sengaja dikosongkan: email uji tidak boleh menyentuh siapa pun selain pengujinya.
  insert into public.email_outbox(jenis,tujuan,cc,subjek,isi_html,konteks)
  values('pengajuan', array[v_email], '{}',
    '[UJI] RC Pengajuan Baru - ' || coalesce(v_batch,''),
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

revoke all on function public.rc_email_pengajuan_baca() from public, anon;
revoke all on function public.rc_email_pengajuan_simpan(boolean,jsonb) from public, anon;
revoke all on function public.rc_email_pengajuan_uji(text) from public, anon;
grant execute on function public.rc_email_pengajuan_baca() to authenticated;
grant execute on function public.rc_email_pengajuan_simpan(boolean,jsonb) to authenticated;
grant execute on function public.rc_email_pengajuan_uji(text) to authenticated;

-- ------------------------------------------------------------------------------------------
-- Pemeriksaan: dijalankan sebagai pengguna sungguhan, bukan sebagai pemilik skema
-- ------------------------------------------------------------------------------------------
-- Pelajaran yang sudah mahal sekali dibayar pada modul Report: memeriksa bahwa fungsinya ADA
-- tidak membuktikan aplikasinya bisa memanggilnya. Yang diperiksa di sini adalah jalur yang
-- benar-benar ditempuh layar.
do $periksa$
declare v_sm uuid; v_osc uuid; h jsonb; v_boleh boolean;
begin
  select id into v_sm from public.profiles
   where lower(coalesce(role,'')) like '%system%' and coalesce(status,'')='active'
   order by user_code limit 1;
  if v_sm is null then raise exception 'GAGAL: tidak ada System Manager untuk menguji.'; end if;

  -- 1. System Manager dapat membaca lewat jalur PostgREST.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sm::text,'role','authenticated')::text, true);
  h := public.rc_email_pengajuan_baca();
  if coalesce(h->>'status','') <> 'success' then
    reset role; raise exception 'GAGAL: System Manager tidak dapat membaca pengaturan.'; end if;
  if (h->>'aktif')::boolean then
    reset role; raise exception 'GAGAL: sakelar menyala; seharusnya lahir nonaktif.'; end if;
  if not (h->>'bolehUbah')::boolean then
    reset role; raise exception 'GAGAL: System Manager tidak diizinkan mengubah.'; end if;
  reset role;
  raise notice 'OK  1. System Manager membaca pengaturan; sakelar nonaktif';
  raise notice '    Depot tanpa alamat email: %', h->>'depotTanpaEmail';
  raise notice '    Contoh depot %: TO % alamat, CC % alamat',
    h->>'depotContoh', jsonb_array_length(h->'contohTo'), jsonb_array_length(h->'contohCc');

  -- 2. OSC hanya boleh melihat, tidak mengubah.
  select id into v_osc from public.profiles
   where lower(coalesce(role,''))='osc' and coalesce(status,'')='active'
   order by user_code limit 1;
  if v_osc is not null then
    set local role authenticated;
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_osc::text,'role','authenticated')::text, true);
    begin
      h := public.rc_email_pengajuan_baca();
      v_boleh := coalesce((h->>'bolehUbah')::boolean,false);
      if v_boleh then
        reset role; raise exception 'GAGAL: OSC dilaporkan boleh mengubah pengaturan.'; end if;
      raise notice 'OK  2. OSC membaca pengaturan tetapi tidak boleh mengubah';
    exception when others then
      if sqlerrm like 'GAGAL:%' then reset role; raise; end if;
      raise notice 'OK  2. OSC tidak memiliki izin tab ini (%).', left(sqlerrm,60);
    end;

    -- Dan percobaan menyimpannya benar-benar ditolak, bukan hanya tombolnya yang disembunyikan.
    begin
      perform public.rc_email_pengajuan_simpan(true, '[]'::jsonb);
      reset role; raise exception 'GAGAL: OSC berhasil menyimpan pengaturan.';
    exception when others then
      if sqlerrm like 'GAGAL:%' then reset role; raise; end if;
      raise notice 'OK  3. Simpan oleh OSC ditolak server';
    end;
    reset role;
  end if;

  -- 4. Alamat yang salah bentuk ditolak.
  set local role authenticated;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_sm::text,'role','authenticated')::text, true);
  begin
    perform public.rc_email_pengajuan_simpan(false, '["bukan-email"]'::jsonb);
    reset role; raise exception 'GAGAL: alamat tidak sah diterima.';
  exception when others then
    if sqlerrm like 'GAGAL:%' then reset role; raise; end if;
    raise notice 'OK  4. Alamat email yang salah bentuk ditolak';
  end;
  reset role;

  -- Keadaan akhir harus tetap: MATI.
  if (select aktif from public.email_settings where jenis='pengajuan') then
    raise exception 'GAGAL: sakelar tertinggal menyala.'; end if;
  raise notice 'OK  5. Sakelar tetap MATI setelah seluruh pemeriksaan';
  raise notice 'Pemeriksaan lolos.';
exception when others then
  reset role; raise;
end
$periksa$;
