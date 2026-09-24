/*
 * Membaca "tulang" sebuah halaman: id elemen dan nama fungsi tingkat atas.
 *
 * MENGAPA INI ADA
 * Sampai modularisasi, build menjaga UI dengan membuktikan markup identik byte per byte
 * terhadap berkas lama. Penjagaan itu tepat selama tugasnya hanya memindahkan backend, tetapi
 * ia menolak setiap perubahan tampilan - termasuk yang memang diminta pemilik. Menghapusnya
 * begitu saja akan meninggalkan halaman tanpa penjaga sama sekali, dan cara paling umum sebuah
 * halaman rusak diam-diam adalah kehilangan satu id yang masih dipanggil kode lain: tombolnya
 * tetap ada, klik-nya tidak melakukan apa-apa, dan tidak ada error yang muncul.
 *
 * Penggantinya adalah paritas struktural. Build boleh menambah apa pun, tetapi tidak boleh
 * menghilangkan id maupun fungsi yang pernah ada tanpa dinyatakan dengan sengaja. Jadi
 * perubahan tampilan berjalan bebas, sementara penghapusan tetap harus disadari.
 */

// getElementById('x'), getElementById("x"), dan atribut id="x" pada markup.
const ID_ATTR = /\sid=["']([A-Za-z0-9_:.-]+)["']/g;
const ID_CALL = /getElementById\(\s*['"]([A-Za-z0-9_:.-]+)['"]\s*\)/g;
// Deklarasi fungsi tingkat atas di dalam blok script halaman.
const FN_DECL = /^\s*(?:async\s+)?function\s+([A-Za-z0-9_$]+)\s*\(/gm;

function kumpulkan(teks, pola, grup = 1) {
  const hasil = new Set();
  pola.lastIndex = 0;
  let m;
  while ((m = pola.exec(teks)) !== null) hasil.add(m[grup]);
  return hasil;
}

export function bacaStruktur(html) {
  const ids = kumpulkan(html, ID_ATTR);
  const fungsi = kumpulkan(html, FN_DECL);
  // Id yang dipanggil kode tetapi tidak pernah ada di markup adalah masalah tersendiri;
  // dikumpulkan terpisah supaya bisa dilaporkan tanpa mencampuri paritas.
  const dipanggil = kumpulkan(html, ID_CALL);
  return {
    ids: [...ids].sort(),
    fungsi: [...fungsi].sort(),
    idDipanggilTanpaMarkup: [...dipanggil].filter((x) => !ids.has(x)).sort()
  };
}

/*
 * Membandingkan struktur hasil build dengan baseline.
 * `diizinkanHilang` adalah daftar yang memang sengaja dihapus; ia harus ditulis manusia,
 * sehingga penghapusan selalu menjadi keputusan, bukan kecelakaan.
 */
export function bandingkanStruktur(baseline, sekarang, diizinkanHilang = []) {
  const boleh = new Set(diizinkanHilang);
  const hilangId = baseline.ids.filter((x) => !sekarang.ids.includes(x) && !boleh.has(x));
  const hilangFungsi = baseline.fungsi.filter((x) => !sekarang.fungsi.includes(x) && !boleh.has(x));
  // Yang sengaja dihapus tetapi ternyata masih ada: daftarnya sudah usang dan menyesatkan.
  const izinBasi = [...boleh].filter(
    (x) => sekarang.ids.includes(x) || sekarang.fungsi.includes(x));
  return {
    hilangId,
    hilangFungsi,
    izinBasi,
    tambahId: sekarang.ids.filter((x) => !baseline.ids.includes(x)),
    tambahFungsi: sekarang.fungsi.filter((x) => !baseline.fungsi.includes(x)),
    lolos: hilangId.length === 0 && hilangFungsi.length === 0
  };
}
