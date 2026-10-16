            // ============================================================================
            // LAPISAN TAMPILAN BERSAMA
            // ============================================================================
            // Berkas ini dipakai DUA halaman: portal Resource Collection (disisipkan ke dalam
            // src/index.html oleh build) dan Claim Dashboard publik (dimuat sebagai
            // public/assets/rc-report-view.js). Keduanya memakai berkas yang sama, bukan salinan.
            //
            // Sebabnya permintaan pemilik: dashboard publik harus sama dengan Report di dalam
            // aplikasi "termasuk jika ada perubahan ke depan". Salinan memenuhi "sama hari ini"
            // lalu menyimpang pada suntingan berikutnya, dan penyimpangan itu baru ketahuan
            // setelah dibaca orang di luar. Satu sumber membuat penyimpangan itu tidak mungkin.
            //
            // Karena itu isinya harus tetap bebas dari apa pun yang mengandaikan adanya sesi:
            // tidak memanggil backend, tidak membaca currentUserData, tidak mengenal hak akses.
            // Yang boleh ada di sini hanya cara MENGGAMBAR, bukan cara memperoleh datanya.

            function setHiddenSafely(id, sh) { let e = document.getElementById(id); if (e) { if (sh) e.classList.add('hidden'); else e.classList.remove('hidden'); } }

            function rcEsc(v) {
                return String(v === null || v === undefined ? '' : v)
                    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
            }

            // ============================================================================
            // PENGURUTAN KOLOM TABEL, DIPAKAI SELURUH MODUL
            // ============================================================================
            // Pemilik meminta setiap header tabel dapat diurutkan naik dan turun. Dibuat satu
            // kali di sini, bukan di tiap modul, supaya perilakunya sama di mana pun: klik
            // pertama menurun, klik kedua menaik, klik ketiga kembali ke urutan asli.
            //
            // MENGAPA MENGURUT DOM, BUKAN DATA
            // Tabel di aplikasi ini dirender sebagai HTML oleh masing-masing modul dengan bentuk
            // baris yang berbeda-beda. Mengurut baris <tr> yang sudah jadi membuat satu fungsi
            // ini berlaku untuk semua tabel tanpa satu pun modul perlu menyerahkan datanya
            // dalam bentuk khusus. Yang dibandingkan adalah isi selnya, dengan angka dan tanggal
            // dikenali lebih dulu supaya "Rp 1.200.000" tidak diurutkan sebagai teks.

            function rcAngkaDari(teks) {
                const s = String(teks == null ? '' : teks).trim();
                if (s === '' || s === '-') return null;
                // Buang mata uang, spasi, dan pemisah ribuan titik; koma menjadi titik desimal.
                const bersih = s.replace(/rp/i, '').replace(/\s/g, '')
                    .replace(/\.(?=\d{3}\b)/g, '').replace(/,/, '.').replace(/[%x]/gi, '');
                if (/^-?\d+(\.\d+)?$/.test(bersih)) return Number(bersih);
                // Tanggal DD/MM/YYYY atau DD-MM-YYYY diubah agar dapat dibandingkan sebagai angka.
                const t = s.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})/);
                if (t) return Number(t[3] + t[2].padStart(2, '0') + t[1].padStart(2, '0'));
                if (/^\d{1,2}-[A-Za-z]{3}-\d{4}/.test(s)) { const d=Date.parse(s.replace(' ', 'T')); if(Number.isFinite(d))return d; const fallback=Date.parse(s);if(Number.isFinite(fallback))return fallback; }
                return null;
            }

            function rcBandingkan(a, b) {
                const na = rcAngkaDari(a), nb = rcAngkaDari(b);
                if (na !== null && nb !== null) return na - nb;
                // Sel kosong selalu di bawah, apa pun arah pengurutannya; sebuah kolom yang
                // separuhnya kosong akan terlihat kacau bila baris kosongnya ikut naik.
                if (na === null && nb !== null) return 1;
                if (na !== null && nb === null) return -1;
                return String(a).localeCompare(String(b), 'id', { sensitivity: 'base' });
            }

            function rcAktifkanUrut(tabel) {
                if (!tabel || tabel.dataset.rcSortSiap === '1') return;
                const thead = tabel.tHead;
                const tbody = tabel.tBodies && tabel.tBodies[0];
                if (!thead || !tbody) return;

                // Hanya baris header terakhir yang diberi tombol urut; tabel dengan header
                // bertingkat memakai baris teratas sebagai pengelompokan, bukan kolom.
                const baris = thead.rows[thead.rows.length - 1];
                if (!baris) return;

                [...baris.cells].forEach((th, idx) => {
                    if (th.dataset.rcNoSort === '1') return;
                    th.classList.add('rc-sort');
                    if (!th.querySelector('.rc-arrow')) {
                        th.insertAdjacentHTML('beforeend', '<span class="rc-arrow">&#9650;&#9660;</span>');
                    }
                    th.addEventListener('click', () => rcUrutKolom(tabel, idx, th));
                });
                tabel.dataset.rcSortSiap = '1';
            }

            function rcUrutKolom(tabel, idx, th) {
                const tbody = tabel.tBodies[0];
                const barisAsli = [...tbody.rows];
                // Urutan asli disimpan sekali, supaya klik ketiga benar-benar mengembalikannya
                // dan bukan sekadar membalik hasil urutan sebelumnya.
                if (!tabel.rcUrutanAsli || tabel.rcUrutanAsli.length !== barisAsli.length) {
                    tabel.rcUrutanAsli = barisAsli.slice();
                }

                const arahLama = th.classList.contains('rc-desc') ? 'desc'
                    : th.classList.contains('rc-asc') ? 'asc' : '';
                const arah = arahLama === '' ? 'desc' : arahLama === 'desc' ? 'asc' : '';

                [...th.parentElement.cells].forEach(c => c.classList.remove('rc-asc', 'rc-desc'));
                if (arah) th.classList.add('rc-' + arah);

                let hasil;
                if (arah === '') {
                    hasil = tabel.rcUrutanAsli.slice();
                } else {
                    const isi = (tr) => {
                        const td = tr.cells[idx];
                        return td ? (td.dataset.sort !== undefined ? td.dataset.sort : td.innerText) : '';
                    };
                    hasil = barisAsli.slice().sort((x, y) =>
                        (arah === 'asc' ? 1 : -1) * rcBandingkan(isi(x), isi(y)));
                }
                const frag = document.createDocumentFragment();
                hasil.forEach(tr => frag.appendChild(tr));
                tbody.appendChild(frag);
            }

            // Dipanggil sesudah sebuah modul selesai menggambar tabelnya.
            function rcAktifkanUrutSemua(induk) {
                const akar = (typeof induk === 'string' ? document.getElementById(induk) : induk) || document;
                akar.querySelectorAll('table').forEach(t => {
                    // Baris baru berarti urutan asli yang lama sudah tidak berlaku.
                    t.rcUrutanAsli = null;
                    rcAktifkanUrut(t);
                });
            }

            // Tabel dan rincian tetap memakai rupiah penuh tanpa bagian desimal.
            function rcNominal(n) { return rcNominalPenuh(n); }

            // Kartu ringkasan memakai satuan juta, termasuk nilai di bawah satu juta.
            // Pecahan di sini adalah pecahan juta; nilai detail tetap rupiah utuh.
            function rcNominalRingkas(n) {
                const raw = Number(n);
                const juta = (Number.isFinite(raw) ? Math.trunc(raw) : 0) / 1000000 || 0;
                return 'Rp ' + juta.toLocaleString('id-ID', {
                    // Nominal kecil yang bukan nol jangan tampak sebagai nol juta.
                    maximumFractionDigits: Math.abs(juta) < 0.01 ? 6 : 2
                }) + ' jt';
            }

            // Nilai penuh, TANPA BAGIAN DESIMAL ke rupiah utuh.
            //
            // Gross up dihitung dengan pembagian, sehingga nilainya kerap berekor panjang -
            // 13268421.05263158 muncul di layar sebagai "Rp 13.268.421,053". Pemilik meminta
            // ekor itu hilang: "untuk nominal yang ada desimalnya tidak perlu masukan decimalnya".
            //
            // Bagian desimal dihilangkan pada TAMPILAN dan export nominal. Nilai aslinya tetap utuh di basis data dan pada
            // atribut data-sort, sehingga pengurutan dan penjumlahan tidak ikut kehilangan presisi.
            function rcNominalPenuh(n) { return 'Rp ' + Math.trunc(Number(n) || 0).toLocaleString('id-ID'); }

            // Memperbesar kartu dengan MEMINDAHKAN isinya ke dialog tersendiri, bukan
            // menempelkan kelas CSS pada kartunya di tempat. Cara lama membuat kartu tetap
            // terkurung di dalam grid induknya beserta overflow dan stacking context-nya,
            // sehingga pada sebagian tata letak ia tidak membesar sama sekali.
            //
            // Isinya dipindahkan, bukan disalin: grafik Chart.js terikat pada elemen kanvas
            // aslinya, dan menyalin kanvas hanya menghasilkan gambar kosong.
            let rcExpandAsal = null;

            function rcToggleCardExpand(cardId) {
                if (rcExpandAsal) { rcTutupCardExpand(); return; }
                const kartu = document.getElementById(cardId);
                if (!kartu) return;

                const judul = kartu.querySelector('h3');
                document.getElementById('cardExpandTitle').innerText =
                    judul ? judul.innerText.trim() : 'Perbesar';

                // Yang dipindahkan hanya isi, bukan tombol perbesar dan judulnya.
                const isi = kartu.querySelector('.rc-expand-body') || kartu;
                const penanda = document.createComment('rc-expand-placeholder');
                isi.parentNode.insertBefore(penanda, isi);
                const wadahKanvas = [];
                isi.querySelectorAll('canvas').forEach(function (canvas) {
                    const wadah = canvas.parentElement;
                    if (wadah && wadah !== isi && !wadahKanvas.some(x => x.el === wadah)) {
                        wadahKanvas.push({ el: wadah, gaya: wadah.getAttribute('style') });
                    }
                });
                rcExpandAsal = {
                    isi: isi, penanda: penanda, kelas: isi.className,
                    gaya: isi.getAttribute('style'), wadahKanvas: wadahKanvas
                };

                isi.classList.add('rc-expanded-content');
                if (isi.querySelector('canvas')) {
                    isi.classList.add('rc-expanded-chart');
                    wadahKanvas.forEach(function (x) {
                        x.el.style.height = '100%';
                        x.el.style.minHeight = '0';
                        x.el.style.flex = '1 1 auto';
                    });
                }
                document.getElementById('cardExpandBody').appendChild(isi);
                setHiddenSafely('cardExpandModal', false);
                document.body.classList.add('rc-has-expanded');
                rcUkurUlangGrafik(isi);
            }

            function rcTutupCardExpand() {
                if (!rcExpandAsal) return;
                const { isi, penanda, kelas, gaya, wadahKanvas } = rcExpandAsal;
                isi.className = kelas;
                if (gaya === null) isi.removeAttribute('style'); else isi.setAttribute('style', gaya);
                (wadahKanvas || []).forEach(function (x) {
                    if (x.gaya === null) x.el.removeAttribute('style'); else x.el.setAttribute('style', x.gaya);
                });
                penanda.parentNode.insertBefore(isi, penanda);
                penanda.remove();
                rcExpandAsal = null;
                setHiddenSafely('cardExpandModal', true);
                document.body.classList.remove('rc-has-expanded');
                rcUkurUlangGrafik(isi);
            }

            // Mengukur ulang grafik sesudah kanvasnya berpindah wadah.
            //
            // Memanggil resize() saja tidak cukup, dan itulah sebab kartu menjadi raksasa
            // sesudah modal ditutup: Chart.js menuliskan lebar dan tinggi sebagai gaya INLINE
            // pada elemen kanvas. Ketika kanvas dipindahkan kembali ke kartu aslinya, gaya itu
            // ikut terbawa, dan resize() justru membaca ukuran besar tersebut sebagai ukuran
            // yang diinginkan. Gaya inline-nya dikosongkan lebih dulu supaya ukuran dihitung
            // ulang dari wadah barunya.
            function rcUkurUlangGrafik(akar) {
                if (!window.Chart || typeof Chart.getChart !== 'function') return;
                const ukur = function () {
                    akar.querySelectorAll('canvas').forEach(function (c) {
                        const ch = Chart.getChart(c);
                        if (!ch) return;
                        c.style.width = '';
                        c.style.height = '';
                        ch.resize();
                    });
                };
                // Dua kali: sekali pada bingkai berikutnya, sekali sesudah tata letak benar-benar
                // selesai. Ukuran akhir wadah belum diketahui pada pemanggilan pertama.
                if (window.requestAnimationFrame) window.requestAnimationFrame(ukur); else ukur();
                window.setTimeout(ukur, 260);
            }
            // Escape menutup kartu yang sedang diperbesar, seperti perilaku modal lain di halaman.
            document.addEventListener('keydown', function (e) {
                if (e.key === 'Escape' && rcExpandAsal) rcTutupCardExpand();
            });

            function showNotification(msg, type = "error") {
                let n = document.getElementById('notification'); let icon = type === 'success' ? '<i class="fas fa-check-circle mr-2 text-xl"></i>' : (type === 'warning' ? '<i class="fas fa-exclamation-triangle mr-2 text-xl"></i>' : '<i class="fas fa-times-circle mr-2 text-xl"></i>');
                n.innerHTML = icon + msg; n.className = `fixed bottom-5 right-5 px-5 py-3.5 rounded-xl shadow-2xl text-white font-bold z-[100] flex items-center border border-white/20 transform transition-all duration-300 scale-100 ${type === 'success' ? 'bg-green-600' : (type === 'warning' ? 'bg-orange-500' : 'bg-red-600')}`;
                n.style.display = 'flex'; setTimeout(() => { n.classList.remove('scale-100'); n.classList.add('scale-95', 'opacity-0'); setTimeout(() => { n.style.display = 'none'; n.classList.remove('opacity-0'); }, 300); }, 5000);
            }

            // Sel Excel untuk unduhan yang harus SAMA dengan layar. Pemilik, 12 Oktober 2026:
            // "semua yang muncul di layar harus sama ketika di download".
            //   rcSelTeks    identitas dan kode (KTP, NPWP, No Rekening, No Doc, kode toko) selalu
            //                teks, sehingga Excel tidak membuang nol di depan atau mengubah digit
            //                ke-16 menjadi 0.
            //   rcSelPersen  rasio 0..1 tampil seperti layar (rtPersen), mis. 87,7%, tetapi tetap
            //                angka yang dapat dihitung.
            function rcSelTeks(v) {
                if (v === null || v === undefined || v === '') return '';
                return { t: 's', v: String(v), z: '@' };
            }
            function rcSelPersen(rasio) {
                const n = Number(rasio);
                return Number.isFinite(n) ? { t: 'n', v: n, z: '0.0%' } : '';
            }

            // Nominal ditulis sebagai rupiah bulat seperti di layar (Math.trunc); rasio sebagai persen.
            function rcExportAmount(key, value, row) {
                if(typeof value !== 'number' || !Number.isFinite(value)) return value;
                if(/rate$/i.test(key) || /rate$/i.test(row && row.Keterangan || '')) return rcSelPersen(value);
                if(/persen|percent|pct|%/i.test(key+' '+(row && row.Keterangan || '')))return value;
                return /cashback|gross|cb|claimed|expired|outstanding|reward|nilai|value|tagih|nominal|amount/i.test(key+' '+(row && row.Keterangan || '')) ? Math.trunc(value) : value;
            }

            // Penanda lingkungan DEV. Situs dev dan produksi tampak identik, sehingga mudah
            // tertukar - padahal akun uji dev tidak ada di produksi dan sebaliknya. Pita ini
            // hanya muncul bila config yang dimuat menyatakan environment 'dev'; tampilan
            // produksi tidak berubah sama sekali.
            document.addEventListener('DOMContentLoaded', function () {
                if (!window.RC_ENV || window.RC_ENV.environment !== 'dev') return;
                document.body.insertAdjacentHTML('afterbegin',
                    '<div id="rcPitaDev" class="bg-yellow-300 text-yellow-900 text-center text-xs font-black tracking-widest py-1">'
                    + 'LINGKUNGAN DEV · database rc-next-gen-dev · data rekayasa, bukan data produksi</div>');
            });
