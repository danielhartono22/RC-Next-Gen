
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

            // Dialog umum untuk menampilkan HTML apa pun.
            //
            // showActionResult() TIDAK dapat dipakai untuk ini: tanda tangannya
            // (title, successList, failList, actionType, batchNum) menuntut daftar hasil
            // eksekusi, dan ia memanggil .map() atas argumen kedua. Memberinya string HTML
            // membuatnya melempar TypeError sebelum sempat menampilkan apa pun, sehingga
            // layar hanya diam tanpa dialog dan tanpa pesan galat yang terlihat.
            function rcDialog(judul, html) {
                document.getElementById('rcDialogTitle').innerText = judul || '';
                const body = document.getElementById('rcDialogBody');
                const modal = document.getElementById('rcDialogModal');
                body.innerHTML = html || '';
                // Detail berupa tabel/grafik memerlukan panel lebar; pesan dan formulir pendek
                // tetap memakai ukuran ringkas. Keduanya selalu dibatasi viewport oleh CSS.
                modal.classList.toggle('rc-dialog-wide', !!body.querySelector('table, canvas, [data-rc-dialog-wide]'));
                setHiddenSafely('rcDialogModal', false);
                rcUkurUlangGrafik(body);
            }

            function rcTutupDialog() { setHiddenSafely('rcDialogModal', true); }

            document.addEventListener('keydown', function (e) {
                if (e.key === 'Escape') rcTutupDialog();
            });

            // ------------------------------------------------------------------------------
            // Status Pajak: satu penafsiran untuk seluruh layar
            // ------------------------------------------------------------------------------
            // Kolom tax_status pada master campaign berisi kalimat bebas warisan spreadsheet
            // lama, dan isinya beragam:
            //
            //   "PT Nipsea Paint and Chemicals" (35 campaign)   "Rebate Non Tax" (28)
            //   "PT Nipsea Paint And Chemicals" (11, beda huruf) "Customer"       (22)
            //   "0" (3)                                          kosong           (1)
            //
            // Sementara itu filter di layar hanya menawarkan "Ditanggung Perusahaan" dan
            // "Ditanggung Customer". Tidak satu pun nilai di atas memuat kata "ditanggung",
            // sehingga KEDUA pilihan filter itu selalu menghasilkan tabel kosong - inilah
            // yang terlihat sebagai status pajak "tidak sinkron".
            //
            // Penafsirannya disatukan di sini supaya filter, tampilan kolom, dan perhitungan
            // gross up membaca nilai yang sama. Teks aslinya tidak diubah di database; yang
            // disepakati hanyalah cara membacanya.
            const RC_PAJAK = {
                perusahaan: { label: 'Ditanggung Perusahaan', kelas: 'text-emerald-700' },
                customer:   { label: 'Ditanggung Customer',   kelas: 'text-orange-700' },
                nonTax:     { label: 'Rebate Non Tax',        kelas: 'text-sky-700' },
                takJelas:   { label: 'Belum Ditentukan',      kelas: 'text-gray-400' }
            };

            function rcKunciPajak(mentah) {
                const t = String(mentah == null ? '' : mentah).trim().toLowerCase();
                if (!t || t === '0' || t === '-') return 'takJelas';
                if (t.indexOf('non tax') > -1 || t.indexOf('nontax') > -1) return 'nonTax';
                if (t.indexOf('nipsea') > -1 || t.indexOf('ditanggung perusahaan') > -1
                    || t.indexOf('ditanggung pt') > -1 || t.indexOf('perusahaan') > -1) return 'perusahaan';
                if (t.indexOf('customer') > -1 || t.indexOf('toko') > -1) return 'customer';
                return 'takJelas';
            }

            // Label seragam sebagai teks biasa. Dipakai berkas Excel, yang tidak dapat memuat
            // markup, dan menjadi dasar bentuk berwarna di bawahnya.
            function rcTeksPajak(mentah) { return RC_PAJAK[rcKunciPajak(mentah)].label; }

            // Label seragam untuk ditampilkan. Teks aslinya tetap dibawa sebagai title, supaya
            // perbedaan penulisan di master masih dapat ditelusuri dari layar.
            function rcLabelPajak(mentah) {
                const k = rcKunciPajak(mentah);
                const asli = String(mentah == null ? '' : mentah).trim();
                return '<span class="' + RC_PAJAK[k].kelas + ' font-bold" title="'
                    + rcEsc(asli || '(kosong di master campaign)') + '">' + RC_PAJAK[k].label + '</span>';
            }

            // Subyek Pajak toko diturunkan dari kelengkapan identitasnya, bukan dari kolom yang
            // pernah disimpan saat upload. Kolom simpanan itu dapat tertinggal ketika KTP atau
            // NPWP toko diperbarui kemudian, dan 37 dokumen di basis data ini memang sudah
            // menyimpang dari identitas tokonya.
            function rcSubyekPajak(ktp, npwp) {
                const a = String(ktp || '').replace(/\D/g, '');
                const b = String(npwp || '').replace(/\D/g, '');
                if (a && b) return 'Check';
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
