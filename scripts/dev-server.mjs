/*
 * Local development server for the Resource Collection frontend.
 *
 * The page cannot be opened as a file. `file://` is not a secure context, so
 * `crypto.subtle` is unavailable and the login address cannot be derived; module imports and
 * Supabase's session storage fail there too. This serves the same build over
 * http://localhost, which browsers do treat as a secure context.
 *
 * It sends the same security headers as vercel.json, so a Content-Security-Policy problem
 * shows up here rather than after a deployment. It rebuilds automatically whenever one of
 * the build inputs changes, so editing the legacy page, the adapter, the sign-up markup or
 * the environment file only needs a browser refresh.
 *
 * It binds to 127.0.0.1 only. This is an internal claim system, and browsers treat a LAN
 * address as insecure anyway, which would break the login form.
 *
 * Usage: node scripts/dev-server.mjs [--port 5173]
 */
import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { statSync } from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { BUILD_INPUTS, OUTPUT_DIR } from './build-rc-frontend.mjs';

const BUILD_SCRIPT = fileURLToPath(new URL('./build-rc-frontend.mjs', import.meta.url));

// Build dijalankan sebagai proses anak, bukan lewat import.
//
// Sebabnya nyata dan sempat menyesatkan: kalau build diimpor, logikanya ikut tersimpan di
// memori server. Mengubah markup modul lalu me-refresh browser akan membangun ulang dengan
// logika LAMA, dan diam-diam menimpa public/index.html dengan hasil yang usang. Halaman
// terlihat "tidak berubah" padahal kodenya sudah benar. Proses anak selalu membaca versi
// terbaru dari disk, sehingga tidak mungkin basi.
function buildFrontend() {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [BUILD_SCRIPT], { cwd: path.dirname(BUILD_SCRIPT) },
      (err, stdout, stderr) => {
        if (err) reject(new Error((stderr || stdout || err.message).trim()));
        else resolve(stdout.trim());
      });
  });
}

const args = process.argv.slice(2);
const portArg = args.indexOf('--port');
const PORT = Number(portArg >= 0 ? args[portArg + 1] : process.env.PORT || 5173);
const HOST = '127.0.0.1';

// CADANGAN SAJA. Header yang sebenarnya dibaca dari vercel.json di bawah - lihat
// bacaHeaderVercel(). Salinan di sini dulu menjadi satu-satunya sumber, dan justru karena ia
// salinan kedua ia menyimpang: host Supabase dev ditambahkan ke vercel.json tetapi tidak ke
// sini, sehingga login di localhost gagal diam-diam sementara situs yang ter-deploy berjalan.
// Kini ia hanya dipakai bila vercel.json tidak terbaca.
const SUPABASE_ORIGIN = 'https://vvojshgcduqlugngpzkj.supabase.co';
let SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), interest-cohort=()',
  'Content-Security-Policy': [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://cdn.tailwindcss.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com",
    "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com https://fonts.googleapis.com",
    "font-src 'self' data: https://cdnjs.cloudflare.com https://fonts.gstatic.com",
    // quickchart.io diperlukan oleh PRATINJAU email: diagramnya adalah <img> ke layanan itu.
    // Tanpa ini pratinjau menampilkan bingkai kosong, sementara email yang terkirim tetap
    // bergambar - mail client tidak memakai CSP halaman ini, jadi gejalanya hanya di layar.
    "img-src 'self' data: blob: https://quickchart.io",
    `connect-src 'self' ${SUPABASE_ORIGIN} ${SUPABASE_ORIGIN.replace('https://', 'wss://')} https://script.google.com https://script.googleusercontent.com`,
    "frame-ancestors 'none'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'"
  ].join('; ')
};

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2'
};

let lastBuilt = 0;

// Penjaga terhadap server yang sudah basi.
//
// Server yang dijalankan sebelum dev-server.mjs diubah tetap memakai kode lama di memori.
// Sebelumnya itu berakibat fatal dan senyap: server lama membangun ulang dengan logika
// usang lalu menimpa public/index.html, sehingga halaman terlihat "tidak berubah" padahal
// sumbernya sudah benar. Sekarang server memeriksa berkasnya sendiri dan berhenti dengan
// pesan jelas, bukan menyajikan hasil yang salah.
// vercel.json ikut diawasi karena rutenya dibaca sekali saat server dijalankan. Tanpa ini,
// mengganti sebuah alamat - misalnya /compilation menjadi /document-center - membuat server
// menyajikan rute LAMA sampai seseorang kebetulan menjalankannya ulang: alamat barunya 404 dan
// yang lama masih hidup, padahal berkasnya sudah benar. Keliru seperti itu memakan waktu lama
// untuk dilacak, karena yang dicurigai pertama selalu berkasnya.
const SELF_FILES = [fileURLToPath(import.meta.url), BUILD_SCRIPT,
  fileURLToPath(new URL('../vercel.json', import.meta.url))];
let selfStamp = 0;

async function newestSelf() {
  const times = await Promise.all(SELF_FILES.map(async (f) => {
    try { return (await stat(f)).mtimeMs; } catch { return 0; }
  }));
  return Math.max(...times);
}

async function newestInput() {
  const times = await Promise.all(BUILD_INPUTS.map(async (file) => {
    try { return (await stat(file)).mtimeMs; } catch { return 0; }
  }));
  return Math.max(...times);
}

async function rebuildIfStale() {
  const newest = await newestInput();
  if (newest <= lastBuilt) return null;
  const summary = await buildFrontend();
  lastBuilt = Date.now();
  return summary;
}

// ------------------------------------------------------------------------------------------
// Rute: cleanUrls dan rewrites dibaca dari vercel.json
// ------------------------------------------------------------------------------------------
// Setiap modul kini punya alamatnya sendiri - /report, /timetable, /dashboard/cost-center-1 -
// dan alamat itu bukan berkas, melainkan satu halaman yang memilih isinya dari pathname.
// Vercel mengerjakannya lewat "cleanUrls" dan "rewrites" pada vercel.json.
//
// Aturannya dibaca dari berkas yang sama, bukan disalin ke sini. Menyalinnya berarti suatu saat
// sebuah rute bekerja di localhost tetapi 404 setelah deploy - atau sebaliknya - dan selisih
// seperti itu baru ketahuan setelah orang lain yang menemukannya.
const VERCEL_JSON = fileURLToPath(new URL('../vercel.json', import.meta.url));
let rute = { cleanUrls: false, rewrites: [] };
try {
  const cfg = JSON.parse(await readFile(VERCEL_JSON, 'utf8'));
  rute = {
    cleanUrls: cfg.cleanUrls === true,
    rewrites: (cfg.rewrites || []).map((r) => ({
      // ":nama" pada Vercel mencocokkan satu ruas, ":nama*" mencocokkan sisa alamat.
      pola: new RegExp('^' + String(r.source)
        .replace(/[.+^${}()|[\]\\]/g, '\\$&')
        .replace(/:[A-Za-z0-9_]+\*/g, '.*')
        .replace(/:[A-Za-z0-9_]+/g, '[^/]+') + '$'),
      tujuan: String(r.destination || '')
    }))
  };
} catch (e) {
  console.error(`  vercel.json tidak terbaca (${e.message}); rute tambahan dimatikan.`);
}

// Header keamanan dibaca dari vercel.json, sama seperti rute di atas dan dengan alasan yang
// sama. Yang diambil adalah blok ber-source "/(.*)" - blok yang berlaku untuk setiap alamat.
// Header khusus per alamat (Cache-Control) tetap diatur di tempatnya masing-masing.
try {
  const cfg = JSON.parse(await readFile(VERCEL_JSON, 'utf8'));
  const blok = (cfg.headers || []).find((h) => h.source === '/(.*)');
  if (blok && Array.isArray(blok.headers) && blok.headers.length) {
    SECURITY_HEADERS = Object.fromEntries(blok.headers
      // HSTS dilewati: server ini berjalan di http://localhost. Peramban memang mengabaikan
      // HSTS dari koneksi tidak aman, tetapi mengirimnya tetap tidak ada gunanya dan salinan
      // lama pun sengaja tidak menyertakannya.
      .filter((h) => h.key !== 'Strict-Transport-Security')
      .map((h) => [h.key, h.value]));
  }
} catch (e) {
  console.error(`  header vercel.json tidak terbaca (${e.message}); memakai cadangan.`);
}

// Sebuah alamat diubah menjadi nama berkas di dalam public/. "/" dan tujuan rewrite yang
// berupa alamat bersih ("/", "/dashboard") ikut diselesaikan di sini, sehingga rewrite boleh
// menunjuk alamat - bukan berkas - persis seperti yang dituntut Vercel ketika cleanUrls aktif.
function berkasUntuk(alamat) {
  let relative = alamat.replace(/^\/+/, '');
  if (relative === '') relative = 'index.html';
  else if (rute.cleanUrls && !path.extname(relative)
           && adaBerkas(path.resolve(OUTPUT_DIR, relative + '.html'))) relative += '.html';
  return relative;
}

// Reject anything that escapes public/, so a crafted URL cannot read the repository.
function resolveRequest(urlPath) {
  const clean = decodeURIComponent(urlPath.split('?')[0]);
  let relative = berkasUntuk(clean);

  // Rewrite hanya berlaku bila tidak ada berkas dengan nama itu, sama seperti di Vercel.
  if (!adaBerkas(path.resolve(OUTPUT_DIR, relative))) {
    const cocok = rute.rewrites.find((r) => r.pola.test(clean));
    if (cocok) relative = berkasUntuk(cocok.tujuan);
  }

  const resolved = path.resolve(OUTPUT_DIR, relative);
  if (resolved !== OUTPUT_DIR && !resolved.startsWith(OUTPUT_DIR + path.sep)) return null;
  return resolved;
}

function adaBerkas(p) {
  if (p !== OUTPUT_DIR && !p.startsWith(OUTPUT_DIR + path.sep)) return false;
  try { return statSync(p).isFile(); } catch { return false; }
}


const server = http.createServer(async (req, res) => {
  const send = (code, body, headers = {}) => {
    res.writeHead(code, { ...SECURITY_HEADERS, ...headers });
    res.end(body);
  };

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return send(405, 'Method not allowed', { 'Content-Type': 'text/plain; charset=utf-8', Allow: 'GET, HEAD' });
  }

  if (await newestSelf() > selfStamp) {
    console.error('');
    console.error('  Kode dev server berubah sejak dijalankan. Berhenti supaya tidak');
    console.error('  menyajikan hasil build yang usang. Jalankan "npm run dev" lagi.');
    console.error('');
    res.writeHead(503, { ...SECURITY_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Dev server sudah usang. Jalankan "npm run dev" lagi.\n');
    setTimeout(() => process.exit(0), 100);
    return;
  }

  try {
    const summary = await rebuildIfStale();
    if (summary) console.log(`  ${summary}`);
  } catch (e) {
    console.error(`  build failed: ${e.message}`);
    return send(500, `Build failed:\n\n${e.message}\n`, { 'Content-Type': 'text/plain; charset=utf-8' });
  }

  let file = resolveRequest(req.url || '/');
  if (!file) return send(403, 'Forbidden', { 'Content-Type': 'text/plain; charset=utf-8' });

  // Ketika server dijalankan untuk sebuah lingkungan (RC_ENV_TARGET), config peramban
  // disajikan LANGSUNG dari sumbernya, bukan dari hasil build di public/.
  //
  // Sebabnya nyata dan sudah terjadi: build apa pun yang berjalan di jendela lain - termasuk
  // `npm test` - menimpa public/assets/rc-env.js dengan config produksi, dan server ini
  // menyajikan apa yang ada di sana. Akibatnya localhost yang dikira menunjuk dev diam-diam
  // berpindah ke database sungguhan, tanpa satu pun tanda di layar. Memeriksa sekali saat
  // start tidak cukup; yang menyelesaikan adalah tidak pernah membaca berkas yang bisa
  // ditimpa itu.
  if (process.env.RC_ENV_TARGET && file.endsWith(`assets${path.sep}rc-env.js`)) {
    const asal = fileURLToPath(
      new URL(`../config/rc-env.${process.env.RC_ENV_TARGET}.js`, import.meta.url));
    try { await readFile(asal); file = asal; }
    catch { /* berkasnya tidak ada; biarkan jatuh ke hasil build seperti biasa */ }
  }

  try {
    const body = await readFile(file);
    const ext = path.extname(file).toLowerCase();
    // index.html and rc-env.js carry the backend flag, so they are never cached, matching
    // the deployed configuration.
    const noStore = ext === '.html' || file.endsWith(`assets${path.sep}rc-env.js`);
    send(200, req.method === 'HEAD' ? '' : body, {
      'Content-Type': TYPES[ext] || 'application/octet-stream',
      'Cache-Control': noStore ? 'no-store, must-revalidate' : 'no-cache'
    });
  } catch {
    send(404, `Not found: ${req.url}\n`, { 'Content-Type': 'text/plain; charset=utf-8' });
  }
});

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use. Run with --port <other port>.`);
    process.exit(1);
  }
  throw e;
});

await buildFrontend();
lastBuilt = Date.now();
selfStamp = await newestSelf();

server.listen(PORT, HOST, () => {
  const env = process.env.RC_DATA_BACKEND;
  console.log(`\n  Resource Collection  ->  http://localhost:${PORT}\n`);
  console.log('  Serving public/ with the same headers as the Vercel deployment.');
  console.log('  Rebuilds automatically when the legacy page, adapter, sign-up markup or config changes.');
  console.log('  Open the localhost URL, not the file. file:// has no crypto.subtle and login cannot work there.');
  if (env) console.log(`  RC_DATA_BACKEND is set to ${env}, but the browser reads config/rc-env.js, not this variable.`);
  console.log('\n  Press Ctrl+C to stop.\n');
});
