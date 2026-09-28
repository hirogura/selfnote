const http = require('http');
const https = require('https');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');
const { URL } = require('url');
const { exec } = require('child_process');

const PORT = 3342;
const HOST = '127.0.0.1';
const DATA = '/opt/lxd-data/note';
const PUB = path.join(__dirname, 'public');
const FAVORITES_FILE = path.join(DATA, '.favorites.json');
const UPDATE_FLAG = '/tmp/selfnote-update.flag';
const MAX_BODY = 5 * 1024 * 1024;
const MAX_SEARCH_QUERY = 200;
const MAX_SEARCH_RESULTS = 50;
const MAX_SEARCH_FILE = 1024 * 1024;
const MAX_RECENT = 100;
const SYNC_CONFIG_FILE = path.join(__dirname, 'sync_config.json');
const SYNC_ROLE_SOURCE = 'source';
const SYNC_ROLE_DEST = 'destination';
const SYNC_MAX_BODY = 100 * 1024 * 1024;
const SYNC_MAX_FILE = 20 * 1024 * 1024;
const DEFAULT_SYNC_CONFIG = { role: SYNC_ROLE_SOURCE, peer: '', peer_name: '', sync_time: '03:00', last_sync: '', last_result: '' };

try { fs.unlinkSync(UPDATE_FLAG); } catch {}

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

function isInside(real, base) {
  const rel = path.relative(base, real);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function safeData(p) {
  return isInside(path.resolve(p), DATA);
}

function safePub(p) {
  return isInside(path.resolve(p), PUB);
}

function safe(p) {
  const real = path.resolve(p);
  return isInside(real, DATA) || isInside(real, PUB);
}

function readBody(req, max) {
  return new Promise((resolve, reject) => {
    const limit = max || MAX_BODY;
    const c = [];
    let size = 0;
    req.on('data', d => {
      size += d.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      c.push(d);
    });
    req.on('end', () => resolve(Buffer.concat(c).toString()));
    req.on('error', reject);
  });
}

function parseJson(text) {
  if (!text) return null;
  try { return JSON.parse(text); } catch { return undefined; }
}

function validSegment(name) {
  if (typeof name !== 'string') return false;
  const t = name.trim();
  if (!t || t === '.' || t === '..') return false;
  if (t.includes('/') || t.includes('\\') || t.includes('\0')) return false;
  return true;
}

function validRel(rel) {
  if (rel === '' || rel === undefined || rel === null) return true;
  if (typeof rel !== 'string') return false;
  if (rel.includes('\0')) return false;
  if (path.isAbsolute(rel)) return false;
  const parts = rel.split('/');
  for (const p of parts) {
    if (p === '..' || p.includes('\\')) return false;
  }
  return true;
}

const dirCache = new Map();
const CACHE_TTL = 2000;

function fileTimes(st) {
  return {
    birthtime: st.birthtimeMs || st.mtimeMs || st.ctimeMs || 0,
    mtime: st.mtimeMs || 0,
  };
}

async function listDir(dir) {
  const cached = dirCache.get(dir);
  if (cached && Date.now() - cached.ts < CACHE_TTL) return cached.items;
  try {
    const entries = await fsp.readdir(dir, { withFileTypes: true });
    const items = await Promise.all(entries.map(async d => {
      try {
        const st = await fsp.stat(path.join(dir, d.name));
        return { name: d.name, isDir: d.isDirectory(), ...fileTimes(st) };
      } catch { return { name: d.name, isDir: d.isDirectory(), birthtime: 0, mtime: 0 }; }
    }));
    items.sort((a, b) => a.isDir !== b.isDir ? (a.isDir ? -1 : 1) : a.name.localeCompare(b.name));
    dirCache.set(dir, { items, ts: Date.now() });
    return items;
  } catch { return []; }
}

function invalidateCache() { dirCache.clear(); }

// ===== 同期 (sync) =====
// 別PCの selfnote と1日1回・片方向で同期する（予備機用途・同期先は1箇所のみ）。
// 同期対象は DATA 配下の全ファイル。tailnet 内通信を前提とする。

function loadSyncConfig() {
  const cfg = { ...DEFAULT_SYNC_CONFIG };
  try {
    const d = JSON.parse(fs.readFileSync(SYNC_CONFIG_FILE, 'utf-8'));
    if (d && typeof d === 'object') {
      for (const k of Object.keys(DEFAULT_SYNC_CONFIG)) {
        if (typeof d[k] === 'string') cfg[k] = d[k];
      }
    }
  } catch {}
  if (cfg.role !== SYNC_ROLE_SOURCE && cfg.role !== SYNC_ROLE_DEST) cfg.role = SYNC_ROLE_SOURCE;
  if (!validSyncTime(cfg.sync_time)) cfg.sync_time = DEFAULT_SYNC_CONFIG.sync_time;
  return cfg;
}

function saveSyncConfig(cfg) {
  const tmp = SYNC_CONFIG_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), 'utf-8');
  fs.renameSync(tmp, SYNC_CONFIG_FILE);
}

function validSyncTime(s) {
  return typeof s === 'string' && /^([01]\d|2[0-3]):[0-5]\d$/.test(s);
}

function isValidPeerUrl(u) {
  if (typeof u !== 'string' || !u || u.length > 500) return false;
  try {
    const p = new URL(u);
    return (p.protocol === 'http:' || p.protocol === 'https:') && !!p.hostname;
  } catch { return false; }
}

function tailscaleStatus() {
  return new Promise((resolve) => {
    exec('tailscale status --json', { timeout: 10000, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => {
      if (err) return resolve(null);
      try {
        const d = JSON.parse(stdout);
        return resolve(d && typeof d === 'object' ? d : null);
      } catch { return resolve(null); }
    });
  });
}

async function getSelfBaseUrl() {
  const d = await tailscaleStatus();
  try {
    const dns = String((((d || {}).Self) || {}).DNSName || '').replace(/\.+$/, '');
    if (dns) return `https://${dns}:${PORT}`;
  } catch {}
  return '';
}

async function getSelfHostName() {
  const d = await tailscaleStatus();
  try { return String((((d || {}).Self) || {}).HostName || ''); } catch {}
  return '';
}

async function getSyncPeerList() {
  const d = await tailscaleStatus();
  if (!d) return [];
  const peers = (d.Peer && typeof d.Peer === 'object') ? d.Peer : {};
  let selfDns = '';
  try { selfDns = String((((d || {}).Self) || {}).DNSName || '').replace(/\.+$/, ''); } catch {}
  const out = [];
  for (const k of Object.keys(peers)) {
    const p = peers[k];
    if (!p || typeof p !== 'object') continue;
    let dns = '';
    try { dns = String(p.DNSName || '').replace(/\.+$/, ''); } catch {}
    if (!dns || dns === selfDns) continue;
    const name = p.HostName || dns;
    const ips = Array.isArray(p.TailscaleIPs) ? p.TailscaleIPs : [];
    out.push({ name, dns, url: `https://${dns}:${PORT}`, ip: ips[0] || '', os: p.OS || '', online: !!p.Online });
  }
  // 稼働中を先頭に
  out.sort((a, b) => (a.online === b.online) ? a.name.localeCompare(b.name) : (a.online ? -1 : 1));
  return out;
}

function httpsRequestJson(urlStr, method, payload, timeoutMs) {
  return new Promise((resolve, reject) => {
    let u;
    try { u = new URL(urlStr); } catch { return reject(new Error('bad url')); }
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return reject(new Error('bad url'));
    const body = payload !== undefined ? JSON.stringify(payload) : null;
    const lib = u.protocol === 'https:' ? https : http;
    const opts = {
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      method,
      timeout: timeoutMs || 30000,
      rejectUnauthorized: false,
      headers: { 'User-Agent': 'selfnote-sync' },
    };
    if (body) {
      opts.headers['Content-Type'] = 'application/json';
      opts.headers['Content-Length'] = Buffer.byteLength(body);
    }
    const req = lib.request(opts, (res) => {
      const chunks = [];
      res.on('data', (d) => chunks.push(d));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString() || '{}';
        try { resolve(JSON.parse(text)); } catch { reject(new Error('bad response')); }
      });
    });
    req.on('timeout', () => { req.destroy(new Error('timeout')); });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function buildSyncBundle() {
  const files = [];
  async function walk(dir, base) {
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const fp = path.join(dir, e.name);
      const rel = base ? base + '/' + e.name : e.name;
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) { await walk(fp, rel); continue; }
      if (!e.isFile()) continue;
      try {
        const st = await fsp.stat(fp);
        if (st.size > SYNC_MAX_FILE) {
          files.push({ rel, size: st.size, mtime: st.mtimeMs || 0, tooLarge: true, content: null });
          continue;
        }
        const buf = await fsp.readFile(fp);
        files.push({ rel, size: st.size, mtime: st.mtimeMs || 0, content: buf.toString('base64') });
      } catch {}
    }
  }
  await walk(DATA, '');
  return { version: 1, exported_at: new Date().toISOString(), files };
}

async function applySyncBundle(bundle) {
  if (!bundle || typeof bundle !== 'object' || !Array.isArray(bundle.files)) throw new Error('invalid bundle');
  const wanted = new Map();
  for (const f of bundle.files) {
    if (!f || typeof f !== 'object') continue;
    if (typeof f.rel !== 'string' || !f.rel || !validRel(f.rel)) continue;
    if (f.tooLarge) { wanted.set(f.rel, null); continue; } // 肥大ファイルは現地のものを保持
    if (typeof f.content !== 'string') continue;
    let buf;
    try { buf = Buffer.from(f.content, 'base64'); } catch { continue; }
    if (buf.length > SYNC_MAX_FILE) { wanted.set(f.rel, null); continue; }
    wanted.set(f.rel, { buf, mtime: typeof f.mtime === 'number' ? f.mtime : 0 });
  }
  const existing = [];
  async function walk(dir, base) {
    let entries;
    try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const fp = path.join(dir, e.name);
      const rel = base ? base + '/' + e.name : e.name;
      if (e.isSymbolicLink()) continue;
      if (e.isDirectory()) { await walk(fp, rel); continue; }
      if (e.isFile()) existing.push(rel);
    }
  }
  await walk(DATA, '');
  for (const rel of existing) {
    if (wanted.has(rel)) continue;
    const fp = path.join(DATA, rel);
    if (!safeData(fp)) continue;
    try { await fsp.unlink(fp); } catch {}
  }
  for (const [rel, entry] of wanted) {
    if (!entry) continue;
    const fp = path.join(DATA, rel);
    if (!safeData(fp)) continue;
    try {
      await fsp.mkdir(path.dirname(fp), { recursive: true });
      await fsp.writeFile(fp, entry.buf);
      if (entry.mtime > 0) {
        try { await fsp.utimes(fp, new Date(), new Date(entry.mtime)); } catch {}
      }
    } catch {}
  }
  // 空になったディレクトリを掃除（ベストエフォート）
  async function prune(dir) {
    let entries;
    try { entries = await fsp.readdir(dir); } catch { return; }
    for (const e of entries) {
      const fp = path.join(dir, e);
      try { const st = await fsp.stat(fp); if (st.isDirectory()) await prune(fp); } catch {}
    }
    if (path.resolve(dir) !== path.resolve(DATA)) {
      try { await fsp.rmdir(dir); } catch {}
    }
  }
  await prune(DATA);
  invalidateCache();
}

function markSyncResult(ok, message) {
  try {
    const cfg = loadSyncConfig();
    if (ok) cfg.last_sync = new Date().toISOString();
    cfg.last_result = String(message || '').slice(0, 300);
    saveSyncConfig(cfg);
  } catch {}
}

async function syncPushToPeer(peerUrl) {
  if (!isValidPeerUrl(peerUrl)) throw new Error('同期先が未設定です');
  const bundle = await buildSyncBundle();
  await httpsRequestJson(peerUrl.replace(/\/+$/, '') + '/api/sync/import', 'POST', bundle, 60000);
  markSyncResult(true, '同期しました（送信・' + (bundle.exported_at || '') + '）');
  return bundle.exported_at || '';
}

async function syncPullFromPeer(peerUrl) {
  if (!isValidPeerUrl(peerUrl)) throw new Error('同期元が未設定です');
  const bundle = await httpsRequestJson(peerUrl.replace(/\/+$/, '') + '/api/sync/export', 'GET', undefined, 60000);
  await applySyncBundle(bundle);
  const exported_at = (bundle && bundle.exported_at) || '';
  markSyncResult(true, '同期しました（受信・' + exported_at + '）');
  return exported_at;
}

let syncRunning = false;

async function syncSchedulerTick(now) {
  const cfg = loadSyncConfig();
  const peer = (cfg.peer || '').trim();
  if (!peer || !isValidPeerUrl(peer)) return false;
  if (!validSyncTime(cfg.sync_time)) return false;
  const t = now || new Date();
  const hm = String(t.getHours()).padStart(2, '0') + ':' + String(t.getMinutes()).padStart(2, '0');
  if (hm < cfg.sync_time) return false;
  const today = t.getFullYear() + '-' + String(t.getMonth() + 1).padStart(2, '0') + '-' + String(t.getDate()).padStart(2, '0');
  if (typeof cfg.last_sync === 'string' && cfg.last_sync.slice(0, 10) === today) return false;
  if (syncRunning) return false;
  syncRunning = true;
  try {
    if (cfg.role === SYNC_ROLE_SOURCE) await syncPushToPeer(peer);
    else if (cfg.role === SYNC_ROLE_DEST) await syncPullFromPeer(peer);
    else return false;
    return true;
  } catch (e) {
    markSyncResult(false, '自動同期に失敗しました: ' + (e && e.message ? e.message : e));
    return false;
  } finally { syncRunning = false; }
}

setInterval(() => { syncSchedulerTick().catch(() => {}); }, 30000);

const server = http.createServer(async (req, res) => {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host || '127.0.0.1'}`);
  } catch {
    return json(res, 400, { error: 'bad request' });
  }
  let pn;
  try {
    pn = decodeURIComponent(url.pathname);
  } catch {
    return json(res, 400, { error: 'bad request' });
  }

  try {
    if ((pn === '/api/files' || pn === '/api/files/') && req.method === 'GET')
      return json(res, 200, await listDir(DATA));

    if (pn.startsWith('/api/files/') && req.method === 'GET') {
      const rel = pn.slice(11);
      if (!validRel(rel)) return json(res, 403, { error: 'denied' });
      const fp = path.join(DATA, rel);
      if (!safeData(fp)) return json(res, 403, { error: 'denied' });
      let st;
      try { st = await fsp.stat(fp); } catch { return json(res, 404, { error: 'not found' }); }
      if (st.isDirectory()) {
        if (!isInside(path.resolve(fp), DATA)) return json(res, 403, { error: 'denied' });
        return json(res, 200, await listDir(fp));
      }
      try {
        const content = await fsp.readFile(fp, 'utf-8');
        return json(res, 200, { content, path: rel });
      } catch { return json(res, 404, { error: 'not found' }); }
    }

    if ((pn === '/api/files' || pn === '/api/files/') && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (b === undefined || b === null) return json(res, 400, { error: 'bad json' });
      const parent = b.parent || '';
      if (!validRel(parent) || !validSegment(b.name)) return json(res, 400, { error: 'bad name' });
      const fp = path.join(parent, b.name);
      const full = path.join(DATA, fp);
      if (!safeData(full)) return json(res, 403, { error: 'denied' });
      if (path.resolve(full) === path.resolve(DATA)) return json(res, 400, { error: 'bad name' });
      try {
        if (fs.existsSync(full)) return json(res, 409, { error: 'exists' });
        if (b.isDir) fs.mkdirSync(full, { recursive: true });
        else { fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, ''); }
      } catch { return json(res, 500, { error: 'create failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true, path: fp });
    }

    if (pn.startsWith('/api/files/') && req.method === 'PUT') {
      const fp = pn.slice(11);
      if (!fp || !validRel(fp)) return json(res, 400, { error: 'bad path' });
      const full = path.join(DATA, fp);
      if (!safeData(full)) return json(res, 403, { error: 'denied' });
      if (path.resolve(full) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      let body;
      try { body = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (body === undefined || body === null) return json(res, 400, { error: 'bad json' });
      try {
        let st = null;
        try { st = fs.statSync(full); } catch {}
        if (st && st.isDirectory()) return json(res, 400, { error: 'is directory' });
        fs.mkdirSync(path.dirname(full), { recursive: true });
        fs.writeFileSync(full, body.content || '', 'utf-8');
      } catch { return json(res, 500, { error: 'write failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true });
    }

    if (pn.startsWith('/api/files/') && req.method === 'DELETE') {
      const fp = pn.slice(11);
      if (!fp || !validRel(fp)) return json(res, 400, { error: 'bad path' });
      const full = path.join(DATA, fp);
      if (!safeData(full)) return json(res, 403, { error: 'denied' });
      if (path.resolve(full) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      try {
        if (!fs.existsSync(full)) return json(res, 404, { error: 'not found' });
        fs.rmSync(full, { recursive: true });
      } catch { return json(res, 500, { error: 'delete failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true });
    }

    if (pn === '/api/rename' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (!b || typeof b.old !== 'string' || !validRel(b.old) || !b.old) return json(res, 400, { error: 'bad request' });
      if (!validSegment(b.newName)) return json(res, 400, { error: 'bad name' });
      const o = path.join(DATA, b.old);
      const n = path.join(path.dirname(o), b.newName.trim());
      if (!safeData(o) || !safeData(n)) return json(res, 403, { error: 'denied' });
      if (path.resolve(o) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      try {
        if (!fs.existsSync(o)) return json(res, 404, { error: 'not found' });
        if (fs.existsSync(n)) return json(res, 409, { error: 'exists' });
        fs.renameSync(o, n);
      } catch { return json(res, 500, { error: 'rename failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true, path: path.relative(DATA, n) });
    }

    if (pn === '/api/move' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (!b || typeof b.from !== 'string' || !b.from || !validRel(b.from)) return json(res, 400, { error: 'bad request' });
      const to = b.to || '';
      if (typeof to !== 'string' || !validRel(to)) return json(res, 400, { error: 'bad request' });
      const src = path.join(DATA, b.from);
      if (!safeData(src)) return json(res, 403, { error: 'denied' });
      if (path.resolve(src) === path.resolve(DATA)) return json(res, 400, { error: 'bad path' });
      let srcStat;
      try { srcStat = fs.statSync(src); } catch { return json(res, 404, { error: 'not found' }); }
      const destDir = path.join(DATA, to);
      const dest = path.join(destDir, path.basename(b.from));
      if (!safeData(destDir) || !safeData(dest)) return json(res, 403, { error: 'denied' });
      const rSrc = path.resolve(src);
      const rDest = path.resolve(dest);
      const rDestDir = path.resolve(destDir);
      if (rSrc === rDest) return json(res, 409, { error: 'exists' });
      if (rDest === path.resolve(DATA) || rDestDir === rSrc || rDest.startsWith(rSrc + path.sep) || rDestDir.startsWith(rSrc + path.sep)) {
        return json(res, 400, { error: 'cannot move into itself' });
      }
      try {
        if (fs.existsSync(dest)) return json(res, 409, { error: 'exists' });
        let destStat = null;
        try { destStat = fs.statSync(destDir); } catch {}
        if (destStat && !destStat.isDirectory()) return json(res, 400, { error: 'bad destination' });
        void srcStat;
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.renameSync(src, dest);
      } catch { return json(res, 500, { error: 'move failed' }); }
      invalidateCache();
      return json(res, 200, { ok: true, path: path.relative(DATA, dest) });
    }

    if (pn === '/api/favorites' && req.method === 'GET') {
      try {
        const data = fs.readFileSync(FAVORITES_FILE, 'utf-8');
        const parsed = JSON.parse(data);
        if (!Array.isArray(parsed)) return json(res, 200, []);
        return json(res, 200, parsed.filter(x => typeof x === 'string').slice(0, 500));
      } catch { return json(res, 200, []); }
    }

    if (pn === '/api/favorites' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      if (!b || !Array.isArray(b.favorites)) return json(res, 400, { error: 'bad request' });
      const favs = b.favorites.filter(x => typeof x === 'string' && x && validRel(x)).slice(0, 500);
      try {
        fs.mkdirSync(DATA, { recursive: true });
        fs.writeFileSync(FAVORITES_FILE, JSON.stringify(favs, null, 2), 'utf-8');
      } catch { return json(res, 500, { error: 'write failed' }); }
      return json(res, 200, { ok: true });
    }

    if (pn === '/api/restart' && req.method === 'POST') {
      json(res, 200, { ok: true });
      setTimeout(() => exec('systemctl restart selfnote'), 200);
      return;
    }

    if (pn === '/api/update' && req.method === 'POST') {
      let busy = false;
      try { if (Date.now() - fs.statSync(UPDATE_FLAG).mtimeMs < 15 * 60 * 1000) busy = true; } catch {}
      if (busy) return json(res, 409, { ok: false, error: 'updating' });
      try { fs.writeFileSync(UPDATE_FLAG, String(Date.now())); } catch {}
      json(res, 200, { ok: true });
      setTimeout(() => {
        const script = 'curl -fsSL https://raw.githubusercontent.com/hirogura/selfnote/main/install-selfnote.sh | bash';
        const hasSystemdRun = fs.existsSync('/usr/bin/systemd-run') || fs.existsSync('/bin/systemd-run');
        const cmd = hasSystemdRun
          ? `systemctl reset-failed selfnote-update 2>/dev/null; systemd-run --unit=selfnote-update --collect bash -c '${script}'`
          : `setsid bash -c "trap '' TERM HUP INT; ${script}" </dev/null >>/tmp/selfnote-update.log 2>&1 &`;
        exec(cmd);
      }, 100);
      return;
    }

    if (pn === '/api/update/status' && req.method === 'GET') {
      let updating = false;
      try {
        const st = fs.statSync(UPDATE_FLAG);
        // 15分以上前の stale なフラグは残留とみなして自己修復 (失敗時にずっと updating のままになるのを防ぐ)
        if (Date.now() - st.mtimeMs < 15 * 60 * 1000) updating = true;
        else try { fs.unlinkSync(UPDATE_FLAG); } catch {}
      } catch {}
      return json(res, 200, { updating });
    }

    if (pn === '/api/update/status' && req.method === 'DELETE') {
      try { fs.unlinkSync(UPDATE_FLAG); } catch {}
      return json(res, 200, { ok: true });
    }

    if (pn === '/api/sync/config' && req.method === 'GET') {
      const cfg = loadSyncConfig();
      return json(res, 200, { ...cfg, self_url: await getSelfBaseUrl(), self_name: await getSelfHostName() });
    }

    if (pn === '/api/sync/config' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { ok: false, error: 'body too large' }); }
      if (!b || typeof b !== 'object') return json(res, 400, { ok: false, error: 'bad request' });
      const role = b.role;
      const peer = typeof b.peer === 'string' ? b.peer.trim() : '';
      const peer_name = typeof b.peer_name === 'string' ? b.peer_name.trim().slice(0, 100) : '';
      const sync_time = typeof b.sync_time === 'string' ? b.sync_time.trim() : '';
      if (role !== SYNC_ROLE_SOURCE && role !== SYNC_ROLE_DEST) return json(res, 400, { ok: false, error: '同期元・同期先のいずれかを指定してください' });
      if (peer && !isValidPeerUrl(peer)) return json(res, 400, { ok: false, error: '同期先のURLが不正です' });
      if (!validSyncTime(sync_time)) return json(res, 400, { ok: false, error: '同期時刻は HH:MM 形式で指定してください' });
      const cfg = loadSyncConfig();
      const old_sync_time = cfg.sync_time || '';
      cfg.role = role; cfg.peer = peer; cfg.peer_name = peer_name; cfg.sync_time = sync_time;
      if (sync_time !== old_sync_time) {
        // 同期時刻が変わったら当日の同期済みフラグをリセットし、
        // その日のうちに即時テストできるようにする。
        cfg.last_sync = '';
        cfg.last_result = '同期時刻を変更したため、当日の同期済みフラグをリセットしました';
      }
      saveSyncConfig(cfg);
      // 相手側の役割を反対にそろえる（相手が旧バージョン等で失敗しても保存自体は成功扱い）
      let peer_notified = false, peer_message = '';
      if (peer && b.notify_peer !== false) {
        const opposite = role === SYNC_ROLE_SOURCE ? SYNC_ROLE_DEST : SYNC_ROLE_SOURCE;
        try {
          await httpsRequestJson(peer.replace(/\/+$/, '') + '/api/sync/role', 'POST',
            { role: opposite, peer_url: await getSelfBaseUrl(), peer_name: await getSelfHostName(), sync_time }, 10000);
          peer_notified = true;
          peer_message = '相手側を「' + (opposite === SYNC_ROLE_DEST ? '同期先' : '同期元') + '」に切り替え、同期時刻（' + sync_time + '）を共有しました';
        } catch (e) {
          peer_message = '相手側への通知に失敗しました（相手のselfnoteを最新版に更新してください）: ' + (e && e.message ? e.message : e);
        }
      }
      return json(res, 200, { ok: true, peer_notified, peer_message });
    }

    if (pn === '/api/sync/role' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { ok: false, error: 'body too large' }); }
      if (!b || typeof b !== 'object') return json(res, 400, { ok: false, error: 'bad request' });
      const role = b.role;
      const peer_url = typeof b.peer_url === 'string' ? b.peer_url.trim() : '';
      const peer_name = typeof b.peer_name === 'string' ? b.peer_name.trim().slice(0, 100) : '';
      if (role !== SYNC_ROLE_SOURCE && role !== SYNC_ROLE_DEST) return json(res, 400, { ok: false, error: 'invalid role' });
      if (peer_url && !isValidPeerUrl(peer_url)) return json(res, 400, { ok: false, error: 'invalid peer_url' });
      const cfg = loadSyncConfig();
      const old_sync_time = cfg.sync_time || '';
      cfg.role = role;
      if (peer_url) { cfg.peer = peer_url; cfg.peer_name = peer_name; }
      // 同期時刻も共有する（旧バージョンからは送られてこないため任意扱い）。
      // 形式が正しい場合のみ反映し、不正な値では役割の更新を妨げない。
      const sync_time = typeof b.sync_time === 'string' ? b.sync_time.trim() : '';
      if (validSyncTime(sync_time)) cfg.sync_time = sync_time;
      if (validSyncTime(sync_time) && sync_time !== old_sync_time) {
        // 相手側で時刻が変わった場合も当日の同期済みフラグをリセットし、
        // その日のうちに即時テストできるようにする。
        cfg.last_sync = '';
        cfg.last_result = '同期時刻を変更したため、当日の同期済みフラグをリセットしました';
      }
      saveSyncConfig(cfg);
      return json(res, 200, { ok: true, role, sync_time: cfg.sync_time });
    }

    if (pn === '/api/sync/peers' && req.method === 'GET') {
      return json(res, 200, { peers: await getSyncPeerList(), self_url: await getSelfBaseUrl(), self_name: await getSelfHostName() });
    }

    if (pn === '/api/sync/export' && req.method === 'GET') {
      return json(res, 200, await buildSyncBundle());
    }

    if (pn === '/api/sync/import' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req, SYNC_MAX_BODY)); } catch { return json(res, 413, { ok: false, error: 'body too large' }); }
      try { await applySyncBundle(b); }
      catch (e) { return json(res, 400, { ok: false, error: (e && e.message) || 'invalid bundle' }); }
      const exported_at = (b && b.exported_at) || '';
      markSyncResult(true, '同期しました（受信・' + exported_at + '）');
      return json(res, 200, { ok: true });
    }

    if (pn === '/api/sync/unlink' && req.method === 'POST') {
      // 相手PCからの停止連動用。相手が同期を停止したら自分の相手指定も外す。
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { ok: false, error: 'body too large' }); }
      if (!b || typeof b !== 'object') return json(res, 400, { ok: false, error: 'bad request' });
      const peer_url = typeof b.peer_url === 'string' ? b.peer_url.trim().replace(/\/+$/, '') : '';
      const cfg = loadSyncConfig();
      let unlinked = false;
      if (peer_url && (cfg.peer || '').replace(/\/+$/, '') === peer_url) {
        cfg.peer = ''; cfg.peer_name = '';
        cfg.last_result = '相手側で同期が停止されたため、相手指定を解除しました';
        saveSyncConfig(cfg);
        unlinked = true;
      }
      return json(res, 200, { ok: true, unlinked });
    }

    if (pn === '/api/sync/stop' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { ok: false, error: 'body too large' }); }
      if (b !== null && (typeof b !== 'object' || Array.isArray(b))) return json(res, 400, { ok: false, error: 'bad request' });
      const cfg = loadSyncConfig();
      const oldPeer = (cfg.peer || '').trim();
      cfg.peer = ''; cfg.peer_name = '';
      cfg.last_result = '同期を停止しました（' + new Date().toISOString() + '）';
      saveSyncConfig(cfg);
      // 相手側にも通知し、相手の相手指定を外す（ベストエフォート）
      let peer_notified = false, peer_message = '';
      if (oldPeer && (!b || b.notify_peer !== false)) {
        try {
          const r = await httpsRequestJson(oldPeer.replace(/\/+$/, '') + '/api/sync/unlink', 'POST',
            { peer_url: await getSelfBaseUrl() }, 10000);
          peer_notified = !!(r && r.unlinked);
          peer_message = peer_notified ? '相手側の同期設定も解除しました' : '相手側への通知は届きましたが、相手の相手指定は既に外れていました';
        } catch (e) {
          peer_message = '相手側への通知に失敗しました（相手のselfnoteを最新版に更新するか、相手側でも停止してください）: ' + (e && e.message ? e.message : e);
        }
      }
      return json(res, 200, { ok: true, peer_notified, peer_message });
    }

    if (pn === '/api/sync/run' && req.method === 'POST') {
      const cfg = loadSyncConfig();
      const peer = (cfg.peer || '').trim();
      if (!peer) return json(res, 400, { ok: false, error: '同期相手が未設定です。先に相手を選択して保存してください' });
      if (syncRunning) return json(res, 409, { ok: false, error: '同期を実行中です。しばらく待ってください' });
      syncRunning = true;
      try {
        if (cfg.role === SYNC_ROLE_SOURCE) {
          const exported_at = await syncPushToPeer(peer);
          return json(res, 200, { ok: true, direction: 'push', message: '同期先へ送信しました（' + exported_at + '）' });
        } else if (cfg.role === SYNC_ROLE_DEST) {
          const exported_at = await syncPullFromPeer(peer);
          return json(res, 200, { ok: true, direction: 'pull', message: '同期元から取得しました（' + exported_at + '）' });
        }
        return json(res, 400, { ok: false, error: '役割が不正です' });
      } catch (e) {
        markSyncResult(false, '手動同期に失敗しました: ' + (e && e.message ? e.message : e));
        return json(res, 500, { ok: false, error: (e && e.message ? e.message : e) });
      } finally { syncRunning = false; }
    }

    if (pn === '/api/recent' && req.method === 'GET') {
      const files = [];
      async function walk(dir) {
        let entries;
        try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
        for (const f of entries) {
          if (f.name.startsWith('.')) continue;
          const fp = path.join(dir, f.name);
          if (!safeData(fp)) continue;
          if (f.isDirectory()) { await walk(fp); continue; }
          if (!f.name.endsWith('.md')) continue;
          try {
            const st = await fsp.stat(fp);
            files.push({ path: path.relative(DATA, fp), mtime: st.mtimeMs || 0 });
          } catch {}
        }
      }
      await walk(DATA);
      files.sort((a, b) => b.mtime - a.mtime);
      return json(res, 200, files.slice(0, MAX_RECENT));
    }

    if (pn === '/api/search' && req.method === 'POST') {
      let b;
      try { b = parseJson(await readBody(req)); } catch { return json(res, 413, { error: 'body too large' }); }
      const raw = (b && b.query) || '';
      if (typeof raw !== 'string') return json(res, 400, { error: 'bad request' });
      const q = raw.toLowerCase().slice(0, MAX_SEARCH_QUERY);
      if (!q.trim()) return json(res, 200, []);
      const results = [];
      async function searchDir(dir, base) {
        if (results.length >= MAX_SEARCH_RESULTS) return;
        let entries;
        try { entries = await fsp.readdir(dir, { withFileTypes: true }); } catch { return; }
        for (const f of entries) {
          if (results.length >= MAX_SEARCH_RESULTS) break;
          if (f.name.startsWith('.')) continue;
          const fp = path.join(dir, f.name);
          if (!safeData(fp)) continue;
          const rel = base ? base + '/' + f.name : f.name;
          if (f.isDirectory()) { await searchDir(fp, rel); continue; }
          if (!f.name.endsWith('.md')) continue;
          try {
            const st = await fsp.stat(fp);
            if (st.size > MAX_SEARCH_FILE) continue;
            const content = await fsp.readFile(fp, 'utf-8');
            const lines = content.split('\n');
            for (let i = 0; i < lines.length; i++) {
              if (lines[i].toLowerCase().includes(q)) {
                results.push({ file: rel, line: i + 1, text: lines[i].trim().slice(0, 200) });
                break;
              }
            }
          } catch {}
        }
      }
      await searchDir(DATA, '');
      return json(res, 200, results);
    }

    let fp = pn === '/' ? '/index.html' : pn;
    let full = path.normalize(path.join(PUB, fp));
    if (!safePub(full)) return json(res, 403, { error: 'denied' });
    try {
      const st = fs.statSync(full);
      if (st.isDirectory()) full = path.join(PUB, 'index.html');
    } catch {
      full = path.join(PUB, 'index.html');
    }
    try {
      const data = fs.readFileSync(full);
      res.writeHead(200, { 'Content-Type': MIME[path.extname(full)] || 'application/octet-stream' });
      res.end(data);
    } catch { res.writeHead(404); res.end('Not found'); }
  } catch (e) {
    try { return json(res, 500, { error: 'internal' }); } catch {}
  }
});

server.on('error', (err) => {
  console.error('Server error:', err.code, err.message);
  process.exit(1);
});

server.listen(PORT, HOST, () => console.log('SelfNote: http://' + HOST + ':' + PORT));
