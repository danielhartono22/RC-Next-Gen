-- ==========================================================================================
-- Nol di depan No KTP, NPWP dan No Rekening per klaim dikembalikan dari Customer Master
-- ==========================================================================================
-- Pemilik, 12 Oktober 2026: "saya cek ada beberapa seperti no ktp 0 nya terhapus ketika di
-- download, saya mau di perbaiki".
--
-- SEBABNYA. Lembar Klaim pada template muat ulang memuat sebagian identitas sebagai sel ANGKA
-- di Excel, sehingga nol di depannya sudah hilang sebelum dimuat (pemeriksa muat ulang memang
-- memperingatkan "tersimpan sebagai angka; nol di depan sudah hilang"). Nilai per klaim itu
-- tersimpan di rc_private.claim_sensitive dan mengungguli Customer Master, sementara Customer
-- Master sendiri utuh. Di prod 12 Oktober 2026: 1.973 NPWP, 21 No Rekening dan 6 KTP.
--
-- YANG DIUBAH. Hanya nilai yang SAMA PERSIS dengan Customer Master kecuali nol di depannya:
-- keduanya hanya angka, nilai klaim lebih pendek, dan sama setelah nol di depan dibuang.
-- Nilai klaim yang memang berbeda dari master (identitas lain yang diajukan untuk klaim itu)
-- tidak disentuh, begitu pula klaim tanpa Customer Master - tidak ada pembandingnya.
--
-- Satu catatan per jalannya ditulis ke activity_logs. Aman dijalankan berulang: jalan kedua
-- tidak menemukan apa pun lagi.
-- ==========================================================================================

do $pulih$
declare n_ktp int; n_npwp int; n_rek int; sisa int;
begin
  create temp table _nol on commit drop as
  select s.claim_id,
         case when s.ktp ~ '^[0-9]+$' and cu.ktp ~ '^[0-9]+$' and length(s.ktp) < length(cu.ktp)
                   and ltrim(cu.ktp, '0') = ltrim(s.ktp, '0') then cu.ktp end ktp,
         case when s.npwp ~ '^[0-9]+$' and cu.npwp ~ '^[0-9]+$' and length(s.npwp) < length(cu.npwp)
                   and ltrim(cu.npwp, '0') = ltrim(s.npwp, '0') then cu.npwp end npwp,
         case when s.account_number ~ '^[0-9]+$' and cu.account_number ~ '^[0-9]+$'
                   and length(s.account_number) < length(cu.account_number)
                   and ltrim(cu.account_number, '0') = ltrim(s.account_number, '0') then cu.account_number end rek
    from rc_private.claim_sensitive s
    join public.claims c on c.id = s.claim_id
    join public.customers cu on cu.id = c.customer_id;
  delete from _nol where ktp is null and npwp is null and rek is null;

  select count(ktp), count(npwp), count(rek) into n_ktp, n_npwp, n_rek from _nol;
  if n_ktp + n_npwp + n_rek = 0 then raise notice 'Tidak ada nol di depan yang hilang.'; return; end if;

  update rc_private.claim_sensitive s
     set ktp = coalesce(x.ktp, s.ktp),
         npwp = coalesce(x.npwp, s.npwp),
         account_number = coalesce(x.rek, s.account_number)
    from _nol x
   where x.claim_id = s.claim_id;

  -- Pemeriksaan: tidak ada lagi pasangan yang hanya berbeda nol di depan.
  select count(*) into sisa
    from rc_private.claim_sensitive s
    join public.claims c on c.id = s.claim_id
    join public.customers cu on cu.id = c.customer_id
   where (s.ktp ~ '^[0-9]+$' and cu.ktp ~ '^[0-9]+$' and length(s.ktp) < length(cu.ktp) and ltrim(cu.ktp,'0') = ltrim(s.ktp,'0'))
      or (s.npwp ~ '^[0-9]+$' and cu.npwp ~ '^[0-9]+$' and length(s.npwp) < length(cu.npwp) and ltrim(cu.npwp,'0') = ltrim(s.npwp,'0'))
      or (s.account_number ~ '^[0-9]+$' and cu.account_number ~ '^[0-9]+$' and length(s.account_number) < length(cu.account_number)
          and ltrim(cu.account_number,'0') = ltrim(s.account_number,'0'));
  if sisa > 0 then raise exception 'GAGAL: % baris masih kehilangan nol di depan.', sisa; end if;

  insert into public.activity_logs(actor_id, event_type, details)
  values (null, 'identitas_nol_depan_dipulihkan', jsonb_build_object(
    'migrasi', '20261162220000', 'ktp', n_ktp, 'npwp', n_npwp, 'noRekening', n_rek,
    'sumber', 'Customer Master'));
  raise notice 'Nol di depan dipulihkan: % KTP, % NPWP, % No Rekening.', n_ktp, n_npwp, n_rek;
end
$pulih$;
