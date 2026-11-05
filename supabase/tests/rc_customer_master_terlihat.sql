-- ==========================================================================================
-- Uji Customer Master terlihat (migrasi 20261163280000)
-- ==========================================================================================
-- Pemeriksaan RLS dijalankan sebagai peran authenticated (SET LOCAL ROLE) dengan klaim JWT user
-- uji. Seluruh perubahan (akses, klaim) di subtransaksi yang DIBATALKAN (UJI_SELESAI). Aman untuk
-- dev dan prod.
--
--   node scripts/apply-sql.mjs --env dev|prod supabase/tests/rc_customer_master_terlihat.sql
-- ==========================================================================================
create temp table if not exists _hasil_cm(urut serial, uji text, lulus boolean, rinci text);
truncate _hasil_cm;
grant all on _hasil_cm to authenticated;
create temp table if not exists _lihat_cm(n bigint);
truncate _lihat_cm;
grant all on _lihat_cm to authenticated;

create or replace function pg_temp.terlihat(p_user uuid, p_customer uuid) returns boolean language plpgsql as $f$
declare v boolean;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select exists(select 1 from public.customers where id = p_customer) into v;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  return v;
end $f$;

do $uji$
declare hasil jsonb := '[]'; v_sm uuid; v_dep uuid; v_cust uuid; v_non uuid; c record; v_dep2 uuid; n integer;
begin
  select id into v_sm from public.profiles where role = 'system manager' and status = 'active' and not must_change_password order by user_code limit 1;
  -- Customer yang hanya tertaut ke satu depot.
  select cd.customer_id, cd.depot_id into v_cust, v_dep from public.customer_depots cd
   where (select count(*) from public.customer_depots x where x.customer_id = cd.customer_id) = 1 limit 1;
  -- User non-System Manager yang tidak menjangkau depot itu.
  select p.id into v_non from public.profiles p where p.status = 'active' and not p.must_change_password and p.role not in ('system manager')
     and exists(select 1 from public.user_depot_access a where a.user_id = p.id)
     and not exists(select 1 from public.user_depot_access a where a.user_id = p.id and a.depot_id = v_dep) order by p.user_code limit 1;

  begin
    -- A. System Manager tetap melihat walau cermin aksesnya tertinggal.
    delete from public.user_depot_access where user_id = v_sm and depot_id = v_dep;
    hasil := hasil || jsonb_build_object('uji', 'System Manager melihat customer walau baris aksesnya ke depot itu tidak ada',
      'lulus', pg_temp.terlihat(v_sm, v_cust), 'rinci', '');
    hasil := hasil || jsonb_build_object('uji', 'User lain tetap hanya melihat customer di depot jangkauannya',
      'lulus', v_non is not null and not pg_temp.terlihat(v_non, v_cust), 'rinci', '');
    insert into public.user_depot_access(user_id, depot_id) values (v_non, v_dep);
    hasil := hasil || jsonb_build_object('uji', 'Setelah diberi akses depot itu, user tersebut melihatnya',
      'lulus', pg_temp.terlihat(v_non, v_cust), 'rinci', '');

    -- B. Klaim di depot baru menautkan tokonya otomatis.
    select c2.id, c2.customer_id into c from public.claims c2
     where c2.archived_at is null and c2.customer_id is not null order by c2.created_at desc limit 1;
    select d.id into v_dep2 from public.depots d where d.archived_at is null
       and not exists(select 1 from public.customer_depots cd where cd.customer_id = c.customer_id and cd.depot_id = d.id) limit 1;
    update public.claims set depot_id = v_dep2 where id = c.id;
    hasil := hasil || jsonb_build_object('uji', 'Klaim dipindah / dibuat di depot lain: toko otomatis tertaut ke depot itu',
      'lulus', exists(select 1 from public.customer_depots where customer_id = c.customer_id and depot_id = v_dep2), 'rinci', '');
    update public.claims set updated_at = updated_at where id = c.id;
    hasil := hasil || jsonb_build_object('uji', 'Perubahan klaim berikutnya tidak menggandakan tautan',
      'lulus', (select count(*) from public.customer_depots where customer_id = c.customer_id and depot_id = v_dep2) = 1, 'rinci', '');

    select count(*) into n from public.claims c3
     where c3.archived_at is null and c3.customer_id is not null and c3.depot_id is not null
       and not exists(select 1 from public.customer_depots cd where cd.customer_id = c3.customer_id and cd.depot_id = c3.depot_id);
    hasil := hasil || jsonb_build_object('uji', 'Tidak ada lagi klaim aktif yang tokonya belum tertaut ke depot klaim', 'lulus', n = 0, 'rinci', n || ' pasangan');

    hasil := hasil || jsonb_build_object('uji', 'Cermin akses System Manager lengkap (seluruh depot)',
      'lulus', not exists(select 1 from public.profiles p cross join public.depots d
                           where p.role = 'system manager' and p.status = 'active'
                             and not exists(select 1 from public.user_depot_access a where a.user_id = p.id and a.depot_id = d.id)
                             and not (p.id = v_sm and d.id = v_dep)),
      'rinci', '');

    raise exception 'UJI_SELESAI';
  exception when others then
    if sqlerrm <> 'UJI_SELESAI' then hasil := hasil || jsonb_build_object('uji', 'Blok uji berhenti', 'lulus', false, 'rinci', sqlerrm); end if;
  end;

  insert into _hasil_cm(uji, lulus, rinci) select x->>'uji', (x->>'lulus')::boolean, x->>'rinci' from jsonb_array_elements(hasil) x;
end $uji$;

select urut, case when lulus then 'LULUS' else 'GAGAL' end hasil, uji, rinci from _hasil_cm order by urut;
