            // ============================================================================
            // KEY MASTER - DEPOT MASTER
            // ============================================================================
            // Region dan alamat email tujuan berada di sini, satu tempat dengan master depotnya
            // sendiri. Pada sistem lama alamat email ada di sheet terpisah dengan pemetaan kode
            // depot, sehingga menambah depot dan menambah penerimanya adalah dua pekerjaan yang
            // mudah tidak sinkron.

            let dmState = { offset: 0, limit: 50, total: 0, rows: [], bolehLangsung: false };
            let dmPending = null;

            async function loadDepotMaster(offset) {
                dmState.offset = Math.max(0, offset || 0);
                showLoadingOverlay();
                try {
                    const res = await fetchApp({
                        action: 'depotList',
                        search: document.getElementById('depotSearch').value.trim(),
                        offset: dmState.offset,
                        limit: dmState.limit
                    });
                    if (res.status !== 'success') throw new Error(res.message || 'Gagal memuat Depot Master.');
                    dmState.total = res.total || 0;
                    dmState.rows = res.rows || [];
                    // Server yang memutuskan apakah perubahan langsung tersimpan atau
                    // masuk antrean; layar hanya mengikuti, tidak menebak dari peran.
                    dmState.bolehLangsung = res.bolehLangsung === true;
                    renderDepotMaster();
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal memuat Depot Master.', 'error');
                } finally { hideLoadingOverlay(); }
            }

            function toggleSemuaDepot(src) {
                const nyala = src ? src.checked : false;
                document.querySelectorAll('.cb-depot').forEach(c => { c.checked = nyala; });
                updateDepotArsipCount();
            }
            function updateDepotArsipCount() {
                const n = document.querySelectorAll('.cb-depot:checked').length;
                setTextSafely('depotArsipCount', n);
                setDisabledSafely('btnArsipDepot', n === 0);
            }

            function renderDepotMaster() {
                document.getElementById('depotTableBody').innerHTML = dmState.rows.map(r => `
                    <tr class="border-b border-gray-100 hover:bg-emerald-50">
                        <td class="p-3 text-center"><input type="checkbox" class="cb-depot w-4 h-4 rounded" value="${rcEsc(r.kode)}" onchange="updateDepotArsipCount()"></td>
                        <td class="p-3 font-black text-gray-800 font-mono">${rcEsc(r.kode)}</td>
                        <td class="p-3 font-bold text-gray-700">${rcEsc(r.nama)}</td>
                        <td class="p-3 text-center font-mono">${rcEsc(r.abbr || '-')}</td>
                        <td class="p-3 text-center">${r.region ? rcEsc(r.region) : '<span class="text-orange-500 text-xs font-bold">belum diisi</span>'}</td>
                        <td class="p-3 text-xs ${r.jumlahTo ? 'text-gray-700' : 'text-orange-500 font-bold'}">${r.jumlahTo ? rcEsc(r.emailTo) : 'belum diisi'}</td>
                        <td class="p-3 text-xs text-gray-500">${r.jumlahCc ? rcEsc(r.emailCc) : '-'}</td>
                        <td class="p-3 text-center">
                            <button onclick="openDepotEditor('${rcEsc(r.kode)}')" class="bg-white hover:bg-emerald-50 text-emerald-700 font-bold border border-emerald-200 px-3 py-1.5 rounded-lg shadow-sm transition"><i class="fas fa-edit mr-1"></i>Ubah</button>
                        </td>
                    </tr>`).join('') || '<tr><td colspan="8" class="p-6 text-center text-gray-400">Tidak ada depot yang cocok.</td></tr>';

                const cbAllDepot = document.getElementById('cbDepotAll');
                if (cbAllDepot) cbAllDepot.checked = false;
                updateDepotArsipCount();

                const dari = dmState.total === 0 ? 0 : dmState.offset + 1;
                const sampai = Math.min(dmState.offset + dmState.limit, dmState.total);
                document.getElementById('depotPager').innerHTML = `
                    <div class="flex items-center justify-between text-sm">
                        <span class="text-gray-500">Menampilkan ${dari}-${sampai} dari ${dmState.total} depot</span>
                        <span class="flex gap-2">
                            <button onclick="loadDepotMaster(${Math.max(0, dmState.offset - dmState.limit)})" ${dmState.offset === 0 ? 'disabled' : ''} class="px-4 py-2 bg-white border border-gray-300 rounded-lg font-bold disabled:opacity-40">Sebelumnya</button>
                            <button onclick="loadDepotMaster(${dmState.offset + dmState.limit})" ${sampai >= dmState.total ? 'disabled' : ''} class="px-4 py-2 bg-white border border-gray-300 rounded-lg font-bold disabled:opacity-40">Berikutnya</button>
                        </span>
                    </div>`;
            }

            // Editor memuat seluruh isian depot dalam satu dialog. Bagian yang dihitung
            // sendiri - Region turunan kode depot, Tim Pengawas, dan akun terdaftar -
            // ditampilkan sebagai keterangan, bukan sebagai kolom isian, supaya tidak ada
            // yang mengetiknya lalu bingung mengapa ketikannya tidak tersimpan.
            function dmKolom(id, label, nilai, tipe, catatan) {
                return [
                    '<div><label class="block text-[10px] font-bold text-gray-500 uppercase mb-1">' + label + '</label>',
                    '<input id="' + id + '" type="' + (tipe || 'text') + '" value="' + rcEsc(nilai == null ? '' : String(nilai))
                        + '" class="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm">',
                    catatan ? '<p class="text-[10px] text-gray-400 mt-1">' + catatan + '</p>' : '',
                    '</div>'
                ].join('');
            }

            function openDepotEditor(kode) {
                const d = dmState.rows.find(x => x.kode === kode);
                if (!d) return;
                const langsung = dmState.bolehLangsung;

                const html = [
                    langsung
                        ? '<div class="mb-4 p-3 bg-green-50 border border-green-200 rounded-xl text-xs text-green-800">Perubahan Anda langsung tersimpan.</div>'
                        : '<div class="mb-4 p-3 bg-amber-50 border border-amber-200 rounded-xl text-xs text-amber-800">Perubahan Anda masuk antrean persetujuan di Access Management. Nilai lama tetap berlaku sampai disetujui Supervisor wilayah atau System Manager.</div>',

                    '<div class="p-3 bg-gray-50 border border-gray-200 rounded-xl text-xs text-gray-600 mb-4">',
                    '<b>Dihitung sendiri, tidak dapat diketik:</b><br>',
                    'Tim Pengawas: ' + rcEsc(d.timPengawas || '-') + '<br>',
                    'Akun terdaftar: ' + rcEsc(d.akunTerdaftar || '-') + '<br>',
                    'Total karyawan: ' + Number(d.karTotal || 0) + ' orang (jumlah dari rincian di bawah)',
                    (d.grade ? '<br>Grade: <b>' + rcEsc(d.grade) + '</b> (ditetapkan System Manager)' : ''),
                    '</div>',

                    '<div class="grid grid-cols-1 md:grid-cols-2 gap-3">',
                    '<div><label class="block text-[10px] font-bold text-gray-500 uppercase mb-1">Kode (kunci)</label>',
                    '<input readonly value="' + rcEsc(d.kode) + '" class="w-full px-3 py-2 border border-gray-200 rounded-lg bg-gray-50 font-mono text-sm"></div>',
                    dmKolom('dmNama', 'Nama Depot', d.nama),
                    dmKolom('dmAbbr', 'Abbr', d.abbr, 'text', '2-10 huruf atau angka; dipakai pada No Doc.'),
                    dmKolom('dmRegion', 'Region', d.region),
                    dmKolom('dmTipe', 'Tipe Depot', d.tipeDepot),
                    dmKolom('dmKepalaDepot', 'Kepala Depot', d.kepalaDepot),
                    dmKolom('dmKepalaAdmin', 'Kepala Admin', d.kepalaAdmin),
                    dmKolom('dmGmaps', 'Link Google Maps', d.gmapsUrl, 'url'),
                    '</div>',

                    '<div class="mt-3">' + dmKolom('dmAlamat', 'Alamat', d.alamat) + '</div>',
                    '<div class="mt-3">' + dmKolom('dmFoto', 'Foto Depot (URL gambar)', d.fotoUrl, 'url',
                        'Tempelkan tautan gambar. Pratinjaunya muncul di bawah bila tautannya dapat dibuka.') + '</div>',
                    (d.fotoUrl ? '<img src="' + rcEsc(d.fotoUrl) + '" alt="Foto depot" class="mt-2 rounded-xl border border-gray-200 max-h-40" onerror="this.style.display=\'none\'">' : ''),

                    '<h4 class="text-xs font-black text-gray-600 uppercase mt-5 mb-2">Jumlah Karyawan</h4>',
                    '<div class="grid grid-cols-2 md:grid-cols-4 gap-3">',
                    dmKolom('dmKarAdmin', 'Admin', d.karAdmin, 'number'),
                    dmKolom('dmKarSales', 'Sales', d.karSales, 'number'),
                    dmKolom('dmKarDriver', 'Driver', d.karDriver, 'number'),
                    dmKolom('dmKarFg', 'FG', d.karFg, 'number'),
                    dmKolom('dmKarPcc', 'PCC', d.karPcc, 'number'),
                    dmKolom('dmKarTeknisi', 'Teknisi', d.karTeknisi, 'number'),
                    dmKolom('dmKarLain', 'Lainnya', d.karLain, 'number'),
                    '</div>',

                    '<h4 class="text-xs font-black text-gray-600 uppercase mt-5 mb-2">Email</h4>',
                    '<div class="grid grid-cols-1 md:grid-cols-2 gap-3">',
                    dmKolom('dmEmailRsm', 'Email RSM', d.emailRsm, 'text', 'Maksimal 4 alamat, dipisah koma.'),
                    dmKolom('dmEmailAsm', 'Email ASM', d.emailAsm, 'text', 'Maksimal 4 alamat.'),
                    dmKolom('dmEmailSm', 'Email SM', d.emailSm, 'text', 'Maksimal 4 alamat.'),
                    dmKolom('dmEmailTo', 'Email Depot (TO)', d.emailTo, 'text', 'Maksimal 4 alamat. Inilah tujuan email otomatis.'),
                    '</div>',
                    '<div class="mt-3">' + dmKolom('dmEmailCc', 'Email CC', d.emailCc, 'text',
                        'Daftar siar, maksimal 20 alamat. Alamat yang sudah ada di TO akan DIHAPUS SENDIRI dari CC saat disimpan, '
                        + 'supaya tidak ada yang menerima email yang sama dua kali.') + '</div>',

                    '<button onclick="simpanDepotEditor(&#39;' + rcEsc(d.kode) + '&#39;)" class="w-full mt-5 py-2.5 bg-emerald-600 hover:bg-emerald-700 text-white font-bold rounded-xl">'
                        + (langsung ? 'Simpan' : 'Ajukan Perubahan') + '</button>'
                ].join('');

                rcDialog('Depot ' + d.kode + ' - ' + d.nama, html);
            }

            function dmAmbil(id) {
                const el = document.getElementById(id);
                return el ? el.value.trim() : '';
            }
            function dmAngka(id) { return Math.max(0, Number(dmAmbil(id) || 0)); }

            async function simpanDepotEditor(kode) {
                const data = {
                    nama: dmAmbil('dmNama'),
                    abbr: dmAmbil('dmAbbr').toUpperCase(),
                    region: dmAmbil('dmRegion'),
                    tipeDepot: dmAmbil('dmTipe'),
                    kepalaDepot: dmAmbil('dmKepalaDepot'),
                    kepalaAdmin: dmAmbil('dmKepalaAdmin'),
                    gmapsUrl: dmAmbil('dmGmaps'),
                    alamat: dmAmbil('dmAlamat'),
                    fotoUrl: dmAmbil('dmFoto'),
                    karAdmin: dmAngka('dmKarAdmin'), karSales: dmAngka('dmKarSales'),
                    karDriver: dmAngka('dmKarDriver'), karFg: dmAngka('dmKarFg'),
                    karPcc: dmAngka('dmKarPcc'), karTeknisi: dmAngka('dmKarTeknisi'),
                    karLain: dmAngka('dmKarLain'),
                    emailRsm: dmAmbil('dmEmailRsm'), emailAsm: dmAmbil('dmEmailAsm'),
                    emailSm: dmAmbil('dmEmailSm'), emailTo: dmAmbil('dmEmailTo'),
                    emailCc: dmAmbil('dmEmailCc')
                };
                try {
                    const res = await fetchApp({ action: 'depotSave', kode: kode, data: data });
                    if (res.status === 'success') {
                        showNotification(res.message || 'Tersimpan.', res.diajukan ? 'warning' : 'success');
                        logActivity((res.diajukan ? 'Mengajukan perubahan depot ' : 'Mengubah depot ') + kode);
                        rcTutupDialog();
                        loadDepotMaster(dmState.offset);
                    } else showNotification(res.message || 'Gagal menyimpan.', 'error');
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal menyimpan depot.', 'error');
                }
            }
            const DM_HEADER = ['Kode', 'Nama', 'Abbr', 'Region', 'Email TO', 'Email CC'];
            const DM_FIELD = ['kode', 'nama', 'abbr', 'region', 'emailTo', 'emailCc'];

            function downloadDepotTemplate() {
                // Template diisi dengan data yang ada sekarang, bukan baris kosong. Mengisi email
                // 51 depot dari nol jauh lebih berat daripada menyunting kolom pada daftar yang
                // sudah lengkap kodenya.
                const aoa = [DM_HEADER];
                (dmState.rows.length ? dmState.rows : []).forEach(r =>
                    aoa.push(DM_FIELD.map(f => r[f] || '')));
                if (aoa.length === 1) aoa.push(['4A', 'Medan', 'MDN', '4', 'admin.mdn@contoh.com', 'spv@contoh.com']);
                const ws = XLSX.utils.aoa_to_sheet(aoa);
                ws['!cols'] = [{ wch: 10 }, { wch: 26 }, { wch: 8 }, { wch: 10 }, { wch: 38 }, { wch: 38 }];
                const wb = XLSX.utils.book_new();
                XLSX.utils.book_append_sheet(wb, ws, 'Depot Master');
                XLSX.writeFile(wb, 'Template_Depot_Master.xlsx');
            }

            function previewDepotUpload(input) {
                const file = input.files && input.files[0];
                if (!file) return;
                const reader = new FileReader();
                reader.onload = (e) => {
                    try {
                        const wb = XLSX.read(new Uint8Array(e.target.result), { type: 'array' });
                        const rows = XLSX.utils.sheet_to_json(wb.Sheets[wb.SheetNames[0]], { header: 1, defval: '' });
                        if (rows.length < 2) { showNotification('Berkas tidak memuat baris data.', 'warning'); return; }

                        const header = rows[0].map(h => String(h || '').trim().toLowerCase());
                        const peta = {};
                        DM_HEADER.forEach((h, i) => {
                            const at = header.indexOf(h.toLowerCase());
                            if (at !== -1) peta[DM_FIELD[i]] = at;
                        });
                        if (peta.kode === undefined) {
                            showNotification('Kolom "Kode" tidak ditemukan pada berkas.', 'error'); return;
                        }

                        dmPending = rows.slice(1)
                            .filter(r => r.some(c => String(c || '').trim() !== ''))
                            .map(r => {
                                const o = {};
                                Object.keys(peta).forEach(f => { o[f] = rcCellText(r[peta[f]]); });
                                return o;
                            });

                        const tanpaEmail = dmPending.filter(r => !String(r.emailTo || '').trim()).length;
                        document.getElementById('depotUploadText').innerText =
                            `${dmPending.length} baris terbaca. ${dmPending.length - tanpaEmail} punya Email TO, ${tanpaEmail} kosong. `
                            + 'Kolom yang tidak ada di berkas dibiarkan seperti semula.';
                        setHiddenSafely('depotUploadInfo', false);
                    } catch (err) {
                        showNotification('Gagal membaca berkas Excel.', 'error');
                    }
                };
                reader.readAsArrayBuffer(file);
                input.value = '';
            }

            function cancelDepotUpload() {
                dmPending = null;
                setHiddenSafely('depotUploadInfo', true);
            }

            async function commitDepotUpload() {
                if (!dmPending || dmPending.length === 0) return;
                setDisabledSafely('btnCommitDepot', true);
                try {
                    const res = await fetchApp({ action: 'depotUpsert', rows: dmPending });
                    if (res.status === 'success') {
                        showNotification(res.message || 'Depot Master diperbarui.', Number(res.ditolak || 0) ? 'warning' : 'success');
                        if (Number(res.ditolak || 0) > 0) {
                            rcDialog('Baris yang ditolak',
                                '<ul class="list-disc pl-5 text-sm text-red-700">'
                                + (res.pesanDitolak || []).map(x => `<li>${rcEsc(x)}</li>`).join('')
                                + '</ul>');
                        }
                        logActivity('Unggah Depot Master: ' + dmPending.length + ' baris');
                        cancelDepotUpload();
                        loadDepotMaster(dmState.offset);
                    } else showNotification(res.message || 'Gagal menyimpan.', 'error');
                } catch (e) {
                    showNotification((e && e.message) || 'Gagal menyimpan Depot Master.', 'error');
                } finally { setDisabledSafely('btnCommitDepot', false); }
            }
