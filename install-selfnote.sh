#!/bin/bash
set -e

INSTALL_DIR="/opt/selfnote"
DATA_DIR="/opt/lxd-data/note"
PORT=3342
TAILSCALE_PORT=3342

echo "🔧 SelfNote v23 (patched) インストール開始..."

if ! command -v node &>/dev/null; then
  echo "📦 Node.js インストール中..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

echo "Node.js: $(node -v)"

mkdir -p "$INSTALL_DIR/public"
mkdir -p "$DATA_DIR"

if ! touch "$DATA_DIR/.write-test" 2>/dev/null; then
  echo "❌ $DATA_DIR への書き込みに失敗しました (権限/UID squashing等の可能性)。インストールを中止します。"
  exit 1
fi
rm -f "$DATA_DIR/.write-test"

systemctl stop selfnote 2>/dev/null || true

cat > "$INSTALL_DIR/public/favicon.svg" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <rect x="4" y="2" width="24" height="28" rx="3" fill="#2563eb" opacity="0.12"/>
  <rect x="4" y="2" width="24" height="28" rx="3" fill="none" stroke="#2563eb" stroke-width="1.5"/>
  <line x1="9" y1="9" x2="23" y2="9" stroke="#2563eb" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="9" y1="14" x2="20" y2="14" stroke="#2563eb" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="9" y1="19" x2="17" y2="19" stroke="#2563eb" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="9" y1="24" x2="22" y2="24" stroke="#2563eb" stroke-width="1.5" stroke-linecap="round"/>
</svg>
SVGEOF

cat > "$INSTALL_DIR/server.js" <<'SERVEREOF'
const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { URL } = require('url');

const PORT = 3342;
const HOST = '127.0.0.1';
const DATA = '/opt/lxd-data/note';
const PUB = path.join(__dirname, 'public');
const FAVORITES_FILE = path.join(DATA, '.favorites.json');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.gif': 'image/gif',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
};

function json(res, code, data) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(data));
}

function safe(p) {
  const real = path.resolve(p);
  return real.startsWith(DATA) || real.startsWith(PUB);
}

function readBody(req) {
  return new Promise(r => {
    const c = [];
    req.on('data', d => c.push(d));
    req.on('end', () => r(Buffer.concat(c).toString()));
  });
}

const dirCache = new Map();
const CACHE_TTL = 2000;

async function listDir(dir) {
  const cached = dirCache.get(dir);
  if (cached && Date.now() - cached.ts < CACHE_TTL) return cached.items;
  try {
    const entries = await fsp.readdir(dir, { withFileTypes: true });
    const items = await Promise.all(entries.map(async d => {
      try {
        const st = await fsp.stat(path.join(dir, d.name));
        return { name: d.name, isDir: d.isDirectory(), birthtime: st.birthtimeMs || 0 };
      } catch { return { name: d.name, isDir: d.isDirectory(), birthtime: 0 }; }
    }));
    items.sort((a, b) => a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name));
    dirCache.set(dir, { items, ts: Date.now() });
    return items;
  } catch { return []; }
}

function invalidateCache() { dirCache.clear(); }

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pn = decodeURIComponent(url.pathname);

  if (pn === '/api/files' && req.method === 'GET')
    return json(res, 200, await listDir(DATA));

  if (pn.startsWith('/api/files/') && req.method === 'GET') {
    const rel = pn.slice(11), fp = path.join(DATA, rel);
    if (!safe(fp)) return json(res, 403, { error: 'denied' });
    if (!fs.existsSync(fp)) return json(res, 404, { error: 'not found' });
    if (fs.statSync(fp).isDirectory()) return json(res, 200, await listDir(fp));
    return json(res, 200, { content: await fsp.readFile(fp, 'utf-8'), path: rel });
  }

  if (pn === '/api/files' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const fp = path.join(b.parent || '', b.name);
    const full = path.join(DATA, fp);
    if (!safe(full)) return json(res, 403, { error: 'denied' });
    if (fs.existsSync(full)) return json(res, 409, { error: 'exists' });
    if (b.isDir) fs.mkdirSync(full, { recursive: true });
    else { fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, ''); }
    invalidateCache();
    return json(res, 200, { ok: true, path: fp });
  }

  if (pn.startsWith('/api/files/') && req.method === 'PUT') {
    const fp = pn.slice(11), full = path.join(DATA, fp);
    if (!safe(full)) return json(res, 403, { error: 'denied' });
    fs.mkdirSync(path.dirname(full), { recursive: true });
    const body = JSON.parse(await readBody(req));
    fs.writeFileSync(full, body.content || '', 'utf-8');
    invalidateCache();
    return json(res, 200, { ok: true });
  }

  if (pn.startsWith('/api/files/') && req.method === 'DELETE') {
    const fp = pn.slice(11), full = path.join(DATA, fp);
    if (!safe(full)) return json(res, 403, { error: 'denied' });
    if (!fs.existsSync(full)) return json(res, 404, { error: 'not found' });
    fs.rmSync(full, { recursive: true });
    invalidateCache();
    return json(res, 200, { ok: true });
  }

  if (pn === '/api/rename' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const o = path.join(DATA, b.old), n = path.join(path.dirname(o), b.newName);
    if (!safe(o) || !safe(n)) return json(res, 403, { error: 'denied' });
    if (fs.existsSync(n)) return json(res, 409, { error: 'exists' });
    fs.renameSync(o, n);
    invalidateCache();
    return json(res, 200, { ok: true, path: path.relative(DATA, n) });
  }

  if (pn === '/api/move' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const src = path.join(DATA, b.from);
    if (!safe(src) || !fs.existsSync(src)) return json(res, 404, { error: 'not found' });
    const dest = path.join(DATA, b.to, path.basename(b.from));
    if (!safe(dest)) return json(res, 403, { error: 'denied' });
    if (fs.existsSync(dest)) return json(res, 409, { error: 'exists' });
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.renameSync(src, dest);
    invalidateCache();
    return json(res, 200, { ok: true, path: path.relative(DATA, dest) });
  }

  if (pn === '/api/favorites' && req.method === 'GET') {
    try {
      const data = fs.readFileSync(FAVORITES_FILE, 'utf-8');
      return json(res, 200, JSON.parse(data));
    } catch { return json(res, 200, []); }
  }

  if (pn === '/api/favorites' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    fs.writeFileSync(FAVORITES_FILE, JSON.stringify(b.favorites || [], null, 2), 'utf-8');
    return json(res, 200, { ok: true });
  }

  if (pn === '/api/search' && req.method === 'POST') {
    const b = JSON.parse(await readBody(req));
    const q = (b.query || '').toLowerCase();
    if (!q) return json(res, 200, []);
    const results = [];
    async function searchDir(dir, base) {
      try {
        for (const f of await fsp.readdir(dir, { withFileTypes: true })) {
          const fp = path.join(dir, f.name);
          const rel = base ? base + '/' + f.name : f.name;
          if (f.isDirectory()) { await searchDir(fp, rel); continue; }
          if (!f.name.endsWith('.md')) continue;
          try {
            const content = await fsp.readFile(fp, 'utf-8');
            const lines = content.split('\n');
            for (let i = 0; i < lines.length; i++) {
              if (lines[i].toLowerCase().includes(q)) {
                results.push({ file: rel, line: i + 1, text: lines[i].trim() });
                break;
              }
            }
          } catch {}
        }
      } catch {}
    }
    await searchDir(DATA, '');
    return json(res, 200, results);
  }

  let fp = pn === '/' ? '/index.html' : pn;
  fp = path.join(PUB, fp);
  if (!fs.existsSync(fp) || fs.statSync(fp).isDirectory()) fp = path.join(PUB, 'index.html');
  try {
    const data = fs.readFileSync(fp);
    res.writeHead(200, { 'Content-Type': MIME[path.extname(fp)] || 'application/octet-stream' });
    res.end(data);
  } catch { res.writeHead(404); res.end('Not found'); }
});

server.on('error', (err) => {
  console.error('Server error:', err.code, err.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => console.log('SelfNote: http://' + HOST + ':' + PORT));
SERVEREOF

cat > "$INSTALL_DIR/package.json" <<'PKGEOF'
{
  "name": "selfnote",
  "version": "23.0.1",
  "main": "server.js",
  "scripts": { "start": "node server.js" }
}
PKGEOF

cat > "$INSTALL_DIR/public/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SelfNote</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#ffffff;--bg2:#f7f7f8;--sf:#f0f0f0;--tx:#1a1a1a;--tx2:#616161;--ac:#2563eb;--bd:#e5e5e5;--ok:#16a34a;--er:#dc2626;--radius:8px}
body.dark{--bg:#1a1a1a;--bg2:#242424;--sf:#2d2d2d;--tx:#e0e0e0;--tx2:#999;--ac:#5b9cf5;--bd:#3a3a3a;--ok:#4ade80;--er:#f87171;--radius:8px}
html,body{height:100%;overflow:hidden}
body{font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--tx)}
#app{display:flex;height:100vh}
#sb{width:240px;background:var(--bg2);border-right:1px solid var(--bd);display:flex;flex-direction:column;flex-shrink:0}
#sb.hide{width:0;overflow:hidden;border:none}
.sb-hd{display:flex;align-items:center;justify-content:space-between;padding:9px 12px;border-bottom:1px solid var(--bd);font-size:15px;font-weight:600}
.sb-hd span{color:var(--ac)}
.sb-act{padding:8px 10px;display:flex;gap:6px;border-bottom:1px solid var(--bd)}
.sb-act button{flex:1;padding:6px;background:var(--sf);color:var(--tx);border:none;border-radius:var(--radius);cursor:pointer;font-size:13px;transition:background .1s}
.sb-act button:first-child{border:1px solid var(--ac);color:var(--ac);font-weight:600}
.sb-act button:hover{opacity:.8}
.sb-sort{display:flex;gap:4px;padding:6px 10px;border-bottom:1px solid var(--bd)}
.sort-btn{flex:1;padding:4px 8px;background:var(--bg2);color:var(--tx2);border:1px solid var(--bd);border-radius:var(--radius);cursor:pointer;font-size:12px;white-space:nowrap;transition:background .1s}
.sort-btn:hover{background:var(--sf)}
.sort-btn.on{color:var(--ac);border-color:var(--ac)}
#ft{flex:1;overflow-y:auto;padding:6px}
.fi{display:flex;align-items:center;padding:4px 10px;border-radius:var(--radius);cursor:pointer;font-size:15px;gap:6px;user-select:none;white-space:nowrap;transition:background .1s}
.fi .fi-name{flex:1;overflow:hidden;text-overflow:ellipsis}
.fi-rename{opacity:0;font-size:12px;padding:2px 6px;border-radius:var(--radius);flex-shrink:0;cursor:pointer}
.fi:hover .fi-rename{opacity:.6}
.fi-rename:hover{opacity:1!important;background:var(--bd)}
.fi.on .fi-rename{color:var(--bg)}
.fi-fav{opacity:0;font-size:12px;padding:2px 6px;border-radius:var(--radius);flex-shrink:0;cursor:pointer;color:var(--tx2)}
.fi:hover .fi-fav{opacity:.6}
.fi-fav:hover{opacity:1!important}
.fi-fav.on{opacity:1;color:#e0a33e}
.fi-sep{border-top:1px solid var(--bd);margin:6px 10px}
.fi-favpath{font-size:12px;color:var(--tx2);overflow:hidden;text-overflow:ellipsis}
.fi:hover{background:var(--sf)}
.fi.drag-over{outline:2px dashed var(--ac);outline-offset:-2px;background:var(--sf)}
.fi.on{background:var(--ac);color:var(--bg)}
.fi .ico{width:18px;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.fi .ico svg{width:16px;height:16px;flex-shrink:0}
.fi .ico-tree{font-size:9px;width:12px;text-align:center;flex-shrink:0;color:var(--tx2);cursor:pointer;transition:transform .15s;user-select:none}
.fi .ico-tree.open{transform:rotate(90deg)}
.fi:hover .ico-tree{color:var(--tx)}
#mn{flex:1;display:flex;flex-direction:column;overflow:hidden}
#tb{display:flex;align-items:center;padding:4px 8px;background:var(--bg2);border-bottom:1px solid var(--bd);gap:2px;flex-shrink:0;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none}
#tb::-webkit-scrollbar{display:none}
.tg{display:flex;gap:2px}
.td{width:1px;align-self:stretch;background:var(--bd);margin:4px 4px}
.bt{background:none;border:none;color:var(--tx2);cursor:pointer;padding:5px 8px;border-radius:var(--radius);font-size:13px;display:flex;align-items:center;justify-content:center;min-width:28px;height:28px;transition:background .1s}
.bt svg{width:16px;height:16px;stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex-shrink:0}
.bt:hover{background:var(--sf);color:var(--tx)}
.bt.on{background:var(--ac);color:var(--bg)}
.bt:disabled{opacity:.35;cursor:default}
.bt:disabled:hover{background:none;color:var(--tx2)}
#fn{font-size:13px;color:var(--tx2);margin:0 8px;max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sp{flex:1}
#ec{flex:1;display:flex;overflow:hidden}
#toc{width:0;overflow:hidden;background:var(--bg2);border-right:1px solid var(--bd);flex-shrink:0;transition:width .15s;display:flex;flex-direction:column}
#toc.open{width:200px}
.toc-hd{padding:10px 12px;border-bottom:1px solid var(--bd);font-size:13px;font-weight:600;color:var(--ac);display:flex;align-items:center;justify-content:space-between}
.toc-hd span{cursor:pointer;font-size:11px;color:var(--tx2)}
.toc-hd span:hover{color:var(--tx)}
#toc-list{flex:1;overflow-y:auto;padding:4px 0}
.toc-item{padding:5px 12px;cursor:pointer;font-size:13px;color:var(--tx2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;border-radius:var(--radius);margin:1px 4px;transition:background .1s}
.toc-item:hover{background:var(--sf);color:var(--tx)}
.toc-item.l1{font-weight:600;color:var(--tx)}
.toc-item.l2{padding-left:20px}
.toc-item.l3{padding-left:30px;font-size:12px}
.ep{flex:1;display:flex;flex-direction:column;overflow:hidden}
.ep.hide{display:none}
#ed{flex:1;width:100%;padding:12px 18px;background:var(--bg);color:var(--tx);border:none;outline:none;resize:none;overflow-y:auto;font-family:'Menlo','Consolas','Courier New',monospace;font-size:13px;line-height:1.4;tab-size:2}
#pv{flex:1;padding:14px 22px;overflow-y:auto;font-size:15px;line-height:1.5;border-left:1px solid var(--bd)}
#il{flex:1;padding:14px 22px;overflow-y:auto;font-size:15px;line-height:1.5;outline:none;border-left:1px solid var(--bd)}
#pv h1,#il h1{font-size:1.8em;margin:.5em 0 .3em;border-bottom:1px solid var(--bd);padding-bottom:.25em}
#pv h2,#il h2{font-size:1.4em;margin:.5em 0 .25em;border-bottom:1px solid var(--bd);padding-bottom:.2em}
#pv h3,#il h3{font-size:1.2em;margin:.5em 0 .2em}
#pv p,#il p{margin:.5em 0}
#pv a,#il a{color:var(--ac);text-decoration:underline;cursor:pointer}
#pv ul,#pv ol,#il ul,#il ol{padding-left:1.8em;margin:.5em 0}
#pv li,#il li{margin:.2em 0}
#pv blockquote,#il blockquote{border-left:3px solid var(--ac);padding-left:1em;margin:.5em 0;color:var(--tx2)}
#pv code,#il code{background:var(--sf);padding:2px 6px;border-radius:var(--radius);font-family:'Menlo','Consolas','Courier New',monospace;font-size:.88em}
#pv pre,#il pre{background:var(--sf);padding:12px 16px;border-radius:var(--radius);overflow-x:auto;margin:.5em 0;position:relative;min-height:1.5em}
#pv pre code,#il pre code{background:none;padding:0;white-space:pre;display:block}
.cp-btn{position:absolute;top:6px;right:6px;background:var(--bd);color:var(--tx2);border:none;border-radius:var(--radius);padding:3px 10px;font-size:11px;cursor:pointer;opacity:0;transition:opacity .15s}
pre:hover .cp-btn{opacity:1}
.cp-btn:hover{background:var(--ac);color:var(--bg)}
#pv hr,#il hr{border:none;border-top:1px solid var(--bd);margin:1em 0}
#pv img,#il img{max-width:100%;border-radius:var(--radius)}
#pv table,#il table{border-collapse:collapse;width:100%;margin:.5em 0}
#pv th,#pv td,#il th,#il td{border:1px solid var(--bd);padding:8px 12px;text-align:left}
#pv th,#il th{background:var(--sf);font-weight:600}
#pv input[type=checkbox],#il input[type=checkbox]{margin-right:5px}
#modal{position:fixed;inset:0;background:rgba(0,0,0,.5);display:flex;align-items:center;justify-content:center;z-index:100}
#modal.hide{display:none}
#modal .box{background:var(--bg2);padding:20px;border-radius:10px;min-width:300px;border:1px solid var(--bd);box-shadow:0 8px 32px rgba(0,0,0,.2)}
#modal h3{margin-bottom:12px;font-size:14px;font-weight:600}
.modal-row{display:flex;gap:6px;align-items:center;margin-bottom:14px}
.modal-row input{flex:1;padding:8px 12px;background:var(--sf);color:var(--tx);border:1px solid var(--bd);border-radius:var(--radius);font-size:13px;outline:none;transition:border-color .15s}
.modal-row input:focus{border-color:var(--ac)}
.date-btn{padding:8px 12px;background:var(--sf);color:var(--ac);border:1px solid var(--bd);border-radius:var(--radius);cursor:pointer;font-size:12px;white-space:nowrap;transition:background .1s}
.date-btn:hover{background:var(--bd)}
#modal .ma{display:flex;justify-content:flex-end;gap:8px}
#modal .ma button{padding:6px 14px;border:none;border-radius:var(--radius);cursor:pointer;font-size:13px;transition:background .1s}
.mb{background:var(--sf);color:var(--tx)}
.mb:hover{opacity:.8}
.mp{background:var(--ac);color:var(--bg)}
.mp:hover{opacity:.9}
#toast{position:fixed;bottom:16px;right:16px;padding:10px 16px;background:var(--sf);color:var(--tx);border-radius:var(--radius);font-size:13px;z-index:101;border:1px solid var(--bd);box-shadow:0 4px 12px rgba(0,0,0,.15)}
#toast.hide{display:none}
.sr-wrap{padding:8px;border-top:1px solid var(--bd)}
.sr-row{display:flex;gap:4px}
.sr-input{flex:1;padding:6px 10px;background:var(--sf);color:var(--tx);border:1px solid var(--bd);border-radius:var(--radius);font-size:12px;outline:none;transition:border-color .15s}
.sr-input:focus{border-color:var(--ac)}
.sr-btn{padding:6px 12px;background:var(--sf);color:var(--ac);border:1px solid var(--bd);border-radius:var(--radius);cursor:pointer;font-size:12px;transition:background .1s}
.sr-btn:hover{background:var(--bd)}
#sr{max-height:140px;overflow-y:auto;padding:4px 0}
.sr-item{padding:5px 10px;font-size:12px;cursor:pointer;border-radius:var(--radius);display:flex;gap:6px;transition:background .1s}
.sr-item:hover{background:var(--sf)}
.sr-file{color:var(--ac);white-space:nowrap}
.sr-line{color:var(--tx2);flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
::-webkit-scrollbar{width:6px;height:6px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:var(--bd);border-radius:3px}
::-webkit-scrollbar-thumb:hover{background:var(--tx2)}
@keyframes blink-save{0%,100%{opacity:1}50%{opacity:.2}}
.bt.dirty{animation:blink-save 1s ease-in-out infinite;color:var(--er)}
</style>
</head>
<body>
<div id="app">
  <div id="sb">
    <div class="sb-hd"><span>SelfNote</span></div>
    <div class="sb-act"><button onclick="newItem(false)"><svg viewBox="0 0 24 24" width="14" height="14" style="stroke:currentColor;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;vertical-align:-2px"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="12" y1="18" x2="12" y2="12"/><line x1="9" y1="15" x2="15" y2="15"/></svg> 新規</button><button onclick="newItem(true)"><svg viewBox="0 0 24 24" width="14" height="14" style="stroke:#e8b430;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;vertical-align:-2px"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/><line x1="12" y1="11" x2="12" y2="17"/><line x1="9" y1="14" x2="15" y2="14"/></svg> 新規</button></div>
    <div class="sb-sort">
      <button class="sort-btn on" id="sort-name" onclick="toggleSort('name')">ファイル名 ▲</button>
      <button class="sort-btn" id="sort-date" onclick="toggleSort('date')">作成日 ▲</button>
    </div>
    <div id="ft"></div>
    <div class="sr-wrap">
      <div class="sr-row">
        <input class="sr-input" id="sq" placeholder="全文検索...">
        <button class="sr-btn" onclick="doSearch()">検索</button>
      </div>
      <div id="sr"></div>
    </div>
  </div>
  <div id="mn">
    <div id="tb">
      <div class="tg">
        <button class="bt" id="saveBtn" onclick="save()" title="Ctrl+S"><svg viewBox="0 0 24 24"><path d="M19 21H5a2 2 0 01-2-2V5a2 2 0 012-2h11l5 5v11a2 2 0 01-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></svg></button>
        <button class="bt" onclick="toggleSb()" title="サイドバー表示切替"><svg viewBox="0 0 24 24"><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="18" x2="21" y2="18"/></svg></button>
      </div><div class="td"></div>
      <div class="tg">
        <button class="bt fmt-bt" onclick="ins('heading',1)"><b>H1</b></button>
        <button class="bt fmt-bt" onclick="ins('heading',2)"><b>H2</b></button>
        <button class="bt fmt-bt" onclick="ins('heading',3)"><b>H3</b></button>
      </div><div class="td"></div>
      <div class="tg">
        <button class="bt fmt-bt" onclick="ins('bold')" title="Ctrl+B"><b>B</b></button>
        <button class="bt fmt-bt" onclick="ins('italic')" title="Ctrl+I"><i>I</i></button>
        <button class="bt fmt-bt" onclick="ins('strike')"><s>S</s></button>
      </div><div class="td"></div>
      <div class="tg">
        <button class="bt fmt-bt" onclick="ins('ul')"><svg viewBox="0 0 24 24"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg></button>
        <button class="bt fmt-bt" onclick="ins('ol')">1.</button>
        <button class="bt fmt-bt" onclick="ins('check')"><svg viewBox="0 0 24 24"><polyline points="9 11 12 14 22 4"/><path d="M21 12v7a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2h11"/></svg></button>
      </div><div class="td"></div>
      <div class="tg">
        <button class="bt fmt-bt" onclick="ins('link')"><svg viewBox="0 0 24 24"><path d="M10 13a5 5 0 007.54.54l3-3a5 5 0 00-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 00-7.54-.54l-3 3a5 5 0 007.07 7.07l1.71-1.71"/></svg></button>
        <button class="bt fmt-bt" onclick="ins('image')"><svg viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg></button>
        <button class="bt fmt-bt" onclick="ins('code')">{ }</button>
        <button class="bt fmt-bt" onclick="ins('codeblock')"><svg viewBox="0 0 24 24"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg></button>
        <button class="bt fmt-bt" onclick="ins('quote')"><svg viewBox="0 0 24 24"><path d="M3 21c3 0 7-1 7-8V5c0-1.25-.756-2.017-2-2H4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2 1 0 1 0 1 1v1c0 1-1 2-2 2s-1 .008-1 1.031V21z"/><path d="M15 21c3 0 7-1 7-8V5c0-1.25-.757-2.017-2-2h-4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2h.75c0 2.25.25 4-2.75 4v3c0 1 0 1 1 1z"/></svg></button>
        <button class="bt fmt-bt" onclick="ins('hr')"><svg viewBox="0 0 24 24"><line x1="5" y1="12" x2="19" y2="12"/></svg></button>
      </div><div class="td"></div>
      <div class="tg">
        <button class="bt on" id="vm-edit" onclick="setView('edit')" title="ソース"><svg viewBox="0 0 24 24"><path d="M11 4H4a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z"/></svg></button>
        <button class="bt" id="vm-split" onclick="setView('split')" title="分割"><svg viewBox="0 0 24 24"><rect x="3" y="3" width="18" height="18" rx="2"/><line x1="12" y1="3" x2="12" y2="21"/></svg></button>
        <button class="bt" id="vm-preview" onclick="setView('preview')" title="プレビュー"><svg viewBox="0 0 24 24"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg></button>
        <button class="bt" id="vm-inline" onclick="setView('inline')" title="インライン＋ソース"><svg viewBox="0 0 24 24"><path d="M11 4H4a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 013 3L12 15l-4 1 1-4 9.5-9.5z"/></svg><svg viewBox="0 0 24 24" style="margin-left:-4px"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg></button>
        <button class="bt" id="vm-inlineonly" onclick="setView('inlineonly')" title="インラインのみ"><svg viewBox="0 0 24 24"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg></button>
      </div>
      <div class="sp"></div>
      <span id="fn">未選択</span>
      <button class="bt" onclick="toggleToc()" title="見出し一覧" id="tocBtn"><svg viewBox="0 0 24 24"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg></button>
      <button class="bt" onclick="toggleHidden()" title="隠しファイル表示切替" id="hiddenBtn"><svg viewBox="0 0 24 24"><path d="M17.94 17.94A10.07 10.07 0 0112 20c-7 0-11-8-11-8a18.45 18.45 0 015.06-5.94M9.9 4.24A9.12 9.12 0 0112 4c7 0 11 8 11 8a18.5 18.5 0 01-2.16 3.19m-6.72-1.07a3 3 0 11-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg></button>
      <div class="td"></div>
      <div class="tg">
        <button class="bt" onclick="changeFontSize(-1)" title="文字を小さく">－</button>
        <span id="fs" style="font-size:12px;color:var(--tx2);min-width:26px;text-align:center;line-height:26px">13</span>
        <button class="bt" onclick="changeFontSize(1)" title="文字を大きく">＋</button>
      </div><div class="td"></div>
      <button class="bt" onclick="location.reload()" title="ページリロード"><svg viewBox="0 0 24 24"><polyline points="23 4 23 10 17 10"/><path d="M20.49 15a9 9 0 11-2.12-9.36L23 10"/></svg></button>
      <button class="bt" onclick="toggleTheme()" title="ライト/ダーク切替" id="themeBtn"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg></button>
      <button class="bt" onclick="deleteFile()" title="削除"><svg viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg></button>
    </div>
    <div id="ec">
      <div id="toc"><div class="toc-hd"><svg viewBox="0 0 24 24" width="14" height="14" style="stroke:var(--ac);fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;vertical-align:-2px"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg> 見出し <span onclick="toggleToc()">✕</span></div><div id="toc-list"></div></div>
      <div class="ep" id="ep-edit"><textarea id="ed" spellcheck="false" placeholder="Markdownを入力..."></textarea></div>
      <div class="ep hide" id="ep-preview"><div id="pv"></div></div>
      <div class="ep hide" id="ep-inline"><div id="il" contenteditable="true"></div></div>
    </div>
  </div>
</div>
<div id="modal" class="hide"><div class="box"><h3 id="mt"></h3><div class="modal-row"><button class="date-btn" onclick="insertDate()">日付</button><input id="mi" autocomplete="off"></div><div class="ma"><button id="modalDel" class="mb" style="background:var(--er);color:#fff;display:none" onclick="modalDelItem()">フォルダを削除</button><button class="mb" onclick="modalClose()">キャンセル</button><button class="mp" onclick="modalOk()">作成</button></div></div></div>
<div id="toast" class="hide"></div>
<script>
let curFile=null,curView='edit',modalCb=null,curDir='',lastEdited='ed',savedSel=null,dirty=false;
let dirCache={};
async function ensureDir(p){if(!(p in dirCache)){try{dirCache[p]=await api('GET','/api/files/'+encodeURIComponent(p))}catch{dirCache[p]=[]}}}
const ed=document.getElementById('ed'),pv=document.getElementById('pv'),il=document.getElementById('il'),ft=document.getElementById('ft');
ft.addEventListener('click',function(e){const row=e.target.closest('.fi');if(!row)return;const p=row.dataset.path;if(!p)return;if(e.target.closest('.fi-fav')){e.stopPropagation();toggleFav(p,e);return}if(e.target.closest('.fi-rename')){e.stopPropagation();renameItem(p,row.dataset.isdir==='1');return}});
let dragSrc=null;ft.addEventListener('dragstart',function(e){const row=e.target.closest('.fi');if(!row)return;dragSrc=row.dataset.path;e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',dragSrc||'')});ft.addEventListener('dragover',function(e){const row=e.target.closest('.fi');if(!row||row.dataset.isdir!=='1')return;e.preventDefault();e.dataTransfer.dropEffect='move'});ft.addEventListener('dragenter',function(e){const row=e.target.closest('.fi');if(!row||row.dataset.isdir!=='1')return;row.classList.add('drag-over')});ft.addEventListener('dragleave',function(e){const row=e.target.closest('.fi');if(!row)return;if(row.contains(e.relatedTarget))return;row.classList.remove('drag-over')});document.addEventListener('dragend',function(){document.querySelectorAll('.fi.drag-over').forEach(function(el){el.classList.remove('drag-over')});dragSrc=null});ft.addEventListener('drop',async function(e){e.preventDefault();const row=e.target.closest('.fi');if(!row)return;row.classList.remove('drag-over');if(row.dataset.isdir!=='1')return;const from=dragSrc||e.dataTransfer.getData('text/plain');const to=row.dataset.path||'';if(!from||from===to)return;if(to&&from.startsWith(to+'/'))return toast('移動できません',false);const r=await api('POST','/api/move',{from,to});if(r.ok){toast('移動しました');if(curFile===from){curFile=null;ed.value='';pv.innerHTML='';il.innerHTML='';document.getElementById('fn').textContent='未選択';dirty=false;document.getElementById('saveBtn').classList.remove('dirty')}loadTree()}else toast(r.error||'移動失敗',false)});
document.addEventListener('mousedown',e=>{if(e.target.closest('.fmt-bt')&&document.activeElement===ed){savedSel={s:ed.selectionStart,e:ed.selectionEnd}}},{capture:true});
const api=(m,u,b)=>fetch(u,{method:m,headers:{'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined}).then(r=>r.json());
function toast(t,ok=true){const e=document.getElementById('toast');e.textContent=t;e.className=ok?'':'error';setTimeout(()=>e.className='hide',2000)}
let modalDelPath=null;
function showModal(t,v,cb,showDel,delText){document.getElementById('mt').textContent=t;const i=document.getElementById('mi');i.value=v||'';modalCb=cb;const db=document.getElementById('modalDel');if(showDel){db.textContent=delText||'削除';db.style.display=''}else{db.style.display='none'}document.getElementById('modal').className='';setTimeout(()=>i.focus(),50)}
function modalClose(){document.getElementById('modal').className='hide';modalCb=null}
function modalOk(){if(!modalCb)return;const v=document.getElementById('mi').value.trim();if(!v)return;modalCb(v);modalClose()}
async function modalDelItem(){if(!modalDelPath)return;if(!confirm('削除しますか？'))return;const r=await api('DELETE','/api/files/'+encodeURIComponent(modalDelPath));if(r.ok){toast('削除しました');if(curFile&&(curFile===modalDelPath||curFile.startsWith(modalDelPath+'/'))){curFile=null;ed.value='';pv.innerHTML='';il.innerHTML='';document.getElementById('fn').textContent='未選択';dirty=false;document.getElementById('saveBtn').classList.remove('dirty')}modalDelPath=null;modalClose();loadTree()}else toast(r.error||'削除失敗',false)}
document.getElementById('mi').onkeydown=e=>{if(e.key==='Escape')modalClose()};
function insertDate(){const d=new Date();const ds=d.getFullYear()+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0')+'-';const i=document.getElementById('mi');const s=i.selectionStart;i.value=i.value.slice(0,s)+ds+i.value.slice(i.selectionEnd);i.selectionStart=i.selectionEnd=s+ds.length;i.focus()}
function toggleSb(){document.getElementById('sb').classList.toggle('hide')}
let tocOpen=localStorage.getItem('selfnote-toc')==='true';function toggleToc(){tocOpen=!tocOpen;document.getElementById('toc').classList.toggle('open',tocOpen);document.getElementById('tocBtn').classList.toggle('on',tocOpen);localStorage.setItem('selfnote-toc',tocOpen);if(tocOpen)updateToc()}
function updateToc(){const list=document.getElementById('toc-list');const lines=ed.value.split('\n');list.innerHTML='';lines.forEach((line,i)=>{const m=line.match(/^(#{1,3})\s+(.+)/);if(!m)return;const level=m[1].length;const el=document.createElement('div');el.className='toc-item l'+level;el.textContent=m[2];el.onclick=()=>{const pos=ed.value.split('\n').slice(0,i).join('\n').length;ed.focus();ed.setSelectionRange(pos,pos);const lineH=parseInt(getComputedStyle(ed).lineHeight);ed.scrollTop=i*lineH-ed.clientHeight/3;const headings=[];lines.forEach((l,j)=>{if(/^(#{1,3})\s+/.test(l))headings.push(j)});const idx=headings.indexOf(i);const tgt=(curView==='split'||curView==='preview')?pv:il;if(tgt&&idx>=0){const targets=tgt.querySelectorAll('h1,h2,h3');if(idx<targets.length)targets[idx].scrollIntoView({behavior:'smooth',block:'center'})}};list.appendChild(el)})}
function toggleTheme(){document.body.classList.toggle('dark');const d=document.body.classList.contains('dark');localStorage.setItem('selfnote-theme',d?'dark':'light')}
let fontSize=parseInt(localStorage.getItem('selfnote-fontsize'))||13;function changeFontSize(d){fontSize=Math.max(10,Math.min(24,fontSize+d));document.getElementById('fs').textContent=fontSize;document.getElementById('ed').style.fontSize=fontSize+'px';document.getElementById('pv').style.fontSize=(fontSize+1)+'px';document.getElementById('il').style.fontSize=(fontSize+1)+'px';localStorage.setItem('selfnote-fontsize',fontSize)}
function initTheme(){const t=localStorage.getItem('selfnote-theme');if(t==='dark'){document.body.classList.add('dark')}const sv=localStorage.getItem('selfnote-view');if(sv&&sv!==curView)setView(sv);const ss=localStorage.getItem('selfnote-sort');if(ss){try{const s=JSON.parse(ss);sortField=s.field;sortAsc=s.asc;document.getElementById('sort-name').className='sort-btn'+(sortField==='name'?' on':'');document.getElementById('sort-date').className='sort-btn'+(sortField==='date'?' on':'');document.getElementById('sort-name').textContent='ファイル名 '+(sortField==='name'?(sortAsc?'▲':'▼'):'▲');document.getElementById('sort-date').textContent='作成日 '+(sortField==='date'?(sortAsc?'▲':'▼'):'▲')}catch(e){}}}
const ICO_FOLDER='<svg viewBox="0 0 24 24" fill="none" stroke="#e8b430" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/></svg>';
const ICO_FOLDER_OPEN='<svg viewBox="0 0 24 24" fill="none" stroke="#e8b430" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 19a2 2 0 01-2-2V7a2 2 0 012-2h4l2 2h9a2 2 0 012 2v1"/><path d="M3 17h18a1 1 0 011 1v1a2 2 0 01-2 2H4a2 2 0 01-2-2v-1a1 1 0 011-1z"/></svg>';
const ICO_MD='<svg viewBox="0 0 24 24" fill="none" stroke="#7aa2f7" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>';
const ICO_FILE='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/></svg>';
function fileIcon(n,d){if(d)return ICO_FOLDER;if(n.endsWith('.md'))return ICO_MD;return ICO_FILE}
let expandedDirs=new Set();
let sortField='name',sortAsc=true;
let showHidden=localStorage.getItem('selfnote-hidden')==='true';
let favorites=[];
function isHidden(name){return name.startsWith('.')}
async function loadFavorites(){try{const r=await api('GET','/api/favorites');favorites=Array.isArray(r)?r:[]}catch{favorites=[]}}
function isFav(path){return favorites.includes(path)}
async function toggleFav(path,e){e.stopPropagation();const i=favorites.indexOf(path);if(i>=0)favorites.splice(i,1);else favorites.push(path);await api('POST','/api/favorites',{favorites});loadTree()}
function toggleSort(f){if(sortField===f)sortAsc=!sortAsc;else{sortField=f;sortAsc=true}document.getElementById('sort-name').className='sort-btn'+(sortField==='name'?' on':'');document.getElementById('sort-date').className='sort-btn'+(sortField==='date'?' on':'');document.getElementById('sort-name').textContent='ファイル名 '+(sortField==='name'?(sortAsc?'▲':'▼'):'▲');document.getElementById('sort-date').textContent='作成日 '+(sortField==='date'?(sortAsc?'▲':'▼'):'▲');localStorage.setItem('selfnote-sort',JSON.stringify({field:sortField,asc:sortAsc}));loadTree()}
function toggleHidden(){showHidden=!showHidden;localStorage.setItem('selfnote-hidden',showHidden);document.getElementById('hiddenBtn').classList.toggle('on',showHidden);loadTree()}
function sortFiles(files){const d=files.filter(f=>f.isDir);const ff=files.filter(f=>!f.isDir);const c=(a,b)=>{if(sortField==='date')return sortAsc?(a.birthtime-b.birthtime):(b.birthtime-a.birthtime);return sortAsc?a.name.localeCompare(b.name):b.name.localeCompare(a.name)};d.sort(c);ff.sort(c);return[...d,...ff]}
function makeFavItem(fav){const d=document.createElement('div');d.className='fi'+(curFile===fav.path?' on':'');const dir=fav.path.includes('/')?fav.path.slice(0,fav.path.lastIndexOf('/')):'';d.innerHTML='<span class="ico-tree" style="visibility:hidden">▸</span><span class="ico">'+ICO_MD+'</span><span class="fi-name">'+fav.name+'</span><span class="fi-favpath">'+dir+'</span><span class="fi-fav on" title="お気に入り解除">★</span><span class="fi-rename" title="名前変更">✏</span>';d.onclick=()=>{curDir=dir;openFile(fav.path)};d.dataset.path=fav.path;d.dataset.isdir='0';d.draggable=true;return d}
function renderItems(items,container,depth,parentPath){for(const item of items){if(!showHidden&&isHidden(item.name))continue;if(item.isDir){const fp=parentPath?parentPath+'/'+item.name:item.name;const isExp=expandedDirs.has(fp);const el=document.createElement('div');el.className='fi'+(curFile===fp?' on':'');el.style.paddingLeft=(10+depth*16)+'px';el.innerHTML='<span class="ico-tree'+(isExp?' open':'')+'">▸</span><span class="ico">'+(isExp?ICO_FOLDER_OPEN:ICO_FOLDER)+'</span><span class="fi-name">'+item.name+'</span><span class="fi-rename" title="名前変更">✏</span>';el.onclick=()=>{curDir=fp;toggleDir(fp)};el.dataset.path=fp;el.dataset.isdir='1';el.draggable=true;container.appendChild(el);if(isExp){const ch=dirCache[fp]||[];renderItems(sortFiles(ch),container,depth+1,fp)}}else{const fp=parentPath?parentPath+'/'+item.name:item.name;const el=document.createElement('div');el.className='fi'+(curFile===fp?' on':'');el.style.paddingLeft=(10+depth*16)+'px';const fvBtn=item.name.endsWith('.md')?'<span class="fi-fav'+(isFav(fp)?' on':'')+'" title="お気に入り">★</span>':'';el.innerHTML='<span class="ico-tree" style="visibility:hidden">▸</span><span class="ico">'+fileIcon(item.name,false)+'</span><span class="fi-name">'+item.name+'</span>'+fvBtn+'<span class="fi-rename" title="名前変更">✏</span>';el.onclick=()=>openFile(fp);el.dataset.path=fp;el.dataset.isdir='0';el.draggable=true;container.appendChild(el)}}}
function renderTree(){ft.innerHTML='';const rootEl=document.createElement('div');rootEl.className='fi';rootEl.style.paddingLeft='10px';rootEl.style.borderBottom='1px solid var(--bd)';rootEl.innerHTML='<span class="ico-tree" style="visibility:hidden">▸</span><span class="ico">'+ICO_FOLDER+'</span><span class="fi-name" style="color:var(--ac);font-weight:600">ルートフォルダ</span>';rootEl.onclick=()=>{curDir='';expandedDirs.clear();loadTree()};rootEl.dataset.path='';rootEl.dataset.isdir='1';rootEl.draggable=true;ft.appendChild(rootEl);const allFav=favorites.map(fp=>{const name=fp.split('/').pop();return{name,path:fp}});allFav.sort((a,b)=>sortAsc?a.name.localeCompare(b.name):b.name.localeCompare(a.name));if(allFav.length){const sep=document.createElement('div');sep.className='fi-sep';ft.appendChild(sep);allFav.forEach(fav=>ft.appendChild(makeFavItem(fav)))}const rootFiles=dirCache['']||[];renderItems(sortFiles(rootFiles),ft,0,'')}
async function toggleDir(path){if(expandedDirs.has(path)){expandedDirs.delete(path);for(const d of[...expandedDirs]){if(d.startsWith(path+'/'))expandedDirs.delete(d)}}else{expandedDirs.add(path);await ensureDir(path)}renderTree()}
async function loadTree(){dirCache={};await ensureDir('');for(const dir of expandedDirs){await ensureDir(dir)}renderTree()}
async function openFile(p,noTree){const r=await api('GET','/api/files/'+encodeURIComponent(p));if(r.error)return toast(r.error,false);curFile=p;dirty=false;document.getElementById('saveBtn').classList.remove('dirty');document.getElementById('fn').textContent=p.split('/').pop();ed.value=r.content;lastEdited='ed';if(curView==='split'||curView==='preview')updatePreview();if(curView==='inline'||curView==='inlineonly')updateInline();if(tocOpen)updateToc();if(!noTree)loadTree()}
function setView(v){syncEdFromInline();curView=v;document.querySelectorAll('[id^="vm-"]').forEach(b=>b.classList.remove('on'));document.getElementById('vm-'+v).classList.add('on');document.getElementById('ep-edit').className='ep'+((v==='edit'||v==='split'||v==='inline')?'':' hide');document.getElementById('ep-preview').className='ep'+((v==='split'||v==='preview')?'':' hide');document.getElementById('ep-inline').className='ep'+((v==='inline'||v==='inlineonly')?'':' hide');if(v==='split'||v==='preview')updatePreview();if(v==='inline'||v==='inlineonly')updateInline();localStorage.setItem('selfnote-view',v);updateToolbarState()}
function syncEdFromInline(){if(lastEdited==='il'){clearTimeout(previewTimer);ed.value=html2md(il.innerHTML)}}
function updateToolbarState(){const dis=curView==='preview';document.querySelectorAll('.fmt-bt').forEach(b=>b.disabled=dis)}
function updatePreview(){pv.innerHTML=md(ed.value)}let skipIlInput=false;function updateInline(){skipIlInput=true;il.innerHTML=md(ed.value);skipIlInput=false}
let previewTimer;function markDirty(){if(!dirty){dirty=true;document.getElementById('saveBtn').classList.add('dirty')}}
let autoSaveTimer;function autoSave(){clearTimeout(autoSaveTimer);autoSaveTimer=setTimeout(()=>{if(dirty&&curFile)save()},1000)}
ed.addEventListener('input',()=>{lastEdited='ed';markDirty();autoSave();if(curView==='split'||curView==='preview')clearTimeout(previewTimer),previewTimer=setTimeout(updatePreview,80);if(curView==='inline'||curView==='inlineonly')clearTimeout(previewTimer),previewTimer=setTimeout(updateInline,80);if(tocOpen)updateToc()});
il.addEventListener('input',()=>{if(composing||skipIlInput)return;lastEdited='il';markDirty();autoSave();clearTimeout(previewTimer);previewTimer=setTimeout(()=>{ed.value=html2md(il.innerHTML)},150)});
let composing=false;il.addEventListener('compositionstart',()=>{composing=true});il.addEventListener('compositionend',()=>{composing=false;il.dispatchEvent(new Event('input'))});
il.addEventListener('keydown',e=>{if(composing)return;if(e.key==='Tab'){e.preventDefault();document.execCommand('insertText',false,'  ')}if(e.key==='Enter'){const sel=window.getSelection();if(!sel.rangeCount)return;const anchor=sel.anchorNode;const inPre=anchor.nodeType===3?anchor.parentElement.closest('pre'):anchor.closest&&anchor.closest('pre');if(inPre){e.preventDefault();document.execCommand('insertText',false,'\n')}}});
il.addEventListener('mousedown',e=>{const a=e.target.closest('a');if(a&&a.href){e.preventDefault();window.open(a.href,'_blank');return}});
il.addEventListener('click',e=>{if(!e.target.closest('a')&&!e.target.closest('pre')&&il.lastElementChild&&il.lastElementChild.tagName==='PRE'){const p=document.createElement('p');p.innerHTML='<br>';il.appendChild(p);const r=document.createRange();r.setStart(p,0);r.collapse(true);const sel=window.getSelection();sel.removeAllRanges();sel.addRange(r)}});
function copyCode(btn){const c=btn.previousElementSibling;if(!c)return;const t=c.textContent;if(navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(t).then(()=>{btn.textContent='done!';setTimeout(()=>btn.textContent='copy',1500)}).catch(()=>fc(t,btn));else fc(t,btn)}
function fc(t,b){const a=document.createElement('textarea');a.value=t;a.style.position='fixed';a.style.left='-9999px';document.body.appendChild(a);a.select();try{document.execCommand('copy');b.textContent='done!';setTimeout(()=>b.textContent='copy',1500)}catch(e){}document.body.removeChild(a)}
async function save(){if(!curFile){if(!ed.value.trim())return toast('内容がありません',false);return showModal('ファイル名を入力','',async name=>{if(!name)return;if(!name.endsWith('.md'))name+='.md';const dot=name.lastIndexOf('.');const stem=name.slice(0,dot),ext=name.slice(dot);let tryName=name,n=1,r;do{r=await api('POST','/api/files',{name:tryName,isDir:false,parent:''});if(r.error==='exists'&&n<100){n++;tryName=stem+'('+n+')'+ext}else break}while(r.error==='exists');if(r.ok){curFile=r.path;dirty=false;document.getElementById('saveBtn').classList.remove('dirty');syncEdFromInline();ed.value=ed.value.replace(/(```[\s\S]*?```)/g,(m)=>m.replace(/\n{3,}/g,'\n\n'));const s=await api('PUT','/api/files/'+encodeURIComponent(curFile),{content:ed.value});if(s.ok){document.getElementById('fn').textContent=name;toast('保存しました');loadTree()}else toast(s.error,false)}else toast(r.error||'作成失敗',false)})}syncEdFromInline();ed.value=ed.value.replace(/(```[\s\S]*?```)/g,(m)=>m.replace(/\n{3,}/g,'\n\n'));const r=await api('PUT','/api/files/'+encodeURIComponent(curFile),{content:ed.value});if(r.ok){dirty=false;document.getElementById('saveBtn').classList.remove('dirty');toast('保存しました')}else toast(r.error,false)}
function newItem(isDir){showModal(isDir?'フォルダ名':'ファイル名','',async name=>{if(!name)return;if(!isDir&&!name.endsWith('.md'))name+='.md';const dot=name.lastIndexOf('.');const stem=isDir?name:name.slice(0,dot);const ext=isDir?'':name.slice(dot);let tryName=name,n=1,r;do{r=await api('POST','/api/files',{name:tryName,isDir,parent:curDir});if(r.error==='exists'&&n<100){n++;tryName=stem+'('+n+')'+ext}else break}while(r.error==='exists');if(r.ok){toast('作成しました');if(!isDir&&curDir){expandedDirs.add(curDir)}loadTree();if(!isDir)openFile(r.path,true)}else toast(r.error,false)})}
function renameItem(filePath,isDir){modalDelPath=filePath;showModal('新しい名前',filePath.split('/').pop(),async name=>{if(!name)return;const r=await api('POST','/api/rename',{old:filePath,newName:name});if(r.ok){if(curFile===filePath){curFile=r.path;document.getElementById('fn').textContent=name}loadTree()}else toast(r.error||'変更失敗',false)},true,isDir?'フォルダを削除':'ファイルを削除')}
async function deleteFile(){if(!curFile)return;if(!confirm('削除しますか？'))return;const r=await api('DELETE','/api/files/'+encodeURIComponent(curFile));if(r.ok){curFile=null;ed.value='';pv.innerHTML='';il.innerHTML='';document.getElementById('fn').textContent='未選択';toast('削除しました');loadTree()}else toast(r.error,false)}
function ins(type,arg){insSource(type,arg)}
function insSource(type,arg){
  const t=ed.value;
  let s=ed.selectionStart,e=ed.selectionEnd;
  const lineTypes={heading:1,ul:1,ol:1,check:1,quote:1};
  if(lineTypes[type])s=t.lastIndexOf('\n',s-1)+1;
  const sel=t.substring(s,e);let b='',a='',r=sel;
  switch(type){
    case'heading':b='#'.repeat(arg)+' ';break;
    case'bold':b='**';a='**';break;
    case'italic':b='*';a='*';break;
    case'strike':b='~~';a='~~';break;
    case'ul':b='- ';break;
    case'ol':b='1. ';break;
    case'check':b='- [ ] ';break;
    case'link':r='['+(sel||'テキスト')+']('+(sel||'URL')+')';break;
    case'image':r='!['+(sel||'alt')+'](URL)';break;
    case'code':b='`';a='`';break;
    case'codeblock':{const nb=s>0&&t[s-1]!=='\n',na=e<t.length&&t[e]!=='\n';b=(nb?'\n\n':'')+'```\n';a='\n```'+(na?'\n\n':'');break}
    case'quote':b='> ';break;
    case'hr':{const nb=s>0&&t[s-1]!=='\n',na=e<t.length&&t[e]!=='\n';r=(nb?'\n\n':'')+'---'+(na?'\n\n':'\n');break}
  }
  ed.value=t.slice(0,s)+b+r+a+t.slice(e);ed.focus();ed.setSelectionRange(s+b.length,s+b.length+r.length);ed.dispatchEvent(new Event('input'))
}
function md(s){
  const blocks=[];
  let h=s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/^```([\s\S]*?)^```/gm,(m,c)=>{const idx=blocks.length;blocks.push('<pre><code>'+(c.replace(/^\n/,'').replace(/\n$/,'')||'\n')+'</code><button class="cp-btn" onclick="copyCode(this)">copy</button></pre>');return'\x00B'+idx+'\x00'})
    .replace(/`([^`]+)`/g,'<code>$1</code>').replace(/^######\s+(.+)$/gm,'<h6>$1</h6>').replace(/^#####\s+(.+)$/gm,'<h5>$1</h5>').replace(/^####\s+(.+)$/gm,'<h4>$1</h4>').replace(/^###\s+(.+)$/gm,'<h3>$1</h3>').replace(/^##\s+(.+)$/gm,'<h2>$1</h2>').replace(/^#\s+(.+)$/gm,'<h1>$1</h1>').replace(/^---+$/gm,'<hr>').replace(/\*\*(.+?)\*\*/g,'<strong>$1</strong>').replace(/\*(.+?)\*/g,'<em>$1</em>').replace(/~~(.+?)~~/g,'<del>$1</del>').replace(/!\[([^\]]*)\]\(([^)]+)\)/g,'<img src="$2" alt="$1">').replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<a href="$2" target="_blank">$1</a>').replace(/(?<![">\]])(https?:\/\/[^\s<)&\]]+)/g,(m)=>'<a href="'+m+'" target="_blank">'+m+'</a>').replace(/^>\s+(.+)$/gm,'<blockquote>$1</blockquote>').replace(/^- \[x\]\s+(.+)$/gm,'<li><input type="checkbox" checked disabled> $1</li>').replace(/^- \[ \]\s+(.+)$/gm,'<li><input type="checkbox" disabled> $1</li>').replace(/^[-*]\s+(.+)$/gm,'<li>$1</li>').replace(/^(\d+)\.\s+(.+)$/gm,'<li>$2</li>');
  h=h.replace(/((?:<li>[\s\S]*?<\/li>\n*)+)/g,m=>{const items=m.split(/\n/).filter(l=>l.trim());return'<'+(items.every(l=>l.includes('checkbox'))?'ul':'ul')+'>'+items.join('')+'</ul>'});
  h=h.replace(/<\/blockquote>\n<blockquote>/g,'<br>');
  h=h.replace(/((?:^\|.+\|$\n?)+)/gm,(m)=>{const rows=m.trim().split('\n').filter(l=>l.trim());if(rows.length<2)return m;const sepIdx=rows.findIndex(r=>/^\|[\s\-:|]+\|$/.test(r.trim()));if(sepIdx<1)return m;let out='<table>';for(let i=0;i<rows.length;i++){if(i===sepIdx)continue;const cells=rows[i].split('|').slice(1,-1).map(c=>c.trim());out+='<tr>'+cells.map(c=>'<'+(i===0?'th':'td')+'>'+c+'</td>').join('')+'</tr>'}return out+'</table>'});
  h=h.replace(/([^\n])\n(?=[^\n\u0000])/g,'$1<br>');
  h=h.replace(/\n?(<h[1-6]>[\s\S]*?<\/h[1-6]>|<hr>|\u0000B\d+\u0000|<ul>[\s\S]*?<\/ul>|<ol>[\s\S]*?<\/ol>|<blockquote>[\s\S]*?<\/blockquote>|<table>[\s\S]*?<\/table>)\n?/g,'\n\n$1\n\n');
  h=h.replace(/\n{2,}/g,'</p><p>');h='<p>'+h+'</p>';
  h=h.replace(/<p>\s*<(h[1-6]|hr|ul|ol|blockquote|table)/g,'<$1');
  h=h.replace(/<\/(h[1-6]|hr|ul|ol|blockquote|table)>\s*<\/p>/g,'</$1>');
  h=h.replace(/<p>\s*(\u0000B\d+\u0000)\s*<\/p>/g,'$1');h=h.replace(/<p>\s*<\/p>/g,'');
  h=h.replace(/\u0000B(\d+)\u0000/g,(m,i)=>blocks[i]);return h;
}
function html2md(html){const d=document.createElement('div');d.innerHTML=html;function walk(n){if(n.nodeType===3)return n.textContent;if(n.nodeType!==1)return'';const t=n.tagName.toLowerCase();if(t==='button')return'';let c='';for(const ch of n.childNodes)c+=walk(ch);switch(t){case'h1':return'# '+c+'\n\n';case'h2':return'## '+c+'\n\n';case'h3':return'### '+c+'\n\n';case'h4':return'#### '+c+'\n\n';case'h5':return'##### '+c+'\n\n';case'h6':return'###### '+c+'\n\n';case'p':return c+'\n\n';case'br':return'\n';case'strong':case'b':return'**'+c+'**';case'em':case'i':return'*'+c+'*';case'del':return'~~'+c+'~~';case'code':return n.parentElement&&n.parentElement.tagName.toLowerCase()==='pre'?c:'`'+c+'`';case'pre':return'```\n'+c.trim()+'\n```\n';case'a':return'['+c+']('+(n.getAttribute('href')||'')+')';case'img':return'!['+(n.getAttribute('alt')||'')+']('+(n.getAttribute('src')||'')+')';case'ul':case'ol':return c+'\n';case'li':{const p=n.parentElement;if(!p)return c+'\n';const cb=n.querySelector('input[type=checkbox]');return cb?'- ['+(cb.checked?'x':' ')+'] '+c.replace(/^\s*\n?/,'')+'\n':'- '+c+'\n'}case'blockquote':return'> '+c+'\n\n';case'hr':return'---\n\n';case'input':return n.type==='checkbox'?'- ['+(n.checked?'x':' ')+'] ':'';default:return c}}return walk(d).replace(/\n{3,}/g,'\n\n').trim()+'\n'}
let searchTimer;function doSearch(){clearTimeout(searchTimer);const q=document.getElementById('sq').value.trim(),sr=document.getElementById('sr');if(!q){sr.innerHTML='';return}searchTimer=setTimeout(async()=>{const r=await api('POST','/api/search',{query:q});sr.innerHTML=r.length?r.map(x=>'<div class="sr-item" onclick="openFile(\''+x.file.replace(/'/g,"\\'")+'\')"><span class="sr-file">'+x.file+':'+x.line+'</span><span class="sr-line">'+x.text.replace(/</g,'&lt;')+'</span></div>').join(''):'<div class="sr-item" style="color:var(--tx2)">見つかりません</div>'},300)}
ed.addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key==='s'){e.preventDefault();save()}if((e.ctrlKey||e.metaKey)&&e.key==='b'){e.preventDefault();ins('bold')}if((e.ctrlKey||e.metaKey)&&e.key==='i'){e.preventDefault();ins('italic')}if(e.key==='Tab'){e.preventDefault();const s=ed.selectionStart;ed.value=ed.value.slice(0,s)+'  '+ed.value.slice(ed.selectionEnd);ed.selectionStart=ed.selectionEnd=s+2;ed.dispatchEvent(new Event('input'))}});
document.getElementById('sq').addEventListener('keydown',e=>{if(e.key==='Enter')doSearch()});
initTheme();changeFontSize(0);if(tocOpen){document.getElementById('toc').classList.add('open');document.getElementById('tocBtn').classList.add('on');updateToc()}if(showHidden){document.getElementById('hiddenBtn').classList.add('on')}loadFavorites().then(()=>loadTree());updateToolbarState();
</script>
</body>
</html>
HTMLEOF

cat > /etc/systemd/system/selfnote.service <<EOF
[Unit]
Description=SelfNote v23 Markdown Editor
After=network.target

[Service]
Type=simple
ExecStart=$(which node) $INSTALL_DIR/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable selfnote
systemctl start selfnote

echo ""
echo "==> tailscale serve を設定..."

TAILSCALE_PORT=3342
tailscale serve --https=${TAILSCALE_PORT} off 2>/dev/null || true
tailscale serve --bg --https=${TAILSCALE_PORT} "http://127.0.0.1:${PORT}" || {
    echo "⚠️  tailscale serve の設定に失敗しました（手動で設定してください）"
    echo "     tailscale serve --bg --https=${TAILSCALE_PORT} http://127.0.0.1:${PORT}"
}
echo "  ✓ tailscale serve 設定完了"

sleep 1
if systemctl is-active --quiet selfnote; then
  echo "  ✓ selfnote.service 起動確認OK"
else
  echo "  ⚠️  selfnote.service が起動していません。'journalctl -u selfnote -n 30' を確認してください"
fi

IP=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname)
TAILSCALE_DOMAIN=$(tailscale status --json 2>/dev/null | grep -oP '"DNSName"\s*:\s*"[^"]*"' | head -1 | grep -oP '"[^"]*"$' | tr -d '"' | sed 's/\.$//')
if [ -z "$TAILSCALE_DOMAIN" ]; then
  TAILSCALE_DOMAIN="(tailscale未設定)"
fi

echo ""
echo "✅ SelfNote v23 (patched) インストール完了!"
echo ""
echo "URL: https://${TAILSCALE_DOMAIN}:${TAILSCALE_PORT}"
echo ""
echo "📁 データ: $DATA_DIR"
echo "📂 インストール: $INSTALL_DIR"
echo ""
echo "コマンド:"
echo "  systemctl start selfnote   # 起動"
echo "  systemctl stop selfnote    # 停止"
echo "  systemctl restart selfnote # 再起動"
echo "  journalctl -u selfnote -f  # ログ確認"