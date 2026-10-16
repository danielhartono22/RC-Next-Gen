            // ============================================================================
            // CAMPAIGN MASTER: NOT PARTICIPATING PER DEPOT / REGION (20261162170000)
            // ============================================================================
            // Permintaan pemilik 9 Oktober 2026: depot atau seluruh depot dalam satu region yang
            // ditandai Not Participating tidak dapat meng-compile dokumen campaign itu di Document
            // Center, dan dihitung cleared seperti N/A di Timetable. Penjagaannya di server
            // (compile, trigger pada claims, Timetable); layar ini hanya mengatur daftarnya.
            //
            // Yang dikirim ke server adalah keadaan AKHIR untuk depot/region dalam jangkauan akun
            // ini. Tanda di luar jangkauannya tidak terlihat namanya dan tidak ikut terhapus.
            let npState = { kode: '', depots: [], regions: [] };

            async function bukaNotParticipating(kode) {
                showLoadingOverlay('Memuat Not Participating...');
                try {
                    const res = await fetchApp({ action: 'campaignNp', campaign: kode });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal memuat.', 'error'); return; }
                    npState = { kode: res.kode, depots: res.depots || [], regions: res.regions || [] };
                    document.getElementById('npJudul').innerText = res.kode + ' - ' + (res.nama || '');
                    document.getElementById('npCariDepot').value = '';
                    document.getElementById('npCatatan').value = '';
                    const info = [];
                    if (Number(res.tandaLain) > 0) info.push(res.tandaLain + ' tanda lain di luar jangkauan Anda tetap berlaku dan tidak ikut berubah.');
                    if (Number(res.dokumenAda) > 0) info.push(res.dokumenAda + ' dokumen campaign ini sudah ada pada depot yang ditandai; dokumen itu tetap diproses seperti biasa.');
                    document.getElementById('npInfo').innerText = info.join(' ');
                    npGambarRegion();
                    setHiddenSafely('npModal', false);
                } catch (e) { showNotification('Gagal memuat Not Participating.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

            function npTutup() { setHiddenSafely('npModal', true); }

            function npGambarRegion() {
                document.getElementById('npRegion').innerHTML = npState.regions.map(function (r, i) {
                    return '<label class="flex items-center gap-2 text-sm py-1' + (r.bolehUbah ? '' : ' opacity-50') + '"'
                        + (r.bolehUbah ? '' : ' title="Region ini memuat depot di luar jangkauan Anda"') + '>'
                        + '<input type="checkbox" class="rounded" data-i="' + i + '" onchange="npUbahRegion(this)"'
                        + (r.np ? ' checked' : '') + (r.bolehUbah ? '' : ' disabled') + '>'
                        + '<span class="font-bold">' + rcEsc(r.region) + '</span>'
                        + '<span class="text-[11px] text-gray-500">' + Number(r.jumlahDepot || 0) + ' depot</span></label>';
                }).join('') || '<p class="text-xs text-gray-400">Tidak ada region.</p>';
                npGambarDepot();
            }

            function npUbahRegion(el) { npState.regions[Number(el.dataset.i)].np = el.checked; npGambarDepot(); }
            function npUbahDepot(el) { npState.depots[Number(el.dataset.i)].np = el.checked; npRingkas(); }

            function npGambarDepot() {
                const cari = (document.getElementById('npCariDepot').value || '').trim().toLowerCase();
                const regionNp = new Set(npState.regions.filter(r => r.np).map(r => String(r.region).trim().toUpperCase()));
                document.getElementById('npDepot').innerHTML = npState.depots.map(function (d, i) {
                    if (cari && (d.kode + ' ' + d.nama).toLowerCase().indexOf(cari) < 0) return '';
                    const lewatRegion = regionNp.has(String(d.region || '').trim().toUpperCase());
                    return '<label class="flex items-center gap-2 text-xs py-1' + (d.bolehUbah ? '' : ' opacity-50') + '"'
                        + (d.bolehUbah ? '' : ' title="Depot di luar jangkauan Anda"') + '>'
                        + '<input type="checkbox" class="rounded" data-i="' + i + '" onchange="npUbahDepot(this)"'
                        + (d.np ? ' checked' : '') + (d.bolehUbah ? '' : ' disabled') + '>'
                        + '<span class="font-black">' + rcEsc(d.kode) + '</span>'
                        + '<span class="text-gray-600 truncate">' + rcEsc(d.nama) + '</span>'
                        + '<span class="text-[10px] text-gray-400">' + rcEsc(d.region || '-') + '</span>'
                        + (lewatRegion ? '<span class="text-[9px] font-black uppercase bg-gray-200 text-gray-600 px-1.5 rounded">NP via region</span>' : '')
                        + '</label>';
                }).join('') || '<p class="text-xs text-gray-400">Tidak ada depot.</p>';
                npRingkas();
            }

            function npRingkas() {
                const nr = npState.regions.filter(r => r.np).length;
                const nd = npState.depots.filter(d => d.np).length;
                document.getElementById('npRingkas').innerText = nr + ' region, ' + nd + ' depot ditandai';
            }

            async function npSimpan() {
                const regions = npState.regions.filter(r => r.np && r.bolehUbah).map(r => r.region);
                const depots = npState.depots.filter(d => d.np && d.bolehUbah).map(d => d.kode);
                const setuju = await showConfirmModal({
                    title: 'Simpan Not Participating',
                    message: 'Campaign ' + npState.kode + ': ' + regions.length + ' region dan ' + depots.length
                        + ' depot ditandai Not Participating. Compile baru untuk depot tersebut akan ditolak dan di Timetable dihitung cleared (N/A).'
                });
                if (!setuju) return;
                setDisabledSafely('btnNpSimpan', true);
                try {
                    const res = await fetchApp({
                        action: 'campaignNpSimpan', campaign: npState.kode, depots: depots, regions: regions,
                        catatan: document.getElementById('npCatatan').value.trim()
                    });
                    if (res.status !== 'success') { showNotification(res.message || 'Gagal menyimpan.', 'error'); return; }
                    showNotification(res.message || 'Tersimpan.', 'success');
                    logActivity('Not Participating campaign ' + npState.kode + ': ' + regions.length + ' region, ' + depots.length + ' depot');
                    npTutup();
                    loadCampaignMaster(rcMasterState.campaign ? rcMasterState.campaign.offset : 0);
                } catch (e) {
                    showNotification((e && e.message) ? e.message : 'Gagal menyimpan.', 'error');
                } finally { setDisabledSafely('btnNpSimpan', false); }
            }

            // Sel kolom Not Participating di tabel Campaign Master.
            function kolomNotParticipating(r) {
                const reg = r.npRegion || [], dep = r.npDepot || [], lain = Number(r.npDepotLain || 0);
                const bagian = [];
                if (reg.length) bagian.push(reg.length + ' region');
                if (dep.length + lain) bagian.push((dep.length + lain) + ' depot');
                const rinci = [reg.length ? 'Region: ' + reg.join(', ') : '', dep.length ? 'Depot: ' + dep.join(', ') : '',
                               lain ? lain + ' depot lain di luar jangkauan Anda' : ''].filter(Boolean).join(' | ');
                return '<button type="button" data-kode="' + rcEsc(r.codeCampaign) + '" onclick="bukaNotParticipating(this.dataset.kode)"'
                    + ' title="' + rcEsc(rinci || 'Atur depot/region yang tidak mengikuti campaign ini') + '"'
                    + ' class="px-2 py-1 rounded-lg text-[11px] font-bold border whitespace-nowrap '
                    + (bagian.length ? 'border-gray-400 bg-gray-100 text-gray-700 hover:bg-gray-200' : 'border-gray-200 text-gray-400 hover:bg-gray-50') + '">'
                    + rcEsc(bagian.length ? 'NP: ' + bagian.join(' · ') : 'Atur') + '</button>';
            }
