            // ============================================================================
            // TIMETABLE - TAB REPORT / DETAILS CAMPAIGN (20261163200000)
            // ============================================================================
            // Pemilik, 19 Oktober 2026: isi Timetable yang sudah ada menjadi tab "Report", dan tab
            // baru "Details Campaign" memuat data campaign langsung dari Key Master > Campaign Master.
            // Revisi pemilik (hari yang sama): tampilan pertama hanya kode, nama, status, Periode
            // Start (SO start), Periode End (SO end - semula Billing end, diubah pemilik 20 Oktober 2026),
            // dan memo PDF - lalu ditambah Jenis CB dan
            // Status Pajak (penafsiran status pajak yang sama di seluruh layar); klik baris membuka detail
            // hingga variant (Variant Name + Description untuk ZSQ04 / ZSOD / MCSI) beserta region /
            // depot yang berlaku atau di-exclude. Seluruh campaign tampil; yang tidak berlaku di depot
            // terpilih (Not Participating) ditandai merah. Tab ini hanya membaca.

            let rcTtTab = 'matrix';
            let rcTtcMuatKe = 0;

            function switchTimetableTab(tab) {
                if (!rcEnterTab('timetable', tab)) return;
                rcTtTab = tab;
                setHiddenSafely('ttPanelReport', tab !== 'matrix');
                setHiddenSafely('ttPanelCampaign', tab !== 'campaign');
                [['matrix', 'ttTabReport'], ['campaign', 'ttTabCampaign']].forEach(([t, id]) => {
                    const el = document.getElementById(id);
                    if (el) el.className = 'px-5 py-2 text-sm font-bold rounded-lg ' + (t === tab ? 'bg-amber-100 text-amber-700' : 'text-gray-500 hover:bg-gray-100');
                });
                if (tab === 'campaign') loadTimetableCampaigns();
                else {
                    loadTimetable();
                    // Grafik yang digambar saat panelnya tersembunyi berukuran nol; ukur ulang saat terlihat.
                    if (typeof rcUkurUlangGrafik === 'function') setTimeout(() => rcUkurUlangGrafik(document.getElementById('modTimetable')), 50);
                }
            }

            // Tombol kepala modul bekerja untuk tab yang sedang terbuka.
            function ttMuatUlang() { if (rcTtTab === 'campaign') loadTimetableCampaigns(); else loadTimetable(); }
            function ttUnduhExcel() { if (rcTtTab === 'campaign') unduhTimetableCampaignExcel(); else downloadTimetableExcel(); }

            async function loadTimetableCampaigns() {
                const ke = ++rcTtcMuatKe;
                showLoadingOverlay('Memuat Details Campaign...');
                try {
                    const r = await fetchApp({ action: 'timetableCampaigns' });
                    if (ke !== rcTtcMuatKe) return;
                    if (r.status !== 'success') throw new Error(r.message || 'Details Campaign gagal dimuat');
                    ttcIsiData(r); // src/view/js/30-details-campaign.js (20261163470000)
                    ttcSaring();
                } catch (e) {
                    if (ke !== rcTtcMuatKe) return;
                    document.getElementById('ttcBody').innerHTML = '<tr><td colspan="8" class="p-6 text-red-600">' + rcEsc(e.message) + '</td></tr>';
                    showNotification(e.message, 'error');
                } finally { hideLoadingOverlay(); }
            }

            async function bukaMemoTimetable(kode) {
                const r = rcTtcState.rows.find(x => x.kode === kode); if (!r || !r.memoPath) return;
                showLoadingOverlay('Membuka memo...');
                try {
                    const res = await fetchApp({ action: 'campaignMemoUrl', path: r.memoPath });
                    if (res.status !== 'success' || !res.url) { showNotification(res.message || 'Gagal membuka memo.', 'error'); return; }
                    window.open(res.url, '_blank', 'noopener');
                } catch (e) { showNotification('Gagal membuka memo.', 'error'); }
                finally { hideLoadingOverlay(); }
            }

