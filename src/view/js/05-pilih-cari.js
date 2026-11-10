            // ============================================================================
            // DROPDOWN BERCARI - pilihan Campaign dan Depot di seluruh modul (5 November 2026)
            // ============================================================================
            // Pemilik: "buat searchable dropdown untuk nama campaign dan depot di seluruh modul".
            // Setiap <select> tunggal yang id-nya memuat "camp" atau "depot" (bukan tahun / jenis /
            // status) diberi tombol pengganti dengan kotak cari. <select> aslinya tetap ada (hanya
            // disembunyikan) dan tetap menjadi sumber nilai, sehingga kode yang sudah ada tidak berubah:
            // onchange tetap dipicu, dan pilihan yang diisi ulang atau .value yang disetel kode langsung
            // tampil di tombol. Berkas ini bagian src/view, jadi portal dan halaman publik (Report,
            // Details Campaign) memakai komponen yang sama. Gaya: .rc-pc-* di view/parts/style.html.
            // <select data-rc-cari-tidak> dikecualikan.
            (function () {
                // DOM tiruan (uji) tanpa HTMLSelectElement / MutationObserver: komponen tidak dipasang.
                if (typeof window === 'undefined' || window.rcPilihCari || typeof HTMLSelectElement === 'undefined'
                    || typeof MutationObserver === 'undefined' || typeof document === 'undefined' || !document.querySelectorAll) return;
                const POLA = /camp|depot/i, KECUALI = /tahun|year|cbtype|jenis|status/i;
                const D_VALUE = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value');
                const D_INDEX = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'selectedIndex');
                const norm = s => String(s == null ? '' : s).toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/\s+/g, ' ').trim();
                const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
                let buka = null; // { sel, tombol, panel, cari, daftar, cocok, sorot }

                function layak(sel) {
                    return !sel.multiple && !sel._rcTombol && !sel.hasAttribute('data-rc-cari-tidak')
                        && POLA.test(sel.id || '') && !KECUALI.test(sel.id || '');
                }
                function teks(sel) { const o = sel.options[D_INDEX.get.call(sel)]; return o ? o.textContent.replace(/\s+/g, ' ').trim() : ''; }

                function perbarui(sel) {
                    const t = sel._rcTombol; if (!t) return;
                    const isi = teks(sel);
                    t.firstChild.textContent = isi || ' ';
                    t.title = isi;
                    t.disabled = sel.disabled;
                    t.style.display = sel.classList.contains('hidden') ? 'none' : '';
                    if (buka && buka.sel === sel) gambar(false);
                }

                function pasang(sel) {
                    const t = document.createElement('button');
                    t.type = 'button';
                    t.className = sel.className.replace(/(^|\s)hidden(?=\s|$)/g, ' ') + ' rc-pc-tombol'; // tampil / sembunyi mengikuti <select> lewat perbarui()
                    t.setAttribute('aria-haspopup', 'listbox');
                    t.innerHTML = '<span class="rc-pc-teks"></span><span class="rc-pc-panah" aria-hidden="true">▾</span>';
                    sel.insertAdjacentElement('afterend', t);
                    sel.classList.add('rc-pc-asli');
                    sel._rcTombol = t;
                    t.addEventListener('click', () => bukaPanel(sel));
                    t.addEventListener('keydown', e => { if (e.key === 'ArrowDown' || e.key === 'Enter' || e.key === ' ') { e.preventDefault(); bukaPanel(sel); } });
                    // Nilai yang disetel kode lewat .value / .selectedIndex ikut tampil di tombol.
                    Object.defineProperty(sel, 'value', { configurable: true,
                        get: function () { return D_VALUE.get.call(this); }, set: function (v) { D_VALUE.set.call(this, v); perbarui(this); } });
                    Object.defineProperty(sel, 'selectedIndex', { configurable: true,
                        get: function () { return D_INDEX.get.call(this); }, set: function (v) { D_INDEX.set.call(this, v); perbarui(this); } });
                    new MutationObserver(() => perbarui(sel)).observe(sel, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['disabled', 'class', 'selected'] });
                    sel.addEventListener('change', () => perbarui(sel));
                    perbarui(sel);
                }

                function bukaPanel(sel) {
                    if (sel.disabled) return;
                    const sama = buka && buka.sel === sel;
                    tutup();
                    if (sama) return;
                    const panel = document.createElement('div');
                    panel.className = 'rc-pc-panel';
                    panel.innerHTML = '<input type="search" class="rc-pc-cari" placeholder="Ketik untuk mencari..." autocomplete="off" spellcheck="false"><div class="rc-pc-daftar" role="listbox"></div>';
                    document.body.appendChild(panel);
                    buka = { sel, tombol: sel._rcTombol, panel, cari: panel.querySelector('.rc-pc-cari'), daftar: panel.querySelector('.rc-pc-daftar'), cocok: [], sorot: 0 };
                    // Klik di panel tidak boleh dianggap "klik di luar" oleh modal / dropdown lain.
                    ['mousedown', 'click'].forEach(n => panel.addEventListener(n, e => e.stopPropagation()));
                    buka.daftar.addEventListener('mousedown', e => e.preventDefault()); // fokus tetap di kotak cari
                    buka.daftar.addEventListener('click', e => { const el = e.target.closest('[data-i]'); if (el) pilih(Number(el.dataset.i)); });
                    buka.cari.addEventListener('input', () => gambar(true));
                    buka.cari.addEventListener('keydown', tombolCari);
                    letakkan(); gambar(true, true);
                    buka.cari.focus();
                }

                function letakkan() {
                    const r = buka.tombol.getBoundingClientRect(), p = buka.panel, lebarLayar = window.innerWidth;
                    if (r.bottom < 0 || r.top > window.innerHeight) { tutup(); return; }
                    p.style.width = Math.min(Math.max(r.width, 280), lebarLayar - 16) + 'px';
                    p.style.left = Math.max(8, Math.min(r.left, lebarLayar - p.offsetWidth - 8)) + 'px';
                    const bawah = window.innerHeight - r.bottom - 12, atas = r.top - 12;
                    if (bawah >= 240 || bawah >= atas) { p.style.top = (r.bottom + 4) + 'px'; p.style.bottom = ''; p.style.maxHeight = Math.min(380, bawah) + 'px'; }
                    else { p.style.top = ''; p.style.bottom = (window.innerHeight - r.top + 4) + 'px'; p.style.maxHeight = Math.min(380, atas) + 'px'; }
                }

                // Semua kata yang diketik harus ada (urutan bebas), pada teks atau nilai pilihan.
                function gambar(cariBaru, awal) {
                    const { sel, cari, daftar } = buka, kata = norm(cari.value).split(' ').filter(Boolean), aktif = D_INDEX.get.call(sel);
                    buka.cocok = Array.from(sel.options).map((o, i) => ({ o, i, t: norm(o.textContent + ' ' + o.value) }))
                        .filter(x => kata.every(k => x.t.includes(k)));
                    if (cariBaru) buka.sorot = awal ? Math.max(0, buka.cocok.findIndex(x => x.i === aktif)) : 0;
                    buka.sorot = Math.min(buka.sorot, Math.max(0, buka.cocok.length - 1));
                    daftar.innerHTML = buka.cocok.length
                        ? buka.cocok.map((x, k) => '<div role="option" data-i="' + x.i + '" class="rc-pc-opsi' + (x.i === aktif ? ' rc-pc-aktif' : '')
                            + (k === buka.sorot ? ' rc-pc-sorot' : '') + (x.o.disabled ? ' rc-pc-mati' : '') + '">' + (esc(x.o.textContent.trim()) || '&nbsp;') + '</div>').join('')
                        : '<div class="rc-pc-kosong">Tidak ada yang cocok</div>';
                    const s = daftar.querySelector('.rc-pc-sorot'); if (s) s.scrollIntoView({ block: 'nearest' });
                }

                function tombolCari(e) {
                    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                        e.preventDefault();
                        buka.sorot = Math.max(0, Math.min(buka.cocok.length - 1, buka.sorot + (e.key === 'ArrowDown' ? 1 : -1)));
                        gambar(false);
                    } else if (e.key === 'Enter') {
                        e.preventDefault();
                        if (buka.cocok[buka.sorot]) pilih(buka.cocok[buka.sorot].i);
                    } else if (e.key === 'Escape') {
                        e.preventDefault(); const t = buka.tombol; tutup(); t.focus();
                    } else if (e.key === 'Tab') tutup();
                }

                function pilih(i) {
                    const { sel, tombol } = buka, o = sel.options[i];
                    if (!o || o.disabled) return;
                    const berubah = D_INDEX.get.call(sel) !== i;
                    tutup();
                    sel.selectedIndex = i;
                    if (berubah) sel.dispatchEvent(new Event('change', { bubbles: true }));
                    tombol.focus();
                }

                function tutup() { if (buka) { buka.panel.remove(); buka = null; } }

                document.addEventListener('mousedown', e => { if (buka && !buka.panel.contains(e.target) && !buka.tombol.contains(e.target)) tutup(); }, true);
                window.addEventListener('resize', tutup);
                document.addEventListener('scroll', e => { if (buka && !buka.panel.contains(e.target)) letakkan(); }, true);

                // Pasang ke <select> yang sudah ada dan yang muncul kemudian (modul, modal, filter
                // yang dibuat lewat kode). Pemindaian ditunda sebentar supaya render tabel besar tidak
                // memicunya berkali-kali; tombol yang <select>-nya sudah hilang ikut dibuang.
                function pindai() {
                    document.querySelectorAll('select').forEach(sel => { if (layak(sel)) pasang(sel); });
                    document.querySelectorAll('.rc-pc-tombol').forEach(t => { const s = t.previousElementSibling; if (!s || s._rcTombol !== t) t.remove(); });
                }
                let jeda = 0;
                function mulai() {
                    pindai();
                    new MutationObserver(() => { if (!jeda) jeda = setTimeout(() => { jeda = 0; pindai(); }, 150); }).observe(document.body, { childList: true, subtree: true });
                }
                if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mulai); else mulai();
                window.rcPilihCari = { pindai, tutup };
            })();
