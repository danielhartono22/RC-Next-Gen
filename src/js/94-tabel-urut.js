
            // Mengisi satu kartu angka.
            //
            // Kartu ringkasan di modul antrean sebelumnya berupa pil teks yang memuat judul dan
            // nilainya sekaligus - "Total Cashback: Rp 3.330.540.954". Pada layar laptop pil itu
            // melipat di tengah kalimat dan barisnya menjadi berantakan, dan bentuknya pun
            // berbeda dari kartu angka di Report maupun Timetable. Sekarang judulnya menjadi
            // bagian kartu dan fungsi ini hanya mengisi nilainya, memakai gaya yang sama.
            function rcIsiKartuAngka(id, nilai, nilaiPenuh) {
                const el = document.getElementById(id);
                if (!el) return;
                el.innerText = nilai;
                el.classList.toggle('rc-kpi-money', Boolean(nilaiPenuh));
                if (nilaiPenuh) el.title = nilaiPenuh; else el.removeAttribute('title');
            }

            // Pemilik meminta "header apapun" dapat diurutkan. Memanggil rcAktifkanUrutSemua()
            // di setiap fungsi render berarti menyentuh puluhan tempat dan pasti ada yang
            // terlewat. Pengamat ini menyalakannya sendiri begitu sebuah tabel memperoleh baris,
            // sehingga tabel yang dibuat kemudian pun ikut terlayani tanpa perlu diingat.
            document.addEventListener('DOMContentLoaded', function () {
                const pasang = () => document.querySelectorAll('table').forEach(t => {
                    if (t.tBodies && t.tBodies[0] && t.tBodies[0].rows.length > 0) rcAktifkanUrut(t);
                });
                pasang();
                const pengamat = new MutationObserver(function (rekaman) {
                    let perlu = false;
                    rekaman.forEach(r => {
                        if (r.target && r.target.closest && r.target.closest('table')) perlu = true;
                    });
                    if (perlu) pasang();
                });
                pengamat.observe(document.body, { childList: true, subtree: true });
            });

            // rcDialog dan penafsir Status Pajak (rcKunciPajak, rcTeksPajak, rcLabelPajak) pindah ke
            // src/view/js/30-details-campaign.js (20261163470000) karena dipakai juga halaman publik
            // Details Campaign.

            // Subyek Pajak toko diturunkan dari kelengkapan identitasnya, bukan dari kolom yang
            // pernah disimpan saat upload. Kolom simpanan itu dapat tertinggal ketika KTP atau
            // NPWP toko diperbarui kemudian, dan 37 dokumen di basis data ini memang sudah
            // menyimpang dari identitas tokonya.
            function rcSubyekPajak(ktp, npwp) {
                const a = String(ktp || '').replace(/\D/g, '');
                const b = String(npwp || '').replace(/\D/g, '');
                // 20261163110000 (server): NPWP terisi berarti Badan walaupun KTP juga ada. Dulu layar
                // menulis "Check", sehingga unduhan Claim to Finance tidak sama dengan server.
                if (b) return 'Badan';
                if (a) return 'Perorangan';
                return '';
            }

            // Pemilik meminta penanggalan ditampilkan dd.mm.yyyy. Kolom <input type="date">
            // sendiri tetap memakai format ISO karena itu yang dituntut standarnya; yang
            // diubah hanyalah cara menampilkannya.
            // Satu bentuk tampilan untuk seluruh sistem: 22-Jan-2026, sama dengan keluaran
            // normalizeDateUI. Sebelumnya dd.mm.yyyy, yang mudah tertukar dengan mm.dd.yyyy
            // ketika berkasnya dibuka di mesin berlokal Amerika.
            function rcTanggalId(iso) { return rcDisplayDate(iso); }

            // Mengurai tanggal dari bentuk apa pun yang benar-benar muncul di data ini.
            //
            // Fungsi ini SENGAJA tetap longgar, berbeda dari normalizeDateUI yang kini hanya
            // menerima enam bentuk. Keduanya menangani hal yang berbeda: normalizeDateUI menjaga
            // apa yang DIKETIK pengguna, sedangkan rcUraiTanggal membaca apa yang sudah terlanjur
            // ADA di Campaign Master - dan di sana nama bulannya bercampur Indonesia dan Inggris,
            // penuh maupun singkat. Memperketatnya berarti menolak data master yang sah.
            //
            // Nama bulan pada master campaign bercampur Indonesia dan Inggris, penuh maupun
            // singkat - "01-Feb-25", "9-Desember-24", "30-Sept-24". Petanya disusun dari
            // daftar yang memang ada di data, sama seperti yang dipakai di sisi server.
            const RC_BULAN = {
                jan: 1, januari: 1, january: 1,
                feb: 2, februari: 2, february: 2,
                mar: 3, maret: 3, march: 3,
                apr: 4, april: 4,
                may: 5, mei: 5,
                jun: 6, juni: 6, june: 6,
                jul: 7, juli: 7, july: 7,
                aug: 8, agu: 8, agt: 8, agustus: 8, august: 8,
                sep: 9, sept: 9, september: 9,
                oct: 10, okt: 10, oktober: 10, october: 10,
                nov: 11, november: 11,
                dec: 12, des: 12, desember: 12, december: 12
            };

            // Mengembalikan ISO yyyy-mm-dd, atau string kosong bila tidak dikenali.
            // Tidak menebak: tanggal yang salah tebak akan memindahkan dokumen ke periode
            // yang keliru tanpa ada yang menyadarinya.
            function rcUraiTanggal(teks) {
                const s = String(teks == null ? '' : teks).trim();
                if (!s) return '';
                if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;

                let m = s.match(/^(\d{1,2})[-\/. ]+([A-Za-z]+)[-\/. ]+(\d{2,4})$/);
                if (m) {
                    const bln = RC_BULAN[m[2].toLowerCase()];
                    if (!bln) return '';
                    let thn = Number(m[3]);
                    if (thn < 100) thn += 2000;
                    return thn + '-' + String(bln).padStart(2, '0') + '-' + m[1].padStart(2, '0');
                }
                m = s.match(/^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})$/);
                if (m) {
                    let thn = Number(m[3]);
                    if (thn < 100) thn += 2000;
                    return thn + '-' + m[2].padStart(2, '0') + '-' + m[1].padStart(2, '0');
                }
                return '';
            }
