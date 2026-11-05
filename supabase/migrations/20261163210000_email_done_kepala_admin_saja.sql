-- ==========================================================================================
-- Email Done: TO Email Kepala Admin, bila kosong user yang proses; CC hanya Access Management
-- ==========================================================================================
-- Pemilik, 20 Oktober 2026: "supaya ga spam email done hanya kepala admin aja ... dan cc hanya
-- yang ada di access management?", lalu "intinya kalo belum ada kepala admin, gunakan user yang
-- proses tanpa perlu syarat admin" (pilihan: "Pengaju, lalu user Done").
--  * TO email Done, berurutan:
--      1. Email Kepala Admin depot (Key Master > Depot Master), bila terisi;
--      2. bila kosong: user yang MENGAJUKAN klaim di surat itu (claims.submitted_by), apa pun
--         perannya;
--      3. bila tidak ada pengaju tercatat (klaim impor - per 20 Oktober 2026 hanya 26 dari 3.496
--         klaim Done 30 hari terakhir yang mencatatnya): user yang MEMPROSES Done (pelaku proses
--         ini dan claims.cleared_by);
--      4. bila tetap tanpa alamat (akun nonaktif / tanpa email): email Done ditahan, dicatat di
--         Log Activity sebagai email_pengajuan_tanpa_tujuan.
--    Tidak lagi jatuh ke Email TO depot (20261163100000). Hanya akun aktif ber-email.
--  * CC "Email Done saja": CC email Done hanya CC Semua Email + CC wajib Done (Access Management >
--    Email Pengajuan). OSC / Supervisor depot tidak lagi otomatis ditembuskan pada email Done.
--    Jenis email lain (Pengajuan Baru, On Hold / Expired, Disetujui) tidak berubah.
--  * Mode uji tetap membuat surat uji.
--
-- Tambalan memakai penjaga MD5 pra-citra; keduanya sama di dev dan prod (20 Oktober 2026) dan
-- tidak bergantung pada migrasi 20261163170000 - 20261163200000.
-- ==========================================================================================

create or replace function pg_temp.ganti(p_src text, p_lama text, p_baru text, p_n integer, p_nama text)
returns text language plpgsql as $f$
declare n integer := (length(p_src) - length(replace(p_src, p_lama, ''))) / greatest(length(p_lama), 1);
begin
  if n <> p_n then raise exception '%: pola ditemukan % kali, diharapkan %: %', p_nama, n, p_n, left(p_lama, 120); end if;
  return replace(p_src, p_lama, p_baru);
end $f$;

-- "User yang proses" untuk email Done: pengaju klaim (submitted_by); bila tidak ada, user yang
-- memproses Done (pelaku dan cleared_by). Hanya akun aktif ber-email, apa pun perannya.
create or replace function rc_private.email_done_penerima(p_ids uuid[], p_aktor uuid) returns text[]
language sql stable security definer set search_path = '' as $f$
  select case when cardinality(x.pengaju) > 0 then x.pengaju else x.pemroses end
    from (select
      coalesce((select array_agg(distinct lower(btrim(p.business_email)) order by lower(btrim(p.business_email)))
                  from public.claims c join public.profiles p on p.id = c.submitted_by
                 where c.id = any(coalesce(p_ids, '{}')) and coalesce(p.status, '') = 'active'
                   and coalesce(p.business_email, '') like '%@%'), '{}') as pengaju,
      coalesce((select array_agg(distinct lower(btrim(p.business_email)) order by lower(btrim(p.business_email)))
                  from public.profiles p
                 where (p.id = p_aktor
                        or p.id in (select c.cleared_by from public.claims c where c.id = any(coalesce(p_ids, '{}'))))
                   and coalesce(p.status, '') = 'active' and coalesce(p.business_email, '') like '%@%'), '{}') as pemroses) x;
$f$;
revoke all on function rc_private.email_done_penerima(uuid[], uuid) from public, anon, authenticated;

do $tambal$
declare src text; f record;
begin
  for f in select * from (values
    ('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)', 'fc22f88de96cd7dce6d84541df8fdab8'),
    ('rc_private.email_pengajuan_penerima(uuid,text)', '97d2065aa7a97aaf740c3a959496f7fe')) x(sig, harapan)
  loop
    src := replace(pg_get_functiondef(f.sig::regprocedure), E'\r', '');
    if src ~ '20261163210000' then raise notice '% sudah ditambal.', f.sig; continue; end if;
    if md5(src) <> f.harapan then raise exception 'DITOLAK: % berbeda dari yang diukur (md5 %).', f.sig, md5(src); end if;

    if f.sig like 'rc_private.email_pengajuan_antre%' then
      src := pg_temp.ganti(src, $p$    -- 20261163100000: email Done hanya ke Kepala Admin depot (Depot Master > Email Kepala Admin).
    -- Selama kolom itu kosong, tetap ke Email TO depot. CC tidak berubah, tanpa alamat TO.
    if p_action = 'clearing' then
      select coalesce(array_agg(distinct lower(btrim(x))), '{}') into v_ka
        from public.depot_profiles dp, unnest(rc_private.pecah_email(dp.email_kepala_admin)) x
       where dp.depot_id = v_dep.depot_id and btrim(x) <> '';
      if coalesce(array_length(v_ka,1),0) > 0 then
        v_to := v_ka;
        v_cc := array(select y from unnest(v_cc) y where not (lower(y) = any(v_ka)));
      end if;
    end if;$p$,
        $p$    -- 20261163100000 + 20261163210000: TO email Done = Email Kepala Admin depot (Depot Master).
    -- Bila kosong, user yang proses (pemilik, 20 Oktober 2026): pengaju klaim di surat ini, lalu
    -- user yang memproses Done. Tidak lagi ke Email TO depot; tanpa alamat, ditahan. CC tanpa TO.
    if p_action = 'clearing' then
      select coalesce(array_agg(distinct lower(btrim(x))), '{}') into v_ka
        from public.depot_profiles dp, unnest(rc_private.pecah_email(dp.email_kepala_admin)) x
       where dp.depot_id = v_dep.depot_id and btrim(x) <> '';
      if coalesce(array_length(v_ka,1),0) = 0 then
        v_ka := rc_private.email_done_penerima(v_ids, p_aktor);
      end if;
      v_to := coalesce(v_ka, '{}');
      v_cc := array(select y from unnest(v_cc) y where not (lower(y) = any(coalesce(v_ka, '{}'))));
    end if;$p$, 1, 'antre TO Done');
      src := pg_temp.ganti(src, $p$                           'sebab','Alamat email depot belum diisi di Depot Master'));$p$,
        $p$                           'sebab', case when p_action = 'clearing'
                             then 'Email Kepala Admin kosong dan user yang mengajukan / memproses Done tidak punya email aktif (email Done ditahan)'
                             else 'Alamat email depot belum diisi di Depot Master' end));$p$, 1, 'antre sebab');
      src := pg_temp.ganti(src, $p$             'BELUM ADA ALAMAT DEPOT DI DEPOT MASTER')) || '<br>'$p$,
        $p$             case when p_action = 'clearing' then 'TIDAK ADA EMAIL KEPALA ADMIN MAUPUN EMAIL USER YANG PROSES - email Done ditahan, tidak dikirim'
                  else 'BELUM ADA ALAMAT DEPOT DI DEPOT MASTER' end)) || '<br>'$p$, 1, 'antre spanduk');
    else
      -- CC email Done hanya dari Access Management: OSC / Supervisor depot tidak ikut.
      src := pg_temp.ganti(src, $p$         and lower(coalesce(p.role,'')) in ('osc','supervisor')$p$,
        $p$         and lower(coalesce(p.role,'')) in ('osc','supervisor')
         and coalesce(p_kategori,'') <> 'done' /* 20261163210000: CC email Done hanya dari Access Management */$p$, 1, 'penerima CC Done');
    end if;
    execute src;
  end loop;
end $tambal$;

do $cek$
declare e text := '';
begin
  if pg_get_functiondef('rc_private.email_pengajuan_antre(text,text,uuid[],uuid,text)'::regprocedure) !~ 'email_done_penerima' then e := e || ' antre;'; end if;
  if pg_get_functiondef('rc_private.email_pengajuan_penerima(uuid,text)'::regprocedure) !~ 'CC email Done hanya dari Access Management' then e := e || ' penerima;'; end if;
  if e <> '' then raise exception 'GAGAL:%', e; end if;
end $cek$;
