            // Excel menyimpan KTP, NPWP dan nomor rekening sebagai angka bila kolomnya
            // berformat General. Membacanya sebagai teks tampilan menghasilkan "3.17501E+15",
            // dan membacanya sebagai angka membuat digit ke-16 ke atas hilang presisinya.
            // Fungsi ini menulis seluruh digit tanpa notasi eksponen, lalu pemanggilnya
            // memperingatkan bila nilainya sudah melewati batas aman JavaScript.
            function rcCellText(v) {
                if (v === null || v === undefined) return '';
                if (typeof v === 'number') {
                    if (!isFinite(v)) return '';
                    return v.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                let s = String(v).trim();
                // Sel yang terlanjur berisi teks eksponen dikembalikan ke bentuk penuh.
                if (/^-?\d+(\.\d+)?[eE][+-]?\d+$/.test(s)) {
                    let n = Number(s);
                    if (isFinite(n)) return n.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                return s;
            }
            function rcPrecisionRisk(v) {
                return typeof v === 'number' && Math.abs(v) > Number.MAX_SAFE_INTEGER;
            }

            // ---------- Warna status: satu sumber untuk seluruh modul ----------
            // Sebelumnya tiap tabel memakai peta warnanya sendiri dan saling berbeda:
            // Bulk Process menandai Submitted kuning dan Claimed ungu, sementara History
            // menandai semua yang bukan Done dan bukan Not Yet dengan oranye. Warna yang
            // sama karena itu bisa berarti status yang berbeda tergantung layar.
            const RC_STATUS_CLASS = {
                'not yet':   'bg-gray-200 text-gray-700',
                'submitted': 'bg-orange-100 text-orange-800',
                'approved': 'bg-pink-100 text-pink-800',
                'bulk process': 'bg-fuchsia-100 text-fuchsia-800',
                'released':  'bg-yellow-100 text-yellow-800',
                'claimed':   'bg-blue-100 text-blue-800',
                'done':      'bg-green-100 text-green-800',
                'on hold':   'bg-purple-100 text-purple-800',
                'expired':   'bg-gray-800 text-white'
            };
            function rcStatusClass(status) {
                return RC_STATUS_CLASS[String(status || '').trim().toLowerCase()] || 'bg-gray-100 text-gray-700';
            }

            // Angka panjang seperti nomor batch (15 digit), KTP, NPWP dan nomor rekening
            // tidak boleh pernah tampil sebagai 1.0011E+14. Nilai apa pun dilewatkan ke sini
            // sebelum ditampilkan maupun sebelum ditulis ke Excel.
            function rcFull(v) {
                if (v === null || v === undefined) return '';
                if (typeof v === 'number') {
                    if (!isFinite(v)) return '';
                    return v.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                let s = String(v).trim();
                if (/^-?\d+(\.\d+)?[eE][+-]?\d+$/.test(s)) {
                    let n = Number(s);
                    if (isFinite(n)) return n.toLocaleString('fullwide', { useGrouping: false, maximumFractionDigits: 20 });
                }
                return s;
            }

            // ---------- Compile cashback ----------